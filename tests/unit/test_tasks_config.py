"""Exercise Tasks first-use config through real Ansible and Tasks parsers.

All HOME/data paths are temporary. No task commands or API servers are started.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
BOOTSTRAP = ROOT / "dot_ansible/roles/coding_agents/tasks/tasks-config.yml"
ANSIBLE = shutil.which("ansible-playbook")
TASKS = shutil.which("tasks")


@unittest.skipUnless(ANSIBLE and TASKS, "requires ansible-playbook and Tasks")
class TasksConfigTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="tasks-config-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name).resolve()
        self.home = self.base / "user's 中文 home"
        self.home.mkdir()
        self.facts_env = {"HOME": str(self.home)}
        self.ansible_config = self.base / "ansible.cfg"
        self.ansible_config.write_text("[defaults]\nstdout_callback = default\n")

    def apply(self, *, check=False, succeeds=True):
        play = [{
            "name": "Tasks config fixture",
            "hosts": "localhost",
            "gather_facts": False,
            "vars": {
                "ansible_python_interpreter": sys.executable,
                "ansible_facts": {"env": self.facts_env},
                "tasks_cli_path": TASKS,
            },
            "tasks": [{"ansible.builtin.include_tasks": str(BOOTSTRAP)}],
        }]
        play_path = self.base / "play.json"
        play_path.write_text(json.dumps(play))
        env = dict(os.environ, ANSIBLE_CONFIG=str(self.ansible_config), ANSIBLE_NOCOLOR="1")
        command = [ANSIBLE, "-i", "localhost,", "-c", "local", str(play_path)]
        if check:
            command.append("--check")
        result = subprocess.run(command, cwd=self.base, env=env, text=True,
                                capture_output=True, timeout=90)
        if succeeds:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def resolved(self):
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("TASKS_", "XDG_"))}
        env.update(self.facts_env)
        result = subprocess.run([TASKS, "config", "--json"], cwd=self.base,
                                env=env, text=True, capture_output=True, check=True)
        return json.loads(result.stdout)

    def test_default_seed_is_parseable_private_and_idempotent(self):
        self.apply()
        config = self.home / ".config/tasks/config"
        data = self.home / ".local/share/tasks"
        self.assertEqual(config.stat().st_mode & 0o777, 0o600)
        self.assertEqual(data.stat().st_mode & 0o777, 0o700)
        paths = self.resolved()
        self.assertTrue(paths["configured"])
        self.assertEqual(paths["org"], str(data / "tasks.jsonl"))
        self.assertEqual(paths["archive"], str(data / "archive.jsonl"))
        self.assertEqual(list(data.iterdir()), [])
        original = config.read_bytes()
        output = self.apply()
        self.assertIn("changed=0", output)
        self.assertEqual(config.read_bytes(), original)
        self.assertEqual(list(data.iterdir()), [])

    def test_custom_xdg_paths(self):
        cfg = self.base / "custom config"
        data = self.base / "custom data"
        self.facts_env.update(XDG_CONFIG_HOME=str(cfg), XDG_DATA_HOME=str(data))
        self.apply()
        self.assertTrue((cfg / "tasks/config").is_file())
        self.assertEqual(self.resolved()["org"], str(data / "tasks/tasks.jsonl"))
        self.assertFalse((self.home / ".config").exists())

    def test_existing_config_and_store_are_unchanged(self):
        config = self.home / ".config/tasks/config"
        config.parent.mkdir(parents=True)
        data = self.base / "existing data"
        data.mkdir()
        store = data / "tasks.jsonl"
        store.write_text("existing user data\n")
        original = f"theme = nord\ndir = {data}\n"
        config.write_text(original)
        config.chmod(0o640)
        self.assertIn("changed=0", self.apply())
        self.assertEqual(config.read_text(), original)
        self.assertEqual(config.stat().st_mode & 0o777, 0o640)
        self.assertEqual(store.read_text(), "existing user data\n")
        self.assertEqual(self.resolved()["org"], str(store))
        self.assertFalse((self.home / ".local/share/tasks").exists())

    def test_each_explicit_path_override_prevents_default_seed(self):
        for name in ("TASKS_DIR", "TASKS_FILE", "TASKS_ARCHIVE", "TASKS_MEMORY"):
            with self.subTest(name=name):
                self.facts_env = {"HOME": str(self.home), name: str(self.base / name)}
                self.assertIn("changed=0", self.apply())
                self.assertFalse((self.home / ".config/tasks/config").exists())
                self.assertFalse((self.home / ".local/share/tasks").exists())

    def test_existing_empty_config_is_not_overwritten(self):
        config = self.home / ".config/tasks/config"
        config.parent.mkdir(parents=True)
        config.write_text("theme = nord\n")
        output = self.apply()
        self.assertIn("existing config or path environment is incomplete", output)
        self.assertEqual(config.read_text(), "theme = nord\n")
        self.assertFalse(self.resolved()["configured"])

    def test_check_mode_writes_nothing(self):
        self.apply(check=True)
        self.assertFalse((self.home / ".config").exists())
        self.assertFalse((self.home / ".local").exists())

    def test_relative_data_home_is_rejected_without_creating_data(self):
        self.facts_env["XDG_DATA_HOME"] = "relative-data"
        self.apply(succeeds=False)
        self.assertFalse((self.base / "relative-data").exists())
        self.assertFalse((self.home / ".config/tasks/config").exists())


if __name__ == "__main__":
    unittest.main()
