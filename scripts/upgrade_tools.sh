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
# See docs/this_repo/upgrades.md and `## Upgrades` in AGENTS.md for rationale.

set -u
# NOTE: we deliberately do not `set -e`. Each command is guarded by _run /
# run_category so we can continue past individual failures.

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ----------------------------------------------------------------------------
# Shared console logging — info/success/warn/error/hr + colour detection.
# Sourced (not inlined): this script only ever runs from the repo checkout,
# unlike the run_*.sh.tmpl consumers that must `include` the same file.
# ----------------------------------------------------------------------------
# shellcheck source=lib/log_shared.sh
# shellcheck disable=SC1091
source "$_REPO_ROOT/scripts/lib/log_shared.sh"
# shellcheck source=lib/herdr_skill.sh
source "$_REPO_ROOT/scripts/lib/herdr_skill.sh"

# ----------------------------------------------------------------------------
# Source shared sudo helper (same file used by run_*.sh.tmpl via `include`)
# ----------------------------------------------------------------------------
# shellcheck source=lib/sudo_shared.sh
if [[ -f "$_REPO_ROOT/scripts/lib/sudo_shared.sh" ]]; then
  # shellcheck disable=SC1091
  source "$_REPO_ROOT/scripts/lib/sudo_shared.sh"
fi

# ----------------------------------------------------------------------------
# Homebrew PATH detection (mirrors .chezmoiscripts/global/run_onchange_after_30_brew_bundle.sh.tmpl)
# ----------------------------------------------------------------------------
# Probe brew by OUTPUT, not exit status. A fake `brew` stub on PATH
# (`#!/bin/sh` + `exit 0` — used to stop bootstrap from installing Linuxbrew
# on a distro Homebrew doesn't support) satisfies `command -v brew` and
# returns 0 for *every* subcommand while printing nothing, which would make
# `brew list --formula <x>` succeed and misclassify install styles.
# See pitfalls/ansible-homebrew-expecting-value-line-1-column-1.md.
brew_usable() {
  [[ -n "$(brew --prefix 2>/dev/null)" ]]
}

