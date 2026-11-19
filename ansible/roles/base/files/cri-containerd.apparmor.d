# Managed by Ansible (homelab), role base.
#
# Default AppArmor profile for the containers (RuntimeDefault). It is the
# containerd v2.3.4 template (contrib/apparmor/template.go) rendered the way containerd
# would on this host (abi 3.0, tunables/global, abstractions/base, daemon
# unconfined), PLUS the two rules marked "stacked" and the "homelab" D-Bus rule below.
#
# Why: with kernel.apparmor_restrict_unprivileged_unconfined=1 (Ubuntu 26.04,
# kernel 7.0.0-42+) runc's change_onexec turns into stacking and the container's
# processes get the label "cri-containerd.apparmor.d//&unconfined". The peer
# without the suffix does not match, and signals between processes of the same container are
# denied: Postgres (CNPG) hangs in recovery and fills up the connections.
#
# containerd does not generate its own profile when one with this name is
# already loaded, and apparmor.service loads this file at boot, before k3s.
#
# Remove once k3s ships a containerd with the fix:
#   https://github.com/containerd/containerd/issues/14485
#   https://github.com/containerd/containerd/pull/14487 (uses //&*; here we use
#   only the observed label, //&unconfined)

abi <abi/3.0>,

#include <tunables/global>

profile cri-containerd.apparmor.d flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>

  network,
  capability,
  file,
  umount,
  # Host (privileged) processes may send signals to container processes.
  signal (receive) peer=unconfined,
  # runc may send signals to container processes.
  signal (receive) peer=runc,
  # crun may send signals to container processes.
  signal (receive) peer=crun,
  # Manager may send signals to container processes.
  signal (receive) peer=unconfined,
  # Container processes may send signals amongst themselves.
  signal (send,receive) peer=cri-containerd.apparmor.d,
  # stacked: same peer with the stacked label (containerd#14485).
  signal (send,receive) peer="cri-containerd.apparmor.d//&unconfined",

  # homelab: system D-Bus with the host's unconfined services (dbus-daemon,
  # BlueZ). Only containers that mount the host's /run/dbus reach the bus: today only
  # Home Assistant (Bluetooth, ADR 009). Without the socket mounted, the rule opens nothing.
  dbus (send,receive) bus=system peer=(label=unconfined),

  deny @{PROC}/* w,   # deny write for all files directly in /proc (not in a subdir)
  # deny write to files not in /proc/<number>/** or /proc/sys/**
  deny @{PROC}/{[^1-9/],[^1-9/][^0-9/],[^1-9s/][^0-9y/][^0-9s/],[^1-9/][^0-9/][^0-9/][^0-9/]*}/** w,
  deny @{PROC}/sys/[^k]** w,  # deny /proc/sys except /proc/sys/k* (effectively /proc/sys/kernel)
  deny @{PROC}/sys/kernel/{?,??,[^s][^h][^m]**} w,  # deny everything except shm* in /proc/sys/kernel/
  deny @{PROC}/sysrq-trigger rwklx,
  deny @{PROC}/kcore rwklx,

  deny mount,

  deny /sys/[^f]*/** wklx,
  deny /sys/f[^s]*/** wklx,
  deny /sys/fs/[^c]*/** wklx,
  deny /sys/fs/c[^g]*/** wklx,
  deny /sys/fs/cg[^r]*/** wklx,
  deny /sys/firmware/** rwklx,
  deny /sys/devices/virtual/powercap/** rwklx,
  deny /sys/kernel/security/** rwklx,

  # allow processes within the container to trace each other,
  # provided all other LSM and yama setting allow it.
  ptrace (trace,tracedby,read,readby) peer=cri-containerd.apparmor.d,
  # stacked: same peer with the stacked label (containerd#14485).
  ptrace (trace,tracedby,read,readby) peer="cri-containerd.apparmor.d//&unconfined",
}
