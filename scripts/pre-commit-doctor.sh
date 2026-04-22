#!/usr/bin/env bash
# pre-commit-doctor.sh — diagnose + repair a broken `pre-commit` setup.
#
# Checks, in order:
#   1. `uv` is on PATH (prereq — install via chezmoi bootstrap).
#   2. `pre-commit` resolves to ~/.local/bin/pre-commit (the uv-managed copy).
#      If a shadowing binary wins (conda ~/miniforge3/bin, brew
#      /opt/homebrew/bin, system /usr/bin), warn and offer to fix.
#   3. `pre-commit` actually runs — caller can opt into a full
#      `pre-commit run --all-files --verbose` via --run-hooks to smoke-test
#      hook virtualenv bootstrap (catches the macOS python@3.14 pyexpat
#      / _XML_SetAllocTrackerActivationThreshold class of errors).
#
# Exit codes:
#   0 — healthy OR fixed in this run
#   1 — unhealthy and auto-fix was not attempted (use --fix to reinstall)
#   2 — fix attempted but pre-commit still broken
#   3 — prerequisite missing (uv not installed)
#
# Usage:
#   scripts/pre-commit-doctor.sh               # diagnose + auto-fix if broken
#   scripts/pre-commit-doctor.sh --check       # diagnose only, no reinstall
#   scripts/pre-commit-doctor.sh --run-hooks   # also smoke-test hooks on repo
#   scripts/pre-commit-doctor.sh -h|--help
#
# See docs/tools/pre-commit.md for the rationale behind the uv-pinned pre-commit.

set -u

# ----------------------------------------------------------------------------
# Logging (match scripts/upgrade_tools.sh style)
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  _C_RED=$'\033[0;31m'
  _C_GRN=$'\033[0;32m'
  _C_YLW=$'\033[1;33m'
  _C_BLU=$'\033[0;34m'
  _C_DIM=$'\033[2m'
  _C_RST=$'\033[0m'
else
  _C_RED='' _C_GRN='' _C_YLW='' _C_BLU='' _C_DIM='' _C_RST=''
fi

info() { printf '%s\n' "${_C_BLU}[INFO]${_C_RST} $*"; }
success() { printf '%s\n' "${_C_GRN}[OK]${_C_RST} $*"; }
warn() { printf '%s\n' "${_C_YLW}[WARN]${_C_RST} $*"; }
error() { printf '%s\n' "${_C_RED}[ERROR]${_C_RST} $*" >&2; }
hr() { printf '%s\n' "${_C_DIM}────────────────────────────────────────────${_C_RST}"; }

# ----------------------------------------------------------------------------
# Args
# ----------------------------------------------------------------------------
MODE="fix" # fix | check
RUN_HOOKS=0

usage() {
  sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      MODE="check"
      shift
      ;;
    --fix)
      MODE="fix"
      shift
      ;;
    --run-hooks)
      RUN_HOOKS=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      error "Unknown flag: $1"
      usage
      exit 64
      ;;
  esac
done

# ----------------------------------------------------------------------------
# Known-good target
# ----------------------------------------------------------------------------
EXPECTED_BIN="$HOME/.local/bin/pre-commit"
PINNED_PYTHON="3.13"

# ----------------------------------------------------------------------------
# 1. uv prerequisite
# ----------------------------------------------------------------------------
hr
info "Checking uv is installed (prereq for uv tool install pre-commit)"
if ! command -v uv >/dev/null 2>&1; then
  error "uv not found on PATH."
  error "Run \`chezmoi apply\` (bootstrap installs uv into ~/.local/bin),"
  error "or install manually: https://astral.sh/uv"
  exit 3
fi
success "uv: $(uv --version) @ $(command -v uv)"

# ----------------------------------------------------------------------------
# 2. PATH shadowing
# ----------------------------------------------------------------------------
hr
info "Checking which pre-commit wins on PATH"

ACTUAL_BIN=""
if command -v pre-commit >/dev/null 2>&1; then
  ACTUAL_BIN="$(command -v pre-commit)"
  info "Found: $ACTUAL_BIN"
else
  warn "pre-commit not found on PATH."
fi

# Enumerate every pre-commit on PATH for debugging
ALL_BINS=""
if command -v which >/dev/null 2>&1; then
  # `which -a` works on both GNU and macOS BSD `which`.
  ALL_BINS="$(which -a pre-commit 2>/dev/null || true)"
fi
if [[ -n "$ALL_BINS" ]]; then
  info "All pre-commit binaries on PATH:"
  printf '%s\n' "$ALL_BINS" | sed 's/^/       /'
fi

NEEDS_FIX=0
if [[ -z "$ACTUAL_BIN" ]]; then
  NEEDS_FIX=1
