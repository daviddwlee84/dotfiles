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
  [[ "$output" == "gpt-5.6-sol[1m]|built-in default" ]]
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

# --- _copilot_pkg_name / _copilot_pkg_ready -------------------------------------
#
# pkg_name feeds the pkill pattern that reaps a stalled `bun add`. The naive
# "${spec%@*}" returns EMPTY for a scoped spec with no version, which would turn
# the reap into `pkill -f 'bun add.*'` — a pattern that matches every bun install
# on the box. Hence the scope-stripped test inside the helper, and these cases.

@test "pkg_name: strips the version but keeps the @scope" {
  run bash -c "COPILOT_API_PKG='@jeffreycao/copilot-api@2.1.0' \
    bash -c \"source '$SHELL_LIB'; _copilot_pkg_name\""
  [ "$status" -eq 0 ]
  [ "$output" = "@jeffreycao/copilot-api" ]
}

@test "pkg_name: a scoped spec with NO version survives intact (not emptied)" {
  run bash -c "COPILOT_API_PKG='@jeffreycao/copilot-api' \
    bash -c \"source '$SHELL_LIB'; _copilot_pkg_name\""
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$output" = "@jeffreycao/copilot-api" ]
}

@test "pkg_name: unscoped spec, with and without a version" {
  run bash -c "COPILOT_API_PKG='copilot-api@0.7.0' \
    bash -c \"source '$SHELL_LIB'; _copilot_pkg_name\""
  [ "$output" = "copilot-api" ]
  run bash -c "COPILOT_API_PKG='copilot-api' \
    bash -c \"source '$SHELL_LIB'; _copilot_pkg_name\""
  [ "$output" = "copilot-api" ]
}

@test "pkg_ready: false when the stamp names a DIFFERENT spec than the pin" {
  # A version bump must re-install, not silently run the old binary.
  local prefix="$TMP/data/copilot-api/pkg"
  mkdir -p "$prefix/node_modules/.bin"
  printf '#!/bin/sh\n' > "$prefix/node_modules/.bin/copilot-api"
  chmod +x "$prefix/node_modules/.bin/copilot-api"
  printf '@jeffreycao/copilot-api@2.1.0\n' > "$prefix/.installed-spec"

  run bash -c "export XDG_DATA_HOME='$TMP/data' COPILOT_API_PKG='@jeffreycao/copilot-api@9.9.9'
    source '$SHELL_LIB'; _copilot_pkg_ready"
  [ "$status" -ne 0 ]

  run bash -c "export XDG_DATA_HOME='$TMP/data' COPILOT_API_PKG='@jeffreycao/copilot-api@2.1.0'
    source '$SHELL_LIB'; _copilot_pkg_ready"
  [ "$status" -eq 0 ]
}

@test "pkg_ready: false when the stamp exists but the binary does not" {
  local prefix="$TMP/data/copilot-api/pkg"
  mkdir -p "$prefix"
  printf '@jeffreycao/copilot-api@2.1.0\n' > "$prefix/.installed-spec"
  run bash -c "export XDG_DATA_HOME='$TMP/data' COPILOT_API_PKG='@jeffreycao/copilot-api@2.1.0'
    source '$SHELL_LIB'; _copilot_pkg_ready"
  [ "$status" -ne 0 ]
}

