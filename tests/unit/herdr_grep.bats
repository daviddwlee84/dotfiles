#!/usr/bin/env bats
# Offline black-box tests for dot_dotfiles/bin/executable_herdr-grep.

load "../test_helper.bash"

CLI="$REPO_ROOT/dot_dotfiles/bin/executable_herdr-grep"
ZSH_COMPLETION="$REPO_ROOT/dot_config/zsh/tools/59_herdr_grep_completion.zsh"
BASH_COMPLETION="$REPO_ROOT/dot_config/bash/59_herdr_grep_completion.bash"

setup() {
  PYTHON_BIN="$(command -v python3)"
  REAL_RG="$(command -v rg)"
  [ -n "$PYTHON_BIN" ] || skip "python3 is required"
  [ -n "$REAL_RG" ] || skip "rg is required"
  export PYTHON_BIN REAL_RG
  unset HERDR_ENV HERDR_SOCKET_PATH

  setup_path_stub
  HERDR_CALL_LOG="$BATS_STUB_DIR/herdr.log"
  RG_CALL_LOG="$BATS_STUB_DIR/rg.log"
  FZF_CALL_LOG="$BATS_STUB_DIR/fzf.log"
  FZF_INPUT_LOG="$BATS_STUB_DIR/fzf-input.tsv"
  FZF_STATE="$BATS_STUB_DIR/fzf-state"
  FOCUS_CALL_LOG="$BATS_STUB_DIR/focus.log"
  HERDR_GREP_FOCUS_HELPER="$BATS_STUB_DIR/focus-helper.py"
  export HERDR_CALL_LOG RG_CALL_LOG FZF_CALL_LOG FZF_INPUT_LOG FZF_STATE
  export FOCUS_CALL_LOG HERDR_GREP_FOCUS_HELPER

  _install_herdr_stub
  _install_rg_stub
  _install_fzf_stub
  _install_focus_stub
}

_install_herdr_stub() {
  cat > "$BATS_STUB_DIR/herdr" <<'EOF'
#!/bin/bash
{
  printf 'socket=%s' "${HERDR_SOCKET_PATH-<unset>}"
  for arg in "$@"; do
    printf '\t%s' "$arg"
  done
  printf '\n'
} >> "$HERDR_CALL_LOG"

mode="${HERDR_TEST_MODE-default}"
if [ "$#" -eq 0 ]; then
  exit "${HERDR_ATTACH_RC:-0}"
fi
if [ "$1" = "session" ] && [ "$2" = "attach" ]; then
  exit "${HERDR_ATTACH_RC:-0}"
fi
if [ "$1" = "session" ] && [ "$2" = "list" ] && [ "$3" = "--json" ]; then
  case "$mode" in
    malformed-session)
      printf '{\n'
      ;;
    no-running)
      printf '%s\n' '{"sessions":[{"name":"stopped","running":false,"socket_path":"/tmp/stopped.sock"}]}'
      ;;
    duplicate-session)
      printf '%s\n' '{"sessions":[{"name":"default","running":true,"socket_path":"/tmp/a.sock"},{"name":"default","running":true,"socket_path":"/tmp/b.sock"}]}'
      ;;
    *)
      printf '%s\n' '{"sessions":[{"name":"stopped","running":false,"socket_path":"/tmp/stopped.sock"},{"name":"alpha","running":true,"socket_path":"/tmp/alpha.sock"},{"name":"default","running":true,"socket_path":"/tmp/default.sock"}]}'
      ;;
  esac
  exit 0
fi

