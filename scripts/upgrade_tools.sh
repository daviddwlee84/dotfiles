#!/usr/bin/env bash
# upgrade_tools.sh — explicit, opt-in upgrade entrypoint.
#
# `chezmoi apply` is deliberately conservative (install-only, `state: present`,
# `creates:` idempotency). This script is the companion upgrade path: run it
# (or `just upgrade-*`) when you want to actually move tools forward.
#
# Design: each category is best-effort. A failure in one category does NOT
# abort later categories; a summary is printed at the end listing SUCCESS /
# FAILED / SKIPPED categories.
#
# Usage:
#   scripts/upgrade_tools.sh [all|<category> ...] [flags]
#
# Categories (also selectable via `all`):
#   externals brew mise uv npm cargo dotnet gem agents plugins
#
# Flags:
#   --dry-run          Print commands without executing.
#   --only a,b,c       Only run listed categories (comma-separated).
#   --skip a,b         Run everything except listed categories.
#   -h, --help         Show help.
#
# See docs/tools/upgrades.md and `## Upgrades` in AGENTS.md for rationale.

set -u
# NOTE: we deliberately do not `set -e`. Each command is guarded by _run /
# run_category so we can continue past individual failures.

# ----------------------------------------------------------------------------
# Colors + loggers (match the style used in run_onchange_after_*.sh.tmpl)
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  _C_RED='\033[0;31m'
  _C_GRN='\033[0;32m'
  _C_YLW='\033[1;33m'
  _C_BLU='\033[0;34m'
  _C_DIM='\033[2m'
  _C_RST='\033[0m'
else
  _C_RED='' _C_GRN='' _C_YLW='' _C_BLU='' _C_DIM='' _C_RST=''
fi

info() { printf '%b\n' "${_C_BLU}[INFO]${_C_RST} $*"; }
success() { printf '%b\n' "${_C_GRN}[SUCCESS]${_C_RST} $*"; }
warn() { printf '%b\n' "${_C_YLW}[WARN]${_C_RST} $*"; }
error() { printf '%b\n' "${_C_RED}[ERROR]${_C_RST} $*" >&2; }
hr() { printf '%b\n' "${_C_DIM}────────────────────────────────────────────${_C_RST}"; }

# ----------------------------------------------------------------------------
# Source shared sudo helper (same file used by run_*.sh.tmpl via `include`)
# ----------------------------------------------------------------------------
_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/sudo_shared.sh
if [[ -f "$_REPO_ROOT/scripts/lib/sudo_shared.sh" ]]; then
  # shellcheck disable=SC1091
  source "$_REPO_ROOT/scripts/lib/sudo_shared.sh"
fi

# ----------------------------------------------------------------------------
# Homebrew PATH detection (mirrors run_onchange_after_30_brew_bundle.sh.tmpl)
# ----------------------------------------------------------------------------
setup_brew_path() {
  if command -v brew >/dev/null 2>&1; then
    return 0
  fi
  local candidates=(
    /opt/homebrew/bin/brew              # macOS Apple Silicon
    /usr/local/bin/brew                 # macOS Intel
    /home/linuxbrew/.linuxbrew/bin/brew # Linuxbrew system-wide
    "$HOME/.linuxbrew/bin/brew"         # Linuxbrew user
  )
  for b in "${candidates[@]}"; do
    if [[ -x "$b" ]]; then
      eval "$("$b" shellenv)"
      return 0
    fi
  done
  return 1
}

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------
DRY_RUN=0
ONLY=""
SKIP=""
SELECTED=()

ALL_CATEGORIES=(externals brew mise uv npm cargo dotnet gem agents plugins)

