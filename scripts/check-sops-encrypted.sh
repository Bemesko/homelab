#!/usr/bin/env bash
# Fails if any *.sops.yaml is not encrypted by SOPS:
#   - it must have the `sops:` metadata block with `mac: ENC[...]`
#   - every scalar value outside the `sops:` block must be `ENC[...]`, except the
#     top-level keys allowed by the file's own `unencrypted_regex` (KSOPS manifests)
#   - it must have at least one `ENC[...]` value
#   - the CI test key (public, tests/ci-age.key) may only be a recipient
#     of the demo files in kubernetes/workloads/hello-world/
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly CI_DEMO_PATH='(^|/)kubernetes/workloads/hello-world/'
CI_RECIPIENT="$(sed -nE 's/^# public key: (age1[0-9a-z]+)$/\1/p' "${REPO_ROOT}/tests/ci-age.key")"
readonly CI_RECIPIENT

status=0
for file in "$@"; do
  if ! grep -qE '^sops:' "${file}" || ! grep -qE '^[[:space:]]+mac: ENC\[' "${file}"; then
    echo "ERROR: ${file} has no SOPS metadata (sops/mac). Run: sops encrypt --in-place ${file}" >&2
    status=1
    continue
  fi
  if grep -qE '^[[:space:]]+encrypted_regex:' "${file}"; then
    echo "ERROR: ${file} uses encrypted_regex; use unencrypted_regex (rules in .sops.yaml)" >&2
    status=1
    continue
  fi
  if [[ -n "${CI_RECIPIENT}" ]] && grep -qF "recipient: ${CI_RECIPIENT}" "${file}" && ! [[ "${file}" =~ ${CI_DEMO_PATH} ]]; then
    echo "ERROR: ${file} is encrypted for the PUBLIC CI test key (tests/ci-age.key)." >&2
    echo "       It is only allowed in kubernetes/workloads/hello-world/. Run: sops updatekeys ${file}" >&2
    status=1
    continue
  fi
  unencrypted="$(sed -nE 's/^[[:space:]]+unencrypted_regex: (.*)$/\1/p' "${file}")"
  plaintext="$(awk -v unencrypted="${unencrypted}" '
    /^sops:/ { in_sops = 1; next }
    /^[^[:space:]#]/ {
      in_sops = 0
      top = $0; sub(/:.*/, "", top)
      skip = (unencrypted != "" && top ~ unencrypted)
    }
    in_sops || skip { next }
    /^[[:space:]]*(#|$)/ { next }
    /^[[:space:]]*-?[[:space:]]*[^:]+:[[:space:]]*$/ { next }
    /:[[:space:]]+ENC\[/ { encrypted++; next }
    /^[[:space:]]*-[[:space:]]+ENC\[/ { encrypted++; next }
    { print FILENAME ":" NR }
    END { if (!encrypted) print FILENAME ":no-encrypted-values" }
  ' "${file}")"
  if [[ -n "${plaintext}" ]]; then
    echo "ERROR: plaintext values in ${file} (lines: ${plaintext//$'\n'/, })" >&2
    status=1
  fi
done
exit "${status}"
