# shellcheck shell=bash
# log_shared.sh — one console-logging vocabulary for every shell script in
# this repo.
#
# WHY this file exists: 13 scripts each hand-rolled the same colour block plus
# an info/warn/success/error trio, in four mutually incompatible dialects —
# `echo -e` vs `printf '%b'` vs `printf '%s'`, `'\033'` (needs %b) vs
# `$'\033'` (real ESC), `[OK]` vs `[SUCCESS]`. Colour was gated on `[[ -t 1 ]]`
# in three of them and unconditional in the rest; NO_COLOR was honoured
# nowhere. This file is the single source of truth for all of it.
#
# ---------------------------------------------------------------------------
# How to consume it
# ---------------------------------------------------------------------------
# Two mechanisms, picked by whether the script has a stable path back to the
# source tree at runtime:
#
#   1. INLINED — `{{ include "scripts/lib/log_shared.sh" }}`
#      chezmoi renders every run_*.sh.tmpl to a temp path and executes it
#      there, so `source` has nothing to resolve against. `include` (not
#      `includeTemplate`) because this file is plain bash with no `{{ … }}`
#      tokens to re-render. Same reasoning as scripts/lib/sudo_shared.sh —
#      read that file's header for the long version.
#
#      COST: an inlined copy is part of the consuming script's bytes, so
#      editing THIS file changes the hash of every `run_onchange_after_*`
#      that includes it and re-triggers all of them on the next apply
#      (a full ansible re-run, a full brew bundle, …). Batch edits here.
#
#   2. SOURCED — `. "$(dirname "${BASH_SOURCE[0]}")/lib/log_shared.sh"`
#      For scripts/*.sh, which only ever run from the repo checkout.
#
# `scripts/**` is listed in .chezmoiignore.tmpl, so this file is never
# deployed to $HOME. Its only runtime existence is the inlined copy or a
# source from the checkout.
#
# Consumers are enumerated in the `scripts/lib/log_shared.sh` row of
# CLAUDE.md § Cross-file maintenance rules — update it when you add one.
#
# ---------------------------------------------------------------------------
# API
# ---------------------------------------------------------------------------
# Message lines (all accept multiple args, joined with a single space):
#   info    "msg"    [INFO]     blue
#   success "msg"    [SUCCESS]  green
#   warn    "msg"    [WARN]     yellow
#   error   "msg"    [ERROR]    red      → stderr (see LOG_STREAM)
#   skip    "msg"    [SKIP]     dim
#   die     "msg"    [ERROR]    red      → stderr, then `exit 1`
#
# Structure:
#   step "Heading"   blank line + bold heading (section separator)
#   hr               dim horizontal rule
#   dim  "msg"       unlabelled dim text (hints, command echoes)
#
# Verification mode — for one-shot "did this actually work" check scripts.
# This is NOT a test framework: committed, re-runnable tests belong in
# tests/unit/*.bats (`just bats`). Use these when you want a throwaway
# post-apply sanity script that still exits non-zero on failure:
#   ok  "condition holds"     ✔ green,  bumps the pass counter
#   bad "condition broken"    ✘ red,    bumps the fail counter
#   log_summary               prints "N passed, M failed"; returns 1 if M>0
#   log_fail_count            echoes the current fail count
#   log_reset_counters        zeroes both counters
#
# ---------------------------------------------------------------------------
# Configuration — set these BEFORE the include/source line, or set them and
# re-run `log_init` by hand.
# ---------------------------------------------------------------------------
#   LOG_PREFIX     ''       Replaces the [INFO]/[WARN]/… tag on every line
#                           with one fixed label, e.g. '[raycast-sync]'.
#                           Colour still varies by severity.
#
#   LOG_STREAM     'split'  'split'  → error/die go to stderr, rest stdout.
#                           'stdout' → EVERYTHING goes to stdout.
#
#     Why 'stdout' exists, and why every chezmoi run_* script sets it:
#     scripts/fleet/apply.py::_classify_drift() is fed *real stderr lines*
#     on the local-host path, and treats any line it does not recognise as
#     "not pure drift" → the host is reported `failed` instead of `drift`.
#     All 13 pre-migration scripts printed warnings on stdout, so they were
#     invisible to that classifier. Routing them to stderr would silently
#     turn benign `drift` results into `failed` ones. See the fleet-apply
#     invariants in CLAUDE.md.
#
#     Note that even in 'split' mode `warn` stays on stdout — that matches
#     what all 13 scripts did before, and keeps `just upgrade-all 2>/dev/null`
#     from swallowing 47 warnings in upgrade_tools.sh.
#
#   NO_COLOR       unset    Present and non-empty → colour off (no-color.org).
#   CLICOLOR_FORCE unset    Non-empty and not "0" → colour on even when piped.
#                           Deliberately beats NO_COLOR: this repo's yazi
#                           piper rules set it to force colour into a pipe
#                           (see the glow contract in docs/tools/
#                           yazi-previews.md), and an ambient NO_COLOR in the
#                           user's environment must not defeat that.
#
# Auto-detection when neither is set: colour on iff stdout is a TTY and
# TERM is not "dumb".
#
# ---------------------------------------------------------------------------
# Palette — exported for direct use (`printf '%s\n' "${_C_DIM}…${_C_RST}"`).
# Real ESC characters, so they are safe with printf '%s', printf '%b', and
# `echo -e` alike. Initialised empty at load so `set -u` scripts are safe
# even if log_init never runs.
# ---------------------------------------------------------------------------
_C_RED='' _C_GRN='' _C_YLW='' _C_BLU='' _C_CYN='' _C_MAG=''
_C_DIM='' _C_BLD='' _C_RST=''

