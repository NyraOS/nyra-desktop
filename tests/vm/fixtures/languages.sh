#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# The language checks of tests/vm/plasma.sh, run in the VM as root (the script is on the test's SD card;
# test only, never shipped). It fails, naming the language, when one of these is missing from the image:
#   - the locale (glibc's data: the weekday of 2 November 2026 must be spelled as the language does);
#   - the translation of a KDE application (Konsole's catalog) and of the login screen (SDDM);
#   - a font with a letter that only that language's script has (no empty boxes where text should be).
# Non-ASCII text is written as hex bytes, so that the script does not depend on the console's encoding.
set -u

command -v fc-list >/dev/null || { echo "FAIL: fc-list (fontconfig) is not in the image"; exit 1; }
bad=0
fail() { echo "FAIL: $*"; bad=1; }
# A locale of that name, in UTF-8 (a missing one makes locale fall back to the C locale, whose charmap is ASCII).
utf8() { [ "$(LC_ALL=$1.UTF-8 locale charmap 2>/dev/null)" = UTF-8 ]; }

# language, locale, "Monday" in that language (hex of the UTF-8 bytes), a letter of its script (hex code point)
while read -r lang loc monday glyph; do
  [ -n "$lang" ] || continue
  utf8 "$loc" || { fail "$lang: no UTF-8 locale $loc"; continue; }
  got="$(LC_ALL=$loc.UTF-8 date -d 2026-11-02 +%A | od -An -tx1 | tr -d ' \n')"
  [ "$got" = "${monday}0a" ] || fail "$lang: Monday is $got, not $monday"
  if [ "$lang" != en ]; then
    [ -f "/usr/share/locale/$lang/LC_MESSAGES/konsole.mo" ] || fail "$lang: no Konsole translation"
  fi
  [ "$lang" = en ] || [ -f "/usr/share/sddm/translations-qt6/$lang.qm" ] || fail "$lang: no SDDM translation"
  [ -n "$(fc-list ":charset=$glyph" family)" ] || fail "$lang: no font has U+$glyph"
  echo "ok: $lang ($loc, translations, a font for U+$glyph)"
done <<EOF2
en en_US 4d6f6e646179 41
ro ro_RO 6c756e69 219
ja ja_JP e69c88e69b9ce697a5 65e5
ar ar_SA d8a7d984d8a7d8abd986d98ad986 639
EOF2

# More scripts, without a spoken check: a font for each (Hebrew, Devanagari, Bengali, Tamil, Thai,
# Hangul, Simplified Chinese, Greek, Cyrillic) and a locale and translation for the languages that use them.
for s in he:5d0 hi:905 bn:985 ta:b85 th:e01 ko:d55c zh:4e2d el:3b1 ru:436; do
  lang="${s%:*}" glyph="${s#*:}"
  [ -n "$(fc-list ":charset=$glyph" family)" ] || fail "$lang: no font has U+$glyph"
done
for lang in he:he_IL hi:hi_IN bn:bn_BD ta:ta_IN th:th_TH ko:ko_KR zh:zh_CN el:el_GR ru:ru_RU de:de_DE fr:fr_FR es:es_ES; do
  l="${lang#*:}"
  utf8 "$l" || fail "no UTF-8 locale $l"
done

# The long list: the image must carry a locale for every language of the GNU C library, selectable
# without the network (UTF-8 only: the legacy ones do not count).
n=0
for l in $(locale -a | sed -E 's/[.@].*//' | sort -u); do utf8 "$l" && n=$((n + 1)); done
echo "$n UTF-8 locales"
[ "$n" -ge 300 ] || fail "only $n UTF-8 locales, at least 300 expected"

# Settings saves the language and the layout through systemd-localed, which asks polkit. The base makes root
# the only polkit administrator (49-nyra.rules), so without image/files/usr/share/polkit-1/rules.d/48-nyra-desktop-locale.rules
# nobody could approve it. Here two users really authenticate (a text agent in a pseudo-terminal types the
# password): a member of sudo must be let through for each of the two locale1 actions with their own password,
# a user who is not a member must be refused, and an action the rule does not name (the time zone) must still
# need root, whose password nobody has. The users exist for this check only.
polkit_check() { # USER PASSWORD ACTION: the exit code of pkcheck and the identity the agent asked for
  (sleep 3; echo "$2") | runuser -u "$1" -- script -qec "sh -c 'pkttyagent --process \$\$ & sleep 1; timeout 20 pkcheck -u --action-id org.freedesktop.$3 --process \$\$; echo \"RESULT \$?\"'" /dev/null 2>&1 | tr -d '\r'
}
if ! { useradd -m -G sudo nyraadmin && useradd -m nyraplain && printf 'nyraadmin:pw-admin\nnyraplain:pw-plain\n' | chpasswd; }; then
  fail "cannot make the polkit test users"
fi
for a in locale1.set-locale locale1.set-keyboard; do
  out="$(polkit_check nyraadmin pw-admin "$a")"; echo "$a, admin: $(echo "$out" | tr '\n' ' ')"
  echo "$out" | grep -qx 'RESULT 0' || fail "$a: a member of sudo is not let through with their password"
  out="$(polkit_check nyraplain pw-plain "$a")"; echo "$a, not an admin: $(echo "$out" | tr '\n' ' ')"
  echo "$out" | grep -qx 'RESULT 0' && fail "$a: a user who is not a member of sudo is let through"
done
out="$(polkit_check nyraadmin pw-admin timedate1.set-timezone)"; echo "timedate1.set-timezone, admin: $(echo "$out" | tr '\n' ' ')"
echo "$out" | grep -qx 'RESULT 0' && fail "timedate1.set-timezone: a member of sudo is let through, the rule is wider than the two actions"
userdel -r nyraadmin 2>/dev/null; userdel -r nyraplain 2>/dev/null

# Nothing of the input methods runs by default.
! pgrep -x fcitx5 >/dev/null || fail "fcitx5 runs without being asked for"

[ "$bad" = 0 ] || exit 1
echo "all languages present"
