#!/usr/bin/env bats
# Unit tests for the coding-agent CLI overlay scripts:
#   dot_cursor/modify_cli-config.json.tmpl
#   dot_config/opencode/modify_opencode.json.tmpl
#   dot_codex/modify_config.toml.tmpl
#
# Each script is a chezmoi `modify_` template: chezmoi pipes the live target
# file into stdin and expects the new contents on stdout. The contract we
# care about (silent-regression risk):
#   1. Overlay keys are enforced.
#   2. Live runtime keys outside the overlay are preserved verbatim.
#   3. For Codex specifically: [projects."<path>"] and [marketplaces.*]
#      round-trip unchanged (machine-local trust state).
#
# Tests render each .tmpl via `chezmoi execute-template` first (so the
# `{{ template ... }}` includes are resolved), then exec the rendered script
# with crafted stdin.

load "../test_helper.bash"

SOURCE_DIR="$REPO_ROOT"

setup() {
  RENDER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agent-overlay.XXXXXX")"
  export RENDER_DIR
}

teardown() {
  [ -n "${RENDER_DIR:-}" ] && [ -d "$RENDER_DIR" ] && rm -rf "$RENDER_DIR"
}

# Render a chezmoi modify_ template into a runnable script.
_render() {
  local src="$1" out="$2"
  chezmoi execute-template --source "$SOURCE_DIR" < "$src" > "$out"
  chmod +x "$out"
}

_render_with_data() {
  local src="$1" out="$2" data="$3"
  chezmoi execute-template --source "$SOURCE_DIR" --override-data "$data" < "$src" > "$out"
  chmod +x "$out"
}

_have_chezmoi() {
  command -v chezmoi >/dev/null 2>&1
}

@test "cursor modify_cli-config: overlay keys enforced, runtime keys preserved" {
  _have_chezmoi || skip "chezmoi not installed"
  command -v jq >/dev/null 2>&1 || skip "jq not installed"

  local script="$RENDER_DIR/cursor.sh"
  _render "$SOURCE_DIR/dot_cursor/modify_cli-config.json.tmpl" "$script"

  # Live file with runtime/secret keys we must NOT touch.
  local live='{
    "version": 1,
    "authInfo": {"token": "SECRET-DO-NOT-LEAK"},
    "privacyCache": {"hash": "abc"},
    "statsigBootstrap": {"x": "y"},
    "editor": {"vimMode": false, "fontSize": 14}
  }'

  run bash -c "printf '%s' \"\$1\" | '$script'" _ "$live"
  [ "$status" -eq 0 ]

  # Overlay enforces editor.vimMode=true.
  echo "$output" | jq -e '.editor.vimMode == true' >/dev/null
  # Runtime keys preserved verbatim.
  echo "$output" | jq -e '.authInfo.token == "SECRET-DO-NOT-LEAK"' >/dev/null
  echo "$output" | jq -e '.privacyCache.hash == "abc"' >/dev/null
  echo "$output" | jq -e '.statsigBootstrap.x == "y"' >/dev/null
  echo "$output" | jq -e '.version == 1' >/dev/null
  # Sibling key under editor must survive (deep merge).
  echo "$output" | jq -e '.editor.fontSize == 14' >/dev/null
}

@test "cursor modify_cli-config: empty live file produces overlay-only output" {
  _have_chezmoi || skip "chezmoi not installed"
  command -v jq >/dev/null 2>&1 || skip "jq not installed"

  local script="$RENDER_DIR/cursor.sh"
  _render "$SOURCE_DIR/dot_cursor/modify_cli-config.json.tmpl" "$script"

  run bash -c "printf '' | '$script'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.editor.vimMode == true' >/dev/null
}

