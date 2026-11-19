# 011 — NAS Syncthing managed by Ansible

- **Status:** accepted
- **Date:** 2026-11-11
- **Updates:** [005](005-immich-nas-nfs.md) and [008](008-observability-otel-lgtm.md), where they say "Ansible does not touch the NAS"

## Context

The Obsidian vault (`borbsidian`) lives on the NAS and reaches the phone through Syncthing. Syncthing was installed by hand on the NAS in 2026-08 (package from apt.syncthing.net) and started as **root**, with no `syncthing@` instance enabled in systemd. After some reboot it did not come back: the index stopped being written on 2026-10-01 and nothing synced since.

The manual install had three more problems:

- **Root-owned files in the vault.** The vault belongs to `Bernardo` (uid 1000:users). The cluster's Obsidian writes over NFS with `all_squash` 1000:100 and cannot rewrite root-owned files.
- **State on the USB stick.** The config and the index lived in `/root/.local/state`, on the system USB stick, which takes about 230 ms per small write.
- **A leftover peer.** The folder was still shared with the k3s laptop, which already reads the vault over NFS ([ADR 006](006-obsidian-nas-nfs.md)).

openmediavault does not manage this Syncthing install through its UI. A compose stack would solve the boot problem, but the config (devices, folders) would still be manual through the GUI.

## Decision

- Ansible now changes the NAS **only** for Syncthing, through the `nas_syncthing` role. The rest of the NAS is still managed through the OMV UI, and `nas_storage` still only verifies.
- **Access:** a second play in `site.yaml` uses a `nas` group in the private inventory. It connects over SSH as root with the `ansible-control@wsl` key, which stays permanently in the NAS's `/root/.ssh/authorized_keys`. CI has no `nas` group, so the play does not run there.
- **Package:** the `.deb` from the GitHub release is installed with version and sha256 pinned in `group_vars/all` and kept on `hold`.
- **Service:** `syncthing@Bernardo` enabled at boot. A drop-in points `--home` to `appdata/syncthing` on the data SSD, uses `RequiresMountsFor=` with the home and the folders so it does not start before the disk, and sets `UMask=0002`.
- **Migration:** the identity (cert/key), config and index from the root install are copied once, so the device ID does not change. Root-owned files in the folders become `Bernardo:users`. The old directory under `/root` stays as a backup.
- **Declarative config through the REST API:**
  - options, the GUI address (only `127.0.0.1:8384`, reached through an SSH tunnel), devices and folders come from the inventory;
  - a device outside the list is removed;
  - a folder outside the list only produces a warning, because deleting a folder is too destructive to do silently.

## Consequences

- Changes made in the Syncthing GUI (devices, folders, managed options) are undone on the next `make apply`. Pairing a new device means: add its ID to `local.yaml`, run `make apply` and accept on the other side.
- The playbook gains write access to the NAS that stores the photos, with root SSH. The scope is limited to the role and reviewed in the PR. The `no-lockout` pre-commit hook still applies to the new play.
- Upgrading Syncthing means changing the version and sha256 in `group_vars/all`. The apt timers on the NAS stay off.