elif [[ "$ACTUAL_BIN" != "$EXPECTED_BIN" ]]; then
  warn "pre-commit is not the uv-managed copy:"
  warn "  active:   $ACTUAL_BIN"
  warn "  expected: $EXPECTED_BIN"
  case "$ACTUAL_BIN" in
    *miniforge3* | *miniconda3* | *anaconda3*)
      warn "  cause: conda env shadowing. PATH has conda/bin before ~/.local/bin."
      ;;
    /opt/homebrew/* | /usr/local/Cellar/*)
      warn "  cause: Homebrew pre-commit winning. Uninstall: brew uninstall pre-commit"
      ;;
    /usr/local/bin/*)
      warn "  cause: /usr/local/bin pre-commit winning (Homebrew Intel or manual install)."
      ;;
    /usr/bin/*)
      warn "  cause: system-installed pre-commit."
      ;;
  esac
  NEEDS_FIX=1
else
  success "pre-commit binary is the uv-managed one."
fi

# ----------------------------------------------------------------------------
# 3. Tool runs at all
# ----------------------------------------------------------------------------
if [[ -n "$ACTUAL_BIN" ]]; then
  hr
  info "Checking pre-commit --version runs"
  if VERSION_OUT="$("$ACTUAL_BIN" --version 2>&1)"; then
    success "$VERSION_OUT"
  else
    error "pre-commit --version failed:"
    printf '%s\n' "$VERSION_OUT" | sed 's/^/  /' >&2
    NEEDS_FIX=1
  fi
fi

# ----------------------------------------------------------------------------
# 4. Optional smoke test: can it actually build hook virtualenvs?
# ----------------------------------------------------------------------------
HOOKS_OUT=""
HOOKS_FAILED=0
if [[ "$RUN_HOOKS" -eq 1 && "$NEEDS_FIX" -eq 0 ]]; then
  hr
  info "Smoke-testing pre-commit run --all-files --verbose (this rebuilds hook envs)"
  if [[ -f ".pre-commit-config.yaml" ]]; then
    if ! HOOKS_OUT="$(pre-commit run --all-files --verbose 2>&1)"; then
      HOOKS_FAILED=1
    fi
    # Match pyexpat / virtualenv bootstrap failure signatures.
    if printf '%s' "$HOOKS_OUT" | grep -qE 'pyexpat|XML_SetAllocTrackerActivationThreshold|CalledProcessError.*virtualenv|Symbol not found'; then
      error "Detected known hook-env bootstrap failure signature:"
      printf '%s\n' "$HOOKS_OUT" | grep -E 'pyexpat|XML_SetAllocTrackerActivationThreshold|CalledProcessError|Symbol not found' | sed 's/^/  /' >&2
      NEEDS_FIX=1
    elif [[ "$HOOKS_FAILED" -eq 1 ]]; then
      warn "pre-commit exited non-zero but no known-bad signature matched."
      warn "This may be a hook-content failure (lint fail), not an env break. Re-run manually:"
      warn "  pre-commit run --all-files --verbose"
    else
      success "Hooks ran clean."
    fi
  else
    warn "No .pre-commit-config.yaml in \$PWD — skipping smoke test."
  fi
fi

# ----------------------------------------------------------------------------
# 5. Repair
# ----------------------------------------------------------------------------
hr
if [[ "$NEEDS_FIX" -eq 0 ]]; then
  success "pre-commit is healthy. Nothing to do."
  exit 0
fi

if [[ "$MODE" != "fix" ]]; then
  warn "pre-commit is unhealthy. Re-run without --check to auto-repair:"
  warn "  just pre-commit-doctor"
  exit 1
fi

info "Repairing: uv tool install --force pre-commit --python $PINNED_PYTHON"
if ! uv tool install --force pre-commit --python "$PINNED_PYTHON"; then
  error "uv tool install failed."
  exit 2
fi

# Clear cached hook envs so the next `pre-commit run` rebuilds them with the
# freshly-installed bootstrap Python.
info "Clearing hook env cache: pre-commit clean"
if ! "$EXPECTED_BIN" clean; then
  warn "pre-commit clean failed (non-fatal). Hook cache may retain broken envs."
fi

hr
if [[ -x "$EXPECTED_BIN" ]] && "$EXPECTED_BIN" --version >/dev/null 2>&1; then
  success "Repair complete. Active pre-commit: $("$EXPECTED_BIN" --version)"
  info "Location: $EXPECTED_BIN"
  # Re-check that PATH now resolves correctly (no conda/brew shadow).
  if [[ "$(command -v pre-commit 2>/dev/null || true)" != "$EXPECTED_BIN" ]]; then
    warn "Another pre-commit still wins on PATH:"
    warn "  active:   $(command -v pre-commit 2>/dev/null || echo '(none)')"
    warn "  expected: $EXPECTED_BIN"
    warn "Ensure \$HOME/.local/bin is earlier in PATH than conda/brew, or uninstall the shadow:"
    warn "  brew uninstall pre-commit          # if Homebrew owns the shadow"
    warn "  conda deactivate                   # if conda base env is active"
    exit 1
  fi
  exit 0
fi

error "pre-commit still broken after repair attempt."
exit 2
