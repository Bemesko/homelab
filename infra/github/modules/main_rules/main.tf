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

variable "allow_auto_merge" {
  type    = bool
  default = true
}

locals {
  strict = var.profile == "strict"
}

# The repository itself is only ADOPTED (import blocks in the root module) to turn auto-merge on:
# the provider has no resource for a single setting, so every other attribute is ignored and the
# repository can never be destroyed by this configuration.
resource "github_repository" "this" {
  name             = var.repository
  allow_auto_merge = var.allow_auto_merge

  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      allow_forking,
      allow_merge_commit,
      allow_rebase_merge,
      allow_squash_merge,
      allow_update_branch,
      archive_on_destroy,
      archived,
      auto_init,
      default_branch,
      delete_branch_on_merge,
      description,
      fork,
      gitignore_template,
      has_discussions,
      has_downloads,
      has_issues,
      has_projects,
      has_wiki,
      homepage_url,
      ignore_vulnerability_alerts_during_read,
      is_template,
      license_template,
      merge_commit_message,
      merge_commit_title,
      pages,
      private,
      security_and_analysis,
      source_owner,
      source_repo,
      squash_merge_commit_message,
      squash_merge_commit_title,
      template,
      topics,
      visibility,
      vulnerability_alerts,
      web_commit_signoff_required,
    ]
  }
}

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
