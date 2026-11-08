# Releasing the desktop image

This is how the desktop image is signed for release and published to `updates.nyraos.com`. It is **off**
until the repository variable `DESKTOP_RELEASE` is `on`: with the variable unset, every run builds and
boot-tests the image as before (`docs/IMAGE.md`), with keys made for the run, and nothing here runs. The
image signature and publishing need a second variable, `PUBLISH_ENABLED`, `on` as well.

**None of it can run today.** Every switch is the owner's (see "What the owner sets"): the Google Cloud setup
script, the repository variables, the environments `sign` and `publish` with their tokens, the ruleset on
`main`. Two code changes come first as well: `publish` and `publish-arm64` need `UPDATES_PIN` (empty until
the nyra-updates pull request that allows the desktop repositories is merged), and the sign jobs need a
pinned base whose signature policy trusts the desktop's signer (`base/pin`, `base/pin-arm64`).

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

Only the jobs `release-sign` and `release-sign-arm64` of `image.yml` may reach the KMS. They have
exactly `contents: read` and `id-token: write` and **no environment**. The identity provider in Google
Cloud accepts a token only for this repository (by ID), `refs/heads/main`, a push or manual run,
a GitHub-hosted runner, the caller `workflow_ref` and the file `job_workflow_ref` both `image.yml`, and the
`sub` of a job without an environment. Both signing jobs run on GitHub-hosted x86_64 runners and match the
same conditions; nothing in the provider is specific to an architecture. Pull requests, forks, tags, other workflows and other repositories of
the organization get nothing.

Only `sign` and `sign-arm64` may reach the image signer, `nyra-desktop-image-signer`, with the same
permissions and **exactly the environment `sign`**: its provider (in its own pool, `github-desktop-sign`,
which holds no other provider) checks the same conditions and the environment `sign` instead of the `sub`.
The KMS provider's `sub` check keeps those two jobs away from the KMS, and the image signer has no role on
any key. The base's signature policy trusts this signer only for `nyra-desktop` and `nyra-desktop-arm64`,
so it can never vouch for a base image, and the base's signer never for a desktop one.

`ci/check-credential-jobs.py` enforces the repository's side of it, on every workflow, and runs as the
required check **`credential-jobs`** (`.github/workflows/credentials.yml`) on every pull request:

- `id-token` (a job's, the workflow's, `write-all`, or permissions that are not a mapping) only in those
  two jobs and in `sign` and `sign-arm64`, each with exactly `contents: read` and `id-token: write`;
- `sign` and `sign-arm64` have exactly `environment: sign`; `publish` and `publish-arm64` have exactly
  `environment: publish` and `permissions: {contents: read}` (so never an id-token); the verify jobs have no
  environment and exactly `contents: read`; no other job may use `sign` or `publish`, and no environment
  name has an expression in it;
- a job that calls a reusable workflow has exactly `permissions: {contents: read}` and passes no
  `secrets:`; `secrets: inherit` is never allowed;
- `image.yml` has no `workflow_call` trigger: nothing may call the workflow that holds the signing jobs.

The same workflow runs the pinned base's own lints of these jobs, `ci/check-sign-jobs.py` and
`ci/check-publish-job.py` (from the commit in `base/pin`): they also refuse the R2 and Cloudflare secrets
anywhere but the publish jobs.

The lint catches mistakes. Against a deliberate change the controls are review of `.github/` and `ci/`
(CODEOWNERS) and the ruleset on `main` below: both providers trust whatever runs on `main`.

## The image signature

In a release run with `PUBLISH_ENABLED` `on`, after `boot` passed on the release image:

