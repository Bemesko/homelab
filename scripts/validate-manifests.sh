#!/usr/bin/env bash
# Validates manifests against the Kubernetes schemas and best practices.
#   validate-manifests.sh            -> repo manifests (pre-commit)
#   validate-manifests.sh upstream   -> rendered upstream charts (CI, needs network)
# The schemas are downloaded on the first run and cached in .cache/kubeconform.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
# Same minor as the k3s pinned in ansible/group_vars/all/main.yaml
readonly KUBERNETES_VERSION="1.37.0"
readonly CACHE_DIR="${REPO_ROOT}/.cache/kubeconform"
readonly CRD_SCHEMAS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

mkdir -p "${CACHE_DIR}"

kubeconform_args=(
  -strict
  -summary
  -kubernetes-version "${KUBERNETES_VERSION}"
  -cache "${CACHE_DIR}"
  -schema-location default
  -schema-location "${CRD_SCHEMAS}"
  # The catalog's ObjectStore (Barman Cloud plugin) predates v0.16: it lacks
  # s3AddressingStyle and zstd for data. The CRD in the cluster validates it on apply.
  -skip ObjectStore
)

case "${1:-local}" in
  local)
    "${REPO_ROOT}/scripts/render-manifests.sh" local | kubeconform "${kubeconform_args[@]}" -
    while read -r dir; do
      "${REPO_ROOT}/scripts/kustomize-build.sh" "${dir}" |
        kube-linter lint --config "${REPO_ROOT}/.kube-linter.yaml" -
    done < <(find "${REPO_ROOT}/kubernetes/workloads" -name kustomization.yaml -printf '%h\n' | sort)
    ;;
  upstream)
    # Third-party CRDs without a schema in the catalog must not block; core resources stay strict.
    "${REPO_ROOT}/scripts/render-manifests.sh" upstream |
      kubeconform "${kubeconform_args[@]}" -ignore-missing-schemas -
    ;;
  *)
    echo "usage: $0 [local|upstream]" >&2
    exit 2
    ;;
esac
