#!/usr/bin/env bats
# Unit tests for the coding-agent CLI overlay scripts:
#   dot_cursor/modify_cli-config.json.tmpl
#   dot_config/opencode/modify_opencode.json.tmpl
#   dot_codex/modify_config.toml.tmpl
#   dot_claude/modify_settings.json.tmpl
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

# Render dot_claude/modify_settings.json.tmpl at a given `agentSounds` tier and
# echo the path to the runnable script. The tier is a real prompt value
# (none|notify|peon|both) — see docs/tools/agent-sounds.md. Most tests use
# `notify` because that's the default and the tier the pre-peon assertions were
# written against.
_claude_overlay() {
  local tier="${1:-notify}" out="$RENDER_DIR/claude-$1.sh"
  _render_with_data "$SOURCE_DIR/dot_claude/modify_settings.json.tmpl" \
    "$out" "{\"agentSounds\":\"$tier\"}"
  printf '%s' "$out"
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
  echo "$output" | yq -p toml -e '.tui.status_line | join("|") == "model-with-reasoning|fast-mode|git-branch|context-remaining|task-progress|current-dir"' >/dev/null
  echo "$output" | yq -p toml -e '.tui.status_line | contains(["five-hour-limit"]) | not' >/dev/null
  echo "$output" | yq -p toml -e '.tui.status_line | contains(["weekly-limit"]) | not' >/dev/null
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
  echo "$output" | yq -p toml -e '.tui.status_line[0] == "model-with-reasoning"' >/dev/null
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

@test "codex modify_config.toml: peon-ping [[hooks.*]] arrays-of-tables round-trip" {
  _have_chezmoi || skip "chezmoi not installed"
  command -v yq >/dev/null 2>&1 || skip "yq not installed"
  yq --version 2>&1 | grep -qi 'mikefarah' || skip "wrong yq variant"

  local script="$RENDER_DIR/codex-aot.sh"
  _render "$SOURCE_DIR/dot_codex/modify_config.toml.tmpl" "$script"

  # peon-ping's Codex adapter (hooks/peon-ping/scripts/codex-config.py) writes
  # [[hooks.<Event>]] / [[hooks.<Event>.hooks]] blocks into this file, and Codex
  # itself writes a plain [hooks.state."<path>:<event>:0:0"] sibling. The
  # emitter used to assume "no arrays-of-tables" and died with
  # `TypeError: unsupported scalar type for TOML emit: dict`, failing the whole
  # apply. Also covers an empty array and a mixed array (neither has a [[…]]
  # spelling — both must stay inline).
  local live='[hooks.state."/home/me/.codex/hooks.json:session_start:0:0"]
trusted_hash = "sha256:deadbeef"

[[hooks.SessionStart]]
matcher = "startup|resume|clear"

[[hooks.SessionStart.hooks]]
type = "command"
command = "bash /home/me/.openpeon/hooks/peon-ping/adapters/codex.sh"
timeout = 30

[[hooks.Stop]]

[[hooks.Stop.hooks]]
type = "command"
command = "bash /home/me/.openpeon/hooks/peon-ping/adapters/codex.sh"
timeout = 30

[weird]
empty_list = []
mixed = [1, { a = 2 }]
'

  run bash -c "printf '%s' \"\$1\" | '$script'" _ "$live"
  [ "$status" -eq 0 ]

  echo "$output" | yq -p toml -e '.hooks.SessionStart | length == 1' >/dev/null
  echo "$output" | yq -p toml -e '.hooks.SessionStart[0].matcher == "startup|resume|clear"' >/dev/null
  echo "$output" | yq -p toml -e '.hooks.SessionStart[0].hooks[0].type == "command"' >/dev/null
  echo "$output" | yq -p toml -e '.hooks.SessionStart[0].hooks[0].timeout == 30' >/dev/null
  echo "$output" | yq -p toml -e '.hooks.SessionStart[0].hooks[0].command | test("adapters/codex.sh")' >/dev/null
  # Matcher-less event survives as a one-element array with only .hooks.
  echo "$output" | yq -p toml -e '.hooks.Stop | length == 1' >/dev/null
  echo "$output" | yq -p toml -e '.hooks.Stop[0] | has("matcher") | not' >/dev/null
  echo "$output" | yq -p toml -e '.hooks.Stop[0].hooks[0].timeout == 30' >/dev/null
  # Codex's own [hooks.state] table is a plain sibling of the arrays.
  echo "$output" | yq -p toml -e '.hooks.state["/home/me/.codex/hooks.json:session_start:0:0"].trusted_hash == "sha256:deadbeef"' >/dev/null
  # Lists with no [[…]] spelling stay inline.
  echo "$output" | yq -p toml -e '.weird.empty_list | length == 0' >/dev/null
  echo "$output" | yq -p toml -e '.weird.mixed[0] == 1' >/dev/null
  echo "$output" | yq -p toml -e '.weird.mixed[1].a == 2' >/dev/null
  # Overlay still applied alongside all of the above.
  echo "$output" | yq -p toml -e '.personality == "pragmatic"' >/dev/null

  # Byte-identical on re-application: chezmoi runs this on every apply, so a
  # non-idempotent emitter would show a permanent diff.
  local pass1 pass2
  pass1=$(printf '%s' "$live" | "$script")
  pass2=$(printf '%s' "$pass1" | "$script")
  [ "$pass1" = "$pass2" ]
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
  _have_chezmoi || skip "chezmoi not installed"

  # Live file mimics a fresh install where CodeIsland has already injected
  # its entries but our notify.sh hook is missing.
  local live='{
    "model": "sonnet",
    "permissions": {"defaultMode": "acceptEdits"},
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

  run bash -c "printf '%s' \"\$1\" | sh '$(_claude_overlay notify)'" _ "$live"
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
  # `permissions.defaultMode` is enforced by overlay → live "acceptEdits" loses to overlay "auto".
  echo "$output" | jq -e '.permissions.defaultMode == "auto"' >/dev/null
  echo "$output" | jq -e '.skipDangerousModePermissionPrompt == true' >/dev/null
  echo "$output" | jq -e '.enabledPlugins["claude-hud@claude-hud"] == false' >/dev/null
}

@test "claude modify_settings: idempotent when notify.sh already present" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _have_chezmoi || skip "chezmoi not installed"

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
  local _ov; _ov="$(_claude_overlay notify)"
  pass1=$(printf '%s' "$live" | sh "$_ov")
  # Second pass on the result of the first.
  pass2=$(printf '%s' "$pass1" | sh "$_ov")

  # No duplicate notify.sh entry on first pass.
  printf '%s' "$pass1" | jq -e '[.hooks.Notification[] | select(.hooks[0].command == "~/.claude/hooks/notify.sh")] | length == 1' >/dev/null
  printf '%s' "$pass1" | jq -e '[.hooks.Stop[] | select(.hooks[0].command == "~/.claude/hooks/notify.sh")] | length == 1' >/dev/null

  # Stable across re-application.
  diff <(printf '%s' "$pass1" | jq -S .) <(printf '%s' "$pass2" | jq -S .)
}

