# 016 — Control node on a Raspberry Pi

- **Status:** accepted
- **Date:** 2026-11-22
- **Issue:** #32 (relates to #23 Wake-on-LAN, which the Pi will also serve)
- **Updates:** [002](002-sops-age-secrets.md) (who holds the age key), [003](003-remote-control-node.md) (where Ansible runs), [004](004-ksops.md) (recipients of the app secrets)

## Context

Until now the playbooks ran only from WSL on one Windows PC, which also held the single copy of the age key, the SSH key to the hosts, the kubeconfig and the private inventory. That PC is going to be discarded, and in the meantime it was a single point of failure for any change to a host.

A Raspberry Pi 3B (Debian 13 trixie, aarch64, wired to the modem, powered over USB) takes over as the **control node**. Development environments move to the cluster laptop and are not part of this decision.

## Decision

- **Where it runs.** `make plan` and `make apply` run by hand, over SSH, on the Pi, against the laptop and the NAS. No scheduled plan, no self-hosted runner, no automatic apply.
- **Everything on the Pi is Ansible.** `ansible/control-node.yaml` (`make control-node`) configures it: `control_node_base` (system updates, unattended-upgrades, log2ram, no swap), `control_node_tailscale`, `control_node_keys`, `control_node_toolchain`, `control_node_logging` and `otel_host_agent`. The first run comes from a machine that still has access; afterwards the Pi runs it on itself (`--connection local`, the Makefile's default on aarch64).
- **Tailscale.** A pinned arm64 binary (sha256) joins the tailnet with a **tagged pre-auth key** kept in `ansible/secrets/secrets.sops.yaml`. The key is only used while the node is not logged in.
- **Keys.** The Pi's SSH key (ed25519) and age identity are created by Ansible and stay **in clear on the SD card**, owned by the connection user. A separate **recovery** age key exists only in the password manager. The PC keeps no key once it is discarded; secrets are edited on the Pi.
- **SOPS recipients.** `ansible/secrets/` is encrypted for the PC (until it is discarded), the Pi and the recovery key. App secrets add the cluster; the hello-world demo adds the CI key. The data is not re-encrypted, only the recipient stanzas change (`sops updatekeys`).
- **Access to the other hosts.** `control_node_access` only **adds** the Pi's public key to `authorized_keys` of the laptop and the NAS, never removes any and never touches the SSH server. The Pi learns the hosts' SSH host keys with `ssh-keyscan` over the tailnet (already authenticated), so `host_key_checking` stays on.
- **Toolchain.** `scripts/setup-control-node.sh --runtime` installs only what `make plan/apply/kubeconfig` needs (ansible-core, sops, age, helm, kubectl, collections). The dev/test tools stay on x86_64 and in the CI. Every binary has one sha256 per architecture.
- **Telemetry (mandatory).** Each run is tee'd into the Pi's journal as `homelab-ansible` and traced by the `community.general.opentelemetry` callback. A collector on the Pi (the same `otel_host_agent` role, arm64) forwards the journal entries and the traces to the cluster gateway over the tailnet, under `service.name: control-node`. Two alerts: `control-node-apply-failed` (a `failed=` or `unreachable=` above zero in the PLAY RECAP) and `control-node-silent`.

### Exceptions to the `no-lockout` rule

The hook still blocks any task that changes Tailscale, SSH, the firewall or the host network. Two exceptions, both for this issue:

1. `control_node_access`: add-only, on the laptop and the NAS; only the line that writes the key carries `# lockout-safe`.
2. `control_node_tailscale`: runs only on the Pi, which is wired and in the house, so a mistake costs a walk to the SD card, not access to the cluster. The role is excluded from the hook by path.

## Consequences

- **The Pi is now the single point of failure**, as the PC was. What changes is that it can be rebuilt from the repo and the password manager (runbook in the README), and that its failures are visible: the collector reports metrics, and `control-node-silent` fires when it stops.
- **The age private key is in clear on an SD card.** Anyone with the card can decrypt every secret that lists the Pi, and that includes `ansible/secrets/secrets.sops.yaml`: the cluster's age private key, the Tailscale OAuth client, the GitHub App key and the GHCR token are all readable from the Pi. Only the recovery key stays off it. Accepted for a device in the house; a passphrase or a hardware key is out of scope.
- **A rebuilt Pi is a new identity.** It generates a new SSH key and age identity, so rebuilding means adding its age public key to `.sops.yaml`, running `sops updatekeys` with the recovery key, running `make control-access` and removing the old Pi by hand.
- **Pre-auth key lifetime.** A single tagged key is used at the first login; a rebuild needs a valid key (or a new one in `secrets.sops.yaml`).
- **log2ram keeps `/var/log` in RAM**, including the persistent journal (capped at 32 MB). The local journal copy survives a cluster outage but **not a power cut**; the copy in Loki covers that when the cluster is up. Accepted.
- **log2ram comes from the Debian archive**, pinned by version and verified by apt's signature, not by a sha256 in the repo like the downloaded binaries. The Debian package was already installed, and a third-party repository would have added a trust root for no gain.
- **Everything the Pi does is visible through the same stack** as the other hosts, with its own `service.name` so that `host-silent` (keyed on `homelab-host`) cannot be masked by the Pi's series.
- **Not tested yet:** rebuilding the Pi on a clean SD card from the repo and the password manager, as the runbook describes. Until someone does, treat the runbook as unverified; the issue keeps that item open.
- **Wake-on-LAN (#23)** can reuse this Pi: it is wired, boots when power returns and already has an Ansible role set.
