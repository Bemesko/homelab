# 020 — GitHub branch rules as code (OpenTofu)

- **Status:** accepted
- **Date:** 2026-11-24
- **Issue:** #39 (follows [ADR 015](015-ci-flow-and-required-checks.md), which chose `ci-ok` as the one required check)

## Context

The `make` targets apply the checked-out branch to the real hosts, so whatever reaches `main` is what Ansible applies. Until now nothing stopped a direct push, a force push or a merge with a red CI. The first fix would be a few `gh api` commands or a click in the UI, but those leave no record, cannot be reviewed and are forgotten for the next repository.

Facts that shaped the design:

- `homelab` and `grocery-ops` live in the **personal** account, the template and `bernats-finances-v4` in the `bernats-homelab` **organization**. Organization-level rulesets would not cover the personal repositories.
- The organization is on the Free plan: GitHub does not enforce rulesets on its **private** repositories (`bernats-finances-v4`).
- Every recent PR was opened and merged by one person with no review; the second person has not committed yet.
- The app repositories' `release.yaml` pushes a "Release vX" commit straight to `main` as `github-actions[bot]`. Their CI has no `ci-ok` job.
- GitHub copies neither rulesets nor topics from a template repository to the repositories created from it.

## Decision

Rulesets are defined in **OpenTofu** in `infra/github/`, with the same scheme as `infra/hetzner/` (ADR 019): the state is encrypted by OpenTofu (pbkdf2 + AES-GCM) and versioned in git, the token and the passphrase live in `infra/github/secrets.sops.yaml`, and `make github-plan` / `make github-apply` run from the control node through `sops exec-env`. The configuration manages **only rulesets**, never `github_repository`, so it cannot fight with repository settings or delete a repository.

**Scope by topic.** A public repository with the topic `homelab-managed` is in scope; two `github_repositories` data sources (personal account and organization) find them, and a module creates the ruleset in each. A new repository is added by giving it the topic and running `make github-apply`. A `check` block warns at plan time when a repository listed in `strict_repos` was not found.

**Two profiles**, both on the default branch:

| Profile | Repositories | Rules |
|---|---|---|
| `strict` | `Bemesko/homelab` (variable `strict_repos`) | no deletion, no force push, **PR required** (0 approvals, conversations resolved), **`ci-ok` required** with the branch up to date, pinned to the GitHub Actions app |
| `app` | every other repository in scope | no deletion and no force push only |

- `ci-ok` is the only required check (ADR 015): a skipped `e2e` counts as passed, and renaming the job breaks the protection.
- **0 approvals** (`required_approvals`) because one person opens and merges every PR; an approval from an account that cannot approve its own PR would only force the admin bypass. `.github/CODEOWNERS` already marks the sensitive areas (`ansible/`, `.sops.yaml`, `kubernetes/apps/`, `.github/`, `infra/`) and asks for review; raise `required_approvals` to 1 and set `require_code_owner_review` when the second person starts reviewing.
- **Emergency bypass:** the repository Admin role, `bypass_mode = pull_request`. When the CI itself is broken, the admin merges a PR over the red check (visible in the PR). A direct push is never allowed. Personal repositories only accept the Admin role as a bypass actor.
- **The `app` profile requires no PR and no check** because a required status check or a PR rule rejects the release workflow's push to `main`. The cost is that an app's `main` accepts direct pushes; the alternatives (a GitHub App as bypass actor, or the release opening a PR with auto-merge) can come later without changing this layout.
- Not enabled: linear history (the repository uses merge commits), signed commits (agent and Windows commits are unsigned).

## Consequences

- After the first `make github-apply`, `homelab` `main` takes only PRs with `ci-ok` green. The commit of the updated, encrypted `terraform.tfstate` goes through a PR like any other change; that is the intended flow. Commits that used to land directly on `main` ("Update targetRevision for ...") become PRs.
- `infra/` changes skip the `e2e` (`scripts/ci-changes.sh`): they never run in the bootstrap, and the `tofu-validate` hook covers fmt and validate.
- A new repository **is not protected until it has the topic and `make github-apply` runs**: the template cannot carry rules or topics. The template's `scripts/init.sh` and README should add the topic (a change in `repotpl-k8s-app`, not here). The plan shows what would change, but nothing runs on a schedule: a drift check in CI would need the token and the passphrase as GitHub secrets, which was left out on purpose.
- `bernats-finances-v4` is private on a Free organization and stays unprotected (the discovery filters `is:public`, so the plan does not try). Making it public or upgrading the plan brings it in with no code change.
- The token needs Administration (read and write) on the repositories in scope, and on the organization for the org repositories. It is the most privileged secret in the repository; it lives only in `secrets.sops.yaml` and is opened on the control node.
