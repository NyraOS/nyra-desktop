#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# One language of the system in the VM, as tests/vm/plasma.sh runs it as root (the script is on the test's
# SD card; test only, never shipped): sets the language and the keyboard by writing the files localectl writes, as the installer
# does, restarts SDDM and checks the login screen and then the Plasma session of the test user nyratest,
# which both must run in that language. The screenshots are taken by the test runner when this prints
# NYRA-SHOT-<name> (QMP commands of plasma.sh).
#   language-session.sh LANG CONSOLE_KEYMAP X11_LAYOUT NAME
set -eu

lang="$1" keymap="$2" layout="$3" name="$4"
# Up to 120 s for a command to succeed (the same as wait_for in plasma.sh).
w() { for _ in $(seq 60); do if eval "$1"; then return 0; fi; sleep 2; done; eval "$1"; }
greeter='pgrep -u sddm -f "^/usr/bin/sddm-greeter-qt6 " >/dev/null && pgrep -u sddm -x kwin_wayland >/dev/null'
session='s="$(loginctl show-user nyratest -p Display --value 2>/dev/null)" && [ -n "$s" ] && [ "$(loginctl show-session "$s" -p Type --value)" = wayland ] && [ "$(loginctl show-session "$s" -p Active --value)" = yes ] && pgrep -u nyratest -x plasmashell >/dev/null'
# The value of LANG in the environment of the process that has the given name and user.
lang_of() { tr '\0' '\n' < "/proc/$(pgrep -u "$1" -f "$2" | head -n 1)/environ" | sed -n 's/^LANG=//p'; }

# The files that localectl (systemd-localed) writes, written directly: the image's polkit administrator is
# root only (49-nyra.rules), and root on the serial console is no active local session, so polkit has
# nobody to ask and localed refuses set-locale, set-keymap and set-x11-keymap there. The installer writes
# the same files before the first boot (first-admin does it for /etc/locale.conf); localed and kwin
# (--locale1) then read them as for any user. Nothing is loosened: the same files are checked below.
mkdir -p /etc/X11/xorg.conf.d
printf 'LANG=%s\n' "$lang" > /etc/locale.conf
printf 'KEYMAP=%s\n' "$keymap" > /etc/vconsole.conf
cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<EOF
# Written by localectl
Section "InputClass"
        Identifier "system-keyboard"
        MatchIsKeyboard "on"
        Option "XkbLayout" "$layout"
        Option "XkbModel" "pc105"
EndSection
EOF
localectl status
grep -qx "LANG=$lang" /etc/locale.conf
grep -qx "KEYMAP=$keymap" /etc/vconsole.conf
grep -q "Option \"XkbLayout\" \"$layout\"" /etc/X11/xorg.conf.d/00-keyboard.conf

# The login screen: without the autologin of the test.
rm -f /etc/sddm.conf.d/99-nyra-test.conf
systemctl restart sddm.service
w "$greeter"
sleep 30
got="$(lang_of sddm '^/usr/bin/sddm-greeter-qt6 ')"
echo "login screen: LANG=$got"
[ "$got" = "$lang" ]
echo "NYRA-SHOT-login-screen-$name"
sleep 3

# The session of the test user.
mkdir -p /etc/sddm.conf.d
printf '[Autologin]\nUser=nyratest\nSession=plasma.desktop\n' > /etc/sddm.conf.d/99-nyra-test.conf
loginctl terminate-user nyratest 2>/dev/null || true
# Plasma writes [Formats] LANG of the language it first started in to the user's plasma-localerc (measured
# in CI: en_US from the test user's first session), and startplasma then lets that file win over the
# system language. A user who chose a language at the installer has the file in that language; this test
# user is reused for each language, so its file is removed to be a user who has not been in Plasma yet.
rm -f ~nyratest/.config/plasma-localerc
systemctl restart sddm.service
w "$session"
sleep 90
# Where the session's LANG comes from, stage by stage (printed whatever the result, for the log).
for p in "sddm /usr/bin/sddm$" "root sddm-helper" "nyratest systemd --user" "nyratest startplasma" "nyratest kwin_wayland" "nyratest plasmashell"; do
  u="${p%% *}" pat="${p#* }"
  if pid="$(pgrep -u "$u" -f "$pat" | head -n 1)" && [ -n "$pid" ]; then
    echo "  $pat (pid $pid): LANG=$(tr '\0' '\n' < "/proc/$pid/environ" | sed -n 's/^LANG=//p')"
  else
    echo "  $pat: not running"
  fi
done
echo "  user manager: $(runuser -u nyratest -- env XDG_RUNTIME_DIR="/run/user/$(id -u nyratest)" systemctl --user show-environment 2>&1 | grep -E '^LANG' || echo 'no LANG')"
ls -l /etc/default/locale; cat ~nyratest/.config/plasma-localerc 2>/dev/null || echo "no plasma-localerc"
got="$(lang_of nyratest '^/usr/bin/plasmashell')"
echo "plasma session: LANG=$got"
[ "$got" = "$lang" ]
echo "NYRA-SHOT-plasma-session-$name"
sleep 3
