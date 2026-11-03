# Releasing the desktop image

This is how the desktop image is signed for release. It is **off** until the repository variable
`DESKTOP_RELEASE` is `on`: with the variable unset, every run builds and boot-tests the image as before
(`docs/IMAGE.md`), with keys made for the run, and nothing here runs. Publishing the image and the signature
of the image for the registry are not part of this step.

## What is signed, and with which keys

A run is a **release run** when it is `image.yml` on `main`, started by a push or a manual run, and
`DESKTOP_RELEASE` is `on`. In a release run:

| What | Key | Where |
|---|---|---|
| The PCR 11 policy of the UKI's main profile (what lets a TPM-bound disk unlock) | Cloud KMS key `pcr-policy-1` | `release-sign` |
| The UKI, for Secure Boot (certificate `nyra.crt`, enrolled as a MOK on every Nyra machine) | Cloud KMS key `uki` | `release-sign` |

They are **the same two keys and the same certificate as nyra-base's**: a machine trusts the Nyra certificate
and the policy key, not a repository, so a new key would mean a new MOK enrollment on every machine. A
desktop UKI therefore boots on every Nyra machine, and what can sign it is as serious as what can sign the
base's. The caller in the KMS is its own service account (`nyra-desktop-release-signer`, with the roles
`signerVerifier` on exactly these two keys and nothing on the others), so it has its own audit trail and
can be revoked on its own. Every run of `release-sign` or `release-sign-arm64` counts as a release when revoking, whether or not
the tests pass afterwards.

The jobs of a release run, in `image.yml`:

1. `build` makes the UKI with the pinned base's committed PCR policy key and leaves it **unsigned**
   (`NYRA_RELEASE=1`, `ci/build-image.sh`). The same version and `updated.conf` as in `docs/IMAGE.md`,
   "Identity", are in it. The job uploads the unsigned UKI and the sealed image it was made from (one day
   of retention) and reports their sha256.
2. `release-sign` (the only job with `id-token: write`) checks both against those hashes, authenticates to
   Google Cloud, has `pcr-policy-1` sign the PCR policy, joins the signature into the UKI with the sealed
   image's own `ukify` (no network, no environment, three fresh directories mounted, never the workspace),
   and has `uki` sign the result. It runs **only the pinned base's tools** (`.nyra-base`, a checkout of the
   commit in `base/pin`, which must be on nyra-base's `main`): `kms-pkcs11.sh`, `pcr-policy.py sign-kms`
   and `sign-uki.sh`, with the base's committed certificate and public key. It does not check out this
   repository, so no code of the desktop runs next to the credentials. The signed UKI is uploaded for one
   day.
3. `release-image` (no token) builds the final image with that UKI (`ci/final-image.sh`), requires that its
   layers are those of the image `build` checked (setuid files, added files, composefs digest, SBOM) except
   the one with the UKI, checks the repository and version (`ci/check-image-repository.sh`), and runs the
   pinned base's UKI release gate. It uploads the release image for one day.
4. `boot` boots **that** image with Secure Boot, enrolling the committed `nyra.crt`. The run fails if
   `release-image` did not succeed.

If `KMS_WIF_PROVIDER` or `KMS_SIGNER_SA` is not set, `release-sign` fails (red, not skipped). There is no
switch inside the run: the variable `DESKTOP_RELEASE` is the switch, and the other way back is to unset it.

## arm64

The arm64 image has its own release jobs in `image.yml`, in release mode only and by the same rule (a push
or manual run on `main` with `DESKTOP_RELEASE` `on`; there is no separate variable). They are the jobs above
on the arm64 build, with the same keys, certificate, service account and variables, for the repository
`nyra-desktop-arm64` and the version rule of `docs/IMAGE.md`, "Identity" (it is the run's number, so the
x86_64 and arm64 images of one run have the same version):

