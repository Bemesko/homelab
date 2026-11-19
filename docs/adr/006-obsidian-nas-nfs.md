# 006 — Obsidian in the browser with the NAS vault over NFS

- **Status:** accepted
- **Date:** 2026-11-05

## Context

We want the Obsidian desktop app reachable from any tailnet device through a browser. The vault (`borbsidian`, ~9,600 files, ~530 MB) already lives on the NAS, inside the backed-up area, and is edited from other devices through Syncthing/SMB.

## Decision

- **The `linuxserver/obsidian` image**, not the `sytone/obsidian-remote` one that tutorials mention.
  - The linuxserver one is maintained and has versioned tags, so the version and digest can be pinned like the rest of the repo.
  - The sytone one only publishes `latest`.
- **The vault is mounted from the NAS over NFS (rw), with no copy and no sync in the cluster.**
  - It follows the same path as Immich (ADR 005): OMV is configured through its UI, the `nas_storage` role checks the export and creates the PV, and the PVC comes from git.
  - The role now takes a list of volumes (`nas_storage_volumes`) instead of being Immich-specific.
  - `all_squash` to `1000:100` gives the files Obsidian creates the same owner as the existing ones.
- **The app state (`/config`) lives on local-path, on the laptop.** It is rebuildable state: the open vault, the Electron profile.
- **Access only through the tailnet, with basic auth.**
  - The container has a web terminal. So besides the tailnet ACL there is a user and password (`CUSTOM_USER`/`PASSWORD`, in a SOPS Secret in the `tailscale` overlay).
  - `allowPrivilegeEscalation: false` turns off sudo inside the container.
  - CI uses `base`, which has no secret, Ingress or auth.

## Rejected alternative: Syncthing inside the cluster

The vault would live on local-path, with a Syncthing in the cluster as one more peer. Obsidian would see changes in real time, and conflicts would become `.sync-conflict` files.

It was left out for now because it brings more moving parts (another app, Syncthing keys in SOPS, manual pairing) and a second copy of the vault outside the NAS backup.

## Consequences

- **inotify does not cross NFS.** The cluster's Obsidian does not see changes made from other devices until it reloads (*Reload app without saving*), and it can overwrite a newer edit. The rule is to edit in one place at a time. If that becomes annoying, the alternative above is the next step.
- **The image starts as root and writes to the rootfs**, because of the s6-overlay that switches to the PUID. These are explicit kube-linter exceptions, in the Deployment annotations.
- **s6-overlay is multi-process and signals its own children.** On Ubuntu 26.04 that depends on the fixed AppArmor profile in the `base` role (containerd#14485).
- **The `nas_storage` test mount writes and deletes a file at the vault root.** If another device syncs at that moment, the file may briefly show up there too.