1. `sign` (environment `sign`, exactly `contents: read` and `id-token: write`) loads the release image
   (checked against `release-image`'s hash) into a throwaway registry as `updates.nyraos.com/nyra-desktop`,
   and refuses to sign unless:
   - the image follows `nyra-desktop` with this run's version and a `version_floor` not above it
     (`ci/check-image-repository.sh`);
   - the signature policy the image ships is the pinned base's file, unchanged, and its scope
     `updates.nyraos.com/nyra-desktop` trusts exactly this signer (`GCP_SIGNER_SA`), keyless, with
     `matchRepository` (`ci/check-signer-policy.sh`). Without that scope the host scope applies, which
     trusts only the base's signer: a machine running the image would refuse its next update. nyra-base
     has these scopes from its "per-repository image signers" change on; the pins must be at least there;
   - the pinned base's UKI release gate passes on the image's `/boot`.

   It then signs the manifest with cosign (the base's version and hash) as `nyra-desktop-image-signer`,
   a keyless Fulcio identity that only the provider of the environment `sign` can reach and that has no
   other role. No code of the image runs in the job. The signature is uploaded as an OCI layout.
2. `verify-signature` (no token, no environment) puts the image and the signature into a throwaway registry
   and runs the image's own `skopeo` with the policy the image ships (`ci/test-signature.sh`): the image is
   accepted under `nyra-desktop`; an unsigned image, the signature moved onto another image, and the image
   with its signature copied to `nyra-desktop-arm64`, `nyra-base` or `nyra-base-arm64` are all refused.

If `GCP_WIF_PROVIDER` or `GCP_SIGNER_SA` is not set, `sign` fails (red, not skipped).

## Publishing

3. `publish` (environment `publish`: `main` only, the owner approves every run) holds the R2 and KV
   tokens and has exactly `contents: read`, so it can never sign. It runs no code of the image and reads
   no value from the artifacts that it does not check against a job output (`ci/check-publish.sh`): the
   archive's hash, one manifest equal to the digest `sign` signed, the signature layout `sign` exported,
   and in the signed config the version, the commit of the run and `linux/amd64`. It then runs nyra-updates'
   `registry/scripts/publish-image.sh` at `UPDATES_PIN` (fetched without a token, and refused unless it is
   on nyra-updates' `main`): the signature first, then the version tag. The script never re-points a
   released version.
4. `verify-published` (no secret, no environment) pulls `updates.nyraos.com/nyra-desktop:<version>` the way
   a machine does, with the pinned base's policy, by tag and by digest, and checks the digest, the
   architecture and both labels (`ci/verify-published.sh`). Red here is an incident to look into, not a
   reason to publish again.

The channel sheets are not touched: putting a release on a channel is a reviewed pull request in
nyra-updates (`channels/nyra-desktop/releases.json`, then the channel). The summary of `publish` prints the
`releases.json` line.

**`UPDATES_PIN` is set to `a28d8fed29611109e01dd255a58c34bfe6903a8b`** in `image.yml`, in both jobs. It is the
merge commit of the nyra-updates pull request that adds `nyra-desktop` and `nyra-desktop-arm64` to the repository
allow-list (`publish-image.sh` and the registry's `REPOSITORIES`). Without it, `publish` and `publish-arm64` fail
before anything is read. It moves only by
a reviewed pull request that reads the nyra-updates diff from the old pin to the new one, the same value in
both jobs.

### Rollback and the version floor

- **No release below a published one.** `ci/check-publish.sh` refuses a version that is not newer than every
  version in `channels/<repository>/releases.json` on nyra-updates' `main`, and one already listed. The run
  number only grows, so this only stops a mistake (an old run re-run, a changed version rule).
- **The floor.** `sign` refuses an image whose `version_floor` is above its own version, and nyra-updated
  refuses any target below the floor, signed retractions included (`docs/IMAGE.md`, "Identity").
- **A machine that switched from the base.** Its rollback deployment is a base version, counted in the
  base's build numbers, so usually higher than the desktop's. nyra-updated (nyra-base,
  `updated/daemon/src`) never compares that number with a desktop sheet: an update must be newer than the
  **booted** version (`check_newer`); the rollback deployment is only compared with the floor, to decide
  whether "go back to the previous version" may offer it (`offered_rollback`); retractions, failed versions
  and versions gone back from are matched by digest, not version; and the last accepted sheet is kept per
  `repository:channel`, so the desktop's sheets start their own sequence. Going back to the base deployment
  stays possible only when the base version is at least the desktop's `version_floor` (otherwise the floor refuses it), and the base deployment then follows the base's channel again.

## arm64 publishing

`sign-arm64`, `verify-signature-arm64`, `publish-arm64` and `verify-published-arm64` are the same jobs for
the repository `nyra-desktop-arm64` and `linux/arm64`, by the same switches, environments, signer and pin,
after `boot-arm64` passed on the arm64 release image. `sign-arm64` runs on x86_64 (it only reads the arm64
image); `verify-signature-arm64` and `verify-published-arm64` run on arm64, so the image's own `skopeo` runs
natively. `publish-arm64` has its own concurrency group. The two architectures do not wait for each other.

## What the owner sets

Nothing here runs until all of it is set. The values of the four Google Cloud variables are printed by the
Google Cloud setup script (it creates `nyra-desktop-release-signer`, `nyra-desktop-image-signer`, the provider
`github/nyra-desktop` and the pool `github-desktop-sign` with its one provider `nyra-desktop-sign`).

In this order:

1. **A ruleset on `main`**, before the script runs: pull request required, the required checks (including
   `credential-jobs`), no force push, no deletion, an empty bypass list (administrators included). The
   providers trust `main`, so `main` must be protected.
2. **Actions settings**: the default workflow token read-only, "Allow GitHub Actions to create and approve
   pull requests" off, approval for workflow runs from all outside contributors.
3. **The Google Cloud setup script**, then the repository variables (Settings, Secrets and variables,
   Actions, Variables):

   | Variable | Value |
   |---|---|
   | `KMS_WIF_PROVIDER` | `projects/<project number>/locations/global/workloadIdentityPools/github/providers/nyra-desktop` |
   | `KMS_SIGNER_SA` | `nyra-desktop-release-signer@<project>.iam.gserviceaccount.com` |
   | `GCP_WIF_PROVIDER` | `projects/<project number>/locations/global/workloadIdentityPools/github-desktop-sign/providers/nyra-desktop-sign` |
   | `GCP_SIGNER_SA` | `nyra-desktop-image-signer@<project>.iam.gserviceaccount.com` (the address the base's policy names for the desktop scopes) |

4. **Environment `sign`** (Settings, Environments): deployment branches: the selected branch `main` only,
   no tag rule; no secrets; no reviewer.
5. **Environment `publish`**: deployment branches: `main` only, no tag rule; required reviewer: the owner;
   "Allow administrators to bypass" off; no wait timer. Its secrets, and nowhere else (never as repository
   secrets):

   | Secret | What |
   |---|---|
   | `R2_ACCESS_KEY_ID` | a new R2 token, Object Read & Write on the bucket `nyra-images` only |
   | `R2_SECRET_ACCESS_KEY` | the same token's secret |
   | `CLOUDFLARE_KV_TOKEN` | a new token, Workers KV Storage Edit on the account, nothing else |

6. **`DESKTOP_RELEASE`** = `on`: release signing with the KMS (nothing is published yet).
7. **`PUBLISH_ENABLED`** = `on`, last: only after `UPDATES_PIN` is set in `image.yml`, the base pins trust the
   desktop's signer, and steps 1 to 5 exist.

Each publish run then waits for the owner's approval of the environment `publish`. To stop publishing, unset
`PUBLISH_ENABLED`; to stop all release signing, unset `DESKTOP_RELEASE`.

## What is not here yet

The installer and an ISO of the desktop: a machine gets the desktop by switching from the base (as root,
from the recovery console), not by installing it.
