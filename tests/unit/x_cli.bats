#!/usr/bin/env bats

load "../test_helper.bash"

X_BIN="$REPO_ROOT/dot_dotfiles/bin/executable_x"

setup() {
  setup_path_stub
  X_TMP="$(mktemp -d "${TMPDIR:-/tmp}/x-cli.XXXXXX")"
  export X_TMP

  # Hermetic backend selection: `x` keys off these to decide OSC 52 vs a local
  # tool (prefer_osc52 / clipboard_forced) and Wayland-vs-X11. Running bats
  # inside herdr, over SSH, or in a graphical session must not change what
  # these tests exercise — each test sets the vars it needs via `env`.
  unset HERDR_ENV ZELLIJ SSH_CONNECTION SSH_TTY SSH_CLIENT X_CLIPBOARD \
    DISPLAY WAYLAND_DISPLAY
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

@test "copy-file on macOS writes file URLs via JXA + NSPasteboard" {
  _stub_uname "Darwin"
  cat > "$BATS_STUB_DIR/osascript" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$X_TMP/osascript.argv"
cat > "$X_TMP/osascript.stdin"
EOF
  chmod +x "$BATS_STUB_DIR/osascript"

  mkdir -p "$X_TMP/folder"
  printf 'payload' > "$X_TMP/file.txt"

  run "$X_BIN" copy-file "$X_TMP/file.txt" "$X_TMP/folder"
  [ "$status" -eq 0 ]
  # invoked as: osascript -l JavaScript - <path>...
  grep -Fx -- '-l' "$X_TMP/osascript.argv" >/dev/null
  grep -Fx -- 'JavaScript' "$X_TMP/osascript.argv" >/dev/null
  grep -Fx -- "$X_TMP/file.txt" "$X_TMP/osascript.argv" >/dev/null
  grep -Fx -- "$X_TMP/folder" "$X_TMP/osascript.argv" >/dev/null
  grep -F 'writeObjects' "$X_TMP/osascript.stdin" >/dev/null
  grep -F 'fileURLWithPath' "$X_TMP/osascript.stdin" >/dev/null
}

@test "X_CLIPBOARD forces a specific backend, bypassing autodetect" {
  _stub_uname "Linux"
  cat > "$BATS_STUB_DIR/pbcopy" <<'EOF'
#!/usr/bin/env bash
echo pbcopy > "$X_TMP/backend"; cat >/dev/null
EOF
  cat > "$BATS_STUB_DIR/xsel" <<'EOF'
#!/usr/bin/env bash
echo "xsel $*" > "$X_TMP/backend"; cat > "$X_TMP/xsel.input"
EOF
  chmod +x "$BATS_STUB_DIR/pbcopy" "$BATS_STUB_DIR/xsel"

  run env X_CLIPBOARD=xsel bash -c 'printf hi | "$1" copy' _ "$X_BIN"
  [ "$status" -eq 0 ]
  [ "$(cat "$X_TMP/backend")" = "xsel --clipboard --input" ]
  [ "$(cat "$X_TMP/xsel.input")" = "hi" ]
}

@test "X_CLIPBOARD rejects an unknown value" {
  run env X_CLIPBOARD=bogus bash -c 'printf hi | "$1" copy' _ "$X_BIN"
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown X_CLIPBOARD='bogus'"* ]]
}

@test "copy-file refuses inside herdr (frozen env — OSC 52 can't carry a file)" {
  _stub_uname "Linux"
  cat > "$BATS_STUB_DIR/wl-copy" <<'EOF'
#!/usr/bin/env bash
echo wl-copy-ran > "$X_TMP/leak"
EOF
  chmod +x "$BATS_STUB_DIR/wl-copy"
  printf 'payload' > "$X_TMP/report.txt"

  run env HERDR_ENV=1 WAYLAND_DISPLAY=wayland-1 "$X_BIN" copy-file "$X_TMP/report.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"can't cross SSH / OSC 52"* ]]
  [ ! -e "$X_TMP/leak" ]
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
