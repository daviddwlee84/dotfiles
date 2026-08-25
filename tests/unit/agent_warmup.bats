#!/usr/bin/env bats

load "../test_helper.bash"

SCRIPT="$REPO_ROOT/dot_dotfiles/bin/executable_agent-warmup"

@test "Tyro exposes commands and backend flags" {
  run uv run --quiet --no-project --script "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"{run,at,install,uninstall,status,cancel,verify}"* ]]
  run uv run --quiet --no-project --script "$SCRIPT" run --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--backend {auto,tmux,herdr}"* ]]
  [[ "$output" == *"--herdr-session"* ]]
}

@test "scheduled payload round-trips without importing Tyro" {
  run python3 - "$SCRIPT" <<'PY'
import importlib.machinery, importlib.util, sys
spec=importlib.util.spec_from_loader("warmup",importlib.machinery.SourceFileLoader("warmup",sys.argv[1]))
m=importlib.util.module_from_spec(spec);sys.modules[spec.name]=m;spec.loader.exec_module(m)
r=m.Run(model="haiku",prompt="hi",backend="herdr",herdr_session="default")
assert m._decode_run_spec(m._encode_run_spec(r)) == r
assert "tyro" not in sys.modules
PY
  [ "$status" -eq 0 ]
}

@test "missing uv takes direct fallback exactly once" {
  run python3 - "$SCRIPT" <<'PY'
import importlib.machinery, importlib.util, os, sys, tempfile
spec=importlib.util.spec_from_loader("warmup",importlib.machinery.SourceFileLoader("warmup",sys.argv[1]))
m=importlib.util.module_from_spec(spec);sys.modules[spec.name]=m;spec.loader.exec_module(m)
os.environ["XDG_CACHE_HOME"]=tempfile.mkdtemp()
m.shutil.which=lambda name: None
calls=[]
m.cmd_run=lambda run:(calls.append(run) or 7)
p=m._encode_run_spec(m.Run(backend="tmux"))
assert m._scheduled_bootstrap(p)==7
assert len(calls)==1 and os.environ["AGENT_WARMUP_RUNTIME"]=="direct-fallback"
PY
  [ "$status" -eq 0 ]
}

@test "scheduled argv uses hidden bootstrap" {
  run python3 - "$SCRIPT" <<'PY'
import importlib.machinery, importlib.util, sys
spec=importlib.util.spec_from_loader("warmup",importlib.machinery.SourceFileLoader("warmup",sys.argv[1]))
m=importlib.util.module_from_spec(spec);sys.modules[spec.name]=m;spec.loader.exec_module(m)
m._resolve_backend=lambda spec:("tmux",None)
argv=m._run_argv(m.At(delay="5m"))
assert argv[2]=="__scheduled-run" and argv[0].endswith("python3"), argv
PY
  [ "$status" -eq 0 ]
}

@test "Herdr warmup creates no-focus workspace and cleans only its workspace" {
  run python3 - "$SCRIPT" <<'PY'
import importlib.machinery, importlib.util, json, os, subprocess, sys, tempfile
spec=importlib.util.spec_from_loader("warmup",importlib.machinery.SourceFileLoader("warmup",sys.argv[1]))
m=importlib.util.module_from_spec(spec);sys.modules[spec.name]=m;spec.loader.exec_module(m)
os.environ["XDG_CACHE_HOME"]=tempfile.mkdtemp()
m.shutil.which=lambda name:f"/stub/{name}"
calls=[]
def herdr(session,*args,**kwargs):
    calls.append((session,*args))
    if args[:2]==("workspace","create"):
        data={"result":{"root_pane":{"workspace_id":"ws-new","pane_id":"pane-new"},"workspace":{"workspace_id":"ws-new"}}}
    elif args[:2]==("pane","process-info"):
        data={"result":{"process_info":{"foreground_processes":[{"name":"zsh"}]}}}
    else:
        data={"result":{"type":"ok"}}
    return subprocess.CompletedProcess([],0,json.dumps(data),"")
m._herdr=herdr
m._wait_herdr_ready=lambda *a:(True,"ready")
m._wait_herdr_response=lambda *a:"reply"
assert m._run_herdr(m.Run(backend="herdr"),"default")==0
create=next(call for call in calls if call[1:3]==("workspace","create"))
assert "--no-focus" in create and ("default","workspace","close","ws-new") in calls, calls
assert all(call[-1] != "ws-existing" for call in calls)
PY
  [ "$status" -eq 0 ]
}
