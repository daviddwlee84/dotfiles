#!/usr/bin/env bats
# Offline black-box tests for dot_config/herdr/executable_edit-config.sh.

load "../test_helper.bash"

# Expected-status flags on `run` need bats >= 1.5.
bats_require_minimum_version 1.5.0

HELPER="$REPO_ROOT/dot_config/herdr/executable_edit-config.sh"
CONFIG="$REPO_ROOT/.chezmoitemplates/herdr/config.toml"

setup() {
  setup_path_stub

  TEST_HOME="$BATS_STUB_DIR/home dir"
  TARGET="$TEST_HOME/.config/herdr/config.toml"
  CALL_LOG="$BATS_STUB_DIR/calls.log"
  ORIGINAL_FILE="$BATS_STUB_DIR/original config"
  EDITED_FILE="$BATS_STUB_DIR/edited config"
  INVALID_FILE="$BATS_STUB_DIR/invalid config"
  EDITOR_PATH="$BATS_STUB_DIR/editor wrappers/blocking editor"
  CHEZMOI_CALLED="$BATS_STUB_DIR/chezmoi-called"
  mkdir -p "$(dirname "$TARGET")" "$(dirname "$EDITOR_PATH")"
  printf '%s\n' 'original = true' >"$ORIGINAL_FILE"
  printf '%s\n' 'edited = true' >"$EDITED_FILE"
  printf '%s\n' 'invalid = [' >"$INVALID_FILE"
  cp "$ORIGINAL_FILE" "$TARGET"
  chmod 640 "$TARGET"
  : >"$CALL_LOG"

  export TEST_HOME TARGET CALL_LOG ORIGINAL_FILE EDITED_FILE INVALID_FILE
  export EDITOR_PATH CHEZMOI_CALLED
  export HOME="$TEST_HOME"
  export HERDR_SOCKET_PATH="$BATS_STUB_DIR/current session.sock"
  export EXPECTED_TARGET="$TARGET"
  export EDITOR_WRITE_FILE="$EDITED_FILE"
  unset HERDR_CONFIG_PATH

  _install_editor_stub "$EDITOR_PATH"
  ln -s "$EDITOR_PATH" "$BATS_STUB_DIR/vi"
  _install_herdr_stub
  _install_chezmoi_tripwire
  _install_failure_stubs
}

teardown() {
  [ ! -e "$CHEZMOI_CALLED" ]
  PATH=${PATH#"$BATS_STUB_DIR:"}
  export PATH
  hash -r
  cleanup_path_stubs
}

_install_editor_stub() {
  local path=$1
  cat >"$path" <<'EOF'
#!/usr/bin/env sh
[ "$#" -eq 1 ] || exit 97
target=$1
backup=$(find "$(dirname "$target")" -type f -name "$(basename "$target").backup-*" -print -quit)
[ -n "$backup" ] || exit 96
cmp -s "$ORIGINAL_FILE" "$backup" || exit 95
printf 'backup\t%s\n' "$backup" >>"$CALL_LOG"
printf 'editor\t%s\t%s\n' "$0" "$target" >>"$CALL_LOG"
/bin/cp "$EDITOR_WRITE_FILE" "$target" || exit 94
chmod "${EDITOR_TARGET_MODE:-666}" "$target" || exit 93
if [ "${FAIL_PHASE:-}" = editor ]; then
  printf '%s\n' 'editor stub failed' >&2
  exit 42
fi
EOF
  chmod +x "$path"
}

_install_herdr_stub() {
  cat >"$BATS_STUB_DIR/herdr" <<'EOF'
#!/usr/bin/env sh
if [ "${1-}" = config ] && [ "${2-}" = check ] && [ "$#" -eq 2 ]; then
  printf 'check\t%s\n' "${HERDR_CONFIG_PATH-<unset>}" >>"$CALL_LOG"
  [ "${HERDR_CONFIG_PATH-}" = "$EXPECTED_TARGET" ] || exit 97
  [ -f "$HERDR_CONFIG_PATH" ] || exit 97
  if [ "${FAIL_PHASE:-}" = validate ]; then
    printf '%s\n' 'validation stub failed' >&2
    exit 44
  fi
  cmp -s "$EDITED_FILE" "$HERDR_CONFIG_PATH" || exit 97
  exit 0
fi

if [ "${1-}" = server ] && [ "${2-}" = reload-config ] && [ "$#" -eq 2 ]; then
  printf 'reload\t%s\t%s\n' "${HERDR_CONFIG_PATH-<unset>}" "${HERDR_SOCKET_PATH-<unset>}" >>"$CALL_LOG"
  if [ "${FAIL_PHASE:-}" = reload ]; then
    printf '%s\n' 'reload stub failed' >&2
    exit 46
  fi
  exit 0
fi

printf 'unexpected herdr call: %s\n' "$*" >&2
exit 98
EOF
  chmod +x "$BATS_STUB_DIR/herdr"
}

_install_chezmoi_tripwire() {
  cat >"$BATS_STUB_DIR/chezmoi" <<'EOF'
#!/usr/bin/env sh
: >"$CHEZMOI_CALLED"
printf 'forbidden chezmoi call: %s\n' "$*" >&2
exit 99
EOF
  chmod +x "$BATS_STUB_DIR/chezmoi"
}

_install_failure_stubs() {
  cat >"$BATS_STUB_DIR/mktemp" <<'EOF'
#!/usr/bin/env sh
case "${1-}" in
  *.backup-XXXXXX)
    if [ "${FAIL_PHASE:-}" = backup ]; then
      printf '%s\n' 'backup stub failed' >&2
      exit 41
    fi
    ;;
esac
exec /usr/bin/mktemp "$@"
EOF

  cat >"$BATS_STUB_DIR/mv" <<'EOF'
#!/usr/bin/env sh
if [ "${FAIL_PHASE:-}" = rollback ] && [ "${1-}" = -f ]; then
  case "${2-}" in
    *.backup-*)
      printf '%s\n' 'rollback stub failed' >&2
      exit 47
      ;;
  esac