@test "opencode modify_opencode: overlay enforced, plugin paths preserved" {
  _have_chezmoi || skip "chezmoi not installed"
  command -v jq >/dev/null 2>&1 || skip "jq not installed"

  local script="$RENDER_DIR/opencode.sh"
  _render "$SOURCE_DIR/dot_config/opencode/modify_opencode.json.tmpl" "$script"

  local live='{
    "$schema": "https://opencode.ai/config.json",
    "plugin": ["file:///Users/me/.config/opencode/plugins/local.js"],
    "agent": {"title": {"reasoningEffort": "high"}, "build": {"model": "x"}}
  }'

  run bash -c "printf '%s' \"\$1\" | '$script'" _ "$live"
  [ "$status" -eq 0 ]

  echo "$output" | jq -e '.autoupdate == true' >/dev/null
  # Overlay sets agent.title.reasoningEffort=low.
  echo "$output" | jq -e '.["agent"].title.reasoningEffort == "low"' >/dev/null
  # default_agent and small_model enforced by overlay.
  echo "$output" | jq -e '.default_agent == "build"' >/dev/null
  echo "$output" | jq -e '.small_model == "github-copilot/gpt-5-mini"' >/dev/null
  # Copilot stream-stall mitigation enforced (timeout only; chunkTimeout
  # intentionally absent — see docs/tools/opencode.md).
  echo "$output" | jq -e '.provider["github-copilot"].options.timeout == 600000' >/dev/null
  echo "$output" | jq -e '.provider["github-copilot"].options | has("chunkTimeout") | not' >/dev/null
  # Sibling agent.build untouched.
  echo "$output" | jq -e '.["agent"].build.model == "x"' >/dev/null
  # Local plugin path preserved verbatim (machine-local).
  echo "$output" | jq -e '.plugin[0] == "file:///Users/me/.config/opencode/plugins/local.js"' >/dev/null
}

@test "codex modify_config.toml: overlay enforced, [projects] and [marketplaces.*] preserved" {
  _have_chezmoi || skip "chezmoi not installed"
  command -v yq >/dev/null 2>&1 || skip "yq not installed"
  yq --version 2>&1 | grep -qi 'mikefarah' || skip "wrong yq variant (need mikefarah/yq)"

  local script="$RENDER_DIR/codex.sh"
  _render "$SOURCE_DIR/dot_codex/modify_config.toml.tmpl" "$script"

  local live='personality = "old"
model = "old-model"
model_reasoning_effort = "low"

[features]
codex_hooks = false
some_user_flag = true

[projects."/Users/me/secret-repo"]
trust_level = "trusted"

[projects."/tmp/scratch"]
trust_level = "trusted"

[marketplaces.openai-bundled]
last_updated = "2026-04-22T05:56:50Z"
source_type = "local"
source = "/Users/me/.codex/.tmp/bundled-marketplaces/openai-bundled"
'

  run bash -c "printf '%s' \"\$1\" | '$script'" _ "$live"
  [ "$status" -eq 0 ]

  # Overlay wins on managed keys, but no longer pins the default model.
  echo "$output" | yq -p toml -e '.personality == "pragmatic"' >/dev/null
  echo "$output" | yq -p toml -e '.model == "old-model"' >/dev/null
  echo "$output" | yq -p toml -e '.model_reasoning_effort == "xhigh"' >/dev/null
  echo "$output" | yq -p toml -e '.features.hooks == true' >/dev/null
  echo "$output" | yq -p toml -e '.features.unified_exec == true' >/dev/null
  echo "$output" | yq -p toml -e '.tui.keymap.editor.insert_newline[0] == "ctrl-j"' >/dev/null
  echo "$output" | yq -p toml -e '.tui.keymap.editor.insert_newline[1] == "shift-enter"' >/dev/null
  echo "$output" | yq -p toml -e '.tui.keymap.editor.insert_newline[2] == "alt-enter"' >/dev/null
  # Deprecated live key must be pruned, not preserved beside `hooks`.
  echo "$output" | yq -p toml -e '.features | has("codex_hooks") | not' >/dev/null
  # User-added [features] keys outside overlay survive.
  echo "$output" | yq -p toml -e '.features.some_user_flag == true' >/dev/null
  # Per-project trust round-trips verbatim.
  echo "$output" | yq -p toml -e '.projects["/Users/me/secret-repo"].trust_level == "trusted"' >/dev/null
  echo "$output" | yq -p toml -e '.projects["/tmp/scratch"].trust_level == "trusted"' >/dev/null
  # Marketplace block round-trips verbatim.
  echo "$output" | yq -p toml -e '.marketplaces["openai-bundled"].source == "/Users/me/.codex/.tmp/bundled-marketplaces/openai-bundled"' >/dev/null
}

@test "codex modify_config.toml: empty live file produces overlay-only output" {
  _have_chezmoi || skip "chezmoi not installed"
  command -v yq >/dev/null 2>&1 || skip "yq not installed"
  yq --version 2>&1 | grep -qi 'mikefarah' || skip "wrong yq variant"

  local script="$RENDER_DIR/codex.sh"
  _render "$SOURCE_DIR/dot_codex/modify_config.toml.tmpl" "$script"

  run bash -c "printf '' | '$script'"
  [ "$status" -eq 0 ]
  echo "$output" | yq -p toml -e '.personality == "pragmatic"' >/dev/null
  echo "$output" | yq -p toml -e '. | has("model") | not' >/dev/null
  echo "$output" | yq -p toml -e '.features.steer == true' >/dev/null
  echo "$output" | yq -p toml -e '.tui.keymap.editor.insert_newline[1] == "shift-enter"' >/dev/null
}

