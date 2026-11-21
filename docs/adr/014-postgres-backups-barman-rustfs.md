# 014 — Postgres backups with the CNPG Barman Cloud plugin and RustFS

- **Status:** accepted
- **Date:** 2026-11-21
- **Updates:** [005](005-immich-nas-nfs.md) (Immich's own database dump is retired) and [009](009-home-assistant.md) (the HA Postgres now has a backup)

## Context

Every Postgres in the cluster is a single-instance CloudNativePG cluster on the laptop SSD (`local-path`). A database on NFS corrupts easily (ADR 005), so the data cannot move to the NAS.

Until now only Immich had a backup, through its own job (a daily `pg_dump` to the NAS, 14 copies). Home Assistant had none on purpose (ADR 009). The external apps (grocery-ops, bernats-finances) had none at all. A failed SSD or a `make reset` lost their data, and household finances is not disposable.

## Decision

**One CNPG-native mechanism for every cluster:**
- a daily base backup at 02:00;
- continuous WAL archiving;
- a 14-day point-in-time recovery window;
- the data stored on the NAS.

**Components:**
- **Barman Cloud plugin** (`plugin-barman-cloud`, in `cnpg-system`). The in-tree `spec.backup.barmanObjectStore` is deprecated since CNPG 1.26 and leaves in 1.32. The plugin needs CNPG ≥ 1.30 and **cert-manager** for its mTLS with the operator.
- **RustFS** (standalone, in the cluster) as the S3 store, with its data on a dedicated NFS export (`backups`) inside the NAS area that the Rsync replica copies.
  - MinIO was the first choice, but its community edition is archived (no images since October 2025).
  - Before any database was wired, a spike on NFSv3 checked the behaviour barman needs: multipart, pagination beyond 1,000 keys, bulk delete and per-prefix denials.
- **One RustFS user per cluster**, `cnpg-<namespace>`, created by a PostSync Job (`rc`). Objects are limited to `s3://cnpg/<namespace>/`. Bucket listing is not limited, because barman's bucket check (HeadBucket) needs it, so a user sees object names but never contents. `kubernetes/workloads/rustfs/cnpg-users.sops.yaml` is the single source of the keys; each cluster's `*-s3` Secret is a copy.
- **Per cluster:**
  - an `ObjectStore` (zstd for WAL and data, `retentionPolicy: 14d`);
  - the plugin as WAL archiver on the `Cluster`;
  - a `ScheduledBackup` (`method: plugin`, 02:00, before the 03:00 replica).
  - In this repo they live in `database/overlays/nas`. The external apps get them from the template (`repotpl-k8s-app`), in their tailscale overlay.
- **Without the NAS (CI)** neither RustFS nor the backups exist. cert-manager and the plugin still run and are checked in the e2e.

## Consequences

- **Alerts** (`base/alerts/backups.yaml`):
  - archiving failing for 15 min (critical);
  - a base backup older than 26 h (warning).
  - Not "time since the last archival": an idle cluster legitimately archives nothing for a long time.
- **A NAS outage does not stop Postgres.** The WAL waits on the laptop disk, and `local-path` does not enforce the PVC size, so the limit is the SSD, already watched by the root-disk alerts.
- **Restore** is a new `Cluster` with `bootstrap.recovery` from the `ObjectStore` (see the README). It is tested per database, including one point-in-time restore.
- **Three more components to keep up to date** (cert-manager, plugin, RustFS), all pinned by digest.
- **RustFS on NFS** is not a documented setup. The spike passed, but a RustFS upgrade must repeat it.
