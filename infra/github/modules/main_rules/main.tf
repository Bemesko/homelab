terraform {
  required_providers {
    github = {
      source = "integrations/github"
    }
  }
}

variable "repository" {
  description = "Repository name (without the owner; the owner is the provider's)"
  type        = string
}

variable "profile" {
  description = "strict: PR + ci-ok + admin bypass on PRs. app: no force push and no deletion only (the release workflow pushes straight to main)"
  type        = string

  validation {
    condition     = contains(["strict", "app"], var.profile)
    error_message = "profile must be strict or app."
  }
}

variable "required_approvals" {
  type    = number
  default = 0
}

variable "require_code_owner_review" {
  type    = bool
  default = false
}

locals {
  strict = var.profile == "strict"
}

# Only rulesets: the module never manages github_repository, so it cannot fight with the
# repository settings or delete a repository.
resource "github_repository_ruleset" "main" {
  name        = "main-protection"
  repository  = var.repository
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  # Emergency path (for example to fix a broken CI): the repository admin can merge a PR over a red
  # ci-ok, never push straight to main. Personal repositories only accept the Admin role (id 5).
  dynamic "bypass_actors" {
    for_each = local.strict ? [1] : []
    content {
      actor_id    = 5
      actor_type  = "RepositoryRole"
      bypass_mode = "pull_request"
    }
  }

  rules {
    deletion         = true
    non_fast_forward = true

    dynamic "pull_request" {
      for_each = local.strict ? [1] : []
      content {
        required_approving_review_count   = var.required_approvals
        require_code_owner_review         = var.require_code_owner_review
        require_last_push_approval        = false
        dismiss_stale_reviews_on_push     = false
        required_review_thread_resolution = true
      }
    }

    # ci-ok is the only required check (ADR 015): a skipped e2e must not block a PR. Pinned to the
    # GitHub Actions app (15368) so no other app can report a check with that name.
    dynamic "required_status_checks" {
      for_each = local.strict ? [1] : []
      content {
        strict_required_status_checks_policy = true

        required_check {
          context        = "ci-ok"
          integration_id = 15368
        }
      }
    }
  }
}
