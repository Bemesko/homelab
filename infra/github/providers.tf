# A ruleset lives in the owner of the provider that creates it, so the personal account (homelab,
# grocery-ops) and the organization (the template and the apps) each get their own instance of the
# provider. A fine-grained token belongs to ONE owner, hence one token per provider
# (TF_VAR_github_token_*, exported by the Makefile from SOPS).
provider "github" {
  alias = "personal"
  owner = "Bemesko"
  token = var.github_token_personal
}

provider "github" {
  alias = "org"
  owner = "bernats-homelab"
  token = var.github_token_org
}
