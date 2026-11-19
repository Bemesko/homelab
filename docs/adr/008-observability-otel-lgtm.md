# 008 — Observability: OpenTelemetry Collector + a lean LGTM stack

- **Status:** accepted. The semantics of the Kubernetes metrics (native OTel only) were replaced by the Prometheus format in [013](013-kubernetes-metrics-prometheus-semantics.md); the OTLP transport still stands.
- **Date:** 2026-11-07

## Context

We want logs, metrics and traces from the cluster, the laptop itself, the NAS and, later, other bare-metal hosts. There are four requirements:

- **Everything in OpenTelemetry (OTLP).** That way other backends can be tried without re-instrumenting anything.
- **CNCF or open-source projects.**
- **Lightweight, with few moving parts.** The laptop has 4 threads, 18 GB of RAM and ~37 GB of free disk.
- **Email alerts.**

## Decision

- **Collection: upstream OpenTelemetry Collector (CNCF), `otelcol-contrib` image.**
  - `otel-agent` (DaemonSet): pod logs, kubelet, OTLP from apps and scraping of the `/metrics` endpoints that already exist (ArgoCD, CNPG).
  - `otel-gateway` (Deployment): receives everything, collects cluster metrics and events, and is the **only** place that knows the backends. It is exposed on the tailnet as `otel`, the entry point for the hosts and the NAS.
  - Hosts (laptop, bare metal): the `otel_host_agent` role installs the `.deb` (journald + host metrics). The Collector image has no `journalctl`, so journald is not visible from inside the cluster.
  - NAS: a container through the OMV compose plugin (`hosts/nas/otel-collector`), with an in-memory queue only, because of the USB stick. Ansible does not touch the NAS.
- **Backends: Prometheus (native OTLP), Loki, Tempo and Grafana**, each as a single binary, on local disk (local-path).
  - Mimir is not worth it on a single node, and Prometheus 3 already accepts OTLP.
  - The backends do not scrape. Every metric comes in over OTLP. The only exception is the Tempo metrics-generator, which can only remote-write.
- **Alerts through Grafana Alerting**, with Gmail SMTP. The rules are versioned and loaded from ConfigMaps by the sidecar. The credentials and the recipient live in a SOPS Secret, only in the laptop overlay.
- **Retention sized by disk:** metrics 30 d (or 6 GB), logs 14 d and traces 7 d. That is ~18 GiB of PVCs, and an alert fires if the root disk goes above 85%.

## Alternatives considered

| | Why not (for now) |
|---|---|
| **Victoria** (VictoriaMetrics + VictoriaLogs + VictoriaTraces) | The lightest option and all Apache-2.0, but VictoriaTraces is still v0.x, with recent breaking changes. It also puts everything on a single vendor. |
| **OpenObserve** | A single binary for everything, but outside the Grafana ecosystem, with SQL queries and an AGPL license. |
| **SigNoz / ClickStack** | ClickHouse is too heavy for the laptop. |
| **100% CNCF stack** (Prometheus + Jaeger v2 + Perses) | The CNCF has no log storage, and correlating the signals gets fragmented. |
| **Grafana Alloy** | It runs the same YAML as the Collector (*OTel engine*), but that mode is still in Public Preview, and the native syntax (River) ties the config to Alloy. The upstream Collector keeps switching cheap. |

## Consequences

- **Switching backends = switching the `otel-gateway` exporters.** Agents, hosts and the NAS do not change.
- **Local disk:** the data dies with the laptop, and retention is short. Object storage (S3) is left for a later phase.
- **Metric names follow the OTLP→Prometheus translation** (`system.filesystem.usage` → `system_filesystem_usage_bytes`). `service.name` becomes the `job` label in Prometheus and `service_name` in Loki. The hosts use `homelab-host` and the NAS uses `nas-host`, so no hostnames are versioned.
- **In CI**, Grafana comes up without secrets (no SMTP and no Ingress), and the e2e checks the whole flow: metrics, logs and a synthetic trace (`telemetrygen`).
- **The Grafana charts moved to `grafana-community`.** The ones under `grafana/` are deprecated.

## Community dashboards and alerts

Dashboards and alert rules come from community projects, **without** installing kube-state-metrics, node-exporter or cAdvisor: the stack keeps to native OTel metrics only (`kubeletstats`, `k8s_cluster`, `hostmetrics`). *(Revisited on 2026-11-17 by [013](013-kubernetes-metrics-prometheus-semantics.md): kube-state-metrics and cAdvisor came in, for OpenCost and for dashboards without translation; `kubeletstats` and `k8s_cluster` went out. node-exporter is still left out.)*

- **Vendored, pinned dashboards.** `scripts/vendor-dashboards.sh` downloads each dashboard at a pinned version (grafana.com by ID and revision; ArgoCD, Loki and Tempo by tag), checks the upstream sha256 in `dashboards.lock` and applies a common filter (datasources by uid) plus one jq patch per dashboard (`patches/<name>.jq`). A generated `kustomization.yaml` creates one ConfigMap per dashboard, with the Grafana folder in the `grafana_folder` annotation. The chart's `gnetId` was left out: it downloads when the pod starts, with no hash and no patch.
- **Typical patches.** `job` comes as `service.namespace/service.name`; counters arrive with the `_total` suffix; the mixins' recording rules do not exist; and panels that depend on `kube_*`, on `kubelet_volume_stats_*` (`local-path` does not report them) or on the CNPG operator's controller-runtime are removed.
- **Two dashboards of our own** (cluster and Immich), because none from the community used the `k8s_cluster` metrics or the current Immich ones.
- **Alerts converted to Grafana**, not to Prometheus: a single path to email, with no Alertmanager. Each rule cites its origin (kubernetes-mixin, awesome-prometheus-alerts, CloudNativePG rules) and was rewritten for our names. The set is curated for a single node: HA, replicas, lag, PVC disk and backups were left out.
- **New scrapes, all over OTLP.** The `otel-agent` now scrapes Loki, Tempo, Prometheus and CoreDNS (with a series allowlist and `cluster=homelab`) and sends the collectors' own telemetry. That leaves out, for now, Grafana and Tailscale: the proxies need a `ProxyClass` with metrics, which is left for a later step.
- **Routing by `severity`:** `critical` and `warning` arrive by email; `info` only shows in the UI.
- **Verification.** `make test` checks the lock (`--check`) and the rules (`scripts/check-alert-rules.py`); the e2e checks that the Grafana sidecar loaded every file. `scripts/check-dashboard-metrics.py` runs by hand against the laptop's Prometheus and lists the missing metrics.