- `build-arm64` makes the unsigned UKI and the sealed image (`NYRA_RELEASE=1`) and reports their sha256.
- `release-sign-arm64` (the second job with `id-token: write`, exactly `contents: read` and `id-token:
  write`, no environment) checks out the pinned **arm64** base (`base/pin-arm64`, whose commit must be on
  nyra-base's `main`), checks both files against `build-arm64`'s hashes, authenticates, and signs as
  `release-sign` does with the pinned base's tools only, without checking out this repository. It runs on
  x86_64, because Google's KMS library has no arm64 build, so the join of the PCR signature into the UKI
  runs the sealed arm64 image's `ukify` under Ubuntu's `qemu-user-static` (installed and registered before
  the authentication step; the pinned base's `join-pcrsig.sh` refuses any other emulator). The emulator is
  not a boundary, the container is: no network, no environment, three fresh directories, never the
  workspace.
- `release-image-arm64` (no token, an arm64 runner) builds the final image with the signed UKI, requires the
  same layers as `build-arm64`'s image except the one with the UKI, checks that the image is `linux/arm64`
  and follows `nyra-desktop-arm64` with its version, and runs the pinned base's UKI release gate.
- `boot-arm64` boots **that** image, emulated (about an hour and a half), instead of `build-arm64`'s: in
  release mode there is still one boot, and the run fails if `release-image-arm64` did not succeed.

An arm64 failure does not hold back the x86_64 release, and the x86_64 jobs need none of these.

## Who can sign

Only the jobs `release-sign` and `release-sign-arm64` of `image.yml` may have `id-token: write`, with
exactly `contents: read` and `id-token: write` and **no environment**. The identity provider in Google
Cloud accepts a token only for this repository (by ID), `refs/heads/main`, a push or manual run,
a GitHub-hosted runner, the caller `workflow_ref` and the file `job_workflow_ref` both `image.yml`, and the
`sub` of a job without an environment. Both signing jobs run on GitHub-hosted x86_64 runners and match the
same conditions; nothing in the provider is specific to an architecture. Pull requests, forks, tags, other workflows and other repositories of
the organization get nothing.

`ci/check-credential-jobs.py` enforces the repository's side of it, on every workflow, and runs as the
required check **`credential-jobs`** (`.github/workflows/credentials.yml`) on every pull request:

- `id-token` (a job's, the workflow's, `write-all`, or permissions that are not a mapping) only in those
  two jobs;
- no job may use an environment named `sign` or `publish`, and no expression in an environment name (the
  jobs that need them come with the image signature and publishing);
- a job that calls a reusable workflow has exactly `permissions: {contents: read}` and passes no
  `secrets:`; `secrets: inherit` is never allowed;
- `image.yml` has no `workflow_call` trigger: nothing may call the workflow that holds the signing jobs.

The lint catches mistakes. Against a deliberate change the controls are review of `.github/` and `ci/`
(CODEOWNERS) and the ruleset on `main` below: the KMS provider trusts whatever runs on `main`.

## What the owner sets

The values are printed by the Google Cloud setup script.

Repository variables (Settings, Secrets and variables, Actions, Variables):

| Variable | Value |
|---|---|
| `KMS_WIF_PROVIDER` | the provider `github/nyra-desktop` of the pool `github` |
| `KMS_SIGNER_SA` | `nyra-desktop-release-signer@<project>.iam.gserviceaccount.com` |
| `DESKTOP_RELEASE` | `on`, set last |

(`GCP_WIF_PROVIDER` and `GCP_SIGNER_SA` are printed too: they belong to the image signature and are used
by the next step, not by this one.)

No secrets and no environments are used by this step. Before the script runs, and before `DESKTOP_RELEASE`
is set:

- a ruleset on `main`: pull request required, the required checks (including `credential-jobs`), no force
  push, no deletion, an empty bypass list (administrators included). The KMS provider trusts `main`, so
  `main` must be protected;
- Actions settings: the default workflow token read-only, "Allow GitHub Actions to create and approve pull
  requests" off, approval for workflow runs from outside contributors.

## What is not here yet

The keyless signature of the image for the registry, the `publish` environment and the publishing jobs
are the next step. Nothing of this repository is published by the release jobs, x86_64 or arm64.
