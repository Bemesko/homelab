# Run in WSL (control machine). CI calls the same targets.
SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

# On /mnt/c Ansible ignores ansible.cfg in the cwd (world-writable directory); ANSIBLE_CONFIG solves it.
export ANSIBLE_CONFIG := $(CURDIR)/ansible/ansible.cfg
export PATH := $(HOME)/.local/bin:$(PATH)

# ASK_BECOME_PASS=0 when the laptop's sudo does not ask for a password (NOPASSWD).
ASK_BECOME_PASS ?= 1
BECOME_FLAGS := $(if $(filter 1,$(ASK_BECOME_PASS)),--ask-become-pass,)
PLAYBOOK := ansible-playbook $(BECOME_FLAGS)
INVENTORY := ansible/inventory/local.yaml

# On the control node (Raspberry Pi) every run is also written to the journal as `homelab-ansible`
# (the host collector ships it to Loki) and traced by the Ansible OpenTelemetry callback through
# the collector on localhost. Elsewhere none of this applies. Issue #32.
JOURNAL :=
ifeq ($(shell uname -m),aarch64)
export ANSIBLE_CALLBACKS_ENABLED := community.general.opentelemetry
export ANSIBLE_LOG_PATH := $(HOME)/.ansible/log/ansible.log
export OTEL_SERVICE_NAME := homelab-ansible
export OTEL_EXPORTER_OTLP_ENDPOINT := http://127.0.0.1:4317
export OTEL_EXPORTER_OTLP_PROTOCOL := grpc
export OTEL_EXPORTER_OTLP_TIMEOUT := 3000
JOURNAL := 2>&1 | tee >(systemd-cat -t homelab-ansible)
endif

# Base for `make test-changed` (the branch is compared against it).
BASE_REF ?= origin/main

# OpenTofu (Hetzner Storage Box): HCLOUD_TOKEN and TF_VAR_state_passphrase come from SOPS.
TOFU_DIR := infra/hetzner
TOFU := sops exec-env $(TOFU_DIR)/secrets.sops.yaml

# OpenTofu (GitHub branch rules, ADR 020): TF_VAR_github_token_personal, TF_VAR_github_token_org and TF_VAR_state_passphrase come from SOPS.
GITHUB_DIR := infra/github
GITHUB_TOFU := sops exec-env $(GITHUB_DIR)/secrets.sops.yaml

.PHONY: help deps lint test-changed test-unit test-render test check-inventory plan apply idempotency kernel-upgrade kubeconfig control-access control-node reset \
	tofu-plan tofu-apply backup-secret github-plan github-apply

help: ## List the targets
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

deps: ## Install the control machine tools (pinned versions; runtime tools only on aarch64)
	./scripts/setup-control-node.sh

lint: ## All pre-commit hooks on all files
	pre-commit run --all-files

test-changed: ## pre-commit only on the files this branch changed vs $(BASE_REF) (quick check before pushing)
	pre-commit run --from-ref $(BASE_REF) --to-ref HEAD

test-unit: ## helm lint + helm unittest of the app-of-apps chart
	helm lint --strict kubernetes/apps
	helm unittest kubernetes/apps

test-render: ## Render the repo manifests and upstream charts and validate them with kubeconform/kube-linter
	./scripts/validate-manifests.sh local
	./scripts/validate-manifests.sh upstream

test: lint test-unit test-render ## Everything that runs without a cluster

check-inventory:
	@test -f $(INVENTORY) || { echo "Create $(INVENTORY) from ansible/inventory/inventory.example.yaml"; exit 1; }

plan: check-inventory ## Dry run (--check --diff) against the laptop
	cd ansible && $(PLAYBOOK) site.yaml --check --diff $(JOURNAL)

# The control node (Raspberry Pi, aarch64) only has the runtime tools, so lint runs where pre-commit exists.
apply: check-inventory $(if $(shell PATH="$(HOME)/.local/bin:$$PATH" command -v pre-commit),lint,) ## Apply to the laptop (runs lint first when pre-commit is installed)
	cd ansible && $(PLAYBOOK) site.yaml $(JOURNAL)

idempotency: check-inventory ## Re-apply and fail if anything changes
	cd ansible && ../scripts/assert-idempotent.sh site.yaml $(BECOME_FLAGS)

kernel-upgrade: check-inventory ## Upgrade the kernel, reboot the laptop and validate the cluster (ADR 010)
	cd ansible && $(PLAYBOOK) kernel-upgrade.yaml

kubeconfig: check-inventory ## Update ~/.kube/notebook.yaml
	cd ansible && $(PLAYBOOK) site.yaml --tags kubeconfig $(JOURNAL)

control-access: check-inventory ## Authorize the control node's SSH keys on the hosts (add only; issue #32)
	cd ansible && $(PLAYBOOK) control-node.yaml --tags keys,control_access

# On the Pi itself the control node is the local machine: no SSH to itself, and only its own play.
CONTROL_NODE_ARGS ?= $(if $(filter aarch64,$(shell uname -m)),--connection local --limit control_node,)

control-node: check-inventory ## Configure the control node (Raspberry Pi; base, Tailscale, keys, toolchain; issue #32)
	cd ansible && $(PLAYBOOK) control-node.yaml $(CONTROL_NODE_ARGS) $(JOURNAL)

reset: check-inventory ## Remove k3s from the laptop (asks for confirmation)
	cd ansible && $(PLAYBOOK) reset.yaml

tofu-plan: ## OpenTofu: show what changes on the Hetzner Storage Box
	$(TOFU) 'tofu -chdir=$(TOFU_DIR) init -input=false -lockfile=readonly >/dev/null && tofu -chdir=$(TOFU_DIR) plan -input=false'

tofu-apply: ## OpenTofu: apply to the Storage Box (bills the Hetzner account; asks for confirmation)
	$(TOFU) 'tofu -chdir=$(TOFU_DIR) init -input=false -lockfile=readonly >/dev/null && tofu -chdir=$(TOFU_DIR) apply -input=false'

backup-secret: ## Fill in the restic repository and known_hosts from the OpenTofu state
	$(TOFU) ./scripts/backup-fill-secret.sh

github-plan: ## OpenTofu: show what changes in the GitHub rulesets (read-only)
	$(GITHUB_TOFU) 'tofu -chdir=$(GITHUB_DIR) init -input=false -lockfile=readonly >/dev/null && tofu -chdir=$(GITHUB_DIR) plan -input=false'

github-apply: ## OpenTofu: apply the GitHub rulesets (changes who can push to main; asks for confirmation)
	$(GITHUB_TOFU) 'tofu -chdir=$(GITHUB_DIR) init -input=false -lockfile=readonly >/dev/null && tofu -chdir=$(GITHUB_DIR) apply -input=false'
