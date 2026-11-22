#!/usr/bin/env bash
# e2e (CI) assertions against the runner's local k3s.
# Usage: scripts/e2e-assert.sh [lite|full]   (default: full)
#   lite: what the host bootstrap owns (node, ArgoCD, root app, KSOPS). Runs on PRs that touch the bootstrap.
#   full: also every Application Healthy and the apps/observability pipeline. Runs nightly (docs/adr/015).
# Per-app health is not a merge gate: ArgoCD already follows `main`, and an unhealthy app shows up as an alert.
set -euo pipefail

profile="${1:-full}"
case "${profile}" in
  lite | full) ;;
  *)
    echo "Usage: $0 [lite|full]" >&2
    exit 2
    ;;
esac

kubectl() { sudo /usr/local/bin/k3s kubectl "$@"; }

echo "==> profile: ${profile}"
echo "==> node Ready"
kubectl wait --for=condition=Ready node --all --timeout=300s

apps=(root argocd hello-world)
if [[ "${profile}" == "full" ]]; then
  apps=(root argocd hello-world cloudnative-pg cert-manager barman-cloud-plugin immich-database immich obsidian home-assistant-database home-assistant k8s-app-smoke grocery-ops prometheus loki tempo observability otel-gateway otel-agent grafana opencost)
fi
for app in "${apps[@]}"; do
  echo "==> Application ${app} Synced + Healthy"
  kubectl -n argocd wait "application/${app}" --for=create --timeout=300s
  kubectl -n argocd wait "application/${app}" --for=jsonpath='{.status.sync.status}'=Synced --timeout=600s
  kubectl -n argocd wait "application/${app}" --for=jsonpath='{.status.health.status}'=Healthy --timeout=600s
done

echo "==> Tailscale Operator absent in CI"
if kubectl -n argocd get application/tailscale-operator >/dev/null 2>&1; then
  echo "ERROR: tailscale-operator should not exist with tailscaleOperator.enabled=false" >&2
  exit 1
fi

echo "==> hello-world answers through its Service"
kubectl -n hello-world rollout status deployment/hello-world --timeout=300s
body="$(kubectl get --raw /api/v1/namespaces/hello-world/services/hello-world:http/proxy/)"
grep -q '^Hostname: hello-world-' <<<"${body}" || {
  echo "ERROR: unexpected response from hello-world:" >&2
  echo "${body}" >&2
  exit 1
}
echo "==> KSOPS: demo Secret decrypted by ArgoCD"
message="$(kubectl -n hello-world get secret hello-world-demo -o jsonpath='{.data.message}' | base64 -d)"
if [[ "${message}" != "hello from KSOPS" ]]; then
  echo "ERROR: unexpected hello-world-demo.message: '${message}'" >&2
  exit 1
fi

if [[ "${profile}" == "lite" ]]; then
  echo "OK: e2e (lite) passed."
  exit 0
fi

echo "==> Immich Postgres (CNPG) ready with the extensions"
kubectl -n immich wait cluster.postgresql.cnpg.io/immich-database --for=condition=Ready --timeout=600s
kubectl -n immich wait database.postgresql.cnpg.io/immich-database --for=jsonpath='{.status.applied}'=true --timeout=300s

echo "==> Immich answers /api/server/ping"
kubectl -n immich rollout status deployment/immich-server --timeout=600s
ping="$(kubectl get --raw /api/v1/namespaces/immich/services/immich-server:http/proxy/api/server/ping)"
grep -q '"res":"pong"' <<<"${ping}" || {
  echo "ERROR: unexpected response from Immich: ${ping}" >&2
  exit 1
}

echo "==> Obsidian (Selkies) serves the web page"
kubectl -n obsidian rollout status deployment/obsidian --timeout=600s
page="$(kubectl get --raw /api/v1/namespaces/obsidian/services/obsidian:http/proxy/)"
grep -qi '<html' <<<"${page}" || {
  echo "ERROR: unexpected response from Obsidian:" >&2
  head -c 500 <<<"${page}" >&2
  exit 1
}

echo "==> Home Assistant Postgres (CNPG) ready"
kubectl -n home-assistant wait cluster.postgresql.cnpg.io/home-assistant-database --for=condition=Ready --timeout=600s

echo "==> Home Assistant serves /manifest.json"
kubectl -n home-assistant rollout status deployment/home-assistant --timeout=900s
# From inside the pod: the API proxy adds X-Forwarded-For, and HA answers 400 to
# untrusted proxies (trust is configured through the UI, see ADR 009).
manifest="$(kubectl -n home-assistant exec deployment/home-assistant -c home-assistant -- \
  python3 -c 'import urllib.request; print(urllib.request.urlopen("http://127.0.0.1:8123/manifest.json").read().decode())')"
grep -q "Home Assistant" <<<"${manifest}" || {
  echo "ERROR: unexpected response from Home Assistant:" >&2
  head -c 500 <<<"${manifest}" >&2
  exit 1
}

echo "==> External app (repotpl-k8s-app) in the homelab-apps AppProject answers /healthz"
project="$(kubectl -n argocd get application/k8s-app-smoke -o jsonpath='{.spec.project}')"
if [[ "${project}" != "homelab-apps" ]]; then
  echo "ERROR: k8s-app-smoke is in project '${project}', expected homelab-apps" >&2
  exit 1
