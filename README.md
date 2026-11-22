# homelab

Bootstrap and configuration of a **single-node k3s** cluster on a personal laptop (Ubuntu 26.04).
Everything is applied **remotely**: Ansible runs in WSL on this machine and connects to the laptop over SSH through the tailnet.

```
WSL (control)  ──ssh over Tailscale──▶  laptop (Ubuntu 26.04)
  ansible + sops/age                      k3s
                                           └─ ArgoCD (app-of-apps, GitOps from this repo)
                                               ├─ tailscale-operator  → Ingress on the tailnet
                                               ├─ argocd (self-managed) → https://argocd.<your-tailnet>
                                               ├─ hello-world           → https://hello.<your-tailnet>
                                               ├─ cloudnative-pg        → Immich Postgres
                                               ├─ immich                → https://fotos.<your-tailnet>
                                               │    └─ NFS (tailnet) ──▶ openmediavault NAS (photos ro, immich-data rw)
                                               ├─ home-assistant        → https://casa.<your-tailnet> (/config on the NAS, recorder on CNPG)
                                               └─ apps: (other repos from the org/Bemesko, AppProject homelab-apps)
                                                    └─ <owner>/<app> @ vX.Y.Z → deploy/ → https://<app>.<your-tailnet>
```

## Safety guarantees

- **No lockout.** The playbook never touches Tailscale, SSH, the firewall or the host network. The `tailscale_check` role only reads the status, and the `no-lockout` hook blocks any task that tries to change those things.
- **Nothing identifiable in the repo.** The real inventory lives in `ansible/inventory/local.yaml` (ignored by git and blocked by a hook). The tailnet name (`*.ts.net`) is discovered at runtime and blocked by gitleaks. Kubeconfigs live in `~/.kube/`.
- **Secrets with SOPS + age.** The private key lives only in WSL. Ansible decrypts on the controller and creates the bootstrap Secrets with `no_log` (see [ADR 002](docs/adr/002-sops-age-secrets.md)). App secrets are committed encrypted next to the app, and ArgoCD decrypts them with KSOPS using the cluster's own age key (see [ADR 004](docs/adr/004-ksops.md)).
- **The laptops never suspend, and a power outage never takes anything down without warning.** The `power` role (cluster laptop and NAS; see [ADR 012](docs/adr/012-power-management.md)):
  - ignores the lid in `systemd-logind` and masks the sleep targets;
  - locks GNOME so it does not suspend on inactivity;
  - runs a guard that, without external power, warns (alert `host-on-battery`) and shuts down at 10% battery;
  - powering back on is manual (open the Acer lid, press the NAS button): both BIOSes ignore the RTC alarm. Wake-on-LAN automation is tracked in issue #23.
  - Charge limit: neither firmware supports one (the ADR records what was tried).
- **Ubuntu updates without surprises.** The `os_updates` role runs unattended-upgrades at 05:15 with idle CPU and I/O priority, and takes the kernel (`linux-*`) out of the automatic run: kernels only through `make kernel-upgrade`, which reboots and validates the cluster. See [ADR 010](docs/adr/010-notebook-os-updates.md).
- **Versions pinned with sha256** for k3s (installer), helm, kubectl, sops, age, kubeconform, kube-linter and kustomize. The hello-world image is pinned by digest.
- **One source per version.** Chart versions live only in [kubernetes/apps/values.yaml](kubernetes/apps/values.yaml), which Ansible also reads during the bootstrap.

## Prerequisites (once)

### 1. WSL on this machine

```bash
make deps                 # tools with pinned version/sha256 in ~/.local/bin + Ansible collections
pre-commit install
```

The repo can live under `/mnt/c/...`. The `Makefile` exports `ANSIBLE_CONFIG`, because under `/mnt/c` Ansible ignores the `ansible.cfg` of a world-writable directory. Commit **from WSL** so the hooks run; if one slips through, the CI `lint` job runs the same hooks.

### 2. SSH access to the laptop

