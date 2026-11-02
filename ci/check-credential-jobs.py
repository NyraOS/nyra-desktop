#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Which jobs may hold a signing credential (docs/RELEASE.md, "Who can sign"), checked on every
workflow in .github/workflows. Adapted from nyra-base's ci/check-credential-jobs.py. The identity
providers of the cloud project check `workflow_ref`, which for a called workflow names the caller, and
`job_workflow_ref`, which names the file the job is defined in, so a job of any workflow that image.yml
calls (or that calls it) could otherwise get a KMS token. Refused:
- `id-token: write` (a job's, the workflow's, `write-all`, or permissions that are not a mapping)
  anywhere but the jobs `release-sign`, `release-sign-arm64` (the KMS) and `sign`, `sign-arm64` (the keyless
  image signature) of image.yml, and those four jobs must have exactly `contents: read` and
  `id-token: write`;
- an environment on the release-sign jobs (the KMS provider accepts only jobs without one); anything but
  exactly `environment: sign` on the sign jobs (the keyless provider accepts only that one);
- anything but exactly `environment: publish` and `permissions: {contents: read}` on image.yml's `publish`
  and `publish-arm64` (the environment that holds the R2 and KV tokens never gets an id-token);
- an environment, or other permissions than exactly `contents: read`, on the verify jobs
  (`verify-signature`, `verify-published` and their arm64 twins);
- an environment named `sign` or `publish` (any case, spaces ignored) on any other job, and an environment
  name with an expression in it anywhere;
