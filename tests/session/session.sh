#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# The desktop session of the session test (docs/TESTING.md), started by run.sh inside the desktop
# image as uid 1000: a session bus, KWin at 1280x800 and plasmashell. KWin runs on its virtual backend
# (no display), or on its DRM backend when run.sh hands it a display-only KMS device such as vkms in
# KWIN_DRM_DEVICES (docs/TESTING.md, "The screenshot"). Everything here is test setup and stays out of
# the image:
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
if [ -z "${KWIN_DRM_DEVICES:-}" ]; then
  exec dbus-run-session --config-file=/harness/session-bus.conf -- \
    kwin_wayland --virtual --width 1280 --height 800 --no-lockscreen plasmashell
fi
# The DRM backend: no logind here, so KWin opens the device itself. llvmpipe draws on the device's
# primary node (GBM in software: the device has no Mesa driver); KWin would not pick OpenGL for a
# software renderer without KWIN_COMPOSE. The device
# has no EDID and its own preferred mode, so the output gets a custom 1280x800 mode (CVT, 60 Hz,
# which KWin stores as 59810 mHz with the Generated and Custom flags). KWin matches the entry by the
# empty EDID, as the only output; the connector name is the one vkms gets.
export KWIN_COMPOSE=O2 GBM_ALWAYS_SOFTWARE=1
cat > "$HOME/.config/kwinoutputconfig.json" <<'JSON'
[
  {"name": "outputs", "data": [{
    "connectorName": "Virtual-2",
    "mode": {"width": 1280, "height": 800, "refreshRate": 59810, "flags": 10},
    "customModes": [{"width": 1280, "height": 800, "refreshRate": 60000, "flags": 0}],
    "scale": 1
  }]},
  {"name": "setups", "data": [{"lidClosed": false, "outputs": [
    {"enabled": true, "outputIndex": 0, "position": {"x": 0, "y": 0}, "priority": 0}
  ]}]}
]
JSON
exec dbus-run-session --config-file=/harness/session-bus.conf -- \
  kwin_wayland --drm --no-lockscreen plasmashell
