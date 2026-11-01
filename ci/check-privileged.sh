#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Setuid and setgid files, and files with capabilities (security.capability), give a local user root's
# (or a group's) rights: one the desktop adds to the base must be a decision, not a side effect of a
# package (docs/IMAGE.md, "Checks"). Fails unless the files of IMAGE that BASE_IMAGE does not have
# are exactly the ones image/privileged.txt lists, with their mode or capabilities.
#   ci/check-privileged.sh IMAGE BASE_IMAGE
set -euo pipefail

list() { # the setuid, setgid and capability files of an image: "PATH mode" and "PATH capabilities"
  local m
  m="$(sudo podman image mount "$1")"
  # An empty or unmounted directory would list nothing and pass.
  sudo test -x "$m/usr/bin/bootc" || { echo "check-privileged.sh: $1 is not mounted at $m" >&2; return 1; }
  sudo find "$m" -xdev -type f -perm /6000 -printf '/%P %m\n'
  sudo getcap -r "$m" | sed "s|^$m||"
  sudo podman image umount "$1" >/dev/null
}
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
list "$1" | LC_ALL=C sort > "$tmp/image"
list "$2" | LC_ALL=C sort > "$tmp/base"
LC_ALL=C comm -13 "$tmp/base" "$tmp/image" > "$tmp/new"
grep -Ev '^(#|$)' image/privileged.txt | LC_ALL=C sort > "$tmp/listed"
echo "Setuid, setgid and capability files the desktop adds:"
cat "$tmp/new"
if ! diff -u "$tmp/listed" "$tmp/new"; then
  echo "check-privileged.sh: not the files image/privileged.txt lists (- listed, + in the image)" >&2
  exit 1
fi
