#!/usr/bin/env bash
# CI helper (docs/adr/015): decides whether the e2e (k3s + ArgoCD on the runner) is worth running, and how much of it.
# Prints `e2e=true|false` and `e2e_profile=none|lite|full` (append them to $GITHUB_OUTPUT).
#
# Environment:
#   EVENT_NAME  GitHub event (pull_request, push, schedule, workflow_dispatch)
#   BASE_SHA    base commit of the pull request (the diff is BASE_SHA..HEAD)
#
# Rule: the highest profile among the changed files wins.
#   full: the change reaches what ArgoCD deploys (charts, Helm values, workloads), so every Application
#         has to become Healthy. Automerge relies on this gate (docs/adr/021).
#   lite: the change can affect the host bootstrap. Unknown paths land here (fail-safe).
#   none: every changed file is known not to affect the cluster.
set -euo pipefail

# profile_for <path>: prints the profile a change to <path> needs.
profile_for() {
  case "$1" in
    # Docs and repo metadata.
    docs/* | *.md | LICENSE | .gitignore | .github/ISSUE_TEMPLATE/* | .github/CODEOWNERS) echo none ;;
    # Renovate configuration: validated by the renovate-config-validator hook in lint.
    renovate.json | renovate/*) echo none ;;
    # OpenTofu (infra/hetzner, infra/github) runs from the control machine, never from the bootstrap;
    # the tofu-validate hook in lint covers fmt + validate.
    infra/*) echo none ;;
    # Shared pipeline library: only the app repositories run it.
    pipelines/*) echo none ;;
    kubernetes/apps/values.yaml) values_profile ;;
    kubernetes/values/* | kubernetes/workloads/*) echo full ;;
    # Scripts and hooks that only lint/render use.
    scripts/check-alert-rules.py | scripts/check-no-lockout.sh | scripts/check-sops-encrypted.sh) echo none ;;
    scripts/kustomize-build.sh | scripts/render-manifests.sh | scripts/validate-manifests.sh) echo none ;;
    scripts/vendor-dashboards.sh | scripts/ksops-stub.py | .pre-commit-config.yaml | Makefile) echo none ;;
    scripts/check-chart-images.py | scripts/update-checksums.sh) echo none ;;
    # Everything else (ansible/, kubernetes/apps/, kubernetes/bootstrap/, tests/, the e2e scripts, the
    # CI definition, unknown paths) runs the bootstrap.
    *) echo lite ;;
  esac
}

# kubernetes/apps/values.yaml holds the chart versions and the external app tags: a change to its data is a
# deploy (full). Comments and formatting are not (none), and neither is a new version of one of our own apps
# (`apps.<name>.targetRevision`): their owners decide when to deploy (docs/adr/021). Adding, removing or
# repointing an app is still full. Any doubt counts as changed.
values_profile() {
  local file="kubernetes/apps/values.yaml" base head status=0
  base="$(git show "${BASE_SHA}:${file}" 2>/dev/null || true)"
  head="$(cat "${file}" 2>/dev/null || true)"
  # Exit 0: same platform data; anything else (changed, no PyYAML, bad YAML) counts as changed.
  python3 - "${base}" "${head}" <<'PY' || status=$?
import sys

import yaml


def platform_data(text):
    data = yaml.safe_load(text)
    for app in (data.get("apps") or {}).values():
        app.pop("targetRevision", None)
    return data


sys.exit(0 if platform_data(sys.argv[1]) == platform_data(sys.argv[2]) else 10)
PY
  if [[ "${status}" -eq 0 ]]; then
    echo none
  else
    echo full
  fi
}

main() {
  local profile=none changed="" path needed

  # Only pull requests are classified: main already ran in the PR, nightly/dispatch call e2e-full directly.
  if [[ "${EVENT_NAME:-}" == "pull_request" ]]; then
    # Captured first so that a failing git diff aborts instead of reading as "nothing changed".
    changed="$(git diff --name-only --no-renames "${BASE_SHA}" HEAD)"
  fi

  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    needed="$(profile_for "${path}")"
    if [[ "${needed}" == "full" ]]; then
      echo "e2e full needed: ${path}" >&2
      profile=full
      break
    fi
    if [[ "${needed}" == "lite" && "${profile}" == "none" ]]; then
      echo "e2e lite needed: ${path}" >&2
      profile=lite
    fi
  done <<<"${changed}"

  if [[ "${profile}" == "none" ]]; then
    echo "e2e=false"
  else
    echo "e2e=true"
  fi
  echo "e2e_profile=${profile}"
}

main "$@"
