#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# The install step of the Containerfile (docs/IMAGE.md), in the stage FROM nyra-base: installs the
# packages the "fetch" stage downloaded, in apt's order (/fetch/plan), with Debian's dpkg, which the
# base keeps at /usr/lib/nyra/dpkg (its /usr/bin/dpkg refuses to install, by design, on machines).
# The dpkg database exists only for this step: /var is a tmpfs here, as the base has none (its
# packages are listed in the SBOM instead), so it starts from /fetch/status, the base's packages
# marked installed. Nothing is downloaded and nothing is compiled.
#   sh install.sh   (as root, with the fetch stage's /out at /fetch and a tmpfs on /var)
set -eu

dpkg=/usr/lib/nyra/dpkg
export DEBIAN_FRONTEND=noninteractive
mkdir -p /var/lib/dpkg/info /var/lib/dpkg/updates /var/lib/dpkg/triggers /var/cache/debconf /var/log /var/tmp
cp /fetch/status /var/lib/dpkg/status
: > /var/lib/dpkg/available
# An empty file list for each base package (dpkg warns about every missing one, at every step). dpkg
# names it after the package, with the architecture for Multi-Arch: same packages.
awk '/^Package: / { p = $2; m = "" } /^Architecture: / { a = $2 } /^Multi-Arch: / { m = $2 }
  /^$/ && p { print (m == "same" ? p ":" a : p); p = "" } END { if (p) print (m == "same" ? p ":" a : p) }' /fetch/status | while read -r p; do : > "/var/lib/dpkg/info/$p.list"; done

# shellcheck disable=SC2086 # $words: one word per deb or package
while read -r action words; do
  case "$action" in
    unpack) (cd /fetch/debs && $dpkg --unpack $words) ;;
    configure) $dpkg --configure $words ;;
    *) echo "install.sh: unknown step '$action' in the plan" >&2; exit 1 ;;
  esac
done < /fetch/plan
$dpkg --configure --pending

# Every package of the base and of the plan installed and configured, nothing half done. (dpkg --audit
# would also list every base package, for its missing file lists and checksums.)
test -z "$(dpkg-query -W -f '${db:Status-Abbrev} ${Package}\n' | grep -v '^ii ')"
want=$(($(grep -c '^Package: ' /fetch/status) + $(ls /fetch/debs | wc -l)))
got="$(dpkg-query -W -f '${db:Status-Abbrev}\n' | grep -c '^ii ')"
[ "$got" = "$want" ] || { echo "install.sh: $got packages installed, not $want" >&2; exit 1; }

# Debian's sudo comes only as a dependency of KDE's kdesu library (libkf6su6). The base has no sudo on
# purpose (nyra-base docs/DEFAULTS.md, "su"): a setuid root program that a user's own password opens,
# beside polkit, which is the one way to approve an action. Its files go, except its licence; kdesu then
# reports that it cannot run, and nothing in the desktop uses it.
dpkg-query -L sudo | while read -r f; do
  case "$f" in /usr/share/doc/*) continue ;; esac
  if [ -f "$f" ] || [ -L "$f" ]; then rm "$f"; fi
done
rm -r /usr/libexec/sudo /etc/sudoers.d && rm -f /etc/rc?.d/[SK][0-9][0-9]sudo
for f in /usr/bin/sudo /usr/bin/sudoedit /usr/sbin/visudo /etc/sudoers /etc/pam.d/sudo; do
  if [ -e "$f" ] || [ -L "$f" ]; then echo "install.sh: $f is still there" >&2; exit 1; fi
done
echo "install.sh: $(ls /fetch/debs | wc -l) packages installed on the base"
