#!/usr/bin/env bats

load "../test_helper.bash"

X_BIN="$REPO_ROOT/dot_dotfiles/bin/executable_x"

setup() {
  setup_path_stub
  X_TMP="$(mktemp -d "${TMPDIR:-/tmp}/x-cli.XXXXXX")"
  export X_TMP
}

teardown() {
  [ -n "${X_TMP:-}" ] && [ -d "$X_TMP" ] && rm -rf "$X_TMP"
  cleanup_path_stubs
}

_stub_uname() {
  local value="$1"
  cat > "$BATS_STUB_DIR/uname" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$value"
EOF
  chmod +x "$BATS_STUB_DIR/uname"
}

@test "copy FILE keeps copying file contents" {
  cat > "$BATS_STUB_DIR/pbcopy" <<'EOF'
#!/usr/bin/env bash
cat > "$X_TMP/pbcopy.input"
EOF
  chmod +x "$BATS_STUB_DIR/pbcopy"

  printf 'file contents\n' > "$X_TMP/source.txt"

  run "$X_BIN" copy "$X_TMP/source.txt"
  [ "$status" -eq 0 ]
  [ "$(cat "$X_TMP/pbcopy.input")" = "file contents" ]
}

@test "copy-file on macOS passes file paths to osascript" {
  _stub_uname "Darwin"
  cat > "$BATS_STUB_DIR/osascript" <<'EOF'
#!/usr/bin/env bash
script="$1"
shift
printf '%s\n' "$script" > "$X_TMP/osascript.script_arg"
printf '%s\n' "$@" > "$X_TMP/osascript.args"
cat > "$X_TMP/osascript.stdin"
EOF
  chmod +x "$BATS_STUB_DIR/osascript"

  mkdir -p "$X_TMP/folder"
  printf 'payload' > "$X_TMP/file.txt"

  run "$X_BIN" copy-file "$X_TMP/file.txt" "$X_TMP/folder"
  [ "$status" -eq 0 ]
  [ "$(cat "$X_TMP/osascript.script_arg")" = "-" ]
  grep -F 'set the clipboard to fileList' "$X_TMP/osascript.stdin" >/dev/null
  grep -Fx "$X_TMP/file.txt" "$X_TMP/osascript.args" >/dev/null
  grep -Fx "$X_TMP/folder" "$X_TMP/osascript.args" >/dev/null
}

@test "copy-file on Wayland writes GNOME file-copy MIME payload" {
  _stub_uname "Linux"
  cat > "$BATS_STUB_DIR/wl-copy" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$X_TMP/wl-copy.args"
cat > "$X_TMP/wl-copy.input"
EOF
  chmod +x "$BATS_STUB_DIR/wl-copy"

  printf 'payload' > "$X_TMP/report space.txt"

  run env WAYLAND_DISPLAY=wayland-1 "$X_BIN" copy-file "$X_TMP/report space.txt"
  [ "$status" -eq 0 ]
  [ "$(cat "$X_TMP/wl-copy.args")" = "--type x-special/gnome-copied-files" ]
  [ "$(sed -n '1p' "$X_TMP/wl-copy.input")" = "copy" ]
  grep -F 'report%20space.txt' "$X_TMP/wl-copy.input" >/dev/null
}

@test "copy-file on X11 falls back to xclip with GNOME file-copy target" {
  _stub_uname "Linux"
  cat > "$BATS_STUB_DIR/xclip" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$X_TMP/xclip.args"
cat > "$X_TMP/xclip.input"
EOF
  chmod +x "$BATS_STUB_DIR/xclip"

  printf 'payload' > "$X_TMP/report.txt"

  run env DISPLAY=:0 "$X_BIN" copy-file "$X_TMP/report.txt"
  [ "$status" -eq 0 ]
  [ "$(cat "$X_TMP/xclip.args")" = "-selection clipboard -target x-special/gnome-copied-files" ]
  [ "$(sed -n '1p' "$X_TMP/xclip.input")" = "copy" ]
  grep -F 'report.txt' "$X_TMP/xclip.input" >/dev/null
}

@test "copy-file refuses private key material unless forced" {
  _stub_uname "Darwin"
  cat > "$BATS_STUB_DIR/osascript" <<'EOF'
#!/usr/bin/env bash
cat > "$X_TMP/osascript.stdin"
EOF
  chmod +x "$BATS_STUB_DIR/osascript"

  printf '%s%s%s\n' '-----BEGIN OPENSSH ' 'PRIVATE' ' KEY-----' > "$X_TMP/id_ed25519"

  run "$X_BIN" copy-file "$X_TMP/id_ed25519"
  [ "$status" -eq 3 ]
  [[ "$output" == *"refusing to copy sensitive key material"* ]]

  run "$X_BIN" copy-file --force "$X_TMP/id_ed25519"
  [ "$status" -eq 0 ]
}

@test "copy-file fails clearly without a local desktop file backend" {
  _stub_uname "Linux"
  printf 'payload' > "$X_TMP/report.txt"

  run env -u DISPLAY -u WAYLAND_DISPLAY "$X_BIN" copy-file "$X_TMP/report.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no file clipboard backend found"* ]]
}

@test "copy-file requires at least one path" {
  run "$X_BIN" copy-file
  [ "$status" -eq 2 ]
  [[ "$output" == *"copy-file: expected at least one PATH"* ]]
}
