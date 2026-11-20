#!/usr/bin/env bash
# kustomize build for offline validation: the KSOPS generator is resolved by
# scripts/ksops-stub.py (no age key; values become placeholders).
#   kustomize-build.sh <kustomization-directory>
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

shim="$(mktemp -d)"
trap 'rm -rf "${shim}"' EXIT
printf '#!/bin/sh\nexec python3 "%s" "$@"\n' "${REPO_ROOT}/scripts/ksops-stub.py" >"${shim}/ksops"
chmod +x "${shim}/ksops"

PATH="${shim}:${PATH}" kustomize build --enable-alpha-plugins --enable-exec "$1"
