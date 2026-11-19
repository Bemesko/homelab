# Functions shared by the patches (jq -L .../patches; include "_lib";).

# Applies f to the dashboard's PromQL/LogQL queries: the panels' expr and the
# template variable queries (query as a string or as an object, and definition).
def on_exprs(f):
  walk(
    if type == "object" then
      (if (.expr? | type) == "string" then .expr |= f else . end)
      | (if (.definition? | type) == "string" then .definition |= f else . end)
      | (if (.query? | type) == "string" then .query |= f
         elif (.query? | type) == "object" and (.query.query? | type) == "string" then .query.query |= f
         else . end)
    else . end);

# Removes template variables by name.
def drop_vars($names):
  .templating.list |= map(select(.name as $n | ($names | index($n)) == null));

# Removes panels (except rows) whose queries match the regex: they use metrics our
# stack does not have (node-exporter, kubelet volume stats, kube-state-metrics
# collectors we do not enable, etc.).
def drop_panels($re):
  walk(
    if type == "object" and (.panels? | type) == "array" then
      .panels |= map(select(
        .type == "row"
        or (((.targets // []) | map(.expr? // "") | any(test($re))) | not)))
    else . end);

# The Loki/Tempo mixins assume microservices ("$namespace/<component>"): here
# each backend is a single binary, and the job comes from service.namespace/service.name.
def single_binary($name):
  on_exprs(
    gsub("job=~?\"(\\(\\$namespace\\)|\\$namespace)/[^\"]*\""; "job=~\"(.+/)?" + $name + "\"")
    | gsub(", *namespace=~?\"\\$namespace\""; "")
    | gsub("namespace=~?\"\\$namespace\", *"; ""));
