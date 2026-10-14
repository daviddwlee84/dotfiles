#!/usr/bin/env bats
# Offline tests for the herdr coding-agent launcher pair:
#   dot_config/herdr/executable_agent-open.sh  (split/tab + HERDR_AGENT_LAUNCH)
#   dot_config/herdr/executable_agent-run.sh   (lean env → agent command)
# plus the rc fast-path guard and the "Agent: …" Quick Action option values.
# The values are the wire format between the TOML files and the launcher: a
# typo there only shows up as a notification at click time, so pin it here.

load "../test_helper.bash"

OPEN="$REPO_ROOT/dot_config/herdr/executable_agent-open.sh"
RUN="$REPO_ROOT/dot_config/herdr/executable_agent-run.sh"
QA_DIR="$REPO_ROOT/dot_config/herdr/plugins/config/cloudmanic.herdr-plus/quick-actions"

setup() {
  setup_path_stub
  HERDR_LOG="$BATS_STUB_DIR/herdr.log"
  RUN_LOG="$BATS_STUB_DIR/run.log"
  export HERDR_LOG RUN_LOG
  export XDG_CACHE_HOME="$BATS_STUB_DIR/cache"
  export HERDR_BIN_PATH="$BATS_STUB_DIR/herdr"
  export HERDR_ACTIVE_PANE_ID=w1:p1 HERDR_ACTIVE_PANE_CWD=/src
  unset HERDR_PLUS_PANE_ID HERDR_PLUS_WORKDIR HERDR_AGENT_FULL_RC
  cat > "$BATS_STUB_DIR/herdr" <<'EOF'
#!/bin/bash
{ for a in "$@"; do printf '%s\t' "$a"; done; printf '\n'; } >> "$HERDR_LOG"
case "$1 $2" in
  "pane get")   echo '{"result":{"pane":{"pane_id":"w1:p1","workspace_id":"w1","cwd":"/live"}}}' ;;
  "pane split") echo '{"result":{"pane":{"pane_id":"w1:p9"}}}' ;;
  "tab create") echo '{"result":{"tab":{},"root_pane":{"pane_id":"w1:p8"}}}' ;;
esac
EOF
  # agent-run stubs: record the argv each "agent" was started with.
  for t in specstory claude codex opencode mise; do
    printf '#!/bin/sh\n[ "$(basename "$0")" = mise ] && exit 0\necho "$(basename "$0") $*" >> "$RUN_LOG"\n' > "$BATS_STUB_DIR/$t"
  done
  chmod +x "$BATS_STUB_DIR"/*
}

@test "scripts parse" {
  sh -n "$OPEN"
  bash -n "$RUN"
}

@test "split right: source pane, cwd and launch env reach herdr" {
  run sh "$OPEN" right claude run
  [ "$status" -eq 0 ]
  grep -q $'^pane\tsplit\tw1:p1\t--direction\tright\t--cwd\t/src\t--focus\t--env\tHERDR_AGENT_LAUNCH=claude run\t$' "$HERDR_LOG"
}

@test "Quick Action context wins over keybinding context" {
  HERDR_PLUS_PANE_ID=w2:p3 HERDR_PLUS_WORKDIR=/qa run sh "$OPEN" down codex off
  [ "$status" -eq 0 ]
  grep -q $'^pane\tsplit\tw2:p3\t--direction\tdown\t--cwd\t/qa\t' "$HERDR_LOG"
}

@test "no cwd env: falls back to the pane's live cwd from herdr" {
  unset HERDR_ACTIVE_PANE_CWD
  run sh "$OPEN" right claude run
  [ "$status" -eq 0 ]
  grep -q $'\t--cwd\t/live\t' "$HERDR_LOG"
}

@test "tab: created in the source workspace, labelled with the agent" {
  run sh "$OPEN" tab codex-copilot run
  [ "$status" -eq 0 ]
  grep -q $'^tab\tcreate\t--label\tcodex-copilot\t--workspace\tw1\t--cwd\t/src\t--focus\t--env\tHERDR_AGENT_LAUNCH=codex-copilot run\t$' "$HERDR_LOG"
}

@test "opencode is normalised to off (no SpecStory provider)" {
  run sh "$OPEN" right opencode run
  [ "$status" -eq 0 ]
  grep -q 'HERDR_AGENT_LAUNCH=opencode off' "$HERDR_LOG"
}

@test "unknown tokens are rejected before anything is spawned" {
  run sh "$OPEN" right 'claude;rm' run
  [ "$status" -eq 64 ]
  run sh "$OPEN" left claude run
  [ "$status" -eq 64 ]
  ! grep -q 'split' "$HERDR_LOG"
}

@test "last repeats the previous choice; fails cleanly before the first one" {
  run sh "$OPEN" last
  [ "$status" -eq 1 ]
  sh "$OPEN" down codex run
  : > "$HERDR_LOG"
  run sh "$OPEN" last
  [ "$status" -eq 0 ]
  grep -q -e $'--direction\tdown\t.*HERDR_AGENT_LAUNCH=codex run' "$HERDR_LOG"
}

@test "HERDR_AGENT_FULL_RC=1: no env, command typed into the new pane" {
  HERDR_AGENT_FULL_RC=1 run sh "$OPEN" right claude off
  [ "$status" -eq 0 ]
  ! grep -q HERDR_AGENT_LAUNCH= "$HERDR_LOG"
  grep -q $'^pane\trun\tw1:p9\t.*/agent-run.sh claude off\t$' "$HERDR_LOG"
}

