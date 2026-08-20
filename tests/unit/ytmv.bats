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

_stub_required_runtime() {
  setup_path_stub
  cat > "$BATS_STUB_DIR/ffmpeg" <<'SH'
#!/bin/sh
case " $* " in
  *" -filters "*) echo " T.. subtitles  Render text subtitles onto input video" ;;
esac
exit 0
SH
  printf '#!/bin/sh\necho v24.13.1\n' > "$BATS_STUB_DIR/node"
  chmod +x "$BATS_STUB_DIR/ffmpeg" "$BATS_STUB_DIR/node"
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

@test "ytmv: literal help is a complete import-free setup guide" {
  run "$PYTHON_BIN" "$CLI" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"ytmv setup guide"* ]]
  [[ "$output" == *"Public YouTube videos normally do NOT need an account cookie"* ]]
  [[ "$output" == *"Cookies are credentials"* ]]
  [[ "$output" == *"macOS Chrome: no popup"* ]]
  [[ "$output" == *"Manual converter fallback"* ]]
  [[ "$output" == *"never give the site Google credentials or cookies"* ]]
  [[ "$output" == *"deliberately does not search"* ]]
  [[ "$output" != *"find-generic-password -w"* ]]
}

@test "ytmv: short help stays concise and points at the full guide" {
  run "$PYTHON_BIN" "$CLI" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"help [SUBCOMMAND]"* ]]
  [[ "$output" != *"Cookies are credentials"* ]]
}

@test "ytmv: unknown help topic exits 2 and names the offender" {
  run "$PYTHON_BIN" "$CLI" help bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown help topic 'bogus'"* ]]
}


@test "ytmv: extra help arguments name the unexpected argument" {
  run "$PYTHON_BIN" "$CLI" help get extra
  [ "$status" -eq 2 ]
  [[ "$output" == *"unexpected help argument 'extra'"* ]]
  [[ "$output" != *"unknown help topic 'get'"* ]]
}

@test "ytmv: help SUBCOMMAND delegates to the leaf parser" {
  _uv_cli help get
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage: ytmv get"* ]]
  [[ "$output" == *"--audio-quality"* ]]
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

@test "ytmv doctor --offline --json: has stable statuses and optional checks do not fail" {
  _stub_required_runtime
  _uv_cli doctor --offline --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"profile"'* ]]
  [[ "$output" == *'"id3_version"'* ]]
  [[ "$output" == *'"id": "yt-dlp-ejs"'* ]]
  [[ "$output" == *'"id": "node"'* ]]
  [[ "$output" == *'"id": "youtube-public"'* ]]
  [[ "$output" == *'"status": "skip"'* ]]
  [[ "$output" == *'"required"'* ]]
  [[ "$output" == *"libass"* ]]
}

@test "ytmv doctor: offline cookie probe is rejected before network access" {
  _uv_cli doctor --offline --cookies --json
  [ "$status" -eq 2 ]
  [[ "$output" == *"--offline and --cookies cannot be used together"* ]]
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
  # ytmv tag only needs an MP3 path; mutagen can create an ID3 header on an
  # empty fixture, so these offline tests do not depend on host ffmpeg.
  : > "$YTMV_WORK/demo.mp3"
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
  command -v uv >/dev/null 2>&1 || skip "uv is required"
  # ytmv tag only needs an MP3 path; mutagen can create an ID3 header on an
  # empty fixture, so these offline tests do not depend on host ffmpeg.
  : > "$YTMV_WORK/demo.mp3"

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
  # ytmv tag only needs an MP3 path; mutagen can create an ID3 header on an
  # empty fixture, so these offline tests do not depend on host ffmpeg.
  : > "$YTMV_WORK/demo.mp3"
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
  _uv_cli get "https://www.youtube.com/watch?v=BaW_jenozKc" --lyrics bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"--lyrics must be"* ]]
}

