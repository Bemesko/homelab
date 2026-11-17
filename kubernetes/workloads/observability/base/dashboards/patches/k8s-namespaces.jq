# Kubernetes / Views / Namespaces (dotdc, grafana.com 15758): sem os painéis de volumes
# (kubelet_volume_stats: o local-path não reporta) e sem a contagem de recursos, que
# depende de coletores do kube-state-metrics que não ligamos (configmaps, secrets,
# ingresses, endpoints, networkpolicies).
include "_lib";
drop_panels("kubelet_volume_stats|kube_configmap_info|kube_secret_info")