@test "agent-run maps choices to commands (specstory names the provider)" {
  HOME="$BATS_STUB_DIR" XDG_CONFIG_HOME="$BATS_STUB_DIR/cfg" bash "$RUN" claude run
  HOME="$BATS_STUB_DIR" XDG_CONFIG_HOME="$BATS_STUB_DIR/cfg" bash "$RUN" codex off
  HOME="$BATS_STUB_DIR" XDG_CONFIG_HOME="$BATS_STUB_DIR/cfg" bash "$RUN" opencode off
  [ "$(cat "$RUN_LOG")" = "$(printf 'specstory run claude\ncodex \nopencode ')" ]
}

@test "agent-run rejects unknown agents" {
  run bash "$RUN" 'bash -c' off
  [ "$status" -eq 64 ]
}

@test "rc guard is present in both shells, before the heavy init" {
  grep -q 'agent-run.sh" ${=_herdr_agent_launch}' "$REPO_ROOT/dot_zshrc.tmpl"
  grep -q 'agent-run.sh" $_herdr_agent_launch' "$REPO_ROOT/dot_bashrc.tmpl"
  z_guard=$(grep -n HERDR_AGENT_LAUNCH "$REPO_ROOT/dot_zshrc.tmpl" | head -1 | cut -d: -f1)
  z_omz=$(grep -n '^plugins=(' "$REPO_ROOT/dot_zshrc.tmpl" | head -1 | cut -d: -f1)
  [ "$z_guard" -lt "$z_omz" ]
  b_guard=$(grep -n HERDR_AGENT_LAUNCH "$REPO_ROOT/dot_bashrc.tmpl" | head -1 | cut -d: -f1)
  b_ble=$(grep -n 'ble.sh' "$REPO_ROOT/dot_bashrc.tmpl" | grep -v '^[0-9]*:#' | head -1 | cut -d: -f1)
  [ "$b_guard" -lt "$b_ble" ]
}

@test "every Quick Action option value is a valid launcher argv" {
  vals=$(python3 -c '
import glob, sys, tomllib
for f in sorted(glob.glob(sys.argv[1] + "/agent-*.toml")):
    d = tomllib.load(open(f, "rb"))
    assert d["command"] == "~/.config/herdr/agent-open.sh {{.Value}}", f
    for o in d["options"]:
        if "value" in o: print(o["value"])
' "$QA_DIR")
  [ -n "$vals" ]
  while read -r p a r; do
    : > "$HERDR_LOG"
    sh "$OPEN" "$p" "$a" "$r"
  done <<< "$vals"
}