@test "ytmv get: rejects non-HTTPS and non-media YouTube hosts before extraction" {
  for url in \
    "https://example.invalid/watch?v=BaW_jenozKc" \
    "http://www.youtube.com/watch?v=BaW_jenozKc" \
    "https://consent.youtube.com/m?continue=https://www.youtube.com/watch?v=BaW_jenozKc" \
    "https://www.youtube.com/redirect?q=http%3A%2F%2Fwww.youtube.com%2Fplaylist%3Flist%3DPL123"
  do
    _uv_cli get "$url"
    [ "$status" -eq 2 ]
    [[ "$output" == *"only canonical HTTPS YouTube"* ]]
  done
}

@test "ytmv get: explicit cookies require a configured source" {
  _stub_required_runtime
  _uv_cli get "https://www.youtube.com/watch?v=BaW_jenozKc" --cookies
  [ "$status" -eq 2 ]
  [[ "$output" == *"no cookie source configured"* ]]
}

@test "ytmv get: malformed cookie rows never echo bearer values" {
  _stub_required_runtime
  mkdir -p "$XDG_CONFIG_HOME/yth"
  local jar="$YTMV_WORK/malformed.txt" marker="FAKE_BEARER_MUST_NOT_APPEAR"
  printf '# Netscape HTTP Cookie File\n.youtube.com\tMAYBE\t/\tTRUE\t0\tSID\t%s\n' \
    "$marker" > "$jar"
  chmod 600 "$jar"
  printf 'cookiefile = "%s"\n' "$jar" > "$XDG_CONFIG_HOME/yth/config.toml"

  _uv_cli get "https://www.youtube.com/watch?v=BaW_jenozKc" --cookies
  [ "$status" -eq 2 ]
  [[ "$output" == *"not valid Netscape format"* ]]
  [[ "$output" != *"$marker"* ]]

  printf '# Netscape HTTP Cookie File\n.youtube.com\tTRUE\t/\tTRUE\t+4102444800\tSID\t%s\n' \
    "$marker" > "$jar"
  _uv_cli get "https://www.youtube.com/watch?v=BaW_jenozKc" --cookies
  [ "$status" -eq 2 ]
  [[ "$output" == *"entry yt-dlp cannot parse"* ]]
  [[ "$output" != *"$marker"* ]]
}

@test "ytmv get: rejects non-0600 and multi-domain cookie files" {
  _stub_required_runtime
  mkdir -p "$XDG_CONFIG_HOME/yth"
  local jar="$YTMV_WORK/cookies.txt" marker="FAKE_COOKIE_VALUE"
  printf '# Netscape HTTP Cookie File\n.youtube.com\tTRUE\t/\tTRUE\t0\tSID\t%s\n' \
    "$marker" > "$jar"
  chmod 644 "$jar"
  printf 'cookiefile = "%s"\n' "$jar" > "$XDG_CONFIG_HOME/yth/config.toml"

  _uv_cli get "https://www.youtube.com/watch?v=BaW_jenozKc" --cookies
  [ "$status" -eq 2 ]
  [[ "$output" == *"expected 0600"* ]]
  [[ "$output" != *"$marker"* ]]

  chmod 400 "$jar"
  _uv_cli get "https://www.youtube.com/watch?v=BaW_jenozKc" --cookies
  [ "$status" -eq 2 ]
  [[ "$output" == *"mode is 0400; expected 0600"* ]]
  [[ "$output" != *"$marker"* ]]

  chmod 600 "$jar"
  printf '# Netscape HTTP Cookie File\n.example.com\tTRUE\t/\tTRUE\t0\tSID\t%s\n' \
    "$marker" > "$jar"
  chmod 600 "$jar"
  _uv_cli get "https://www.youtube.com/watch?v=BaW_jenozKc" --cookies
  [ "$status" -eq 2 ]
  [[ "$output" == *"non-YouTube domains"* ]]
  [[ "$output" != *"$marker"* ]]
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
  run env PATH=/usr/bin:/bin bash -c "source '$BASH_COMPLETION'; complete -p ytmv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"_ytmv_completion"* ]]
}

