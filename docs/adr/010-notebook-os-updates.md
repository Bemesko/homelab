# 010 — Laptop OS updates under control

- **Status:** accepted
- **Date:** 2026-11-11

## Context

On 2026-11-11 at 06:40, Ubuntu's `apt-daily-upgrade.timer` fired at a random time (06:00 + up to 60 min) and unattended-upgrades installed kernel 7.0.0-43, with initramfs and NVIDIA modules. The laptop SSD is an entry-level SATA drive (115 GB, 76% full): it stayed 84% busy while writing only 3–8 MB/s. Both of the cluster's SQLite databases stalled for ~7 min:

- **Grafana:** `database is locked (SQLITE_BUSY)`, with failed logins, datasource reads and alert-rule syncs.
- **k3s (kine):** `Handler timeout` in the apiserver.

No pod restarted, but the new kernel was left installed for the next boot without any testing. That is how 7.0.0-42 (also via unattended-upgrades) broke Postgres on 2026-11-05, through the AppArmor regression.

## Decision

- **The `os_updates` role** (Ansible, after `base`):
  - unattended-upgrades keeps installing security updates, **except `linux-*`** (`Package-Blacklist`), and does not remove old kernels on its own.
  - Fixed schedule with no random delay: download at 05:00, upgrade at 05:15. That is after the NAS rsync (03:00) and outside usage hours.
  - `apt-daily-upgrade.service` runs with `Nice=19`, `CPUSchedulingPolicy=idle` and `IOSchedulingClass=idle`. dpkg inherits that, and `mq-deadline` honors the I/O class.
- **`make kernel-upgrade`** (`ansible/kernel-upgrade.yaml`): installs the pending `linux-*` packages, reboots if the newest kernel in `/boot` is not the running one, and checks the kernel, the node `Ready`, all Applications Synced/Healthy, the Postgres clusters (CNPG) ready and no AppArmor signal or D-Bus denials. Only then does it run `apt autoremove`, which keeps the current and the previous kernel.
- **Grafana with SQLite in WAL mode** (`database.wal: true`): readers do not wait for writes.
- **The kubelet image GC stays at the default (85/80).** We tried 70/60: the kubelet measures the whole filesystem (77%, driven by `/home/snap`, swap and snapd), and all 35 containerd images (18 GB) are in use. It freed 0 bytes and would log a failure every 5 minutes. The space to reclaim is outside the cluster.
- **The `host-disk-saturated` alert** (warning): the laptop disk more than 70% busy for 5 min.

## Consequences

- A new kernel only goes in when someone runs `make kernel-upgrade`. It has to be run periodically (kernel security fixes do not apply themselves).
- The `make kernel-upgrade` reboot takes the apps down for a few minutes; run it at a chosen time.
- Postgres for Grafana (instead of SQLite) and replacing the SSD with a bigger one remain as alternatives if the problem comes back.