usage() {
  cat <<EOF
Usage: scripts/upgrade_tools.sh [all|<category> ...] [--dry-run] [--only a,b] [--skip a,b]

Categories: ${ALL_CATEGORIES[*]}

Run order for 'all': ${ALL_CATEGORIES[*]}

Examples:
  scripts/upgrade_tools.sh                      # same as 'all'
  scripts/upgrade_tools.sh all
  scripts/upgrade_tools.sh brew uv
  scripts/upgrade_tools.sh --only brew,mise
  scripts/upgrade_tools.sh --skip agents,plugins
  scripts/upgrade_tools.sh --dry-run all
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --only)
      ONLY="$2"
      shift 2
      ;;
    --only=*)
      ONLY="${1#--only=}"
      shift
      ;;
    --skip)
      SKIP="$2"
      shift 2
      ;;
    --skip=*)
      SKIP="${1#--skip=}"
      shift
      ;;
    all)
      SELECTED=("${ALL_CATEGORIES[@]}")
      shift
      ;;
    externals | brew | mise | uv | npm | cargo | dotnet | gem | agents | plugins)
      SELECTED+=("$1")
      shift
      ;;
    *)
      error "Unknown argument: $1"
      usage
      exit 2
      ;;
  esac
done

# No positional arg and no --only ⇒ default to 'all'
if [[ ${#SELECTED[@]} -eq 0 && -z "$ONLY" ]]; then
  SELECTED=("${ALL_CATEGORIES[@]}")
fi

# --only overrides positional selection
if [[ -n "$ONLY" ]]; then
  IFS=',' read -ra SELECTED <<<"$ONLY"
fi

# --skip filters the selection
if [[ -n "$SKIP" ]]; then
  IFS=',' read -ra _SKIP_ARR <<<"$SKIP"
  _FILTERED=()
  for c in "${SELECTED[@]}"; do
    local_skip=0
    for s in "${_SKIP_ARR[@]}"; do
      [[ "$c" == "$s" ]] && {
        local_skip=1
        break
      }
    done
    [[ "$local_skip" -eq 0 ]] && _FILTERED+=("$c")
  done
  SELECTED=("${_FILTERED[@]}")
fi

# Validate every category exists
for c in "${SELECTED[@]}"; do
  ok=0
  for valid in "${ALL_CATEGORIES[@]}"; do
    [[ "$c" == "$valid" ]] && {
      ok=1
      break
    }
  done
  if [[ "$ok" -ne 1 ]]; then
    error "Unknown category: $c"
    usage
    exit 2
  fi
done

# ----------------------------------------------------------------------------
# Run helper: exec a command (or dry-run it), capture rc without aborting
# ----------------------------------------------------------------------------
# Returns the rc of the invoked command (or 0 under --dry-run).
_run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '%b+ %s%b\n' "$_C_DIM" "$*" "$_C_RST"
    return 0
  fi
  printf '%b+ %s%b\n' "$_C_DIM" "$*" "$_C_RST"
  "$@"
}

# _run_sh: same as _run but runs a single string through `bash -c`.
# Use for pipelines / redirections that _run cannot express.
_run_sh() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '%b+ %s%b\n' "$_C_DIM" "$*" "$_C_RST"
    return 0
  fi
  printf '%b+ %s%b\n' "$_C_DIM" "$*" "$_C_RST"
  bash -c "$*"
}

# run_category <name> <fn>: invoke fn, record success/fail, never abort.
SUCCESS_CATS=()
FAIL_CATS=()
SKIP_CATS=()
declare -A FAIL_REASONS

run_category() {
  local name="$1" fn="$2"
  hr
  info "── category: ${name} ──"
  local rc=0
  # Disable errexit just in case someone later adds `set -e` at the top.
  set +e
  "$fn"
  rc=$?
  set +e
  if [[ "$rc" -eq 0 ]]; then
    success "category '$name' completed"
    SUCCESS_CATS+=("$name")
  elif [[ "$rc" -eq 77 ]]; then
    warn "category '$name' skipped (prerequisite missing)"
    SKIP_CATS+=("$name")
  else
    error "category '$name' had failures (rc=$rc)"
    FAIL_CATS+=("$name")
    FAIL_REASONS[$name]="rc=$rc"
  fi
}

# Convenience: category functions return 77 when prerequisites absent.
SKIP_RC=77

# ============================================================================
# Category: externals — chezmoi self-upgrade + force externals refresh
# ============================================================================
cat_externals() {
  if ! command -v chezmoi >/dev/null 2>&1; then
    warn "chezmoi not found on PATH — skipping"
    return $SKIP_RC
  fi

  local any_fail=0
  # `chezmoi upgrade` only works when chezmoi was installed via the official
  # install script or `go install`. If it was installed via a package manager
  # (brew, apt), the subcommand returns non-zero. Treat non-zero as a warning.
  info "Upgrading chezmoi binary itself"
  if ! _run chezmoi upgrade; then
    warn "chezmoi upgrade failed (possibly installed via brew/apt — upgrade via that channel instead)"
  fi

  info "Force-refreshing chezmoi externals (.chezmoiexternal.toml.tmpl)"
  if ! _run chezmoi apply --refresh-externals; then
    any_fail=1
    error "chezmoi apply --refresh-externals failed"
  fi

  return "$any_fail"
}

# ============================================================================
# Category: brew — Homebrew formulas, casks (greedy), Brewfile, cleanup
# ============================================================================
cat_brew() {
  if ! setup_brew_path; then
    warn "Homebrew not found — skipping"
    return $SKIP_RC
  fi

  local os
  os="$(uname -s)"

  # macOS: pre-warm sudo so cask pkg installers (google-drive, squirrel,
  # ollama-app etc.) find a live ticket when they shell out to
  # `sudo /usr/sbin/installer` internally.
  if [[ "$os" == "Darwin" ]] && [[ "$DRY_RUN" -eq 0 ]]; then
    if declare -F sudo_session_init >/dev/null 2>&1; then
      if sudo_session_init "upgrade-brew"; then
        case "$(sudo_session_skip_reason)" in
          cached)
            sudo_session_warm_cache \
              || warn "sudo_session_warm_cache failed; cask pkg installers may prompt"
            ;;
          passwordless) info "Passwordless sudo detected" ;;
          non-interactive | "")
            warn "Non-interactive mode without passwordless sudo — pkg-based casks may fail"
            ;;
        esac
      else
        warn "Sudo session could not be established — pkg-based casks may fail"
      fi
    fi
  fi

  local any_fail=0
  _run brew update || any_fail=1
  _run brew upgrade || any_fail=1
  # `--greedy` also upgrades casks that self-update (Electron apps etc.)
  _run brew upgrade --cask --greedy || any_fail=1

  # Brewfile — call WITHOUT --no-upgrade so bundled items actually move.
  local brewdir="$HOME/.config/homebrew"
  if [[ -f "$brewdir/Brewfile" ]]; then
    _run brew bundle --file="$brewdir/Brewfile" || any_fail=1
  fi
  if [[ "$os" == "Darwin" && -f "$brewdir/Brewfile.darwin" ]]; then
    _run brew bundle --file="$brewdir/Brewfile.darwin" || any_fail=1
  elif [[ "$os" == "Linux" && -f "$brewdir/Brewfile.linux" ]]; then
    _run brew bundle --file="$brewdir/Brewfile.linux" || any_fail=1
  fi

  _run brew cleanup || any_fail=1

  return "$any_fail"
}

