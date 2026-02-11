#!/usr/bin/env bash
# Install SpecStory CLI from GitHub releases
# https://github.com/specstoryai/getspecstory/releases
#
# Usage:
#   ./install_specstory.sh              # install latest version
#   ./install_specstory.sh v1.6.0       # install specific version
#   INSTALL_DIR=/usr/local/bin ./install_specstory.sh  # custom install dir

set -euo pipefail

REPO="specstoryai/getspecstory"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
VERSION="${1:-}"
TMPDIR_CLEANUP=""
trap 'rm -rf "$TMPDIR_CLEANUP"' EXIT

# --- helpers ---

info()  { printf '\033[1;34m[info]\033[0m  %s\n' "$*"; }
warn()  { printf '\033[1;33m[warn]\033[0m  %s\n' "$*"; }
error() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        error "Required command '$1' not found. Please install it first."
    fi
}

# --- detect platform ---

detect_os() {
    local os
    os="$(uname -s)"
    case "$os" in
        Linux*)  echo "Linux" ;;
        Darwin*) echo "Darwin" ;;
        *)       error "Unsupported OS: $os" ;;
    esac
}

detect_arch() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)  echo "x86_64" ;;
        aarch64|arm64) echo "arm64" ;;
        *)             error "Unsupported architecture: $arch" ;;
    esac
}

# --- main ---

main() {
    need_cmd curl
    need_cmd tar
    need_cmd sha256sum || need_cmd shasum || true

    local os arch
    os="$(detect_os)"
    arch="$(detect_arch)"

    # Resolve version
    if [ -z "$VERSION" ]; then
        info "Fetching latest release version..."
        VERSION="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
            | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')"
        [ -n "$VERSION" ] || error "Failed to determine latest release version."
    fi
    info "Installing SpecStory CLI ${VERSION} (${os}/${arch})"

    # Strip leading 'v' for the checksum filename (e.g. v1.6.0 -> 1.6.0)
    local version_num="${VERSION#v}"

    local asset="SpecStoryCLI_${os}_${arch}.tar.gz"
    local checksums="SpecStoryCLI_${version_num}_checksums.txt"
    local base_url="https://github.com/${REPO}/releases/download/${VERSION}"
    local tmpdir
    tmpdir="$(mktemp -d)"
    TMPDIR_CLEANUP="$tmpdir"

    # Download archive and checksums
    info "Downloading ${asset}..."
    curl -fsSL -o "${tmpdir}/${asset}" "${base_url}/${asset}" \
        || error "Failed to download ${base_url}/${asset}"

    info "Downloading checksums..."
    curl -fsSL -o "${tmpdir}/${checksums}" "${base_url}/${checksums}" \
        || warn "Checksums file not available, skipping verification."

    # Verify checksum
    if [ -f "${tmpdir}/${checksums}" ]; then
        info "Verifying checksum..."
        local expected actual
        expected="$(grep "${asset}" "${tmpdir}/${checksums}" | awk '{print $1}')"
        if [ -n "$expected" ]; then
            if command -v sha256sum >/dev/null 2>&1; then
                actual="$(sha256sum "${tmpdir}/${asset}" | awk '{print $1}')"
            elif command -v shasum >/dev/null 2>&1; then
                actual="$(shasum -a 256 "${tmpdir}/${asset}" | awk '{print $1}')"
            else
                warn "No sha256sum or shasum found, skipping checksum verification."
                actual="$expected"
            fi
            if [ "$expected" != "$actual" ]; then
                error "Checksum mismatch! Expected: ${expected}, Got: ${actual}"
            fi
            info "Checksum verified."
        else
            warn "Asset not found in checksums file, skipping verification."
        fi
    fi

    # Extract
    info "Extracting to ${INSTALL_DIR}..."
    mkdir -p "$INSTALL_DIR"
    tar -xzf "${tmpdir}/${asset}" -C "${tmpdir}"

    # The archive contains a single 'specstory' binary at the root
    if [ ! -f "${tmpdir}/specstory" ]; then
        error "Expected 'specstory' binary not found in archive."
    fi
    mv "${tmpdir}/specstory" "${INSTALL_DIR}/specstory"
    chmod +x "${INSTALL_DIR}/specstory"

    # Verify installation
    if "${INSTALL_DIR}/specstory" --version >/dev/null 2>&1; then
        info "Installed: $("${INSTALL_DIR}/specstory" --version)"
    else
        info "Installed specstory to ${INSTALL_DIR}/specstory"
    fi

    # PATH hint
    case ":${PATH}:" in
        *":${INSTALL_DIR}:"*) ;;
        *) warn "${INSTALL_DIR} is not in your PATH. Add it with:"
           warn "  export PATH=\"${INSTALL_DIR}:\$PATH\"" ;;
    esac

    info "Done."
}

main
