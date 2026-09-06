#!/usr/bin/env bats

load '../test_helper.bash'

setup_file() { bats_require_minimum_version 1.5.0; }

setup() {
  export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config with 空白"
  BIN="$BATS_TEST_TMPDIR/bin with space"
  mkdir -p "$XDG_CONFIG_HOME/dotfiles" "$BIN"
  cp "$REPO_ROOT/dot_config/dotfiles/editor.sh" "$XDG_CONFIG_HOME/dotfiles/editor.sh"
  cp "$REPO_ROOT/dot_dotfiles/bin/executable_dotfiles-editor" "$BIN/dotfiles-editor"
  cp "$REPO_ROOT/dot_dotfiles/bin/executable_editorcfg" "$BIN/editorcfg"
  chmod +x "$BIN/dotfiles-editor" "$BIN/editorcfg"
  for tool in cat mkdir mktemp mv rm; do ln -s "$(command -v "$tool")" "$BIN/$tool"; done
  export EDITOR_TEST_LOG="$BATS_TEST_TMPDIR/args"
  export EDITOR_TEST_CLOSED="$BATS_TEST_TMPDIR/closed"
  export EDITOR=dotfiles-editor VISUAL=dotfiles-editor
  unset EDITOR_TEST_DELAY EDITOR_TEST_EXIT
}

stub() {
  cp "$REPO_ROOT/tests/fixtures/editor-stub.sh" "$BIN/$1"
  chmod +x "$BIN/$1"
}

cfg() { run env PATH="$BIN" "$BIN/editorcfg" "$@"; }
launch() { run env PATH="$BIN" "$BIN/dotfiles-editor" "$@"; }

@test "legacy default is nvim and malformed preference is not evaluated" {
  stub nvim
  cfg status
  [ "$status" -eq 0 ]
  [[ "$output" == *'Preferred: nvim'* ]]
  printf 'touch bad\n' > "$XDG_CONFIG_HOME/dotfiles/editor-choice"
  launch file
  [ "$status" -eq 2 ]
  [ ! -f "$EDITOR_TEST_LOG" ]
}

@test "use overrides init immediately, reset restores init, missing use preserves preference" {
  stub nvim
  stub micro
  printf 'nvim\n' > "$XDG_CONFIG_HOME/dotfiles/editor-default"
  cfg use micro
  [ "$status" -eq 0 ]
  run -127 env PATH="$BIN" "$BIN/editorcfg" use code
  [ "$status" -eq 127 ]
  [ "$(cat "$XDG_CONFIG_HOME/dotfiles/editor-choice")" = micro ]
  cfg status
  [[ "$output" == *'Preferred: micro'* ]]
  cfg reset
  [ "$status" -eq 0 ]
  [ ! -e "$XDG_CONFIG_HOME/dotfiles/editor-choice" ]
  cfg status
  [[ "$output" == *'Preferred: nvim'* ]]
}

@test "launch preserves filenames and cwd, waits and propagates failure without retry" {
  stub nvim
  stub micro
  export EDITOR_TEST_DELAY=0.1 EDITOR_TEST_EXIT=23
  launch "$BATS_TEST_TMPDIR/中文 with spaces.md" 'apostrophe\file & literal.txt'
  [ "$status" -eq 23 ]
  [ -f "$EDITOR_TEST_CLOSED" ]
  [ "$(wc -l < "$EDITOR_TEST_LOG" | tr -d ' ')" -eq 2 ]
  [ "$(head -1 "$EDITOR_TEST_LOG")" = "$BATS_TEST_TMPDIR/中文 with spaces.md" ]
  [[ "$output" != *'using micro'* ]]
}

@test "GUI presets add wait and disappeared executables fall back at invocation" {
  stub code
  stub micro
  cfg use code
  [ "$status" -eq 0 ]
  launch 'prompt text.md'
  [ "$status" -eq 0 ]
  [ "$(head -1 "$EDITOR_TEST_LOG")" = --wait ]
  rm "$BIN/code"
  launch 'prompt text.md'
  [ "$status" -eq 0 ]
  [[ "$output" == *'code unavailable; using micro'* ]]
}

@test "non-modal preference never falls back to vim or a GUI" {
  printf 'micro\n' > "$XDG_CONFIG_HOME/dotfiles/editor-default"
  stub nvim
  stub code
  run -127 env PATH="$BIN" "$BIN/dotfiles-editor" file
  [ "$status" -eq 127 ]
  [ ! -e "$EDITOR_TEST_LOG" ]
  stub nano
  launch file
  [ "$status" -eq 0 ]
  [[ "$output" == *'using nano'* ]]
}

@test "modal preference can use vi as a last resort" {
  stub vi
  launch file
  [ "$status" -eq 0 ]
  [[ "$output" == *'using vi'* ]]
}

@test "doctor reports environment overrides and missing launcher without executing editors" {
  stub nvim
  run env PATH="$BIN" EDITOR=custom "$BIN/editorcfg" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *'EDITOR: custom'* ]]
  [ ! -e "$EDITOR_TEST_LOG" ]
  rm "$BIN/dotfiles-editor"
  run -127 env PATH="$BIN" "$BIN/editorcfg" doctor
  [ "$status" -eq 127 ]
}

@test "Yazi separates text selection from directory Neovim" {
  run rg 'url = "\*/".*"nvim_dir"' "$REPO_ROOT/dot_config/yazi/yazi.toml"
  [ "$status" -eq 0 ]
  run rg -F '"${EDITOR:-dotfiles-editor}" %s' "$REPO_ROOT/dot_config/yazi/yazi.toml"
  [ "$status" -eq 0 ]
}

@test "privileged text editing passes the user launcher to sudoedit" {
  stub sudoedit
  ln -s "$(command -v env)" "$BIN/env"
  action=$(rg '^exec env SUDO_EDITOR=' "$REPO_ROOT/dot_config/television/cable/disk.toml.tmpl")
  run env PATH="$BIN" /bin/sh -c "$action"
  [ "$status" -eq 0 ]
  [ "$(cat "$EDITOR_TEST_LOG")" = /etc/fstab ]
  [ "$(cat "$EDITOR_TEST_LOG.editor")" = dotfiles-editor ]
}
