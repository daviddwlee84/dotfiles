#!/usr/bin/env bats

load "../test_helper.bash"

setup() {
  LIB="$REPO_ROOT/scripts/lib/herdr_skill.sh"
  LOG="$REPO_ROOT/scripts/lib/log_shared.sh"
  TEST_HOME="$BATS_TEST_TMPDIR/home"
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  DEST="$TEST_HOME/.agents/skills/herdr/SKILL.md"
  mkdir -p "$TEST_HOME" "$STUB_BIN"
}

_write_herdr_stub() {
  local body="$1"
  cat >"$STUB_BIN/herdr" <<EOF
#!/bin/bash
case "\${1:-}" in
  --skill) printf '%s' '$body' ;;
  --version) printf '%s\n' 'herdr 9.9.9-test' ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "$STUB_BIN/herdr"
}

_sync() {
  HOME="$TEST_HOME" PATH="$STUB_BIN:$PATH" bash -c '
    source "$1"
    source "$2"
    sync_herdr_skill "$3"
  ' _ "$LOG" "$LIB" "$DEST"
}

@test "syncs the exact skill emitted by the installed Herdr binary" {
  local skill=$'---\nname: herdr\ndescription: test\n---\n\n# Herdr\n'
  _write_herdr_stub "$skill"

  run _sync
  [ "$status" -eq 0 ]
  [ "$(cat "$DEST")" = "${skill%$'\n'}" ]
}

@test "is idempotent when the emitted skill has not changed" {
  local skill=$'---\nname: herdr\ndescription: test\n---\n'
  _write_herdr_stub "$skill"
  _sync
  local before
  before=$(stat -f '%m' "$DEST" 2>/dev/null || stat -c '%Y' "$DEST")
  sleep 1

  run _sync
  [ "$status" -eq 0 ]
  local after
  after=$(stat -f '%m' "$DEST" 2>/dev/null || stat -c '%Y' "$DEST")
  [ "$before" = "$after" ]
}

@test "invalid output never replaces the previous skill" {
  mkdir -p "$(dirname "$DEST")"
  printf '%s\n' 'previous-good-copy' >"$DEST"
  _write_herdr_stub 'not a skill'

  run _sync
  [ "$status" -ne 0 ]
  [ "$(cat "$DEST")" = 'previous-good-copy' ]
}

@test "global lock merger removes Herdr but preserves unrelated ad-hoc skills" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  local merger="$REPO_ROOT/dot_agents/modify_dot_skill-lock.json.tmpl"
  local live='{"version":3,"skills":{"herdr":{"source":"herdrdev/herdr"},"custom":{"source":"me/custom"}}}'

  run bash -c "printf '%s' \"\$1\" | '$merger'" _ "$live"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.skills | has("herdr") | not' >/dev/null
  echo "$output" | jq -e '.skills.custom.source == "me/custom"' >/dev/null
}

@test "Claude discovery symlink and ignore exception are declared" {
  [ "$(cat "$REPO_ROOT/dot_claude/skills/symlink_herdr")" = '../../.agents/skills/herdr' ]
  grep -qxF '!.claude/skills/herdr' "$REPO_ROOT/.chezmoiignore.tmpl"
}
