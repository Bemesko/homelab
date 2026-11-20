# 001 — k3s + Ansible + ArgoCD on the laptop

- **Status:** accepted
- **Date:** 2026-10-31

## Context

The cluster has to run on a personal laptop with Ubuntu 26.04, with few resources, and be reproducible after a system reinstall.

## Decision

- **k3s** directly on the host, single-node. It is a single binary, light on resources, and the embedded Traefik stays off because ingress goes through the Tailscale Operator.
- **Ansible** is idempotent and covers only the host and the bootstrap: packages, sysctl, k3s, the initial Secrets, the ArgoCD `helm install` and the root Application.
- **ArgoCD app-of-apps** (Helm chart in `kubernetes/apps`) takes care of everything that runs inside the cluster. ArgoCD manages itself.
- Ansible installs ArgoCD **only if it does not exist yet**. After that, ArgoCD manages itself, so the two never fight over the release.

## Consequences

- Cluster changes go through Git; Ansible is only needed again for the host/k3s.
- The ArgoCD chart version lives in a single place (`kubernetes/apps/values.yaml`).
