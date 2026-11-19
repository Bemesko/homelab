# 007 — Apps from other repos

- **Status:** accepted
- **Date:** 2026-11-02

## Context

Until now every workload lived in this repo (`kubernetes/workloads/`). For our own apps that mixes the app lifecycle (code, image, version) with the platform's. The idea is for each app to have its own repo in the `bernats-homelab` org, private included, and for the cluster to publish a version chosen here, the same way we already do with third-party charts.

## Decision

- **The `bernats-homelab/repotpl-k8s-app` template.** It brings the layout this repo expects:
  - `deploy/base`, without Ingress, used in CI;
  - `deploy/overlays/tailscale`, used on the laptop;
  - a release workflow (image on GHCR → digest written to `deploy/base` → `vX.Y.Z` tag);
  - CI with the same checks as here (kubeconform, kube-linter, sops, gitleaks) and an e2e on k3s.
- **Only the Application lives here.** Each entry under `apps:` in `kubernetes/apps/values.yaml` becomes an Application (`templates/external-apps.yaml`) that syncs the app repo's `deploy/`.
  - `values.schema.json` requires a `bernats-homelab/*` or `Bemesko/*` repo and a semver tag: promoting a version is a PR here, reviewable like a chart version bump.
- **The `homelab-apps` AppProject.** It only accepts repos from the org and the personal `Bemesko` account, no cluster-scoped resource other than `Namespace`, and denies the system and platform namespaces.
  - *Addendum (2026-11-07):* the personal account was added for `grocery-ops`. Its repos must be public, because the credential (GitHub App) only covers the org.
  - A misbehaving app repo cannot touch ArgoCD, Tailscale, CNPG or the Immich data.
- **Credentials (optional), created by Ansible from `ansible/secrets/` (the ADR 002 path):**

  | For | Credential | Why |
  |---|---|---|
  | Git | GitHub App with *Contents: read-only*, in a `repo-creds` template with the org prefix | no expiry, revocable, native ArgoCD support |
  | Images | Classic PAT with `read:packages` in the k3s `registries.yaml` | GHCR accepts neither an App nor a fine-grained token; on the node, no app needs an `imagePullSecret` |

- **App secrets** with KSOPS, like the ones here: the template's `.sops.yaml` uses the same public keys (WSL + cluster).
- **Smoke test in the e2e.** With `external_apps_smoke_enabled=true` (CI only), the chart syncs the template itself (`smokeApp`, at a published tag) and `e2e-assert.sh` checks `/healthz`.

## Consequences

- **A new app version = a release in its repo + a PR here.** Nothing reaches the cluster without going through this repo, and the e2e here does not break because of an app's `main`.
- **The e2e depends on an external repo:** the template tag in `smokeApp` and its public GHCR package. Changing that tag is a PR like any other.
- **Private credentials are not tested in CI.** CI has neither the GitHub App nor the PAT, so private repos and images are only exercised on the laptop.
- **The GitHub App credential covers the whole org prefix.** If the App is not installed on a repo, ArgoCD cannot read that repo. Since 2026-11-19 this repo lives in the personal account (`Bemesko/homelab`, public) and no longer needs it.
- **Anyone with push access to an app repo can make ArgoCD decrypt that app's secrets** (cluster key), but only inside the app's namespace, because of the AppProject.
- **An app's key under `apps:` is the name of the Application and, by default, of the namespace.** The schema blocks the names of the platform Applications.
