#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds the desktop image with its own sealed UKI (docs/IMAGE.md), the way nyra-base builds its
# own on a pull request, with nyra-base's own tools from BASE_SRC, a checkout of the commit that
# built the pinned base (base/pin):
#   1. the root filesystem (Containerfile target "sealed"): the base plus the desktop's packages,
#      committed;
#   2. the kernel and initramfs: the base's, from its UKI (target "kernel", image/kernel.py);
#   3. the UKI from that committed image, with nyra-base's ci/ukify.sh: bootc container ukify puts
#      the image's composefs digest on the command line, plus the base's recovery and reset profiles;
#   4. the UKI signed outside the image build, as nyra-base signs it for a pull request: its PCR 11
#      policy (pcr-policy.py), then the whole file for Secure Boot (sign-uki.sh, the only script that
#      signs a UKI, after uki-check.py and pcr-policy.py check), with two keys made for this run only
#      and deleted right after signing. Only the UKI certificate and the policy's public key stay in
#      WORK, for the tests;
#   5. the final image: the committed root filesystem plus the signed UKI in /boot/EFI/Linux.
# WORK also gets desktop.manifest.json, the packages the desktop adds (for ci/sbom.sh).
# With NYRA_RELEASE=1 (a release, docs/RELEASE.md) steps 3 and 4 happen outside this script: the UKI
# gets the committed PCR policy key of the pinned base instead of a new one, the single-file check runs on
# it, and the final image is made with the unsigned UKI (WORK/unsigned); the release-sign job signs it in
# the KMS with the pinned base's tools, and the release-image job makes the image again with the signed
# UKI (ci/final-image.sh). Unset (the default: pull requests, runs without DESKTOP_RELEASE, local
# builds) it is as described above, and no key outside this run is used.
# The image's identity (docs/IMAGE.md, "Identity") comes from the environment: VERSION (year.month.run, as in
# the base; dev without it) and REPOSITORY (nyra-desktop, the default, or nyra-desktop-arm64). Both go into
# the sealed image, so before the UKI is made.
#   [NYRA_RELEASE=1] [VERSION=...] [REPOSITORY=...] ci/build-image.sh BASE_SRC BASE_IMAGE TAG WORK [podman build options for the final image...]
# On an arm64 machine the image is the arm64 one: the base's package list is base/manifest-arm64.json
# (the same Containerfile, the same steps, natively; docs/IMAGE.md, "arm64").
# BASE_IMAGE is the verified pull of the pinned base (an image ID, ci/pull-base.sh). SOURCE_DATE_EPOCH
# is the base's snapshot date (ci/pull-base.sh checks that the base was built at it).
set -euo pipefail