```bash
ssh-copy-id <user>@<magicdns-hostname>
cp ansible/inventory/inventory.example.yaml ansible/inventory/local.yaml   # and fill it in
```

### 3. age key

```bash
age-keygen -o ~/.config/sops/age/keys.txt
age-keygen -y ~/.config/sops/age/keys.txt   # public key → replace it in .sops.yaml
```

Keep `keys.txt` in your password manager. Without that file the secrets cannot be decrypted.

### 4. Tailscale (admin console)

1. In the policy, under `tagOwners`, add:
   ```json
   "tag:k8s-operator": ["autogroup:admin"],
   "tag:k8s": ["tag:k8s-operator"]
   ```
2. Under Trust credentials, create an **OAuth client** with the *Devices Core* and *Auth Keys* (write) scopes and the `tag:k8s-operator` tag.
3. Under DNS, keep **MagicDNS** and **HTTPS Certificates** enabled.

### 5. Secrets

```bash
cp ansible/secrets/secrets.example.yaml ansible/secrets/secrets.sops.yaml
sops ansible/secrets/secrets.sops.yaml   # fill in the OAuth client id/secret
```

If the file already exists in plain text, encrypt it with `sops --encrypt --in-place ...`. The `sops-encrypted` hook blocks committing a decrypted file.

Also fill in `sops_age_cluster_key` with the cluster's age private key, which KSOPS uses. Generate it with `age-keygen` and put the matching public key in `.sops.yaml`, in the `kubernetes/` rule.

## Immich (photos from the NAS)

Immich shows the NAS photos and videos **read-only** as an External Library. The data it generates (thumbnails, previews, transcodes and daily database dumps) lives in its own folder on the NAS. Postgres lives on the laptop disk. See [ADR 005](docs/adr/005-immich-nas-nfs.md).

### 1. NAS: NFS exports in OMV (once, through the openmediavault UI)

