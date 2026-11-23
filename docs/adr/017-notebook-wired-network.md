# 017 — Wired-first network for the cluster laptop

- **Status:** accepted
- **Date:** 2026-11-23
- **Updates:** [003](003-remote-control-node.md), which gains a second exception to "Ansible does not touch the host network"
- **Issue:** #24 (stays open until the failover test passes)

## Context

The cluster laptop (Acer, `ath10k_pci`, firmware `WLAN.TF.2.1`) carried k3s, the tailnet and remote access over Wi-Fi alone. Its Ethernet port sat without a cable.

- **2026-11-17, 21:14 to 21:48:** a power cut took the router down. The node had no network until 21:48. Pods could not reach the API server, and some went into CrashLoopBackOff.
- **2026-11-18, 11:34, no power cut:** the Wi-Fi supplicant disconnected and reconnected at 11:36, but traffic stayed dead for about 22 minutes, until someone toggled the radio by hand. Nobody was at home to do it sooner, so remote access was lost too.
- **2026-11-22:** the cable was plugged in. The link came up at 100 Mbps, but the port only had a link-local address. The installer's netplan has `match` and `set-name` and no `dhcp4`. The default route stayed on Wi-Fi (metric 600), and k3s kept the Wi-Fi address as its node IP.

Wi-Fi power saving was on (`wifi.powersave = 3`).

## Decision

1. **The wired port carries the default route when the cable is connected.** The `host_network` role adds `dhcp4` and `dhcp6` to the installer's ethernet ID, in a separate netplan file. NetworkManager gives Ethernet a lower route metric than Wi-Fi, so the default route moves to the cable once the port has a lease. Wi-Fi remains as the standby route.
2. **The change is verified, and it can be undone.** Before applying, the role keeps the current profile, validates the new one with `netplan generate`, and arms a transient systemd timer (180 s). The timer restores the kept profile and re-applies netplan. After applying, the role waits for a default route through the cable (when a cable is connected), pings the router through it, and checks that Tailscale is `Running`. Then it stops the timer. Any failed check restores the kept profile at once. The timer is the backstop for a lost Ansible connection. It replaces the manual `netplan try`, which needs a terminal.
3. **Wi-Fi power saving is off** (`wifi.powersave = 2`), in `/etc/NetworkManager/conf.d/homelab-wifi-powersave.conf`. NetworkManager applies conf.d files in name order and the last one wins. Ubuntu ships `default-wifi-powersave-on.conf` (value 3), so the name sorts after `default-`.
4. **k3s uses the laptop's tailnet address as its node IP** (`node-ip`), with `flannel-iface: tailscale0`. The k3s unit starts after the Tailscale daemon, so the address exists at boot. The tailnet address is already a `tls-san`, so the API certificate does not change. The node IP stays the same whichever port carries the default route.
5. **No Wi-Fi watchdog for now.** A timer that restarts the radio when the gateway is unreachable would need a second exception to `no-lockout`. With the cable in use, Wi-Fi is only the standby, so the case for a watchdog is weaker. The decision is deferred. If the failover test fails, write a new ADR for it.

## Alternatives considered

- **A manual `netplan try`** (the issue's suggestion): it works, but it needs a terminal and it is not repeatable. Replaced by the timer in Ansible.
- **The wired LAN address as node IP:** the node would depend on one interface and on a DHCP reservation at the router. Rejected, because the tailnet address does not change.
- **Leaving the node IP alone:** the node IP would change when the default route moves. k3s adopts a new node IP only after a restart, so a stale IP can break the cluster even with a good route. Rejected.

## Consequences

- **Cluster networking depends on `tailscaled`.** Flannel runs over `tailscale0`, whose MTU is 1280. Pod traffic that leaves the node goes through the tailnet.
- **A new exception to `no-lockout`:** `ansible/roles/host_network/` is excluded from the hook, like the control node's Tailscale and SSH roles ([016](016-control-node-raspberry-pi.md)). The role only adds the wired profile and the Wi-Fi setting. It never removes the Wi-Fi profile, never touches Tailscale or sshd, and always arms the rollback.
- **A fixed address is optional ([ADR 018](018-wake-on-lan-from-control-node.md)).** When `host_network_static_address` is set, the wired profile carries that IPv4 address instead of DHCP, under the same rollback. IPv6 stays on DHCP, and the Wi-Fi profile is never touched.
- **Turning the role off does not undo it.** Setting `host_network_enabled: false` only stops Ansible from managing the files. To undo the change by hand, see the README.
- **The first apply restarts k3s once,** because the node IP and the unit ordering change.
- **The rollback protects the network, not k3s.** A wrong `node-ip` is not rolled back. If the node misbehaves, revert the two lines in `config.yaml.j2` and run `make apply`.
- **Wi-Fi power saving takes effect when the radio next associates.** To apply it at once, toggle the radio with the cable connected. That is the failover test.

## Follow-ups (not in this change)

- **External visibility (issue #4):** the `host-silent` alert sends mail, and mail needs the network. A check from the NAS would cover that case.
- **Cable and port:** the link negotiated 100 Mbps, although the port supports gigabit. Replace the cable or check the router port. The role warns while the speed stays below 1000 Mbps.
- **Wi-Fi watchdog:** see decision 5.
- **Unexplained `python3` in state D:** on 2026-11-18 a process stayed blocked in `Blocked by coredump` for more than 20 minutes. It has not come back. Keep watching for it.

## Verification

- `make test` (pre-commit, helm unittest, render, kubeconform, kube-linter) in WSL.
- On the device, with someone at home: `make plan`, review the diff, then `make apply` from `main`. The failover test in the README decides whether issue #24 closes.
