# 005 — Immich with the NAS photos over NFS

- **Status:** accepted
- **Date:** 2026-11-01

## Context

Immich runs on the laptop's k3s and has to show, **read-only**, the photos and videos on the `thinkpad` NAS (openmediavault, on the tailnet). The collection is 200 GB to 1 TB; the laptop has ~50 GB free. The NAS only exposed SMB.

## Decision

- **NFS, not SMB.**
  - The kubelet mounts `nfs:` natively: no CSI driver in the cluster, only `nfs-common` on the host.
  - There is no credential to store.
  - Both sides are Linux, so permissions and file names work without translation.
  - Access is restricted to the laptop's Tailscale IP, and the traffic is already encrypted by WireGuard.
- **OMV is configured through its own UI, and Ansible only verifies.**
  - OMV keeps its configuration in its own database and regenerates `/etc/exports`. Automating it would need `omv-rpc` + `omv-salt`, which is fragile across versions and would give the playbook write access to the photo NAS.
  - The `nas_storage` role only reads (`showmount`) and does a temporary test mount, including a write to the data export.
- **PVs come from Ansible; PVCs come from git.**
  - The PV carries the NAS hostname and paths, which live in the private inventory together with the laptop hostname.
  - The PVC only declares what the app needs. `claimRef` makes sure only the Immich PVC uses each PV.
- **Where each piece of data lives:**

  | Data | Where | Why |
  |---|---|---|
  | Original photos/videos | NAS, `ro` export | Immich never changes the originals |
  | Thumbnails, previews, transcodes, database dumps | NAS, dedicated `rw` export (`immich-data`) | ~12 to 70 GB, does not fit on the laptop |
  | Postgres (CNPG + VectorChord) | laptop disk (`local-path`) | a database on NFS corrupts easily |

- **Database backup** with Immich's native job (daily dump to `immich-data/backups`, 14 copies). The database is gone after a `make reset`, but the dumps stay on the NAS.
  Superseded by [014](014-postgres-backups-barman-rustfs.md): CNPG backups to RustFS on the NAS; the native dump is turned off once those are proven.
- **HEVC accepted without transcoding** (`ffmpeg.acceptedVideoCodecs`) and **ML turned off**. Both avoid days of CPU on the i7-7500U and extra GBs on the NAS.

## Consequences

- **Firefox and HEVC:** Firefox may not play HEVC videos. Chrome/Edge, Safari and the app do.
- **New photos do not show up right away.** `library.watch` does not work over NFS; they appear on the next scheduled scan.
- **CI has no NAS.** The e2e brings up Immich + CNPG on `local-path` (`nasStorage.enabled=false`). The NFS path is covered by the `nas_storage` assert and test mount, which run on the laptop.
- **PVCs are immutable.** Switching `nasStorage` after the PVCs exist requires deleting them.
- **The Immich Postgres has no secret of ours:** CNPG generates `immich-database-app`.
