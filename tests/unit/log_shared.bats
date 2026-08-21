#!/usr/bin/env bats
# Unit tests for scripts/lib/log_shared.sh — the shared console-logging
# vocabulary inlined into every chezmoi run-script and sourced by scripts/*.sh.
#
# Why this file earns its keep: the lib is consumed by 13 scripts, nine of them
# via `{{ include }}` into run-scripts that only execute during a real
# `chezmoi apply`. A regression there surfaces as a broken bootstrap on a fresh
# machine, which is the worst possible place to find it. The `set -e` counter
# test in particular guards a trap that is invisible on inspection: `(( x++ ))`
# evaluates to the OLD value, so the very first increment returns exit status 1
# and kills the caller.

load "../test_helper.bash"

# `run --separate-stderr` (used by the stream-routing tests) needs bats >= 1.5.
# Without this declaration bats emits a BW02 warning for every such call.
bats_require_minimum_version 1.5.0

setup() {
  LIB="$REPO_ROOT/scripts/lib/log_shared.sh"
  SNIP="$BATS_TEST_TMPDIR/snippet.sh"
}

# Write a test script that has $LIB predefined, then the heredoc body.
# Bodies use `. "$LIB"` themselves so each test controls whether config
# variables are set before or after the source.
_write() {
  {
    echo "LIB='$LIB'"
    cat
  } > "$SNIP"
}

@test "lib exists and is shellcheck-clean at the repo's hook severity" {
  [ -f "$LIB" ]
  if ! command -v shellcheck > /dev/null 2>&1; then
    skip "shellcheck not installed"
  fi
  run shellcheck --shell=bash --severity=warning "$LIB"
  [ "$status" -eq 0 ]
}

# --- colour detection -------------------------------------------------------

@test "no colour when stdout is not a TTY" {
  _write <<'EOF'
. "$LIB"
info "plain"
EOF
  run bash "$SNIP"
  [ "$status" -eq 0 ]
  [ "$output" = "[INFO] plain" ]
}

@test "CLICOLOR_FORCE emits ANSI even when piped" {
  _write <<'EOF'
. "$LIB"
info "coloured"
EOF
  CLICOLOR_FORCE=1 run bash "$SNIP"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\033[0;34m'* ]]
}

@test "CLICOLOR_FORCE=0 does not force colour" {
  _write <<'EOF'
. "$LIB"
info "plain"
EOF
  CLICOLOR_FORCE=0 run bash "$SNIP"
  [ "$output" = "[INFO] plain" ]
}

@test "NO_COLOR suppresses colour" {
  _write <<'EOF'
. "$LIB"
log_init
info "plain"
EOF
  # Force colour on via a fake TTY check would be fragile; instead assert that
  # NO_COLOR wins over the TTY branch by checking no ESC ever appears.
  NO_COLOR=1 run bash "$SNIP"
  [[ "$output" != *$'\033'* ]]
}

@test "CLICOLOR_FORCE beats NO_COLOR (documented precedence)" {
  # This ordering is load-bearing: yazi piper rules set CLICOLOR_FORCE to push
  # colour through a pipe, and an ambient NO_COLOR must not defeat that.
  _write <<'EOF'
. "$LIB"
info "coloured"
EOF
  NO_COLOR=1 CLICOLOR_FORCE=1 run bash "$SNIP"
  [[ "$output" == *$'\033[0;34m'* ]]
}

@test "TERM=dumb suppresses colour" {
  _write <<'EOF'
. "$LIB"
info "plain"
EOF
  TERM=dumb run bash "$SNIP"
  [[ "$output" != *$'\033'* ]]
}

# --- stream routing ---------------------------------------------------------

@test "default split mode sends error to stderr and info/warn to stdout" {
  _write <<'EOF'
. "$LIB"
info "on stdout"
warn "also stdout"
error "on stderr"
EOF
  run --separate-stderr bash "$SNIP"
  [[ "$output" == *"[INFO] on stdout"* ]]
  # warn stays on stdout on purpose — all 13 pre-migration scripts did that,
  # and moving it would break `just upgrade-all 2>/dev/null`.
  [[ "$output" == *"[WARN] also stdout"* ]]
  [[ "$output" != *"[ERROR]"* ]]
  [[ "$stderr" == *"[ERROR] on stderr"* ]]
}

@test "LOG_STREAM=stdout keeps stderr completely empty" {
  # This is what every chezmoi run-script sets. fleet-apply's local-host drift
  # classifier reads real stderr and demotes the host to `failed` on any line
  # it does not recognise, so run-scripts must not write there.
  _write <<'EOF'
LOG_STREAM=stdout
. "$LIB"
info "i"; warn "w"; error "e"; bad "b"
EOF
  run --separate-stderr bash "$SNIP"
  [ "$stderr" = "" ]
  [[ "$output" == *"[ERROR] e"* ]]
}

@test "LOG_STREAM set after sourcing still takes effect" {
  _write <<'EOF'
. "$LIB"
LOG_STREAM=stdout
error "late"
EOF
  run --separate-stderr bash "$SNIP"
  [ "$stderr" = "" ]
  [[ "$output" == *"[ERROR] late"* ]]
}

# --- LOG_PREFIX -------------------------------------------------------------

@test "LOG_PREFIX replaces the severity tag on every line" {
  _write <<'EOF'
LOG_PREFIX='[raycast-sync]'
LOG_STREAM=stdout
. "$LIB"
info "a"; warn "b"; error "c"
EOF
  run bash "$SNIP"
  [ "${lines[0]}" = "[raycast-sync] a" ]
  [ "${lines[1]}" = "[raycast-sync] b" ]
  [ "${lines[2]}" = "[raycast-sync] c" ]
}

# --- verification mode ------------------------------------------------------

@test "ok/bad under set -e: the first increment must not abort the script" {
  # The regression this guards: `(( _LOG_PASS++ ))` returns the pre-increment
  # value, so going 0 -> 1 exits 1 and `set -e` kills everything downstream.
  _write <<'EOF'
set -euo pipefail
. "$LIB"
ok "first"
ok "second"
bad "third"
echo "REACHED_END"
EOF
  run bash "$SNIP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"REACHED_END"* ]]
}

@test "log_summary counts and returns 1 when anything failed" {
  _write <<'EOF'
set -euo pipefail
. "$LIB"
ok "a"; ok "b"; bad "c"
log_summary
EOF
  run bash "$SNIP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"2 passed, 1 failed"* ]]
}

@test "log_summary returns 0 when everything passed" {
  _write <<'EOF'
set -euo pipefail
. "$LIB"
ok "a"; ok "b"
log_summary
EOF
  run bash "$SNIP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 passed, 0 failed"* ]]
}