@test "codex modify_config.toml: stale managed model is pruned but custom model survives" {
  _have_chezmoi || skip "chezmoi not installed"
  command -v yq >/dev/null 2>&1 || skip "yq not installed"
  yq --version 2>&1 | grep -qi 'mikefarah' || skip "wrong yq variant"

  local script="$RENDER_DIR/codex.sh"
  _render "$SOURCE_DIR/dot_codex/modify_config.toml.tmpl" "$script"

  local stale_live='model = "gpt-5.4"
model_reasoning_effort = "low"
'
  run bash -c "printf '%s' \"\$1\" | '$script'" _ "$stale_live"
  [ "$status" -eq 0 ]
  echo "$output" | yq -p toml -e '. | has("model") | not' >/dev/null
  echo "$output" | yq -p toml -e '.model_reasoning_effort == "xhigh"' >/dev/null

  local custom_live='model = "gpt-5.5"
model_reasoning_effort = "low"
'
  run bash -c "printf '%s' \"\$1\" | '$script'" _ "$custom_live"
  [ "$status" -eq 0 ]
  echo "$output" | yq -p toml -e '.model == "gpt-5.5"' >/dev/null
  echo "$output" | yq -p toml -e '.model_reasoning_effort == "xhigh"' >/dev/null
}

@test "codex modify_config.toml: useChineseMirror does not persist reserved OpenAI provider override" {
  _have_chezmoi || skip "chezmoi not installed"
  command -v yq >/dev/null 2>&1 || skip "yq not installed"
  yq --version 2>&1 | grep -qi 'mikefarah' || skip "wrong yq variant"

  local script="$RENDER_DIR/codex-gfw.sh"
  _render_with_data "$SOURCE_DIR/dot_codex/modify_config.toml.tmpl" "$script" '{"useChineseMirror":true}'

  run bash -c "printf '' | '$script'"
  [ "$status" -eq 0 ]
  echo "$output" | yq -p toml -e '. | has("model_providers") | not' >/dev/null
}

@test "codex modify_config.toml: prunes invalid built-in OpenAI provider but preserves custom providers" {
  _have_chezmoi || skip "chezmoi not installed"
  command -v yq >/dev/null 2>&1 || skip "yq not installed"
  yq --version 2>&1 | grep -qi 'mikefarah' || skip "wrong yq variant"

  local script="$RENDER_DIR/codex-prune-reserved.sh"
  _render_with_data "$SOURCE_DIR/dot_codex/modify_config.toml.tmpl" "$script" '{"useChineseMirror":true}'

  local stale_live='[model_providers.openai]
stream_max_retries = 1
websocket_connect_timeout_ms = 3000
supports_websockets = false
request_max_retries = 7

[model_providers.openai-gfw]
stream_max_retries = 2
websocket_connect_timeout_ms = 5000
'

  run bash -c "printf '%s' \"\$1\" | '$script'" _ "$stale_live"
  [ "$status" -eq 0 ]
  echo "$output" | yq -p toml -e '.model_providers | has("openai") | not' >/dev/null
  echo "$output" | yq -p toml -e '.model_providers["openai-gfw"].stream_max_retries == 2' >/dev/null
  echo "$output" | yq -p toml -e '.model_providers["openai-gfw"].websocket_connect_timeout_ms == 5000' >/dev/null
}

@test "opencode migrate: legacy config.json renamed when modern absent" {
  local fake_home="$RENDER_DIR/home"
  mkdir -p "$fake_home/.config/opencode"
  printf '{"foo": "bar"}' > "$fake_home/.config/opencode/config.json"

  HOME="$fake_home" run bash "$SOURCE_DIR/run_once_before_50_opencode_migrate.sh.tmpl"
  [ "$status" -eq 0 ]
  [ ! -f "$fake_home/.config/opencode/config.json" ]
  [ -f "$fake_home/.config/opencode/opencode.json" ]
  grep -q '"foo": "bar"' "$fake_home/.config/opencode/opencode.json"
}

