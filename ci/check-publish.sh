#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# What the publish jobs publish, checked against the jobs that made it (docs/RELEASE.md, "Publishing").
# Everything read here is data from artifacts: unpacked by tar, read by jq and sha256sum, never run. Every
# digest, version and commit it is compared with is a job output.
#
#   ci/check-publish.sh --signature LAYOUT IMAGE_DIGEST SIGNATURE_DIGEST
#     The signature layout of the sign job holds exactly one manifest, SIGNATURE_DIGEST, tagged as the
#     registry expects (sha256-<image digest>.sig), and its blob matches its digest.
#   ci/check-publish.sh ARCHIVE SHA256 SIGNATURE_LAYOUT IMAGE_DIGEST SIGNATURE_DIGEST VERSION REVISION PLATFORM RELEASES OUT
#     ARCHIVE (the only file in its directory) has SHA256; unpacked into the new directory OUT it is an OCI
#     layout of exactly the manifest IMAGE_DIGEST, whose signed config has the labels VERSION and REVISION
#     and the os/architecture PLATFORM; the signature layout is as above. RELEASES is nyra-updates'
#     channels/<repository>/releases.json from its main ({} before the first release): VERSION must be
#     newer than every version in it (no release goes back below one already published).
#   ci/check-publish.sh --self-test
set -euo pipefail

die() { echo "::error::check-publish: $*" >&2; exit 1; }
digest_re='^sha256:[0-9a-f]{64}$'
version_re='^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$'

# blob LAYOUT DIGEST: the path of a regular blob file of LAYOUT whose content has DIGEST.
blob() {
  local file="$1/blobs/sha256/${2#sha256:}"
  if ! [[ "$2" =~ $digest_re ]] || [ ! -f "$file" ] || [ -L "$file" ]; then die "no blob '$2' in $1"; fi
  [ "$(sha256sum < "$file" | cut -d' ' -f1)" = "${2#sha256:}" ] || die "blob $2 of $1 does not match its digest"
  echo "$file"
}

# plain_layout LAYOUT: only files and directories, and a regular index.json.
plain_layout() {
  [ -z "$(find "$1" ! -type f ! -type d -print -quit)" ] || die "$1 holds more than files and directories"
  if [ ! -f "$1/index.json" ] || [ -L "$1/index.json" ]; then die "$1/index.json is not a regular file"; fi
}

