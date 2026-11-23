#!/usr/bin/env bash
# Prepares the control machine: tools with pinned version and sha256 in ~/.local/bin +
# Ansible collections.
#
#   x86_64 (WSL Ubuntu, the CI runner)  all tools: runtime + dev/test    (--full, the default)
#   aarch64 (the Raspberry Pi)          runtime only                      (--runtime, the default)
#
# Runtime = what `make plan/apply/kubeconfig` needs: ansible-core, sops, age, helm, kubectl, tofu
# (`make tofu-plan/tofu-apply`) and the collections. Dev/test tools (pre-commit, ansible-lint, kubeconform, kube-linter, kustomize,
# helm-unittest) stay on x86_64 and in the CI.
# SETUP_SKIP_APT=1 skips the apt step (the Ansible role control_node_toolchain installs the packages).
set -euo pipefail

readonly BIN_DIR="${HOME}/.local/bin"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

# --- pinned versions (update version + sha256 of EVERY architecture together) -------------------
readonly ANSIBLE_CORE_VERSION="2.21.5"
readonly ANSIBLE_LINT_VERSION="26.10.1"
readonly PRE_COMMIT_VERSION="4.7.0"
readonly KUBERNETES_PY_VERSION="37.0.1"
# For the Ansible OpenTelemetry callback, enabled only on the control node (see the Makefile).
readonly OTEL_PY_VERSION="1.45.2"

readonly SOPS_VERSION="v3.13.3"
readonly SOPS_SHA256_AMD64="e5bec3346a873ae91d871550f3e698c1aad962aff462a080e40f25fde17fef6b"
readonly SOPS_SHA256_ARM64="53b0abacd38ef1b12a66d6c100956691b9cefce018d91f81e73ddf7438b94d77"
readonly AGE_VERSION="v1.3.2"
readonly AGE_SHA256_AMD64="cbe24006683f8eb669266162894b9a522a1af52f2665fbc63a4bb032ed26ac10"
readonly AGE_SHA256_ARM64="6b8dc4333c53a5a57c9e5834e3a48f92605d7154014cd07269ff3327db5d37f4"
readonly HELM_VERSION="v4.3.1"
readonly HELM_SHA256_AMD64="0403a88ae20913d11b10a2467b50087721fea7581736da6b9d3992f5357fe54b"
readonly HELM_SHA256_ARM64="8cf8f66ecbc252ac8f7f06cca68aba88508ddfde3a6a34feb1678ad1694b4f88"
readonly KUBECTL_VERSION="v1.37.1"
readonly KUBECTL_SHA256_AMD64="65691ff77eb6fa44c908b77a1082c9f092c3b9733b5cefabec0d1104890e21a8"
readonly KUBECTL_SHA256_ARM64="ff749f4b78d9c4f1ec87307df9b50119ed819e2094aa9810cb9acffc3286c8c7"
# OpenTofu for infra/hetzner (`make tofu-plan/tofu-apply`, ADR 017).
readonly TOFU_VERSION="v1.13.9"
readonly TOFU_SHA256_AMD64="b34b327cc1ef07178207b6f2cd1f5276537d3e5b7be316500f6dac50d4c0a857"
readonly TOFU_SHA256_ARM64="5dc196dde75b667e4806d358310ec96742774cd0993c54c1237efee5644b69b8"

# Dev/test tools: x86_64 only.
readonly KUBECONFORM_VERSION="v0.8.0"
readonly KUBECONFORM_SHA256="9bc2bffbf71f261128533edaf912153948b7ff238f9a531ae6d34466ec287883"
readonly KUBE_LINTER_VERSION="v0.8.3"
readonly KUBE_LINTER_SHA256="1a6d8419b11971372971fdbc22682b684ebfb7cf1c39591662d1b6ca736c41df"
readonly KUSTOMIZE_VERSION="v5.8.3"
readonly KUSTOMIZE_SHA256="cb9e31198d3f63b44848bd0afc4c8efc56e6cfef9c93a4a39a211940e6decd61"
readonly HELM_UNITTEST_VERSION="v1.2.1"
# ---------------------------------------------------------------------------------------------

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# download <url> <sha256> <dest>
download() {
  local url="$1" sha="$2" dest="$3"
  curl -fsSL --retry 3 -o "${dest}" "${url}"
  echo "${sha}  ${dest}" | sha256sum --check --quiet -
}

