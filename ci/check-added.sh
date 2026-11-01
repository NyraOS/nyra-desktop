#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# What a package drops into the image outside the setuid files (ci/check-privileged.sh) and the unit
# links (image/units.sh) is code that runs as root or decides who may become root: polkit actions
# and rules, system D-Bus services and their policy, PAM stacks. Each one the desktop adds to the base
# must be a decision (docs/IMAGE.md, "Checks"), so this fails unless the files of IMAGE that
# BASE_IMAGE does not have, in those directories, are exactly the ones image/added.txt lists. Also:
#   - no test-only setting of the session test (docs/TESTING.md) in /usr, /etc or the image's
#     environment;
#   - no udev rule the desktop adds touches the DRM devices, and none loads or names vkms.
#   ci/check-added.sh IMAGE BASE_IMAGE
set -euo pipefail

dirs=(usr/share/polkit-1 etc/polkit-1 usr/share/dbus-1/system-services usr/share/dbus-1/system.d
  etc/dbus-1/system-services etc/dbus-1/system.d etc/pam.d usr/lib/pam.d)

list() { # the files of an image in those directories, as /PATH
  local m d
  m="$(sudo podman image mount "$1")"
  # An empty or unmounted directory would list nothing and pass.
  sudo test -x "$m/usr/bin/bootc" || { echo "check-added.sh: $1 is not mounted at $m" >&2; return 1; }
  for d in "${dirs[@]}"; do
    if sudo test -d "$m/$d"; then sudo find "$m/$d" \( -type f -o -type l \) -printf "/$d/%P\\n"; fi
  done
  sudo podman image umount "$1" >/dev/null
}
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
list "$1" | LC_ALL=C sort > "$tmp/image"
list "$2" | LC_ALL=C sort > "$tmp/base"
LC_ALL=C comm -13 "$tmp/base" "$tmp/image" > "$tmp/new"
grep -Ev '^(#|$)' image/added.txt | LC_ALL=C sort > "$tmp/listed"
echo "Polkit, D-Bus and PAM files the desktop adds:"
cat "$tmp/new"
if ! diff -u "$tmp/listed" "$tmp/new"; then
  echo "check-added.sh: not the files image/added.txt lists (- listed, + in the image)" >&2
  exit 1
fi

# The checks below read the image's files; the base's are only for telling a new udev rule from its own.
m="$(sudo podman image mount "$1")"
b="$(sudo podman image mount "$2")"
trap 'rm -rf "$tmp"; sudo podman image umount "$1" "$2" >/dev/null' EXIT
for x in "$m" "$b"; do
  sudo test -x "$x/usr/bin/bootc" || { echo "check-added.sh: an image is not mounted at $x" >&2; exit 1; }
done

# These make a session easy to test and a real one unsafe: AT-SPI exposes every window to any
# program on the bus, and KWin's screenshot interface answers any client, not only those it trusts.
# Text files only (-I): the programs themselves read these names.
test_only='QT_LINUX_ACCESSIBILITY_ALWAYS_ON|KWIN_SCREENSHOT_NO_PERMISSION_CHECKS|KCRASH_DUMP_ONLY|LP_NUM_THREADS|KWIN_COMPOSE|SESSION_DRM_DEVICE'
if sudo grep -rIlE "$test_only" "$m/usr" "$m/etc"; then
  echo "check-added.sh: a test-only setting is in the image (the files above)" >&2
  exit 1
fi
if sudo podman image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" | grep -E "^($test_only)="; then
  echo "check-added.sh: a test-only setting is in the image's environment" >&2
  exit 1
fi

# vkms is a virtual display (the session test loads it on the CI host only): a rule or a module list
# that names it would put it on every desktop.
if sudo grep -rIliEs 'vkms' "$m/usr/lib/udev" "$m/etc/udev" "$m/usr/lib/modules-load.d" "$m/etc/modules-load.d" \
    "$m/usr/lib/modprobe.d" "$m/etc/modprobe.d" "$m/etc/modules"; then
  echo "check-added.sh: vkms is named in a udev rule or a module list (the files above)" >&2
  exit 1
fi
# A rule that sets the mode, group or owner of a DRM device, or tags it for the logged-in user, would
# give every local program the GPU: the render nodes stay as the base makes them. Only the rule files
# the base does not have are looked at; the base's own rules are the base's decision.
for d in usr/lib/udev/rules.d etc/udev/rules.d; do
  sudo test -d "$m/$d" || continue
  while read -r f; do
    if sudo test -e "$b/$d/$f"; then continue; fi
    if sudo grep -iE '(drm|/dev/dri|card|render).*(MODE|GROUP|OWNER|uaccess)|(MODE|GROUP|OWNER|uaccess).*(drm|/dev/dri|card|render)' "$m/$d/$f"; then
      echo "check-added.sh: /$d/$f touches the DRM devices" >&2
      exit 1
    fi
  done < <(sudo find "$m/$d" -type f -name '*.rules' -printf '%P\n')
done
