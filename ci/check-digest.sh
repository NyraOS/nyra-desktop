#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The UKI's command line pins the composefs digest of the root filesystem (docs/IMAGE.md, "UKI"); the
# boot checks only that a digest of the right form is there. This computes the digest of the built
# image (bootc, as ukify does) and fails unless every command line of the UKI in the image (one per
# profile) carries exactly that digest: a UKI made for another root filesystem, or a change to the
# image after the UKI was made, boots into "no such composefs" instead of passing the build.
#   ci/check-digest.sh IMAGE
set -euo pipefail

image="$1"
# bootc keeps its scratch repository in /var/tmp; /boot is left out of the digest (bootc empties it).
want="$(sudo podman run --rm --network none --tmpfs /tmp --tmpfs /var/tmp \
  --mount "type=image,source=$image,target=/target" "$image" bootc container compute-composefs-digest /target)"
[[ "$want" =~ ^[0-9a-f]{128}$ ]] || { echo "check-digest.sh: not a composefs digest: $want" >&2; exit 1; }

m="$(sudo podman image mount "$image")"
trap 'sudo podman image umount "$image" >/dev/null' EXIT
sudo test -x "$m/usr/bin/bootc" || { echo "check-digest.sh: $image is not mounted at $m" >&2; exit 1; }
mapfile -t efi < <(sudo find "$m/boot/EFI" -type f)
if [ "${#efi[@]}" != 1 ] || [[ "${efi[0]}" != *.efi ]]; then
  echo "check-digest.sh: expected exactly one UKI in the image, found: ${efi[*]}" >&2
  exit 1
fi
got="$(sudo python3 -I - "${efi[0]}" <<'PY'
import re, sys, pefile
pe = pefile.PE(sys.argv[1])
lines = [s.get_data().rstrip(b"\0").decode() for s in pe.sections if s.Name.rstrip(b"\0") == b".cmdline"]
if not lines:
    sys.exit("no .cmdline section")
for line in lines:
    print(" ".join(re.findall(r"(?:^| )composefs=(\S+)", line)))
PY
)"
echo "Image:  $want"
echo "UKI:    $(echo "$got" | tr '\n' ' ')"
# Every profile has exactly one composefs= and it is the image's.
if [ -z "$got" ] || [ "$(echo "$got" | grep -vcx "$want")" != 0 ]; then
  echo "check-digest.sh: the UKI's command lines do not all carry the digest of the image" >&2
  exit 1
fi
