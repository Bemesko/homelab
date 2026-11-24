# Token in GITHUB_TOKEN (exported by the Makefile from SOPS). A ruleset lives in the owner of the
# provider that creates it, so the personal account (homelab, grocery-ops) and the organization
# (the template and the apps) each get their own instance of the provider.
provider "github" {
  alias = "personal"
  owner = "Bemesko"
}

provider "github" {
  alias = "org"
  owner = "bernats-homelab"
}
