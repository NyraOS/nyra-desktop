#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The desktop image's SBOM and vulnerability scan (docs/IMAGE.md, "SBOM"), with nyra-base's own scanner
# (tools/sbom/sbom.py of BASE_SRC, the commit of the pinned base): the same CycloneDX 1.6 SBOM and the
# same report, for the whole image. The package list is the base's (base/manifest.json) plus the
# desktop's (DESKTOP_MANIFEST, from ci/build-image.sh); the Rust crates are those of the Cargo.lock
# files the base ships in /usr/share/doc. The exceptions are the desktop's (sbom/mitigations.toml), never
# the base's. Report mode: a blocking finding is a warning, as in the base's builds before a release;
# a scan that cannot run still fails.
#   ci/sbom.sh BASE_SRC IMAGE DESKTOP_MANIFEST OUT_DIR
set -euo pipefail

base_src="$1" image="$2" desktop="$3" out="$4"
mkdir -p "$out"
jq -s '{manifest_version: 1, config: .[0].config, packages: (.[0].packages + .[1].packages)}' \
  base/manifest.json "$desktop" > "$out/nyra-desktop.manifest.json"
dupes="$(jq -r '.packages[].name' "$out/nyra-desktop.manifest.json" | sort | uniq -d)"
[ -z "$dupes" ] || { echo "sbom.sh: packages in both the base and the desktop: $dupes" >&2; exit 1; }

cid="$(sudo podman create -q "$image")"
for p in bootc nyra-zlib ntpd-rs pam-totp nyra-editor; do
  sudo podman cp "$cid:/usr/share/doc/$p/Cargo.lock" "$out/$p.Cargo.lock"
done
sudo podman rm -f "$cid" >/dev/null
sudo chown -R "$(id -u):$(id -g)" "$out"

# sbom.py reads its exceptions from its own directory: the desktop's file takes the base's place there.
cp sbom/mitigations.toml "$base_src/tools/sbom/mitigations.toml"
BOOTC_REF="$(sed -n 's/^  BOOTC_REF: //p' "$base_src/.github/workflows/image.yml")"
BOOTC_COMMIT="$(sed -n 's/^  BOOTC_COMMIT: //p' "$base_src/.github/workflows/image.yml")"
export BOOTC_REF BOOTC_COMMIT
venv="$(mktemp -d)"
trap 'rm -rf "$venv"' EXIT
python3 -m venv "$venv"
"$venv/bin/pip" install -q --no-deps --require-hashes -r "$base_src/tools/sbom/requirements.txt"
"$venv/bin/python" "$base_src/tools/sbom/sbom.py" --vulnerabilities=report "$out/nyra-desktop.manifest.json" \
  "$out/bootc.Cargo.lock" "$out/nyra-desktop.cdx.json" "$out/nyra-zlib.Cargo.lock" "$out/ntpd-rs.Cargo.lock" \
  "$out/pam-totp.Cargo.lock" "$out/nyra-editor.Cargo.lock" > "$out/nyra-desktop.vulnerabilities.md"

# The scanner names the image nyra-base: the SBOM is the desktop's, on the pinned base.
base="$(sed -n 's/^version=//p' base/pin) $(sed -n 's/^digest=//p' base/pin)"
jq --arg base "$base" '.metadata.component |= (.name = "nyra-desktop" | ."bom-ref" = "nyra-desktop"
    | .description = "Nyra OS desktop image: nyra-base \($base) with KDE Plasma, " + (.description | sub("^[^:]*: "; "")))' \
  "$out/nyra-desktop.cdx.json" > "$out/sbom.tmp" && mv "$out/sbom.tmp" "$out/nyra-desktop.cdx.json"