The playbook does not change the NAS; it only checks what you configure here. The only exceptions are Syncthing (see [Syncthing on the NAS](#syncthing-on-the-nas)) and power management.

1. **Services → NFS → Settings**: tick *Enabled*, click *Save* and apply the changes (yellow banner).
2. **Storage → Shared Folders**: create the `immich-data` folder on the disk with free space (Immich writes about 12 to 70 GB there). The photos folder must already exist. If the photos are spread across the disk, it can be the shared folder for the disk root; in that case, see the import paths in step 3.
3. Find the UID/GID of the files' owner, for the squash. For example, under **Users → Users** check the UID of your user (usually `1000`); the OMV `users` group is GID `100`.
4. **Services → NFS → Shares → Create**, twice:

   | Shared folder | Client | Permission | Extra options |
   |---|---|---|---|
   | (photos folder) | `<laptop Tailscale IP>/32` | Read-only | `subtree_check,all_squash,anonuid=<uid>,anongid=<gid>` |
   | `immich-data` | `<laptop Tailscale IP>/32` | Read/Write | `subtree_check,all_squash,anonuid=<uid>,anongid=<gid>` |

   To find the laptop's Tailscale IP, run `tailscale ip -4` on it. `all_squash` makes Immich (which runs as root in the container) write as your user.
5. Apply the changes. The exports show up as `/export/<folder>`.

### 2. Inventory (`ansible/inventory/local.yaml`)

Fill in the variables from `inventory.example.yaml`: `nas_storage_enabled: true`, `nas_storage_host` and `nas_storage_exports.{photos,data,obsidian,home_assistant}`, which are the `/export/...` paths (`obsidian` and `home_assistant` are described in each app's section). Do this **before** the first `make apply` with Immich. PVCs are immutable, and with `nas_storage_enabled: false` they would be created on `local-path`.

Then run `make plan` and `make apply`. The `nas_storage` role checks the exports with `showmount` and test-mounts each one, including a write to `immich-data`. If something is wrong in OMV, it fails before creating the PVs.

### 3. First access

1. Open `https://fotos.<your-tailnet>` and create the admin user.
2. Under **Administration → External Libraries → Create**, add the import path `/mnt/nas/fotos` and click *Scan*.
   - If the photos export is the disk root, use one import path per subfolder (e.g. `/mnt/nas/fotos/<folder>`) instead of `/mnt/nas/fotos`. That keeps `immich-data`, which is on the same disk, out of the library; otherwise Immich would index the thumbnails it generates itself.
   - Use *Exclusion patterns* to skip what is not a photo, such as system backups (e.g. `**/*backup-windows*/**`, `**/lost+found/**`).
   - Libraries live in the database, not in `immich.configuration`, so they are managed through the UI.

Server settings come from `kubernetes/values/immich.yaml` (`immich.configuration`), and the matching settings screens in the UI are read-only. To change something (enable ML, the scan schedule), edit the file and push.

### Database backup and restore

Every Postgres (Immich, Home Assistant and the external apps) is backed up by CloudNativePG through the Barman Cloud plugin to RustFS, whose data lives on the NAS (`cnpg-backups`, inside the replicated area). See [ADR 014](docs/adr/014-postgres-backups-barman-rustfs.md).

- **What is kept:**
  - WAL archived continuously (at most every 5 min while there are writes);
  - a base backup every day at 02:00;
  - a 14-day window for restoring to any point in time.
- **Status:**
  - `kubectl -n <ns> get cluster <cluster> -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].message}'`
  - `kubectl -n <ns> get backups`
  - The recovery window is in `kubectl -n <ns> get objectstore <cluster>-backup -o jsonpath='{.status}'`.
- **Alerts:** archiving failing for 15 min (critical) and a base backup older than 26 h (warning), in `base/alerts/backups.yaml`.
- **Restore into a new cluster:** create a `Cluster` in the same namespace with the source's spec (image, `postgresql`, storage) and, instead of the plugin:
  ```yaml
  bootstrap:
    recovery:
      source: origin
      # recoveryTarget: {targetTime: "2026-11-21T16:53:25Z"}   # point in time (UTC); omit for the latest WAL
  externalClusters:
    - name: origin
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters: {barmanObjectName: <cluster>-backup, serverName: <cluster>}
  ```
  - Leave `spec.plugins` out of the new cluster: archiving to the same `serverName` would mix the histories.
  - To replace the original, stop the app, delete the old `Cluster`, recreate it under the original name with `bootstrap.recovery` and the same `serverName`, then put the `plugins` back.
  - Tested on 2026-11-21: Immich identical (72 tables, 252,198 rows); Home Assistant PITR stopped exactly at the target.
- **Old Immich dumps:** Immich's own `pg_dump` (in `immich-data/backups`) is off. The files there are from before ADR 014 and can be removed by hand.

## Obsidian in the browser (vault on the NAS)

The Obsidian desktop app runs in the cluster ([linuxserver/obsidian](https://docs.linuxserver.io/images/docker-obsidian/)) and opens in the browser at `https://borbsidian.<your-tailnet>`, with a user and password. The vault lives on the NAS, mounted over NFS, and the app state (`/config`) lives on the laptop disk. See [ADR 006](docs/adr/006-obsidian-nas-nfs.md).

1. **NAS (OMV UI):** create the vault's shared folder (it can point to an existing folder) and an NFS share, **Read/Write**, for `<laptop Tailscale IP>/32` with `subtree_check,all_squash,anonuid=<uid>,anongid=<gid>`, like `immich-data`. Put the path in `nas_storage_exports.obsidian` and run `make apply`.
2. **Password:** the user and password are in `kubernetes/workloads/obsidian/overlays/tailscale/auth.sops.yaml`:
   ```bash
   sops -d kubernetes/workloads/obsidian/overlays/tailscale/auth.sops.yaml
   ```
   To change the password, run `sops edit` on the same file and push.
3. **First access:** in Obsidian, use *Open folder as vault* on `/vaults/borbsidian`. The choice is saved in `/config`.

**Editing in several places.** Over NFS, the cluster's Obsidian is not notified of changes made from other devices (Syncthing, SMB), because inotify does not cross NFS. Edit in one place at a time. When you come back to the browser Obsidian, run *Reload app without saving* (command palette) before editing, so you do not overwrite the newer version.

### Syncthing on the NAS

The vault reaches the phone through the NAS's Syncthing. Together with power management (the `power` role, `nas_power_enabled`; see [ADR 012](docs/adr/012-power-management.md)), it is what Ansible changes on the NAS: OMV does not manage Syncthing through its UI. See [ADR 011](docs/adr/011-syncthing-nas-ansible.md).

- **Inventory:** fill in the `nas` group from `inventory.example.yaml`. It takes `ansible_user: root`, `nas_syncthing_home` (a directory on the data disk, off the system USB stick), `nas_syncthing_devices` and `nas_syncthing_folders`.
  - `nas_syncthing_devices` is the **complete** list: a device that is not in it is removed.
  - A folder outside `nas_syncthing_folders` is not deleted; it only produces a warning.
- **SSH:** the WSL key must be in the NAS's `/root/.ssh/authorized_keys`, and the NAS host key in WSL's `known_hosts` (run `ssh root@<nas>` once and accept). `host_key_checking` stays on.
- **Apply:** `make plan` and `make apply`. The second play (`hosts: nas`) installs the `.deb` pinned in `group_vars/all` and enables `syncthing@<user>` at boot. Then it applies options, devices and folders through the REST API. Any change made through the GUI to those items reverts to the inventory on the next apply.
- **Pair a new device:** add its ID to `nas_syncthing_devices` (and to the folder's `devices`), run `make apply` and accept on the other side.
- **GUI:** listens only on `127.0.0.1:8384`. To open it in the browser:
  ```bash
  ssh -L 8384:127.0.0.1:8384 root@<nas>
  ```
  Then open `http://localhost:8384`.

## Home Assistant (bridge for the Alexa shopping list)

Home Assistant runs in the cluster and opens at `https://casa.<your-tailnet>`. Its `configuration.yaml` comes from Git ([kubernetes/workloads/home-assistant/base/configuration.yaml](kubernetes/workloads/home-assistant/base/configuration.yaml)); the rest of `/config` lives on the NAS and the history in Postgres (CNPG). On the laptop it uses `hostNetwork` (LAN discovery; it also answers on `<laptop IP>:8123`) and the host's Bluetooth over D-Bus. See [ADR 009](docs/adr/009-home-assistant.md).

1. **NAS (OMV UI):** create the `home-assistant` shared folder and an NFS share, **Read/Write**, for `<laptop Tailscale IP>/32` with the same options as `immich-data`. Put the path in `nas_storage_exports.home_assistant` and run `make plan` and `make apply`.
2. **First access (directly, without the proxy):** open `http://<laptop IP>:8123` (LAN or the laptop's Tailscale IP; it works because of `hostNetwork`) and create the owner user. Through `https://casa.<your-tailnet>` HA answers 400 until the next step.
3. **Trust the Tailscale proxy:** since 2026.8 the HTTP config is UI-only (the `http:` block in YAML is ignored). Under *Settings → System → Network → HTTP server*, turn on *Trust X-Forwarded-For*, put `10.42.0.0/16` in *Trusted proxies* and save. HA restarts and asks for confirmation: **confirm within 5 minutes, still through the direct access**, or it rolls back to the previous config. After that, `https://casa.<your-tailnet>` works.
4. **Alexa:** enable authenticator-app 2FA on the Amazon account (SMS does not work) and add the **Alexa Devices** integration under *Settings → Devices & services*. The shopping list becomes a `todo` entity. Then, under *Alexa Devices → ⋮ → System options*, **turn off "Enable polling for changes"**: with polling on, Amazon returns 429 (Too Many Requests) every few cycles and every entity goes `unavailable`. The lists stay in sync both ways, because they arrive by push.
5. **grocery-ops:** create a `grocery-ops` user in HA, generate a *long-lived access token* in its profile and store it as `*.sops.yaml` in the grocery-ops repo's `deploy/`. The app calls `http://home-assistant.home-assistant.svc:8123` (contract in ADR 009).

## Observability (OpenTelemetry + Grafana)

Logs, metrics and traces from the cluster, the laptop and the NAS arrive over OTLP at the `otel-gateway` and go on to Prometheus, Loki and Tempo, all in the `observability` namespace. See [ADR 008](docs/adr/008-observability-otel-lgtm.md). Kubernetes metrics follow the Prometheus format (kube-state-metrics and cAdvisor, scraped by the `otel-agent`), which feeds OpenCost: see [ADR 013](docs/adr/013-kubernetes-metrics-prometheus-semantics.md).

- **Access:** `https://grafana.<your-tailnet>`. The admin user and password are in SOPS:
  ```bash
  sops -d --extract '["stringData"]["admin-password"]' kubernetes/workloads/observability/overlays/tailscale/grafana-admin.sops.yaml
  ```
- **Email alerts (Gmail):** create an [app password](https://myaccount.google.com/apppasswords) and fill in `GF_SMTP_USER`, `GF_SMTP_PASSWORD`, `GF_SMTP_FROM_ADDRESS` and `ALERT_EMAIL_TO`. Also set `GF_SMTP_ENABLED` to `"true"`:
  ```bash
  sops edit kubernetes/workloads/observability/overlays/tailscale/grafana-smtp.sops.yaml
  ```
  Push. Then, under *Alerting → Contact points → email*, use *Test* to confirm. The rules live in `kubernetes/workloads/observability/base/alerts/`.
- **Laptop (journald and host metrics):** the `otel_host_agent` role installs `otelcol-contrib` as a service. Enable it in `local.yaml`, as a host var, with `otel_host_agent_enabled: true` and `otel_host_agent_endpoint: otel:4317`, and run `make apply`.
- **NAS (through the OMV UI, once):**
  1. Install omv-extras and the `openmediavault-compose` plugin. Under *Services → Compose → Settings*, point *Compose Files* and the *Docker storage* to folders on the SSD, **not** on the system USB stick.
  2. Under *Services → Compose → Files*, create the `otel-collector` stack by pasting the contents of [`hosts/nas/otel-collector/compose.yaml`](hosts/nas/otel-collector/compose.yaml) (the config is embedded) and click *Up*. If the NAS does not use the tailnet's MagicDNS, set `OTEL_GATEWAY=otel.<your-tailnet>:4317` in the stack's `.env`. For the capacity alerts (`base/alerts/nas.yaml`), also set `NAS_PRIMARY_MOUNT` (data disk) and `NAS_REPLICA_MOUNT` (backup replica disk) in the `.env`, with the mount path from *Storage → File Systems* (e.g. `/srv/dev-disk-by-uuid-...`). The same stack runs `smartctl-exporter` (disk SMART) and reads `/var/log/rsync.log` from the OMV Rsync jobs: the replica history stays 30 days in Loki (`service_name="nas-rsync"`) and shows up in the *Hosts → NAS - Replication and disks* dashboard. The alert "replica without a successful run in 26h" fires until the first job runs after the deploy.
  3. Under *Diagnostics → System Logs → Remote* (the name varies with the OMV version), send syslog to `127.0.0.1`, port `5140`, TCP.
  4. The NAS shows up in Grafana with `job="nas-host"` (metrics) and `service_name="nas-host"` (logs). After that, the OMV graphs (*System → Monitoring*) can be turned off: collectd/rrd would only write to the USB stick for nothing.
- **Costs (OpenCost):** `https://opencost.<your-tailnet>` shows the cost per namespace, pod and node, and the Grafana dashboard *Costs → OpenCost / Overview* uses the same metrics. The UI has no login: only devices on the tailnet can reach it. Prices come from OpenCost's `default.json` (GCP us-central1 reference, in USD): what matters is the proportion between apps, not the absolute amount.
- **Community dashboards and alerts:** Grafana comes with ready-made folders: *Hosts* (laptop and NAS), *Kubernetes* (namespaces and pods), *Costs* (OpenCost), *Apps* (ArgoCD, CloudNativePG and Immich), *Observability* (OTel collectors, Loki, Tempo and Prometheus), *Network* (CoreDNS) and *Logs*. They are versioned in `kubernetes/workloads/observability/base/dashboards/`, with version and sha256 in `dashboards.lock`; the community ones are adjusted to our metrics by jq patches. The alert rules (`base/alerts/`) derive from community rules, with `severity` `critical`, `warning` or `info`.
  ```bash
  scripts/vendor-dashboards.sh --check        # offline: what is versioned matches the lock
  scripts/vendor-dashboards.sh --update       # bump a dashboard version (edit the lock first)
  scripts/check-dashboard-metrics.py kubernetes/workloads/observability/base/dashboards --prometheus http://localhost:9090
  ```
  The last command (run it with `kubectl port-forward` to Prometheus) lists the metrics used by the dashboards that Prometheus does not have. Run it after every collector upgrade too: OTel names change between versions.
- **Retention:** metrics for 30 days (or 6 GB), logs for 14 days and traces for 7 days, all on the laptop disk.
- **Instrumenting an app:** send OTLP to `otel-agent.observability.svc:4317` (gRPC) or `:4318` (HTTP).

## App secrets (KSOPS)

1. Create the Secret in plain text next to the app, for example `kubernetes/workloads/<app>/base/<name>.sops.yaml`, and encrypt it **in place**:
   ```bash
   sops encrypt --in-place kubernetes/workloads/<app>/base/<name>.sops.yaml
   ```
   `.sops.yaml` picks the recipients by path (WSL + cluster) and encrypts only `data`/`stringData`.
2. Declare a KSOPS generator in the kustomization. The template is [secret-generator.yaml](kubernetes/workloads/hello-world/base/secret-generator.yaml):
   ```yaml
   generators:
     - secret-generator.yaml
   ```
3. Commit and push. ArgoCD decrypts while rendering and applies the Secret.

To edit it later, use `sops kubernetes/workloads/<app>/base/<name>.sops.yaml`. In pre-commit and CI, which have no key, `scripts/ksops-stub.py` stands in for KSOPS: it generates the Secret with placeholder values only to validate the structure.

The `tests/ci-age.key` key is **public** and only exists so the hello-world demo runs in the e2e. The `sops-encrypted` hook blocks any other file encrypted to it.

## Apps from other repos

Own apps live in separate repos, generated from the template [bernats-homelab/repotpl-k8s-app](https://github.com/bernats-homelab/repotpl-k8s-app). The app repo holds the code, the `Dockerfile` and kustomize in `deploy/`. This repo only holds the Application, pinned to a tag, the same way we pin chart versions (see [ADR 007](docs/adr/007-external-apps.md)).

### Publishing an app

1. In the app repo, follow the template's README: `scripts/init.sh <name>`, then *Actions → release* with `vX.Y.Z`.
2. Here, open a PR adding the app to [kubernetes/apps/values.yaml](kubernetes/apps/values.yaml). The release job summary shows the snippet ready to paste:
   ```yaml
   apps:
     <name>:
       repoURL: https://github.com/<owner>/<repo>
       targetRevision: v0.1.0
   ```
3. After the merge, ArgoCD creates the `<name>` namespace and syncs `deploy/overlays/tailscale`, which ends up at `https://<name>.<your-tailnet>`.

For a new version, run the release in the app repo and open a PR changing `targetRevision`. `values.schema.json` only accepts `bernats-homelab/*` or `Bemesko/*` repos and `vX.Y.Z` tags.

Repos from the personal `Bemesko` account (for example [grocery-ops](https://github.com/Bemesko/grocery-ops)) must be **public**, and so must their GHCR package: the GitHub App credential only covers the org.

The Applications run in the `homelab-apps` AppProject. It does not allow cluster-scoped resources (other than `Namespace`) nor the system and platform namespaces. The e2e syncs the template itself (`smokeApp`, Ansible `external_apps_smoke_enabled=true`) to cover that path.

### Private repos and images (once)

1. **GitHub App** (org → *Settings → Developer settings → GitHub Apps → New*):
   - *Repository permissions → Contents: Read-only*, no webhook;
   - install it on the org with *All repositories*. The credential covers every repo with the `https://github.com/bernats-homelab` prefix;
   - generate a *private key*.
2. **Classic PAT** with only `read:packages` (GHCR does not accept a GitHub App or a fine-grained token for pulls).
3. Fill in with `sops ansible/secrets/secrets.sops.yaml`:
   - `argocd_github_app_id`, `argocd_github_app_installation_id` and `argocd_github_app_private_key` (the whole PEM);
   - `ghcr_pull_username` and `ghcr_pull_token`.

   Then run `make plan` → `make apply`. Ansible creates the `argocd/repo-creds-bernats-homelab` Secret and `/etc/rancher/k3s/registries.yaml`; creating `registries.yaml` restarts k3s once.

Both are optional: without them, apps from public repos with public images already work.

## Usage

| Command | What it does |
|---|---|
| `make plan` | Dry-run (`--check --diff`) against the laptop |
| `make apply` | Runs `lint`, then applies |
| `make idempotency` | Re-applies and fails if anything changes |
| `make kernel-upgrade` | Installs the new kernel, reboots the laptop and only removes the old one if the node, Applications, Postgres and AppArmor are OK ([ADR 010](docs/adr/010-notebook-os-updates.md)) |
| `make kubeconfig` | Writes `~/.kube/notebook.yaml` pointing at `https://<host>.<tailnet>:6443` |
| `make reset` | Removes k3s (asks for confirmation; does not touch Tailscale or SSH) |
| `make test` | lint + helm unittest + render/kubeconform/kube-linter |
| `make test-changed` | Only the pre-commit hooks that match the files the branch changed vs `origin/main` (quick check before pushing) |

Normal flow: `make plan` → review the diff → `make apply`.

By default the targets ask for the sudo password (`--ask-become-pass`). If sudo on the laptop does not ask for a password (`NOPASSWD`), pass `ASK_BECOME_PASS=0`, for example `make apply ASK_BECOME_PASS=0`.

```bash
export KUBECONFIG=~/.kube/notebook.yaml
kubectl -n argocd get applications
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

After the bootstrap, everything inside the cluster is **GitOps**: change `kubernetes/` and push. ArgoCD syncs on its own.

## Safety nets

### Pre-commit (WSL and CI)

| Hook | Ensures |
|---|---|
| `trailing-whitespace`, `end-of-file-fixer`, `mixed-line-ending`, `check-yaml`, `check-json`, `check-merge-conflict`, `detect-private-key` | Basic hygiene and LF |
| `gitleaks` (+ `AGE-SECRET-KEY` and `*.ts.net` rules) | No secrets and no tailnet name in the repo |
| `sops-encrypted` | Every `*.sops.yaml` is encrypted (only `apiVersion`/`kind`/`metadata`/`type` may stay in plain text, via `unencrypted_regex`); the CI's public test key is not used outside the demo |
| `no-local-inventory`, `no-kubeconfig` | Hostname/user and kubeconfigs are not committed |
| `no-lockout` | No task changes Tailscale, SSH, the firewall or the host network |
| `yamllint --strict`, `ansible-lint` (profile `production`) | YAML/Ansible quality, FQCN, `changed_when`, permissions |
| `shellcheck`, `shfmt` | Scripts |
| `actionlint` | CI workflow |
| `helm-lint` (with `values.schema.json`), `helm-unittest` | app-of-apps chart |
| `validate-manifests` | `kubeconform -strict` (k8s 1.37 + Application CRD) and `kube-linter` |

`validate-manifests` downloads the schemas on the first run and caches them in `.cache/kubeconform`.

### CI ([.github/workflows/ci.yaml](.github/workflows/ci.yaml))

Design, measurements and the reasoning: [ADR 015](docs/adr/015-ci-flow-and-required-checks.md). The control machine tools are installed once and cached (`.github/actions/setup-tools`).

- **lint**: runs pre-commit on every file.
- **render**: runs `helm unittest` and renders the upstream charts (argo-cd, tailscale-operator, cloudnative-pg, immich, prometheus, loki, tempo, grafana, otel-agent/otel-gateway, opencost) with our values, validating everything with kubeconform.
- **e2e** ([e2e.yaml](.github/workflows/e2e.yaml), `lite` profile): runs on a PR only when the change can affect the host bootstrap (Ansible, `kubernetes/bootstrap`, the e2e scripts, the CI definition, the hello-world demo, the ArgoCD chart version; see `scripts/ci-changes.sh`). On the `ubuntu-26.04` runner:
  1. generates an ephemeral age key with dummy secrets;
  2. runs the full `site.yaml` with `tailscale_enabled=false`, syncing the PR's own SHA;
  3. runs the playbook again and requires **changed=0**;
  4. checks the node, that `argocd`, `root` and hello-world are Synced/Healthy, and that the demo Secret was decrypted by KSOPS;
  5. runs `reset.yaml`.
- **e2e-full** ([e2e-full.yaml](.github/workflows/e2e-full.yaml)): the same, but step 4 also checks every Application, that Postgres (CNPG + VectorChord) is ready, that Immich answers `/api/server/ping`, that the external smoke app (the `repotpl-k8s-app` template, in the `homelab-apps` AppProject) answers `/healthz`, and that the Kubernetes metrics and the OpenCost node cost reach Prometheus (in CI, Immich uses `local-path` instead of the NAS). It runs nightly, on demand and on a PR labeled `e2e-full`; it is a canary, not a merge gate.
- **ci-ok**: the aggregate of the jobs above (a skipped `e2e` counts as passed).

Recommended: branch protection on `main` requiring only `ci-ok` (a skipped e2e must not block a PR; the ruleset itself is issue #39). Before pushing, `make test-changed` runs the hooks only on what the branch changed.

## Troubleshooting

- **Firewall enabled on the laptop.** The preflight warns but changes nothing. If pods cannot reach the API, open the k3s ranges manually (`10.42.0.0/16` pods, `10.43.0.0/16` services).
- **ArgoCD does not open at `https://argocd.<tailnet>`.** Check the Tailscale policy and tags and run `kubectl -n tailscale logs deploy/operator`.
- **Postgres hangs on startup, "too many clients" or a pod stuck in `Terminating`** (Ubuntu 26.04, kernel 7.0.0-42+). `dmesg` shows `apparmor="DENIED" operation="signal" ... peer="cri-containerd.apparmor.d//&unconfined"`. The `base` role installs a fixed AppArmor profile for the containers (workaround for [containerd#14485](https://github.com/containerd/containerd/issues/14485)). Run `make apply`; the profile is replaced in the kernel and also applies to running containers.
- **Ansible ignores `ansible.cfg`.** Use the `make` targets, or export `ANSIBLE_CONFIG=$PWD/ansible/ansible.cfg`.

## Layout

```
ansible/              playbooks (site, reset), roles, example/CI inventory, SOPS secrets
kubernetes/apps/      app-of-apps Helm chart (ArgoCD Applications) + tests
kubernetes/values/    values for the upstream charts
kubernetes/workloads/ workload manifests (kustomize)
kubernetes/bootstrap/ root Application (template rendered by Ansible)
hosts/nas/            files applied by hand on the NAS through the OMV UI (OTel collector)
scripts/              control-node setup and checks used by pre-commit/CI (includes the KSOPS stub)
tests/ci-age.key      PUBLIC age test key for CI (only the hello-world demo)
docs/adr/             architecture decisions
```
