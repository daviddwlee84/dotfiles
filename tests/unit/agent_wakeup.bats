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

@test "Herdr send re-resolves identity and atomically prompts with startup verification" {
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
assert calls == [("s","agent","prompt","new","continue","--wait","--until","working","--until","blocked","--timeout","15000")], calls
PY
  [ "$status" -eq 0 ]
}

@test "ID-less Herdr scheduling pins a process and uses distinct pane labels" {
  run python3 - "$SCRIPT" <<'PY'
import contextlib, importlib.util, io, json, shlex, subprocess, sys
spec = importlib.util.spec_from_file_location("wakeup", sys.argv[1])
m = importlib.util.module_from_spec(spec); sys.modules[spec.name] = m; spec.loader.exec_module(m)
r=m.PaneRec("codex","","","/tmp","","","w:p1","","",pane_id="w:p1",backend="herdr",backend_session="default",native_status="idle")
m._select_target=lambda a:r
m.capture_target=lambda *a,**k:"You've hit your usage limit. Try again at 8:10 AM."
m._herdr_process_identity=lambda r:"fingerprint"
m._ensure_group=lambda: (_ for _ in ()).throw(AssertionError("dry-run must not enqueue"))
a=m.build_parser().parse_args(["schedule","--pane","w:p1","--at","2026-10-25 08:11:00","--dry-run"])
out=io.StringIO()
with contextlib.redirect_stdout(out):
    assert m.cmd_schedule(a)==0
parts=shlex.split(out.getvalue())
assert parts[parts.index("--label")+1] == "agent-wakeup:herdr:default:pane:w:p1"
command=shlex.split(parts[-1])
assert "--scheduled" in command and "--expect-quota" in command
assert command[command.index("--expected-process")+1] == "fingerprint"
m.shutil.which=lambda _:"pueue"
payload={"tasks":{str(i):{"label":f"agent-wakeup:herdr:default:pane:w:p{i}","status":"Stashed"} for i in (1,2)}}
m.run=lambda *a,**k:subprocess.CompletedProcess([],0,json.dumps(payload),"")
tasks=m._pueue_tasks()
assert tasks[0].pane_id == "w:p1" and tasks[0].agent_session_id == ""
assert m._identity(r) == m._task_identity(tasks[0]) != m._task_identity(tasks[1])
r.agent_session_id="newly-reported-id"
assert m._task_matches(tasks[0], r) and not m._task_matches(tasks[1], r)
m._pueue_tasks=lambda:tasks
removed=[]
m.run=lambda args: (removed.append(args) or subprocess.CompletedProcess([],0,"",""))
assert m.cmd_cancel(a)==0
assert removed==[["pueue","remove","1"]]
r.agent_session_id=""
m._herdr_process_identity=lambda r:""
try:
    m.cmd_schedule(a)
except SystemExit as e:
    assert "refusing to schedule" in str(e)
else:
    raise AssertionError("missing identity allowed")
PY
  [ "$status" -eq 0 ]
}

@test "Herdr process fingerprint detects terminal, PID and start-time replacement" {
  run python3 - "$SCRIPT" <<'PY'
import importlib.util, json, subprocess, sys
spec = importlib.util.spec_from_file_location("wakeup", sys.argv[1])
m = importlib.util.module_from_spec(spec); sys.modules[spec.name] = m; spec.loader.exec_module(m)
r=m.PaneRec("codex","","","/tmp","","","w:p1","","",pane_id="w:p1",backend="herdr",backend_session="default")
pane={"terminal_id":"term-original"}
process={"name":"codex","pid":123,"argv":["codex"]}
info={"foreground_processes":[process,{"name":"specstory","pid":122,"argv":["specstory","run","codex"]}]}
m._herdr=lambda session,*args:subprocess.CompletedProcess([],0,json.dumps({"pane":pane} if args[1]=="get" else {"process_info":info}),"")
start="Sun Oct 25 03:00:00 2026"
m.run=lambda *a,**k:subprocess.CompletedProcess([],0,start,"")
original=m._herdr_process_identity(r)
assert len(original)==64
assert m._herdr_process_identity(r)==original
start="Sun Oct 25 04:00:00 2026"
assert m._herdr_process_identity(r)!=original
start="Sun Oct 25 03:00:00 2026"
process["pid"]=124
assert m._herdr_process_identity(r)!=original
process["pid"]=123
pane["terminal_id"]="term-new"
assert m._herdr_process_identity(r)!=original
info["foreground_processes"]=info["foreground_processes"][1:]
assert m._herdr_process_identity(r)=="", "wrapper alone is not agent identity"
info["foreground_processes"]=[process]
m.run=lambda *a,**k:subprocess.CompletedProcess([],1,"","")
assert m._herdr_process_identity(r)==""
PY
  [ "$status" -eq 0 ]
}