- a job that calls a reusable workflow (`uses:`) without exactly `permissions: {contents: read}`
  (missing permissions inherit the workflow's, so they count as wrong), with any `secrets:` key,
  and `secrets: inherit` anywhere;
- a `workflow_call` trigger in image.yml: nothing may call the workflow that holds the signing jobs.
This guards against mistakes, not against whoever can change the workflows.

  check-credential-jobs.py [REPO]   (the current directory by default)
  check-credential-jobs.py --self-test
"""
import copy
import glob
import os
import sys

import yaml

KMS_SIGN = {("image.yml", "release-sign"), ("image.yml", "release-sign-arm64")}
KEYLESS_SIGN = {("image.yml", "sign"), ("image.yml", "sign-arm64")}
CAN_SIGN = KMS_SIGN | KEYLESS_SIGN
SIGN_PERMISSIONS = {"contents": "read", "id-token": "write"}
PUBLISH = {("image.yml", "publish"), ("image.yml", "publish-arm64")}
VERIFY = {("image.yml", job) for job in (
    "verify-signature", "verify-signature-arm64", "verify-published", "verify-published-arm64")}
# Environments that hold credentials or are matched by an identity provider, and the jobs (by file and
# name) that must use exactly that one, written as a plain name.
IN_ENVIRONMENT = {"sign": KEYLESS_SIGN, "publish": PUBLISH}
GUARDED_ENVIRONMENTS = set(IN_ENVIRONMENT)
READ_ONLY = {"contents": "read"}


def gives_token(permissions):
    # write-all, read-all and the like are not mappings: counted as granting it.
    return permissions is not None and (
        not isinstance(permissions, dict) or str(permissions.get("id-token", "none")).lower() != "none")


def environment_name(job):
    env = job.get("environment")
    name = env.get("name") if isinstance(env, dict) else env
    return str(name).strip().lower() if name is not None else None


def triggers(workflow):
    # PyYAML reads the key `on` as the boolean True.
    on = workflow.get("on", workflow.get(True))
    if isinstance(on, dict):
        return {str(k) for k in on}
    if isinstance(on, list):
        return {str(k) for k in on}
    return {str(on)} if on is not None else set()


def check_workflow(name, workflow):
    found = []
    if gives_token(workflow.get("permissions")):
        found.append(f"{name}: the workflow-level permissions must be a mapping without id-token")
    if name == "image.yml" and "workflow_call" in triggers(workflow):
        found.append(f"{name}: must not be callable (no `workflow_call`): it holds the signing jobs")
    for job_name, job in (workflow.get("jobs") or {}).items():
        where = f"{name} job {job_name}"
        key = (name, job_name)
        if key in CAN_SIGN:
            if job.get("permissions") != SIGN_PERMISSIONS:
                found.append(f"{where}: must have exactly `permissions: {{contents: read, id-token: write}}`")
        elif gives_token(job.get("permissions")):
            found.append(f"{where}: only image.yml's release-sign, release-sign-arm64, sign and sign-arm64 "
                         "may have id-token: write")
        if key in KMS_SIGN and "environment" in job:
            found.append(f"{where}: must have no environment (the KMS provider accepts only jobs without one)")
        if (key in PUBLISH or key in VERIFY) and job.get("permissions") != READ_ONLY:
            found.append(f"{where}: must have exactly `permissions: {{contents: read}}` (never an id-token)")
        if key in VERIFY and "environment" in job:
            found.append(f"{where}: must have no environment")
        for wanted, jobs in IN_ENVIRONMENT.items():
            if key in jobs and job.get("environment") != wanted:
                found.append(f"{where}: must have exactly `environment: {wanted}`")
        environment = environment_name(job)
        if environment is not None and "${{" in environment:
            found.append(f"{where}: the environment name has an expression in it")
        elif environment in GUARDED_ENVIRONMENTS and key not in IN_ENVIRONMENT[environment]:
            found.append(f"{where}: only {sorted(j for _, j in IN_ENVIRONMENT[environment])} may use the "
                         f"environment `{environment}`")
        if "uses" in job and job.get("permissions") != READ_ONLY:
            found.append(f"{where}: a job calling a reusable workflow must have exactly "
                         "`permissions: {contents: read}`")
        if "uses" in job and "secrets" in job:
            found.append(f"{where}: a job calling a reusable workflow must not pass `secrets:`")
        if str(job.get("secrets", "")).strip().lower() == "inherit":
            found.append(f"{where}: `secrets: inherit` is not allowed")
    return found


def check(repo):
    found = []
    paths = sorted(glob.glob(os.path.join(repo, ".github/workflows/*.y*ml")))
    if not any(os.path.basename(p) == "image.yml" for p in paths):
        found.append("no .github/workflows/image.yml: the check would pass on an empty set")
    for path in paths:
        with open(path) as f:
            found += check_workflow(os.path.basename(path), yaml.safe_load(f))
    return found


def self_test():
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, "../.github/workflows/image.yml")) as f:
        good = yaml.safe_load(f)
    assert check_workflow("image.yml", good) == [], check_workflow("image.yml", good)
    assert "release-sign" in good["jobs"], "the signing job is not in image.yml"
    assert "release-sign-arm64" in good["jobs"], "the arm64 signing job is not in image.yml"
    for _, name in sorted(KEYLESS_SIGN | PUBLISH | VERIFY):
        assert name in good["jobs"], f"{name} is not in image.yml"
    assert check(os.path.join(here, "..")) == [], check(os.path.join(here, ".."))

    def broken(change, name="image.yml"):
        workflow = copy.deepcopy(good)
        change(workflow)
        return check_workflow(name, workflow)

    def job(name, key, value):
        return lambda w: w["jobs"].__setitem__(name, {**w["jobs"][name], key: value})

    def call(w):
        w["jobs"]["caller"] = {"uses": "./.github/workflows/x.yml", "permissions": {"contents": "read"}}

    def call_with(key, value):
        def change(w):
            call(w)
            w["jobs"]["caller"][key] = value
        return change

    def call_without_permissions(w):
        call(w)
        del w["jobs"]["caller"]["permissions"]

    assert broken(call) == [], "refused: a read-only reusable workflow call"
    both = {"contents": "read", "id-token": "write"}
    cases = {
        "id-token in build": job("build", "permissions", both),
        "id-token in boot": job("boot", "permissions", both),
        "write-all in build": job("build", "permissions", "write-all"),
        "read-all in build": job("build", "permissions", "read-all"),
        "id-token in release-image": job("release-image", "permissions", both),
        "id-token in a new job": lambda w: w["jobs"].__setitem__("sign-x", {"permissions": both}),
        # The keyless sign jobs: exactly environment `sign`, exactly contents: read and id-token: write.
        "no environment on sign": lambda w: w["jobs"]["sign"].pop("environment"),
        "environment publish on sign": job("sign", "environment", "publish"),
        "environment Sign on sign": job("sign", "environment", " Sign "),
        "environment mapping on sign": job("sign", "environment", {"name": "sign", "url": "x"}),
        "no environment on sign-arm64": lambda w: w["jobs"]["sign-arm64"].pop("environment"),
        "environment build on sign-arm64": job("sign-arm64", "environment", "build"),
        "no id-token in sign": job("sign", "permissions", {"contents": "read"}),
        "more in sign": job("sign", "permissions", {**both, "packages": "write"}),
        "write-all in sign-arm64": job("sign-arm64", "permissions", "write-all"),
        # The publish jobs: exactly environment `publish`, exactly contents: read, never an id-token.
        "id-token in publish": job("publish", "permissions", both),
        "id-token in publish-arm64": job("publish-arm64", "permissions", both),
        "write-all in publish": job("publish", "permissions", "write-all"),
        "no permissions in publish": lambda w: w["jobs"]["publish"].pop("permissions"),
        "more in publish-arm64": job("publish-arm64", "permissions", {"contents": "read", "actions": "write"}),
        "no environment on publish": lambda w: w["jobs"]["publish"].pop("environment"),
        "environment sign on publish-arm64": job("publish-arm64", "environment", "sign"),
        # The verify jobs: no environment, exactly contents: read.
        "environment publish on verify-published": job("verify-published", "environment", "publish"),
        "environment sign on verify-signature": job("verify-signature", "environment", "sign"),
        "environment on verify-signature-arm64": job("verify-signature-arm64", "environment", "build"),
        "id-token in verify-published-arm64": job("verify-published-arm64", "permissions", both),
        "no permissions in verify-signature": lambda w: w["jobs"]["verify-signature"].pop("permissions"),
        # The environments of the sign and publish jobs on any other job.
        "environment sign in release-image": job("release-image", "environment", "sign"),
        "environment publish in boot-arm64": job("boot-arm64", "environment", "publish"),
        "environment publish in a new job": lambda w: w["jobs"].__setitem__("publish-x", {"environment": "publish"}),
        "no id-token in release-sign": job("release-sign", "permissions", {"contents": "read"}),
        "more in release-sign": job("release-sign", "permissions", {**both, "packages": "write"}),
        "write-all in release-sign": job("release-sign", "permissions", "write-all"),
        "id-token in release-image-arm64": job("release-image-arm64", "permissions", both),
        "id-token in build-arm64": job("build-arm64", "permissions", both),
        "id-token in boot-arm64": job("boot-arm64", "permissions", both),
        "no id-token in release-sign-arm64": job("release-sign-arm64", "permissions", {"contents": "read"}),
        "more in release-sign-arm64": job("release-sign-arm64", "permissions", {**both, "packages": "write"}),
        "write-all in release-sign-arm64": job("release-sign-arm64", "permissions", "write-all"),
        "environment on release-sign-arm64": job("release-sign-arm64", "environment", "build"),
        "environment sign on release-sign-arm64": job("release-sign-arm64", "environment", "sign"),
        "environment on release-sign": job("release-sign", "environment", "build"),
        "environment sign on release-sign": job("release-sign", "environment", "sign"),
        "environment sign in build": job("build", "environment", "sign"),
        "environment Sign in boot": job("boot", "environment", " Sign "),
        "environment name: publish in build": job("build", "environment", {"name": "PUBLISH"}),
        "environment expression in build": job("build", "environment", {"name": "${{ vars.ENV }}"}),
        "id-token at workflow level": lambda w: w.__setitem__("permissions", {"id-token": "write"}),
        "write-all at workflow level": lambda w: w.__setitem__("permissions", "write-all"),
        "workflow_call in image.yml": lambda w: w[True].__setitem__("workflow_call", None),
        "call without permissions": call_without_permissions,
        "call with write permissions": call_with("permissions", {"contents": "write"}),
        "call with extra permissions": call_with("permissions", {"contents": "read", "actions": "read"}),
        "call with id-token": call_with("permissions", both),
        "call with write-all": call_with("permissions", "write-all"),
        "call inheriting secrets": call_with("secrets", "inherit"),
        "call passing secrets": call_with("secrets", {"TOKEN": "${{ secrets.TOKEN }}"}),
        "call with empty secrets": call_with("secrets", None),
        "build inheriting secrets": job("build", "secrets", "inherit"),
    }
    for what, change in cases.items():
        assert broken(change), f"accepted: {what}"
    # The exemption is by file and job name: the same jobs in another workflow are refused.
    signer = {"permissions": both}
    for other in ("other.yml", "session.yml"):
        for job_name in ("release-sign", "release-sign-arm64", "sign", "sign-arm64"):
            assert check_workflow(other, {"jobs": {job_name: signer}}), f"accepted: {job_name} in {other}"
            assert check_workflow(other, {"jobs": {job_name: {**signer, "environment": "sign"}}}), \
                f"accepted: {job_name} with environment sign in {other}"
        for job_name in ("publish", "publish-arm64"):
            publisher = {"permissions": {"contents": "read"}, "environment": "publish"}
            assert check_workflow(other, {"jobs": {job_name: publisher}}), f"accepted: {job_name} in {other}"
    # Another workflow may not call image.yml with more than contents: read, nor with a token.
    assert check_workflow("other.yml", {"jobs": {"image": {
        "uses": "./.github/workflows/image.yml", "permissions": both}}}), "accepted: a call with id-token"
    # A workflow that is only `on: workflow_call` is still a workflow_call trigger in image.yml.
    assert check_workflow("image.yml", {"on": ["workflow_call"], "jobs": {}}), "accepted: workflow_call as a list"
    print("check-credential-jobs.py self-test: ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        sys.exit(0)
    problems = check(sys.argv[1] if len(sys.argv) > 1 else ".")
    for p in problems:
        print(f"::error::{p}")
    sys.exit(1 if problems else 0)
