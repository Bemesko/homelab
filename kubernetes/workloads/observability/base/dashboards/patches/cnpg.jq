# CloudNativePG (grafana.com 20417): sem volume stats (local-path não reporta), sem as
# recording rules do kubernetes-mixin (node_namespace_*) e sem as métricas do
# controller-runtime do operador. O resto (kube_* e cAdvisor) vem do kube-state-metrics
# e do cAdvisor (docs/adr/013). Contadores chegam por OTLP com o sufixo _total.
include "_lib";
drop_vars(["operatorNamespace"])
| drop_panels("kubelet_volume_stats|controller_runtime|node_namespace")
| on_exprs(
    gsub("\\b(?<n>cnpg_pg_stat_(archiver_(archived|failed)_count|database_(blks_hit|blks_read|deadlocks|temp_bytes|tup_deleted|tup_fetched|tup_inserted|tup_returned|tup_updated|xact_commit|xact_rollback)))\\b"; "\(.n)_total")
    | gsub("(?<p>cnpg_pg_stat_\\(bgwriter_checkpoint\\|checkpointer\\)_(sync|write)_time)"; "\(.p)_total")
    | gsub("(?<p>cnpg_pg_stat_\\(bgwriter\\|checkpointer\\)_checkpoints_(req|timed))\\b"; "\(.p)_total"))
