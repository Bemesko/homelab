# 015 — CI flow: what gates a PR, what runs at night, what is required

- **Status:** accepted
- **Date:** 2026-11-22
- **Issue:** #45 (relates to #39 branch protection, #40 pipeline library, #42 Renovate)

## Context

A PR took 8 to 14 minutes to turn green (about 9 on average), almost all of it the `e2e` job. Measured on the green `main` run 45078235481:

| Job / step | Seconds |
|---|---|
| `lint` (total) | 74 (55 installing the tools) |
| `render` (total) | 75 (56 installing the tools) |
| `e2e` (total) | 522 |
| `e2e`: install the tools | 57 |
| `e2e`: bootstrap (1st run) | 91 |
| `e2e`: idempotency (2nd run) | 46 |
| `e2e`: cluster assertions | **269** |
| `e2e`: reset | 55 |

Three things made it worse than the sum of its parts: the tools were installed three times (about a minute each), `e2e` waited for `lint` and `render` to finish (`needs`), and every push to `main` ran the whole thing again, including the "Update targetRevision" commits.

The more important question was what the `e2e` is worth. Our deploys go through ArgoCD, which follows `main`:

- A new app version that does not become Healthy stays `Progressing`, and the alerts show it. Checking every Application in the PR does not prevent that.
- Running the same check on `main` after the merge adds nothing: ArgoCD already has the new revision.
- What only the `e2e` proves is the **host bootstrap**: the Ansible roles, idempotency (`changed=0` on the second run), the reset, the ArgoCD install and root Application, and KSOPS decryption. A regression there breaks the next `make apply` against the real laptop, which is what the PR must protect.

## Decision

Three tiers.

1. **Every PR and every push to `main`: `lint` and `render`**, in parallel, with the tools cached.
2. **PRs that can affect the bootstrap: `e2e` with the `lite` profile.** `scripts/ci-changes.sh` classifies the diff in a `changes` job (no third-party action). The lite profile runs the bootstrap, the idempotency check, the minimal assertions (node Ready, `argocd`, `root` and `hello-world` Synced/Healthy, KSOPS Secret decrypted, Tailscale operator absent) and the reset. It runs in parallel with `lint` and `render`. Pushes to `main` do not run it.

   The first run of this design (PR #52) showed that cutting only the assertions was not enough: the `lite` e2e took 541 s, with the assertions at 345 s, because the `root` Application still synced every heavy app (Immich, Postgres, observability), and they competed for the runner's CPU and I/O with the three apps the profile waits for. So the profile also sets the chart value `minimal` (Ansible `apps_minimal`), and the `root` Application renders only `argocd`, `hello-world` and the Tailscale operator.
3. **`e2e-full`: every Application Healthy, Immich, Obsidian, Home Assistant, the external apps and the observability pipeline.** It runs nightly (`schedule`), on demand (`workflow_dispatch`) and on a PR that gets the `e2e-full` label. It is a canary for drift, such as a chart or image that disappeared upstream, not a merge gate.

Supporting changes:

- `.github/actions/setup-tools` wraps `scripts/setup-control-node.sh` and caches its output (`~/.local/bin`, pipx, the helm plugin and the Ansible collections), keyed on the script, `ansible/requirements.yml` and the runner image. The pins and sha256 checks are unchanged; they run on a cache miss. It is a composite action so that #40 can promote it to the shared pipeline library.
- `.github/workflows/e2e.yaml` is a reusable workflow (`profile: lite|full`), called by `ci.yaml` and `e2e-full.yaml`.
- `scripts/e2e-assert.sh [lite|full]` (default `full`).
- `make test-changed` runs pre-commit only on what the branch changed against `origin/main`, for a quick check before pushing. `make test` stays the complete local run and `make plan` still comes before `make apply`.

### Required check

Only **`ci-ok`** should be required in the branch protection (to be configured in #39, not here). It runs `if: always()` after `changes`, `lint`, `render` and `e2e`, passes when each of them succeeded or was skipped and fails otherwise. A workflow-level `paths:` filter was rejected on purpose: a required check that never starts stays "pending" and blocks the PR, while a skipped job inside the workflow is reported and `ci-ok` accepts it.

`e2e-full` is never required. A red nightly run is something to look at the next day, not something that blocks a PR.

### What triggers the `lite` e2e

The classification lives in `scripts/ci-changes.sh` and is **fail-safe**: a PR runs the e2e unless every changed file is on a short list of paths known not to affect the bootstrap (docs and repo metadata, workloads other than `hello-world`, the lint/render-only scripts, `Makefile`, `.pre-commit-config.yaml`). A new or unknown path runs the e2e. `kubernetes/apps/values.yaml` counts only when its `charts.argocd` block changed (the initial ArgoCD install reads it), so Renovate chart bumps skip it. `kubernetes/apps/templates/` still runs it: the `root` Application syncs that chart. Pushes to `main`, `schedule` and `workflow_dispatch` are not classified (the first never runs the e2e; the other two call `e2e-full` directly).

## Targets

To re-measure after the first runs of the new flow:

| Change | Before | Target |
|---|---|---|
| Docs, workloads, chart bumps | about 9-10 min | 2 min or less |
| Ansible, bootstrap, CI definition | about 10 min | 5 min or less |
| Nightly full e2e | about 8 min (on every PR) | about 8 min, off the PR path |

Idempotency and the reset remain on every PR that touches the bootstrap.

## Consequences

- A workload or chart change is validated by `lint` (including `helm unittest` and kubeconform/kube-linter) and `render`, not by a cluster. If it breaks an app, the alerts and the nightly run show it, and the revert is a PR.
- A change that should have run the e2e but was not classified as such is caught by the nightly run. When that happens, widen the rule in `scripts/ci-changes.sh` and add a case to its test.
- A PR that wants the full check before the merge (a new app, a new chart) gets the `e2e-full` label.
- `ci-ok` must be the only name in the ruleset; renaming or removing it breaks the protection, so its name is stable on purpose (#40).
