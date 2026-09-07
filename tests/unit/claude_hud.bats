#!/usr/bin/env bats
# Exercise real chezmoi permission/state handling in an isolated destination.
# No installed HUD, network, or writes to the user's Claude directory required.
load "../test_helper.bash"

setup() {
  command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
  command -v python3 >/dev/null 2>&1 || skip "python3 not installed"
  HUD_TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-hud-test.XXXXXX")"
  HUD_SOURCE="$HUD_TEST_ROOT/source"
  HUD_DEST="$HUD_TEST_ROOT/home"
  HUD_TARGET="$HUD_DEST/.claude/plugins/claude-hud"
  mkdir -p "$HUD_SOURCE/dot_claude" "$HUD_DEST"
  cp -R "$REPO_ROOT/dot_claude/plugins" "$HUD_SOURCE/dot_claude/plugins"
  : >"$HUD_TEST_ROOT/config.toml"
}

teardown() {
  [ -z "${HUD_TEST_ROOT:-}" ] || rm -rf "$HUD_TEST_ROOT"
}

_hud_chezmoi() {
  chezmoi --config "$HUD_TEST_ROOT/config.toml" \
    --source "$HUD_SOURCE" --destination "$HUD_DEST" \
    --persistent-state "$HUD_TEST_ROOT/state.boltdb" \
    --cache "$HUD_TEST_ROOT/cache" --no-tty "$@"
}

_hud_cache_write() {
  # Model upstream version.ts: write a cache and tighten its parent to 0700.
  chmod 700 "$HUD_TARGET"
  printf '%s\n' '{"version":"2.1.0"}' >"$HUD_TARGET/.claude-code-version-cache.json"
  chmod 600 "$HUD_TARGET/.claude-code-version-cache.json"
}

_hud_assert_clean() {
  run _hud_chezmoi apply
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run _hud_chezmoi status
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run _hud_chezmoi diff --no-pager
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  python3 - "$HUD_TARGET" <<'PY'
import json
import pathlib
import stat
import sys

target = pathlib.Path(sys.argv[1])
assert stat.S_IMODE(target.stat().st_mode) == 0o700
assert json.loads((target / '.claude-code-version-cache.json').read_text()) == {'version': '2.1.0'}
PY
  cmp "$HUD_SOURCE/dot_claude/plugins/private_claude-hud/config.json" "$HUD_TARGET/config.json"
}

@test "claude HUD: cache writer and repeated apply agree on directory permissions" {
  _hud_chezmoi apply
  _hud_cache_write
  _hud_assert_clean
  _hud_cache_write
  _hud_assert_clean
}

@test "claude HUD: private source migrates old overwrite conflict without deleting caches" {
  mv "$HUD_SOURCE/dot_claude/plugins/private_claude-hud" "$HUD_SOURCE/dot_claude/plugins/claude-hud"
  _hud_chezmoi apply
  _hud_cache_write

  # The old source reproduces a metadata-only conflict (no text diff menu).
  run _hud_chezmoi apply
  [ "$status" -ne 0 ]
  [[ "$output" == *".claude/plugins/claude-hud has changed since chezmoi last wrote it"* ]]

  mv "$HUD_SOURCE/dot_claude/plugins/claude-hud" "$HUD_SOURCE/dot_claude/plugins/private_claude-hud"
  _hud_assert_clean
}
