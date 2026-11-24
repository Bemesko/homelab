# 018 — Wake-on-LAN from the control node after a power cut

- **Status:** accepted. Tested on the hardware on 2026-11-23: a cold start of each host, and a full power cut with the NAS battery removed
- **Date:** 2026-11-23
- **Updates:** [012](012-power-management.md) (the RTC cannot power the hosts on, so this replaces the manual recovery), [016](016-control-node-raspberry-pi.md) (the Pi gains a second role: the Wake-on-LAN sender)
- **Issue:** #23

## Context

The cluster laptop (Acer A515-51G) and the NAS (ThinkPad T400) run with the lid closed and no suspend ([ADR 012](012-power-management.md)). When the guard shuts them down on low battery, nothing brings them back by itself:

- **RTC:** both BIOSes ignore the wake alarm in S5. The T400 failed on 2026-11-14, and the Acer on 2026-11-15, so both run with `power_rtc_wake_interval: 0`.
- **Manual recovery:** open the Acer lid ("Lid Open Resume") and press the NAS power button.
- **Wi-Fi:** the Acer's Wi-Fi does not wake from S5, so Wake-on-LAN needs the cable, which the laptop has since 2026-11-22 ([ADR 017](017-notebook-wired-network.md)).

The control node (Raspberry Pi 3B, [ADR 016](016-control-node-raspberry-pi.md)) is wired, lives in the house and has no power button: it boots as soon as it gets power. So its boot is a signal that the power is back.

## Decision

1. **The control node sends the packets, once per boot.** The `wol_sender` role installs `/usr/local/sbin/homelab-wol` and a oneshot unit `homelab-wol.service`. At boot, the unit waits for the network. For 900 s, every 60 s, it pings each host in the list. A host that does not answer gets a Wake-on-LAN magic packet (UDP 9, broadcast). It stops when every host answers, or at the end of the window.
2. **Ansible only enables the unit; it never starts it.** A playbook run (`make control-node`) therefore sends no packets. The second run reports `changed=0`.
3. **The hosts come from the inventory.** Each host sets `wol_sender_mac` (its wired MAC) and `wol_sender_address` (its LAN address, pinged). The role checks the format before it writes `/etc/homelab-wol.conf`. The ping uses the LAN address, not the tailnet name: the Tailscale daemon on the NAS answers about 2 minutes after the LAN, and on the laptop even later.
4. **The laptop arms its Ethernet port.** `host_network` adds `wakeonlan: true` to the netplan profile of the wired port ([ADR 017](017-notebook-wired-network.md)). The change goes through the existing rollback (the timer, the default route, the router ping and Tailscale). The role also checks `ethtool` for `Wake-on: g` and only warns if it is missing.
5. **The NAS is configured by hand.** Its BIOS and the OMV UI (Wake on LAN on the interface) are not managed by Ansible, as in [ADR 011](011-syncthing-nas-ansible.md).
6. **The boot is the window.** The sender runs only in the window after its own boot, so a host that is off for maintenance is not woken by a later playbook run, but it is woken if the Pi itself restarts (see the consequences).
7. **The addresses are fixed on the hosts, not reserved at the router.** The control node pings the LAN address, so it must not change.
   - **Laptop:** `host_network_static_address` (CIDR), `host_network_static_gateway` and optionally `host_network_static_nameservers` in the inventory. The `host_network` role replaces DHCP for IPv4 on the wired port with that address, under the same rollback ([ADR 017](017-notebook-wired-network.md)). The role checks that the address equals `wol_sender_address`, so the two cannot drift apart.
   - **NAS:** fixed by hand in the OMV UI. Ansible does not touch the NAS network. It already had a fixed address from its first setup, which kept working through a change of internet provider.
   - **Both** addresses must lie outside the router's DHCP range, or the router may give the same address to another device. The router's panel was not reachable, so the laptop got `.200`, far above the addresses the router hands out in practice, and the risk of a collision is accepted.
8. **The Pi must lose power when the house does.** Its boot is the signal that the power is back, so it cannot sit on a UPS, nor on the USB port of a modem that gets one: it would never reboot, and the window would never open. It runs from its own wall adapter (5 V, 2.5 A) on the same mains as the hosts. The modem's USB port also left it undervoltage (`vcgencmd get_throttled` showed `0x50005`).

## Alternatives considered

- **Keep the RTC:** rejected by the tests of 2026-11-14/15 (see Context). Both hosts woke from Wake-on-LAN in the tests below, so the RTC stays off (`power_rtc_wake_interval: 0`).
- **Hibernate (S4) and wake from the RTC:** evaluated and rejected on 2026-11-15, recorded in issue #23. The NAS has no swap or battery for it, the Acer has no `resume=`, and a resumed node reproduces the incident of 2026-11-13.
- **A watchdog on the hosts:** a host-side service would need to stay up on a dead host, which is the case we cannot cover. The Pi is the only device that is up when the power comes back.
- **A timer that runs all the time:** rejected. A "wake whoever does not answer" loop would power on a host that was switched off on purpose for maintenance.
- **Running the sender on the cluster:** the cluster is down when the power is out. The Pi boots on its own.
- **The Pi on a UPS, with a sentinel:** the Pi would ping a device on a plain outlet (a smart plug, a speaker) and open the window when it comes back after being down. It works wherever the Pi is plugged, but it needs a continuous service and a device the flow depends on. Not done. It is the option if the Pi must stay up during a cut.
- **A UPS with a data port and NUT on the Pi:** the Pi would read the UPS state and open the window when it goes from battery back to mains. Rejected: it needs hardware that small router UPSes usually lack.

## Consequences

