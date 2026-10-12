"""dev-projects contracts, using temporary Git repos/configs and fake providers.

Run: python3 -m unittest discover -s tests/unit -p test_dev_projects.py -v
The optional native Sidecar test also isolates HOME, config, state and tmux.
"""

import json
from importlib.machinery import SourceFileLoader
import io
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import types
import unittest
from unittest import mock


REPO = Path(__file__).resolve().parents[2]
HELPER = REPO / "dot_dotfiles/bin/executable_dev-projects"
NATIVE_SIDECAR = shutil.which("sidecar")

FAKE_DEV = r'''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
count_file = pathlib.Path(os.environ["PROBE_COUNT"])
count = int(count_file.read_text()) + 1 if count_file.exists() else 1
count_file.write_text(str(count))
if os.environ.get("FAIL_DEV"):
    print("private provider failure details", file=sys.stderr)
    sys.exit(17)
if os.environ.get("MALFORMED_DEV"):
    print(os.environ["MALFORMED_DEV"])
    sys.exit(0)
if os.environ.get("DEV_ENV_RECORD"):
    pathlib.Path(os.environ["DEV_ENV_RECORD"]).write_text(json.dumps(dict(os.environ)))
if count == 2 and os.environ.get("REPLACE_REPO"):
    path = pathlib.Path(os.environ["REPLACE_REPO"])
    path.rename(str(path) + "-old")
    path.mkdir()
    subprocess.run(["git", "init", "-q", str(path)], check=True)
print(pathlib.Path(os.environ["DEV_ROWS"]).read_text())
'''

FAKE_SIDECAR = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
if args[:1] == ["--project"]:
    pathlib.Path(os.environ["LAUNCH_RECORD"]).write_text(json.dumps({"argv": args, "cwd": os.getcwd()}))
    if os.environ.get("EXEC_ENV_RECORD"):
        pathlib.Path(os.environ["EXEC_ENV_RECORD"]).write_text(json.dumps(dict(os.environ)))
    sys.exit(0)
assert args[0] == "--config", args
path = pathlib.Path(args[1])
doc = json.loads(path.read_text()) if path.exists() else {}
projects = doc.get("projects", {}).get("list", [])
if args[2:4] == ["project", "list"]:
    print(json.dumps({"projects": projects, "aligned": False}))
elif args[2:4] == ["project", "add"]:
    with open(os.environ["WRITE_RECORD"], "a") as f:
        f.write(json.dumps(args) + "\n")
    name = args[4]
    if os.environ.get("FAIL_ADD") == name:
        print("private configuration content", file=sys.stderr)
        sys.exit(1)
    project_path = args[args.index("--path") + 1]
    if any(p["name"].casefold() == name.casefold() or p["path"] == project_path for p in projects):
        sys.exit(5)
    projects.append({"name": name, "path": project_path})
    doc.setdefault("projects", {})["list"] = projects
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc))
    if os.environ.get("FAIL_AFTER_WRITE") == name:
        sys.exit(1)
    print(json.dumps({"name": name, "path": project_path, "switched": False}))
else:
    sys.exit(2)
'''


SLOW_DEV = r'''#!/usr/bin/env python3
import json, os, pathlib, signal, subprocess, sys, time
ready = pathlib.Path(os.environ["SLOW_READY"])
child = subprocess.Popen([sys.executable, "-c",
    "import os,pathlib,signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); "
    "pathlib.Path(os.environ['SLOW_READY']).write_text('ready'); time.sleep(60)"])
while not ready.exists():
    time.sleep(0.01)