@test "ytmv: help and both completion files advertise every public option" {
  command -v uv >/dev/null 2>&1 || skip "uv is required to enumerate tyro flags"
  local sub flag flags missing=0
  for sub in get lyrics tag doctor; do
    run uv run --quiet --script "$CLI" "$sub" --help
    [ "$status" -eq 0 ]
    flags="$(printf '%s\n' "$output" | grep -oE '\-\-[a-z0-9][a-z0-9-]*' | sort -u)"
    [ -n "$flags" ]
    for flag in $flags; do
      case "$flag" in
        --help) continue ;;
        --no-*)
          case "$flag" in
            --no-audio|--no-soft-subs) ;;
            *) continue ;;
          esac
          ;;
      esac
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


@test "ytmv: both completions expose setup help topics and cookie diagnostics" {
  for file in "$ZSH_COMPLETION" "$BASH_COMPLETION"; do
    grep -qF -- "help" "$file"
    grep -qF -- "get lyrics tag doctor" "$file"
    grep -qF -- "--cookies" "$file"
  done
}

@test "ytmv: both natural cookie-file targets are excluded from chezmoi" {
  grep -qxF '.config/yth/cookies.txt' "$REPO_ROOT/.chezmoiignore.tmpl"
  grep -qxF '.config/ytmv/cookies.txt' "$REPO_ROOT/.chezmoiignore.tmpl"
}

@test "ytmv: every install surface includes yt-dlp default EJS support" {
  grep -qF -- '"yt-dlp[default]>=2026.7.4"' "$REPO_ROOT/dot_dotfiles/bin/executable_ytmv"
  grep -qF -- '"yt-dlp[default]>=2026.7.4"' "$REPO_ROOT/dot_dotfiles/bin/executable_yth"
  grep -qF -- 'name: yt-dlp[default]' "$REPO_ROOT/dot_ansible/roles/python_uv_tools/defaults/main.yml"
  grep -qF -- 'yt-dlp-ejs' "$REPO_ROOT/dot_ansible/roles/python_uv_tools/defaults/main.yml"
  grep -qF -- "subelements('required_distributions'" "$REPO_ROOT/dot_ansible/roles/python_uv_tools/tasks/main.yml"
}

@test "ytmv: legacy Node is not advertised as an EJS runtime" {
  setup_path_stub
  printf '#!/bin/sh\necho v20.19.5\n' > "$BATS_STUB_DIR/node"
  chmod +x "$BATS_STUB_DIR/node"
  run env PYTHONPATH="$REPO_ROOT" "$PYTHON_BIN" -c \
    'from scripts.yth import yt_dlp_runtime_opts; print(yt_dlp_runtime_opts())'
  [ "$status" -eq 0 ]
  [[ "$output" == *"'js_runtimes': {}"* ]]

  printf '#!/bin/sh\necho v22.14.0\n' > "$BATS_STUB_DIR/node"
  run env PYTHONPATH="$REPO_ROOT" "$PYTHON_BIN" -c \
    'from scripts.yth import yt_dlp_runtime_opts; print(yt_dlp_runtime_opts())'
  [ "$status" -eq 0 ]
  [[ "$output" == *"'node': {}"* ]]
}

@test "ytmv: all embedded yt-dlp calls use managed Node and keep warnings visible" {
  grep -qF -- 'return {"js_runtimes": runtimes}' "$REPO_ROOT/scripts/yth/__init__.py"
  ! grep -R -qF -- '"no_warnings": True' \
    "$REPO_ROOT/scripts/yth" "$REPO_ROOT/scripts/ytmv/get.py"
  for file in sync.py enrich.py fetch_subs.py; do
    grep -qF -- 'yt_dlp_runtime_opts()' "$REPO_ROOT/scripts/yth/$file"
  done
  grep -qF -- 'yt_dlp_runtime_opts()' "$REPO_ROOT/scripts/ytmv/get.py"
}