if [ "$1" = "pane" ] && [ "$2" = "list" ]; then
  case "$mode:${HERDR_SOCKET_PATH-}" in
    malformed-pane:*)
      printf '{\n'
      exit 0
      ;;
    bad-entry:*)
      printf '%s\n' '{"id":"cli:pane:list","result":{"panes":[{"pane_id":"broken"},{"pane_id":"opaque:p9","workspace_id":"workspace-A","tab_id":"tab-Z","agent_status":"idle","foreground_cwd":"/live","cwd":"/start"}]}}'
      exit 0
      ;;
    disappearing:*)
      printf '%s\n' '{"id":"cli:pane:list","result":{"panes":[{"pane_id":"gone:p1","workspace_id":"workspace-G","tab_id":"tab-G"},{"pane_id":"opaque:p9","workspace_id":"workspace-A","tab_id":"tab-Z","agent_status":"idle","foreground_cwd":"/live","cwd":"/start"}]}}'
      exit 0
      ;;
    invalid-bytes:*)
      printf '%s\n' '{"id":"cli:pane:list","result":{"panes":[{"pane_id":"bytes:p1","workspace_id":"workspace-B","tab_id":"tab-B"}]}}'
      exit 0
      ;;
    nul-pane:*)
      printf '%s\n' '{"id":"cli:pane:list","result":{"panes":[{"pane_id":"bad\u0000id","workspace_id":"workspace-N","tab_id":"tab-N"},{"pane_id":"opaque:p9","workspace_id":"workspace-A","tab_id":"tab-Z"}]}}'
      exit 0
      ;;
    session-failure:/tmp/alpha.sock)
      printf '%s\n' 'alpha pane list failed' >&2
      exit 9
      ;;
    *:/tmp/alpha.sock)
      printf '%s\n' '{"id":"cli:pane:list","result":{"panes":[{"pane_id":"same:p1","workspace_id":"alpha-space","tab_id":"alpha-tab","agent_status":"working","foreground_cwd":"/alpha/live","cwd":"/alpha/start"}]}}'
      exit 0
      ;;
    shuffle:*)
      printf '%s\n' '{"id":"cli:pane:list","result":{"panes":[{"pane_id":"opaque:p9","workspace_id":"workspace-A","tab_id":"tab-Z","agent_status":"idle","foreground_cwd":"/live","cwd":"/start"},{"pane_id":"same:p1","workspace_id":"workspace-B","tab_id":"tab-A"}]}}'
      exit 0
      ;;
    *)
      printf '%s\n' '{"id":"cli:pane:list","result":{"panes":[{"pane_id":"same:p1","workspace_id":"workspace-B","tab_id":"tab-A"},{"pane_id":"opaque:p9","workspace_id":"workspace-A","tab_id":"tab-Z","agent_status":"idle","foreground_cwd":"/live","cwd":"/start"}]}}'
      exit 0
      ;;
  esac
fi

if [ "$1" = "pane" ] && [ "$2" = "read" ]; then
  pane="$3"
  source="$5"
  if [ "$mode" = "scrollback-only" ] && [ "$source" = "visible" ]; then
    printf 'no visible match\n'
    exit 0
  fi
  case "$pane" in
    opaque:p9)
      printf 'ordinary needle\nneedle needle\nliteral a.b\n-leading-dash\n'
      ;;
    same:p1)
      if [ "${HERDR_SOCKET_PATH-}" = "/tmp/alpha.sock" ]; then
        printf 'needle from alpha\n'
      else
        printf 'needle from default-second-pane\n'
      fi
      ;;
    gone:p1)
      printf '%s\n' 'pane not found' >&2
      exit 7
      ;;
    bytes:p1)
      printf 'bad\377 needle\n'
      ;;
    *)
      printf 'no matching content\n'
      ;;
  esac
  exit 0
fi

printf 'unexpected herdr call:' >&2
printf ' %s' "$@" >&2
printf '\n' >&2
exit 99
EOF
  chmod +x "$BATS_STUB_DIR/herdr"
}