check_signature() {
  local layout="$1" image="$2" signature="$3" tag
  [[ "$image" =~ $digest_re ]] || die "no image digest from sign ('$image')"
  [[ "$signature" =~ $digest_re ]] || die "no signature digest from sign ('$signature')"
  tag="${image/:/-}.sig"
  plain_layout "$layout"
  [ "$(jq -er --arg ref "$tag" '.manifests | select(length == 1) | .[0]
        | select(.annotations["org.opencontainers.image.ref.name"] == $ref) | .digest' "$layout/index.json")" = "$signature" ] ||
    die "the signature layout is not exactly the manifest $signature tagged $tag"
  blob "$layout" "$signature" >/dev/null
}

# newer VERSION RELEASES: VERSION is above every version RELEASES (a JSON object version -> digest) lists.
newer() {
  local version="$1" releases="$2" v
  [[ "$version" =~ $version_re ]] || die "not a release version: '$version'"
  jq -e 'type == "object"' "$releases" >/dev/null || die "$releases is not a JSON object"
  while IFS= read -r v; do
    [[ "$v" =~ $version_re ]] || die "releases.json lists '$v', which is not a version"
    [ "$v" != "$version" ] || die "$version is already released"
    [ "$(printf '%s\n%s\n' "$v" "$version" | sort -V | tail -n 1)" = "$version" ] ||
      die "$version is older than the released $v: a release never goes back below a published version"
  done < <(jq -r 'keys[]' "$releases")
}

if [ "${1:-}" = --self-test ]; then
  d="$(mktemp -d)"
  trap 'rm -rf "$d"' EXIT
  ok() { ( "$@" ) >/dev/null 2>&1 || { echo "self-test: refused: $*"; exit 1; }; }
  no() { if ( "$@" ) >/dev/null 2>&1; then echo "self-test: accepted: $*"; exit 1; fi; }
  echo '{}' > "$d/none.json"
  echo '{"2026.11.9": "sha256:x", "2026.10.40": "sha256:y"}' > "$d/some.json"
  echo '{"latest": "sha256:x"}' > "$d/bad.json"
  echo '[]' > "$d/list.json"
  ok newer 2026.11.1 "$d/none.json"
  ok newer 2026.11.10 "$d/some.json"
  ok newer 2026.12.1 "$d/some.json"
  no newer 2026.11.9 "$d/some.json"
  no newer 2026.11.8 "$d/some.json"
  no newer 2026.10.41 "$d/some.json"
  no newer 2026.11 "$d/none.json"
  no newer 2026.11.10 "$d/bad.json"
  no newer 2026.11.10 "$d/list.json"
  # A signature layout as the sign job exports it.
  image="sha256:$(printf '%064d' 1)"
  s="$d/sig"
  mkdir -p "$s/blobs/sha256"
  echo '{"schemaVersion":2}' > "$d/m"
  sd="sha256:$(sha256sum < "$d/m" | cut -d' ' -f1)"
  cp "$d/m" "$s/blobs/sha256/${sd#sha256:}"
  jq -n --arg d "$sd" --arg t "${image/:/-}.sig" \
    '{manifests: [{digest: $d, annotations: {"org.opencontainers.image.ref.name": $t}}]}' > "$s/index.json"
  ok check_signature "$s" "$image" "$sd"
  no check_signature "$s" "sha256:$(printf '%064d' 2)" "$sd"
  no check_signature "$s" "$image" "sha256:$(printf '%064d' 3)"
  no check_signature "$s" "$image" ""
  ln -s /etc/passwd "$s/link"
  no check_signature "$s" "$image" "$sd"
  rm "$s/link"
  echo changed > "$s/blobs/sha256/${sd#sha256:}"
  no check_signature "$s" "$image" "$sd"
  echo "check-publish.sh self-test: ok"
  exit 0
fi

if [ "${1:-}" = --signature ]; then
  [ $# = 4 ] || die "usage: ci/check-publish.sh --signature LAYOUT IMAGE_DIGEST SIGNATURE_DIGEST"
  check_signature "$2" "$3" "$4"
  echo "check-publish: the signature layout is $4, for $3"
  exit 0
fi

[ $# = 10 ] || die "usage: ci/check-publish.sh ARCHIVE SHA256 SIGNATURE_LAYOUT IMAGE_DIGEST SIGNATURE_DIGEST VERSION REVISION PLATFORM RELEASES OUT"
archive="$1" sha="$2" signature="$3" image_digest="$4" signature_digest="$5" version="$6" revision="$7" platform="$8" releases="$9" out="${10}"
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || die "not a commit: '$revision'"
case "$platform" in linux/amd64 | linux/arm64) ;; *) die "not a platform of the desktop: '$platform'" ;; esac

# The version first: nothing else matters for a version that may not be published.
newer "$version" "$releases"

# a. The archive is the file release-image made, alone in its directory.
[[ "$sha" =~ ^[0-9a-f]{64}$ ]] || die "no sha256 from release-image ('$sha')"
[ -z "$(find "$(dirname "$archive")" -mindepth 1 -maxdepth 1 ! -name "$(basename "$archive")" -print -quit)" ] ||
  die "$(dirname "$archive") holds more than $(basename "$archive")"
[ "$(sha256sum < "$archive" | cut -d' ' -f1)" = "$sha" ] || die "$archive is not the file release-image made"

# b. podman's oci-archive is an OCI layout in a tar: unpacked into a new directory, as no one.
mkdir "$out"
tar -x --no-same-owner --no-same-permissions -f "$archive" -C "$out"
plain_layout "$out"

# c. The image layout is the one manifest sign signed; d. the signature layout is sign's.
[ "$(jq -er '.manifests | select(length == 1) | .[0].digest' "$out/index.json")" = "$image_digest" ] ||
  die "the image layout is not exactly the manifest $image_digest that sign signed"
manifest="$(blob "$out" "$image_digest")"
check_signature "$signature" "$image_digest" "$signature_digest"

# e. The signed config says which version, commit and architecture this is.
config="$(blob "$out" "$(jq -er '.config.digest' "$manifest")")"
[ "$(jq -r '.config.Labels["org.opencontainers.image.version"] // ""' "$config")" = "$version" ] ||
  die "the image's version label is not $version"
[ "$(jq -r '.config.Labels["org.opencontainers.image.revision"] // ""' "$config")" = "$revision" ] ||
  die "the image's revision label is not $revision"
[ "$(jq -r '"\(.os)/\(.architecture)"' "$config")" = "$platform" ] || die "the image is not $platform"
echo "check-publish: $version, $revision, $platform, image $image_digest, signature $signature_digest; newer than every published version"
