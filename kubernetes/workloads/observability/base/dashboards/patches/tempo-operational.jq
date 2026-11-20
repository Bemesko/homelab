# Tempo Operational (compiled mixin): Tempo runs monolithic (a single job).
include "_lib";
drop_vars(["namespace"])
| single_binary("tempo")