_LOG_PASS=0
_LOG_FAIL=0

# log_init — (re)compute the palette and reset counters. Safe to call more
# than once; called automatically at the bottom of this file.
log_init() {
  LOG_PREFIX="${LOG_PREFIX:-}"
  LOG_STREAM="${LOG_STREAM:-split}"

  local want_color=0
  if [[ -n "${CLICOLOR_FORCE:-}" && "${CLICOLOR_FORCE}" != "0" ]]; then
    want_color=1
  elif [[ -n "${NO_COLOR:-}" ]]; then
    want_color=0
  elif [[ -t 1 && "${TERM:-}" != "dumb" ]]; then
    want_color=1
  fi

  if [[ "$want_color" == 1 ]]; then
    _C_RED=$'\033[0;31m'
    _C_GRN=$'\033[0;32m'
    _C_YLW=$'\033[1;33m'
    _C_BLU=$'\033[0;34m'
    _C_CYN=$'\033[0;36m'
    _C_MAG=$'\033[0;35m'
    _C_DIM=$'\033[2m'
    _C_BLD=$'\033[1m'
    _C_RST=$'\033[0m'
  else
    _C_RED='' _C_GRN='' _C_YLW='' _C_BLU='' _C_CYN='' _C_MAG=''
    _C_DIM='' _C_BLD='' _C_RST=''
  fi
}

# _log_emit <out|err> <colour> <tag> <message...>
# `local IFS=' '` pins the "$*" join character — import_ssh_to_bw.sh and
# friends reassign IFS for record splitting, and without this the tag and
# message would be glued together with an ASCII unit separator.
_log_emit() {
  local stream="$1" color="$2" tag="$3"
  shift 3
  local IFS=' '
  local label="${LOG_PREFIX:-}"
  [[ -n "$label" ]] || label="$tag"
  if [[ "$stream" == "err" && "${LOG_STREAM:-split}" != "stdout" ]]; then
    printf '%s\n' "${color}${label}${_C_RST} $*" >&2
  else
    printf '%s\n' "${color}${label}${_C_RST} $*"
  fi
}

info() { _log_emit out "$_C_BLU" '[INFO]' "$@"; }
success() { _log_emit out "$_C_GRN" '[SUCCESS]' "$@"; }
warn() { _log_emit out "$_C_YLW" '[WARN]' "$@"; }
error() { _log_emit err "$_C_RED" '[ERROR]' "$@"; }
skip() { _log_emit out "$_C_DIM" '[SKIP]' "$@"; }

# die — error + exit 1. For any other exit code, call `error` then `exit N`
# yourself; scripts with a documented exit-code contract (pre-commit-doctor.sh
# uses 0/1/2/3) need that control.
die() {
  error "$@"
  exit 1
}

# step — section heading. Leading blank line, so sections separate visually
# without every caller remembering to echo one.
step() {
  local IFS=' '
  printf '\n%s\n' "${_C_BLD}$*${_C_RST}"
}

hr() { printf '%s\n' "${_C_DIM}────────────────────────────────────────────${_C_RST}"; }

dim() {
  local IFS=' '
  printf '%s\n' "${_C_DIM}$*${_C_RST}"
}

# --- verification mode ------------------------------------------------------
# Counters use `x=$(( x + 1 ))` and never `(( x++ ))`: the latter evaluates to
# the OLD value, so the first increment (0 → 1) returns exit status 1 and
# kills any caller running under `set -e`.

ok() {
  local IFS=' '
  _LOG_PASS=$((${_LOG_PASS:-0} + 1))
  printf '  %s✔%s %s\n' "$_C_GRN" "$_C_RST" "$*"
}

bad() {
  local IFS=' '
  _LOG_FAIL=$((${_LOG_FAIL:-0} + 1))
  if [[ "${LOG_STREAM:-split}" != "stdout" ]]; then
    printf '  %s✘%s %s\n' "$_C_RED" "$_C_RST" "$*" >&2
  else
    printf '  %s✘%s %s\n' "$_C_RED" "$_C_RST" "$*"
  fi
}

log_fail_count() { printf '%s\n' "${_LOG_FAIL:-0}"; }

log_reset_counters() {
  _LOG_PASS=0
  _LOG_FAIL=0
}

# log_summary — final tally. Returns 1 when anything failed, so the common
# shape is a bare `log_summary` as the script's last line (its return value
# becomes the exit status).
log_summary() {
  local passed="${_LOG_PASS:-0}" failed="${_LOG_FAIL:-0}"
  printf '\n'
  if [[ "$failed" -gt 0 ]]; then
    printf '%s%s passed, %s failed%s\n' "$_C_RED" "$passed" "$failed" "$_C_RST"
    return 1
  fi
  printf '%s%s passed, 0 failed%s\n' "$_C_GRN" "$passed" "$_C_RST"
  return 0
}

log_init
