#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Before the sign jobs sign (docs/RELEASE.md, "The image signature"): the signature policy the image ships
# must trust SIGNER for the image's own repository, or a machine running it would refuse its next update
# (and a machine switching to it would refuse it). The policy comes from the pinned base, unchanged: the
# image's file must be BASE's files/usr/lib/nyra/containers/policy.json byte for byte, so that
# verify-published (which reads BASE's file) checks the same policy.
# The scope updates.nyraos.com/REPOSITORY must exist (otherwise the host scope, the base's signer,
# applies) and hold exactly one requirement: sigstoreSigned by the Fulcio identity SIGNER, issuer Google,
# with matchRepository. Reads the image with podman create and cp: nothing from the image runs.
#   ci/check-signer-policy.sh IMAGE BASE REPOSITORY SIGNER
#   ci/check-signer-policy.sh --self-test
set -euo pipefail

refuse() { echo "::error::check-signer-policy: $*" >&2; exit 1; }

# check_scope POLICY REPOSITORY SIGNER
check_scope() {
  jq -e --arg scope "updates.nyraos.com/$2" --arg signer "$3" '
    .transports.docker[$scope]
    | length == 1 and (.[0] | .type == "sigstoreSigned"
        and .fulcio.subjectEmail == $signer
        and .fulcio.oidcIssuer == "https://accounts.google.com"
        and .signedIdentity == {"type": "matchRepository"})' "$1" >/dev/null ||
    refuse "the policy does not trust exactly $3 for updates.nyraos.com/$2 (scope: $(jq -c --arg s "updates.nyraos.com/$2" '.transports.docker[$s]' "$1")). The pinned base must have the desktop's scope (base/pin, base/pin-arm64)."
}

if [ "${1:-}" = --self-test ]; then
  d="$(mktemp -d)"
  trap 'rm -rf "$d"' EXIT
  signer=nyra-desktop-image-signer@example.iam.gserviceaccount.com
  entry() { printf '[{"type":"sigstoreSigned","fulcio":{"caPath":"/x","oidcIssuer":"%s","subjectEmail":"%s"},"rekorPublicKeyPath":"/y","signedIdentity":{"type":"%s"}}]' "$1" "$2" "$3"; }
  good="$(entry https://accounts.google.com "$signer" matchRepository)"
  base="$(entry https://accounts.google.com nyra-image-signer@example.iam.gserviceaccount.com matchRepository)"
  t() { # WANTED_EXIT_CODE SCOPE_JSON REPOSITORY WHAT
    local rc=0
    jq -n --argjson s "$2" --argjson b "$base" '{default: [{type: "insecureAcceptAnything"}],
      transports: {docker: {"updates.nyraos.com": $b, "updates.nyraos.com/nyra-desktop-arm64": $s}}}' > "$d/p.json"
    ( check_scope "$d/p.json" "$3" "$signer" ) >/dev/null 2>&1 || rc=$?
    [ "$rc" = "$1" ] || { echo "self-test: $4"; exit 1; }
  }
  t 0 "$good" nyra-desktop-arm64 "refused the good scope"
  t 1 "$good" nyra-desktop "accepted a repository without a scope (the host scope would apply)"
  t 1 "$base" nyra-desktop-arm64 "accepted the base's signer"
  t 1 "$(entry https://accounts.google.com "$signer" matchRepoDigestOrExact)" nyra-desktop-arm64 "accepted another signedIdentity"
  t 1 "$(entry https://token.actions.githubusercontent.com "$signer" matchRepository)" nyra-desktop-arm64 "accepted another issuer"
  t 1 "$(jq -c '. + .' <<<"$good")" nyra-desktop-arm64 "accepted two requirements"
  t 1 '[{"type":"insecureAcceptAnything"}]' nyra-desktop-arm64 "accepted insecureAcceptAnything"
  t 1 '[]' nyra-desktop-arm64 "accepted an empty scope"
  echo "check-signer-policy.sh self-test: ok"
  exit 0
fi

[ $# = 4 ] || refuse "usage: ci/check-signer-policy.sh IMAGE BASE REPOSITORY SIGNER"
image="$1" base="$2" repository="$3" signer="$4"
case "$repository" in
  nyra-desktop) platform=linux/amd64 ;;
  nyra-desktop-arm64) platform=linux/arm64 ;;
  *) refuse "not a desktop repository (nyra-desktop, nyra-desktop-arm64): $repository" ;;
esac
[[ "$signer" =~ ^[a-z0-9-]+@[a-z0-9-]+\.iam\.gserviceaccount\.com$ ]] || refuse "not a service account: '$signer'"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cid="$(sudo podman create -q --platform "$platform" "$image")"
sudo podman cp "$cid:/usr/lib/nyra/containers/policy.json" "$tmp/policy.json"
sudo podman rm -f "$cid" >/dev/null
sudo chown "$(id -u):$(id -g)" "$tmp/policy.json"
cmp -s "$tmp/policy.json" "$base/files/usr/lib/nyra/containers/policy.json" ||
  refuse "the image's policy.json is not the pinned base's"
check_scope "$tmp/policy.json" "$repository" "$signer"
echo "check-signer-policy: the image's policy trusts $signer for updates.nyraos.com/$repository"
