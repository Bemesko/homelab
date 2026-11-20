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

# OpenTofu (Hetzner Storage Box): HCLOUD_TOKEN and TF_VAR_state_passphrase come from SOPS.
TOFU_DIR := infra/hetzner
TOFU := sops exec-env $(TOFU_DIR)/secrets.sops.yaml

.PHONY: help deps lint test-unit test-render test check-inventory plan apply idempotency kernel-upgrade kubeconfig reset \
	tofu-plan tofu-apply backup-secret

help: ## List the targets
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

deps: ## Install the control machine tools (pinned versions)
	./scripts/setup-control-node.sh

lint: ## All pre-commit hooks on all files
	pre-commit run --all-files

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
	cd ansible && $(PLAYBOOK) site.yaml --check --diff

apply: check-inventory lint ## Apply to the laptop (runs lint first)
	cd ansible && $(PLAYBOOK) site.yaml

idempotency: check-inventory ## Re-apply and fail if anything changes
	cd ansible && ../scripts/assert-idempotent.sh site.yaml $(BECOME_FLAGS)

kernel-upgrade: check-inventory ## Upgrade the kernel, reboot the laptop and validate the cluster (ADR 010)
	cd ansible && $(PLAYBOOK) kernel-upgrade.yaml

kubeconfig: check-inventory ## Update ~/.kube/notebook.yaml
	cd ansible && $(PLAYBOOK) site.yaml --tags kubeconfig

reset: check-inventory ## Remove k3s from the laptop (asks for confirmation)
	cd ansible && $(PLAYBOOK) reset.yaml

tofu-plan: ## OpenTofu: show what changes on the Hetzner Storage Box
	$(TOFU) 'tofu -chdir=$(TOFU_DIR) init -input=false -lockfile=readonly >/dev/null && tofu -chdir=$(TOFU_DIR) plan -input=false'

tofu-apply: ## OpenTofu: apply to the Storage Box (bills the Hetzner account; asks for confirmation)
	$(TOFU) 'tofu -chdir=$(TOFU_DIR) init -input=false -lockfile=readonly >/dev/null && tofu -chdir=$(TOFU_DIR) apply -input=false'

backup-secret: ## Fill in the restic repository and known_hosts from the OpenTofu state
	$(TOFU) ./scripts/backup-fill-secret.sh
