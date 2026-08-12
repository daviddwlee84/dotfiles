#!/usr/bin/env bats
# Offline black-box tests for dot_config/herdr/executable_focus-pane.py.

load "../test_helper.bash"

HELPER="$REPO_ROOT/dot_config/herdr/executable_focus-pane.py"

setup() {
  PYTHON_BIN="$(command -v python3)"
  [ -n "$PYTHON_BIN" ] || skip "python3 is required"
  setup_path_stub
  FOCUS_LOG="$BATS_STUB_DIR/herdr.log"
  FOCUS_STATE="$BATS_STUB_DIR/focused"
  printf 'p1\n' > "$FOCUS_STATE"
  export FOCUS_LOG FOCUS_STATE
  _install_herdr_stub
}

_install_herdr_stub() {
  cat > "$BATS_STUB_DIR/herdr" <<'EOF'
#!/bin/bash
mode="${FOCUS_MODE:-vertical}"
focused=$(cat "$FOCUS_STATE")
{
  printf 'socket=%s' "${HERDR_SOCKET_PATH-<unset>}"
  for arg in "$@"; do printf '\t%s' "$arg"; done
  printf '\n'
} >> "$FOCUS_LOG"

layout_json() {
  focused=$(cat "$FOCUS_STATE")
  case "$mode" in
    one)
      printf '{"area":{"height":20,"width":80,"x":0,"y":0},"focused_pane_id":"target","panes":[{"focused":true,"pane_id":"target","rect":{"height":20,"width":80,"x":0,"y":0}}],"splits":[],"tab_id":"tab","workspace_id":"ws","zoomed":false}'
      ;;
    malformed)
      printf '{"focused_pane_id":"p1","panes":"bad","tab_id":"tab","workspace_id":"ws","zoomed":false}'
      ;;
    multihop)
      printf '{"area":{"height":20,"width":120,"x":0,"y":0},"focused_pane_id":"%s","panes":[{"focused":false,"pane_id":"p1","rect":{"height":20,"width":40,"x":0,"y":0}},{"focused":false,"pane_id":"p2","rect":{"height":20,"width":40,"x":40,"y":0}},{"focused":false,"pane_id":"target","rect":{"height":20,"width":40,"x":80,"y":0}}],"splits":[{"direction":"right","id":"s1","ratio":0.33,"rect":{"height":20,"width":120,"x":0,"y":0}},{"direction":"right","id":"s2","ratio":0.5,"rect":{"height":20,"width":80,"x":40,"y":0}}],"tab_id":"tab","workspace_id":"ws","zoomed":false}' "$focused"
      ;;
    *)
      printf '{"area":{"height":40,"width":80,"x":0,"y":0},"focused_pane_id":"%s","panes":[{"focused":false,"pane_id":"p1","rect":{"height":20,"width":80,"x":0,"y":0}},{"focused":false,"pane_id":"target","rect":{"height":20,"width":80,"x":0,"y":20}}],"splits":[{"direction":"down","id":"s1","ratio":0.5,"rect":{"height":40,"width":80,"x":0,"y":0}}],"tab_id":"tab","workspace_id":"ws","zoomed":false}' "$focused"
      ;;
  esac
}

ok() { printf '%s\n' '{"id":"stub","result":{"type":"ok"}}'; }

if [ "$1" = pane ] && [ "$2" = get ]; then
  if [ "$mode" = stale ]; then
    printf '%s\n' '{"result":{"pane":{"pane_id":"other","workspace_id":"ws","tab_id":"tab"}}}'
  else
    printf '%s\n' '{"result":{"pane":{"pane_id":"target","workspace_id":"ws","tab_id":"tab"}}}'
  fi
  exit 0
fi

if [ "$1" = agent ] && [ "$2" = get ]; then
  case "$mode" in
    agent) printf '%s\n' '{"result":{"agent":{"pane_id":"target"}}}'; exit 0 ;;
    agent-error) printf '%s\n' '{"error":{"code":"protocol_mismatch","message":"stale server"}}' >&2; exit 1 ;;
    *) printf '%s\n' '{"error":{"code":"agent_not_found","message":"not an agent"}}' >&2; exit 1 ;;
  esac
fi

if [ "$1" = agent ] && [ "$2" = focus ]; then
  printf 'target\n' > "$FOCUS_STATE"
  ok
  exit 0
fi

