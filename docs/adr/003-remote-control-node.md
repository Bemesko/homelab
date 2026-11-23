# 003 — Remote control machine (WSL) over SSH through the tailnet

- **Status:** accepted; the control machine moved from WSL to a Raspberry Pi in [016](016-control-node-raspberry-pi.md) (the model of Ansible reaching the hosts over SSH through the tailnet stays)
- **Date:** 2026-10-31

## Context

The repo is edited on a Windows machine, and the laptop is reached over OpenSSH through the tailnet. Ansible does not run natively on Windows.

## Decision

- Ansible runs in **WSL** and connects to the laptop over SSH, with `become` asking for the sudo password.
- The host's Tailscale is **read-only** for the playbook. The `tailscale_check` role reads the status (MagicDNS and IPs for the k3s `tls-san`) and never runs `tailscale up/down`. The `no-lockout` hook blocks tasks that change Tailscale, SSH, the firewall or the network. Its exceptions are the control node roles ([016](016-control-node-raspberry-pi.md)) and the `host_network` role ([017](017-notebook-wired-network.md)).
- The real inventory stays out of git. The tailnet name is discovered at runtime, and the kubeconfig goes to `~/.kube/notebook.yaml` in WSL.

## Consequences

- Reinstalling the laptop from scratch requires joining it to the tailnet by hand before running the playbook.
- Under `/mnt/c`, `ansible.cfg` is only read through `ANSIBLE_CONFIG`, which the Makefile exports.
