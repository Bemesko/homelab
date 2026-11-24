#!/usr/bin/env bash
# CI helper (docs/adr/015): decides whether the e2e (k3s + ArgoCD on the runner) is worth running.
# Prints `e2e=true` or `e2e=false` (append it to $GITHUB_OUTPUT).
#
# Environment:
#   EVENT_NAME  GitHub event (pull_request, push, schedule, workflow_dispatch)
#   BASE_SHA    base commit of the pull request (the diff is BASE_SHA..HEAD)
#
# Rule: a PR runs the e2e unless EVERY changed file is known not to affect the host bootstrap.
# Unknown paths therefore run it (fail-safe); the nightly e2e-full is the second safety net.
set -euo pipefail

# skips_e2e <path>: succeeds when a change to <path> cannot affect the bootstrap
# (Ansible, ArgoCD install + root Application, KSOPS, reset).
skips_e2e() {
  case "$1" in
    # Docs and repo metadata.
    docs/* | *.md | LICENSE | .gitignore | .github/ISSUE_TEMPLATE/* | .github/CODEOWNERS) return 0 ;;
    # OpenTofu (infra/hetzner, infra/github) runs from the control machine, never from the bootstrap;
    # the tofu-validate hook in lint covers fmt + validate.
    infra/*) return 0 ;;
    # hello-world is the demo the e2e uses to prove KSOPS: its changes need the cluster (first match wins).
    kubernetes/workloads/hello-world/*) return 1 ;;
    # Workloads: ArgoCD syncs them from main; kubeconform/kube-linter validate them, and an app that does
    # not become Healthy shows up as an alert (ADR 015). The nightly e2e-full covers the rest.
    kubernetes/workloads/*) return 0 ;;
    # Scripts and hooks that only lint/render use.
    scripts/check-alert-rules.py | scripts/check-no-lockout.sh | scripts/check-sops-encrypted.sh) return 0 ;;
    scripts/kustomize-build.sh | scripts/render-manifests.sh | scripts/validate-manifests.sh) return 0 ;;
    scripts/vendor-dashboards.sh | scripts/ksops-stub.py | .pre-commit-config.yaml | Makefile) return 0 ;;
    # Everything else (ansible/, kubernetes/apps/, kubernetes/bootstrap/, tests/, the e2e scripts, the
    # CI definition, unknown paths) runs the e2e.
    *) return 1 ;;
  esac
}

# kubernetes/apps/values.yaml also holds the ArgoCD chart version, which the initial Ansible install reads.
# Only a change to that block counts; other chart bumps (Renovate) do not. Any doubt counts as changed.
argocd_chart_changed() {
  local file="kubernetes/apps/values.yaml" base head
  base="$(git show "${BASE_SHA}:${file}" 2>/dev/null || true)"
  head="$(cat "${file}")"
  local status=0
  # Exit 0: unchanged, 10: changed; anything else (no PyYAML, bad YAML) is a doubt, so it counts as changed.
  python3 - "${base}" "${head}" <<'PY' || status=$?
import sys
import yaml

def argocd(text):
    return (yaml.safe_load(text) or {}).get("charts", {}).get("argocd")

sys.exit(10 if argocd(sys.argv[1]) != argocd(sys.argv[2]) else 0)
PY
  [[ "${status}" -ne 0 ]]
}

main() {
  # Only pull requests are classified: main already ran in the PR, nightly/dispatch call e2e-full directly.
  if [[ "${EVENT_NAME:-}" != "pull_request" ]]; then
    echo "e2e=false"
    return 0
  fi

  local path
  while IFS= read -r path; do
    if [[ "${path}" == "kubernetes/apps/values.yaml" ]]; then
      if argocd_chart_changed; then
        echo "e2e needed: ${path} (charts.argocd changed)" >&2
        echo "e2e=true"
        return 0
      fi
      continue
    fi
    if ! skips_e2e "${path}"; then
      echo "e2e needed: ${path}" >&2
      echo "e2e=true"
      return 0
    fi
  done < <(git diff --name-only "${BASE_SHA}" HEAD)

  echo "e2e=false"
}

main "$@"
