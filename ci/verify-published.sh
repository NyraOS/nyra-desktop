#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only (verify-published, verify-published-arm64; docs/RELEASE.md): the pull a machine makes of a
# published desktop release, updates.nyraos.com/REPOSITORY:VERSION, with the signature policy of the
# pinned base checkout BASE (the policy the image ships: the sign job checks they are the same file).
# Adapted from nyra-base's tools/install/verified-pull.sh, which takes the base's repositories only.
#   ci/verify-published.sh BASE REPOSITORY VERSION DIGEST REVISION STORAGE
# The image must be accepted by the policy, by tag and by digest; the tag must name DIGEST (anyone who
# can write to the registry could point a tag at an older, validly signed image); the signed config must
# say the repository's architecture, VERSION and REVISION (the commit of this run).
# Run as root, with skopeo, podman and jq. Exit codes: 0 verified; 2 pulled, but a check failed (no retry
# can change that); 1 anything else (the caller may retry: the registry's cache may still be cold).
set -euo pipefail

die() { echo "verify-published: $*" >&2; exit 1; }
refuse() { echo "verify-published: $*" >&2; exit 2; }

[ $# = 6 ] || die "usage: ci/verify-published.sh BASE REPOSITORY VERSION DIGEST REVISION STORAGE"
base="$1" name="$2" version="$3" digest="$4" revision="$5" storage="$6"
case "$name" in
  nyra-desktop) platform=linux/amd64 ;;
  nyra-desktop-arm64) platform=linux/arm64 ;;
  *) die "not a desktop repository (nyra-desktop, nyra-desktop-arm64): $name" ;;
esac
[[ "$version" =~ ^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]] || die "not a version: $version"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "not a sha256 digest: $digest"
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || die "not a commit: $revision"
[ -z "${CONTAINERS_POLICY_JSON:-}" ] || die "CONTAINERS_POLICY_JSON is set"
repo=updates.nyraos.com/$name
files="$(cd "$base" && pwd)/files"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# The trust roots are the checkout's: the policy's /usr/lib/nyra/ paths point into BASE/files.
policy="$tmp/policy.json"
jq --arg root "$files" '(.. | strings | select(startswith("/usr/lib/nyra/"))) |= $root + .' \
  "$files/usr/lib/nyra/containers/policy.json" > "$policy" || die "cannot read the policy"
jq -e --arg root "$files/" '[.. | strings | select(startswith("/"))] | length > 0 and all(startswith($root))' \
  "$policy" > /dev/null || die "the policy points outside $files"
# The scope of this repository must exist: without it the host scope (the base's signer) would apply.
jq -e --arg scope "$repo" '.transports.docker[$scope] | length == 1' "$policy" > /dev/null ||
  die "the policy has no scope $repo"

pull() {
  skopeo --policy "$policy" --registries.d "$files/usr/lib/nyra/containers/registries.d" \
    copy --preserve-digests --digestfile "$tmp/digest" "docker://$1" "containers-storage:[overlay@$storage]$1" >&2
}
pull "$repo:$version" || die "cannot pull $repo:$version"
[ "$(cat "$tmp/digest")" = "$digest" ] || refuse "$repo:$version is $(cat "$tmp/digest"), not $digest"
id="$(podman --root "$storage" image inspect --format '{{.Id}}' "$repo:$version")" || die "cannot find the pulled image"
[ "$(podman --root "$storage" image inspect --format '{{.Os}}/{{.Architecture}}' "$id")" = "$platform" ] ||
  refuse "$repo:$version is not $platform"
label() { podman --root "$storage" image inspect --format "{{index .Labels \"org.opencontainers.image.$1\"}}" "$id"; }
[ "$(label version)" = "$version" ] || refuse "the image's version label is not $version"
[ "$(label revision)" = "$revision" ] || refuse "the image's revision label is not $revision"

# Machines switch by digest: the same policy must accept that reference.
pull "$repo@$digest" || die "cannot pull $repo@$digest"
[ "$(cat "$tmp/digest")" = "$digest" ] || refuse "$repo@$digest was stored as another digest"
echo "verify-published: $repo:$version is $digest, accepted by the policy, $platform, revision $revision" >&2