if [ "$1" = workspace ] && [ "$2" = get ]; then
  focused=true
  [ "$mode" = inactive-final ] && focused=false
  printf '{"result":{"workspace":{"workspace_id":"ws","active_tab_id":"tab","focused":%s}}}\n' "$focused"
  exit 0
fi
if [ "$1" = tab ] && [ "$2" = get ]; then
  focused=true
  [ "$mode" = inactive-final ] && focused=false
  printf '{"result":{"tab":{"workspace_id":"ws","tab_id":"tab","focused":%s}}}\n' "$focused"
  exit 0
fi
if [ "$1" = workspace ] && [ "$2" = focus ]; then ok; exit 0; fi
if [ "$1" = tab ] && [ "$2" = focus ]; then ok; exit 0; fi

if [ "$1" = pane ] && [ "$2" = layout ]; then
  printf '{"result":{"layout":'
  layout_json
  printf '}}\n'
  exit 0
fi

if [ "$1" = pane ] && [ "$2" = neighbor ]; then
  origin="$4"
  direction="$6"
  next=""
  case "$mode:$origin:$direction" in
    multihop:p1:right) next=p2 ;;
    multihop:p2:left) next=p1 ;;
    multihop:p2:right) next=target ;;
    multihop:target:left) next=p2 ;;
    vertical:p1:down|wrong-focus:p1:down|inactive-final:p1:down) next=target ;;
    vertical:target:up|wrong-focus:target:up|inactive-final:target:up) next=p1 ;;
  esac
  printf '{"result":{"neighbor":{"direction":"%s","layout":' "$direction"
  layout_json
  printf ',"pane_id":"%s"' "$origin"
  [ -n "$next" ] && printf ',"neighbor_pane_id":"%s"' "$next"
  printf '}}}\n'
  exit 0
fi

if [ "$1" = pane ] && [ "$2" = focus ]; then
  direction="$4"
  origin="$6"
  case "$mode:$origin:$direction" in
    multihop:p1:right) next=p2 ;;
    multihop:p2:right) next=target ;;
    *:p1:down) next=target ;;
    *) next="$origin" ;;
  esac
  [ "$mode" = wrong-focus ] && next=p1
  printf '%s\n' "$next" > "$FOCUS_STATE"
  ok
  exit 0
fi

if [ "$1" = pane ] && [ "$2" = current ]; then
  focused=$(cat "$FOCUS_STATE")
  printf '{"result":{"pane":{"pane_id":"%s","workspace_id":"ws","tab_id":"tab"}}}\n' "$focused"
  exit 0
fi

if [ "$1" = pane ] && [ "$2" = read ]; then
  printf 'live pane content\n'
  exit 0
fi

printf 'unexpected call' >&2
exit 99
EOF
  chmod +x "$BATS_STUB_DIR/herdr"
}

run_focus() {
  run "$PYTHON_BIN" "$HELPER" \
    --socket-path /tmp/selected.sock \
    --workspace-id ws --tab-id tab --pane-id target
}

make_token() {
  "$PYTHON_BIN" -c '
import base64, json
payload = {
  "schema_version": 1,
  "session": "default",
  "socket_path": "/tmp/selected.sock",
  "workspace_id": "ws",
  "tab_id": "tab",
  "pane_id": "target",
  "source": "visible",
  "line_number": 4,
  "line": "stored match",
  "agent_status": "idle",
  "cwd": "/tmp/project",
}
print(base64.urlsafe_b64encode(json.dumps(payload).encode()).decode().rstrip("="))
'
}

@test "focus-pane: agent pane uses direct agent focus and selected socket" {
  run env FOCUS_MODE=agent "$PYTHON_BIN" "$HELPER" \
    --socket-path /tmp/selected.sock --workspace-id ws --tab-id tab --pane-id target
  [ "$status" -eq 0 ]
  grep -F $'socket=/tmp/selected.sock\tagent\tfocus\ttarget' "$FOCUS_LOG"
  grep -F $'socket=/tmp/selected.sock\tpane\tlayout\t--pane\ttarget' "$FOCUS_LOG"
}

@test "focus-pane: already-focused one-pane tab needs no directional focus" {
  printf 'target\n' > "$FOCUS_STATE"
  run env FOCUS_MODE=one "$PYTHON_BIN" "$HELPER" \
    --socket-path /tmp/selected.sock --workspace-id ws --tab-id tab --pane-id target
  [ "$status" -eq 0 ]
  ! grep -F $'pane\tfocus\t--direction' "$FOCUS_LOG"
}

