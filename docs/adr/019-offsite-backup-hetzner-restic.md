# 019 — NAS off-site backup: restic in the cluster to a Hetzner Storage Box

- **Status:** accepted
- **Date:** 2026-11-09

## Context

The NAS (OMV) has two copies, both at home: the primary SSD and the replica on a USB disk (OMV Rsync jobs at 03:00, `data-with-backup` only). The third copy, outside the house, is missing. Today it is ~600 GB (`data-with-backup` ~250 GB + `data-without-backup`), with a budget of up to ~US$ 5/month. A slow restore is acceptable, but the provider configuration must be declarative.

Prices checked on 2026-11-08, before taxes, for 600 GB:

| Option | Cost/month | Notes |
|---|---|---|
| **Hetzner Storage Box BX11 (1 TB)** | € 3.20 flat (US$ 4.00 when billed in USD) | Unlimited traffic; SFTP/SSH; BX21 (5 TB) at € 10.90 / US$ 13.00; no setup fee |
| Backblaze B2 | US$ 4.17 (US$ 6.95/TB) | Free egress up to 3× the stored data; passes US$ 5 at ~720 GB |
| Storj | US$ 4.20 + US$ 7/TB egress | |
| Wasabi | US$ 7.99 (1 TB minimum) | |
| Cloudflare R2 | US$ 9 (Standard) / US$ 6 (IA) | Free egress |
| AWS S3 Standard | US$ 13.80 (us-east-1) / US$ 24.30 (sa-east-1) | |
| Glacier Deep Archive, GCS Archive, Azure Archive | US$ 0.59–0.72 | 180–365 day minimum retention; paid restore in 12–48 h; does not fit `restic prune` |

## Decision

- **Destination:** Hetzner Storage Box **BX11** in `fsn1`. In USD it is cheaper than B2 above ~575 GB (above ~530 GB in EUR), with no egress cost on restore. Between 1 and ~1.9 TB B2 would be cheaper again; above that, the BX21.
- **Provisioning:** **OpenTofu** in `infra/hetzner/` with the `hetznercloud/hcloud` provider (Storage Box support is no longer experimental there). It creates the box, the `access_settings` (SSH only) and the snapshot plan, and injects the restic SSH key.
  - The **state is versioned in git, encrypted by OpenTofu itself** (pbkdf2 + AES-GCM, `enforced`). It holds the box password.
  - The API token and the state passphrase live in `infra/hetzner/secrets.sops.yaml`, which only the control node (Pi) and the recovery key open.
  - `ssh_keys` cannot be changed through the API (changing it would recreate the box). Hence `ignore_changes` and `prevent_destroy`, on top of `delete_protection` on Hetzner's side.
- **Tool:** **restic** over SFTP (port 23), with client-side encryption, deduplication and versions. The repository password lives only in the SOPS Secret and in the password manager.
- **Where it runs:** the `restic-backup` CronJob in k3s (namespace `backup`), at 04:00, after the local replica and the Immich Postgres dump and before the laptop's unattended-upgrades (05:15, ADR 010). Not on the NAS, because:
  - the NAS is configured only through its UI and this repo does not change it (the exceptions are the `nas_syncthing` and `power` roles);
  - in the cluster we get GitOps, image by digest, the secret in KSOPS and alerts in the existing stack;
  - the NAS (T400, system on USB 2.0) is already fragile.
  - The cost is reading over NFS (`ro`) through the tailnet. With an upload below 50 Mbps, the bottleneck is the internet, not NFS.
- **Scope:** the whole SSD root (export `photos`, PV `backup-source`, read-only). This includes `data-with-backup`, `data-without-backup` and `immich-data` (uploads and Postgres dumps).
- **Retention:**
  - restic: 7 daily, 4 weekly, 6 monthly. `forget` runs every day; `prune` and `check --read-data-subset=5%` run on Sundays.
  - Storage Box automatic snapshots: 7 daily at 06:00 UTC (03:00 in Brasília), before the backup. They are out of reach of the cluster's SSH key: if that key is used to delete the repository, you can go back up to a week. No extra charge, but they use the quota.

- **Rollout:** merged **inactive**. `offsiteBackup.enabled` is `false` in `kubernetes/apps/values.yaml`, so the `backup` Application is not rendered, and the two alert rules carry `isPaused: true`. The OpenTofu scaffolding, the workload manifests and the tooling are all in the repo (and still validated by CI: the chart is rendered with the flag on, and the workload kustomizations are linted either way), but nothing runs and nothing is billed until someone applies OpenTofu and fills in the restic Secret. Activation is one PR: flag on, `isPaused` removed (README).

## Consequences and risks

- **restic password:** without it the backup cannot be recovered. Keep it in the password manager (`sops -d kubernetes/workloads/backup/overlays/nas/restic.sops.yaml`).
- **Initial upload:** takes days (~3 at 20 Mbps, ~11 at 5 Mbps). Each run is cut at 22h and resumed the next day, so for the first days it still overlaps the 05:15 unattended-upgrades. Meanwhile the `backup-offsite-stale` alert fires.
- **Quota:** with NAS growth, old snapshots and the box snapshots, 1 TB can fill up. Follow the NAS upgrade triggers; the next step is the BX21. There is no quota alert yet: the used space shows in the Hetzner console and in `restic stats`.
- **Unreadable files:** with the export's `all_squash` 1000:100, a file this user cannot read makes restic exit with code 3. The Job fails and fires `backup-offsite-failed`, even though the snapshot was created.
- **Cache:** the restic cache is an `emptyDir`. Each run downloads indexes and trees again, which is acceptable with free traffic. A local-path PVC would leave the Application `Progressing` until the first run.
- **Restore:** done from the control node with restic and the same key/password (README). Outbound traffic from the Storage Box is not billed.
