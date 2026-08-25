#!/usr/bin/env bats

load "../test_helper.bash"

SCRIPT="$REPO_ROOT/dot_config/television/executable_agent-wakeup.py"

@test "TSV keeps legacy columns and appends backend identity" {
  run python3 - "$SCRIPT" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("wakeup", sys.argv[1])
m = importlib.util.module_from_spec(spec); sys.modules[spec.name] = m; spec.loader.exec_module(m)
r = m.PaneRec("claude", "", "sid", "/tmp", "title", "", "s:1.1", "", "○", pane_id="w1:p1", backend="herdr", backend_session="default", agent_session_id="stable-id")
m._print_tsv([r])
PY
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | awk -F '\t' '{print NF}')" -eq 16 ]
  [ "$(printf '%s\n' "$output" | cut -f14-16)" = $'herdr\tdefault\tstable-id' ]
}

@test "Herdr blocked without quota becomes WAIT_USER" {
  run python3 - "$SCRIPT" <<'PY'
import importlib.util, json, subprocess, sys
spec = importlib.util.spec_from_file_location("wakeup", sys.argv[1])
m = importlib.util.module_from_spec(spec); sys.modules[spec.name] = m; spec.loader.exec_module(m)
payload={"result":{"agents":[{"agent":"claude","agent_status":"blocked","cwd":"/tmp","pane_id":"w:p","agent_session":{"value":"stable"}}]}}
m._herdr=lambda *a: subprocess.CompletedProcess([],0,json.dumps(payload),"")
m._running_herdr_sessions=lambda: ["default"]
m.capture_target=lambda *a,**k: "Please answer the question above"
m._pueue_tasks=lambda: []
rows,_,errors=m._rows("herdr","default")
assert not errors and rows[0].state == "WAIT_USER", rows
PY
  [ "$status" -eq 0 ]
}

@test "Herdr send re-resolves identity and uses literal input steps" {
  run python3 - "$SCRIPT" <<'PY'
import argparse, importlib.util, subprocess, sys
spec = importlib.util.spec_from_file_location("wakeup", sys.argv[1])
m = importlib.util.module_from_spec(spec); sys.modules[spec.name] = m; spec.loader.exec_module(m)
r=m.PaneRec("claude","","stable","/tmp","","","old","","",pane_id="old",backend="herdr",backend_session="s",agent_session_id="stable")
m._select_target=lambda a:r
m.capture_target=lambda *a,**k:"quota reached; resets in 5m"
m._find_herdr_agent=lambda *a:m.PaneRec("claude","","stable","/tmp","","","new","","",pane_id="new",backend="herdr",backend_session="s",agent_session_id="stable")
calls=[]
m._herdr=lambda session,*args:(calls.append((session,*args)) or subprocess.CompletedProcess([],0,"",""))
a=argparse.Namespace(enter_only=False,auto=False,expect_quota=True,force=False,text="continue",dry_run=False)
assert m.cmd_send_now(a)==0
assert calls == [("s","pane","send-keys","new","ctrl+u"),("s","pane","send-text","new","continue"),("s","agent","send-keys","new","enter")], calls
PY
  [ "$status" -eq 0 ]
}
