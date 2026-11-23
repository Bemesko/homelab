# 018 — Wake-on-LAN from the control node after a power cut

- **Status:** accepted. The hardware test (a host that stays off after a battery-less power cut) is still open
- **Date:** 2026-11-23
- **Updates:** [012](012-power-management.md) (the RTC cannot power the hosts on, so this replaces the manual recovery), [016](016-control-node-raspberry-pi.md) (the Pi gains a second role: the Wake-on-LAN sender)
- **Issue:** #23 (stays open until the tests pass)

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

## Alternatives considered

- **Keep the RTC:** rejected by the tests of 2026-11-14/15 (see Context).
- **Hibernate (S4) and wake from the RTC:** evaluated and rejected on 2026-11-15, recorded in issue #23. The NAS has no swap or battery for it, the Acer has no `resume=`, and a resumed node reproduces the incident of 2026-11-13.
- **A watchdog on the hosts:** a host-side service would need to stay up on a dead host, which is the case we cannot cover. The Pi is the only device that is up when the power comes back.
- **A timer that runs all the time:** rejected. A "wake whoever does not answer" loop would power on a host that was switched off on purpose for maintenance.
- **Running the sender on the cluster:** the cluster is down when the power is out. The Pi boots on its own.

## Consequences

- **The Pi restarts for other reasons, and it wakes the hosts.** Any reboot of the Pi (a kernel update, a power blip that does not cut the hosts) starts the 15-minute window. A host that was turned off on purpose is powered on in that window. The unattended upgrades on the Pi do not reboot it (no `Automatic-Reboot`), so a reboot is always someone's action. **Accepted.** If it bothers, the next step is a file that the operator creates before a planned shutdown, which the script respects.
- **Battery-less cut (the G3 case from the issue):** many BIOSes re-arm Wake-on-LAN only on the next boot, so a host whose battery is empty may not wake. The NAS is the likeliest case: its battery has 6% of its capacity and lasts under a minute. The test in the README decides this. If it fails, the NAS stays a manual case, and the alert below will say so.
- **Wi-Fi does not wake.** The laptop needs its cable, and the Pi sends the packet through its own wired port.
- **The alert needs Loki, and Loki runs on the laptop.** The `wol-host-no-answer` alert (warning) fires when the Pi logs "did not answer". If the laptop itself is the host that did not wake, Loki is down too, so the alert then only covers the NAS. The log also stays in the Pi's journal (`journalctl -t homelab-wol`).
- **No new exception to `no-lockout`.** The `wol_sender` role sends UDP packets and touches no Tailscale, SSH or firewall setting. The laptop's `wakeonlan` change sits in the `host_network` role, which already has its exception ([ADR 017](017-notebook-wired-network.md)).
- **The MAC and the LAN address are private.** They stay in `ansible/inventory/local.yaml` (ignored by git), like the other host data.

## Verification

- `make test` (pre-commit, ansible-lint, helm, render) in WSL.
- The sender script with a fake host list and a fake ping (`HOMELAB_WOL_*`, `--dry-run`).
- On the device, with someone at home, from `main`: `make plan`, then `make apply` for the laptop (the netplan change runs the rollback), then `make control-node` on the Pi, twice (the second run must show `changed=0`).
- Cold test per host: power off the NAS, then `sudo /usr/local/sbin/homelab-wol --once` on the Pi, and check the host comes back (about 6 min for the NAS, 5 for the laptop). Repeat for the laptop.
- The full test from issue #23: the whole house without power for a while, then back on, and both hosts return with nobody touching them.