@test "pkg install: npm CA-stack fallback rescues two failed Bun attempts" {
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/bun" <<'SH'
#!/bin/sh
exit 1
SH
  cat > "$TMP/bin/npm" <<'SH'
#!/bin/sh
mkdir -p node_modules/.bin
printf '#!/bin/sh\n' > node_modules/.bin/copilot-api
chmod +x node_modules/.bin/copilot-api
printf '%s\n' npm > npm-fallback-used
SH
  chmod +x "$TMP/bin/bun" "$TMP/bin/npm"

  run bash -c "export PATH='$TMP/bin:/usr/bin:/bin' XDG_DATA_HOME='$TMP/data'
    source '$SHELL_LIB'; _copilot_ensure_pkg >/dev/null"
  [ "$status" -eq 0 ]
  [ -f "$TMP/data/copilot-api/pkg/npm-fallback-used" ]
  [ "$(cat "$TMP/data/copilot-api/pkg/.installed-spec")" = "@jeffreycao/copilot-api@2.1.0" ]
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

# --- model ranking / Claude Code role profiles ---------------------------------

@test "pick_best_model: Claude Fable outranks Opus and OpenAI" {
  run bash -c "printf '%s\n' gpt-5.6-sol claude-opus-5 claude-fable-5 \
    | { source '$SHELL_LIB'; _copilot_pick_best_model; }"
  [ "$status" -eq 0 ]
  [ "$output" = "claude-fable-5" ]
}

@test "pick_best_model: Sol is the strongest OpenAI fallback" {
  run bash -c "printf '%s\n' gpt-5.3-codex gpt-5.6-luna gpt-5.5 gpt-5.6-terra gpt-5.6-sol \
    | { source '$SHELL_LIB'; _copilot_pick_best_model; }"
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-5.6-sol" ]
}

@test "pick_best_model: old flagships outrank lightweight Luna" {
  run bash -c "printf '%s\n' gpt-5.6-luna gpt-5.4-mini gpt-5.3-codex gpt-5.4 gpt-5.5 \
    | { source '$SHELL_LIB'; _copilot_pick_best_model; }"
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-5.5" ]
}

@test "model_for_claude: context metadata controls the [1m] hint" {
  local catalog='{"data":[{"id":"gpt-large","capabilities":{"limits":{"max_context_window_tokens":1050000}}},{"id":"gpt-small","capabilities":{"limits":{"max_context_window_tokens":400000}}}]}'
  run env CATALOG="$catalog" bash -c "source '$SHELL_LIB'
    printf '%s|%s' \"\$(_copilot_model_for_claude gpt-large \"\$CATALOG\")\" \
      \"\$(_copilot_model_for_claude gpt-small \"\$CATALOG\")\""
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-large[1m]|gpt-small" ]
}

@test "model profile: OpenAI maps quality balanced and fast roles" {
  local catalog='{"data":[{"id":"gpt-5.6-sol","capabilities":{"limits":{"max_context_window_tokens":1050000}}},{"id":"gpt-5.6-terra","capabilities":{"limits":{"max_context_window_tokens":1050000}}},{"id":"gpt-5.6-luna","capabilities":{"limits":{"max_context_window_tokens":400000}}}]}'
  run env CATALOG="$catalog" bash -c "source '$SHELL_LIB'
    _copilot_model_profile_json gpt-5.6-sol \"\$CATALOG\" | jq -c ."
  [ "$status" -eq 0 ]
  [ "$output" = '{"main":"gpt-5.6-sol[1m]","fable":"gpt-5.6-sol[1m]","opus":"gpt-5.6-sol[1m]","sonnet":"gpt-5.6-terra[1m]","haiku":"gpt-5.6-luna"}' ]
}

@test "model profile: missing OpenAI role tiers fall back to the selected main" {
  local catalog='{"data":[{"id":"gpt-5.5","capabilities":{"limits":{"max_context_window_tokens":1050000}}}]}'
  run env CATALOG="$catalog" bash -c "source '$SHELL_LIB'
    _copilot_model_profile_json gpt-5.5 \"\$CATALOG\" | jq -r '[.main,.fable,.opus,.sonnet,.haiku] | unique | join(\"|\")'"
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-5.5[1m]" ]
}

@test "model profile: native Claude roles use their strongest served families" {
  local catalog='{"data":[{"id":"claude-fable-5","capabilities":{"limits":{"max_context_window_tokens":1000000}}},{"id":"claude-opus-5","capabilities":{"limits":{"max_context_window_tokens":1000000}}},{"id":"claude-sonnet-5","capabilities":{"limits":{"max_context_window_tokens":1000000}}},{"id":"claude-haiku-4-5","capabilities":{"limits":{"max_context_window_tokens":200000}}}]}'
  run env CATALOG="$catalog" bash -c "source '$SHELL_LIB'
    _copilot_model_profile_json claude-fable-5 \"\$CATALOG\" | jq -c ."
  [ "$status" -eq 0 ]
  [ "$output" = '{"main":"claude-fable-5[1m]","fable":"claude-fable-5[1m]","opus":"claude-opus-5[1m]","sonnet":"claude-sonnet-5[1m]","haiku":"claude-haiku-4-5"}' ]
}

@test "env profile: Fable is managed and legacy small-fast follows Haiku" {
  local catalog='{"data":[{"id":"gpt-5.6-sol","capabilities":{"limits":{"max_context_window_tokens":1050000}}},{"id":"gpt-5.6-terra","capabilities":{"limits":{"max_context_window_tokens":1050000}}},{"id":"gpt-5.6-luna","capabilities":{"limits":{"max_context_window_tokens":400000}}}]}'
  run env CATALOG="$catalog" bash -c "source '$SHELL_LIB'
    _copilot_env_json_for_model gpt-5.6-sol \"\$CATALOG\" \
      | jq -r '[.ANTHROPIC_DEFAULT_FABLE_MODEL,.ANTHROPIC_DEFAULT_OPUS_MODEL,.ANTHROPIC_DEFAULT_SONNET_MODEL,.ANTHROPIC_DEFAULT_HAIKU_MODEL,.ANTHROPIC_SMALL_FAST_MODEL] | join(\"|\")'"
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-5.6-sol[1m]|gpt-5.6-sol[1m]|gpt-5.6-terra[1m]|gpt-5.6-luna|gpt-5.6-luna" ]
}

@test "copilot-model --auto: refuses an offline static fallback" {
  run bash -c "cd '$TMP'; export XDG_STATE_HOME='$TMP/state'; source '$SHELL_LIB'
    _copilot_model_catalog() { return 1; }
    copilot-model --auto"
  [ "$status" -ne 0 ]
  [[ "$output" == *"needs a reachable proxy and live /v1/models catalog"* ]]
  [ ! -f "$TMP/state/copilot-proxy/model" ]
}

@test "copilot-model --auto: refreshes every role in an active local pin" {
  mkdir -p "$TMP/proj/.claude"
  printf '%s\n' '{"env":{"ANTHROPIC_BASE_URL":"http://localhost:4141","ANTHROPIC_MODEL":"stale","ANTHROPIC_DEFAULT_SONNET_MODEL":"stale"},"permissions":{"defaultMode":"auto"}}' \
    > "$TMP/proj/.claude/settings.local.json"
  local catalog='{"data":[{"id":"gpt-5.6-sol","capabilities":{"limits":{"max_context_window_tokens":1050000}}},{"id":"gpt-5.6-terra","capabilities":{"limits":{"max_context_window_tokens":1050000}}},{"id":"gpt-5.6-luna","capabilities":{"limits":{"max_context_window_tokens":400000}}}]}'
  run env CATALOG="$catalog" bash -c "cd '$TMP/proj'; source '$SHELL_LIB'
    _copilot_model_catalog() { printf '%s' \"\$CATALOG\"; }
    copilot-model --auto >/dev/null 2>&1
    jq -r '[.env.ANTHROPIC_MODEL,.env.ANTHROPIC_DEFAULT_FABLE_MODEL,.env.ANTHROPIC_DEFAULT_OPUS_MODEL,.env.ANTHROPIC_DEFAULT_SONNET_MODEL,.env.ANTHROPIC_DEFAULT_HAIKU_MODEL,.env.ANTHROPIC_SMALL_FAST_MODEL,.permissions.defaultMode] | join(\"|\")' .claude/settings.local.json"
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-5.6-sol[1m]|gpt-5.6-sol[1m]|gpt-5.6-sol[1m]|gpt-5.6-terra[1m]|gpt-5.6-luna|gpt-5.6-luna|auto" ]
}
