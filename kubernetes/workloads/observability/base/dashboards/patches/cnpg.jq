# CloudNativePG (grafana.com 20417): no volume stats (local-path does not report them), no
# kubernetes-mixin recording rules (node_namespace_*) and no operator
# controller-runtime metrics. The rest (kube_* and cAdvisor) comes from kube-state-metrics
# and cAdvisor (docs/adr/013). Counters arrive over OTLP with the _total suffix.
include "_lib";
drop_vars(["operatorNamespace"])
| drop_panels("kubelet_volume_stats|controller_runtime|node_namespace")
| on_exprs(
    gsub("\\b(?<n>cnpg_pg_stat_(archiver_(archived|failed)_count|database_(blks_hit|blks_read|deadlocks|temp_bytes|tup_deleted|tup_fetched|tup_inserted|tup_returned|tup_updated|xact_commit|xact_rollback)))\\b"; "\(.n)_total")
    | gsub("(?<p>cnpg_pg_stat_\\(bgwriter_checkpoint\\|checkpointer\\)_(sync|write)_time)"; "\(.p)_total")
    | gsub("(?<p>cnpg_pg_stat_\\(bgwriter\\|checkpointer\\)_checkpoints_(req|timed))\\b"; "\(.p)_total"))
