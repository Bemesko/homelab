# 012 — Power for the laptop servers (lid, battery, RTC)

- **Status:** accepted
- **Date:** 2026-11-14
- **Updates:** [011](011-syncthing-nas-ansible.md), which gains a second exception to "Ansible does not touch the NAS"
- **Issue:** #15

## Context

The cluster and the NAS run on laptops with the lid closed.

- **2026-11-13, from 16:20 to 17:37:** the k3s laptop spent more than 15 min on battery, and GNOME suspended it (`sleep-inactive-battery-type 'suspend'`, 900 s). The `power` role only handled the lid in logind. The whole cluster went down: CNPG lost its lease, the collector dropped data and Loki rejected 1h of late logs.
- **NAS (ThinkPad T400):** the closed lid with `HandleLidSwitch=suspend`, plus the sleep targets that OMV masks, produce about 1,600 lines per hour of "Failed to execute suspend operation: Permission denied". That is 79% of the Loki errors.

Issue #15 asks to:
- never suspend, on AC or on battery;
- cap the charge at 80–90%;
- shut down safely on low battery;
- preferably, power back on by itself when power returns.

Hardware constraints:
- **Acer A515-51G (BIOS V2.02):** `acer_wmi` does not expose `charge_control_end_threshold`. The battery WMI GUID (`79772EC5-…`) exists, but the SSDT `WMBE` method only implements function 0x13 (read information). Functions 20 and 21, which read and write the Acer Care Center "health mode", fall through to `default` and return an error. Tested on 2026-11-14 with [acer-wmi-battery](https://github.com/frederik-h/acer-wmi-battery) v0.2.0 through DKMS: `modprobe` fails with "buffer of unexpected length 4", the same as upstream issue #55 (a TravelMate of the same generation). UPower ships with `CriticalPowerAction=HybridSleep` at 2%.
- **T400 (BIOS 3.23):** the `thinkpad_acpi` thresholds do not work on this model, and `tp_smapi` would need kernel 7.2 with headers on the system USB stick. The battery holds 2.4 of 37.4 Wh (6%).
- **Power on when AC is connected:** neither BIOS has the option. Both expose `/sys/class/rtc/rtc0/wakealarm`.

## Decision

The `power` role applies to both laptops: in the k3s play and in a `hosts: nas` play, with `nas_power_enabled`.

- **Never suspend:**
  - `HandleLidSwitch*=ignore` in logind, on AC, battery and dock;
  - the `sleep`, `suspend`, `hibernate`, `hybrid-sleep` and `suspend-then-hibernate` targets masked;
  - where there is GNOME, the system dconf locks `sleep-inactive-{ac,battery}-type='nothing'`.
- **Power guard (`homelab-power-guard.service`):** a long-running service (not a timer, so it does not write two journal lines every 30 s) reads `/sys/class/power_supply` every 30 s.
  - On battery, it logs "external power lost" once. The `host-on-battery` alert warns by email.
  - At `capacity <= power_shutdown_percent` (10%), it arms the RTC, writes a marker and shuts down through systemd, which stops k3s and Postgres in order.
  - The Acer's UPower is set to `CriticalPowerAction=PowerOff`, only as a safety net.
- **Power back on through the RTC:** before shutting down, the guard sets the RTC to `power_rtc_wake_interval` (30 min) from now. At boot, `homelab-power-gate.service` runs before the network, k3s and samba, **only if the marker exists**: if power is back, the boot continues; if not, it shuts down again and re-arms. A manual boot (no marker) is never taken down.
- **No charge limit** (item 2 of the issue): neither firmware has a mechanism, and the role installs no module and no DKMS. The batteries stay at 100% on AC, which speeds up wear, but the guard does not depend on the full capacity.
- **NAS:** the second exception to "Ansible does not touch the NAS", with the same access as ADR 011 (root SSH, `nas` group, absent in CI).

## Consequences

- **NAS battery:** it lasts less than a minute at 10%, so its shutdown is "best effort" until the battery is replaced (Sanyo 42T4654 or equivalent).
- **RTC:** powering back on depends on the BIOS waking from S5 on the RTC, which is tested with someone at home (`rtcwake -m no -s 300` + `systemctl poweroff`). Where it does not work, `power_rtc_wake_interval: 0` on that host.
  - **T400 (2026-11-14): does not wake.** The alarm stayed programmed in the chip (`/proc/driver/rtc`) and nothing cleared it on shutdown, but BIOS 3.23 ignores it in S5. The NAS uses `power_rtc_wake_interval: 0`: it shuts down safely and only comes back through the power button.
  - **Acer (2026-11-15): does not wake.** The Insyde BIOS keeps the right time in UTC and also ignores the alarm in S5. The BIOS's only "wake" option is Wake on LAN, which only applies to the wired NIC, and the Acer is on Wi-Fi.
  - **Result:** both hosts use `power_rtc_wake_interval: 0`, and item 5 of the issue has no hardware solution. The RTC and gate code stays in the role, tested, for a host that does wake from S5. After a low-battery shutdown, recovery is manual: open the Acer lid ("Lid Open Resume" on in the BIOS) and press the NAS power button. The alternative of a Raspberry Pi sending Wake-on-LAN when power returns is implemented in [ADR 018](018-wake-on-lan-from-control-node.md) (issue #23). Both hosts woke from it in the tests of 2026-11-23, so the RTC stays off (`power_rtc_wake_interval: 0`); the RTC and gate code stay in the role for a host that does wake from S5.
- **Boot cycles:** each gate boot on battery uses a little charge, but the shutdown happens before the network and k3s, so the drain is small.
- **Charge limit, should it ever exist:** a new NAS battery reopens `tp_smapi` (needs the kernel headers on the USB stick). A newer cluster laptop (Acer from ~2019 on) would have "health mode" through acer-wmi-battery.
