#!/usr/bin/env bats
# Offline black-box tests for dot_dotfiles/bin/executable_ytmv + scripts/ytmv/*.py.
#
# Everything here runs without network. The tests that need the real PEP723
# deps (mutagen/tyro) go through `uv`, and skip when it is unavailable; the
# help/dispatch tests run under plain python3 precisely to prove the help path
# never imports yt_dlp or mutagen.

load "../test_helper.bash"

CLI="$REPO_ROOT/dot_dotfiles/bin/executable_ytmv"
ZSH_COMPLETION="$REPO_ROOT/dot_config/zsh/tools/60_ytmv_completion.zsh"
BASH_COMPLETION="$REPO_ROOT/dot_config/bash/60_ytmv_completion.bash"

setup() {
  PYTHON_BIN="$(command -v python3)"
  [ -n "$PYTHON_BIN" ] || skip "python3 is required"
  YTMV_WORK="$(mktemp -d "${TMPDIR:-/tmp}/ytmv-test.XXXXXX")"
  export YTMV_WORK
  # Never let a test touch the real ~/Music or ~/.config.
  export YTMV_OUT="$YTMV_WORK/out"
  export XDG_CONFIG_HOME="$YTMV_WORK/config"
  export XDG_CACHE_HOME="$YTMV_WORK/cache"
}

teardown() {
  [ -n "${YTMV_WORK:-}" ] && [ -d "$YTMV_WORK" ] && rm -rf "$YTMV_WORK"
  cleanup_path_stubs
}

_uv_cli() {
  command -v uv >/dev/null 2>&1 || skip "uv is required for this test"
  run uv run --quiet --script "$CLI" "$@"
}

# --------------------------------------------------------------------------- #
# Dispatch + help (stdlib only — proves the fast path stays import-free)
# --------------------------------------------------------------------------- #

@test "ytmv: --help works under bare python3 (no heavy imports on the help path)" {
  run "$PYTHON_BIN" "$CLI" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: ytmv <subcommand>"* ]]
  [[ "$output" == *"get <URL>"* ]]
  [[ "$output" == *"doctor"* ]]
}

@test "ytmv: bare invocation prints usage and exits 2" {
  run "$PYTHON_BIN" "$CLI"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage: ytmv"* ]]
}

@test "ytmv: unknown subcommand exits 2 and names the offender" {
  run "$PYTHON_BIN" "$CLI" bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown subcommand 'bogus'"* ]]
}

@test "ytmv: help advertises every subcommand the launcher dispatches" {
  run "$PYTHON_BIN" "$CLI" --help
  for sub in get lyrics tag doctor; do
    [[ "$output" == *"$sub"* ]] || {
      echo "subcommand '$sub' missing from --help"; return 1
    }
  done
}

# --------------------------------------------------------------------------- #
# Profiles
# --------------------------------------------------------------------------- #

@test "ytmv doctor --list-profiles: emits the built-in profiles, one per line" {
  _uv_cli doctor --list-profiles
  [ "$status" -eq 0 ]
  for profile in safe cjk-big5 cjk-gbk ipod modern; do
    echo "$output" | grep -qx "$profile" || {
      echo "profile '$profile' missing from --list-profiles"; return 1
    }
  done
}

@test "ytmv doctor: an unknown profile exits 2 and lists the known ones" {
  _uv_cli doctor --profile nope
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown profile 'nope'"* ]]
  [[ "$output" == *"safe"* ]]
}

@test "ytmv doctor --json: reports the resolved profile and the libass probe" {
  _uv_cli doctor --offline --json
  # Exit 1 is legitimate here (a host without libass is a real, expected state).
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  [[ "$output" == *'"profile"'* ]]
  [[ "$output" == *'"id3_version"'* ]]
  [[ "$output" == *"libass"* ]]
}

# --------------------------------------------------------------------------- #
# tag — the offline "try another profile" loop
# --------------------------------------------------------------------------- #

@test "ytmv tag: no paths exits 2 with a usage hint" {
  _uv_cli tag
  [ "$status" -eq 2 ]
  [[ "$output" == *"no files given"* ]]
}

@test "ytmv tag: an unknown profile exits 2" {
  _uv_cli tag "$YTMV_WORK" --profile nope
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown profile"* ]]
}

@test "ytmv tag: --dry-run reports the target encoding and writes nothing" {
  command -v ffmpeg >/dev/null 2>&1 || skip "ffmpeg is required to synthesise an mp3"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "anullsrc=r=44100:cl=stereo" \
    -t 1 -q:a 9 "$YTMV_WORK/demo.mp3"
  local before
  before="$(md5 -q "$YTMV_WORK/demo.mp3" 2>/dev/null || md5sum "$YTMV_WORK/demo.mp3")"
  _uv_cli tag "$YTMV_WORK/demo.mp3" --profile cjk-big5 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"id3v2.3"* ]]
  [[ "$output" == *"cp950"* ]]
  local after
  after="$(md5 -q "$YTMV_WORK/demo.mp3" 2>/dev/null || md5sum "$YTMV_WORK/demo.mp3")"
  [ "$before" = "$after" ]
}

