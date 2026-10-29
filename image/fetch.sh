#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# The "fetch" stage of the Containerfile (docs/IMAGE.md): resolves the desktop's packages against what
# nyra-base already has and downloads them, so that the stage FROM the base only runs dpkg, which the
# base keeps (it has no apt and no dpkg database).
#   fetch.sh SNAPSHOT   with the inputs in /in, the base image's root at /base, the results in /out
# /in: apt-snapshot.sh, manifest.json (the base's package list, mkosi's JSON) and desktop.list.
# /out: status (a dpkg status file that lists the base's packages as installed), debs/ (the packages
# to install, checked by apt against the snapshot's signed index), plan (apt's order: "unpack DEB..."
# and "configure PACKAGE..." lines) and manifest.json (the packages the desktop adds, mkosi's format).
# The build fails if apt would remove or change a base package, if the base's list does not match
# the snapshot, or if a new package would write a file that the base already has: dpkg cannot see the
# base's files (no database), so it would silently replace them (nyra-base's own zlib or su, say).
set -eu

snapshot="$1"
/in/apt-snapshot.sh "$snapshot"
apt-get install -y -q jq >/dev/null
mkdir -p /out/debs

# The base's packages as dpkg would list them: their records from the snapshot's index, installed.
jq -r '.packages[] | "\(.name)=\(.version)"' /in/manifest.json > /tmp/base.list
n="$(wc -l < /tmp/base.list)"
xargs apt-cache show < /tmp/base.list |
  grep -Ev '^(Filename|Size|MD5sum|SHA256|Description-md5): ' |
  awk '/^Package: / { print; print "Status: install ok installed"; next } { print }' > /out/status
[ "$(grep -c '^Package: ' /out/status)" = "$n" ] || { echo "fetch.sh: the snapshot does not have every package of the base ($n)" >&2; exit 1; }

packages="$(grep -Ev '^(#|$)' /in/desktop.list | awk '{ print $1 }')"
apt() {
  # shellcheck disable=SC2086 # one word per package
  apt-get -q -o Dir::State::status=/out/status -o Dir::Cache::archives=/out/debs/ -o Debug::NoLocking=1 "$@" $packages
}
apt -s install > /tmp/sim
if grep -E '^(Remv|Purg) ' /tmp/sim || grep -E '^Inst [^ ]+ \[' /tmp/sim; then
  echo "fetch.sh: apt would remove or change a package of the base (above)" >&2
  exit 1
fi
apt -y --download-only install >/dev/null
rm -f /out/debs/lock && rm -rf /out/debs/partial

# One deb per package: "name file" for the plan, and no file that the base has already.
for f in /out/debs/*.deb; do echo "$(dpkg-deb -f "$f" Package) ${f##*/}"; done > /tmp/debs
[ "$(wc -l < /tmp/debs)" = "$(grep -c '^Inst ' /tmp/sim)" ] || { echo "fetch.sh: not one deb per package" >&2; exit 1; }
for f in /out/debs/*.deb; do
  dpkg-deb --fsys-tarfile "$f" | tar -t | grep -v '/$' | sed 's|^\./||' | while IFS= read -r p; do
    if [ -e "/base/$p" ] || [ -L "/base/$p" ]; then echo "${f##*/} /$p"; fi
  done
done > /tmp/clash
if [ -s /tmp/clash ]; then
  echo "fetch.sh: these packages would replace files of the base:" >&2
  cat /tmp/clash >&2
  exit 1
fi

# apt's order, consecutive steps of one kind in one line.
awk 'NR == FNR { deb[$1] = $2; next }
  /^Inst / { a = "unpack"; w = deb[$2]; if (w == "") { print "fetch.sh: no deb for " $2 > "/dev/stderr"; exit 1 } }
  /^Conf / { a = "configure"; w = $2 }
  /^(Inst|Conf) / { if (a != last) { if (line) print line; line = a; last = a }; line = line " " w }
  END { if (line) print line }' /tmp/debs /tmp/sim > /out/plan

# The desktop's packages for the SBOM, as mkosi lists the base's.
sed -n 's/^Inst \([^ ]*\) (\([^ ]*\) [^[]*\[\([^]]*\)\]).*$/\1 \2 \3/p' /tmp/sim |
  jq -R -s --slurpfile m /in/manifest.json '{manifest_version: 1, config: $m[0].config,
    packages: [split("\n")[] | select(. != "") | split(" ") | {type: "deb", name: .[0], version: .[1], architecture: .[2]}]}' \
  > /out/manifest.json
[ "$(jq '.packages | length' /out/manifest.json)" = "$(grep -c '^Inst ' /tmp/sim)" ]
echo "fetch.sh: $(grep -c '^Inst ' /tmp/sim) packages to add to the base's $n"