fi
kubectl -n k8s-app-smoke rollout status deployment/app-template --timeout=300s
health="$(kubectl get --raw /api/v1/namespaces/k8s-app-smoke/services/app-template:http/proxy/healthz)"
if [[ "${health}" != "ok" ]]; then
  echo "ERROR: unexpected response from the external app: '${health}'" >&2
  exit 1
fi

echo "==> grocery-ops (Bemesko/grocery-ops, Nuxt) answers /healthz"
kubectl -n grocery-ops rollout status deployment/grocery-ops --timeout=300s
health="$(kubectl get --raw /api/v1/namespaces/grocery-ops/services/grocery-ops:http/proxy/healthz)"
if [[ "${health}" != "ok" ]]; then
  echo "ERROR: unexpected response from grocery-ops: '${health}'" >&2
  exit 1
fi

echo "==> Observability: Grafana answers /api/health"
kubectl -n observability rollout status deployment/grafana --timeout=600s
grafana="$(kubectl get --raw /api/v1/namespaces/observability/services/grafana:80/proxy/api/health)"
grep -q '"database": *"ok"' <<<"${grafana}" || {
  echo "ERROR: unexpected response from Grafana: ${grafana}" >&2
  exit 1
}

# retry <description> <command...>: the pipeline (agent -> gateway -> backend) takes a few minutes.
retry() {
  local what="$1" _
  shift
  for _ in $(seq 1 30); do
    if "$@"; then return 0; fi
    sleep 10
  done
  echo "ERROR: ${what} did not show up within 5 min" >&2
  return 1
}

# prom_has <query>: Prometheus returns at least one series (a query without special characters).
prom_has() {
  kubectl get --raw "/api/v1/namespaces/observability/services/prometheus-server:80/proxy/api/v1/query?query=$1" |
    grep -q '"result":\[{'
}
echo "==> Observability: Kubernetes metrics (ADR 013) reached Prometheus over OTLP"
retry "kube_pod_info (kube-state-metrics) no Prometheus" prom_has 'count(kube_pod_info)'
retry "container_cpu_usage_seconds_total (cAdvisor) no Prometheus" prom_has 'count(container_cpu_usage_seconds_total)'
echo "==> OpenCost: the exporter starts and computes the node cost"
kubectl -n opencost rollout status deployment/opencost --timeout=600s
retry "node_total_hourly_cost (OpenCost) no Prometheus" prom_has 'count(node_total_hourly_cost)'

# sum(): without it the query returns one series per stream and Loki rejects it (400) past
# 500 series, which a busy ArgoCD reaches in 10 min.
loki_has_argocd_logs() {
  kubectl get --raw '/api/v1/namespaces/observability/services/loki:3100/proxy/loki/api/v1/query?query=sum(count_over_time(%7Bk8s_namespace_name%3D%22argocd%22%7D%5B10m%5D))' |
    grep -q '"result":\[{'
}
echo "==> Observability: ArgoCD pod logs reached Loki over OTLP"
retry "logs do namespace argocd no Loki" loki_has_argocd_logs

echo "==> Observability: synthetic trace (telemetrygen -> otel-agent -> gateway -> Tempo)"
kubectl -n observability delete job e2e-telemetrygen --ignore-not-found
kubectl -n observability create job e2e-telemetrygen \
  --image=ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:v0.163.0@sha256:569b79a39f8313db839a727e8eac161c66b8a6c2e633f2da4ad352ce7b383c23 \
  -- /telemetrygen traces --otlp-endpoint=otel-agent.observability.svc:4317 --otlp-insecure --traces=5 --service=e2e-telemetrygen
kubectl -n observability wait job/e2e-telemetrygen --for=condition=Complete --timeout=300s
tempo_has_trace() {
  kubectl get --raw '/api/v1/namespaces/observability/services/tempo:3200/proxy/api/search?tags=service.name%3De2e-telemetrygen' |
    grep -q '"traceID"'
}
retry "trace do e2e-telemetrygen no Tempo" tempo_has_trace

echo "==> Observability: the Grafana sidecar loaded every dashboard and alert rule"
# The expected files come from the repo itself (community + own dashboards, and the
# rules in alerts/). The sidecar writes each ConfigMap into the Grafana volume.
expected_dashboards="$(find kubernetes/workloads/observability/base/dashboards -mindepth 2 -name '*.json' -not -path '*/patches/*' | wc -l)"
expected_alert_files="$(find kubernetes/workloads/observability/base/alerts -name '*.yaml' | wc -l)"
sidecar_loaded_everything() {
  local dashboards alerts
  dashboards="$(kubectl -n observability exec deploy/grafana -c grafana-sc-dashboard -- find /tmp/dashboards -name '*.json' | wc -l)"
  alerts="$(kubectl -n observability exec deploy/grafana -c grafana-sc-alerts -- ls /etc/grafana/provisioning/alerting | grep -c 'yaml')"
  [[ "${dashboards}" -ge "${expected_dashboards}" && "${alerts}" -ge "${expected_alert_files}" ]]
}
retry "${expected_dashboards} dashboards e ${expected_alert_files} arquivos de alerta no sidecar" sidecar_loaded_everything

echo "OK: e2e passed."
