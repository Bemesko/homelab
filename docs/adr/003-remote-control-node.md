# 003 — Remote control machine (WSL) over SSH through the tailnet

- **Status:** accepted
- **Date:** 2026-10-31

## Context

The repo is edited on a Windows machine, and the laptop is reached over OpenSSH through the tailnet. Ansible does not run natively on Windows.

## Decision

- Ansible runs in **WSL** and connects to the laptop over SSH, with `become` asking for the sudo password.
- The host's Tailscale is **read-only** for the playbook. The `tailscale_check` role reads the status (MagicDNS and IPs for the k3s `tls-san`) and never runs `tailscale up/down`. The `no-lockout` hook blocks tasks that change Tailscale, SSH, the firewall or the network.
- The real inventory stays out of git. The tailnet name is discovered at runtime, and the kubeconfig goes to `~/.kube/notebook.yaml` in WSL.

## Consequences

- Reinstalling the laptop from scratch requires joining it to the tailnet by hand before running the playbook.
- Under `/mnt/c`, `ansible.cfg` is only read through `ANSIBLE_CONFIG`, which the Makefile exports.
