#!/usr/bin/env bash
# Renders manifests for validation (stdout, multi-document).
#   render-manifests.sh local     -> app-of-apps chart (Tailscale/NAS on/off) + workload kustomize (offline, KSOPS through the stub)
#   render-manifests.sh upstream  -> upstream charts (argo-cd, tailscale-operator, cloudnative-pg, immich, prometheus, loki, tempo, grafana, otel-agent/otel-gateway, opencost) with our values (needs network)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly APPS_CHART="${REPO_ROOT}/kubernetes/apps"

# chart_field <chart-key> <field> -> reads kubernetes/apps/values.yaml (single source of the versions)
chart_field() {
  helm show values "${APPS_CHART}" | awk -v chart="$1" -v field="$2" '
    /^charts:/ { in_charts = 1; next }
    in_charts && /^[^[:space:]]/ { in_charts = 0 }
    in_charts && $0 ~ "^  " chart ":" { in_chart = 1; next }
    in_chart && /^  [^[:space:]]/ { in_chart = 0 }
    in_chart && $1 == field ":" { print $2; exit }
  '
}

# workload_dirs -> every kustomization in kubernetes/workloads/<app>/{base,overlays/*}
workload_dirs() {
  find "${REPO_ROOT}/kubernetes/workloads" -name kustomization.yaml -printf '%h\n' | sort
}

render_local() {
  helm template apps "${APPS_CHART}"
  echo "---"
  helm template apps "${APPS_CHART}" --set tailscaleOperator.enabled=false --set nasStorage.enabled=false \
    --set smokeApp.enabled=true
  echo "---"
  # The off-site backup Application is off by default (offsiteBackup.enabled=false, ADR 019): render it
  # anyway so its manifest keeps being validated until it is activated.
  helm template apps "${APPS_CHART}" --set offsiteBackup.enabled=true --show-only templates/backup.yaml
  echo "---"
  # An example external app, to validate the Application template (apps: {} by default)
  helm template apps "${APPS_CHART}" \
    --set apps.example.repoURL=https://github.com/bernats-homelab/example \
    --set apps.example.targetRevision=v1.0.0 \
    --show-only templates/external-apps.yaml
  local dir
  while read -r dir; do
    echo "---"
    "${REPO_ROOT}/scripts/kustomize-build.sh" "${dir}"
  done < <(workload_dirs)
}

render_upstream() {
  # Isolates helm from the repos configured by the user (hermetic render).
  local helm_home
  helm_home="$(mktemp -d)"
  trap 'rm -rf "${helm_home}"' RETURN
  export HELM_REPOSITORY_CONFIG="${helm_home}/repositories.yaml"
  export HELM_REPOSITORY_CACHE="${helm_home}/cache"
  export HELM_REGISTRY_CONFIG="${helm_home}/registry.json"

  # chart-key:release:namespace, same as the Applications in kubernetes/apps/templates.
  # A chart can have more than one release (opentelemetryCollector: agent and gateway).
  local entry key release namespace repo chart
  local releases=(
    argocd:argocd:argocd
    tailscaleOperator:tailscale-operator:tailscale
    cloudnativePg:cloudnative-pg:cnpg-system
    barmanCloudPlugin:barman-cloud-plugin:cnpg-system
    certManager:cert-manager:cert-manager
    rustfs:rustfs:rustfs
    immich:immich:immich
    prometheus:prometheus:observability
    loki:loki:observability
    tempo:tempo:observability
    grafana:grafana:observability
    opentelemetryCollector:otel-agent:observability
    opentelemetryCollector:otel-gateway:observability
    opencost:opencost:opencost
  )
  for entry in "${releases[@]}"; do
    IFS=: read -r key release namespace <<<"${entry}"
    repo="$(chart_field "${key}" repoURL)"
    chart="$(chart_field "${key}" chart)"
    # OCI charts are referenced directly (oci://registry/path/chart), without --repo.
    local source=(--repo "${repo}" "${chart}")
    [[ "${repo}" == oci://* ]] && source=("${repo}/${chart}")
    echo "---"
    helm template "${release}" "${source[@]}" \
      --namespace "${namespace}" \
      --version "$(chart_field "${key}" version)" \
      --values "${REPO_ROOT}/kubernetes/values/${release}.yaml" \
      --include-crds
  done
}

case "${1:-}" in
  local) render_local ;;
  upstream) render_upstream ;;
  *)
    echo "usage: $0 local|upstream" >&2
    exit 2
    ;;
esac
