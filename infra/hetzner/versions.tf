# NAS off-site copy: Hetzner Storage Box (ADR 014). Run only from WSL:
# `make tofu-plan` / `make tofu-apply` (the token and passphrase come from secrets.sops.yaml).
terraform {
  required_version = "~> 1.13.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "1.70.2"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.9.1"
    }
  }
}

# Token in HCLOUD_TOKEN (exported by the Makefile from SOPS).
provider "hcloud" {}