@test "claude modify_settings: empty live file produces overlay-only output" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _have_chezmoi || skip "chezmoi not installed"

  run bash -c "printf '' | sh '$(_claude_overlay notify)'"
  [ "$status" -eq 0 ]

  echo "$output" | jq -e '.hooks.Notification[0].hooks[0].command == "~/.claude/hooks/notify.sh"' >/dev/null
  echo "$output" | jq -e '.hooks.Stop[0].hooks[0].command == "~/.claude/hooks/notify.sh"' >/dev/null
  echo "$output" | jq -e '.skipDangerousModePermissionPrompt == true' >/dev/null
}

@test "claude modify_settings: non-hook deep-merge preserves siblings" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _have_chezmoi || skip "chezmoi not installed"

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

  run bash -c "printf '%s' \"\$1\" | sh '$(_claude_overlay notify)'" _ "$live"
  [ "$status" -eq 0 ]

  # Overlay keys enforced.
  echo "$output" | jq -e '.enabledPlugins["claude-hud@claude-hud"] == false' >/dev/null
  echo "$output" | jq -e '.extraKnownMarketplaces["claude-hud"].source.repo == "jarrodwatts/claude-hud"' >/dev/null
  # User's extras preserved (deep merge into objects).
  echo "$output" | jq -e '.enabledPlugins["user-custom@some-marketplace"] == true' >/dev/null
  echo "$output" | jq -e '.extraKnownMarketplaces["user-marketplace"].source.repo == "user/m"' >/dev/null
}

# -----------------------------------------------------------------------------
# agentSounds tiers (none|notify|peon|both) — see docs/tools/agent-sounds.md.
# The prompt gates ONLY hook wiring; workmux entries are unconditional. Guards
# against the silent regression where a tier stops emitting (or starts leaking)
# a feedback mechanism.
# -----------------------------------------------------------------------------

