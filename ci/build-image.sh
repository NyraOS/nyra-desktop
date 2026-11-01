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
# No release key, no KMS, nothing published: a release of the desktop is a later step.
#   ci/build-image.sh BASE_SRC BASE_IMAGE TAG WORK [podman build options for the final image...]
# BASE_IMAGE is the verified pull of the pinned base (an image ID, ci/pull-base.sh). SOURCE_DATE_EPOCH
# is the base's snapshot date (ci/pull-base.sh checks that the base was built at it).
set -euo pipefail

base_src="$1" base="$2" tag="$3" work="$4"
shift 4
snapshot="$(sed -n 's/^Snapshot=//p' "$base_src/mkosi/mkosi.conf")"
[[ "$snapshot" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || { echo "build-image.sh: no snapshot in $base_src/mkosi/mkosi.conf" >&2; exit 1; }
build() {
  sudo podman build --timestamp "$SOURCE_DATE_EPOCH" --build-arg BASE="$base" --build-arg SNAPSHOT="$snapshot" "$@" -f Containerfile .
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

# 3. The PCR policy key of this run: its public half goes into the UKI (.pcrpkey).
key="$(mktemp -d)"
trap 'rm -rf "$key"' EXIT
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$key/pcr.key" 2>/dev/null
openssl pkey -in "$key/pcr.key" -pubout -out "$work/pcr/tpm2-pcr-public-key.pem"
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

# 5. Only the local sealed image is used: --pull=never.
sudo podman build --pull=never --timestamp "$SOURCE_DATE_EPOCH" --build-arg BASE="$base" \
  --build-arg SEALED="$tag-sealed" --build-context uki="$work/signed" -t "$tag" "$@" -f Containerfile .
