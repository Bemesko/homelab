# 013 — Kubernetes metrics in the Prometheus format (and OpenCost)

- **Status:** accepted
- **Date:** 2026-11-17
- **Updates:** [008](008-observability-otel-lgtm.md), in the decision to use only native OTel metrics for Kubernetes

## Context

We want OpenCost to know the cost of each namespace, pod and node. It queries Prometheus with the ecosystem's names: real CPU and memory usage from cAdvisor (`container_cpu_usage_seconds_total`, `container_memory_working_set_bytes`) and the object state from kube-state-metrics (`kube_*`). ADR 008 had left both out, to keep only the OTel metrics (`kubeletstats` and `k8s_cluster`).

That choice was already expensive:
- **Patches:** seven `jq` patches (21 translations or panel removals) to adapt community dashboards.
- **Own dashboards:** `cluster.json` was written by hand, because no community dashboard uses the `k8s_*` names.
- **Alerts:** the Kubernetes rules were rewritten for OTel names that still change between collector versions (`*_cpu_utilization_ratio` became `*_cpu_usage`).
- **Tooling:** everything that assumes the Prometheus format (OpenCost, mixin dashboards and alerts) does not work without translation.

## Decision

**The transport from 008 does not change; the semantics of the Kubernetes metrics do.** Everything still goes over OTLP (`otel-agent` → `otel-gateway` → Prometheus), and the backends still do not scrape. What the `otel-agent` now scrapes:
- **kube-state-metrics** (job `kube-state-metrics`): a subchart of the Prometheus chart, with the image by digest. Only the collectors that OpenCost, the dashboards and the alerts use, with `kube_pod_labels`/`kube_namespace_labels` allowed, because OpenCost aggregates cost by label.
- **cAdvisor** (job `kubernetes-nodes-cadvisor`): the node's own kubelet `/metrics/cadvisor`, with the ServiceAccount token (RBAC rule `nodes/metrics`) and a series allowlist.
- **OpenCost** (job `opencost`): with `honor_labels: true`, because its metrics carry their own `instance` and `namespace`.
- The three jobs carry `cluster=homelab`, like the agent's other jobs; it is the label the community dashboards filter on.

**`kubeletstats` (the agent's `kubeletMetrics` preset) and `k8s_cluster` (the gateway's `clusterMetrics` preset) go away.** Neither can coexist with cAdvisor: `kubeletstats` emits `container_memory_working_set_bytes` with `k8s_*` labels, under the same name as cAdvisor, and would duplicate the series. Hosts and the NAS keep `hostmetrics`, without node-exporter.

**OpenCost** (chart 2.5.34, app 1.121.4, images with the chart's own digests):
- **Placement:** namespace `opencost`, sync-wave 3, reading `prometheus-server.observability.svc`.
- **UI:** on the tailnet as `opencost`, no login (only whoever is already on the tailnet), and not exposed in CI.
- **Prices:** `customPricing` on, with the values from OpenCost's own `default.json` (GCP us-central1 reference, in USD per hour). Without it the exporter only emits the PV cost and no `node_*_hourly_cost` (the log shows `No pricing found for key=default`); CI caught that on the first push. The chart ships other example values (CPU 1.25, storage 0.25), which are not the OpenCost defaults. The absolute values are a cloud reference, not the laptop's real cost, but the proportion between apps holds.
- **`emitKsmV1MetricsOnly`:** emits only the v1 metrics that kube-state-metrics 2 does not have, so `kube_*` is not duplicated.

**Migrating the consumers:**
- **Alerts:** the 8 in `kubernetes.yaml`, the restarts one and the `pipeline-dead` sentinel go back to the kubernetes-mixin expressions, keeping their `uid`s. The `info` alert `kube-state-metrics-missing` is added.
- **Dashboards:** `pods` (20944) and our own `cluster.json` go away, and dotdc's *Namespaces* (15758) and *Pods* (15760) come in, plus *OpenCost / Overview* (22208). The `cnpg` and `argocd` patches lose their `kube_*` translations, and the Immich dashboard now uses cAdvisor.
- **dotdc's *Global* dashboard (15757), left out:** its node panels depend on node-exporter, which we do not install. The `host` dashboard remains the node view.

## Consequences

- **History:** the old `k8s_*` series stay for up to 30 days, but no panel queries them. The new dashboards and alerts start without history.
- **Series:** cAdvisor and kube-state-metrics grow the Prometheus head (15.9k series before). Check `prometheus_tsdb_head_series` after the deploy and tighten the allowlist if it goes above ~40k.
- **Stable names:** `kube_*` and `container_*` are the ecosystem standard and no longer change with each collector version. The cost of dashboard patches drops.
- **PVCs:** `kubelet_volume_stats_*` is still missing (`local-path` does not report it), so the volume panels stay removed.
- **UI without login:** any device on the tailnet can see the costs. That is the same access level as Grafana, which has an admin login; consider an authenticating proxy if more people join the tailnet.
- **Resources:** OpenCost (exporter and UI) requests 30m of CPU and 160Mi of memory; kube-state-metrics, 10m and 64Mi.