# ============================================================================
# Category: mise — self-update + upgrade installed runtimes
# ============================================================================
cat_mise() {
  local mise_bin=""
  if command -v mise >/dev/null 2>&1; then
    mise_bin="mise"
  elif [[ -x "$HOME/.local/bin/mise" ]]; then
    mise_bin="$HOME/.local/bin/mise"
  else
    warn "mise not found — skipping"
    return $SKIP_RC
  fi

  local any_fail=0
  # mise self-update only works for user-installed mise (curl | sh). When
  # mise came from Homebrew/apt, it prints an error — treat as warning.
  info "Updating mise itself"
  if ! _run "$mise_bin" self-update --yes; then
    warn "mise self-update failed (likely installed via brew — upgrade via that channel)"
  fi

  info "Upgrading installed mise tools"
  _run "$mise_bin" upgrade || any_fail=1

  return "$any_fail"
}

# ============================================================================
# Category: uv — self-update + upgrade all uv tools
# ============================================================================
cat_uv() {
  if ! command -v uv >/dev/null 2>&1; then
    warn "uv not found — skipping"
    return $SKIP_RC
  fi

  local any_fail=0
  info "Updating uv itself"
  # `uv self update` only works when installed via curl/installer. Homebrew-
  # installed uv refuses; treat non-zero as warning, not failure.
  if ! _run uv self update; then
    warn "uv self update failed (possibly installed via brew — upgrade via that channel)"
  fi

  info "Upgrading all uv tools"
  _run uv tool upgrade --all || any_fail=1

  return "$any_fail"
}