_install_rg_stub() {
  cat > "$BATS_STUB_DIR/rg" <<'EOF'
#!/bin/bash
{
  printf 'rg'
  for arg in "$@"; do
    printf '\t%s' "$arg"
  done
  printf '\n'
} >> "$RG_CALL_LOG"
if [ "${RG_TEST_MODE-}" = "malformed" ]; then
  # Drain stdin before returning a deliberately invalid success payload.
  while IFS= read -r _line; do :; done
  printf '{\n'
  exit 0
fi
exec "$REAL_RG" "$@"
EOF
  chmod +x "$BATS_STUB_DIR/rg"
}

_install_fzf_stub() {
  cat > "$BATS_STUB_DIR/fzf" <<'EOF'
#!/bin/bash
{
  printf 'fzf'
  for arg in "$@"; do printf '\t%s' "$arg"; done
  printf '\n'
} >> "$FZF_CALL_LOG"
cat > "$FZF_INPUT_LOG"
first=$(IFS= read -r line < "$FZF_INPUT_LOG" && printf '%s' "$line")
mode="${FZF_TEST_MODE:-select}"
case "$mode" in
  esc) exit 130 ;;
  no-match) exit 1 ;;
  fail) printf 'fzf failed\n' >&2; exit 9 ;;
  alt-s-once)
    if [ ! -e "$FZF_STATE" ]; then
      : > "$FZF_STATE"
      printf 'refine\nalt-s\n%s\n' "$first"
    else
      printf 'refine\n\n%s\n' "$first"
    fi
    ;;
  alt-v-once)
    if [ ! -e "$FZF_STATE" ]; then
      : > "$FZF_STATE"
      printf 'refine\nalt-v\n%s\n' "$first"
    else
      printf 'refine\n\n%s\n' "$first"
    fi
    ;;
  alt-v-then-alt-s)
    count=$(cat "$FZF_STATE" 2>/dev/null || printf '0')
    case "$count" in
      0) printf '1' > "$FZF_STATE"; printf 'refine\nalt-v\n%s\n' "$first" ;;
      1) printf '2' > "$FZF_STATE"; printf 'refine\nalt-s\n%s\n' "$first" ;;
      *) printf 'refine\n\n%s\n' "$first" ;;
    esac
    ;;
  unicode-query) printf 'refine query\n\n%s\n' "$first" ;;
  *) printf '\n\n%s\n' "$first" ;;
esac
EOF
  chmod +x "$BATS_STUB_DIR/fzf"
}

_install_focus_stub() {
  cat > "$HERDR_GREP_FOCUS_HELPER" <<'EOF'
import os
import sys

with open(os.environ["FOCUS_CALL_LOG"], "a", encoding="utf-8") as handle:
    handle.write("\t".join(sys.argv[1:]) + "\n")
if os.environ.get("FOCUS_HELPER_RC"):
    print("focus helper failed", file=sys.stderr)
sys.exit(int(os.environ.get("FOCUS_HELPER_RC", "0")))
EOF
}

_assert_log_lacks() {
  local pattern="$1" file="$2" count
  count=$(grep -F -c -- "$pattern" "$file" 2>/dev/null || true)
  [ "${count:-0}" -eq 0 ]
}

@test "herdr-grep: help advertises the v1 surface" {
  run "$PYTHON_BIN" "$CLI" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--source {visible,recent,recent-unwrapped}"* ]]
  [[ "$output" == *"--session NAME"* ]]
  [[ "$output" == *"--all-sessions"* ]]
  [[ "$output" == *"--list-sessions"* ]]
  [[ "$output" == *"--json"* ]]
  [[ "$output" == *"--pick"* ]]
}

@test "herdr-grep: list-sessions prints sorted running names without rg" {
  rm -f "$BATS_STUB_DIR/rg"
  run env PATH="$BATS_STUB_DIR" "$PYTHON_BIN" "$CLI" --list-sessions
  [ "$status" -eq 0 ]
  [ "$output" = $'alpha\ndefault' ]
  [ ! -e "$RG_CALL_LOG" ]
}

