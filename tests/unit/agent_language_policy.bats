#!/usr/bin/env bats
# Gate + content contract for dot_claude/rules/language-policy.md.tmpl.
#
# The rule must render ONLY when installCodingAgents && agentLanguagePolicy ==
# "zh-TW"; every other combination (including configs written before the
# prompt existed) must render empty so chezmoi removes the target instead of
# erroring on a missing key.

load "../test_helper.bash"

SOURCE_DIR="$REPO_ROOT"
TMPL="$REPO_ROOT/dot_claude/rules/language-policy.md.tmpl"
BODY="$REPO_ROOT/.chezmoitemplates/agent-language-policy.md"

setup() {
  CFG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lang-policy.XXXXXX")"
}

teardown() {
  [ -n "${CFG_DIR:-}" ] && rm -rf "$CFG_DIR"
}

_render() {
  printf '[data]\n%b\n' "$1" >"$CFG_DIR/chezmoi.toml"
  chezmoi execute-template --source "$SOURCE_DIR" --config "$CFG_DIR/chezmoi.toml" <"$TMPL"
}

@test "zh-TW + coding agents renders the shared policy body verbatim" {
  run _render 'installCodingAgents = true\nagentLanguagePolicy = "zh-TW"'
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$BODY")" ]
}

@test "policy none renders empty (chezmoi removes the target)" {
  run _render 'installCodingAgents = true\nagentLanguagePolicy = "none"'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "zh-TW without coding agents renders empty" {
  run _render 'installCodingAgents = false\nagentLanguagePolicy = "zh-TW"'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "config predating the prompt renders empty instead of erroring" {
  run _render 'installCodingAgents = true'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "policy body covers chat, plans, long-lived docs and thinking" {
  grep -q '繁體中文' "$BODY"
  grep -q 'Plan-mode plan files' "$BODY"
  grep -q 'Long-lived artifacts' "$BODY"
  grep -q 'Internal reasoning / thinking' "$BODY"
}

@test "policy body is byte-identical to the Windows repo copy (superproject only)" {
  local win="$REPO_ROOT/../dotfiles-windows/.chezmoitemplates/agent-language-policy.md"
  [ -f "$win" ] || skip "dotfiles-windows sibling not checked out"
  cmp "$BODY" "$win"
}