@test "claude modify_settings: agentSounds tiers gate notify.sh and peon-ping independently" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _have_chezmoi || skip "chezmoi not installed"

  local tier out n p w
  # tier -> expected notify.sh / peon.sh / workmux command counts
  for tier in "none 0 0 4" "notify 2 0 4" "peon 0 9 4" "both 2 9 4"; do
    set -- $tier
    out=$(printf '' | sh "$(_claude_overlay "$1")")
    n=$(printf '%s' "$out" | jq '[.hooks[][].hooks[0].command | select(test("notify\\.sh"))] | length')
    p=$(printf '%s' "$out" | jq '[.hooks[][].hooks[0].command | select(test("peon\\.sh"))] | length')
    w=$(printf '%s' "$out" | jq '[.hooks[][].hooks[0].command | select(test("workmux"))] | length')
    [ "$n" -eq "$2" ] || { echo "tier=$1 notify.sh: got $n want $2"; return 1; }
    [ "$p" -eq "$3" ] || { echo "tier=$1 peon.sh: got $p want $3"; return 1; }
    [ "$w" -eq "$4" ] || { echo "tier=$1 workmux: got $w want $4"; return 1; }
  done
}

@test "claude modify_settings: peon tier keeps its hook guarded and preserves foreign entries" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _have_chezmoi || skip "chezmoi not installed"

  # herdr installs its own SessionStart hook at runtime; peon also wants
  # SessionStart. Both must coexist.
  local live='{
    "hooks": {
      "SessionStart": [
        {"hooks": [{"type": "command", "command": "bash ~/.claude/hooks/herdr-agent-state.sh session"}]}
      ]
    }
  }'

  run bash -c "printf '%s' \"\$1\" | sh '$(_claude_overlay peon)'" _ "$live"
  [ "$status" -eq 0 ]

  # herdr survived, peon appended alongside it.
  echo "$output" | jq -e '.hooks.SessionStart | length == 2' >/dev/null
  echo "$output" | jq -e '.hooks.SessionStart | map(.hooks[0].command) | any(. | test("herdr-agent-state"))' >/dev/null
  echo "$output" | jq -e '.hooks.SessionStart | map(.hooks[0].command) | any(. | test("peon\\.sh"))' >/dev/null
  # The guard is mandatory: the hook must no-op on a box without peon-ping
  # installed, exactly like the `command -v workmux` guard.
  echo "$output" | jq -e '.hooks.Stop | map(.hooks[0].command) | any(. | test("\\[ -x .* \\] &&.*peon\\.sh.*\\|\\| true"))' >/dev/null
  # PostToolUseFailure is the one peon event with a non-empty matcher.
  echo "$output" | jq -e '.hooks.PostToolUseFailure[0].matcher == "Bash"' >/dev/null
}

@test "claude modify_settings: lowering the tier prunes OUR entries but never foreign ones" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _have_chezmoi || skip "chezmoi not installed"

  # A machine that previously ran at `both`: notify.sh and peon are already
  # wired, alongside foreign CodeIsland / herdr entries. Dropping to `none`
  # must silence ours and leave theirs untouched — the additive merger alone
  # would leave both of ours wired forever (one-way ratchet).
  local live='{
    "hooks": {
      "Stop": [
        {"hooks": [{"type": "command", "command": "~/.codeisland/codeisland-hook.sh"}]},
        {"hooks": [{"type": "command", "command": "~/.claude/hooks/notify.sh"}]},
        {"hooks": [{"type": "command", "command": "[ -x \"$HOME/.claude/hooks/peon-ping/peon.sh\" ] && \"$HOME/.claude/hooks/peon-ping/peon.sh\" || true"}]}
      ],
      "SessionStart": [
        {"hooks": [{"type": "command", "command": "bash ~/.claude/hooks/herdr-agent-state.sh session"}]}
      ]
    }
  }'

  run bash -c "printf '%s' \"\$1\" | sh '$(_claude_overlay none)'" _ "$live"
  [ "$status" -eq 0 ]

  # Ours: gone.
  echo "$output" | jq -e '[.hooks[][].hooks[0].command | select(test("notify\\.sh"))] | length == 0' >/dev/null
  echo "$output" | jq -e '[.hooks[][].hooks[0].command | select(test("peon\\.sh"))] | length == 0' >/dev/null
  # Theirs: untouched.
  echo "$output" | jq -e '[.hooks.Stop[].hooks[0].command | select(test("codeisland"))] | length == 1' >/dev/null
  echo "$output" | jq -e '[.hooks.SessionStart[].hooks[0].command | select(test("herdr"))] | length == 1' >/dev/null
  # workmux is unconditional and must still be enforced at `none`.
  echo "$output" | jq -e '[.hooks[][].hooks[0].command | select(test("workmux"))] | length == 4' >/dev/null
  # No empty event arrays left behind.
  echo "$output" | jq -e '[.hooks[] | select(length == 0)] | length == 0' >/dev/null
}
