# 004 — App secrets with KSOPS in ArgoCD

- **Status:** accepted
- **Date:** 2026-11-01
- **Evolves:** [002](002-sops-age-secrets.md)

## Context

ADR 002 left secrets to Ansible during the bootstrap. That works for the Tailscale OAuth client, but every new app with a secret would need a new task and a `make apply`, and the secret would sit outside GitOps. The idea is to commit the encrypted secret next to the app and let ArgoCD sync it.

## Decision

- **KSOPS** in the ArgoCD `repo-server`. An init container copies the binary (image pinned by digest), and `kustomize.buildOptions` enables `--enable-alpha-plugins --enable-exec`. Apps declare a `viaduct.ai/v1 ksops` generator pointing at their `*.sops.yaml` files.
- **The cluster's own age key**, separate from the WSL one:
  - the private key lives in the `argocd/sops-age` Secret, which Ansible creates from `ansible/secrets/secrets.sops.yaml` (the ADR 002 path) before ArgoCD starts;
  - files under `kubernetes/` are encrypted to both keys (`.sops.yaml`): WSL to edit, the cluster to sync;
  - `ansible/secrets/` still uses only the WSL key.
- **`unencrypted_regex: ^(apiVersion|metadata|kind|type)$`** in the manifests: only `data`/`stringData` are encrypted. That way the diff shows which Secret changed, and the offline render can produce the structure.
- **CI test key** (`tests/ci-age.key`), **public on purpose**:
  - it is a recipient only of the demo `kubernetes/workloads/hello-world/base/demo-secret.sops.yaml`, so the e2e exercises the real path (ArgoCD → KSOPS → Secret);
  - the `sops-encrypted` hook blocks this key on any other path, and gitleaks only allows that file.
- **Offline validation with a stub.** `scripts/ksops-stub.py` replaces ksops in pre-commit and CI. It generates the Secret with placeholder values, validates the structure with kubeconform/kube-linter and needs no key.

## Consequences

- **The cluster key now lives in the cluster.** Anyone with cluster admin (kubeconfig) or read access to the laptop disk can decrypt the secrets under `kubernetes/`, but not those in `ansible/secrets/`. If it leaks: generate a new one, update `.sops.yaml` and `secrets.sops.yaml`, run `sops updatekeys` on the files under `kubernetes/`, then `make apply`.
- **The WSL key is still the root:** it decrypts everything, including the cluster key.
- **Rebuilding the cluster is still just `make apply`:** the cluster key comes from `secrets.sops.yaml`.
- **No real secret is tested in CI.** What the e2e guarantees is the mechanism (init container, key mount, buildOptions, generator), not the values.