pathlib.Path(os.environ["SLOW_PIDS"]).write_text(json.dumps({
    "parent": os.getpid(), "child": child.pid, "group": os.getpgrp(),
    "term_blocked": signal.SIGTERM in signal.pthread_sigmask(signal.SIG_BLOCK, set()),
}))
time.sleep(60)
'''


class DevProjectsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dev-projects-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.rows_file = self.root / "rows.json"
        self.rows_file.write_text("[]")
        self.config = self.root / "sidecar/config.json"
        self.launch = self.root / "launch.json"
        self.writes = self.root / "writes.jsonl"
        self.count = self.root / "count"
        self.fake_dev = self.make_tool("dev", FAKE_DEV)
        self.fake_sidecar = self.make_tool("sidecar", FAKE_SIDECAR)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("SIDECAR_")}
        self.env.update({
            "HOME": str(self.home), "XDG_STATE_HOME": str(self.root / "state"),
            "XDG_CACHE_HOME": str(self.root / "cache"), "XDG_CONFIG_HOME": str(self.root / "config"),
            "TMUX": "", "TMUX_PANE": "", "TMUX_TMPDIR": str(self.root / "tmux"),
            "DEV_PROJECTS_DEV": str(self.fake_dev), "DEV_PROJECTS_SIDECAR": str(self.fake_sidecar),
            "DEV_ROWS": str(self.rows_file), "LAUNCH_RECORD": str(self.launch),
            "WRITE_RECORD": str(self.writes), "PROBE_COUNT": str(self.count),
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
            "PATH": str(self.bin) + os.pathsep + os.environ.get("PATH", ""),
        })
        Path(self.env["TMUX_TMPDIR"]).mkdir()

    def make_tool(self, name, source):
        path = self.bin / name
        path.write_text(source)
        path.chmod(0o755)
        return path

    def git_repo(self, name):
        path = self.root / name
        path.mkdir(parents=True)
        subprocess.run(["git", "init", "-q", str(path)], check=True, env=self.env)
        return path

    def row(self, path, name=None, **extra):
        return {"name": name or path.name, "path": str(path), "has_git": True, "bare": False, **extra}

    def set_rows(self, rows):
        self.rows_file.write_text(json.dumps(rows))

    def set_config(self, entries, **extra):
        self.config.parent.mkdir(exist_ok=True)
        self.config.write_text(json.dumps({"projects": {"list": entries}, **extra}))

    def call(self, *args, env=None):
        return subprocess.run([sys.executable, str(HELPER), *map(str, args)],
                              cwd=self.home, env=env or self.env, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)

    def import_call(self, *args, env=None):
        return self.call("sidecar-import", "--config", self.config, *args, env=env)

    def slow_probe(self):
        tool = self.make_tool("slow-dev", SLOW_DEV)
        pids = self.root / "slow-pids.json"
        env = {**self.env, "DEV_PROJECTS_DEV": str(tool), "SLOW_PIDS": str(pids),
               "SLOW_READY": str(self.root / "slow-ready")}

        def cleanup():
            if pids.exists():
                try:
                    os.killpg(json.loads(pids.read_text())["group"], signal.SIGKILL)
                except ProcessLookupError:
                    pass

        self.addCleanup(cleanup)
        return tool, pids, env

    def assert_probe_stopped(self, pids):
        record = json.loads(pids.read_text())
        self.assertEqual(record["group"], record["parent"])
        self.assertNotEqual(record["group"], os.getpgrp())
        self.assertFalse(record["term_blocked"], "the child inherited a blocked TERM signal")
        deadline = time.monotonic() + 3
        while True:
            living = []
            for pid in (record["parent"], record["child"]):
                status = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)],
                                        capture_output=True, text=True, timeout=2).stdout.strip()
                if status and not status.startswith("Z"):
                    living.append(pid)
            if not living or time.monotonic() >= deadline:
                break
            time.sleep(0.02)
        self.assertEqual(living, [], "a cancelled probe or descendant is still running")

    @unittest.skipUnless(os.name == "posix", "private process groups require POSIX")
    def test_sigterm_cancellation_reaps_private_probe_and_terminates_descendant(self):
        _, pids, env = self.slow_probe()
        proc = subprocess.Popen([sys.executable, str(HELPER), "list"], cwd=self.home,
                                env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(lambda: proc.poll() is None and proc.kill())
        deadline = time.monotonic() + 5
        while not pids.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue(pids.exists(), "slow fixture did not start")
        proc.send_signal(signal.SIGTERM)
        stdout, stderr = proc.communicate(timeout=3)
        self.assertEqual(proc.returncode, 128 + signal.SIGTERM)
        self.assertEqual(stdout, "")
        self.assertIn("cancelled", stderr)
        self.assert_probe_stopped(pids)

    @unittest.skipUnless(os.name == "posix", "private process groups require POSIX")
    def test_timeout_reaps_probe_and_terminates_term_ignoring_descendant(self):
        tool, pids, env = self.slow_probe()
        loader = SourceFileLoader("dev_projects_timeout_test", str(HELPER))
        module = types.ModuleType(loader.name)
        with mock.patch.object(sys, "dont_write_bytecode", True):
            loader.exec_module(module)
        with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(module, "TIMEOUT", 0.5):
            with self.assertRaisesRegex(module.Failure, "timed out"):
                module.run([str(tool)], "slow fixture")
        self.assertTrue(pids.exists(), "slow fixture did not start before timeout")
        self.assert_probe_stopped(pids)

    @unittest.skipUnless(os.name == "posix", "private process groups require POSIX")
    def test_cleanup_never_signals_an_already_reaped_group(self):
        loader = SourceFileLoader("dev_projects_reaped_test", str(HELPER))
        module = types.ModuleType(loader.name)
        with mock.patch.object(sys, "dont_write_bytecode", True):
            loader.exec_module(module)
        proc = types.SimpleNamespace(returncode=0, pid=12345, stdout=io.BytesIO(), stderr=io.BytesIO())
        with mock.patch.object(module.os, "killpg") as kill:
            module.stop_probe(proc)
        kill.assert_not_called()
        self.assertTrue(proc.stdout.closed and proc.stderr.closed)

    @unittest.skipUnless(os.name == "posix", "private process groups require POSIX")
    def test_signal_refusal_still_reaps_closes_and_reports_uncertain_cleanup(self):
        loader = SourceFileLoader("dev_projects_refusal_test", str(HELPER))
        module = types.ModuleType(loader.name)
        with mock.patch.object(sys, "dont_write_bytecode", True):
            loader.exec_module(module)
        wait = mock.Mock(return_value=0)
        proc = types.SimpleNamespace(returncode=None, pid=12345, stdout=io.BytesIO(), stderr=io.BytesIO(), wait=wait)
        with mock.patch.object(module.os, "killpg", side_effect=PermissionError), \
                self.assertRaisesRegex(module.Failure, "cleanup could not be confirmed"):
            module.stop_probe(proc)
        wait.assert_called_once_with(timeout=1)
        self.assertTrue(proc.stdout.closed and proc.stderr.closed)

    def test_list_deduplicates_symlinks_preserves_clones_and_special_paths(self):
        a = self.git_repo("one 空間 ' $(not-a-command)")
        b = self.git_repo("second-clone")
        alias = self.root / "alias"
        alias.symlink_to(a, target_is_directory=True)
        self.set_rows([self.row(a, display="Display", category="work"), self.row(alias),
                       self.row(b), self.row(self.root / "missing"),
                       self.row(a, has_git=False), self.row(a, bare=True)])
        result = self.call("list", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = json.loads(result.stdout)
        self.assertEqual([r["real_path"] for r in rows], [str(a.resolve()), str(b.resolve())])
        self.assertEqual(set(rows[0]), {"name", "display", "category", "path", "real_path"})
        self.assertEqual(rows[0]["category"], "work")

    def test_source_failure_and_malformed_data_do_not_become_empty_list(self):
        for patch in ({"FAIL_DEV": "1"}, {"MALFORMED_DEV": "broken json"},
                      {"MALFORMED_DEV": "{}"}, {"MALFORMED_DEV": '[{"path":"/x"}]'}):
            with self.subTest(patch=patch):
                result = self.call("list", env={**self.env, **patch})
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertNotIn("private provider", result.stderr)

    def test_line_protocol_rejects_control_paths_and_symlink_targets(self):
        for name in ("line\nbreak", "escape\x1b[31m", "delete\x7fcharacter"):
            with self.subTest(name=repr(name)):
                path = self.git_repo(name)
                self.set_rows([self.row(path)])
                result = self.call("list", "--json")
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertIn("ASCII control characters", result.stderr)
                self.assertNotIn(name, result.stderr)
                alias = self.root / "safe-alias"
                alias.symlink_to(path, target_is_directory=True)
                self.set_rows([self.row(alias)])
                result = self.call("list", "--json")
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                alias.unlink()
        self.set_rows([self.row(self.root / "null\0path")])
        result = self.call("list")
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("Traceback", result.stderr)

    def test_git_path_environment_cannot_turn_plain_directory_into_checkout(self):
        real = self.git_repo("real-checkout")
        plain = self.root / "not-a-checkout"
        plain.mkdir()
        self.set_rows([self.row(plain)])
        env = {**self.env, "GIT_DIR": str(real / ".git"), "GIT_WORK_TREE": str(plain)}
        result = self.call("open", plain, env=env)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertFalse(self.launch.exists())

    def test_all_git_path_overrides_are_cleared_for_source_git_and_exec(self):
        selected = self.git_repo("selected")
        foreign = self.git_repo("foreign")
        self.set_rows([self.row(selected)])
        keys = ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_PREFIX",
                "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES")
        source_record, exec_record = self.root / "source-env.json", self.root / "exec-env.json"
        env = {**self.env, **{key: str(foreign) for key in keys},
               "DEV_ENV_RECORD": str(source_record), "EXEC_ENV_RECORD": str(exec_record)}
        result = self.call("open", selected, env=env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for record in (source_record, exec_record):
            child = json.loads(record.read_text())
            self.assertFalse(set(keys) & child.keys())
            for preserved in ("HOME", "XDG_STATE_HOME", "GIT_CONFIG_GLOBAL", "DEV_PROJECTS_DEV", "DEV_PROJECTS_SIDECAR"):
                self.assertEqual(child[preserved], env[preserved])

    def test_open_passes_argv_and_cwd_without_registering(self):
        path = self.git_repo("it's 中文 $(touch bad)")
        self.set_rows([self.row(path)])
        result = self.call("open", path, "--tool", "sidecar")
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(self.launch.read_text())
        self.assertEqual(record, {"argv": ["--project", str(path.resolve())], "cwd": str(path.resolve())})
        self.assertFalse(self.writes.exists())
        self.assertFalse((path / "bad").exists())

    def test_open_nvim_and_rejects_missing_nonroot_and_unlisted_paths(self):
        path = self.git_repo("project")
        self.make_tool("nvim", "#!/usr/bin/env python3\nimport json,os,pathlib,sys\n"
                       "pathlib.Path(os.environ['LAUNCH_RECORD']).write_text(json.dumps({'argv':sys.argv[1:],'cwd':os.getcwd()}))\n")
        self.set_rows([self.row(path)])
        result = self.call("open", path, "--tool", "nvim")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.launch.read_text())["argv"], ["."])
        self.launch.unlink()
        nested = path / "subdir"
        nested.mkdir()
        self.set_rows([self.row(nested)])
        for rejected in (nested, path, self.root / "missing"):
            with self.subTest(rejected=rejected):
                result = self.call("open", rejected)
                self.assertEqual(result.returncode, 1)
                self.assertFalse(self.launch.exists())

    def test_preview_and_apply_require_explicit_pair(self):
        path = self.git_repo("new")
        self.set_rows([self.row(path)])
        for flag in ("--apply", "--yes"):
            result = self.import_call(flag)
            self.assertEqual(result.returncode, 2)
        result = self.import_call("--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["summary"], {"add": 1})
        self.assertFalse(self.config.exists())
        self.assertFalse(self.writes.exists())

    def test_preserves_preferences_and_repeat_import_is_noop(self):
        old = self.git_repo("old")
        new = self.git_repo("new")
        original = {"name": "My manual title", "path": str(old.resolve()),
                    "theme": {"name": "Nord", "community": "custom", "overrides": {"accent": "#123456"}},
                    "openIn": "code", "lastOpenInApp": "nvim", "addedAt": "2026-01-01T00:00:00Z",
                    "worktreeSetup": {"copyEnvFiles": False, "envFiles": [".env.local"],
                                      "runHook": False, "hookPath": "setup.sh", "hookRequired": True}}
        self.set_config([original], customTopLevel={"keep": True})
        self.set_rows([self.row(old), self.row(new)])
        result = self.import_call("--apply", "--yes")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(json.loads(result.stdout)["summary"], {"already_present": 1, "added": 1})
        self.assertEqual(json.loads(self.config.read_text())["projects"]["list"][0], original)
        before = self.config.read_bytes()
        result = self.import_call("--apply", "--yes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["summary"], {"already_present": 2})
        self.assertEqual(self.config.read_bytes(), before)
        self.assertEqual(len(self.writes.read_text().splitlines()), 1)

    def test_collisions_missing_and_selected_subset(self):
        a, b, c = [self.git_repo(name) for name in ("a", "b", "c")]
        self.set_config([{"name": "TAKEN", "path": str(a)}])
        self.set_rows([self.row(b, name="taken"), self.row(c)])
        result = self.import_call("--repo", b, "--repo", self.root / "gone", "--apply", "--yes")
        self.assertEqual(result.returncode, 3, result.stdout)
        self.assertEqual(json.loads(result.stdout)["summary"], {"name_conflict": 1, "unavailable": 1})
        self.assertFalse(self.writes.exists())
        self.set_rows([self.row(b, name="duplicate"), self.row(c, name="DUPLICATE")])
        result = self.import_call()
        self.assertEqual(json.loads(result.stdout)["summary"], {"name_conflict": 2})

    def test_unknown_fields_block_all_writes(self):
        old, new = self.git_repo("old"), self.git_repo("new")
        for patch in ({"futureKey": {"private": "secret"}}, {"theme": {"future": "secret"}},
                      {"worktreeSetup": {"future": "secret"}}):
            with self.subTest(patch=patch):
                self.set_config([{"name": "old", "path": str(old), **patch}])
                self.set_rows([self.row(new)])
                before = self.config.read_bytes()
                result = self.import_call("--apply", "--yes")
                self.assertEqual(result.returncode, 3)
                self.assertEqual(json.loads(result.stdout)["summary"], {"not_attempted": 1})
                self.assertNotIn("secret", result.stdout + result.stderr)
                self.assertEqual(self.config.read_bytes(), before)
                self.assertFalse(self.writes.exists())

    def test_import_rejects_control_characters_in_project_name(self):
        path = self.git_repo("ordinary-path")
        self.set_rows([self.row(path, name="metadata\nname\x1b[31m")])
        result = self.import_call("--apply", "--yes")
        self.assertEqual(result.returncode, 3)
        self.assertEqual(json.loads(result.stdout)["summary"], {"unavailable": 1})
        self.assertFalse(self.writes.exists())

    def test_import_rejects_path_trimming_while_list_and_open_preserve_paths(self):
        for index, suffix in enumerate((" ", "\u00a0", "\u3000")):
            with self.subTest(suffix=repr(suffix)):
                sibling = self.git_repo("trailing-" + str(index))
                selected = self.git_repo(sibling.name + suffix)
                self.set_rows([self.row(selected)])
                result = self.call("list", "--json")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout)[0]["real_path"], str(selected.resolve()))
                result = self.call("open", selected, "--tool", "sidecar")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(self.launch.read_text())["cwd"], str(selected.resolve()))
                result = self.import_call("--apply", "--yes")
                self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
                report = json.loads(result.stdout)
                self.assertEqual(report["summary"], {"unavailable": 1})
                self.assertIn("would trim whitespace", report["items"][0]["reason"])
                self.assertFalse(self.writes.exists())
                self.assertFalse(self.config.exists())

    def test_replaced_repo_between_plan_and_apply_is_refused(self):
        path = self.git_repo("moving")
        self.set_rows([self.row(path)])
        result = self.import_call("--apply", "--yes", env={**self.env, "REPLACE_REPO": str(path)})
        self.assertEqual(result.returncode, 3, result.stdout)
        self.assertEqual(json.loads(result.stdout)["summary"], {"unavailable": 1})
        self.assertFalse(self.writes.exists())

    def test_partial_failure_retains_first_add_and_never_retries(self):
        paths = [self.git_repo(name) for name in ("first", "fail", "last")]
        self.set_rows([self.row(p) for p in paths])
        result = self.import_call("--apply", "--yes", env={**self.env, "FAIL_ADD": "fail"})
        self.assertEqual(result.returncode, 3, result.stdout)
        self.assertEqual(json.loads(result.stdout)["summary"], {"added": 1, "unknown": 1, "not_attempted": 1})
        self.assertEqual(len(self.writes.read_text().splitlines()), 2)
        self.assertEqual([p["name"] for p in json.loads(self.config.read_text())["projects"]["list"]], ["first"])
        self.assertNotIn("private configuration", result.stderr + result.stdout)

    def test_write_then_failure_stays_unknown_without_rollback(self):
        path = self.git_repo("ambiguous")
        self.set_rows([self.row(path)])
        result = self.import_call("--apply", "--yes", env={**self.env, "FAIL_AFTER_WRITE": "ambiguous"})
        self.assertEqual(result.returncode, 3)
        self.assertEqual(json.loads(result.stdout)["summary"], {"unknown": 1})
        self.assertEqual(len(json.loads(self.config.read_text())["projects"]["list"]), 1)
        self.assertEqual(len(self.writes.read_text().splitlines()), 1)

    @unittest.skipUnless(NATIVE_SIDECAR, "native Sidecar is not installed")
    def test_native_sidecar_does_not_register_trimmed_sibling(self):
        env = {**self.env, "DEV_PROJECTS_SIDECAR": NATIVE_SIDECAR}
        version = subprocess.run([NATIVE_SIDECAR, "--version"], env=env, cwd=self.home,
                                 capture_output=True, text=True, timeout=10)
        if "1.14." not in version.stdout:
            self.skipTest("native serializer test is scoped to audited Sidecar 1.14")
        self.set_config([])
        before = self.config.read_bytes()
        for index, suffix in enumerate((" ", "\u00a0", "\u3000")):
            with self.subTest(suffix=repr(suffix)):
                sibling = self.git_repo("native-trailing-" + str(index))
                selected = self.git_repo(sibling.name + suffix)
                self.set_rows([self.row(selected)])
                preview = self.import_call(env=env)
                self.assertEqual(preview.returncode, 0, preview.stderr)
                self.assertEqual(json.loads(preview.stdout)["summary"], {"unavailable": 1})
                result = self.import_call("--apply", "--yes", env=env)
                self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
                self.assertEqual(json.loads(result.stdout)["summary"], {"unavailable": 1})
                self.assertEqual(self.config.read_bytes(), before)
                self.assertEqual(json.loads(self.config.read_text())["projects"]["list"], [])

    @unittest.skipUnless(NATIVE_SIDECAR, "native Sidecar is not installed")
    def test_native_sidecar_isolated_settings_and_second_import(self):
        env = {**self.env, "DEV_PROJECTS_SIDECAR": NATIVE_SIDECAR}
        version = subprocess.run([NATIVE_SIDECAR, "--version"], env=env, cwd=self.home,
                                 capture_output=True, text=True, timeout=10)
        if "1.14." not in version.stdout:
            self.skipTest("native serializer test is scoped to audited Sidecar 1.14")
        old, new = self.git_repo("native-old"), self.git_repo("native-new")
        existing = {"name": "Keep native title", "path": str(old.resolve()),
                    "theme": {"name": "Nord", "overrides": {"accent": "#123456"}},
                    "openIn": "nvim", "lastOpenInApp": "code", "addedAt": "2026-01-01T00:00:00Z",
                    "worktreeSetup": {"copyEnvFiles": False, "envFiles": [".env.local"],
                                      "runHook": False, "hookRequired": True, "hookPath": "setup.sh"}}
        self.set_config([existing])
        self.set_rows([self.row(old), self.row(new)])
        result = self.import_call("--apply", "--yes", env=env)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        saved = json.loads(self.config.read_text())
        self.assertEqual(saved["projects"]["list"][0], existing)
        before = self.config.read_bytes()
        result = self.import_call("--apply", "--yes", env=env)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(json.loads(result.stdout)["summary"], {"already_present": 2})
        self.assertEqual(self.config.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
