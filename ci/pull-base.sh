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
# The runner's Ubuntu skopeo is built without Fulcio support and cannot check the keyless signature, so
# the pull runs in Debian 13 (as nyra-base's own CI does), into a scratch storage; the verified image is
# then loaded into the root storage as an OCI archive, which keeps its ID and creation time.
debian=mirror.gcr.io/library/debian:trixie-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f
scratch="$(sudo mktemp -d /mnt/pull-base.XXXXXX)"
trap 'sudo rm -rf "$scratch"' EXIT
rc=0
id="$(sudo podman run --rm --privileged -v "$(cd "$base_src" && pwd):/src:ro" -v "$scratch:/storage" "$debian" bash -c '
  set -euo pipefail
  apt-get -o Acquire::Retries=5 -o Acquire::http::Timeout=30 update -qq >&2
  DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=5 -o Acquire::http::Timeout=30 install -y -qq --no-install-recommends \
    skopeo podman jq git ca-certificates >&2
  id="$(/src/tools/install/verified-pull.sh "$@")"
  podman --root /storage/root save --format oci-archive -o /storage/base.tar "$id" >&2
  echo "$id"
' verify nyra-base "$version" "$digest" /storage/root)" || rc=$?
[ "$rc" = 0 ] || { echo "pull-base.sh: the verified pull failed ($rc)" >&2; exit 1; }
sudo podman load -q -i "$scratch/base.tar" >&2
sudo podman image inspect -f '{{.Id}}' "$id" >/dev/null || { echo "pull-base.sh: the loaded base has another ID than $id" >&2; exit 1; }

snapshot="$(sed -n 's/^Snapshot=//p' "$base_src/mkosi/mkosi.conf")"
[[ "$snapshot" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})Z$ ]] ||
  { echo "pull-base.sh: no snapshot in $base_src/mkosi/mkosi.conf" >&2; exit 1; }
m=("${BASH_REMATCH[@]}")
want="${m[1]}-${m[2]}-${m[3]}T${m[4]}:${m[5]}:${m[6]}Z"
created="$(sudo podman image inspect -f '{{.Created.UTC.Format "2006-01-02T15:04:05Z"}}' "$id")"
[ "$created" = "$want" ] || { echo "pull-base.sh: the base was built at $created, not at its snapshot $want" >&2; exit 1; }
echo "pull-base.sh: nyra-base $version ($digest, commit $commit), snapshot $snapshot" >&2
echo "$id"
