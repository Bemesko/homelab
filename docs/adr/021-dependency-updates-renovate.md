# 021 — Version updates with self-hosted Renovate

- **Status:** accepted
- **Date:** 2026-11-24
- **Issue:** #42 (amends [ADR 015](015-ci-flow-and-required-checks.md) and [ADR 007](007-external-apps.md); relates to #19 image promotion and #40 pipeline library)

## Context

Every version in the homelab was bumped by hand: the charts in `kubernetes/apps/values.yaml`, the images pinned by digest (in several layouts), the external apps pinned by tag, the binaries pinned with a sha256, the GitHub Actions, the pre-commit hooks, the Ansible collections, the OpenTofu providers and the vendored dashboards. The goal of #42 is to remove the chore of watching for new versions; the tool was open.

## Alternatives

| Tool | Why not (or why) |
|---|---|
| **Renovate** | Chosen. Reads every layout in the repository (built-in managers plus regex managers), pins digests, groups and automerges |
| Updatecli | Can run shell steps (checksums), but every dependency is a hand-written pipeline, and grouping and automerge are weaker |
| Dependabot | Does not read the app-of-apps `values.yaml`, the Ansible variables or the digests in Helm values |
| Argo CD Image Updater, Flux image automation | Container images only (Flux also needs Flux). They belong to the promotion of our own images (#19) |
| Kargo | Promotes artifacts between stages (#19), not third-party version updates |

No CNCF project covers the general case.

## Decision

### Self-hosted in GitHub Actions

`.github/workflows/renovate.yaml` runs the Renovate container, pinned by digest, with a token from our own GitHub App. The hosted Mend app was the simpler option, but it cannot run post-upgrade commands, which the binary checksums need, and any workflow that adds a commit to a Renovate PR needs an App token anyway: a commit pushed with `GITHUB_TOKEN` does not start the CI, so `ci-ok` would never report on it.

It runs daily, on demand, when one of our apps publishes a release, when someone ticks a checkbox on the Dependency Dashboard issue, and on every push to `main`. The last one exists because the ruleset requires up-to-date branches (ADR 020): after one update merges, the others have to be rebased before they can. New branches for third-party updates are only created on Mondays (America/Sao_Paulo); the Dependency Dashboard checkboxes force one earlier. With no webhook server, the workflow listens to `issues: edited` for that, filtered to a person editing the issue Renovate opened: the repository is public, and Renovate rewrites the Dashboard during its own runs.

The workflow must never get a `pull_request` trigger: the repository is public and the job holds the App key.

### The CI is the merge gate

The principle: **what passes the CI may be applied to the cluster.** ArgoCD follows `main`, so an automerged update is deployed with no one looking. Therefore a PR that changes what ArgoCD deploys now runs the `full` e2e (every Application Healthy), not only `lint` and `render` (ADR 015, amended). The rule applies to every PR, not only to Renovate's. The one exception is a new version of our own apps, below.

### Automerge

`renovate.json` automerges every update through GitHub auto-merge, which waits for `ci-ok`, except:

| Update | Why a human merges it |
|---|---|
| Any major version (label `major-update`) | Breaking changes by definition |
| Immich and the Postgres images | The upgrade migrates the database; a green CI starts from an empty one |
| OpenTofu providers | Only take effect with `make *-apply`, which the CI does not run |
| Tailscale (operator chart and the control node's client) | The CI runs without Tailscale |
| The OTel Collector (images and the host `.deb`, grouped) | The CI does not install the host collector |
| Syncthing (NAS) and the OpenTelemetry Python packages (control node) | The CI has neither host |
| A new Kubernetes minor (k3s, kubectl, manifest schemas) | Planned work; patches merge by themselves |

Releases wait 3 days (`minimumReleaseAge`) before they are proposed. Many registries publish no release date, and Renovate would hold those updates forever, so a missing date is accepted (`timestamp-optional`): for those the delay does not apply.

### Images in Helm values

A values file is not a manifest, so no built-in manager reads it, and many entries name no repository (it is the chart's default). Each pin carries a comment right above its `tag`, which is what the regex manager reads:

```yaml
image:
  # renovate: image=quay.io/jetstack/cert-manager-controller
  tag: v1.21.3
  digest: sha256:...        # `sha:` in some charts; or `tag: v1.0.0@sha256:...` on one line
```

**An image without the comment is silently never updated.** The digest must start with `sha256:`; where a chart's own digest key does not take the prefix (Grafana's `sha`), it goes in the tag.

cert-manager and the Barman Cloud plugin ship CRDs and RBAC in the chart that belong to one image version. Chart and images are grouped, and `scripts/check-chart-images.py` (in `make test-render`) compares the pinned tags with the chart's `appVersion`: a PR that updates only one side stays red until Renovate adds the other.

### Downloaded tools: the sha256 comes in the same PR

Versions in Ansible variables and shell constants are marked with a comment on the line above, which one regex manager reads:

```yaml
# renovate: datasource=github-releases depName=helm/helm
helm_version: v4.3.1
helm_sha256: ...
```

- After a bump, Renovate runs `scripts/update-checksums.sh <depName>` (`postUpgradeTasks`), the only command its allow list accepts. The script downloads each artifact, never executes it, compares the hash with the checksum file the project publishes, and rewrites the pins. `age`, `kube-linter`, the Syncthing `.deb` and the k3s installer publish none: their hash is only computed.
- **The `checksums` job of the CI** runs the script for every version a pull request changes and fails if it rewrites anything. It covers what the e2e does not install (arm64, the NAS and control node packages), a failed task (GitHub auto-merge would not notice it) and a version edited by hand.
- **After a manual edit:** `scripts/update-checksums.sh <depName>` (or `--changed origin/main`). A new pinned download needs the comment, an entry in `VERSION_PINS` and a case in the script, and its name in the rule of `renovate.json`.
- Not tracked: `log2ram`, a Debian package version.

### Our own apps: their owners deploy

The apps under `apps:` in `kubernetes/apps/values.yaml` are ours, and publishing a release is the decision to deploy it. This changes [ADR 007](007-external-apps.md), where the PR in this repository was the review step.

| | Third-party | Our own apps |
|---|---|---|
| Proposed | Mondays, 3 days after the release | as soon as the release is published |
| Major versions | a human merges | automerged too |
| e2e on the PR | `full` | none: only `lint` and `render` (the `values.yaml` schema) |

- **Only the version is exempt from the e2e.** `scripts/ci-changes.sh` skips it when the only data that changed is `apps.<name>.targetRevision`. Adding, removing or repointing an app runs the `full` profile.
- **The template too.** A release of `repotpl-k8s-app` (`smokeApp`) is proposed and automerged like our apps', majors included, but its PR runs the `full` e2e: that is where the new version is tested, and nothing is deployed to the cluster.
- **The release starts the run.** The app's release job ends with the composite action [`pipelines/actions/dispatch-homelab-update`](../../pipelines/README.md), which starts `renovate.yaml` here. Renovate finds the tag, opens the PR and GitHub merges it when `ci-ok` is green. If the dispatch fails, the release still succeeds and the daily run picks it up.
- **The trade-off:** whoever can push to an app repository can deploy it with no one else looking, and a broken release reaches the cluster. The `homelab-apps` AppProject keeps the damage inside the app's namespace, the nightly `e2e-full` and the alerts show it, and the revert is a PR (reverting alone is not enough while the broken tag is the newest: publish a fixed release).
- **Private apps** (`bernats-finances-v4`): the Renovate App is also installed on the organization, for that repository only. The workflow mints a second, read-only token and gives it to Renovate as a `hostRules` entry for that repository's tags. A new private app needs its name in `.github/workflows/renovate.yaml` (twice) and a `fetchChangeLogs: off` rule in `renovate.json`, or its release notes are copied into a public pull request.

### Shared preset

`renovate/default.json` holds what every homelab repository should share (schedule, release age, digest pinning for actions, the major rule). This repository extends it with `local>Bemesko/homelab//renovate/default`; another repository would use `github>Bemesko/homelab//renovate/default`. The preset never turns on automerge: the app repositories require no checks (ADR 020), so automerge there would merge untested. Each repository opts in. No other repository extends it today.

### Inside the app repositories: Dependabot

The app repositories and the template keep their own Dependabot configuration for their dependencies (packages, base images, Actions), which already proposes them weekly. Renovate here only follows the tag each one publishes. Wiring Renovate into them would duplicate that work; the shared preset stays there for a repository that opts in later.

### Not covered

- The vendored dashboards (`dashboards.lock`), left to #96.

## Setting up the GitHub Apps

Once, by the repository owner. Both are created in GitHub → Settings → Developer settings → GitHub Apps → New, with the webhook off.

### The Renovate App (`bemesko-homelab-renovate`)

1. Repository permissions: **Read and write** on Checks, Commit statuses, Contents, Issues, Pull requests and Workflows; **Read** on Administration, Dependabot alerts and Metadata.
2. "Where can this GitHub App be installed?": **Any account**, so the organization can install it.
3. Install it on `Bemesko/homelab`, and on the `bernats-homelab` organization for `bernats-finances-v4` only.
4. Generate a private key, keep it in KeePass, and store the credentials:

```bash
gh variable set RENOVATE_APP_CLIENT_ID --repo Bemesko/homelab --body '<client id>'
gh secret set RENOVATE_APP_PRIVATE_KEY --repo Bemesko/homelab < bemesko-homelab-renovate.<date>.private-key.pem
```

Then delete the downloaded `.pem`. Until the variable exists, the workflow is skipped. To check the setup without changing anything: `gh workflow run renovate.yaml -f dry_run=true`.

### The dispatch App (`bemesko-homelab-dispatch`)

A separate App, because its key is copied into the app repositories: the Renovate key there would give every one of them write access to this repository's code and workflows.

1. Repository permissions: **Read and write** on Actions; **Read** on Metadata. Nothing else.
2. Install it on `Bemesko/homelab` only.
3. Generate a private key, keep it in KeePass, and store it in **each app repository**:

```bash
for repo in Bemesko/grocery-ops bernats-homelab/bernats-finances-v4 bernats-homelab/repotpl-k8s-app; do
  gh variable set HOMELAB_DISPATCH_CLIENT_ID --repo "$repo" --body '<client id>'
  gh secret set HOMELAB_DISPATCH_PRIVATE_KEY --repo "$repo" < bemesko-homelab-dispatch.<date>.private-key.pem
done
```

With "Actions: write" the key can start, cancel and re-run workflows here, and disable them. It cannot change code or merge: a disabled `ci` workflow blocks merges, it does not bypass them.

## Consequences

- Updates arrive as grouped, tested PRs; most merge by themselves. A release of our own app reaches the cluster with no step in this repository.
- A PR that changes charts, images or workloads takes the time of the `full` e2e (7 to 10 minutes) instead of about 2.
- What the e2e does not exercise (the NAS, Tailscale, an upgrade of existing data) can still break after an automerge. The alerts show it and the revert is a PR; widen the exceptions when that happens.
- Updates of Ansible variables and control-node tools only reach the hosts at the next `make apply` or `make control-node`, even when they merged by themselves.
- The repository now holds one credential in Actions secrets, and the app repositories hold the dispatch one. Revoking an App or deleting its key stops it.