@test "herdr-grep: default search uses recent and direct pane metadata" {
  run "$PYTHON_BIN" "$CLI" needle
  [ "$status" -eq 0 ]
  [[ "$output" == *"[session=default workspace=workspace-A tab=tab-Z pane=opaque:p9] 1:ordinary needle"* ]]
  [[ "$output" == *"[session=default workspace=workspace-B tab=tab-A pane=same:p1] 1:needle from default-second-pane"* ]]
  grep -F $'socket=<unset>\tpane\tlist' "$HERDR_CALL_LOG"
  grep -F $'pane\tread\topaque:p9\t--source\trecent\t--format\ttext' "$HERDR_CALL_LOG"
  grep -F $'rg\t--no-config\t--json\t--text\t--\tneedle' "$RG_CALL_LOG"
}

@test "herdr-grep: visible and recent-unwrapped select the requested source" {
  run "$PYTHON_BIN" "$CLI" --visible needle
  [ "$status" -eq 0 ]
  grep -F -- $'--source\tvisible' "$HERDR_CALL_LOG"

  : > "$HERDR_CALL_LOG"
  run "$PYTHON_BIN" "$CLI" --source recent-unwrapped needle
  [ "$status" -eq 0 ]
  grep -F -- $'--source\trecent-unwrapped' "$HERDR_CALL_LOG"
}

@test "herdr-grep: fixed-string and ignore-case flags reach ripgrep" {
  run "$PYTHON_BIN" "$CLI" -F -i 'A.B'
  [ "$status" -eq 0 ]
  [[ "$output" == *"literal a.b"* ]]
  grep -F -- $'--fixed-strings\t--ignore-case\t--\tA.B' "$RG_CALL_LOG"
}

@test "herdr-grep: a leading-dash pattern is protected by --" {
  run "$PYTHON_BIN" "$CLI" -F -- -leading-dash
  [ "$status" -eq 0 ]
  [[ "$output" == *"4:-leading-dash"* ]]
  grep -F -- $'--fixed-strings\t--\t-leading-dash' "$RG_CALL_LOG"
}

@test "herdr-grep: ambient socket stays ambient and supplies the session name" {
  run env HERDR_SOCKET_PATH=/tmp/alpha.sock "$PYTHON_BIN" "$CLI" needle
  [ "$status" -eq 0 ]
  [[ "$output" == *"session=alpha workspace=alpha-space tab=alpha-tab pane=same:p1"* ]]
  grep -F $'socket=/tmp/alpha.sock\tpane\tlist' "$HERDR_CALL_LOG"
  grep -F $'socket=/tmp/alpha.sock\tpane\tread\tsame:p1' "$HERDR_CALL_LOG"
}

@test "herdr-grep: unregistered ambient socket fails instead of claiming default" {
  run env HERDR_SOCKET_PATH=/tmp/unregistered.sock "$PYTHON_BIN" "$CLI" --json needle
  [ "$status" -eq 2 ]
  printf '%s' "$output" | jq -e '
    .complete == false
    and (.errors[] | select(.operation == "session-select"
      and (.message | contains("does not uniquely match"))))
  ' >/dev/null
  _assert_log_lacks $'pane\tlist' "$HERDR_CALL_LOG"
}

@test "herdr-grep: explicit session scopes pane calls to its socket" {
  run "$PYTHON_BIN" "$CLI" --session alpha needle
  [ "$status" -eq 0 ]
  [[ "$output" == *"session=alpha"* ]]
  grep -F $'socket=/tmp/alpha.sock\tpane\tlist' "$HERDR_CALL_LOG"
  _assert_log_lacks $'socket=/tmp/default.sock\tpane\tlist' "$HERDR_CALL_LOG"
}

@test "herdr-grep: all-sessions scans running sessions in sorted order" {
  run "$PYTHON_BIN" "$CLI" --all-sessions needle
  [ "$status" -eq 0 ]
  first_line="${output%%$'\n'*}"
  [[ "$first_line" == *"session=alpha"* ]]
  [[ "$output" == *"session=default"* ]]
  _assert_log_lacks '/tmp/stopped.sock' "$HERDR_CALL_LOG"
}