fi
exec /bin/mv "$@"
EOF

  cat >"$BATS_STUB_DIR/rm" <<'EOF'
#!/usr/bin/env sh
if [ "${FAIL_PHASE:-}" = cleanup ]; then
  for arg in "$@"; do
    case "$arg" in
      *.backup-*)
        printf '%s\n' 'cleanup stub failed' >&2
        exit 48
        ;;
    esac
  done
fi
exec /bin/rm "$@"
EOF
  chmod +x "$BATS_STUB_DIR/mktemp" "$BATS_STUB_DIR/mv" "$BATS_STUB_DIR/rm"
}

run_edit() {
  local editor_value=$1
  shift
  run env EDITOR="$editor_value" "$@" sh "$HELPER" </dev/null
}

file_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

artifact_path() {
  local suffix=$1
  find "$(dirname "$EXPECTED_TARGET")" -type f -name "$(basename "$EXPECTED_TARGET").$suffix-*" -print -quit
}

assert_operations() {
  local expected=$1
  local actual
  actual=$(cut -f1 "$CALL_LOG")
  if [ "$actual" != "$expected" ]; then
    printf 'expected operations:\n%s\nactual operations:\n%s\n' "$expected" "$actual" >&2
    return 1
  fi
}

@test "edit-config: default target is backed up, edited, checked, reloaded, and cleaned in order" {
  run_edit ""

  [ "$status" -eq 0 ]
  assert_operations $'backup\neditor\ncheck\nreload'
  grep -Fx $'editor\t'"$BATS_STUB_DIR/vi"$'\t'"$TARGET" "$CALL_LOG"
  grep -Fx $'check\t'"$TARGET" "$CALL_LOG"
  grep -Fx $'reload\t<unset>\t'"$HERDR_SOCKET_PATH" "$CALL_LOG"
  cmp -s "$EDITED_FILE" "$TARGET"
  [ "$(file_mode "$TARGET")" = 640 ]
  [ -z "$(artifact_path backup)" ]
  [ -z "$(artifact_path invalid)" ]
}

@test "edit-config: custom target and editor paths containing spaces remain exact single arguments" {
  local custom="$BATS_STUB_DIR/custom configs/herdr config.toml"
  mkdir -p "$(dirname "$custom")"
  cp "$ORIGINAL_FILE" "$custom"
  chmod 600 "$custom"
  export EXPECTED_TARGET="$custom"

  run_edit "$EDITOR_PATH" HERDR_CONFIG_PATH="$custom"

  [ "$status" -eq 0 ]
  grep -Fx $'editor\t'"$EDITOR_PATH"$'\t'"$custom" "$CALL_LOG"
  grep -Fx $'check\t'"$custom" "$CALL_LOG"
  grep -Fx $'reload\t'"$custom"$'\t'"$HERDR_SOCKET_PATH" "$CALL_LOG"
  cmp -s "$EDITED_FILE" "$custom"
  [ "$(file_mode "$custom")" = 600 ]
  [ -z "$(artifact_path backup)" ]
}

