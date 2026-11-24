module "personal" {
  source   = "./modules/main_rules"
  for_each = toset(data.github_repositories.personal.names)

  providers = { github = github.personal }

  repository                = each.value
  profile                   = contains(var.strict_repos, "Bemesko/${each.value}") ? "strict" : "app"
  required_approvals        = var.required_approvals
  require_code_owner_review = var.require_code_owner_review
  allow_auto_merge          = var.allow_auto_merge
}

module "org" {
  source   = "./modules/main_rules"
  for_each = toset(data.github_repositories.org.names)

  providers = { github = github.org }

  repository                = each.value
  profile                   = contains(var.strict_repos, "bernats-homelab/${each.value}") ? "strict" : "app"
  required_approvals        = var.required_approvals
  require_code_owner_review = var.require_code_owner_review
  allow_auto_merge          = var.allow_auto_merge
}

# Adopts the repositories that already exist; a no-op once they are in the state. Without it the
# first apply would try to create them.
import {
  for_each = toset(data.github_repositories.personal.names)
  to       = module.personal[each.key].github_repository.this
  id       = each.key
}

import {
  for_each = toset(data.github_repositories.org.names)
  to       = module.org[each.key].github_repository.this
  id       = each.key
}