@test "herdr-grep: missing and stopped explicit sessions fail before pane list" {
  run "$PYTHON_BIN" "$CLI" --session missing needle
  [ "$status" -eq 2 ]
  [[ "$output" == *"session 'missing' not found"* ]]
  _assert_log_lacks $'pane\tlist' "$HERDR_CALL_LOG"

  : > "$HERDR_CALL_LOG"
  run "$PYTHON_BIN" "$CLI" --session stopped needle
  [ "$status" -eq 2 ]
  [[ "$output" == *"session 'stopped' is not running"* ]]
  _assert_log_lacks $'pane\tlist' "$HERDR_CALL_LOG"
}

@test "herdr-grep: a complete no-match is silent and exits 1" {
  run "$PYTHON_BIN" "$CLI" '__definitely_absent__'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "herdr-grep: JSON includes metadata and every submatch" {
  run "$PYTHON_BIN" "$CLI" --json 'needle'
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .schema_version == 1
    and .complete == true
    and .source == "recent"
    and (.matches[] | select(.pane_id == "opaque:p9" and .line_number == 2)
      | (.submatches | length) == 2)
    and (.matches[] | select(.pane_id == "opaque:p9")
      | .workspace_id == "workspace-A" and .tab_id == "tab-Z")
  ' >/dev/null
}

@test "herdr-grep: disappearing pane preserves matches and returns partial failure" {
  run env HERDR_TEST_MODE=disappearing "$PYTHON_BIN" "$CLI" needle
  [ "$status" -eq 2 ]
  [[ "$output" == *"ordinary needle"* ]]
  [[ "$output" == *"pane=gone:p1 pane-read: pane not found"* ]]

  run env HERDR_TEST_MODE=disappearing "$PYTHON_BIN" "$CLI" --json needle
  [ "$status" -eq 2 ]
  printf '%s' "$output" | jq -e '
    .complete == false
    and (.matches | length) > 0
    and (.errors[] | select(.pane_id == "gone:p1" and .operation == "pane-read"))
  ' >/dev/null
}

@test "herdr-grep: malformed session and pane JSON are operational errors" {
  run env HERDR_TEST_MODE=malformed-session "$PYTHON_BIN" "$CLI" needle
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid session-list JSON"* ]]

  run env HERDR_TEST_MODE=malformed-pane "$PYTHON_BIN" "$CLI" needle
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid pane-list JSON"* ]]
}

@test "herdr-grep: malformed pane entry keeps valid matches but exits 2" {
  run env HERDR_TEST_MODE=bad-entry "$PYTHON_BIN" "$CLI" needle
  [ "$status" -eq 2 ]
  [[ "$output" == *"ordinary needle"* ]]
  [[ "$output" == *"pane-entry"* ]]
}

@test "herdr-grep: invalid regex fails before pane enumeration" {
  run "$PYTHON_BIN" "$CLI" '('
  [ "$status" -eq 2 ]
  [[ "$output" == *"rg-validate"* ]]
  _assert_log_lacks $'pane\tlist' "$HERDR_CALL_LOG"
}

@test "herdr-grep: malformed ripgrep JSON is a partial pane error" {
  run env RG_TEST_MODE=malformed "$PYTHON_BIN" "$CLI" needle
  [ "$status" -eq 2 ]
  [[ "$output" == *"rg-match"* ]]
}

@test "herdr-grep: launch-time argv errors stay structured and preserve matches" {
  run env HERDR_TEST_MODE=nul-pane "$PYTHON_BIN" "$CLI" --json needle
  [ "$status" -eq 2 ]
  printf '%s' "$output" | jq -e '
    .complete == false
    and (.matches | length) > 0
    and (.errors[] | select(.pane_id == "bad\u0000id" and .operation == "pane-read"
      and (.message | contains("failed to execute"))))
  ' >/dev/null
  [[ "$output" != *"Traceback"* ]]
}

@test "herdr-grep: invalid terminal bytes are replaced instead of crashing" {
  run env HERDR_TEST_MODE=invalid-bytes "$PYTHON_BIN" "$CLI" needle
  [ "$status" -eq 0 ]
  [[ "$output" == *"pane=bytes:p1"* ]]
  [[ "$output" == *"needle"* ]]
}

@test "herdr-grep: one failed all-session scan preserves other results and exits 2" {
  run env HERDR_TEST_MODE=session-failure "$PYTHON_BIN" "$CLI" --all-sessions needle
  [ "$status" -eq 2 ]
  [[ "$output" == *"session=default"* ]]
  [[ "$output" == *"session=alpha pane-list: alpha pane list failed"* ]]
}

@test "herdr-grep: all-sessions with no running sessions is a clean no-match" {
  run env HERDR_TEST_MODE=no-running "$PYTHON_BIN" "$CLI" --all-sessions needle
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  _assert_log_lacks $'pane\tlist' "$HERDR_CALL_LOG"
}

@test "herdr-grep: sorted output does not depend on pane-list order" {
  run "$PYTHON_BIN" "$CLI" needle
  [ "$status" -eq 0 ]
  normal="$output"

  run env HERDR_TEST_MODE=shuffle "$PYTHON_BIN" "$CLI" needle
  [ "$status" -eq 0 ]
  [ "$output" = "$normal" ]
}

@test "herdr-grep: --pick is mutually exclusive with JSON and needs a pattern noninteractively" {
  run "$PYTHON_BIN" "$CLI" --json --pick needle
  [ "$status" -eq 2 ]
  [[ "$output" == *"not allowed with argument --json"* ]]

  run "$PYTHON_BIN" "$CLI" --pick
  [ "$status" -eq 2 ]
  [[ "$output" == *"required: PATTERN"* ]]
}

@test "herdr-grep: inside Herdr picks and focuses the selected current-session pane" {
  run env HERDR_ENV=1 HERDR_SOCKET_PATH=/tmp/default.sock \
    "$PYTHON_BIN" "$CLI" --pick --visible needle
  [ "$status" -eq 0 ]
  grep -F -- '--route-token' "$FOCUS_CALL_LOG"
  grep -F $'[default/workspace-A/tab-Z/opaque:p9 L1 idle]\tordinary needle' "$FZF_INPUT_LOG"
  grep -F -- '--with-nth=2..' "$FZF_CALL_LOG"
  grep -F -- '--preview-route-token {1}' "$FZF_CALL_LOG"
  _assert_log_lacks $'session\tattach' "$HERDR_CALL_LOG"
}

@test "herdr-grep: outside Herdr focuses then attaches default or named session" {
  run "$PYTHON_BIN" "$CLI" --pick --visible needle
  [ "$status" -eq 0 ]
  grep -Fx 'socket=/tmp/default.sock' "$HERDR_CALL_LOG"

  : > "$HERDR_CALL_LOG"
  : > "$FOCUS_CALL_LOG"
  run "$PYTHON_BIN" "$CLI" --pick --visible --session alpha needle
  [ "$status" -eq 0 ]
  grep -F $'session\tattach\talpha' "$HERDR_CALL_LOG"
  grep -F -- '--route-token' "$FOCUS_CALL_LOG"
}

@test "herdr-grep: inside Herdr refuses a cross-session selection without nesting" {
  run env HERDR_ENV=1 HERDR_SOCKET_PATH=/tmp/default.sock \
    "$PYTHON_BIN" "$CLI" --pick --visible --session alpha needle
  [ "$status" -eq 2 ]
  [[ "$output" == *"belongs to another session"* ]]
  [[ "$output" == *"herdr session attach alpha"* ]]
  [ ! -e "$FOCUS_CALL_LOG" ]
}

@test "herdr-grep: Alt+S and Alt+V rescan explicitly and preserve fzf query" {
  run env HERDR_ENV=1 HERDR_SOCKET_PATH=/tmp/default.sock FZF_TEST_MODE=alt-s-once \
    "$PYTHON_BIN" "$CLI" --pick --visible needle
  [ "$status" -eq 0 ]
  grep -F -- $'--source\tvisible' "$HERDR_CALL_LOG"
  grep -F -- $'--source\trecent-unwrapped' "$HERDR_CALL_LOG"
  grep -F -- '--query=refine' "$FZF_CALL_LOG"

  : > "$HERDR_CALL_LOG"
  : > "$FZF_CALL_LOG"
  rm -f "$FZF_STATE"
  run env HERDR_ENV=1 HERDR_SOCKET_PATH=/tmp/default.sock FZF_TEST_MODE=alt-v-once \
    "$PYTHON_BIN" "$CLI" --pick --source recent-unwrapped needle
  [ "$status" -eq 0 ]
  grep -F -- $'--source\trecent-unwrapped' "$HERDR_CALL_LOG"
  grep -F -- $'--source\tvisible' "$HERDR_CALL_LOG"
}

@test "herdr-grep: Esc is quiet and never invokes focus" {
  run env HERDR_ENV=1 HERDR_SOCKET_PATH=/tmp/default.sock FZF_TEST_MODE=esc \
    "$PYTHON_BIN" "$CLI" --pick --visible needle
  [ "$status" -eq 0 ]
  [ ! -e "$FOCUS_CALL_LOG" ]
}

@test "herdr-grep: partial matches remain pickable and warn in the fzf header" {
  run env HERDR_ENV=1 HERDR_SOCKET_PATH=/tmp/default.sock HERDR_TEST_MODE=disappearing \
    "$PYTHON_BIN" "$CLI" --pick --visible needle
  [ "$status" -eq 0 ]
  grep -F -- '⚠ incomplete' "$FZF_CALL_LOG"
  grep -F -- '--route-token' "$FOCUS_CALL_LOG"
}

@test "herdr-grep: picker dependency and focus failures are operational errors" {
  rm -f "$BATS_STUB_DIR/fzf"
  run env PATH="$BATS_STUB_DIR" "$PYTHON_BIN" "$CLI" --pick --visible needle
  [ "$status" -eq 2 ]
  [[ "$output" == *"fzf not found"* ]]

  _install_fzf_stub
  run env FOCUS_HELPER_RC=1 "$PYTHON_BIN" "$CLI" --pick --visible needle
  [ "$status" -eq 2 ]
  [[ "$output" == *"focus helper failed"* ]]
}

@test "herdr-grep: pick mode excludes its own command pane" {
  run env HERDR_ENV=1 HERDR_SOCKET_PATH=/tmp/default.sock HERDR_PANE_ID=opaque:p9 \
    "$PYTHON_BIN" "$CLI" --pick --visible needle
  [ "$status" -eq 0 ]
  _assert_log_lacks 'opaque:p9' "$FZF_INPUT_LOG"
  grep -F 'same:p1' "$FZF_INPUT_LOG"
}

@test "herdr-grep: command-pane exclusion is scoped to its session socket" {
  run env HERDR_ENV=1 HERDR_SOCKET_PATH=/tmp/default.sock HERDR_PANE_ID=same:p1 \
    FZF_TEST_MODE=esc "$PYTHON_BIN" "$CLI" --pick --all-sessions --visible needle
  [ "$status" -eq 0 ]
  grep -F '[alpha/alpha-space/alpha-tab/same:p1' "$FZF_INPUT_LOG"
  _assert_log_lacks '[default/workspace-B/tab-A/same:p1' "$FZF_INPUT_LOG"
}

@test "herdr-grep: default attach is forced through the selected socket" {
  run env HERDR_SOCKET_PATH=/tmp/alpha.sock \
    "$PYTHON_BIN" "$CLI" --pick --visible --session default needle
  [ "$status" -eq 0 ]
  grep -Fx 'socket=/tmp/default.sock' "$HERDR_CALL_LOG"
}

@test "herdr-grep: empty source toggle stays open so the previous source can return" {
  run env HERDR_ENV=1 HERDR_SOCKET_PATH=/tmp/default.sock \
    HERDR_TEST_MODE=scrollback-only FZF_TEST_MODE=alt-v-then-alt-s \
    "$PYTHON_BIN" "$CLI" --pick --source recent-unwrapped needle
  [ "$status" -eq 0 ]
  [ "$(grep -c '^fzf' "$FZF_CALL_LOG")" -eq 3 ]
  grep -F -- 'no matches in this source' "$FZF_CALL_LOG"
  grep -F -- '--route-token' "$FOCUS_CALL_LOG"
}

@test "herdr-grep: Unicode line separator in fzf query does not shift protocol fields" {
  run env HERDR_ENV=1 HERDR_SOCKET_PATH=/tmp/default.sock FZF_TEST_MODE=unicode-query \
    "$PYTHON_BIN" "$CLI" --pick --visible needle
  [ "$status" -eq 0 ]
  grep -F -- '--route-token' "$FOCUS_CALL_LOG"
}

@test "herdr-grep: route token is bounded to routing metadata" {
  run env HERDR_ENV=1 HERDR_SOCKET_PATH=/tmp/default.sock \
    "$PYTHON_BIN" "$CLI" --pick --visible needle
  [ "$status" -eq 0 ]
  call=$(grep -F -- '--route-token' "$FOCUS_CALL_LOG")
  token=${call#*$'\t'}
  TOKEN="$token" "$PYTHON_BIN" -c '
import base64, json, os
value = os.environ["TOKEN"]
value += "=" * (-len(value) % 4)
payload = json.loads(base64.urlsafe_b64decode(value).decode())
assert "line" not in payload
assert "cwd" not in payload
assert len(os.environ["TOKEN"]) < 1024
'
}

@test "herdr-grep: missing dependencies return 2 and JSON errors stay valid" {
  empty_path="$BATS_STUB_DIR/empty"
  mkdir "$empty_path"
  run env PATH="$empty_path" "$PYTHON_BIN" "$CLI" needle
  [ "$status" -eq 2 ]
  [[ "$output" == *"herdr not found on PATH"* ]]

  rm -f "$BATS_STUB_DIR/rg"
  run env PATH="$BATS_STUB_DIR" "$PYTHON_BIN" "$CLI" --json needle
  [ "$status" -eq 2 ]
  printf '%s' "$output" | jq -e '
    .complete == false
    and (.errors[] | select(.operation == "dependency" and (.message | contains("rg not found"))))
  ' >/dev/null
}

@test "herdr-grep: help and both completion files advertise every public option" {
  [ -f "$ZSH_COMPLETION" ]
  [ -f "$BASH_COMPLETION" ]
  run "$PYTHON_BIN" "$CLI" --help
  [ "$status" -eq 0 ]
  for option in --fixed-strings --ignore-case --source --visible --session --all-sessions --json --pick --list-sessions; do
    [[ "$output" == *"$option"* ]]
    grep -F -- "$option" "$ZSH_COMPLETION"
    grep -F -- "$option" "$BASH_COMPLETION"
  done
  for source in visible recent recent-unwrapped; do
    grep -F -- "$source" "$ZSH_COMPLETION"
    grep -F -- "$source" "$BASH_COMPLETION"
  done
}

@test "herdr-grep: Bash completion registers before the managed bin PATH loads" {
  run env PATH=/usr/bin:/bin /bin/bash --noprofile --norc -c \
    "source '$BASH_COMPLETION'; complete -p herdr-grep"
  [ "$status" -eq 0 ]
  [[ "$output" == *"complete -F _herdr_grep_completion herdr-grep"* ]]
}