- **The Pi restarts for other reasons, and it wakes the hosts.** Any reboot of the Pi (a kernel update, a power blip that does not cut the hosts) starts the 15-minute window. A host that was turned off on purpose is powered on in that window. The unattended upgrades on the Pi do not reboot it (no `Automatic-Reboot`), so a reboot is always someone's action. **Accepted.** If it bothers, the next step is a file that the operator creates before a planned shutdown, which the script respects.
- **Battery-less cut (the G3 case from the issue) works on the NAS.** With its battery removed and the mains cut for about 3 minutes, the BIOS re-armed Wake-on-LAN by itself and the NAS came back. The fear that it would only re-arm on the next boot did not hold.
- **Switch the hosts off through the operating system.** The driver arms the network card at shutdown. A host switched off from the BIOS setup screen, or by holding the power button, stays unarmed and the packet does not wake it: the first attempt on the Acer failed this way. The power guard shuts down through systemd, so it arms the card.
- **The Pi has no clock battery.** It boots with the time it was switched off, a few minutes behind, until NTP syncs. The first log lines of a boot carry a stale time, and the timestamps then jump. The `answered after N s` figure uses a monotonic clock and is not affected.
- **The NAS shutdown can be slow.** It took more than 5 minutes the first time and about 3.5 minutes the second, with the SSH and the OMV UI closed long before the network stopped. The cause was not investigated. At 10% its battery lasts under a minute ([ADR 012](012-power-management.md)), so a low-battery shutdown of the NAS can still be cut short. The wake path does not depend on it: a NAS that died abruptly is the same no-power case that was tested.
- **A fixed address can collide.** Nothing stops the router from handing the same address to another device if it lies inside the DHCP range, and nothing at the router knows the hosts use it. Check the range when you pick the addresses. If the router is ever replaced, the fixed addresses must be checked against its new range.
- **The laptop depends on its fixed address being right.** A wrong gateway cuts the wired route, which the rollback of the `host_network` role detects and undoes. The tailnet keeps working through Wi-Fi, so SSH to the laptop does not depend on this address.
- **Wi-Fi does not wake.** The laptop needs its cable, and the Pi sends the packet through its own wired port.
- **The alert needs Loki, and Loki runs on the laptop.** The `wol-host-no-answer` alert (warning) fires when the Pi logs "did not answer". If the laptop itself is the host that did not wake, Loki is down too, so the alert then only covers the NAS. The log also stays in the Pi's journal (`journalctl -t homelab-wol`).
- **No new exception to `no-lockout`.** The `wol_sender` role sends UDP packets and touches no Tailscale, SSH or firewall setting. The laptop's `wakeonlan` change sits in the `host_network` role, which already has its exception ([ADR 017](017-notebook-wired-network.md)).
- **The MAC and the LAN address are private.** They stay in `ansible/inventory/local.yaml` (ignored by git), like the other host data.

## Results

Tested on 2026-11-23, with someone at home. Times come from the sender's log or from a monitor on the Pi.

- **Static checks:** `make test` (pre-commit, `ansible-lint` in the `production` profile, the alert-rule checker, `kubeconform`); the sender script in `--dry-run` with a fake host list and a fake ping; the templates rendered with sample variables.
- **NAS, cold start:** `poweroff`, then `homelab-wol` on the Pi. The BIOS first tried a network boot (`PXE-E53`, harmless) and moved on to the USB stick. SSH and the OMV UI were up in about 6 minutes.
- **Acer, cold start:** the first attempt did not wake it, because it had been switched off from the BIOS setup (see the consequences). After `systemctl poweroff` from Linux, with `Wake-on: g`, it woke. The boot began 3 min 14 s after the shutdown ended, the node was `Ready` 63 s after that, and all 45 pods were ready 8 min 34 s after the boot began.
- **Full power cut:** the Acer and the NAS were shut down with `poweroff` (the Acer first, because it mounts the NAS over NFS), the NAS battery was removed to make it a real no-power case, the Pi was shut down cleanly, and the mains was cut for about 3 minutes. When the power returned, the Pi booted and the unit started 67 s later, with the first packets within 5 s. The NAS answered a ping 62 s after the sender started, and had SSH and the OMV UI at about 111 s and 140 s. The Acer's node was `Ready` at about 166 s. Nobody touched the machines. All 45 pods were ready about 9 minutes after the sender started; none got stuck or crashed.
- **Idempotency:** the first runs after the tests (`make control-node` and `make idempotency`) reported changes in three tasks, none of them in `wol_sender`. All three are fixed in the same change as this record, and reproduced and checked in a local playbook run:
  - `control_node_base` refreshed the package lists and reported `changed` once the cache was over an hour old. It is bookkeeping, so it no longer counts.
  - `control_node_keys` added the hosts' SSH keys to `known_hosts` on every run (the Pi's file had eight copies of each). The inventory's name has capitals and `ssh-keyscan` prints it in lower case, so the module never found the entry it had written. The name and the key line are now normalized.
  - `host_network` copied the current wired profile to `previous.yaml` on every run, so the first run after a change reported `changed`. The snapshot is now taken only when the profile is about to change.

  The confirmation on the hosts (`make control-node` and `make idempotency` from `main`, with `changed=0`) is recorded in issue #23.
- **Not tested:** a power cut with the hosts running (the NAS dying abruptly, the Acer lasting about 3 hours on battery until the guard shuts it down). The guard's shutdown path was validated for real on 2026-11-20 (100% to 10%, a clean shutdown at 15:16).
- **Cable:** the laptop's wired link dropped five times in 38 seconds on 2026-11-23 at 19:58, before any change in this work, and came back after the cable was reconnected. The port still negotiates 100 Mbps, which is the follow-up already open in [ADR 017](017-notebook-wired-network.md).
