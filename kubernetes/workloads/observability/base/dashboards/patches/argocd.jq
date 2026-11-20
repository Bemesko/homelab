# ArgoCD (argo-cd examples/dashboard.json): the job comes as service.namespace/name
# when the target is discovered per pod.
include "_lib";
on_exprs(
  gsub("job=\"(?<j>argocd-[a-z-]+)\""; "job=~\"(.+/)?" + .j + "\""))
