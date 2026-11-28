# 022 — A second Obsidian instance for another person's vault

- **Status:** accepted
- **Date:** 2026-11-28

## Context

Issue [Bemesko/homelab#71](https://github.com/Bemesko/homelab/issues/71) asks for another person's Obsidian vault to be moved to the NAS and served in the browser, the same way as our own vault ([ADR 006](006-obsidian-nas-nfs.md)). The vault is copied once; no sync with the other person's devices is kept.

## Decision

- **The same stack as ADR 006**: the `linuxserver/obsidian` image, the vault mounted over NFS from the NAS (a PV created by the `nas_storage` role), the app state (`/config`) on local-path on the laptop, and access only through the tailnet with basic auth.
- **A separate namespace and Application** (`natsidian`), with its own user and password in a SOPS Secret of the `tailscale` overlay.
- **Reuse of the workload through kustomize.** `kubernetes/workloads/natsidian/base` takes `obsidian/base` as a resource and a patch changes only the title (`TITLE`) and the vault (mount `/vaults/natsidian`, claim `natsidian-vault`). The image and its digest stay in one place, so Renovate updates both instances at once.
- **Names inside the namespace stay as in the base** (Deployment and Service `obsidian`, config PVC `obsidian-config`). Only the vault PV and PVC are called `natsidian-vault`, because a PersistentVolume is cluster-scoped.
- **Access only through the tailnet.** The device used for this vault has Tailscale. Access over the home LAN without Tailscale, and tunnels, are a follow-up issue.
- **The `natsidian` namespace is excluded from external apps** in the `homelab-apps` AppProject, like the `obsidian` namespace.

## Rejected alternatives

- **Renaming the existing `obsidian` resources to a generic name** (for example `obsidian-*` for both instances, or one instance with two vaults). It would make ArgoCD prune and recreate the config PVC of the running instance.
- **A Helm chart or kustomize component for every instance.** Two instances do not justify a generator. A third one should revisit this.

## Consequences

- Every instance costs a request of 512Mi of RAM (limit 2Gi) and a 5Gi config PVC on the laptop disk, which is already short on space. The rollout checks the free space before the first sync.
- Adding an instance is a manual copy of the directory pattern in four places: `kubernetes/workloads/<name>`, `kubernetes/apps/templates/<name>.yaml`, the `nas_storage` volume and export, and the reserved names in the schema and the AppProject.
- The limits of ADR 006 apply: inotify does not cross NFS, so the vault is edited in one place at a time. Once the copy is made, the original vault is no longer edited.
