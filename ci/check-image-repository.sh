#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The identity of a desktop image (docs/IMAGE.md, "Identity"), read from the built image: a machine
# that runs it must follow the desktop's channel sheets, never the base's, and must compare versions
# in the desktop's own numbers. The repository is bound to the architecture:
#   nyra-desktop        linux/amd64
#   nyra-desktop-arm64  linux/arm64
# and nothing else (the base's own repositories are refused). Refuses unless the image's config says that
# OS and architecture, its /usr/lib/nyra/updates/updated.conf has exactly the line
# `repository = REPOSITORY`, `channel = stable` and a version_floor that is not above VERSION, and its
# /usr/lib/os-release and version label say VERSION and the desktop variant. VERSION is year.month.run.
# Reads the image with podman create and cp: nothing from the image runs, so it can read an image of
# another architecture than the runner's.
#   ci/check-image-repository.sh IMAGE REPOSITORY VERSION
#   ci/check-image-repository.sh --self-test
set -euo pipefail

refuse() { echo "check-image-repository: refused: $*" >&2; exit 1; }

# conf: the updated.conf file, VERSION, REPOSITORY. Refuses unless it is the desktop's.
check_conf() {
  local conf="$1" version="$2" repository="$3" lines floor
  lines="$(grep -E '^[[:space:]]*repository[[:space:]]*=' "$conf")" || true
  [ "$lines" = "repository = $repository" ] ||
    refuse "updated.conf must have exactly the line 'repository = $repository', it has: ${lines:-none}"
  [ "$(grep -Ecx 'channel = stable' "$conf")" = 1 ] || refuse "updated.conf must have the line 'channel = stable'"
  floor="$(sed -n 's/^version_floor = //p' "$conf")"
  [[ "$floor" =~ ^[0-9]{4}\.[0-9]{1,2}\.[0-9]+$ ]] || refuse "updated.conf has no version_floor of the form year.month.run: '$floor'"
  # The floor is not above the image's own version (nothing could update to it, and it could not boot-check).
  [ "$(printf '%s\n%s\n' "$floor" "$version" | sort -V | head -n 1)" = "$floor" ] ||
    refuse "version_floor $floor is above the image's version $version"
}

check_version() { [[ "$1" =~ ^[0-9]{4}\.[0-9]{1,2}\.[0-9]+$ ]] || refuse "'$1' is not a release version (year.month.run)"; }

if [ "${1:-}" = --self-test ]; then
  d="$(mktemp -d)"
  trap 'rm -rf "$d"' EXIT
  good=$'# a comment\nrepository = nyra-desktop-arm64\nchannel = stable\nversion_floor = 2026.10.1\n'
  t() { # WANTED_EXIT_CODE CONF VERSION REPOSITORY WHAT
    local rc=0
    printf '%s' "$2" > "$d/conf"
    ( check_conf "$d/conf" "$3" "$4" ) >/dev/null 2>&1 || rc=$?
    [ "$rc" = "$1" ] || { echo "self-test: $5"; exit 1; }
  }
  t 0 "$good" 2026.10.35 nyra-desktop-arm64 "refused the good file"
  t 1 "$good" 2026.10.35 nyra-desktop "accepted the arm64 repository for amd64"
  t 1 "${good/desktop-arm64/base}" 2026.10.35 nyra-desktop-arm64 "accepted nyra-base"
  t 1 "${good/desktop-arm64/base-arm64}" 2026.10.35 nyra-desktop-arm64 "accepted nyra-base-arm64"
  t 1 "$good"$'repository = nyra-desktop-arm64\n' 2026.10.35 nyra-desktop-arm64 "accepted two repository lines"
  t 1 "${good/channel = stable/channel = dev}" 2026.10.35 nyra-desktop-arm64 "accepted channel dev"
  t 1 "${good/version_floor = 2026.10.1/}" 2026.10.35 nyra-desktop-arm64 "accepted no floor"
  t 1 "$good" 2026.9.35 nyra-desktop-arm64 "accepted a floor above the version"
  t 0 "$good" 2026.10.1 nyra-desktop-arm64 "refused a floor equal to the version"
  ( check_version 2026.10.35 ) || { echo "self-test: refused a version"; exit 1; }
  for v in dev 2026.10 2026.10.35.1 ""; do
    if ( check_version "$v" ) >/dev/null 2>&1; then echo "self-test: accepted version '$v'"; exit 1; fi
  done
  echo "check-image-repository.sh self-test: ok"
  exit 0
fi

image="$1" repository="$2" version="$3"
check_version "$version"
case "$repository" in
  nyra-desktop) want=linux/amd64 ;;
  nyra-desktop-arm64) want=linux/arm64 ;;
  *) refuse "'$repository' is not a desktop release repository (nyra-desktop, nyra-desktop-arm64)" ;;
esac
got="$(sudo podman image inspect -f '{{.Os}}/{{.Architecture}}' "$image")"
[ "$got" = "$want" ] || refuse "$image is $got, $repository takes $want"
label="$(sudo podman image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$image")"
[ "$label" = "$version" ] || refuse "$image's version label is '$label', not $version"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cid="$(sudo podman create -q --platform "$want" "$image")"
sudo podman cp "$cid:/usr/lib/nyra/updates/updated.conf" "$tmp/updated.conf"
sudo podman cp "$cid:/usr/lib/os-release" "$tmp/os-release"
sudo podman rm -f "$cid" >/dev/null
check_conf "$tmp/updated.conf" "$version" "$repository"
for line in "IMAGE_VERSION=$version" "PRETTY_NAME=\"Nyra OS $version\"" VARIANT_ID=desktop; do
  [ "$(grep -Fxc "$line" "$tmp/os-release")" = 1 ] || refuse "/usr/lib/os-release must have exactly one line $line"
done
echo "check-image-repository: $image is $got, version $version, and follows $repository"
