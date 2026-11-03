#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only (verify-signature, verify-signature-arm64; docs/RELEASE.md): the image signed by this run, checked
# with the signature policy the image itself ships and the image's own skopeo (the containers/image code
# bootc and nyra-updated use on a machine). The image and its signature must already be in the throwaway
# registry of nyra-base's tools/signing/local-registry.sh (as updates.nyraos.com/REPOSITORY), and
# WORKDIR must hold that script's tiny.oci.tar. Adapted from nyra-base's tools/signing/test-policy.sh, which
# takes the base's repositories only.
#   ci/test-signature.sh IMAGE WORKDIR SIGNED_DIGEST REPOSITORY
# REPOSITORY is nyra-desktop or nyra-desktop-arm64. Checked:
# - the signed image is accepted under REPOSITORY, by digest;
# - an unsigned image under REPOSITORY is refused;
# - the signature moved onto another image is refused;
# - the image and its signature copied to the other desktop repository are refused (matchRepository);
# - copied to nyra-base or nyra-base-arm64 they are refused: those scopes trust the base's signer only,
#   so the desktop's signer can never vouch for a base image.
set -euo pipefail

[ $# = 4 ] || { echo "usage: ci/test-signature.sh IMAGE WORKDIR SIGNED_DIGEST REPOSITORY" >&2; exit 1; }
image="$1" work="$2" signed="$3" name="$4"
case "$name" in
  nyra-desktop) other=nyra-desktop-arm64 ;;
  nyra-desktop-arm64) other=nyra-desktop ;;
  *) echo "test-signature: not a desktop repository (nyra-desktop, nyra-desktop-arm64): $name" >&2; exit 1 ;;
esac
[[ "$signed" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "test-signature: not a digest: $signed" >&2; exit 1; }
repo=updates.nyraos.com/$name
sig="${signed/:/-}.sig"

t="$work/signature-test"
mkdir -p "$t"
cp "$work/tiny.oci.tar" "$t/tiny.oci.tar"
# The only test-only setting: plain HTTP for the throwaway registry.
printf '[[registry]]\nlocation = "updates.nyraos.com"\ninsecure = true\n' > "$t/99-test.conf"

# The image's skopeo, with the image's own /etc/containers (the policy and registries.d it ships).
skopeo() {
  sudo podman run --rm --network host --tmpfs /var/tmp -v "$t:/t:z" \
    -v "$t/99-test.conf:/etc/containers/registries.conf.d/99-test.conf:ro,z" "$image" skopeo "$@"
}
accepted() {
  skopeo "$@" >/dev/null
  echo "accepted as expected: skopeo $*"
}
refused() {
  local want="$1" out
  shift
  if out="$(skopeo "$@" 2>&1)"; then
    echo "::error::accepted, but must be refused: skopeo $*"
    return 1
  fi
  if ! grep -qF -- "$want" <<<"$out"; then
    printf '%s\n' "$out"
    echo "::error::refused for another reason than \"$want\": skopeo $*"
    return 1
  fi
  echo "refused as expected ($want): skopeo $*"
}
# copy_to REPOSITORY: the signed image and its signature, unchanged, under another repository.
copy_to() {
  skopeo copy --insecure-policy --remove-signatures --preserve-digests \
    "docker://$repo@$signed" "docker://updates.nyraos.com/$1:1" >/dev/null
  skopeo copy --insecure-policy "docker://$repo:$sig" "docker://updates.nyraos.com/$1:$sig" >/dev/null
}

# The shipped configuration is the one in effect.
sudo podman run --rm "$image" sh -c 'readlink /etc/containers/policy.json /etc/containers/registries.d/nyra.yaml'

# The image signed in this run is accepted.
accepted copy "docker://$repo@$signed" dir:/t/pull-signed

# An unsigned image under the same repository is refused.
skopeo copy --insecure-policy oci-archive:/t/tiny.oci.tar "docker://$repo:tiny" >/dev/null
refused "A signature was required, but no signature exists" copy "docker://$repo:tiny" dir:/t/pull

# The signature moved onto that other image is refused.
tiny="$(skopeo inspect --format '{{.Digest}}' "docker://$repo:tiny")"
skopeo copy --insecure-policy "docker://$repo:$sig" "docker://$repo:${tiny/:/-}.sig" >/dev/null
refused "does not match" copy "docker://$repo:tiny" dir:/t/pull

# The other desktop repository (the other architecture): the signature names this repository.
copy_to "$other"
refused "is not accepted" copy "docker://updates.nyraos.com/$other@$signed" dir:/t/pull

# The base's repositories: their scopes trust the base's signer, not the desktop's.
for base in nyra-base nyra-base-arm64; do
  copy_to "$base"
  refused "Source image rejected" copy "docker://updates.nyraos.com/$base@$signed" dir:/t/pull
done
echo "test-signature: $repo@$signed is accepted by the image's policy, and only there"
