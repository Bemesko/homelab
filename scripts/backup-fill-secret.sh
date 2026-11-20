#!/usr/bin/env bash
# After `make tofu-apply`: writes RESTIC_REPOSITORY and the Storage Box known_hosts into
# the restic Secret (SOPS). Run it through `make backup-secret`, which exports the token
# and the state passphrase. The box username and FQDN only exist in the encrypted state.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly TOFU_DIR="${REPO_ROOT}/infra/hetzner"
readonly SECRET="${REPO_ROOT}/kubernetes/workloads/backup/overlays/nas/restic.sops.yaml"
readonly SSH_PORT=23

tofu -chdir="${TOFU_DIR}" init -input=false -lockfile=readonly >/dev/null
user="$(tofu -chdir="${TOFU_DIR}" output -raw storage_box_username)"
server="$(tofu -chdir="${TOFU_DIR}" output -raw storage_box_server)"

# If in doubt, compare the fingerprint with the Hetzner console (Storage Box > SSH).
known_hosts="$(ssh-keyscan -p "${SSH_PORT}" -t ed25519,rsa "${server}" 2>/dev/null)"
if [[ -z "${known_hosts}" ]]; then
  echo "ERROR: ssh-keyscan got no answer from ${server}:${SSH_PORT}" >&2
  exit 1
fi

# Path relative to the box home: the repository lives in ~/restic.
repository="sftp://${user}@${server}:${SSH_PORT}/restic"

sops set "${SECRET}" '["stringData"]["RESTIC_REPOSITORY"]' "$(jq -Rn --arg v "${repository}" '$v')"
sops set "${SECRET}" '["stringData"]["known_hosts"]' "$(jq -Rn --arg v "${known_hosts}" '$v')"
echo "OK: ${SECRET#"${REPO_ROOT}"/} updated. Review it with 'sops ${SECRET#"${REPO_ROOT}"/}' and commit."