@test "opencode migrate: legacy + modern both present -> merge then delete legacy" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"

  local fake_home="$RENDER_DIR/home"
  mkdir -p "$fake_home/.config/opencode"
  printf '{"a": 1, "b": "from-legacy"}' > "$fake_home/.config/opencode/config.json"
  printf '{"b": "from-modern", "c": 3}' > "$fake_home/.config/opencode/opencode.json"

  HOME="$fake_home" run bash "$SOURCE_DIR/run_once_before_50_opencode_migrate.sh.tmpl"
  [ "$status" -eq 0 ]
  [ ! -f "$fake_home/.config/opencode/config.json" ]
  # Modern wins on conflict (b="from-modern"); a + c merged in.
  jq -e '.a == 1' "$fake_home/.config/opencode/opencode.json" >/dev/null
  jq -e '.b == "from-modern"' "$fake_home/.config/opencode/opencode.json" >/dev/null
  jq -e '.c == 3' "$fake_home/.config/opencode/opencode.json" >/dev/null
}

@test "opencode migrate: no-op when legacy absent" {
  local fake_home="$RENDER_DIR/home"
  mkdir -p "$fake_home/.config/opencode"
  printf '{"x": 1}' > "$fake_home/.config/opencode/opencode.json"

  HOME="$fake_home" run bash "$SOURCE_DIR/run_once_before_50_opencode_migrate.sh.tmpl"
  [ "$status" -eq 0 ]
  [ -f "$fake_home/.config/opencode/opencode.json" ]
  grep -q '"x": 1' "$fake_home/.config/opencode/opencode.json"
}

# -----------------------------------------------------------------------------
# Claude settings.json hook-aware merger
#
# The Claude overlay must coexist with CodeIsland (https://github.com/wxtsky/
# CodeIsland), which auto-installs entries into hooks.<event> arrays. A naive
# `jq '. * $overlay'` would replace those arrays wholesale and silently
# delete CodeIsland's entries on every apply. The new merger:
#   - deep-merges everything except .hooks normally,
#   - additively merges .hooks.<event> arrays by .hooks[0].command substring
#     match (overlay entries appended only if not already present).
# -----------------------------------------------------------------------------

@test "claude modify_settings: notify.sh added to empty hooks, codeisland entries preserved" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"

  # Live file mimics a fresh install where CodeIsland has already injected
  # its entries but our notify.sh hook is missing.
  local live='{
    "model": "sonnet",
    "permissions": {"defaultMode": "auto"},
    "hooks": {
      "Notification": [
        {"matcher": "", "hooks": [{"type": "command", "command": "~/.codeisland/codeisland-hook.sh", "timeout": 86400}]}
      ],
      "Stop": [
        {"matcher": "", "hooks": [{"type": "command", "command": "~/.codeisland/codeisland-hook.sh", "timeout": 5}]}
      ],
      "PreToolUse": [
        {"matcher": "", "hooks": [{"type": "command", "command": "~/.codeisland/codeisland-hook.sh", "timeout": 5}]}
      ]
    }
  }'

  run bash -c "printf '%s' \"\$1\" | sh '$SOURCE_DIR/dot_claude/modify_settings.json'" _ "$live"
  [ "$status" -eq 0 ]

  # Notification: CodeIsland entry preserved + notify.sh + workmux waiting appended.
  echo "$output" | jq -e '.hooks.Notification | length == 3' >/dev/null
  echo "$output" | jq -e '.hooks.Notification | map(.hooks[0].command) | index("~/.codeisland/codeisland-hook.sh") != null' >/dev/null
  echo "$output" | jq -e '.hooks.Notification | map(.hooks[0].command) | index("~/.claude/hooks/notify.sh") != null' >/dev/null
  echo "$output" | jq -e '.hooks.Notification | map(.hooks[0].command) | any(. | test("workmux set-window-status waiting"))' >/dev/null
  # Stop: CodeIsland + notify.sh + workmux done.
  echo "$output" | jq -e '.hooks.Stop | length == 3' >/dev/null
  echo "$output" | jq -e '.hooks.Stop | map(.hooks[0].command) | index("~/.claude/hooks/notify.sh") != null' >/dev/null
  echo "$output" | jq -e '.hooks.Stop | map(.hooks[0].command) | index("~/.codeisland/codeisland-hook.sh") != null' >/dev/null
  echo "$output" | jq -e '.hooks.Stop | map(.hooks[0].command) | any(. | test("workmux set-window-status done"))' >/dev/null
  # SubagentStop: workmux done injected (live had nothing).
  echo "$output" | jq -e '.hooks.SubagentStop | length == 1' >/dev/null
  echo "$output" | jq -e '.hooks.SubagentStop[0].hooks[0].command | test("workmux set-window-status done")' >/dev/null
  # UserPromptSubmit: workmux working injected.
  echo "$output" | jq -e '.hooks.UserPromptSubmit | length == 1' >/dev/null
  echo "$output" | jq -e '.hooks.UserPromptSubmit[0].hooks[0].command | test("workmux set-window-status working")' >/dev/null
  # PreToolUse: only CodeIsland entry (not in our overlay), must survive untouched.
  echo "$output" | jq -e '.hooks.PreToolUse | length == 1' >/dev/null
  echo "$output" | jq -e '.hooks.PreToolUse[0].hooks[0].command == "~/.codeisland/codeisland-hook.sh"' >/dev/null
  # Non-hook keys: live values preserved EXCEPT where overlay scalars override.
  echo "$output" | jq -e '.model == "sonnet"' >/dev/null
  # `permissions.defaultMode` is enforced by overlay → live "auto" loses to overlay "bypassPermissions".
  echo "$output" | jq -e '.permissions.defaultMode == "bypassPermissions"' >/dev/null
  echo "$output" | jq -e '.skipDangerousModePermissionPrompt == true' >/dev/null
  echo "$output" | jq -e '.enabledPlugins["claude-hud@claude-hud"] == true' >/dev/null
}

