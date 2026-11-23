# Language and Toolchain

- Ansible (ansible-core 2.21, collections pinned in `ansible/requirements.yml`) for the host bootstrap
- Single-node k3s; ArgoCD (app-of-apps in Helm) for everything inside the cluster; kustomize for workloads
- SOPS + age for secrets; the private key lives only on the control machine (WSL)
- Control-machine tools with version + sha256 pinned in `scripts/setup-control-node.sh`, one sha256 per architecture (x86_64 and aarch64); `--runtime` (the Pi's default) skips the dev/test tools

# Repository Layout

- `ansible/`: `site.yaml` (preflight → base → power → tailscale_check → k3s → cluster_bootstrap → otel_host_agent → nas_storage → kubeconfig; then a `hosts: nas` play with `power` and `nas_syncthing`), `reset.yaml`, and `control-node.yaml` (the Raspberry Pi control node, `make control-node`: `control_node_base`, `control_node_tailscale`, `control_node_ssh`, `control_node_keys`, `control_node_toolchain`, `control_node_logging` and `otel_host_agent` (arm64, own `service.name`; vars in `group_vars/control_node.yaml`) on the Pi, then `control_node_access` on the laptop and NAS via `make control-access`; arm64 Debian)
- `kubernetes/apps/`: app-of-apps chart; `values.yaml` is the SINGLE SOURCE of chart versions (Ansible reads it too)
- `kubernetes/workloads/<app>/{base,overlays/tailscale}`: `base` is what CI uses (no Tailscale)
- Apps from other repos in the org or the personal `Bemesko` account, public only (template `bernats-homelab/repotpl-k8s-app`): only the entry under `apps:` in `kubernetes/apps/values.yaml`; the kustomize lives in the app repo's `deploy/`
- `docs/adr/NNN-*.md`: architecture decisions

# Constraints

- The laptop is reached over SSH through the tailnet: NEVER create tasks that change Tailscale, SSH, the firewall or the host network (hook `no-lockout`). The only exceptions are issue #32's: the `control_node_access` role only ADDS the control node's public keys to `authorized_keys`, never removes any and never touches the SSH server config (only that line carries `# lockout-safe`); the `control_node_tailscale` role, which only runs on the Pi; and the `control_node_ssh` role, which only runs on the Pi and allows SSH password login only from the tailnet and the home network (both excluded from the hook in `.pre-commit-config.yaml`)
- Never version the hostname, user, tailnet name (`*.ts.net`) or kubeconfig; the real inventory is `ansible/inventory/local.yaml` (gitignored)
- Every new version comes with a sha256 (binaries) or digest (images)
- Variables registered/defined in roles carry the role prefix (ansible-lint `production`)
- Every `command`/`shell` has `changed_when`/`creates`; the e2e requires changed=0 on the second run
- Chart version changes: only in `kubernetes/apps/values.yaml`
- Grafana dashboards: only through `scripts/vendor-dashboards.sh` (version + sha256 in `dashboards.lock`, tweaks in `patches/*.jq`); never paste dashboard JSON by hand (our own dashboards live in `dashboards/<folder>/`, outside the lock). Alert rules: `base/alerts/*.yaml`, with `severity` critical, warning or info
- External apps always by `vX.Y.Z` tag (never a branch) and in the `homelab-apps` AppProject; the GitHub App and GHCR credentials only in `ansible/secrets/` (optional)
- App secrets: `*.sops.yaml` next to the app + a KSOPS generator; encrypt at the final path (`.sops.yaml` picks the recipients). Never use the CI test key (`tests/ci-age.key`, public) outside `kubernetes/workloads/hello-world/`
- Bootstrap secrets (`ansible/secrets/`) are encrypted for the WSL key, the Pi's key and the recovery key (private part only in KeePass); never for the cluster or the CI key. The WSL key leaves the recipients when the PC is discarded (issue #32)
- The NAS (openmediavault) is configured through its own UI: NEVER create tasks that change the NAS, with two exceptions: Syncthing through the `nas_syncthing` role (ADR 011) and power management through the `power` role (ADR 012). The `nas_storage` role only checks the exports and creates the PVs; the hostname, paths and Syncthing IDs live in `local.yaml`
- Immich/Postgres images by digest; the Immich version lives in `kubernetes/values/immich.yaml` (the chart does not follow the releases)
- Everything in the repo is written in English (docs, comments, task names, alerts, log messages)

# Tests

- `make test`: pre-commit + helm unittest + render/kubeconform/kube-linter
- `make test-changed`: pre-commit only on what the branch changed vs `origin/main`
- CI `e2e` (lite, only when the change can affect the bootstrap; `scripts/ci-changes.sh`): brings up k3s + ArgoCD on the runner, checks idempotency, the root Application, KSOPS and the reset. `e2e-full` (nightly, on demand or label `e2e-full`) also waits for every Application Healthy. The only check meant to be required on `main` is `ci-ok` (ADR 015)
- Against the laptop: `make plan` (check/diff) before `make apply`
