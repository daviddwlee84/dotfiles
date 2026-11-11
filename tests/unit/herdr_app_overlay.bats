#!/usr/bin/env bats
# Contract for the Herdr App modify_ overlays (keys.json / settings.json).
#
# Herdr writes both files itself, so the overlays must: leave a missing/empty
# file empty (Herdr then writes its full defaults), deep-merge the managed
# fragment with managed keys winning, preserve everything else, and pass
# invalid JSON through untouched. The fragments and vendored mod are shared
# byte-for-byte with dotfiles-windows.

load "../test_helper.bash"

setup() {
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/herdr-app-overlay.XXXXXX")"
  printf '[data]\n' >"$WORK/chezmoi.toml"
  for kind in keys settings; do
    chezmoi execute-template --source "$REPO_ROOT" --config "$WORK/chezmoi.toml" \
      <"$REPO_ROOT/dot_config/herdr-app/modify_$kind.json.tmpl" >"$WORK/$kind.sh"
  done
}

teardown() {
  [ -n "${WORK:-}" ] && rm -rf "$WORK"
}

@test "empty or whitespace-only live file stays empty" {
  run sh "$WORK/keys.sh" </dev/null
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run sh -c "printf ' \n' | sh '$WORK/settings.sh'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "keys overlay adds tmux-prefix bindings and keeps the rest" {
  command -v jq >/dev/null || skip "jq required"
  run sh -c "printf '%s' '{\"global\":{\"cmd-q\":\"app.quit\",\"ctrl-b\":\"old\"},\"pane\":{\"x\":\"y\"}}' | sh '$WORK/keys.sh'"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.global["cmd-q"]')" = "app.quit" ]
  [ "$(printf '%s' "$output" | jq -r '.global["ctrl-b"]')" = "mod.open:tmux-prefix" ]
  [ "$(printf '%s' "$output" | jq -r '.terminal["ctrl-b"]')" = "mod.open:tmux-prefix" ]
  [ "$(printf '%s' "$output" | jq -r '.["mod:tmux-prefix"]["ctrl-b"]')" = "tmux-prefix.send-prefix" ]
  [ "$(printf '%s' "$output" | jq -r '.pane.x')" = "y" ]
}

@test "settings overlay enforces managed keys and preserves app-owned ones" {
  command -v jq >/dev/null || skip "jq required"
  run sh -c "printf '%s' '{\"zoom\":1.5,\"appearance\":\"light\",\"sounds\":{\"enabled\":false}}' | sh '$WORK/settings.sh'"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.zoom')" = "1.5" ]
  [ "$(printf '%s' "$output" | jq -r '.appearance')" = "dark" ]
  [ "$(printf '%s' "$output" | jq -r '.sounds.enabled')" = "false" ]
}

@test "overlay is idempotent" {
  command -v jq >/dev/null || skip "jq required"
  once="$(printf '{"global":{"a":"b"}}' | sh "$WORK/keys.sh")"
  twice="$(printf '%s' "$once" | sh "$WORK/keys.sh")"
  [ "$once" = "$twice" ]
}

@test "invalid live JSON passes through untouched" {
  command -v jq >/dev/null || skip "jq required"
  run sh -c "printf '{broken' | sh '$WORK/keys.sh'"
  [ "$status" -eq 0 ]
  [ "$output" = "{broken" ]
}
