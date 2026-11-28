#!/usr/bin/env bash
# Recomputes the sha256 pins of the downloaded tools from the versions written in the repository
# (docs/adr/021). Renovate runs it in the pull request that bumps a version; run it by hand after
# editing a version yourself.
#
# Usage: scripts/update-checksums.sh <dependency>...   (the depName of the `# renovate:` comment)
#        scripts/update-checksums.sh --changed <git-rev> (versions that differ from that revision)
#        scripts/update-checksums.sh --all
#
# The CI runs --changed on every pull request and fails if it rewrites anything.
#
# Each artifact is downloaded into a temporary directory and never executed. Its hash is compared with
# the checksum file the project publishes, when there is one, and only the sha256 values are rewritten.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly SETUP="${REPO_ROOT}/scripts/setup-control-node.sh"
readonly GROUP_VARS="${REPO_ROOT}/ansible/group_vars/all/main.yaml"
readonly TAILSCALE="${REPO_ROOT}/ansible/roles/control_node_tailscale/defaults/main.yaml"
readonly GITHUB="https://github.com"
# Every version that has a sha256 next to it: <dependency> <file> <name>
readonly VERSION_PINS=(
  "k3s-io/k3s ${GROUP_VARS} k3s_version"
  "helm/helm ${SETUP} HELM_VERSION"
  "helm/helm ${GROUP_VARS} helm_version"
  "getsops/sops ${SETUP} SOPS_VERSION"
  "FiloSottile/age ${SETUP} AGE_VERSION"
  "kubernetes/kubernetes ${SETUP} KUBECTL_VERSION"
  "opentofu/opentofu ${SETUP} TOFU_VERSION"
  "yannh/kubeconform ${SETUP} KUBECONFORM_VERSION"
  "stackrox/kube-linter ${SETUP} KUBE_LINTER_VERSION"
  "kubernetes-sigs/kustomize ${SETUP} KUSTOMIZE_VERSION"
  "open-telemetry/opentelemetry-collector-releases ${GROUP_VARS} otel_host_agent_version"
  "syncthing/syncthing ${GROUP_VARS} nas_syncthing_version"
  "tailscale/tailscale ${TAILSCALE} control_node_tailscale_version"
)

WORK="$(mktemp -d)"
readonly WORK
trap 'rm -rf "${WORK}"' EXIT

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# read_version <name>: the value of a YAML key or of a readonly constant, from stdin
read_version() {
  sed -nE "s/^(readonly )?$1(: |=)\"?([A-Za-z0-9.+_-]+)\"?\$/\3/p"
}

# version_of <file> <name>
version_of() {
  local value
  value="$(read_version "$2" <"$1")"
  [[ -n "${value}" && "${value}" != *$'\n'* ]] || die "$2 must appear exactly once in ${1#"${REPO_ROOT}/"}"
  printf '%s' "${value}"
}

all_dependencies() {
  printf '%s\n' "${VERSION_PINS[@]}" | cut -d' ' -f1 | uniq
}

