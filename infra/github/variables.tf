variable "github_token_personal" {
  description = "Fine-grained token owned by the Bemesko account (Administration: read and write on the repositories in scope)"
  type        = string
  sensitive   = true
}

variable "github_token_org" {
  description = "Fine-grained token whose resource owner is bernats-homelab (Administration: read and write on the repositories in scope)"
  type        = string
  sensitive   = true
}

variable "topic" {
  description = "GitHub topic that puts a public repository in scope (added by hand: `gh repo edit --add-topic`)"
  type        = string
  default     = "homelab-managed"
}

variable "strict_repos" {
  description = "owner/name of the repositories that get the strict profile (PR + ci-ok); every other discovered repository gets the app profile"
  type        = set(string)
  default     = ["Bemesko/homelab"]
}

variable "required_approvals" {
  description = "Approvals the strict profile asks for. 0 while every PR is opened and merged by one person; raise it when the other person starts reviewing"
  type        = number
  default     = 0
}

variable "require_code_owner_review" {
  description = "Strict profile: also require a review from the owners in .github/CODEOWNERS (only takes effect with required_approvals >= 1)"
  type        = bool
  default     = false
}