base_src="$1" base="$2" tag="$3" work="$4"
shift 4
case "${NYRA_RELEASE:-}" in ""|1) ;; *) echo "build-image.sh: NYRA_RELEASE must be unset or 1, not '$NYRA_RELEASE'" >&2; exit 1 ;; esac
snapshot="$(sed -n 's/^Snapshot=//p' "$base_src/mkosi/mkosi.conf")"
[[ "$snapshot" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || { echo "build-image.sh: no snapshot in $base_src/mkosi/mkosi.conf" >&2; exit 1; }
manifest=manifest.json
if [ "$(uname -m)" = aarch64 ]; then manifest="manifest-arm64.json"; fi
build() {
  sudo podman build --timestamp "$SOURCE_DATE_EPOCH" --build-arg BASE="$base" --build-arg SNAPSHOT="$snapshot" \
    --build-arg NYRA_VERSION="${VERSION:-dev}" --build-arg NYRA_REPOSITORY="${REPOSITORY:-nyra-desktop}" \
    --build-arg MANIFEST="$manifest" "$@" -f Containerfile .
}

# 1 and 2. The final stage is not built here; its "uki" context is given anyway (empty), so that
# nothing tries to resolve it as an image name.
mkdir -p "$work/none" "$work/pcr" "$work/unsigned" "$work/policy"
build --build-context uki="$work/none" --target sealed -t "$tag-sealed"
build --build-context uki="$work/none" --target kernel -t "$tag-kernel"
# The packages the desktop added (image/fetch.sh), for the SBOM: the fetch stage is built already.
build --build-context uki="$work/none" --target fetch -t "$tag-fetch"
cid="$(sudo podman create -q "$tag-fetch")"
sudo podman cp "$cid:/out/manifest.json" "$work/desktop.manifest.json"
sudo podman rm -f "$cid" >/dev/null
cid="$(sudo podman create -q "$tag-kernel")"
sudo podman cp "$cid:/kernel" "$work/kernel"
sudo podman rm -f "$cid" >/dev/null

# 3. The PCR policy key: a release uses the pinned base's committed one (its private half signs in the
# KMS, outside this script); otherwise one made for this run, deleted right after signing. Its public half
# goes into the UKI (.pcrpkey).
key="$(mktemp -d)"
trap 'rm -rf "$key"' EXIT
if [ "${NYRA_RELEASE:-}" = 1 ]; then
  cp "$base_src/files/usr/lib/nyra/secureboot/tpm2-pcr-public-key.pem" "$work/pcr/"
else
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$key/pcr.key" 2>/dev/null
  openssl pkey -in "$key/pcr.key" -pubout -out "$work/pcr/tpm2-pcr-public-key.pem"
fi
sudo podman run --rm --network none --tmpfs /tmp --tmpfs /var/tmp \
  --mount "type=image,source=$tag-sealed,target=/target" \
  -v "$work/kernel:/kernel:ro" -v "$work/pcr:/pcr:ro" -v "$work/unsigned:/out" -v "$base_src/ci/ukify.sh:/ukify.sh:ro" \
  "$tag-sealed" sh /ukify.sh
sudo chown -R "$(id -u):$(id -g)" "$work"
files=("$work"/unsigned/*)
if [ "${#files[@]}" != 1 ] || [[ "${files[0]}" != *.efi ]]; then
  echo "build-image.sh: expected exactly one UKI to sign, found: ${files[*]}" >&2
  exit 1
fi
f="${files[0]}"
python3 -I "$base_src/tools/signing/uki-check.py" "$f" "$base_src/ci/uki-cmdline.txt"

if [ "${NYRA_RELEASE:-}" = 1 ]; then
  # 4 (release). Nothing is signed here: the final image carries the unsigned UKI, for the checks that
  # do not depend on the signature. The signed one comes from release-sign.
  ci/final-image.sh "$tag-sealed" "$work/unsigned" "$tag" "$@"
  exit 0
fi

# 4. The PCR 11 policy (the main profile's enter-initrd phase only), joined into the UKI with the
# image's own ukify (no key in that container), then the Secure Boot signature.
python3 -I "$base_src/tools/signing/pcr-policy.py" sign "$f" "$key/pcr.key" > "$work/pcr/pcrsig.json"
sudo podman run --rm --network none --tmpfs /tmp --tmpfs /var/tmp -v "$work/unsigned:/in:ro" \
  -v "$work/pcr:/pcr:ro" -v "$work/policy:/out" "$tag-sealed" \
  ukify build --hwids '' --join-pcrsig "/in/${f##*/}" --pcrsig @/pcr/pcrsig.json --output "/out/${f##*/}"
sudo chown -R "$(id -u):$(id -g)" "$work/policy"
openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=Nyra Desktop CI per-run UKI key" \
  -keyout "$key/uki.key" -out "$work/uki.crt" 2>/dev/null
PCR_PUBKEY="$work/pcr/tpm2-pcr-public-key.pem" "$base_src/tools/signing/sign-uki.sh" "$work/policy" "$work/signed" \
  --key "$key/uki.key" --cert "$work/uki.crt"
rm -rf "$key"

# 5. The final image (ci/final-image.sh, the one place that builds it).
ci/final-image.sh "$tag-sealed" "$work/signed" "$tag" "$@"
