# State and plan encrypted by OpenTofu itself: terraform.tfstate is versioned in git
# (it holds the Storage Box password) and never exists in plain text. The passphrase
# lives in secrets.sops.yaml, which only the control node (Pi) and the recovery key open. Without it the state is unreadable.
variable "state_passphrase" {
  description = "State passphrase (TF_VAR_state_passphrase, exported by the Makefile)"
  type        = string
  sensitive   = true
}

terraform {
  encryption {
    key_provider "pbkdf2" "wsl" {
      passphrase = var.state_passphrase
    }

    method "aes_gcm" "wsl" {
      keys = key_provider.pbkdf2.wsl
    }

    state {
      method   = method.aes_gcm.wsl
      enforced = true
    }

    plan {
      method   = method.aes_gcm.wsl
      enforced = true
    }
  }
}
