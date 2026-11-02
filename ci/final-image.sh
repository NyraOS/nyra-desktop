#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The final image (step 5 of ci/build-image.sh): the last stage of the Containerfile, FROM the sealed
# image, plus the UKI of SIGNED_UKI_DIR in /boot/EFI/Linux. The one place that builds it, for
# ci/build-image.sh and for the release-image job, which makes it again with the UKI the KMS signed, so
# the two cannot differ. Every flag that reaches the image (--timestamp, the options after TAG:
# annotations and labels) is here or in the caller's options, never in a second copy.
# SOURCE_DATE_EPOCH is required. The stages before the last are not built, so the base and the packages
# are not needed.
#   SOURCE_DATE_EPOCH=... ci/final-image.sh SEALED_IMAGE SIGNED_UKI_DIR TAG [podman build options...]
set -euo pipefail

sealed="$1" signed="$2" tag="$3"
shift 3
# --pull=never: only the local sealed image is used, nothing is fetched by this build.
sudo podman build --pull=never --timestamp "$SOURCE_DATE_EPOCH" "$@" \
  --build-arg SEALED="$sealed" --build-context uki="$signed" -t "$tag" -f Containerfile .
