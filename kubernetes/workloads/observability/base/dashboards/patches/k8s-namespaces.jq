# Kubernetes / Views / Namespaces (dotdc, grafana.com 15758): without the volume panels
# (kubelet_volume_stats: local-path does not report them) and without the resource count,
# which depends on kube-state-metrics collectors we do not enable (configmaps, secrets,
# ingresses, endpoints, networkpolicies).
include "_lib";
drop_panels("kubelet_volume_stats|kube_configmap_info|kube_secret_info")
