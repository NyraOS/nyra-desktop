#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The session test (docs/TESTING.md): the desktop session runs in one container (session.sh), the
# checks in another (test_session.py, in the image of tools.Containerfile). The two share only the
# session's XDG_RUNTIME_DIR: the session bus, the AT-SPI bus and the Wayland socket.
#   tests/session/run.sh OUT
# OUT gets session.log, screenshot.png, diff.png and summary.md.
# Environment:
#   DESKTOP_IMAGE  the desktop image to test, any reference podman can run (an image in the store,
#                  oci-archive:PATH, ...). Default: the throwaway image of desktop.Containerfile.
#   PODMAN_STORE   a directory for a podman store of its own (--root/--runroot under it). Default:
#                  podman's default store.
# Needs a DRM device in /dev/dri that the calling user can open (CI loads vgem): KWin composites with
# OpenGL (llvmpipe) only on one, and its screenshots need OpenGL compositing.
# Both containers run rootless, as uid 1000 mapped to the calling user. Core dumps of the session are
# collected in OUT/cores when kernel.core_pattern is /cores/core.%e.%p (CI sets it).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out="$(realpath -m "${1:?usage: run.sh OUT}")"
podman=(podman)
if [ -n "${PODMAN_STORE:-}" ]; then
  podman+=(--root "$PODMAN_STORE/root" --runroot "$PODMAN_STORE/run")
fi

# Builds NAME.Containerfile as localhost/nyra-session-NAME:<hash of its inputs>, unless that image
# exists already (from the CI cache or an earlier run), and prints the reference.
# The base image (FROM, pinned by digest) is pulled from Amazon ECR Public's copy of Docker Hub's
# official images, or from Docker Hub when ECR refuses (it limits busy runner IPs); the digest is the
# same on both and podman checks it.
image() {
  local tag digest source
  tag="localhost/nyra-session-$1:$(cat "$here/$1.Containerfile" "$here/apt-snapshot.sh" | sha256sum | cut -c1-16)"
  if ! "${podman[@]}" image exists "$tag"; then
    echo "Building $tag" >&2
    digest="$(sed -n 's/^FROM .*@sha256:/sha256:/p' "$here/$1.Containerfile")"
    for source in public.ecr.aws/docker/library/debian docker.io/library/debian; do
      "${podman[@]}" image exists "$source@$digest" && break
      "${podman[@]}" pull -q "$source@$digest" >/dev/null && break
    done
    "${podman[@]}" build -q --pull=never --from "$source@$digest" -t "$tag" -f "$here/$1.Containerfile" "$here" \
      >/dev/null || return 1
  fi
  echo "$tag"
}

# Plain assignments, so that a failed build stops the script (set -e).
desktop="${DESKTOP_IMAGE:-}"
[ -n "$desktop" ] || desktop="$(image desktop)"
tools="$(image tools)"
rm -rf "$out"
mkdir -p "$out/cores" "$out/home"
runtime="$(mktemp -d)"
name="nyra-session-$$"
cleanup() {
  "${podman[@]}" logs "$name" >"$out/session.log" 2>&1 || true
  "${podman[@]}" rm -f -t 0 "$name" >/dev/null 2>&1 || true
  rm -rf "$runtime"
}
trap cleanup EXIT

# keep-id: uid 1000 in both containers is the calling user, so the two can talk over the sockets
# and OUT stays readable without podman unshare.
user=("--userns=keep-id:uid=1000,gid=1000" --user 1000:1000 -v "$runtime:/run/user/1000" -v "$here:/harness:ro")
devices=()
for d in /dev/dri/card* /dev/dri/renderD*; do
  [ -e "$d" ] && devices+=(--device "$d")
done
# SYS_NICE: kwin_wayland carries the file capability cap_sys_nice, and exec refuses a file whose
# capabilities are outside the bounding set. The hostname shows in the launcher.
"${podman[@]}" run -d --name "$name" "${user[@]}" "${devices[@]}" --cap-add SYS_NICE --hostname nyra-test \
  -v "$out/home:/home/user" -v "$out/cores:/cores" --ulimit core=-1 \
  --entrypoint /harness/session.sh "$desktop" >/dev/null

status=0
rows=()
# A check of this script: printed, and a row of OUT/summary.md after test_session.py's.
result() {
  rows+=("| $1 | $([ "$2" = pass ] && echo pass || echo '**FAIL**') | ${3:-} |")
  echo "$([ "$2" = pass ] && echo PASS || echo FAIL): $1${3:+: $3}" >&2
  [ "$2" = pass ] || status=1
}
core_pattern="$(cat /proc/sys/kernel/core_pattern)"
if [ "$core_pattern" = "/cores/core.%e.%p" ]; then
  # Proves that a crash in the session container leaves a core dump where the check below looks.
  "${podman[@]}" exec "$name" sh -c 'sleep 60 & kill -SEGV $!; wait' || true
  if [ -n "$(ls -A "$out/cores")" ]; then
    result "core dumps are collected (a deliberate crash left one)" pass
  else
    result "core dumps are collected (a deliberate crash left one)" fail
  fi
  rm -f "$out"/cores/core.*
else
  result "core dumps are collected" fail "not on this machine: kernel.core_pattern is $core_pattern, CI sets /cores/core.%e.%p"
fi

"${podman[@]}" run --rm "${user[@]}" -v "$out:/out" \
  -e DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus -e XDG_RUNTIME_DIR=/run/user/1000 \
  "$tools" python3 -I /harness/test_session.py /harness/reference.png /out || status=1

if [ "$("${podman[@]}" inspect -f '{{.State.Running}}' "$name")" = true ]; then
  result "the session runs until the end" pass
else
  result "the session runs until the end" fail
fi
cleanup
trap - EXIT
# Zero crashes: no core dump and no crash caught by KCrash (KDE programs log it there, then dump core;
# some restart themselves, which test_session.py notices for plasmashell).
if [ -z "$(ls -A "$out/cores")" ]; then
  result "no core dumps" pass
else
  result "no core dumps" fail "$(find "$out/cores" -type f -printf '%f ')"
fi
if grep -q 'KCrash' "$out/session.log"; then
  result "no crash caught by KCrash" fail "$(grep -m 3 'KCrash' "$out/session.log" | tr '\n|' '  ')"
else
  result "no crash caught by KCrash" pass
fi
[ -f "$out/summary.md" ] || printf '| Check | Result | Detail |\n|---|---|---|\n' >"$out/summary.md"
printf '%s\n' "${rows[@]}" >>"$out/summary.md"
exit "$status"
