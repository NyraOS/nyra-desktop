#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Moves the unit links that the package scripts made in /etc/systemd to /usr, or removes them, as
# image/units.list says (docs/IMAGE.md, "Services"). Fails on a link the list does not name, on a
# listed one that is not there, and on an "off" unit that our preset does not disable.
#   sh units.sh   (in the image build, with the list at /in/units.list and the base's root at /base)
set -eu

list=/in/units.list
cd /etc/systemd
# The links and files under /etc/systemd that the base does not have.
find . -mindepth 1 ! -type d | sed 's|^\./||' | LC_ALL=C sort | while read -r f; do
  if [ ! -e "/base/etc/systemd/$f" ] && [ ! -L "/base/etc/systemd/$f" ]; then echo "$f"; fi
done > /tmp/units.new
grep -Ev '^(#|$)' "$list" | awk '{ print $1 }' | LC_ALL=C sort > /tmp/units.listed
if ! diff -u /tmp/units.listed /tmp/units.new; then
  echo "units.sh: the packages made other links in /etc/systemd than image/units.list names (- listed, + made)" >&2
  exit 1
fi

grep -Ev '^(#|$)' "$list" | while read -r f what _; do
  case "$what" in
    usr)
      mkdir -p "/usr/lib/systemd/${f%/*}"
      mv "/etc/systemd/$f" "/usr/lib/systemd/$f"
      ;;
    off)
      rm "/etc/systemd/$f"
      # system/... is disabled by the system preset, user/... by the user preset.
      preset="/usr/lib/systemd/${f%%/*}-preset/80-nyra-desktop.preset"
      grep -qx "disable ${f##*/}" "$preset" || { echo "units.sh: $preset does not disable ${f##*/}" >&2; exit 1; }
      ;;
    *) echo "units.sh: '$what' for $f is neither usr nor off" >&2; exit 1 ;;
  esac
done
# The directories the links were in, when the base does not have them.
find . -mindepth 1 -depth -type d -empty | sed 's|^\./||' | while read -r d; do
  if [ ! -d "/base/etc/systemd/$d" ]; then rmdir "$d"; fi
done
