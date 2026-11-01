#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# What a package drops into the image outside the setuid files (ci/check-privileged.sh) and the unit
# links (image/units.sh) is code that runs as root or decides who may become root: polkit actions
# and rules, system D-Bus services and their policy, PAM stacks, udev rules. Each one the desktop adds
# to the base, or changes in it, must be a decision (docs/IMAGE.md, "Checks"), so this fails unless the
# files of IMAGE in those directories that BASE_IMAGE does not have, or has with other content, are
# exactly the ones image/added.txt lists. Also:
#   - no test-only setting of the session test (docs/TESTING.md) in /usr, /etc or the image's
#     environment;
#   - no udev rule the desktop adds or changes touches the DRM devices, and none of the image's
#     rules, units or module lists names vkms.
#   ci/check-added.sh IMAGE BASE_IMAGE
set -euo pipefail

dirs=(usr/share/polkit-1 etc/polkit-1 usr/share/dbus-1/system-services usr/share/dbus-1/system.d
  etc/dbus-1/system-services etc/dbus-1/system.d etc/pam.d usr/lib/pam.d usr/lib/udev/rules.d etc/udev/rules.d)

tmp="$(mktemp -d)"
m="" b=""
trap 'rm -rf "$tmp"; sudo podman image umount "$1" "$2" >/dev/null 2>&1 || true' EXIT
m="$(sudo podman image mount "$1")"
b="$(sudo podman image mount "$2")"
for x in "$m" "$b"; do
  # An empty or unmounted directory would list nothing and pass.
  sudo test -x "$x/usr/bin/bootc" || { echo "check-added.sh: an image is not mounted at $x" >&2; exit 1; }
done

# grep that fails on a read error (exit 2) as well as on a match (exit 0): only "no match" passes.
#   absent MESSAGE GREP_ARGS...
absent() {
  local msg="$1" rc=0
  shift
  sudo grep "$@" || rc=$?
  if [ "$rc" = 1 ]; then return 0; fi
  echo "check-added.sh: $msg$([ "$rc" = 0 ] || echo " (grep failed: $rc)")" >&2
  exit 1
}

list() { # the files in those directories as "/PATH HASH" (a link: "link:TARGET" for the hash)
  local d
  for d in "${dirs[@]}"; do
    if sudo test -d "$1/$d"; then
      sudo find "$1/$d" -type f -exec sha256sum {} + | sed -E "s|^([0-9a-f]+)  $1(.*)\$|\\2 \\1|"
      sudo find "$1/$d" -type l -printf "/$d/%P link:%l\n"
    fi
  done
}
list "$m" | LC_ALL=C sort > "$tmp/image"
list "$b" | LC_ALL=C sort > "$tmp/base"
# The new files and the changed ones, by path.
LC_ALL=C comm -13 "$tmp/base" "$tmp/image" | cut -d' ' -f1 | LC_ALL=C sort -u > "$tmp/new"
grep -Ev '^(#|$)' image/added.txt | LC_ALL=C sort > "$tmp/listed"
echo "Polkit, D-Bus, PAM and udev files the desktop adds or changes:"
cat "$tmp/new"
if ! diff -u "$tmp/listed" "$tmp/new"; then
  echo "check-added.sh: not the files image/added.txt lists (- listed, + in the image)" >&2
  exit 1
fi

# These make a session easy to test and a real one unsafe: AT-SPI exposes every window to any
# program on the bus, and KWin's screenshot interface answers any client, not only those it trusts.
# Text files only (-I): the programs themselves read these names.
test_only='QT_LINUX_ACCESSIBILITY_ALWAYS_ON|KWIN_SCREENSHOT_NO_PERMISSION_CHECKS|KCRASH_DUMP_ONLY|LP_NUM_THREADS|KWIN_COMPOSE|SESSION_DRM_DEVICE'
absent "a test-only setting is in the image (the files above)" -rIlE "$test_only" "$m/usr" "$m/etc"
env="$(sudo podman image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1")"
if grep -qE "^($test_only)=" <<<"$env"; then
  echo "check-added.sh: a test-only setting is in the image's environment" >&2
  exit 1
fi

# vkms is a virtual display (the session test loads it on the CI host only): a rule, unit or module
# list that names it would put it on every desktop.
vk=()
# The directories of configuration, not all of /etc: its certificate bundle is base64 text that can
# contain any four letters.
for d in etc/udev etc/systemd etc/modules-load.d etc/modprobe.d etc/tmpfiles.d etc/modules usr/lib/udev usr/lib/systemd \
    usr/lib/modules-load.d usr/lib/modprobe.d usr/lib/tmpfiles.d; do
  if sudo test -e "$m/$d"; then vk+=("$m/$d"); fi
done
absent "vkms is named in the image's configuration (the lines above)" -rIinw vkms "${vk[@]}"

# A rule that sets the mode, group or owner of a DRM device, or tags it for the logged-in user, would
# give every local program the GPU: the render nodes stay as the base makes them. Only the rule files
# the desktop adds or changes are looked at (the list above); the base's own rules are its decision.
# A line ending in a backslash goes on in the next one, so the lines are joined first.
while read -r f; do
  case "$f" in *.rules) ;; *) continue ;; esac
  rule="$(sudo sed -e ':a' -e '/\\$/{N;s/\\\n//;ba}' "$m$f")"
  absent "$f touches the DRM devices" -iE \
    '(drm|/dev/dri|card|render).*(MODE|GROUP|OWNER|uaccess)|(MODE|GROUP|OWNER|uaccess).*(drm|/dev/dri|card|render)' <<<"$rule"
done < "$tmp/new"
