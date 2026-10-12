"""Offline integration tests for real subprocesses, settings, pins and signals."""
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "dot_config/shell/copilot-session.py"
SPEC = importlib.util.spec_from_file_location("copilot_session", HELPER)
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        self.project = self.root / "project"
        self.project.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = {**os.environ, "HOME": str(self.home),
                    "XDG_STATE_HOME": str(self.root / "state"),
                    "XDG_CONFIG_HOME": str(self.root / "config"),
                    "XDG_CACHE_HOME": str(self.root / "cache"),
                    "COPILOT_SESSION_HELPER": str(HELPER),
                    "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
                    "SYNC_LOG": str(self.root / "sync.log"),
                    "START_LOG": str(self.root / "start.log")}
        self.cwd = Path.cwd()
        os.chdir(self.project)
        self.patch = patch.dict(os.environ, self.env)
        self.patch.start()
        self.processes = []
        self.fake("specstory", """
import json,os,sys,time
from pathlib import Path
if sys.argv[1] == 'sync':
    log=Path(os.environ['SYNC_LOG'])
    with log.open('a') as out: out.write(json.dumps({'cwd':os.getcwd(),'provider':sys.argv[2]})+'\\n')
    time.sleep(float(os.environ.get('SYNC_DELAY','0')))
    sys.exit(int(os.environ.get('SYNC_RC','0')))
if sys.argv[1] == 'run':
    import shlex
    argv=shlex.split(sys.argv[4])
    os.execvpe(argv[0],argv,os.environ)
""")
        self.fake("claude", """
import json,os,sys,time
from pathlib import Path
Path(os.environ['START_LOG']).write_text(json.dumps(sys.argv[1:]))
if os.environ.get('MODEL_PICK'):
    settings=Path(os.environ['HOME'])/'.claude/settings.json'
    old=json.loads(settings.read_text()) if settings.exists() else {}
    old.update(model=os.environ['MODEL_PICK'],other='changed')
    settings.write_text(json.dumps(old))
time.sleep(float(os.environ.get('AGENT_DELAY','0')))
sys.exit(int(os.environ.get('AGENT_RC','0')))
""")

    def tearDown(self):
        for proc in self.processes:
            if proc.poll() is None:
                proc.kill()
            proc.communicate(timeout=3)
        self.patch.stop()
        os.chdir(self.cwd)
        self.tmp.cleanup()

    def fake(self, name, source):
        path = self.bin / name
        path.write_text(f"#!{sys.executable}\n" + source)
        path.chmod(0o755)
        return path

    def config(self, text, user=False):
        path = (self.home if user else self.project) / ".specstory/cli/config.toml"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def proc(self, provider="claude", mode="exit", args=(), **env):
        prepared = M.inspect(provider, mode, list(args))
        proc = subprocess.Popen([sys.executable, str(HELPER), "launch", provider,
                                 mode, json.dumps(prepared), "{}" if provider == "claude" else "[]"],
                                env={**self.env, **env}, cwd=self.project,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.processes.append(proc)
        return proc

    def wait_file(self, path, proc=None):
        end = time.monotonic() + 5
        while time.monotonic() < end:
            if path.exists():
                return
            if proc and proc.poll() is not None:
                self.fail(proc.communicate())
            time.sleep(.02)
        self.fail(f"timed out waiting for {path}")

    def pending(self):
        return list((self.root / "state").rglob("*.pending.json"))

    def shell_launch(self, shell, args, **env):
        script = r'''
source "$1"; shift
_copilot_alive() { return 0; }
_copilot_require_shim() { return 0; }
_copilot_default_model() { printf gpt-default; }
_copilot_model_catalog() { printf ''; }
_copilot_fast_model_for() { printf '%s-fast' "$1"; }
_copilot_env_json_for_model() {
  jq -nc --arg model "$2" '{ANTHROPIC_MODEL:$model,ANTHROPIC_BASE_URL:"http://localhost:4142",ANTHROPIC_AUTH_TOKEN:"dummy"}'
}
claude-copilot-once "$@"
'''
        return subprocess.run([shell, "-c", script, "_",
                               str(ROOT / "dot_config/shell/43_copilot_proxy.sh"), *args],
                              env={**self.env, **env}, cwd=self.project,
                              capture_output=True, text=True, timeout=8)

    def test_bash_zsh_once_preserves_pin_and_merges_user_settings_in_all_modes(self):
        target = self.project / ".claude/settings.local.json"
        target.parent.mkdir()
        baseline = '{"env":{"ANTHROPIC_BASE_URL":"http://old-pin","ANTHROPIC_MODEL":"gpt-old"}}'
        target.write_text(baseline)
        for shell in ("bash", "zsh"):
            for mode in ("run", "exit", "off"):
                with self.subTest(shell=shell, mode=mode):
                    result = self.shell_launch(shell, ["--specstory-mode", mode, "--fast",
                                                      "--settings", '{"ultracode":true,"model":"gpt-explicit"}',
                                                      "-p", "two words"])
                    self.assertEqual(result.returncode, 0, result.stderr)
                    args = json.loads(Path(self.env["START_LOG"]).read_text())
                    self.assertEqual(args.count("--settings"), 1)
                    settings = json.loads(args[args.index("--settings") + 1])
                    self.assertTrue(settings["ultracode"])
                    self.assertEqual(settings["env"]["ANTHROPIC_MODEL"], "gpt-explicit-fast")
                    self.assertEqual(args[-2:], ["--model", "gpt-explicit-fast"])
                    self.assertEqual(target.read_text(), baseline)
                    self.assertNotIn("Update", result.stderr)

    def test_model_picker_guard_retains_unrelated_changes_and_exit_code(self):
        settings = self.home / ".claude/settings.json"
        settings.parent.mkdir()
        for initial, picked, expected in (({}, "gpt-test", None),
                                         ({"model": "sonnet"}, "gpt-test", "sonnet"),
                                         ({"model": "sonnet"}, "opus", "opus")):
            settings.write_text(json.dumps(initial))
            result = self.shell_launch("bash", ["--no-specstory"], MODEL_PICK=picked, AGENT_RC="7")
            self.assertEqual(result.returncode, 7, result.stderr)
            data = json.loads(settings.read_text())
            self.assertEqual(data.get("model"), expected)
            self.assertEqual(data["other"], "changed")

    def test_once_alias_and_fast_boundary(self):
        for shell in ("bash", "zsh"):
            result = self.shell_launch(shell, ["--no-specstory", "--resume", "id", "--fast"])
            self.assertEqual(result.returncode, 2)
            self.assertIn("must come before", result.stderr)
            result = self.shell_launch(shell, ["--no-specstory", "-p", "--", "--fast"])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(Path(self.env["START_LOG"]).read_text())[-2:], ["--", "--fast"])

    def test_toml_precedence_and_escaped_commands(self):
        self.config('[providers]\nclaude_cmd="claude --verbose"\n', user=True)
        self.config('[providers]\nclaude_cmd = """claude --model \\"two words\\""""\n')
        self.assertEqual(M.inspect("claude", "run", [])["model"], "two words")
        self.assertIn("--verbose", M.inspect("claude", "off", ["--verbose"])["argv"])
        self.assertNotIn("--model", M.inspect("claude", "off", [])["argv"])

    def test_settings_last_wins_then_deep_merges_with_wrapper(self):
        path = self.project / "custom.json"
        path.write_text(json.dumps({"ultracode": True, "env": {"EXTRA": "kept"},
                                    "model": "explicit", "permissions": {"defaultMode": "plan"}}))
        plan = M.inspect("claude", "off", ["--settings", '{"discarded":true}',
                                         "--settings", str(path)])
        self.assertEqual(plan["model"], "explicit")
        self.assertNotIn("--dangerously-skip-permissions", plan["argv"])
        self.assertNotIn("discarded", plan["settings"])
        with patch.object(M, "run_session", return_value=0) as run:
            M.launch("claude", "off", plan, {"ANTHROPIC_BASE_URL": "http://localhost:1"})
        argv = run.call_args.args[2]
        self.assertEqual(argv.count("--settings"), 1)
        settings = json.loads(argv[2])
        self.assertTrue(settings["ultracode"])
        self.assertEqual(settings["env"]["EXTRA"], "kept")
        self.assertEqual(settings["env"]["ANTHROPIC_BASE_URL"], "http://localhost:1")

    def test_settings_permission_overrides_configured_bypass(self):
        self.config('[providers]\nclaude_cmd="claude --dangerously-skip-permissions"\n')
        for args in (["--permission-mode", "plan"],
                     ["--settings", '{"permissions":{"defaultMode":"plan"}}']):
            plan = M.inspect("claude", "run", args)
            self.assertNotIn("--dangerously-skip-permissions", plan["argv"])

    def test_explicit_codex_axes_and_model_win_over_config(self):
        self.config('[providers]\ncodex_cmd=\'codex -m configured -a never -s danger-full-access\'\n')
        plan = M.inspect("codex", "exit", ["--model", "explicit", "-c", 'approval_policy="on-request"',
                                         "--sandbox", "read-only"])
        self.assertEqual(plan["model"], "explicit")
        self.assertNotIn("danger-full-access", plan["argv"])
        self.assertNotIn("never", plan["argv"])

    def test_prompt_data_is_not_settings_or_policy(self):
        plan = M.inspect("claude", "off", ["--append-system-prompt", "--permission-mode",
                                         "--", "--settings", "missing.json"])
        self.assertIn("--dangerously-skip-permissions", plan["argv"])
        self.assertEqual(plan["argv"][-3:], ["--", "--settings", "missing.json"])

    def test_invalid_settings_and_dangling_codex_config_fail(self):
        with self.assertRaises(M.Error):
            M.inspect("claude", "off", ["--settings", "{"])
        self.config('[providers]\ncodex_cmd="codex -c --ask-for-approval never"\n')
        with self.assertRaises(M.Error):
            M.inspect("codex", "exit", [])

    def test_resume_picker_and_environment_command_prefix(self):
        self.config('[providers]\nclaude_cmd="env MY_PROFILE=kept claude --verbose"\n')
        prepared = M.inspect("claude", "run", ["--resume"])
        self.assertEqual(prepared["head"], 3)
        self.assertEqual(prepared["argv"][:3], ["env", "MY_PROFILE=kept", "claude"])
        proc = self.proc(mode="run", args=["--resume"])
        _, error = proc.communicate(timeout=5)
        self.assertEqual(proc.returncode, 0, error)
        self.assertIn("--resume", json.loads(Path(self.env["START_LOG"]).read_text()))

    def test_codex_cd_syncs_from_effective_project(self):
        nested = self.project / "nested"
        nested.mkdir()
        self.fake("codex", "import os\nfrom pathlib import Path\nPath(os.environ['START_LOG']).write_text(os.getcwd())\n")
        proc = self.proc(provider="codex", args=["--cd", "nested"])
        _, error = proc.communicate(timeout=5)
        self.assertEqual(proc.returncode, 0, error)
        self.assertEqual(Path(self.env["START_LOG"]).read_text(), str(nested))
        self.assertEqual(json.loads(Path(self.env["SYNC_LOG"]).read_text())["cwd"], str(nested))

    def test_compound_default_preserves_unoverridden_axis(self):
        self.config('[providers]\ncodex_cmd="codex --full-auto"\n')
        prepared = M.inspect("codex", "exit", ["--ask-for-approval", "never"])
        self.assertIn("workspace-write", prepared["argv"])
        self.assertNotIn("on-request", prepared["argv"])

    def test_exit_rejects_background_and_ephemeral(self):
        for provider, flag in (("claude", "--bg"), ("claude", "--no-session-persistence"),
                               ("codex", "--ephemeral"), ("codex", "--worktree")):
            with self.assertRaises(M.Error):
                M.validate_exit(provider, [flag])

    def test_agent_exit_code_and_sync_only_after_exit(self):
        proc = self.proc(AGENT_DELAY=".3", AGENT_RC="7")
        self.wait_file(Path(self.env["START_LOG"]), proc)
        self.assertFalse(Path(self.env["SYNC_LOG"]).exists())
        _, error = proc.communicate(timeout=5)
        self.assertEqual(proc.returncode, 7, error)
        self.assertTrue(Path(self.env["SYNC_LOG"]).exists())
        self.assertFalse(self.pending())

    def test_run_preserves_empty_backslash_and_multiline_argv(self):
        args = ["-p", "", "back\\slash 'quotes'", "line1\nline2", "--", "--settings"]
        proc = self.proc(mode="run", args=args)
        _, error = proc.communicate(timeout=5)
        self.assertEqual(proc.returncode, 0, error)
        observed = json.loads(Path(self.env["START_LOG"]).read_text())
        self.assertEqual(observed[-len(args):], args)
        self.assertFalse(Path(self.env["SYNC_LOG"]).exists())

    def test_failed_sync_is_retried_before_next_agent(self):
        proc = self.proc(SYNC_RC="4")
        proc.communicate(timeout=5)
        self.assertTrue(self.pending())
        proc = self.proc(mode="off", AGENT_DELAY=".3")
        self.wait_file(Path(self.env["SYNC_LOG"]))
        proc.communicate(timeout=5)
        self.assertFalse(self.pending())
        self.assertEqual(len(Path(self.env["SYNC_LOG"]).read_text().splitlines()), 2)

    def test_sync_timeout_retains_pending_and_recovery_succeeds(self):
        directory = M.group_dir(self.project)
        M.write_json(directory / "claude.pending.json", {"provider": "claude"})
        with patch.object(M, "SYNC_TIMEOUT", .2), patch.dict(os.environ, {"SYNC_DELAY": "5"}):
            M.sync_pending(directory, "claude", self.project)
        self.assertTrue(self.pending())
        M.sync_pending(directory, "claude", self.project)
        self.assertFalse(self.pending())

    def test_concurrent_session_defers_until_last_exit(self):
        first = self.proc(AGENT_DELAY=".7")
        self.wait_file(Path(self.env["START_LOG"]), first)
        second = self.proc(AGENT_DELAY=".1")
        second.communicate(timeout=5)
        self.assertFalse(Path(self.env["SYNC_LOG"]).exists())
        first.communicate(timeout=5)
        self.assertEqual(len(Path(self.env["SYNC_LOG"]).read_text().splitlines()), 1)

    def test_term_finishes_then_syncs(self):
        proc = self.proc(AGENT_DELAY="5")
        self.wait_file(Path(self.env["START_LOG"]), proc)
        proc.terminate()
        proc.communicate(timeout=5)
        self.assertEqual(proc.returncode, 143)
        self.assertFalse(self.pending())

    def test_hup_restores_model_after_agent_stops(self):
        settings = self.home / ".claude/settings.json"
        settings.parent.mkdir()
        settings.write_text('{"model":"sonnet"}')
        proc = self.proc(AGENT_DELAY="5", MODEL_PICK="gpt-test")
        self.wait_file(Path(self.env["START_LOG"]), proc)
        end = time.monotonic() + 3
        while json.loads(settings.read_text()).get("model") != "gpt-test" and time.monotonic() < end:
            time.sleep(.02)
        proc.send_signal(signal.SIGHUP)
        proc.communicate(timeout=5)
        self.assertEqual(proc.returncode, 129)
        self.assertEqual(json.loads(settings.read_text()), {"model": "sonnet", "other": "changed"})

    def test_sigkill_retains_live_agent_lease_and_pending(self):
        self.fake("claude", """
import os,time
from pathlib import Path
Path(os.environ['START_LOG']).write_text(str(os.getpid()))
time.sleep(1)
""")
        proc = self.proc()
        self.wait_file(Path(self.env["START_LOG"]), proc)
        proc.kill()
        proc.communicate(timeout=3)  # Child holds inherited pipes until it exits.
        self.assertTrue(self.pending())
        next_proc = self.proc(mode="off")
        next_proc.communicate(timeout=5)
        self.assertFalse(self.pending())

    def test_pty_repeated_ctrl_c_during_sync(self):
        prepared = M.inspect("claude", "exit", [])
        pid, fd = pty.fork()
        if pid == 0:
            os.environ.update(self.env)
            os.environ["SYNC_DELAY"] = ".5"
            os.execv(sys.executable, [sys.executable, str(HELPER), "launch", "claude",
                                     "exit", json.dumps(prepared), "{}"])
        collected = b""
        status = None
        done = 0
        sent = False
        try:
            deadline = time.monotonic() + 6
            while time.monotonic() < deadline:
                ready, _, _ = select.select([fd], [], [], .03)
                if ready:
                    try:
                        collected += os.read(fd, 8192)
                    except OSError:
                        break
                if not sent and b"syncing saved sessions" in collected:
                    os.write(fd, b"\x03\x03\x03")
                    sent = True
                done, status = os.waitpid(pid, os.WNOHANG)
                if done:
                    break
            else:
                self.fail("PTY supervisor hung")
            if status is None or not done:
                _, status = os.waitpid(pid, 0)
            self.assertEqual(os.waitstatus_to_exitcode(status), 0, collected)
            self.assertFalse(self.pending())
        finally:
            os.close(fd)
            with contextlib.suppress(ProcessLookupError, ChildProcessError):
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)

    def test_raw_terminal_first_ctrl_c_cancels_second_exits(self):
        self.fake("claude", """
import os,tty
tty.setraw(0)
os.write(1,b'AGENT_READY')
assert os.read(0,1)==b'\x03'
os.write(1,b'TURN_CANCELLED')
assert os.read(0,1)==b'\x03'
# Deliberately leave raw mode behind: the supervisor restores the terminal.
""")
        prepared = M.inspect("claude", "exit", [])
        pid, fd = pty.fork()
        if pid == 0:
            os.environ.update(self.env)
            os.execv(sys.executable, [sys.executable, str(HELPER), "launch", "claude",
                                     "exit", json.dumps(prepared), "{}"])
        def read_until(marker):
            output = b""
            end = time.monotonic() + 4
            while marker not in output and time.monotonic() < end:
                if select.select([fd], [], [], .05)[0]:
                    output += os.read(fd, 8192)
            self.assertIn(marker, output)
        try:
            read_until(b"AGENT_READY")
            os.write(fd, b"\x03")
            read_until(b"TURN_CANCELLED")
            self.assertFalse(Path(self.env["SYNC_LOG"]).exists())
            os.write(fd, b"\x03")
            read_until(b"sync complete")
            import termios
            self.assertTrue(termios.tcgetattr(fd)[3] & termios.ISIG)
            _, status = os.waitpid(pid, 0)
            self.assertEqual(os.waitstatus_to_exitcode(status), 0)
        finally:
            os.close(fd)
            with contextlib.suppress(ProcessLookupError, ChildProcessError):
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)


