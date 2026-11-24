# Branch rules of the homelab repositories, as code (ADR 020). Run only from the control machine
# (Pi or WSL): `make github-plan` / `make github-apply` (the token and passphrase come from
# secrets.sops.yaml).
terraform {
  required_version = "~> 1.13.0"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "6.13.0"
    }
  }
}