@test "log_fail_count and log_reset_counters" {
  _write <<'EOF'
set -euo pipefail
. "$LIB"
bad "x" > /dev/null 2>&1
bad "y" > /dev/null 2>&1
log_fail_count
log_reset_counters
log_fail_count
EOF
  run bash "$SNIP"
  [ "${lines[0]}" = "2" ]
  [ "${lines[1]}" = "0" ]
}

# --- robustness -------------------------------------------------------------

@test "helpers survive set -u without an explicit log_init call" {
  _write <<'EOF'
set -euo pipefail
. "$LIB"
info "a"; success "b"; warn "c"; skip "d"; step "e"; dim "f"; hr
echo "REACHED_END"
EOF
  run bash "$SNIP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"REACHED_END"* ]]
}

@test "a hostile IFS in the caller does not corrupt output" {
  # import_ssh_to_bw.sh reassigns IFS for record splitting; without the
  # `local IFS=' '` pin inside _log_emit the tag and message get glued
  # together with whatever separator the caller left behind.
  _write <<'EOF'
set -euo pipefail
. "$LIB"
IFS=$'\x1f'
info "two" "words"
EOF
  run bash "$SNIP"
  [ "$output" = "[INFO] two words" ]
}

@test "die prints to stderr and exits 1" {
  _write <<'EOF'
. "$LIB"
die "fatal thing"
echo "SHOULD_NOT_REACH"
EOF
  run --separate-stderr bash "$SNIP"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"[ERROR] fatal thing"* ]]
  [[ "$output" != *"SHOULD_NOT_REACH"* ]]
}

@test "multi-word messages join with a single space" {
  _write <<'EOF'
. "$LIB"
info "alpha" "beta" "gamma"
EOF
  run bash "$SNIP"
  [ "$output" = "[INFO] alpha beta gamma" ]
}

# --- wiring guard -----------------------------------------------------------
# The lib is only useful if its consumers actually reference it. These two
# tests fail loudly if a future edit drops the include/source line, which
# would otherwise reintroduce a hand-rolled helper block unnoticed.

@test "every chezmoi run-script consumer still inlines the lib" {
  local f
  local -a templates=(
    "run_once_before_00_bootstrap.sh.tmpl"
    "run_once_before_02_fix_intel_homebrew.sh.tmpl"
    ".chezmoiscripts/global/run_after_25_bat_theme.sh.tmpl"
    ".chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl"
    ".chezmoiscripts/global/run_onchange_after_26_install_blesh.sh.tmpl"
    ".chezmoiscripts/global/run_onchange_after_30_brew_bundle.sh.tmpl"
    ".chezmoiscripts/global/run_onchange_after_40_install_global_skills.sh.tmpl"
    ".chezmoiscripts/global/run_after_42_sync_herdr_skill.sh.tmpl"
    ".chezmoiscripts/global/run_after_45_yazi_plugins.sh.tmpl"
    ".chezmoiscripts/repo/run_onchange_after_45_bootstrap_skills.sh.tmpl"
    "backlog/raycast-sync/run_onchange_after_32_raycast_config.sh.tmpl"
  )
  for f in "${templates[@]}"; do
    [ -f "$REPO_ROOT/$f" ] || fail "missing consumer: $f"
    grep -q 'include "scripts/lib/log_shared.sh"' "$REPO_ROOT/$f" \
      || fail "$f no longer includes scripts/lib/log_shared.sh"
    # And it must not have grown a private copy of the helpers back.
    if grep -qE '^\s*(info|warn|success|error)\(\)' "$REPO_ROOT/$f"; then
      fail "$f redefines a log helper that the shared lib already provides"
    fi
  done
}

@test "every scripts/ consumer still sources the lib" {
  local f
  for f in upgrade_tools.sh pre-commit-doctor.sh import_ssh_to_bw.sh; do
    [ -f "$REPO_ROOT/scripts/$f" ] || fail "missing consumer: scripts/$f"
    grep -q 'scripts/lib/log_shared.sh' "$REPO_ROOT/scripts/$f" \
      || fail "scripts/$f no longer sources scripts/lib/log_shared.sh"
    if grep -qE '^\s*(info|warn|success|error|hr|skip)\(\)' "$REPO_ROOT/scripts/$f"; then
      fail "scripts/$f redefines a log helper that the shared lib already provides"
    fi
  done
}
