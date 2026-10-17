#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# The desktop session of the session test (docs/TESTING.md), started by run.sh inside the desktop
# image as uid 1000: a session bus, KWin on its virtual backend (no GPU, no display) at 1280x800 and
# plasmashell. Everything here is test setup and stays out of the image:
# - AT-SPI always on in Qt, so the test container can read the tree without enabling it first;
# - KWin's ScreenShot2 without its permission check (it allows only known clients otherwise);
# - no animations and a fixed number of llvmpipe threads, so screenshots do not depend on timing or
#   on the machine;
# - KDE programs that crash dump core and never open the crash dialog (run.sh looks for both).
set -eu
export XDG_RUNTIME_DIR=/run/user/1000 HOME=/home/user
# What startplasma would set; plasma- selects Plasma's menu file (the launcher is empty without it).
export XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=KDE XDG_SESSION_DESKTOP=KDE KDE_SESSION_VERSION=6
export KDE_FULL_SESSION=true XDG_MENU_PREFIX=plasma-
export LANG=C.UTF-8 TZ=UTC
export QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1
export KWIN_SCREENSHOT_NO_PERMISSION_CHECKS=1
export LP_NUM_THREADS=2
export KCRASH_DUMP_ONLY=1
mkdir -p "$HOME/.config"
printf '[KDE]\nAnimationDurationFactor=0\n' > "$HOME/.config/kdeglobals"
cd "$HOME"
exec dbus-run-session --config-file=/harness/session-bus.conf -- \
  kwin_wayland --virtual --width 1280 --height 800 --no-lockscreen plasmashell
