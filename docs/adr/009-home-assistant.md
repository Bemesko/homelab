# 009 — Home Assistant in the cluster, bridge for the Alexa shopping list

- **Status:** accepted
- **Date:** 2026-11-08

## Context

We want items spoken to Alexa ("Alexa, add milk to the shopping list") to reach grocery-ops (`Bemesko/grocery-ops`). Amazon has no public lists API for third parties. Since Home Assistant 2026.7, the native **Alexa Devices** integration exposes the Alexa lists as `todo` entities, updated by push events from Amazon (IoT class *Cloud Polling*). HA becomes the bridge, without being exposed to the internet.

## Decision

- **Our own kustomize** in `kubernetes/workloads/home-assistant`, like Obsidian (ADR 006). There is no official chart, and the community ones would only save about 5 manifests.
- **The official image** `ghcr.io/home-assistant/home-assistant`, pinned by tag + digest.
- **`configuration.yaml` in Git** (a ConfigMap mounted with `subPath`), without the `http:` block (see the risks). The rest of `/config` (`.storage`: integrations, users, tokens) lives in a PVC on the **NAS over NFS**, through the `nas_storage` role, and is included in the NAS replica.
- **Recorder on Postgres** (CloudNativePG, Application `home-assistant-database`, wave 2). HA reads the URI from the CNPG-generated Secret with `!env_var DB_URL`.
- **Only on the laptop (`tailscale` overlay)**:
  - `hostNetwork`, for mDNS/SSDP discovery on the LAN. The pod only listens on the host network, without changing the network, firewall or SSH. Side effect: HA also answers on `<laptop IP>:8123` on the LAN.
  - The host's `/run/dbus`, read-only, and the `NET_ADMIN`/`NET_RAW` capabilities, to use the laptop's Bluetooth through the host's BlueZ. No `privileged`.
  - Ingress `https://casa.<your-tailnet>`.
- CI uses `base`: normal pod network, no Bluetooth and no Ingress.

## Contract with grocery-ops

grocery-ops does not implement the integration yet. The infrastructure leaves this ready:

- **Internal route:** `http://home-assistant.home-assistant.svc:8123`. There is no NetworkPolicy in the cluster. With `hostNetwork`, the Service endpoint becomes `<node IP>:8123` and keeps working.
- **Authentication:** a `grocery-ops` user in HA with a *long-lived access token*. The token lives in a `*.sops.yaml` in the grocery-ops repo's `deploy/`, not here.
- **Read:** `POST /api/services/todo/get_items?return_response` with `{"entity_id": "todo.<list>", "status": "needs_action"}`, or the equivalent websocket command.
- **Write:** `todo.add_item`, `todo.update_item` (mark as bought) and `todo.remove_item`.
- **Push HA → app (once there is an endpoint):** an automation with the `todo.item_added`, `todo.item_completed` and `todo.item_removed` triggers calling a `rest_command` to `http://grocery-ops.grocery-ops.svc.cluster.local/...` (FQDN: the HA pod uses `ndots:2`).

## Consequences and risks

- The Alexa Devices integration requires authenticator-app 2FA on the Amazon account (SMS does not work). amazon.com.br works (tested on 2026-11-10).
- **Alexa Devices polling turned off (UI only, under *System options*).** With polling every 5 min, the per-Echo calls exceed Amazon's limit: half of the cycles got a 429 and every entity went `unavailable`. The shopping and to-do lists arrive through push events, so two-way sync keeps working; only the sensors and the Echo state are lost. When recreating the integration, turn it off again.
- The containerd custom AppArmor profile (`base` role) denied D-Bus (`Hello`, `AddMatch`). It gained the rule `dbus (send,receive) bus=system peer=(label=unconfined)`: only containers that mount the host's `/run/dbus` reach the bus, today just HA.
- **The HTTP config (trusted proxy) is not declarative.** Since 2026.8, HA stores `use_x_forwarded_for`/`trusted_proxies` in `/config/.storage/http`, ignores the `http:` block in YAML, and only promotes a change if an admin confirms it in the UI within 5 minutes of the restart. It is done once through the UI (README) and persists on the NAS. Until then the Ingress answers 400; the first access is direct on `<laptop IP>:8123`.
- HA metrics (`/api/prometheus`) are left for later: they need a token created in the UI and mounted in the otel-agent. The logs already reach Loki through the collector.
- The HA Postgres had no backup beyond the laptop disk (the history looked disposable). Since [014](014-postgres-backups-barman-rustfs.md) it has the same CNPG backups as every other database.
