module "personal" {
  source   = "./modules/main_rules"
  for_each = toset(data.github_repositories.personal.names)

  providers = { github = github.personal }

  repository                = each.value
  profile                   = contains(var.strict_repos, "Bemesko/${each.value}") ? "strict" : "app"
  required_approvals        = var.required_approvals
  require_code_owner_review = var.require_code_owner_review
}

module "org" {
  source   = "./modules/main_rules"
  for_each = toset(data.github_repositories.org.names)

  providers = { github = github.org }

  repository                = each.value
  profile                   = contains(var.strict_repos, "bernats-homelab/${each.value}") ? "strict" : "app"
  required_approvals        = var.required_approvals
  require_code_owner_review = var.require_code_owner_review
}
