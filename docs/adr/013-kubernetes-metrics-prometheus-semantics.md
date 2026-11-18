# 013 — Métricas do Kubernetes no formato Prometheus (e o OpenCost)

- **Status:** aceito
- **Data:** 2026-11-17
- **Atualiza:** [008](008-observability-otel-lgtm.md), na decisão de usar só métricas OTel nativas para o Kubernetes

## Contexto

Queremos o OpenCost para saber o custo de cada namespace, pod e nó. Ele consulta o Prometheus com os nomes do ecossistema: uso real de CPU e memória do cAdvisor (`container_cpu_usage_seconds_total`, `container_memory_working_set_bytes`) e o estado dos objetos do kube-state-metrics (`kube_*`). O ADR 008 tinha deixado os dois de fora, para ficar só com as métricas OTel (`kubeletstats` e `k8s_cluster`).

Essa escolha já custava caro:
- **Patches:** sete patches `jq` (21 traduções ou remoções de painéis) para adaptar dashboards da comunidade.
- **Dashboards próprios:** o `cluster.json` foi escrito à mão, porque nenhum dashboard da comunidade usa os nomes `k8s_*`.
- **Alertas:** as regras de Kubernetes ficaram reescritas para nomes OTel que ainda mudam entre versões do coletor (`*_cpu_utilization_ratio` virou `*_cpu_usage`).
- **Ferramentas:** tudo o que assume o formato Prometheus (OpenCost, dashboards e alertas dos mixins) não funciona sem tradução.

## Decisão

**O transporte do 008 não muda; a semântica das métricas do Kubernetes sim.** Continua tudo por OTLP (`otel-agent` → `otel-gateway` → Prometheus), e os backends seguem sem scrape. O que o `otel-agent` passa a raspar:
- **kube-state-metrics** (job `kube-state-metrics`): subchart do chart do Prometheus, com imagem por digest. Só os coletores que o OpenCost, os dashboards e os alertas usam, e `kube_pod_labels`/`kube_namespace_labels` liberados, porque o OpenCost agrega o custo por label.
- **cAdvisor** (job `kubernetes-nodes-cadvisor`): `/metrics/cadvisor` do kubelet do próprio nó, com o token do ServiceAccount (regra RBAC `nodes/metrics`) e uma allowlist de séries.
- **OpenCost** (job `opencost`): com `honor_labels: true`, porque as métricas dele trazem `instance` e `namespace` próprios.
- Os três jobs levam `cluster=homelab`, como os outros jobs do agent, que é o label que os dashboards da comunidade filtram.

**Saem `kubeletstats` (preset `kubeletMetrics` do agent) e `k8s_cluster` (preset `clusterMetrics` do gateway).** Os dois não podem conviver com o cAdvisor: o `kubeletstats` emite `container_memory_working_set_bytes` com labels `k8s_*`, no mesmo nome que o cAdvisor, e duplicaria as séries. Hosts e NAS continuam com `hostmetrics`, sem node-exporter.

**OpenCost** (chart 2.5.34, app 1.121.4, imagens com digest do próprio chart):
- **Local:** namespace `opencost`, sync-wave 3, lendo `prometheus-server.observability.svc`.
- **UI:** na tailnet como `opencost`, sem login (só quem já está na tailnet), e não exposta no CI.
- **Preços:** os padrões on-prem do OpenCost, sem `customPricing`. Os valores absolutos são uma referência de nuvem e não o custo real do notebook, mas a proporção entre apps vale.
- **`emitKsmV1MetricsOnly`:** emite só as métricas v1 que o kube-state-metrics 2 não tem, para não duplicar `kube_*`.

**Migração dos consumidores:**
- **Alertas:** os 8 de `kubernetes.yaml`, o de restarts e a sentinela `pipeline-dead` voltam às expressões do kubernetes-mixin, mantendo os `uid`. Entra o alerta `info` `kube-state-metrics-missing`.
- **Dashboards:** `pods` (20944) e o `cluster.json` próprio saem, e entram *Namespaces* (15758) e *Pods* (15760) do dotdc, mais *OpenCost / Overview* (22208). Os patches do `cnpg` e do `argocd` perdem as traduções de `kube_*`, e o dashboard do Immich passa a usar o cAdvisor.
- **Dashboard *Global* (15757) do dotdc, de fora:** os painéis de nó dele dependem do node-exporter, que não instalamos. O dashboard `host` continua sendo a visão do nó.

## Consequências

- **Histórico:** as séries `k8s_*` antigas ficam até 30 dias, mas nenhum painel as consulta. Os dashboards e alertas novos começam sem histórico.
- **Séries:** o cAdvisor e o kube-state-metrics aumentam o head do Prometheus (15,9 mil séries antes). Vale conferir `prometheus_tsdb_head_series` depois do deploy e apertar a allowlist se passar de uns 40 mil.
- **Nomes estáveis:** `kube_*` e `container_*` são o padrão do ecossistema, e deixam de mudar a cada versão do coletor. O custo dos patches de dashboard cai.
- **PVCs:** `kubelet_volume_stats_*` continua ausente (o `local-path` não reporta), então os painéis de volume seguem removidos.
- **UI sem login:** qualquer dispositivo na tailnet enxerga os custos. É o mesmo nível de acesso do Grafana, que tem login de admin; avaliar um proxy com autenticação se a tailnet passar a ter mais gente.
- **Recursos:** o OpenCost (exporter e UI) pede 30m de CPU e 160Mi de memória; o kube-state-metrics, 10m e 64Mi.