setup_brew_path() {
  if brew_usable; then
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

ALL_CATEGORIES=(externals brew mise uv npm cargo go dotnet gem flatpak warp atuin herdr agents plugins yazi-plugins)

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
    # Positional category names are matched against ALL_CATEGORIES rather than
    # a literal alternation. A hardcoded second copy of the list drifts
    # silently: the usage text and the validation loop below both read
    # ALL_CATEGORIES, so a category added there but missed here would be
    # advertised as valid and then rejected as "Unknown argument".
    *)
      _known=0
      for valid in "${ALL_CATEGORIES[@]}"; do
        [[ "$1" == "$valid" ]] && {
          _known=1
          break
        }
      done
      if [[ "$_known" -ne 1 ]]; then
        error "Unknown argument: $1"
        usage
        exit 2
      fi
      SELECTED+=("$1")
      shift
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
# Detect uv install style by binary path + brew formula registry. Mirrors
# the same dispatch in dot_ansible/roles/python_uv_tools/tasks/main.yml so
# both surfaces speak the same language. See:
#   - docs/this_repo/uv-bootstrap.md
#   - pitfalls/uv-self-update-homebrew-noop.md
_uv_install_style() {
  local p
  p="$(command -v uv 2>/dev/null)" || return 1
  case "$p" in
    */homebrew/* | */Cellar/* | */linuxbrew/*) echo brew ;;
    /usr/local/bin/uv)
      if brew_usable \
        && brew list --formula uv >/dev/null 2>&1; then
        echo brew
      else
        echo curl
      fi
      ;;
    "$HOME"/.local/bin/uv | "$HOME"/.cargo/bin/uv) echo curl ;;
    *)
      if brew_usable \
        && brew list --formula uv >/dev/null 2>&1; then
        echo brew
      else
        echo curl
      fi
      ;;
  esac
}

cat_uv() {
  if ! command -v uv >/dev/null 2>&1; then
    warn "uv not found — skipping"
    return $SKIP_RC
  fi

  local any_fail=0 style
  style="$(_uv_install_style)"
  info "Updating uv itself (install style: $style)"

  case "$style" in
    brew)
      # Homebrew-installed uv refuses `uv self update` ("self-update is
      # disabled for this build"). Use the right channel instead.
      if ! _run brew upgrade uv; then
        warn "brew upgrade uv failed — leaving uv at current version"
      fi
      ;;
    curl | *)
      # `uv self update` works for the standalone curl-installer and any
      # binary that wasn't built with self-update disabled.
      if ! _run uv self update; then
        warn "uv self update failed (style=$style); falling back to no-op"
      fi
      ;;
  esac

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
# Category: go — `go install <pkg>@latest` for each tool in
# dot_ansible/roles/go_tools/defaults/main.yml
# ============================================================================
cat_go() {
  # macOS installs go_tools binaries via Homebrew (translate → daviddwlee84/tap),
  # so `go install` is Linux-only — skip on macOS to avoid re-creating
  # ~/.local/bin/translate and shadowing the brew copy. Mirrors the go_tools role
  # gate; on macOS upgrade via `brew upgrade` (just upgrade-brew).
  if [[ "$(uname -s)" == "Darwin" ]]; then
    warn "go tools are Homebrew-managed on macOS — skipping (use \`brew upgrade\`)"
    return $SKIP_RC
  fi

  # Resolve go via mise shim first, then system PATH.
  local go_cmd=""
  if [[ -x "$HOME/.local/share/mise/shims/go" ]]; then
    go_cmd="$HOME/.local/share/mise/shims/go"
  elif command -v go >/dev/null 2>&1; then
    go_cmd="go"
  else
    warn "go not found (Go not installed via mise?) — skipping"
    return $SKIP_RC
  fi

  # Parse the tools list from defaults YAML — lines `  - name: <pkg>@<ver>`.
  # Same hand-rolled awk parser as cat_dotnet.
  local defaults_file="$_REPO_ROOT/dot_ansible/roles/go_tools/defaults/main.yml"
  local tools=()
  if [[ -f "$defaults_file" ]]; then
    while IFS= read -r line; do
      tools+=("$line")
    done < <(awk '
            /^go_tools:/ { in_list=1; next }
            in_list && /^[^ ]/ { in_list=0 }
            in_list && /^[[:space:]]*-[[:space:]]*name:/ {
                sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "")
                gsub(/["'"'"']/, "")
                print
            }
        ' "$defaults_file")
  fi

  if [[ ${#tools[@]} -eq 0 ]]; then
    warn "no go tools to upgrade — skipping"
    return $SKIP_RC
  fi

  # Install into ~/.local/bin (the blessed dir), not ~/go/bin or the mise
  # toolchain dir. Upgrade = re-install at @latest regardless of the version
  # pinned in defaults (install-vs-upgrade split — defaults pin for fresh
  # installs, this moves them forward). See docs/this_repo/tool-managers.md.
  # GOPATH pinned to ~/.local/share/go (XDG data) so the build-time module cache
  # doesn't repopulate ~/go — mirrors dot_config/shell/02_legacy_tools.sh and the
  # go_tools ansible role.
  export GOBIN="$HOME/.local/bin"
  export GOPATH="$HOME/.local/share/go"

  local any_fail=0
  for t in "${tools[@]}"; do
    # Strip any @version pin (module paths never contain '@') and go to @latest.
    local pkg="${t%@*}"
    info "Upgrading go tool: $pkg@latest"
    _run "$go_cmd" install "$pkg@latest" || any_fail=1
  done
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
# Category: flatpak — `flatpak update` for user-scope Flathub apps
# ============================================================================
# We deliberately stick to user-scope (`--user`): no sudo required, and our
# ansible role installs everything via `method: user`. System-scope flatpaks
# need `sudo flatpak update --system`, which the user can run manually if
# they have any (rare in this repo's flow).
cat_flatpak() {
  if ! command -v flatpak >/dev/null 2>&1; then
    warn "flatpak not installed — skipping"
    return $SKIP_RC
  fi

  # Skip silently when there's nothing user-scoped to update — avoids logging
  # a "Nothing to do." into upgrade summaries on machines that have never set
  # discordChannel=flatpak.
  local n_user_apps
  n_user_apps="$(flatpak list --app --user 2>/dev/null | wc -l)"
  if [[ "$n_user_apps" -eq 0 ]]; then
    info "No user-scope Flatpak apps installed — skipping"
    return $SKIP_RC
  fi

  local any_fail=0
  info "Upgrading user-scope Flatpak apps ($n_user_apps installed)"
  _run flatpak update --user --noninteractive --assumeyes || any_fail=1
  return "$any_fail"
}

# ============================================================================
# Category: warp — Linux apt-only upgrade for Warp Terminal
# ============================================================================
# macOS Warp is handled by `cat_brew` (cask "warp" + --greedy). On Linux,
# Warp's only supported channel is its own apt repo, but the in-app updater
# pastes `... && warp_finish_update <token>` into the prompt — that token is
# only valid inside a live Warp session and `warp_finish_update` is a
# Warp-injected shell function (not on PATH otherwise). So this category
# does the apt half only and leaves the user to restart Warp themselves.
#
# See docs/tools/warp.md for the full mechanism (token IPC handshake, etc.).
cat_warp() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    info "Not Linux — Warp is upgraded via brew cask, skipping"
    return $SKIP_RC
  fi
  if ! command -v warp-terminal >/dev/null 2>&1; then
    warn "warp-terminal not installed — skipping"
    return $SKIP_RC
  fi

  # warp-terminal is gated behind sudo apt. Reuse the shared sudo session so
  # the user isn't re-prompted across upgrade categories.
  if [[ "$DRY_RUN" -eq 0 ]] && declare -F sudo_session_init >/dev/null 2>&1; then
    if ! sudo_session_init "upgrade-warp"; then
      warn "Sudo session could not be established — skipping"
      return $SKIP_RC
    fi
    case "$(sudo_session_skip_reason)" in
      non-interactive | "")
        warn "Non-interactive mode without passwordless sudo — skipping warp"
        return $SKIP_RC
        ;;
    esac
  fi

  local any_fail=0
  info "Refreshing Warp apt repo + installing only the warp-terminal candidate"
  # `apt update` covers all repos (cheap; usually run once per session anyway).
  _run sudo apt-get update || any_fail=1
  # `--only-upgrade` ensures we never accidentally re-install if the package
  # was uninstalled between commands; `-y` is safe because we're pinned to
  # one package name.
  _run sudo apt-get install --only-upgrade -y warp-terminal || any_fail=1

  if [[ "$any_fail" -eq 0 ]]; then
    info "Warp on-disk binary updated. Quit + relaunch Warp to load the new version."
    info "(The in-app 'warp_finish_update <token>' graceful-restart only works from inside Warp.)"
  fi
  return "$any_fail"
}

# ============================================================================
# Category: atuin — shell history (https://atuin.sh)
# ============================================================================
# macOS path is covered by `brew upgrade atuin` in cat_brew. This category
# only does work on Linux, where atuin was installed via the official
# https://setup.atuin.sh installer (see dot_ansible/roles/atuin/).
cat_atuin() {
  if ! command -v atuin >/dev/null 2>&1; then
    warn "atuin not installed — skipping"
    return $SKIP_RC
  fi
  if [[ "$(uname -s)" != "Linux" ]]; then
    info "Not Linux — atuin upgraded via brew (cat_brew), skipping"
    return $SKIP_RC
  fi

  local any_fail=0
  # `atuin update` (subcommand) is the upstream-recommended self-upgrade for
  # installer-based installs. Falls back to re-running the installer.
  info "Upgrading atuin (Linux, official installer)"
  if ! _run atuin update; then
    warn "atuin update failed; falling back to installer re-run"
    if ! _run_sh 'curl --proto "=https" --tlsv1.2 -LsSf https://setup.atuin.sh | sh -s -- --non-interactive'; then
      any_fail=1
      error "atuin installer re-run failed"
    fi
  fi
  return "$any_fail"
}

# ============================================================================
# Category: herdr — `herdr update --handoff` for the self-managed binary
# ============================================================================
# herdr is the one tool here whose upgrade CANNOT be driven from the terminal
# you are sitting in. The devtools ansible role gates its install on
# `herdr --version` returning non-zero — i.e. "is it installed at all", not "is
# it current" — so once present, `chezmoi apply` never touches it again and the
# box silently drifts versions behind. This category is the explicit upgrade
# path that install-only design implies.
#
# Three guards, all of which SKIP rather than fail, so `upgrade-all` isn't
# derailed by an environment herdr can't be upgraded from:
#   1. not installed
#   2. not a self-managed install — upstream DISABLES `herdr update` on
#      Homebrew/mise/Nix because the package manager owns the binary, which
#      leaves no pane-preserving path at all. This repo therefore installs the
#      GitHub-release binary on macOS too; see
#      pitfalls/herdr-brew-upgrade-strands-running-server.md.
#   3. running inside a herdr pane — the handoff replaces the server process
#      that owns your pane, so herdr refuses. This is the non-obvious one:
#      `just upgrade-all` from a herdr pane would otherwise fail here every
#      single time. See pitfalls/herdr-update-handoff-refuses-inside-pane.md.
#
# `--handoff` is the live, pane-preserving path: the server is replaced without
# killing pane processes, so running coding agents survive the upgrade. Without
# it, the restart exits every pane process.
# Detect where the herdr binary came from. Upstream disables `herdr update`
# on package-manager installs (Homebrew/mise/Nix) because the manager owns the
# binary — so the pane-preserving `--handoff` path only exists for the
# self-managed GitHub-release binary. Mirrors _uv_install_style.
_herdr_install_style() {
  local p
  p="$(command -v herdr 2>/dev/null || true)"
  case "$p" in
    */homebrew/* | */Cellar/* | */linuxbrew/*) echo brew ;;
    *"/.local/share/mise/"* | */mise/installs/*) echo mise ;;
    "$HOME"/.local/bin/herdr) echo self ;;
    *)
      if brew_usable \
        && brew list --formula herdr >/dev/null 2>&1; then
        echo brew
      else
        echo self
      fi
      ;;
  esac
}

cat_herdr() {
  if ! command -v herdr >/dev/null 2>&1; then
    warn "herdr not installed — skipping"
    return $SKIP_RC
  fi

  local style
  style="$(_herdr_install_style)"
  if [[ "$style" != "self" ]]; then
    warn "herdr came from $style — upstream disables \`herdr update\` on $style installs"
    warn "  There is no pane-preserving upgrade from there; a restart exits every pane process."
    warn "  This repo installs the self-managed binary on macOS too — re-run \`chezmoi apply\`"
    warn "  (devtools role) to migrate off $style, then \`just upgrade-herdr\` works."
    return $SKIP_RC
  fi

  # HERDR_ENV is the ambient marker herdr injects into every pane shell; the
  # pane id is checked too so a stray export doesn't mask a real pane.
  if [[ -n "${HERDR_ENV:-}" || -n "${HERDR_PANE_ID:-}" ]]; then
    warn "Running inside a herdr pane — \`herdr update --handoff\` refuses here"
    warn "  Detach (prefix+q), then from a plain terminal: herdr update --handoff"
    warn "  Panes and their processes survive the detach AND the handoff."
    return $SKIP_RC
  fi

  info "Upgrading herdr (self-managed binary, live handoff)"
  if ! _run herdr update --handoff; then
    error "herdr update --handoff failed"
    return 1
  fi

  if ! _run sync_herdr_skill "$HOME/.agents/skills/herdr/SKILL.md"; then
    error "herdr updated, but its global agent skill could not be synchronized"
    return 1
  fi

  # The updater replaces the server, so attached clients must reconnect, and
  # each agent integration is a versioned file herdr wrote OUTSIDE chezmoi's
  # tree — a herdr upgrade leaves them stale. Report rather than auto-install:
  # these land in agent config dirs (~/.claude/hooks/, ~/.codex/, ~/.cursor/,
  # ~/.config/opencode/plugins/), and silently writing there is the caller's
  # call to make. Same "warn, don't silently edit" rule as cat_yazi_plugins.
  if [[ "$DRY_RUN" -eq 0 ]]; then
    local outdated
    outdated=$(herdr integration status 2>/dev/null | grep -c 'outdated' || true)
    if [[ "${outdated:-0}" -gt 0 ]]; then
      warn "$outdated herdr integration(s) now outdated — run \`herdr integration status\` and reinstall each:"
      herdr integration status 2>/dev/null | grep 'outdated' || true
      warn "  e.g. herdr integration install opencode"
    fi
  fi
  warn "Reconnect clients with \`herdr\` (the session's server was replaced)"
  return 0
}

# ============================================================================
# Category: yazi-plugins — `ya pkg upgrade` for Yazi plugins (piper.yazi, …)
# ============================================================================
# `chezmoi apply` is install-only: it materializes plugins from the pinned
# lockfile (dot_config/yazi/package.toml) via `ya pkg install`. This category
# bumps them to the latest upstream revs. Remember to copy the regenerated
# ~/.config/yazi/package.toml back into the chezmoi source afterward, else the
# next apply pins the old rev again. See docs/tools/office-viewers.md.
cat_yazi_plugins() {
  if ! command -v ya >/dev/null 2>&1; then
    warn "ya (yazi CLI) not installed — skipping"
    return $SKIP_RC
  fi
  if [[ ! -f "$HOME/.config/yazi/package.toml" ]]; then
    warn "no ~/.config/yazi/package.toml — no yazi plugins to upgrade, skipping"
    return $SKIP_RC
  fi
  info "Upgrading Yazi plugins (ya pkg upgrade)"
  if ! _run ya pkg upgrade; then
    error "ya pkg upgrade failed"
    return 1
  fi
  warn "Remember: copy ~/.config/yazi/package.toml into the chezmoi source to persist new revs"
  return 0
}

# ============================================================================
# Category: agents — re-run install.sh for curl-installed CLI tools
# ============================================================================
# Only re-runs when the binary is already present. The installers are (by
# design) idempotent self-upgrades.
cat_agents() {
  local any_fail=0
  local ran_any=0

  # Strategy: prefer the binary's built-in self-update subcommand (fast no-op
  # when already current; doesn't re-download the full binary). Fallback to
  # the official curl installer if the subcommand fails, hangs, or doesn't
  # exist. Inspection of upstream installers (2026-04) confirmed none of them
  # delegate to the self-update subcommand internally:
  #   - claude.sh   : always re-downloads, no version check
  #   - opencode.sh : has a same-version fast-path, but no `opencode upgrade`
  #   - cursor.sh   : always re-downloads, no version check
  #
  # We wrap the self-update call with a timeout (some `claude update` runs
  # have been observed hanging indefinitely on network checks) so a stuck
  # subcommand cannot block the whole upgrade flow.
  local _timeout_bin=""
  if command -v timeout >/dev/null 2>&1; then
    _timeout_bin="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    _timeout_bin="gtimeout"
  fi
  _try_self_update_then_curl() {
    local label="$1" self_cmd="$2" curl_url="$3"
    info "Upgrading $label (trying self-update first)"
    local wrapped="$self_cmd"
    if [[ -n "$_timeout_bin" ]]; then
      wrapped="$_timeout_bin 90 $self_cmd"
    fi
    if _run_sh "$wrapped"; then
      return 0
    fi
    warn "$label self-update failed/timed out — falling back to official installer"
    local fallback="curl -fsSL $curl_url | bash"
    if [[ -n "$_timeout_bin" ]]; then
      fallback="$_timeout_bin 300 bash -c 'curl -fsSL $curl_url | bash'"
    fi
    _run_sh "$fallback"
  }

  # Claude Code — `claude update` (alias: `claude upgrade`)
  if command -v claude >/dev/null 2>&1 \
    || [[ -x "$HOME/.claude/local/bin/claude" ]]; then
    _try_self_update_then_curl "Claude Code" \
      "claude update" \
      "https://claude.ai/install.sh" || any_fail=1
    ran_any=1
  fi

  # peon-ping — `peon update` refreshes the binary AND re-syncs sound packs.
  # Install-only elsewhere (ansible seeds the pack once); this is the explicit
  # upgrade path. Safe to run at any agentSounds tier — the binary is installed
  # regardless of whether hooks are wired. On macOS the formula comes from the
  # PeonPing/tap, so `upgrade-brew` may bump it first; `peon update` is then a
  # cheap no-op that still refreshes packs. See docs/tools/agent-sounds.md.
  if command -v peon >/dev/null 2>&1; then
    info "Upgrading peon-ping (binary + sound packs)"
    _run_sh "${_timeout_bin:+$_timeout_bin 180 }peon update" || any_fail=1
    ran_any=1
  fi

  # OpenCode — `opencode upgrade`
  if command -v opencode >/dev/null 2>&1; then
    _try_self_update_then_curl "OpenCode" \
      "opencode upgrade" \
      "https://opencode.ai/install" || any_fail=1
    ran_any=1
  fi

  # Cursor CLI — `cursor-agent update`
  if command -v cursor-agent >/dev/null 2>&1 \
    || command -v cursor-cli >/dev/null 2>&1 \
    || [[ -x "$HOME/.local/bin/cursor-agent" ]]; then
    _try_self_update_then_curl "Cursor CLI" \
      "cursor-agent update" \
      "https://cursor.com/install" || any_fail=1
    ran_any=1
  fi

  # Ollama — Linux official installer (macOS is Homebrew-managed elsewhere).
  # No self-update subcommand exists.
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

  # RTK — official installer (no self-update subcommand)
  if command -v rtk >/dev/null 2>&1; then
    info "Upgrading RTK"
    _run_sh "curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh" || any_fail=1
    ran_any=1
  fi

  # SpecStory — brew tap when available (macOS), else GitHub release script.
  # The installer script is idempotent and pulls latest by default, so re-running
  # it is the upgrade path on Linux (and on macOS when not brew-managed).
  if command -v specstory >/dev/null 2>&1 \
    || [[ -x "$HOME/.local/bin/specstory" ]]; then
    local specstory_handled=0
    if [[ "$(uname -s)" == "Darwin" ]] && setup_brew_path \
      && brew list --formula specstoryai/tap/specstory >/dev/null 2>&1; then
      info "Upgrading SpecStory via Homebrew tap"
      _run brew upgrade specstoryai/tap/specstory || any_fail=1
      specstory_handled=1
    fi
    if [[ "$specstory_handled" -eq 0 ]]; then
      if [[ -x "$_REPO_ROOT/scripts/install_specstory.sh" ]]; then
        info "Upgrading SpecStory via install_specstory.sh (latest GitHub release)"
        _run "$_REPO_ROOT/scripts/install_specstory.sh" || any_fail=1
      else
        warn "specstory present but install_specstory.sh not found — skipping"
      fi
    fi
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
  local claude_hud_helper="$_REPO_ROOT/dot_ansible/roles/coding_agents/files/claude_hud_sync.py"
  local claude_hud_installed=0

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

  # claude-hud plugin cache / installed_plugins.json
  if [[ -d "$HOME/.claude/plugins/cache/claude-hud" ]]; then
    claude_hud_installed=1
  elif [[ -f "$HOME/.claude/plugins/installed_plugins.json" ]] \
    && grep -q '"claude-hud@claude-hud"' "$HOME/.claude/plugins/installed_plugins.json"; then
    claude_hud_installed=1
  fi
  if [[ "$claude_hud_installed" -eq 1 ]] \
    && command -v python3 >/dev/null 2>&1 \
    && [[ -f "$claude_hud_helper" ]]; then
    info "Refreshing claude-hud plugin"
    _run python3 "$claude_hud_helper" --only-if-installed || any_fail=1
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
        go) run_category go cat_go ;;
        dotnet) run_category dotnet cat_dotnet ;;
        gem) run_category gem cat_gem ;;
        flatpak) run_category flatpak cat_flatpak ;;
        warp) run_category warp cat_warp ;;
        atuin) run_category atuin cat_atuin ;;
        herdr) run_category herdr cat_herdr ;;
        agents) run_category agents cat_agents ;;
        plugins) run_category plugins cat_plugins ;;
        yazi-plugins) run_category yazi-plugins cat_yazi_plugins ;;
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
