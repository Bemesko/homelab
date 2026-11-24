# Repositories in scope = public ones carrying the topic. `is:public` is deliberate: on a Free
# organization GitHub does not enforce rulesets on private repositories (bernats-finances-v4), so
# creating one there would fail or give a false sense of protection.
#
# The search API indexes topics with a short delay: a topic added a minute ago may not show up yet.
data "github_repositories" "personal" {
  provider = github.personal
  query    = "user:Bemesko topic:${var.topic} is:public"
}

data "github_repositories" "org" {
  provider = github.org
  query    = "org:bernats-homelab topic:${var.topic} is:public"
}

# A strict repository that was not discovered would silently stay unprotected: warn at plan time.
check "strict_repos_discovered" {
  assert {
    condition = alltrue([
      for repo in var.strict_repos :
      contains(concat(
        [for name in data.github_repositories.personal.names : "Bemesko/${name}"],
        [for name in data.github_repositories.org.names : "bernats-homelab/${name}"],
      ), repo)
    ])
    error_message = "A repository in strict_repos was not found with the topic '${var.topic}' (public, topic added, search index delay?). It is NOT protected."
  }
}