# install_bin <name> <version> <url> <sha256> [path-inside-tar]
install_bin() {
  local name="$1" version="$2" url="$3" sha="$4" member="${5:-}"
  local stamp="${BIN_DIR}/.${name}-${version}"
  if [[ -f "${stamp}" && -x "${BIN_DIR}/${name}" ]]; then
    return 0
  fi
  log "installing ${name} ${version}"
  local tmp
  tmp="$(mktemp -d)"
  download "${url}" "${sha}" "${tmp}/artifact"
  if [[ -n "${member}" ]]; then
    tar -xzf "${tmp}/artifact" -C "${tmp}" "${member}"
    install -m 0755 "${tmp}/${member}" "${BIN_DIR}/${name}"
  else
    install -m 0755 "${tmp}/artifact" "${BIN_DIR}/${name}"
  fi
  rm -rf "${tmp}" "${BIN_DIR}/.${name}-"*
  touch "${stamp}"
}

# Sets ARCH (the Go name used in the release URLs), MODE and the per-architecture sha256 variables.
detect_platform() {
  local machine mode_arg="${1:-}"
  if [[ "$(uname -s)" != "Linux" ]]; then
    echo "Run on Linux: WSL Ubuntu x86_64, a CI runner or the Raspberry Pi (aarch64)." >&2
    exit 1
  fi
  machine="$(uname -m)"
  case "${machine}" in
    x86_64)
      ARCH=amd64
      SOPS_SHA256="${SOPS_SHA256_AMD64}"
      AGE_SHA256="${AGE_SHA256_AMD64}"
      HELM_SHA256="${HELM_SHA256_AMD64}"
      KUBECTL_SHA256="${KUBECTL_SHA256_AMD64}"
      TOFU_SHA256="${TOFU_SHA256_AMD64}"
      MODE="${mode_arg:-full}"
      ;;
    aarch64)
      ARCH=arm64
      SOPS_SHA256="${SOPS_SHA256_ARM64}"
      AGE_SHA256="${AGE_SHA256_ARM64}"
      HELM_SHA256="${HELM_SHA256_ARM64}"
      KUBECTL_SHA256="${KUBECTL_SHA256_ARM64}"
      TOFU_SHA256="${TOFU_SHA256_ARM64}"
      MODE="${mode_arg:-runtime}"
      ;;
    *)
      echo "Unsupported architecture ${machine}: x86_64 and aarch64 only." >&2
      exit 1
      ;;
  esac
  case "${MODE}" in
    full | runtime) ;;
    *)
      echo "Usage: $0 [--full|--runtime]" >&2
      exit 1
      ;;
  esac
  if [[ "${MODE}" == "full" && "${ARCH}" != "amd64" ]]; then
    echo "The dev/test tools are only pinned for x86_64; use --runtime on ${machine}." >&2
    exit 1
  fi
}

