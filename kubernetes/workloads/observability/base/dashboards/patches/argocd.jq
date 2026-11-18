# ArgoCD (argo-cd examples/dashboard.json): o job vem como service.namespace/nome
# quando o alvo é descoberto por pod.
include "_lib";
on_exprs(
  gsub("job=\"(?<j>argocd-[a-z-]+)\""; "job=~\"(.+/)?" + .j + "\""))