@test "edit-config: empty HERDR_CONFIG_PATH selects the default target" {
  run_edit "$EDITOR_PATH" HERDR_CONFIG_PATH=

  [ "$status" -eq 0 ]
  grep -Fx $'editor\t'"$EDITOR_PATH"$'\t'"$TARGET" "$CALL_LOG"
  grep -Fx $'check\t'"$TARGET" "$CALL_LOG"
  grep -Fx $'reload\t\t'"$HERDR_SOCKET_PATH" "$CALL_LOG"
}

@test "edit-config: editor failure preserves candidate and atomically restores bytes and mode without reload" {
  export EDITOR_WRITE_FILE="$INVALID_FILE"

  run_edit "$EDITOR_PATH" FAIL_PHASE=editor

  [ "$status" -eq 42 ]
  assert_operations $'backup\neditor'
  cmp -s "$ORIGINAL_FILE" "$TARGET"
  [ "$(file_mode "$TARGET")" = 640 ]
  local candidate
  candidate=$(artifact_path invalid)
  [ -n "$candidate" ]
  cmp -s "$INVALID_FILE" "$candidate"
  [ "$(file_mode "$candidate")" = 600 ]
  [ -z "$(artifact_path backup)" ]
  [[ "$output" == *"restored target: $TARGET"* ]]
  [[ "$output" == *"rejected candidate retained: $candidate"* ]]
}

@test "edit-config: validation failure preserves candidate and restores original metadata without reload" {
  run_edit "$EDITOR_PATH" FAIL_PHASE=validate

  [ "$status" -eq 44 ]
  assert_operations $'backup\neditor\ncheck'
  cmp -s "$ORIGINAL_FILE" "$TARGET"
  [ "$(file_mode "$TARGET")" = 640 ]
  local candidate
  candidate=$(artifact_path invalid)
  cmp -s "$EDITED_FILE" "$candidate"
  [ "$(file_mode "$candidate")" = 600 ]
  [ -z "$(artifact_path backup)" ]
}

@test "edit-config: reload failure retains the validated edit and metadata-preserving backup" {
  run_edit "$EDITOR_PATH" FAIL_PHASE=reload

  [ "$status" -eq 46 ]
  assert_operations $'backup\neditor\ncheck\nreload'
  cmp -s "$EDITED_FILE" "$TARGET"
  [ "$(file_mode "$TARGET")" = 640 ]
  local backup
  backup=$(artifact_path backup)
  [ -n "$backup" ]
  cmp -s "$ORIGINAL_FILE" "$backup"
  [ "$(file_mode "$backup")" = 640 ]
  [[ "$output" == *"valid edited target retained: $TARGET"* ]]
  [[ "$output" == *"original backup retained: $backup"* ]]
}

@test "edit-config: missing target fails before backup and editor" {
  rm "$TARGET"

  run_edit "$EDITOR_PATH"

  [ "$status" -eq 1 ]
  [[ "$output" == *"target config must be an existing regular file: $TARGET"* ]]
  [ ! -s "$CALL_LOG" ]
}

@test "edit-config: symlink target is rejected without changing its referent" {
  local referent="$BATS_STUB_DIR/real config.toml"
  cp "$ORIGINAL_FILE" "$referent"
  rm "$TARGET"
  ln -s "$referent" "$TARGET"

  run_edit "$EDITOR_PATH"

  [ "$status" -eq 1 ]
  [[ "$output" == *"target config must not be a symlink: $TARGET"* ]]
  cmp -s "$ORIGINAL_FILE" "$referent"
  [ ! -s "$CALL_LOG" ]
}

@test "edit-config: EDITOR arguments are rejected instead of evaluated" {
  local marker="$BATS_STUB_DIR/evaluated"
  local code="$BATS_STUB_DIR/code"
  cat >"$code" <<EOF
#!/usr/bin/env sh
touch "$marker"
EOF
  chmod +x "$code"

  run -127 env EDITOR="$code --wait" sh "$HELPER" </dev/null

  [ "$status" -eq 127 ]
  [[ "$output" == *"one blocking executable or wrapper path"* ]]
  [[ "$output" == *"use a wrapper for arguments such as 'code --wait'"* ]]
  [ ! -e "$marker" ]
  [ ! -s "$CALL_LOG" ]
  [ -z "$(artifact_path backup)" ]
}

