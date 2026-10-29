#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Pulls the nyra-base image that base/pin names and checks it (docs/IMAGE.md, "The pinned base"), into
# the root podman storage the build uses. Prints the image ID, and only that, on stdout.
#   ci/pull-base.sh BASE_SRC
# base/pin is exactly the four lines of nyra-base's release file: version, digest, commit and
# architecture (amd64). BASE_SRC must be a git checkout of nyra-base at that commit. The pull is
# nyra-base's own tools/install/verified-pull.sh from that checkout, the one the installer uses: the
# image must carry nyra-base's keyless release signature (the signature policy and trust roots of
# that commit), have the pinned manifest digest, and its version and revision labels must be the pinned
# version and commit. Then the base must have been built at the snapshot of that commit's mkosi.conf
# (its creation time is SOURCE_DATE_EPOCH, the snapshot date), the snapshot the desktop's packages
# come from.
set -euo pipefail

base_src="$1"
pin=base/pin
version="$(sed -n 's/^version=//p' "$pin")"
digest="$(sed -n 's/^digest=//p' "$pin")"
commit="$(sed -n 's/^commit=//p' "$pin")"
printf 'version=%s\ndigest=%s\ncommit=%s\narchitecture=amd64\n' "$version" "$digest" "$commit" | cmp -s - "$pin" ||
  { echo "pull-base.sh: $pin is not exactly the lines version, digest, commit and architecture=amd64" >&2; exit 1; }
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "pull-base.sh: $pin: not a commit: $commit" >&2; exit 1; }
[ "$(git -C "$base_src" rev-parse HEAD)" = "$commit" ] || { echo "pull-base.sh: $base_src is not at $commit" >&2; exit 1; }

# verified-pull.sh checks the version and the digest itself, and refuses anything else.
id="$(sudo "$base_src/tools/install/verified-pull.sh" nyra-base "$version" "$digest" /var/lib/containers/storage)"

snapshot="$(sed -n 's/^Snapshot=//p' "$base_src/mkosi/mkosi.conf")"
[[ "$snapshot" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})Z$ ]] ||
  { echo "pull-base.sh: no snapshot in $base_src/mkosi/mkosi.conf" >&2; exit 1; }
m=("${BASH_REMATCH[@]}")
want="${m[1]}-${m[2]}-${m[3]}T${m[4]}:${m[5]}:${m[6]}Z"
created="$(sudo podman image inspect -f '{{.Created.UTC.Format "2006-01-02T15:04:05Z"}}' "$id")"
[ "$created" = "$want" ] || { echo "pull-base.sh: the base was built at $created, not at its snapshot $want" >&2; exit 1; }
echo "pull-base.sh: nyra-base $version ($digest, commit $commit), snapshot $snapshot" >&2
echo "$id"