@test "claude modify_settings: idempotent when notify.sh already present" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"

  local live='{
    "hooks": {
      "Notification": [
        {"matcher": "", "hooks": [{"type": "command", "command": "~/.codeisland/codeisland-hook.sh", "timeout": 86400}]},
        {"matcher": "", "hooks": [{"type": "command", "command": "~/.claude/hooks/notify.sh"}]}
      ],
      "Stop": [
        {"hooks": [{"type": "command", "command": "~/.claude/hooks/notify.sh"}]},
        {"matcher": "", "hooks": [{"type": "command", "command": "~/.codeisland/codeisland-hook.sh", "timeout": 5}]}
      ]
    }
  }'

  # First pass.
  pass1=$(printf '%s' "$live" | sh "$SOURCE_DIR/dot_claude/modify_settings.json")
  # Second pass on the result of the first.
  pass2=$(printf '%s' "$pass1" | sh "$SOURCE_DIR/dot_claude/modify_settings.json")

  # No duplicate notify.sh entry on first pass.
  printf '%s' "$pass1" | jq -e '[.hooks.Notification[] | select(.hooks[0].command == "~/.claude/hooks/notify.sh")] | length == 1' >/dev/null
  printf '%s' "$pass1" | jq -e '[.hooks.Stop[] | select(.hooks[0].command == "~/.claude/hooks/notify.sh")] | length == 1' >/dev/null

  # Stable across re-application.
  diff <(printf '%s' "$pass1" | jq -S .) <(printf '%s' "$pass2" | jq -S .)
}

@test "claude modify_settings: empty live file produces overlay-only output" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"

  run bash -c "printf '' | sh '$SOURCE_DIR/dot_claude/modify_settings.json'"
  [ "$status" -eq 0 ]

  echo "$output" | jq -e '.hooks.Notification[0].hooks[0].command == "~/.claude/hooks/notify.sh"' >/dev/null
  echo "$output" | jq -e '.hooks.Stop[0].hooks[0].command == "~/.claude/hooks/notify.sh"' >/dev/null
  echo "$output" | jq -e '.skipDangerousModePermissionPrompt == true' >/dev/null
}

@test "claude modify_settings: non-hook deep-merge preserves siblings" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"

  # User has manually added an extra plugin in enabledPlugins; our overlay
  # only declares two specific plugins. Deep merge means user's extra survives.
  local live='{
    "enabledPlugins": {
      "user-custom@some-marketplace": true
    },
    "extraKnownMarketplaces": {
      "user-marketplace": {"source": {"source": "github", "repo": "user/m"}}
    }
  }'

  run bash -c "printf '%s' \"\$1\" | sh '$SOURCE_DIR/dot_claude/modify_settings.json'" _ "$live"
  [ "$status" -eq 0 ]

  # Overlay keys enforced.
  echo "$output" | jq -e '.enabledPlugins["claude-hud@claude-hud"] == true' >/dev/null
  echo "$output" | jq -e '.extraKnownMarketplaces["claude-hud"].source.repo == "jarrodwatts/claude-hud"' >/dev/null
  # User's extras preserved (deep merge into objects).
  echo "$output" | jq -e '.enabledPlugins["user-custom@some-marketplace"] == true' >/dev/null
  echo "$output" | jq -e '.extraKnownMarketplaces["user-marketplace"].source.repo == "user/m"' >/dev/null
}