@test "edit-config: backup creation failure leaves target untouched and never opens editor" {
  run_edit "$EDITOR_PATH" FAIL_PHASE=backup

  [ "$status" -eq 41 ]
  [[ "$output" == *"could not create a same-directory backup"* ]]
  cmp -s "$ORIGINAL_FILE" "$TARGET"
  [ "$(file_mode "$TARGET")" = 640 ]
  [ ! -s "$CALL_LOG" ]
}

@test "edit-config: rollback failure retains target, candidate, and backup paths" {
  export EDITOR_WRITE_FILE="$INVALID_FILE"

  run_edit "$EDITOR_PATH" FAIL_PHASE=rollback

  [ "$status" -eq 47 ]
  assert_operations $'backup\neditor\ncheck'
  cmp -s "$INVALID_FILE" "$TARGET"
  local candidate backup
  candidate=$(artifact_path invalid)
  backup=$(artifact_path backup)
  [ -n "$candidate" ]
  [ -n "$backup" ]
  cmp -s "$INVALID_FILE" "$candidate"
  cmp -s "$ORIGINAL_FILE" "$backup"
  [[ "$output" == *"rollback failed"* ]]
  [[ "$output" == *"$TARGET"* ]]
  [[ "$output" == *"$candidate"* ]]
  [[ "$output" == *"$backup"* ]]
}

@test "edit-config: cleanup failure keeps valid edit and backup after successful reload" {
  run_edit "$EDITOR_PATH" FAIL_PHASE=cleanup

  [ "$status" -eq 48 ]
  assert_operations $'backup\neditor\ncheck\nreload'
  cmp -s "$EDITED_FILE" "$TARGET"
  [ "$(file_mode "$TARGET")" = 640 ]
  local backup
  backup=$(artifact_path backup)
  [ -n "$backup" ]
  cmp -s "$ORIGINAL_FILE" "$backup"
  [[ "$output" == *"reload succeeded but backup cleanup failed"* ]]
  [[ "$output" == *"$TARGET"* ]]
  [[ "$output" == *"$backup"* ]]
}

@test "edit-config: helper contains no dotfile-manager command and never invokes tripwire" {
  ! grep -Eq 'chezmoi[[:space:]]+(source-path|cat|apply|add|re-add)' "$HELPER"

  run_edit "$EDITOR_PATH"

  [ "$status" -eq 0 ]
  [ ! -e "$CHEZMOI_CALLED" ]
}

@test "edit-config: bindings keep Alt-e, lazygit, and the Yazi popup distinct" {
  [ "$(grep -c '^key = "prefix+alt+e"$' "$CONFIG")" -eq 1 ]
  [ "$(grep -c '^key = "prefix+G"$' "$CONFIG")" -eq 1 ]
  [ "$(grep -c '^key = "prefix+Y"$' "$CONFIG")" -eq 1 ]
  [ "$(grep -c '^key = "prefix+alt+g"$' "$CONFIG")" -eq 0 ]

  local alt_e pane_g popup_y
  alt_e=$(grep -A3 -B1 '^key = "prefix+alt+e"$' "$CONFIG")
  pane_g=$(grep -A3 -B1 '^key = "prefix+G"$' "$CONFIG")
  popup_y=$(grep -A6 -B1 '^key = "prefix+Y"$' "$CONFIG")
  [[ "$alt_e" == *$'type = "pane"'* ]]
  [[ "$alt_e" == *$'command = "~/.config/herdr/edit-config.sh"'* ]]
  [[ "$alt_e" == *$'description = "edit runtime config, validate, and reload"'* ]]
  [[ "$pane_g" == *$'type = "pane"'* ]]
  [[ "$pane_g" == *$'command = "lazygit"'* ]]
  [[ "$popup_y" == *$'type = "popup"'* ]]
  [[ "$popup_y" == *$'command = "yazi"'* ]]
  [[ "$popup_y" == *$'width = "90%"'* ]]
  [[ "$popup_y" == *$'height = "85%"'* ]]
}