# ============================================================================
# Category: npm — `npm -g update`, with mise fallback
# ============================================================================
cat_npm() {
  local npm_cmd=""
  if command -v npm >/dev/null 2>&1; then
    npm_cmd="npm"
  else
    local mise_bin=""
    if command -v mise >/dev/null 2>&1; then
      mise_bin="mise"
    elif [[ -x "$HOME/.local/bin/mise" ]]; then
      mise_bin="$HOME/.local/bin/mise"
    fi
    if [[ -n "$mise_bin" ]]; then
      npm_cmd="$mise_bin exec -- npm"
    else
      warn "neither npm nor mise found — skipping"
      return $SKIP_RC
    fi
  fi

  local any_fail=0
  info "Upgrading global npm packages via: $npm_cmd"
  _run_sh "$npm_cmd -g update" || any_fail=1
  return "$any_fail"
}

# ============================================================================
# Category: cargo — `cargo install-update -a` (bootstraps cargo-update if needed)
# ============================================================================
cat_cargo() {
  if ! command -v cargo >/dev/null 2>&1; then
    # mise-managed rust shim?
    if [[ -x "$HOME/.local/share/mise/shims/cargo" ]]; then
      export PATH="$HOME/.local/share/mise/shims:$PATH"
    elif [[ -x "$HOME/.cargo/bin/cargo" ]]; then
      export PATH="$HOME/.cargo/bin:$PATH"
    else
      warn "cargo not found — skipping"
      return $SKIP_RC
    fi
  fi

  local any_fail=0
  local have_update_tool=0
  if command -v cargo-install-update >/dev/null 2>&1; then
    have_update_tool=1
  else
    info "Bootstrapping cargo-update (needed for 'cargo install-update -a')"
    if _run cargo install cargo-update; then
      # In dry-run, the binary won't materialise — assume success.
      if [[ "$DRY_RUN" -eq 1 ]] \
        || command -v cargo-install-update >/dev/null 2>&1; then
        have_update_tool=1
      fi
    else
      any_fail=1
    fi
  fi

  if [[ "$have_update_tool" -eq 1 ]]; then
    info "Upgrading all cargo-installed binaries"
    _run cargo install-update -a || any_fail=1
  else
    warn "cargo-update not available; skipping bulk upgrade"
    any_fail=1
  fi
  return "$any_fail"
}