main() {
  local mode_arg=""
  case "${1:-}" in
    --full) mode_arg=full ;;
    --runtime) mode_arg=runtime ;;
    "") ;;
    *)
      echo "Usage: $0 [--full|--runtime]" >&2
      exit 1
      ;;
  esac
  detect_platform "${mode_arg}"
  log "platform: ${ARCH}, mode: ${MODE}"

  mkdir -p "${BIN_DIR}"
  case ":${PATH}:" in
    *":${BIN_DIR}:"*) ;;
    *) echo "Add ${BIN_DIR} to the PATH (e.g. in ~/.bashrc)." >&2 ;;
  esac
  export PATH="${BIN_DIR}:${PATH}"
  # Own pipx: ignores pre-existing installations (e.g. /opt/pipx on the GitHub runners)
  export PIPX_HOME="${HOME}/.local/share/pipx"
  export PIPX_BIN_DIR="${BIN_DIR}"

  if [[ "${SETUP_SKIP_APT:-0}" != "1" ]]; then
    log "apt packages"
    sudo apt-get update -qq
    sudo apt-get install -y -qq curl git jq make pipx python3 python3-venv openssh-client >/dev/null
  fi

  log "Python tools (pipx)"
  pipx install --force "ansible-core==${ANSIBLE_CORE_VERSION}" >/dev/null
  pipx inject ansible-core "kubernetes==${KUBERNETES_PY_VERSION}" >/dev/null
  if [[ "${MODE}" == "full" ]]; then
    pipx install --force "ansible-lint==${ANSIBLE_LINT_VERSION}" >/dev/null
    pipx install --force "pre-commit==${PRE_COMMIT_VERSION}" >/dev/null
  else
    pipx inject ansible-core "opentelemetry-api==${OTEL_PY_VERSION}" "opentelemetry-sdk==${OTEL_PY_VERSION}" \
      "opentelemetry-exporter-otlp-proto-grpc==${OTEL_PY_VERSION}" >/dev/null
  fi

  install_bin sops "${SOPS_VERSION}" \
    "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.${ARCH}" \
    "${SOPS_SHA256}"
  install_bin age "${AGE_VERSION}" \
    "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-linux-${ARCH}.tar.gz" \
    "${AGE_SHA256}" age/age
  install_bin age-keygen "${AGE_VERSION}" \
    "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-linux-${ARCH}.tar.gz" \
    "${AGE_SHA256}" age/age-keygen
  install_bin helm "${HELM_VERSION}" \
    "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" \
    "${HELM_SHA256}" "linux-${ARCH}/helm"
  install_bin kubectl "${KUBECTL_VERSION}" \
    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" \
    "${KUBECTL_SHA256}"
  install_bin tofu "${TOFU_VERSION}" \
    "https://github.com/opentofu/opentofu/releases/download/${TOFU_VERSION}/tofu_${TOFU_VERSION#v}_linux_${ARCH}.tar.gz" \
    "${TOFU_SHA256}" tofu

  if [[ "${MODE}" == "full" ]]; then
    install_bin kubeconform "${KUBECONFORM_VERSION}" \
      "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-linux-amd64.tar.gz" \
      "${KUBECONFORM_SHA256}" kubeconform
    install_bin kube-linter "${KUBE_LINTER_VERSION}" \
      "https://github.com/stackrox/kube-linter/releases/download/${KUBE_LINTER_VERSION}/kube-linter-linux.tar.gz" \
      "${KUBE_LINTER_SHA256}" kube-linter
    install_bin kustomize "${KUSTOMIZE_VERSION}" \
      "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" \
      "${KUSTOMIZE_SHA256}" kustomize

    if ! helm plugin list 2>/dev/null | grep -q "^unittest[[:space:]]\+${HELM_UNITTEST_VERSION#v}"; then
      log "helm-unittest ${HELM_UNITTEST_VERSION}"
      helm plugin uninstall unittest >/dev/null 2>&1 || true
      # Helm 4 verifies plugin signatures by default; helm-unittest is installed from the pinned tag.
      helm plugin install https://github.com/helm-unittest/helm-unittest --version "${HELM_UNITTEST_VERSION}" --verify=false
    fi
  fi

  log "Ansible collections"
  ansible-galaxy collection install -r "${REPO_ROOT}/ansible/requirements.yml" >/dev/null

  if [[ "${MODE}" == "full" ]]; then
    log "done. Next step: pre-commit install"
  else
    log "done (runtime tools only)."
  fi
}

main "$@"