@test "focus-pane: ordinary vertical split follows one neighbor edge" {
  run_focus
  [ "$status" -eq 0 ]
  grep -F $'pane\tneighbor\t--pane\tp1\t--direction\tdown' "$FOCUS_LOG"
  grep -F $'pane\tfocus\t--direction\tdown\t--pane\tp1' "$FOCUS_LOG"
  [ "$(cat "$FOCUS_STATE")" = target ]
}

@test "focus-pane: deterministic BFS traverses a multi-hop layout" {
  run env FOCUS_MODE=multihop "$PYTHON_BIN" "$HELPER" \
    --socket-path /tmp/selected.sock --workspace-id ws --tab-id tab --pane-id target
  [ "$status" -eq 0 ]
  grep -F $'pane\tfocus\t--direction\tright\t--pane\tp1' "$FOCUS_LOG"
  grep -F $'pane\tfocus\t--direction\tright\t--pane\tp2' "$FOCUS_LOG"
  [ "$(cat "$FOCUS_STATE")" = target ]
}

@test "focus-pane: stale route fails before any focus mutation" {
  run env FOCUS_MODE=stale "$PYTHON_BIN" "$HELPER" \
    --socket-path /tmp/selected.sock --workspace-id ws --tab-id tab --pane-id target
  [ "$status" -eq 1 ]
  [[ "$output" == *"pane route is stale"* ]]
  ! grep -E $'\t(workspace|tab|agent|pane)\tfocus' "$FOCUS_LOG"
}

@test "focus-pane: non-agent operational error is not treated as ordinary pane" {
  run env FOCUS_MODE=agent-error "$PYTHON_BIN" "$HELPER" \
    --socket-path /tmp/selected.sock --workspace-id ws --tab-id tab --pane-id target
  [ "$status" -eq 1 ]
  [[ "$output" == *"agent get failed"* ]]
  ! grep -F $'workspace\tfocus' "$FOCUS_LOG"
}

@test "focus-pane: malformed layout fails cleanly" {
  run env FOCUS_MODE=malformed "$PYTHON_BIN" "$HELPER" \
    --socket-path /tmp/selected.sock --workspace-id ws --tab-id tab --pane-id target
  [ "$status" -eq 1 ]
  [[ "$output" == *"pane layout"* ]]
}

@test "focus-pane: unexpected directional landing is bounded and reported" {
  run env FOCUS_MODE=wrong-focus "$PYTHON_BIN" "$HELPER" \
    --socket-path /tmp/selected.sock --workspace-id ws --tab-id tab --pane-id target
  [ "$status" -eq 1 ]
  [[ "$output" == *"kept changing after one replan"* ]]
}

@test "focus-pane: preview decodes the route and rereads visible content" {
  token=$(make_token)
  run "$PYTHON_BIN" "$HELPER" --preview-route-token "$token"
  [ "$status" -eq 0 ]
  [[ "$output" == *"default/ws/tab/target"* ]]
  [[ "$output" == *"match: stored match"* ]]
  [[ "$output" == *"live pane content"* ]]
  grep -F $'socket=/tmp/selected.sock\tpane\tread\ttarget\t--source\tvisible' "$FOCUS_LOG"
}

@test "focus-pane: final verification requires globally active workspace and tab" {
  run env FOCUS_MODE=inactive-final "$PYTHON_BIN" "$HELPER" \
    --socket-path /tmp/selected.sock --workspace-id ws --tab-id tab --pane-id target
  [ "$status" -eq 1 ]
  [[ "$output" == *"workspace/tab is not active"* ]]
}

@test "focus-pane: malformed route token is usage exit 2 without traceback" {
  run "$PYTHON_BIN" "$HELPER" --route-token not-base64
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid route token"* ]]
  [[ "$output" != *"Traceback"* ]]
}

@test "focus-pane: boolean schema and line numbers are rejected" {
  token=$("$PYTHON_BIN" -c '
import base64, json
payload = {"schema_version": True, "socket_path": "/tmp/s", "workspace_id": "w", "tab_id": "t", "pane_id": "p", "line_number": True}
print(base64.urlsafe_b64encode(json.dumps(payload).encode()).decode().rstrip("="))
')
  run "$PYTHON_BIN" "$HELPER" --route-token "$token"
  [ "$status" -eq 2 ]
  [[ "$output" == *"integer schema_version 1"* ]]
}
