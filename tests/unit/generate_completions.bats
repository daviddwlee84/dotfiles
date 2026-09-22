#!/usr/bin/env bats

load "../test_helper.bash"
bats_require_minimum_version 1.5.0

setup() {
  FIXTURE="$BATS_TEST_TMPDIR/completions"
  GENERATOR="$REPO_ROOT/scripts/generate_completions.sh"
  BASH_BIN="$(command -v bash)"
  mkdir -p "$FIXTURE/bin" "$FIXTURE/home/.zfunc" "$FIXTURE/data/bash-completion/completions"
  # Isolate the inventory: no installed tools should run in this test.
  local cmd
  for cmd in dirname mkdir mv rm; do
    ln -s "$(command -v "$cmd")" "$FIXTURE/bin/$cmd"
  done
}

generate() {
  run --separate-stderr env HOME="$FIXTURE/home" XDG_DATA_HOME="$FIXTURE/data" \
    PATH="$FIXTURE/bin" NO_COLOR=1 CLICOLOR_FORCE=0 \
    "$BASH_BIN" "$GENERATOR" "$@"
}

@test "SIGKILL names the tool and both shells in quiet mode and preserves caches" {
  cat >"$FIXTURE/bin/lazyclash" <<'SH'
#!/bin/sh
printf 'partial completion\n'
kill -KILL $$
SH
  chmod +x "$FIXTURE/bin/lazyclash"
  printf 'old zsh\n' >"$FIXTURE/home/.zfunc/_lazyclash"
  printf 'old bash\n' >"$FIXTURE/data/bash-completion/completions/lazyclash"

  generate --tool lazyclash --force --quiet
  [ "$status" -eq 1 ]
  [[ "$output" == *"lazyclash (zsh) failed: exit 137 (SIGKILL)"* ]]
  [[ "$output" == *"lazyclash (bash) failed: exit 137 (SIGKILL)"* ]]
  [[ "$stderr" != *"Killed"* ]]
  [ "$(cat "$FIXTURE/home/.zfunc/_lazyclash")" = 'old zsh' ]
  [ "$(cat "$FIXTURE/data/bash-completion/completions/lazyclash")" = 'old bash' ]
  [ ! -e "$FIXTURE/home/.zfunc/_lazyclash.tmp" ]
  [ ! -e "$FIXTURE/data/bash-completion/completions/lazyclash.tmp" ]
}

@test "quiet full run reports exit and empty-output failures and continues to later tools" {
  cat >"$FIXTURE/bin/uv" <<'SH'
#!/bin/sh
case "$2" in
  zsh) printf 'partial completion\n'; exit 42 ;;
  bash) exit 0 ;;
esac
SH
  cat >"$FIXTURE/bin/lazyclash" <<'SH'
#!/bin/sh
printf '# valid %s completion\n' "$2"
SH
  chmod +x "$FIXTURE/bin/uv" "$FIXTURE/bin/lazyclash"

  generate --quiet
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [[ "$output" == *"uv (zsh) failed: exit 42"* ]]
  [[ "$output" == *"uv (bash) failed: empty output"* ]]
  [[ "$output" == *"regenerated 1 zsh + 1 bash"* ]]
  [[ "$output" == *"2 failed"* ]]
  [ ! -e "$FIXTURE/home/.zfunc/_uv" ]
  [ ! -e "$FIXTURE/data/bash-completion/completions/uv" ]
  [ -s "$FIXTURE/home/.zfunc/_lazyclash" ]
  [ -s "$FIXTURE/data/bash-completion/completions/lazyclash" ]

  # Failures must still produce a summary when nothing was regenerated.
  generate --quiet
  [ "$status" -eq 0 ]
  [[ "$output" == *"regenerated 0 zsh + 0 bash"* ]]
  [[ "$output" == *"2 failed"* ]]
}

@test "quiet cached success stays silent" {
  cat >"$FIXTURE/bin/lazyclash" <<'SH'
#!/bin/sh
printf '# valid %s completion\n' "$2"
SH
  chmod +x "$FIXTURE/bin/lazyclash"
  generate --tool lazyclash --quiet
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 failed"* ]]
  generate --tool lazyclash --quiet
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}
