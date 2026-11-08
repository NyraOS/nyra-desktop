#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Draws the PNG files of the boot screen theme from the SVG drawings next to this script. The PNGs are
# committed (the image build has no network and no SVG renderer); run this and commit the result when a
# drawing changes. Needs rsvg-convert (Debian: librsvg2-bin).
#   sh image/plymouth/make-assets.sh
# logo.svg is the Nyra mark with the moon in the accent colour (branding/logo/nyra-mark-white-moon-blue.svg
# of the project's brand files); the ring is the loading ring of the boot screen design, a faint track and
# the arc that the theme turns. The theme scales both to the screen, so they are drawn larger than any
# screen needs them.
set -eu
here="$(dirname "$(realpath "$0")")"
out="$here/../files/usr/share/plymouth/themes/nyra"
rsvg-convert -w 512 -h 512 "$here/logo.svg" -o "$out/logo.png"
rsvg-convert -w 256 -h 256 "$here/ring-track.svg" -o "$out/ring-track.png"
rsvg-convert -w 256 -h 256 "$here/ring-arc.svg" -o "$out/ring-arc.png"
