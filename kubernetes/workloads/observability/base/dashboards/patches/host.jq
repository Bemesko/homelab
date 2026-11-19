# Host Metrics (grafana.com 24638): the host selector only offered k8s_node_name and
# host. Our hosts are told apart by service.name (job) and host_name.
.templating.list |= map(
  if .name == "host_label" then
    .query = "job,host_name"
    | .current = {text: "job", value: "job"}
    | .options = [
        {selected: true, text: "job", value: "job"},
        {selected: false, text: "host_name", value: "host_name"}
      ]
  else . end)
