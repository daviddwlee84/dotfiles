#!/usr/bin/env bash
# End-to-end quick setup test using get.chezmoi.io one-liner.
# Usage: ./scripts/docker/e2e_quick_setup.sh [user|root]

set -euo pipefail

MODE="${1:-user}"
GITHUB_USERNAME="${GITHUB_USERNAME:-daviddwlee84}"
CHEZMOI_REPO="${CHEZMOI_REPO:-dotfiles}"
CHEZMOI_REPO_URL="${CHEZMOI_REPO_URL:-https://github.com/${GITHUB_USERNAME}/${CHEZMOI_REPO}.git}"
PROFILE="${PROFILE:-ubuntu_server}"
USE_CHINESE_MIRROR="${USE_CHINESE_MIRROR:-false}"
CHEZMOI_VERSION="${CHEZMOI_VERSION:-2.69.3}"

info() {
  printf '[INFO] %s\n' "$1"
}

install_prerequisites() {
  export DEBIAN_FRONTEND=noninteractive
  if [[ "${USE_CHINESE_MIRROR}" == "true" ]]; then
    local arch mirror_url
    arch="$(dpkg --print-architecture)"
    if [[ "${arch}" == "amd64" ]]; then
      mirror_url="http://repo.huaweicloud.com/ubuntu"
    else
      mirror_url="http://repo.huaweicloud.com/ubuntu-ports"
    fi

    cat > /etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb
URIs: ${mirror_url}
Suites: noble noble-updates noble-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: ${mirror_url}
Suites: noble-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
  fi

  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl git sudo
  rm -rf /var/lib/apt/lists/*
}

run_quick_setup() {
  local no_root="$1"
  local home_dir="${HOME}"
  local installer_script
  local installer_url="https://get.chezmoi.io"
  local init_args
  local run_installer_cmd
  local arch goarch tarball base_url tmpdir
  local timeout_bin

  init_args=(
    init --apply "${CHEZMOI_REPO_URL}"
    --promptString "profile (ubuntu_server|ubuntu_desktop|macos|macos_intel)=${PROFILE}"
    --promptString "What is your email address=docker@example.com"
    --promptString "What is your full name=Docker User"
    --promptBool "Are you in China (behind GFW) and need to use mirrors=${USE_CHINESE_MIRROR}"
    --promptBool "Enable gitleaks for ALL git repos (not just those with .pre-commit-config.yaml)=false"
    --promptBool "Install coding agents (Claude Code, OpenCode, Cursor, Copilot, Gemini, etc.)=false"
    --promptBool "Install Bitwarden CLI (@bitwarden/cli) with SSH Agent integration and Zsh completion=false"
    --promptBool "Install Python CLI tools via uv (mlflow, litellm, sqlit-tui, etc.)=false"
    --promptBool "Install GUI apps via Homebrew Brewfile (casks, mas)=false"
    --promptBool "No sudo/root access - skip all system package installations=${no_root}"
    --promptBool "Backup existing dotfiles before chezmoi overwrites them=false"
  )

  mkdir -p "${home_dir}/.local/bin"

  installer_script="$(mktemp)"
  curl -fsSL --connect-timeout 10 --max-time 120 "${installer_url}" -o "${installer_script}"
  if [[ "${USE_CHINESE_MIRROR}" == "true" ]]; then
    # get.chezmoi.io hardcodes GitHub release URLs; rewrite them through ghproxy for GFW.
    sed -i 's#https://github.com/#https://ghproxy.cc/https://github.com/#g' "${installer_script}"
  fi

  run_installer_cmd=(sh "${installer_script}" -- -b "${home_dir}/.local/bin" "${init_args[@]}")
  timeout_bin="$(command -v timeout || true)"
  if [[ -n "${timeout_bin}" ]]; then
    if ! "${timeout_bin}" 300 "${run_installer_cmd[@]}"; then
      info "one-liner install timed out/failed, falling back to direct tarball install"
      arch="$(uname -m)"
      case "${arch}" in
        x86_64) goarch="amd64" ;;
        aarch64|arm64) goarch="arm64" ;;
        *) echo "Unsupported architecture: ${arch}" >&2; exit 1 ;;
      esac
      tarball="chezmoi_${CHEZMOI_VERSION}_linux_${goarch}.tar.gz"
      if [[ "${USE_CHINESE_MIRROR}" == "true" ]]; then
        base_url="https://ghproxy.cc/https://github.com/twpayne/chezmoi/releases/download/v${CHEZMOI_VERSION}"
      else
        base_url="https://github.com/twpayne/chezmoi/releases/download/v${CHEZMOI_VERSION}"
      fi
      tmpdir="$(mktemp -d)"
      curl -fL --connect-timeout 10 --max-time 180 --retry 3 --retry-delay 5 \
        -o "${tmpdir}/${tarball}" "${base_url}/${tarball}"
      tar -xzf "${tmpdir}/${tarball}" -C "${tmpdir}"
      install -m 0755 "${tmpdir}/chezmoi" "${home_dir}/.local/bin/chezmoi"
      rm -rf "${tmpdir}"
      "${home_dir}/.local/bin/chezmoi" "${init_args[@]}"
    fi
  else
    "${run_installer_cmd[@]}"
  fi

  rm -f "${installer_script}"

  test -x "${home_dir}/.local/bin/chezmoi"
  test -f "${home_dir}/.gitconfig"
}

info "Running quick setup e2e mode: ${MODE}"
info "Repo URL: ${CHEZMOI_REPO_URL}"

install_prerequisites

case "${MODE}" in
  user)
    id -u devuser >/dev/null 2>&1 || useradd -m -s /bin/bash devuser
    sudo -u devuser -H env \
      CHEZMOI_REPO_URL="${CHEZMOI_REPO_URL}" \
      PROFILE="${PROFILE}" \
      USE_CHINESE_MIRROR="${USE_CHINESE_MIRROR}" \
      bash -lc 'set -euo pipefail; '"$(declare -f run_quick_setup)"'; run_quick_setup true'
    ;;
  root)
    export HOME=/root
    run_quick_setup false
    ;;
  *)
    echo "Unknown mode: ${MODE}. Expected: user or root" >&2
    exit 1
    ;;
esac

info "Quick setup e2e passed (${MODE})"
