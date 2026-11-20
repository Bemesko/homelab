#!/usr/bin/env bash
# The laptop is reached over SSH through Tailscale. No task may change
# Tailscale, the SSH server, the firewall or the host network: that would cut off access.
# Legitimate read-only lines can be marked with the `# lockout-safe` comment.
set -euo pipefail

readonly PATTERN='tailscale[[:space:]]+(up|down|logout|set|switch)|tailscaled|community\.general\.ufw|\bufw\b|iptables|nftables|\bnft\b|netplan|NetworkManager|nmcli|systemd-networkd|\bsshd\b|ssh\.service|ssh\.socket|authorized_key'

status=0
for file in "$@"; do
  if matches="$(grep -nEi "${PATTERN}" "${file}" | grep -v 'lockout-safe')"; then
    echo "ERROR: ${file} contains an operation that could cut off access to the laptop:" >&2
    echo "${matches}" >&2
    status=1
  fi
done
exit "${status}"