# changed_since <git-rev>: dependencies with a version that differs from the revision
changed_since() {
  local rev="$1" pin dependency file name before now
  git -C "${REPO_ROOT}" rev-parse -q --verify "${rev}^{commit}" >/dev/null || die "unknown revision: ${rev}"
  for pin in "${VERSION_PINS[@]}"; do
    read -r dependency file name <<<"${pin}"
    now="$(version_of "${file}" "${name}")"
    # A file or a pin that did not exist there counts as changed.
    before="$(git -C "${REPO_ROOT}" show "${rev}:${file#"${REPO_ROOT}/"}" 2>/dev/null | read_version "${name}" || true)"
    if [[ "${before}" != "${now}" ]]; then
      echo "${dependency}"
    fi
  done | uniq
}

fetch() {
  curl -fsSL --retry 3 --retry-all-errors -o "$2" "$1" || die "download failed: $1"
}

# published <checksums-file> <asset>: the hash listed for the asset, or the only hash of a one-line file
published() {
  awk -v asset="$2" '
    $2 == asset || $2 == "*" asset { print $1; found = 1; exit }
    NR == 1 && NF == 1 { only = $1 }
    END { if (!found && NR == 1) print only }
  ' "$1"
}

# pin <file> <name> <artifact-url> [checksums-url]
pin() {
  local file="$1" name="$2" url="$3" checksums="${4:-}" sha expected
  echo "  ${name} <- ${url}"
  fetch "${url}" "${WORK}/artifact"
  sha="$(sha256sum "${WORK}/artifact" | cut -d' ' -f1)"
  if [[ -n "${checksums}" ]]; then
    fetch "${checksums}" "${WORK}/checksums"
    expected="$(published "${WORK}/checksums" "${url##*/}")"
    [[ "${expected}" == "${sha}" ]] ||
      die "${url##*/}: downloaded sha256 ${sha} differs from the published one '${expected}' (${checksums})"
  fi
  sed -i -E "s/^((readonly )?${name}(: |=)\"?)[0-9a-f]{64}(\"?)\$/\1${sha}\4/" "${file}"
  grep -Eq "^(readonly )?${name}(: |=)\"?${sha}\"?\$" "${file}" || die "${name} not found in ${file#"${REPO_ROOT}/"}"
}

update() {
  local version arch release url
  echo "==> $1"
  case "$1" in
    k3s-io/k3s)
      # The installer script at the release tag; it checks the k3s binary against the release itself.
      version="$(version_of "${GROUP_VARS}" k3s_version)"
      pin "${GROUP_VARS}" k3s_install_script_sha256 \
        "https://raw.githubusercontent.com/k3s-io/k3s/${version//+/%2B}/install.sh"
      ;;
    helm/helm)
      version="$(version_of "${SETUP}" HELM_VERSION)"
      [[ "$(version_of "${GROUP_VARS}" helm_version)" == "${version}" ]] ||
        die "helm: HELM_VERSION and helm_version differ"
      url="https://get.helm.sh/helm-${version}-linux-amd64.tar.gz"
      pin "${GROUP_VARS}" helm_sha256 "${url}" "${url}.sha256sum"
      for arch in amd64 arm64; do
        url="https://get.helm.sh/helm-${version}-linux-${arch}.tar.gz"
        pin "${SETUP}" "HELM_SHA256_${arch^^}" "${url}" "${url}.sha256sum"
      done
      ;;
    getsops/sops)
      version="$(version_of "${SETUP}" SOPS_VERSION)"
      release="${GITHUB}/getsops/sops/releases/download/${version}"
      for arch in amd64 arm64; do
        pin "${SETUP}" "SOPS_SHA256_${arch^^}" "${release}/sops-${version}.linux.${arch}" \
          "${release}/sops-${version}.checksums.txt"
      done
      ;;
    FiloSottile/age)
      version="$(version_of "${SETUP}" AGE_VERSION)"
      release="${GITHUB}/FiloSottile/age/releases/download/${version}"
      for arch in amd64 arm64; do
        pin "${SETUP}" "AGE_SHA256_${arch^^}" "${release}/age-${version}-linux-${arch}.tar.gz"
      done
      ;;
    kubernetes/kubernetes)
      version="$(version_of "${SETUP}" KUBECTL_VERSION)"
      for arch in amd64 arm64; do
        url="https://dl.k8s.io/release/${version}/bin/linux/${arch}/kubectl"
        pin "${SETUP}" "KUBECTL_SHA256_${arch^^}" "${url}" "${url}.sha256"
      done
      ;;
    opentofu/opentofu)
      version="$(version_of "${SETUP}" TOFU_VERSION)"
      release="${GITHUB}/opentofu/opentofu/releases/download/${version}"
      for arch in amd64 arm64; do
        pin "${SETUP}" "TOFU_SHA256_${arch^^}" "${release}/tofu_${version#v}_linux_${arch}.tar.gz" \
          "${release}/tofu_${version#v}_SHA256SUMS"
      done
      ;;
    yannh/kubeconform)
      version="$(version_of "${SETUP}" KUBECONFORM_VERSION)"
      release="${GITHUB}/yannh/kubeconform/releases/download/${version}"
      pin "${SETUP}" KUBECONFORM_SHA256 "${release}/kubeconform-linux-amd64.tar.gz" "${release}/CHECKSUMS"
      ;;
    stackrox/kube-linter)
      version="$(version_of "${SETUP}" KUBE_LINTER_VERSION)"
      pin "${SETUP}" KUBE_LINTER_SHA256 \
        "${GITHUB}/stackrox/kube-linter/releases/download/${version}/kube-linter-linux.tar.gz"
      ;;
    kubernetes-sigs/kustomize)
      version="$(version_of "${SETUP}" KUSTOMIZE_VERSION)"
      release="${GITHUB}/kubernetes-sigs/kustomize/releases/download/kustomize%2F${version}"
      pin "${SETUP}" KUSTOMIZE_SHA256 "${release}/kustomize_${version}_linux_amd64.tar.gz" "${release}/checksums.txt"
      ;;
    open-telemetry/opentelemetry-collector-releases)
      version="$(version_of "${GROUP_VARS}" otel_host_agent_version)"
      release="${GITHUB}/open-telemetry/opentelemetry-collector-releases/releases/download/v${version}"
      for arch in amd64 arm64; do
        url="${release}/otelcol-contrib_${version}_linux_${arch}.deb"
        pin "${GROUP_VARS}" "otel_host_agent_deb_sha256_${arch}" "${url}" "${url}.sha256"
      done
      ;;
    syncthing/syncthing)
      version="$(version_of "${GROUP_VARS}" nas_syncthing_version)"
      # sha256sum.txt.asc of the release does not list the .deb packages.
      pin "${GROUP_VARS}" nas_syncthing_deb_sha256 \
        "${GITHUB}/syncthing/syncthing/releases/download/v${version}/syncthing_${version}_amd64.deb"
      ;;
    tailscale/tailscale)
      version="$(version_of "${TAILSCALE}" control_node_tailscale_version)"
      url="https://pkgs.tailscale.com/stable/tailscale_${version}_arm64.tgz"
      pin "${TAILSCALE}" control_node_tailscale_arm64_sha256 "${url}" "${url}.sha256"
      ;;
    *)
      die "no sha256 pin is known for '$1' (known: $(all_dependencies | tr '\n' ' '))"
      ;;
  esac
}

main() {
  local targets=("$@") dependency list
  [[ $# -gt 0 ]] || die "usage: $0 <dependency>... | --changed <git-rev> | --all"
  case "$1" in
    --all) mapfile -t targets < <(all_dependencies) ;;
    --changed)
      [[ $# -eq 2 ]] || die "usage: $0 --changed <git-rev>"
      # Captured first so that a failure aborts instead of reading as "nothing changed".
      list="$(changed_since "$2")"
      if [[ -z "${list}" ]]; then
        echo "no sha256-pinned version changed since $2"
        return 0
      fi
      mapfile -t targets <<<"${list}"
      ;;
  esac
  for dependency in "${targets[@]}"; do
    update "${dependency}"
  done
}

main "$@"
