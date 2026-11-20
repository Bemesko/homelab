#!/usr/bin/env bash
# fmt + validate of the OpenTofu directories without a token or state: init without a
# backend, only with the providers in .terraform.lock.hcl (cached in .cache/tofu-plugins).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
export TF_PLUGIN_CACHE_DIR="${REPO_ROOT}/.cache/tofu-plugins"
# validate does not read the state, but the encryption config requires the variable (pbkdf2: >= 16 chars).
export TF_VAR_state_passphrase="validate-only-passphrase"
mkdir -p "${TF_PLUGIN_CACHE_DIR}"

tofu fmt -check -recursive "${REPO_ROOT}/infra"
while read -r dir; do
  tofu -chdir="${dir}" init -backend=false -input=false -lockfile=readonly >/dev/null
  tofu -chdir="${dir}" validate -no-color
done < <(find "${REPO_ROOT}/infra" -name versions.tf -printf '%h\n' | sort)