# ============================================================================
# Category: dotnet — upgrade each tool in dot_ansible/roles/dotnet_tools/defaults/main.yml
# ============================================================================
cat_dotnet() {
  # Resolve dotnet via mise shim first, then system PATH.
  local dotnet_cmd=""
  if [[ -x "$HOME/.local/share/mise/shims/dotnet" ]]; then
    dotnet_cmd="$HOME/.local/share/mise/shims/dotnet"
  elif command -v dotnet >/dev/null 2>&1; then
    dotnet_cmd="dotnet"
  else
    warn "dotnet not found — skipping"
    return $SKIP_RC
  fi

  # Parse the tools list from defaults YAML. Small hand-rolled parser: we
  # only need lines of the form `  - name: <pkg>`. If parsing produces no
  # results, fall back to `dotnet tool list --global`.
  local defaults_file="$_REPO_ROOT/dot_ansible/roles/dotnet_tools/defaults/main.yml"
  local tools=()
  if [[ -f "$defaults_file" ]]; then
    while IFS= read -r line; do
      tools+=("$line")
    done < <(awk '
            /^dotnet_tools:/ { in_list=1; next }
            in_list && /^[^ ]/ { in_list=0 }
            in_list && /^[[:space:]]*-[[:space:]]*name:/ {
                sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "")
                gsub(/["'"'"']/, "")
                print
            }
        ' "$defaults_file")
  fi

  if [[ ${#tools[@]} -eq 0 ]]; then
    info "Falling back to 'dotnet tool list --global'"
    if ! mapfile -t tools < <("$dotnet_cmd" tool list --global 2>/dev/null \
      | awk 'NR>2 && NF>0 {print $1}'); then
      warn "could not enumerate dotnet tools"
      return $SKIP_RC
    fi
  fi

  if [[ ${#tools[@]} -eq 0 ]]; then
    warn "no dotnet tools to upgrade — skipping"
    return $SKIP_RC
  fi

  # dotnet tools land under ~/.dotnet/tools.
  export PATH="$HOME/.dotnet/tools:$PATH"

  local any_fail=0
  for t in "${tools[@]}"; do
    info "Upgrading dotnet tool: $t"
    _run "$dotnet_cmd" tool update --global "$t" || any_fail=1
  done
  return "$any_fail"
}

# ============================================================================
# Category: gem — upgrade Ruby gems (via mise ruby shim)
# ============================================================================
cat_gem() {
  local gem_cmd=""
  if [[ -x "$HOME/.local/share/mise/shims/gem" ]]; then
    gem_cmd="$HOME/.local/share/mise/shims/gem"
  elif command -v gem >/dev/null 2>&1; then
    gem_cmd="gem"
  else
    warn "gem not found (Ruby not installed via mise?) — skipping"
    return $SKIP_RC
  fi

  local any_fail=0
  info "Updating rubygems system"
  _run "$gem_cmd" update --system --no-document || any_fail=1
  info "Updating all installed gems"
  _run "$gem_cmd" update --no-document || any_fail=1
  return "$any_fail"
}

# ============================================================================
# Category: agents — re-run install.sh for curl-installed CLI tools
# ============================================================================
# Only re-runs when the binary is already present. The installers are (by
# design) idempotent self-upgrades.
cat_agents() {
  local any_fail=0
  local ran_any=0

  # Claude Code — official installer
  if command -v claude >/dev/null 2>&1 \
    || [[ -x "$HOME/.claude/local/bin/claude" ]]; then
    info "Upgrading Claude Code"
    _run_sh "curl -fsSL https://claude.ai/install.sh | bash" || any_fail=1
    ran_any=1
  fi

  # OpenCode — official installer
  if command -v opencode >/dev/null 2>&1; then
    info "Upgrading OpenCode"
    _run_sh "curl -fsSL https://opencode.ai/install | bash" || any_fail=1
    ran_any=1
  fi

  # Cursor CLI — official installer
  if command -v cursor-agent >/dev/null 2>&1 \
    || command -v cursor-cli >/dev/null 2>&1 \
    || [[ -x "$HOME/.local/bin/cursor-agent" ]]; then
    info "Upgrading Cursor CLI"
    _run_sh "curl -fsSL https://cursor.com/install | bash" || any_fail=1
    ran_any=1
  fi

  # Ollama — Linux official installer (macOS is Homebrew-managed elsewhere)
  if [[ "$(uname -s)" == "Linux" ]] && command -v ollama >/dev/null 2>&1; then
    info "Upgrading Ollama (Linux installer)"
    _run_sh "curl -fsSL https://ollama.com/install.sh | sh" || any_fail=1
    ran_any=1
  fi

  # llmfit — official local installer (Linux; macOS uses Homebrew)
  if [[ "$(uname -s)" == "Linux" ]] && command -v llmfit >/dev/null 2>&1; then
    info "Upgrading llmfit (Linux local installer)"
    _run_sh "curl -fsSL https://llmfit.axjns.dev/install.sh | sh -s -- --local" || any_fail=1
    ran_any=1
  fi

  # RTK — official installer
  if command -v rtk >/dev/null 2>&1; then
    info "Upgrading RTK"
    _run_sh "curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh" || any_fail=1
    ran_any=1
  fi

  if [[ "$ran_any" -eq 0 ]]; then
    warn "no known curl-installed agents detected — skipping"
    return $SKIP_RC
  fi

  return "$any_fail"
}

# ============================================================================
# Category: plugins — editor/tmux/pre-commit/tldr/gh plugin upgrades
# ============================================================================
cat_plugins() {
  local any_fail=0
  local ran_any=0

  # LazyVim (Neovim plugins)
  if command -v nvim >/dev/null 2>&1; then
    info "Syncing LazyVim plugins (nvim --headless +Lazy! sync +qa)"
    # Lazy.nvim's sync runs install + update + clean.
    _run nvim --headless "+Lazy! sync" +qa || any_fail=1
    ran_any=1
  fi

  # TPM (Tmux Plugin Manager)
  if [[ -x "$HOME/.tmux/plugins/tpm/bin/update_plugins" ]]; then
    info "Updating tmux plugins via TPM"
    _run "$HOME/.tmux/plugins/tpm/bin/update_plugins" all || any_fail=1
    ran_any=1
  fi

  # pre-commit autoupdate — only when we're in the dotfiles repo itself
  if command -v pre-commit >/dev/null 2>&1 \
    && [[ -f "$_REPO_ROOT/.pre-commit-config.yaml" ]]; then
    info "Running pre-commit autoupdate on the dotfiles repo"
    (cd "$_REPO_ROOT" && _run pre-commit autoupdate) || any_fail=1
    ran_any=1
  fi

  # tldr cache
  if command -v tldr >/dev/null 2>&1; then
    info "Updating tldr cache"
    _run tldr --update || any_fail=1
    ran_any=1
  fi

  # gh extensions
  if command -v gh >/dev/null 2>&1; then
    info "Upgrading gh extensions"
    _run gh extension upgrade --all || any_fail=1
    ran_any=1
  fi

  if [[ "$ran_any" -eq 0 ]]; then
    warn "no plugin managers detected — skipping"
    return $SKIP_RC
  fi
  return "$any_fail"
}

# ============================================================================
# Main: dispatch selected categories in defined order
# ============================================================================
hr
if [[ "$DRY_RUN" -eq 1 ]]; then
  info "upgrade_tools.sh — categories: ${SELECTED[*]} (dry-run)"
else
  info "upgrade_tools.sh — categories: ${SELECTED[*]}"
fi
if [[ "$DRY_RUN" -eq 1 ]]; then
  warn "DRY-RUN MODE — commands are printed, not executed"
fi

# Run in the canonical ALL_CATEGORIES order (regardless of CLI arg order).
for cat in "${ALL_CATEGORIES[@]}"; do
  for sel in "${SELECTED[@]}"; do
    if [[ "$cat" == "$sel" ]]; then
      case "$cat" in
        externals) run_category externals cat_externals ;;
        brew) run_category brew cat_brew ;;
        mise) run_category mise cat_mise ;;
        uv) run_category uv cat_uv ;;
        npm) run_category npm cat_npm ;;
        cargo) run_category cargo cat_cargo ;;
        dotnet) run_category dotnet cat_dotnet ;;
        gem) run_category gem cat_gem ;;
        agents) run_category agents cat_agents ;;
        plugins) run_category plugins cat_plugins ;;
      esac
      break
    fi
  done
done

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
hr
info "Upgrade Summary"
if [[ ${#SUCCESS_CATS[@]} -gt 0 ]]; then
  success "OK:      ${SUCCESS_CATS[*]}"
fi
if [[ ${#SKIP_CATS[@]} -gt 0 ]]; then
  warn "SKIPPED: ${SKIP_CATS[*]} (prerequisite missing)"
fi
if [[ ${#FAIL_CATS[@]} -gt 0 ]]; then
  error "FAILED:  ${FAIL_CATS[*]}"
  for c in "${FAIL_CATS[@]}"; do
    error "   - ${c}: ${FAIL_REASONS[$c]:-unknown}"
  done
  exit 1
fi
exit 0