@test "ytmv tag: ID3 version follows the profile (v2.3 for safe, v2.4 for modern)" {
  command -v ffmpeg >/dev/null 2>&1 || skip "ffmpeg is required to synthesise an mp3"
  command -v uv >/dev/null 2>&1 || skip "uv is required"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "anullsrc=r=44100:cl=stereo" \
    -t 1 -q:a 9 "$YTMV_WORK/demo.mp3"

  run uv run --quiet --script "$CLI" tag "$YTMV_WORK/demo.mp3" --profile safe \
    --artist "Some Artist" --track "Some Title"
  [ "$status" -eq 0 ]
  run uv run --quiet --with "mutagen>=1.47" python3 -c \
    "from mutagen.id3 import ID3; print(ID3('$YTMV_WORK/demo.mp3').version[:2])"
  [[ "$output" == *"(2, 3)"* ]]

  run uv run --quiet --script "$CLI" tag "$YTMV_WORK/demo.mp3" --profile modern
  [ "$status" -eq 0 ]
  run uv run --quiet --with "mutagen>=1.47" python3 -c \
    "from mutagen.id3 import ID3; print(ID3('$YTMV_WORK/demo.mp3').version[:2])"
  [[ "$output" == *"(2, 4)"* ]]
}

@test "ytmv tag: strict mode refuses to silently mangle unencodable lyrics" {
  command -v ffmpeg >/dev/null 2>&1 || skip "ffmpeg is required to synthesise an mp3"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "anullsrc=r=44100:cl=stereo" \
    -t 1 -q:a 9 "$YTMV_WORK/demo.mp3"
  # Kana cannot be represented in cp950 — the guard must fire, not write '?'.
  printf '[00:01.00]\xe6\xb6\x99\n' > "$YTMV_WORK/demo.lrc"

  _uv_cli tag "$YTMV_WORK/demo.mp3" --profile cjk-big5
  [[ "$output" == *"cannot encode"* ]]
  [[ "$output" == *"--lrc-on-unencodable replace"* ]]

  _uv_cli tag "$YTMV_WORK/demo.mp3" --profile cjk-big5 --lrc-on-unencodable replace
  [ "$status" -eq 0 ]
}

# --------------------------------------------------------------------------- #
# get / lyrics argument validation (no network reached)
# --------------------------------------------------------------------------- #

@test "ytmv get: no URLs exits 2 before touching the network" {
  _uv_cli get
  [ "$status" -eq 2 ]
  [[ "$output" == *"no URLs"* ]]
}

@test "ytmv get: an invalid --lyrics value exits 2" {
  _uv_cli get "https://example.invalid/watch?v=x" --lyrics bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"--lyrics must be"* ]]
}

@test "ytmv lyrics: no paths exits 2" {
  _uv_cli lyrics
  [ "$status" -eq 2 ]
  [[ "$output" == *"no files given"* ]]
}

# --------------------------------------------------------------------------- #
# Completions
# --------------------------------------------------------------------------- #

@test "ytmv: both completion files exist and parse" {
  [ -f "$ZSH_COMPLETION" ]
  [ -f "$BASH_COMPLETION" ]
  bash -n "$BASH_COMPLETION"
  if command -v zsh >/dev/null 2>&1; then zsh -n "$ZSH_COMPLETION"; fi
}

@test "ytmv: Bash completion registers even before the managed bin PATH loads" {
  setup_path_stub
  printf '#!/bin/sh\nexit 0\n' > "$BATS_STUB_DIR/ytmv"
  chmod +x "$BATS_STUB_DIR/ytmv"
  run bash -c "source '$BASH_COMPLETION'; complete -p ytmv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"_ytmv_completion"* ]]
}

@test "ytmv: help and both completion files advertise every public option" {
  command -v uv >/dev/null 2>&1 || skip "uv is required to enumerate tyro flags"
  local sub flag missing=0
  for sub in get lyrics tag doctor; do
    for flag in $(uv run --quiet --script "$CLI" "$sub" --help 2>&1 \
                    | grep -oE '\-\-[a-z0-9][a-z0-9-]*' \
                    | sort -u | grep -v '^--no-' | grep -v '^--help$'); do
      grep -qF -- "$flag" "$ZSH_COMPLETION" || {
        echo "zsh completion missing: $sub $flag"; missing=1
      }
      grep -qF -- "$flag" "$BASH_COMPLETION" || {
        echo "bash completion missing: $sub $flag"; missing=1
      }
    done
  done
  [ "$missing" -eq 0 ]
}

@test "ytmv: completion profile candidates come from the CLI, not a stale copy" {
  grep -qF -- "doctor --list-profiles" "$ZSH_COMPLETION"
  grep -qF -- "doctor --list-profiles" "$BASH_COMPLETION"
}
