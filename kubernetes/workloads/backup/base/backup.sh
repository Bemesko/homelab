#!/bin/sh
# NAS off-site backup (ADR 019). Runs in the restic/restic image (Alpine, busybox sh).
#   /config  RESTIC_REPOSITORY, RESTIC_PASSWORD and, in production, id_ed25519 + known_hosts
#   /source  what goes into the backup (root of the NAS SSD, read-only NFS)
#   /cache   restic cache (indexes and trees; speeds up incremental runs)
# Each step logs a JSON line {"message_type":"homelab",...}; `restic backup` logs its
# own summary. The alerts (observability/base/alerts/backup.yaml) read these lines in Loki.
set -eu

export RESTIC_REPOSITORY_FILE=/config/RESTIC_REPOSITORY
export RESTIC_PASSWORD_FILE=/config/RESTIC_PASSWORD
export RESTIC_CACHE_DIR=/cache

log() { printf '{"message_type":"homelab","step":"%s","msg":"%s"}\n' "$1" "$2"; }

# SFTP to the Storage Box (port 23 in RESTIC_REPOSITORY). ssh refuses a key readable by
# others, so the copy goes to HOME (emptyDir) with 0600.
if [ -f /config/id_ed25519 ]; then
  mkdir -p "${HOME}/.ssh"
  cp /config/id_ed25519 "${HOME}/.ssh/id_ed25519"
  chmod 600 "${HOME}/.ssh/id_ed25519"
  set -- -o "sftp.args=-i ${HOME}/.ssh/id_ed25519 -o UserKnownHostsFile=/config/known_hosts -o StrictHostKeyChecking=yes -o ServerAliveInterval=60"
fi

if ! restic "$@" cat config >/dev/null 2>&1; then
  log init "repository not found; creating it"
  restic "$@" init
fi

# Locks left by killed runs (activeDeadlineSeconds in the middle of the initial upload).
restic "$@" unlock

log backup "start"
status=0
restic "$@" backup /source --host nas --tag nas --exclude-caches --json --quiet || status=$?
case "${status}" in
  0) log backup "ok" ;;
  # 3 = snapshot created, but some file could not be read: go on to retention and fail
  # the Job at the end so it shows up in the alert.
  3) log backup "incomplete snapshot: unreadable files (see the errors above)" ;;
  *)
    log backup "failed with code ${status}"
    exit "${status}"
    ;;
esac

# Retention: 7 daily, 4 weekly, 6 monthly. The prune (pack rewrite) only runs on
# Sundays, together with a check of 5% of the data.
log forget "start"
if [ "$(date +%u)" = "7" ]; then
  restic "$@" forget --host nas --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
  log check "start"
  restic "$@" check --read-data-subset=5%
  log check "ok"
else
  restic "$@" forget --host nas --keep-daily 7 --keep-weekly 4 --keep-monthly 6
fi
log forget "ok"

log end "backup finished with code ${status}"
exit "${status}"