@test "Scheduled Herdr sends fail closed on replacement, missing guard and unsafe state" {
  run python3 - "$SCRIPT" <<'PY'
import importlib.util, subprocess, sys
spec = importlib.util.spec_from_file_location("wakeup", sys.argv[1])
m = importlib.util.module_from_spec(spec); sys.modules[spec.name] = m; spec.loader.exec_module(m)
r=m.PaneRec("codex","","","/tmp","","","w:p1","","",pane_id="w:p1",backend="herdr",backend_session="default",native_status="idle")
m._select_target=lambda a:r
m._find_herdr_agent=lambda *a:r
capture="You've hit your usage limit. Try again at 8:10 AM."
m.capture_target=lambda *a,**k:capture
calls=[]
m._herdr=lambda session,*args:(calls.append(args) or subprocess.CompletedProcess([],0,"",""))
a=m.build_parser().parse_args(["send-now","--scheduled","--expected-process","original","--expect-quota"])
for fingerprint in ("changed", ""):
    m._herdr_process_identity=lambda r:fingerprint
    a.force=True
    assert m.cmd_send_now(a)==3 and not calls
a.force=False
m._herdr_process_identity=lambda r:"original"
for state in ("working","blocked","unknown",""):
    r.native_status=state
    assert m.cmd_send_now(a)==3 and not calls
r.native_status="idle"
a.expected_process=None
assert m.cmd_send_now(a)==3 and not calls
a.expected_process="original"
capture="old quota reached\n" + "normal output\n" * 30
assert m.cmd_send_now(a)==3 and not calls
capture="You've hit your usage limit. Try again at 8:10 AM."
assert m.cmd_send_now(a)==0
assert calls==[("agent","prompt","w:p1","continue","--wait","--until","working","--until","blocked","--timeout","15000")]
calls.clear()
r.native_status="blocked"
a.auto=True
capture="old quota reached\n" + "normal output\n" * 30 + "What do you want to do?\n1. Yes\n2. No"
assert m.cmd_send_now(a)==3 and not calls
capture="quota reached\n/rate-limit-options\nStop and wait for limit to reset"
assert m.cmd_send_now(a)==0
assert calls==[("agent","send-keys","w:p1","enter")]
PY
  [ "$status" -eq 0 ]
}

@test "Herdr prompt failures never retry or fall back to raw Enter" {
  run python3 - "$SCRIPT" <<'PY'
import contextlib, importlib.util, io, subprocess, sys
spec = importlib.util.spec_from_file_location("wakeup", sys.argv[1])
m = importlib.util.module_from_spec(spec); sys.modules[spec.name] = m; spec.loader.exec_module(m)
r=m.PaneRec("codex","","stable","/tmp","","","w:p1","","",pane_id="w:p1",backend="herdr",backend_session="named",agent_session_id="stable",native_status="idle")
m._select_target=lambda a:r
m._find_herdr_agent=lambda *a:r
m.capture_target=lambda *a,**k:"ready"
a=m.build_parser().parse_args(["send-now","--text","literal 'text'\nsecond line"])
for error in ("agent_prompt_stalled", "timeout", "agent_blocked"):
    calls=[]
    m._herdr=lambda session,*args:(calls.append((session,*args)) or subprocess.CompletedProcess([],1,"",error))
    out=io.StringIO()
    with contextlib.redirect_stdout(out):
        assert m.cmd_send_now(a)==1
    assert not out.getvalue() and len(calls)==1
    assert calls[0][:4]==("named","agent","prompt","w:p1")
    assert calls[0][4]==a.text
calls=[]
a.dry_run=True
out=io.StringIO()
with contextlib.redirect_stdout(out):
    assert m.cmd_send_now(a)==0
assert not calls and "herdr --session named agent prompt" in out.getvalue()
PY
  [ "$status" -eq 0 ]
}
