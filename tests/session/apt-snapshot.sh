#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Points apt at Debian unstable on snapshot.debian.org at the date below and runs apt-get update.
# Used by both images of the session test (desktop.Containerfile, tools.Containerfile); run.sh and CI
# rebuild them when this file changes.
# The source is http (the base image has no ca-certificates) and snapshots are old, so apt checks
# signatures but not freshness (Check-Valid-Until: no). To stop a network attacker from serving an
# older, correctly signed InRelease, this fails unless the verified InRelease is dated within 12 h
# before the snapshot date and its Suite is unstable (the same check as nyra-base's CI tools image).
set -eu
# The snapshot date of nyra-base's mkosi/mkosi.conf (Snapshot=).
snapshot=20261016T023245Z
rm -f /etc/apt/sources.list.d/* /etc/apt/sources.list
printf 'Types: deb\nURIs: http://snapshot.debian.org/archive/debian/%s/\nSuites: unstable\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\nCheck-Valid-Until: no\n' \
  "$snapshot" > /etc/apt/sources.list.d/debian.sources
printf 'Acquire::Retries "5";\nAcquire::http::Timeout "60";\nAPT::Install-Recommends "false";\n' > /etc/apt/apt.conf.d/80-nyra
apt-get update -q
inrel="/var/lib/apt/lists/snapshot.debian.org_archive_debian_${snapshot}_dists_unstable_InRelease"
suite=$(sed -n '/^Suite: /{s///p;q}' "$inrel")
[ "$suite" = unstable ] || { echo "InRelease Suite '$suite' is not unstable" >&2; exit 1; }
want=$(date -u -d "$(echo "$snapshot" | sed -E 's/^(....)(..)(..)T(..)(..)(..)Z$/\1-\2-\3T\4:\5:\6Z/')" +%s)
rel=$(sed -n '/^Date: /{s///p;q}' "$inrel")
got=$(date -u -d "$rel" +%s)
[ "$got" -le "$want" ] && [ "$got" -gt $((want - 43200)) ] || { echo "InRelease Date '$rel' is not within 12 h before snapshot $snapshot" >&2; exit 1; }
