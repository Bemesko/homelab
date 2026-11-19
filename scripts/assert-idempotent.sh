#!/usr/bin/env bash
# Runs ansible-playbook with the given arguments and fails if any task reports a change.
# Usage: scripts/assert-idempotent.sh site.yaml [ansible-playbook args...]
set -euo pipefail

log="$(mktemp)"
trap 'rm -f "${log}"' EXIT

ansible-playbook "$@" | tee "${log}"

# Strips ANSI colors (ANSIBLE_FORCE_COLOR) and keeps only the PLAY RECAP lines
recap="$(sed -E 's/\x1b\[[0-9;]*m//g' "${log}" | grep -E '^[^ ]+[[:space:]]+: ok=' || true)"

if [[ -z "${recap}" ]]; then
  echo "ERROR: PLAY RECAP not found in the output." >&2
  exit 1
fi
if grep -qvE 'changed=0[[:space:]]' <<<"${recap}"; then
  echo "ERROR: the playbook is not idempotent (changed > 0 on the second run)." >&2
  exit 1
fi
echo "OK: second run without changes."