class PinTests(unittest.TestCase):
    setUp = SessionTests.setUp
    tearDown = SessionTests.tearDown
    fake = SessionTests.fake
    def desired(self):
        return {"ANTHROPIC_BASE_URL": "http://localhost:4142",
                "ANTHROPIC_AUTH_TOKEN": "dummy", "ANTHROPIC_MODEL": "fixture"}

    def pin_call(self, action="on", yes=False):
        desired = self.desired()
        return M.pin(action, desired, list(desired), yes)

    def test_pin_fresh_unchanged_conflict_and_restore(self):
        target = self.project / ".claude/settings.local.json"
        self.assertEqual(self.pin_call(), 0)
        first = target.stat().st_mtime_ns
        self.assertEqual(self.pin_call(), 0)
        self.assertEqual(first, target.stat().st_mtime_ns)
        data = json.loads(target.read_text())
        data["env"]["ANTHROPIC_MODEL"] = "manual"
        data["plansDirectory"] = "plans"
        target.write_text(json.dumps(data))
        with patch("sys.stdin.isatty", return_value=False):
            self.assertEqual(self.pin_call(), 1)
        self.assertEqual(self.pin_call("off"), 0)
        self.assertEqual(json.loads(target.read_text()), {"plansDirectory": "plans",
                                                        "env": {"ANTHROPIC_MODEL": "manual"}})

    def test_pin_user_confirmation_and_yes_update(self):
        self.pin_call()
        with patch.object(self, "desired", return_value={"ANTHROPIC_MODEL": "new",
                                                         "ANTHROPIC_BASE_URL": "http://localhost:4"}):
            with patch("sys.stdin.isatty", return_value=True), patch("builtins.input", return_value="n"):
                self.assertEqual(self.pin_call(), 1)
            with patch("sys.stdin.isatty", return_value=True), patch("builtins.input", return_value="y"):
                self.assertEqual(self.pin_call(), 0)
        self.assertEqual(self.pin_call(yes=True), 0)

    def test_foreign_proxy_fields_are_restored_not_adopted_as_legacy(self):
        target = self.project / ".claude/settings.local.json"
        target.parent.mkdir()
        original = {"env": {"ANTHROPIC_BASE_URL": "http://original",
                            "ANTHROPIC_AUTH_TOKEN": "original-private-value",
                            "ANTHROPIC_MODEL": "sonnet"}, "plansDirectory": "plans"}
        target.write_text(json.dumps(original))
        import io
        output = io.StringIO()
        with contextlib.redirect_stderr(output):
            self.assertEqual(self.pin_call(yes=True), 0)
        self.assertNotIn("original-private-value", output.getvalue())
        self.assertEqual(self.pin_call("off"), 0)
        self.assertEqual(json.loads(target.read_text()), original)

    def test_tracked_and_staged_files_refused_even_with_yes(self):
        subprocess.run(["git", "init", "-q"], check=True)
        target = self.project / ".claude/settings.local.json"
        target.parent.mkdir()
        target.write_text('{"plansDirectory":"plans"}')
        subprocess.run(["git", "add", str(target)], check=True)
        with self.assertRaisesRegex(M.Error, "tracked/staged"):
            self.pin_call(yes=True)
        self.assertEqual(target.read_text(), '{"plansDirectory":"plans"}')

    def test_existing_unignored_file_needs_confirmation(self):
        subprocess.run(["git", "init", "-q"], check=True)
        target = self.project / ".claude/settings.local.json"
        target.parent.mkdir()
        target.write_text('{"plansDirectory":"plans"}')
        with patch("sys.stdin.isatty", return_value=False):
            self.assertEqual(self.pin_call(), 1)
        self.assertEqual(self.pin_call(yes=True), 0)
        self.assertEqual(subprocess.run(["git", "check-ignore", "-q", str(target)]).returncode, 0)
        self.pin_call("off")
        self.assertEqual(json.loads(target.read_text()), {"plansDirectory": "plans"})

    def test_worktree_exclude_uses_git_resolved_path(self):
        subprocess.run(["git", "init", "-q"], check=True)
        subprocess.run(["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                        "-c", "core.hooksPath=/dev/null", "commit", "--allow-empty", "-qm", "test"], check=True)
        worktree = self.root / "worktree"
        subprocess.run(["git", "worktree", "add", "-q", "-b", "test-pin", str(worktree)], check=True)
        os.chdir(worktree)
        self.assertEqual(self.pin_call(), 0)
        self.assertEqual(subprocess.run(["git", "check-ignore", "-q",
                                        ".claude/settings.local.json"]).returncode, 0)

    def test_nested_directory_glob_characters_are_ignored_literally(self):
        subprocess.run(["git", "init", "-q"], check=True)
        nested = self.project / "project [one]"
        nested.mkdir()
        os.chdir(nested)
        self.assertEqual(self.pin_call(), 0)
        self.assertEqual(subprocess.run(["git", "check-ignore", "-q",
                                        ".claude/settings.local.json"]).returncode, 0)


if __name__ == "__main__":
    unittest.main()
