#!/usr/bin/env bats
# Unit tests for the pure helpers behind `copilot-proxy doctor`
#   dot_config/shell/43_copilot_proxy.sh
#
# Only the OFFLINE, deterministic helpers are covered here. The doctor's
# network checks (_copilot_probe, _copilot_upstream_models) need GitHub and a
# running proxy, so they're exercised by hand, not in CI.
#
# The contract we care about (silent-regression risk):
#   1. _copilot_norm_models must fold the THREE id spellings that the same
#      model has across sources into one key, or the stale-cache diff reports
#      false positives on every run:
#        upstream GitHub : claude-opus-4.8       (dotted)
#        proxy .id       : claude-opus-4-8       (hyphenated)
#        proxy alias     : claude-opus-4-8[1m]   (Claude Code-only suffix)
#   2. _copilot_effective_model must honour the same precedence copilot-model
#      writes with (project pin > $COPILOT_CLAUDE_MODEL > state file > default),
#      or doctor validates a model the client never sends.

load "../test_helper.bash"

SOURCE_DIR="$REPO_ROOT"

setup() {
  SHELL_LIB="$SOURCE_DIR/dot_config/shell/43_copilot_proxy.sh"
  [ -f "$SHELL_LIB" ] || skip "43_copilot_proxy.sh not found"
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/copilot-proxy.XXXXXX")"
}

# `skip` in setup() aborts before TMP exists, so guard — an unguarded
# `[ -n .. ] && rm` would exit non-zero and fail the test it just skipped.
teardown() {
  if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then rm -rf "$TMP"; fi
  return 0
}

# --- _copilot_norm_models -------------------------------------------------------

@test "norm_models: dotted, hyphenated and [1m] spellings fold to one key" {
  run bash -c "printf '%s\n' 'claude-opus-4.8' 'claude-opus-4-8' 'claude-opus-4-8[1m]' \
    | { source '$SHELL_LIB'; _copilot_norm_models; }"
  [ "$status" -eq 0 ]
  [ "$output" = "claude-opus-4-8" ]
}

@test "norm_models: lowercases and de-duplicates" {
  run bash -c "printf '%s\n' 'CLAUDE-Sonnet-5' 'claude-sonnet-5' \
    | { source '$SHELL_LIB'; _copilot_norm_models; }"
  [ "$status" -eq 0 ]
  [ "$output" = "claude-sonnet-5" ]
}

@test "norm_models: strips [1m] only as a suffix, not mid-string" {
  run bash -c "printf '%s\n' 'gpt-5.5[1m]' 'weird[1m]name' \
    | { source '$SHELL_LIB'; _copilot_norm_models; }"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'gpt-5-5'
  printf '%s\n' "$output" | grep -qx 'weird\[1m\]name'
}

@test "norm_models: a missing upstream id survives the set-difference" {
  # The diff doctor performs: upstream MINUS served, restricted to claude ids.
  local served upstream missing
  served="$(printf '%s\n' 'gpt-5.5' 'gemini-2.5-pro' | { source "$SHELL_LIB"; _copilot_norm_models; })"
  upstream="$(printf '%s\n' 'claude-opus-4.8' 'gpt-5.5' | { source "$SHELL_LIB"; _copilot_norm_models; })"
  missing="$(printf '%s\n' "$upstream" | grep -i '^claude' | while IFS= read -r m; do
    printf '%s\n' "$served" | grep -qxF "$m" || printf '%s\n' "$m"
  done)"
  [ "$missing" = "claude-opus-4-8" ]
}

@test "norm_models: identical lists yield an empty difference" {
  local served upstream missing
  served="$(printf '%s\n' 'claude-opus-4-8' 'claude-opus-4-8[1m]' | { source "$SHELL_LIB"; _copilot_norm_models; })"
  upstream="$(printf '%s\n' 'claude-opus-4.8' | { source "$SHELL_LIB"; _copilot_norm_models; })"
  missing="$(printf '%s\n' "$upstream" | grep -i '^claude' | while IFS= read -r m; do
    printf '%s\n' "$served" | grep -qxF "$m" || printf '%s\n' "$m"
  done)"
  [ -z "$missing" ]
}

# --- _copilot_effective_model ---------------------------------------------------

@test "effective_model: falls back to the built-in default" {
  run bash -c "cd '$TMP'; export XDG_STATE_HOME='$TMP/state'; unset COPILOT_CLAUDE_MODEL
    source '$SHELL_LIB'; _copilot_effective_model"
  [ "$status" -eq 0 ]
  [[ "$output" == "claude-opus-4-8[1m]|built-in default" ]]
}

@test "effective_model: \$COPILOT_CLAUDE_MODEL outranks the state file" {
  mkdir -p "$TMP/state/copilot-proxy"
  printf 'claude-sonnet-5\n' > "$TMP/state/copilot-proxy/model"
  run bash -c "cd '$TMP'; export XDG_STATE_HOME='$TMP/state' COPILOT_CLAUDE_MODEL='claude-haiku-4-5'
    source '$SHELL_LIB'; _copilot_effective_model"
  [ "$status" -eq 0 ]
  [[ "$output" == "claude-haiku-4-5|\$COPILOT_CLAUDE_MODEL" ]]
}

@test "effective_model: state file outranks the built-in default" {
  mkdir -p "$TMP/state/copilot-proxy"
  printf 'claude-sonnet-5\n' > "$TMP/state/copilot-proxy/model"
  run bash -c "cd '$TMP'; export XDG_STATE_HOME='$TMP/state'; unset COPILOT_CLAUDE_MODEL
    source '$SHELL_LIB'; _copilot_effective_model"
  [ "$status" -eq 0 ]
  [[ "$output" == claude-sonnet-5\|state\ file:* ]]
}

@test "effective_model: a copilot-here project pin outranks everything" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  mkdir -p "$TMP/proj/.claude" "$TMP/state/copilot-proxy"
  printf 'claude-sonnet-5\n' > "$TMP/state/copilot-proxy/model"
  cat > "$TMP/proj/.claude/settings.local.json" <<'JSON'
{"env":{"ANTHROPIC_BASE_URL":"http://localhost:4141","ANTHROPIC_MODEL":"claude-opus-4-6[1m]"}}
JSON
  run bash -c "cd '$TMP/proj'; export XDG_STATE_HOME='$TMP/state' COPILOT_CLAUDE_MODEL='claude-haiku-4-5'
    source '$SHELL_LIB'; _copilot_effective_model"
  [ "$status" -eq 0 ]
  [[ "$output" == "claude-opus-4-6[1m]|project pin: .claude/settings.local.json" ]]
}

@test "effective_model: a settings.local.json WITHOUT our base_url is not a pin" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  mkdir -p "$TMP/proj/.claude" "$TMP/state/copilot-proxy"
  printf 'claude-sonnet-5\n' > "$TMP/state/copilot-proxy/model"
  # plansDirectory-only local settings: copilot-here is OFF here
  printf '%s\n' '{"plansDirectory":".claude/plans"}' > "$TMP/proj/.claude/settings.local.json"
  run bash -c "cd '$TMP/proj'; export XDG_STATE_HOME='$TMP/state'; unset COPILOT_CLAUDE_MODEL
    source '$SHELL_LIB'; _copilot_effective_model"
  [ "$status" -eq 0 ]
  [[ "$output" == claude-sonnet-5\|state\ file:* ]]
}
