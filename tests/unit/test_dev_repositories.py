"""Exercise the Lua adapter without loading user plugins or user state."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which("nvim") and shutil.which("git"), "requires nvim and git")
class DevRepositoriesTests(unittest.TestCase):
    def test_isolated_adapter(self):
        with tempfile.TemporaryDirectory(prefix="dev-repositories-test-") as directory:
            base = Path(directory)
            home = base / "home"
            home.mkdir()
            env = os.environ.copy()
            env.update({
                "HOME": str(home),
                "NVIM_APPNAME": "dev-repositories-test",
                "NVIM_DEV_REPOSITORIES_SOURCE": str(ROOT / "dot_config/nvim/lua/exact_plugins/dev-repositories.lua"),
            })
            for kind in ("CONFIG", "DATA", "STATE", "CACHE"):
                target = base / kind.lower()
                target.mkdir()
                env[f"XDG_{kind}_HOME"] = str(target)
            for key in ("VIMINIT", "GVIMINIT", "EXINIT", "NVIM", "NVIM_LISTEN_ADDRESS"):
                env.pop(key, None)

            checkout = base / "repo space 中文's"
            other = base / "other" / "repo space 中文's"
            plain = base / "plain directory"
            for path in (checkout, other, plain):
                path.mkdir(parents=True)
            for path in (checkout, other):
                subprocess.run(["git", "init", "--quiet", str(path)], env=env, check=True, capture_output=True)
            helper = base / "fake helper's"
            helper.write_text('#!/bin/sh\nprintf \'%s\\n\' "$DEV_REPO_TEST_JSON"\n', encoding="utf-8")
            helper.chmod(0o755)
            env.update({
                "DEV_REPO_TEST_CHECKOUT": str(checkout),
                "DEV_REPO_TEST_OTHER": str(other),
                "DEV_REPO_TEST_PLAIN": str(plain),
                "DEV_REPO_TEST_HELPER": str(helper),
            })

            # These are synthetic sentinels, never the user's recent/session data.
            protected = []
            for relative in (
                "data/dev-repositories-test/project_nvim/project_history",
                "state/dev-repositories-test/sessions/existing.vim",
            ):
                path = base / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("synthetic state must stay unchanged\n", encoding="utf-8")
                protected.append(path)
            result = subprocess.run(
                [shutil.which("nvim"), "--headless", "--noplugin", "-u", "NONE", "-i", "NONE", "-n", "-l",
                 str(ROOT / "tests/unit/dev_repositories_spec.lua")],
                cwd=base, env=env, text=True, capture_output=True, timeout=30,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("22 cases passed", result.stdout + result.stderr)
            for path in protected:
                self.assertEqual(path.read_text(encoding="utf-8"), "synthetic state must stay unchanged\n")
                self.assertEqual(list(path.parent.iterdir()), [path])


if __name__ == "__main__":
    unittest.main()
