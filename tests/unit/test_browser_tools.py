"""Provisioning failure/ownership tests; no real home, downloads or browsers.

Run: python3 -m unittest discover -s tests/unit -p test_browser_tools.py -v
"""

import importlib.util
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
HELPER = REPO / "dot_ansible/roles/devtools/files/browser_tools.py"
spec = importlib.util.spec_from_file_location("browser_tools", HELPER)
bt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bt)


class BrowserToolsTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="browser-tools-test-")
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name).resolve()
        env = patch.dict(os.environ, {"HOME": str(self.home),
                                     "XDG_DATA_HOME": str(self.home / "data"),
                                     "XDG_STATE_HOME": str(self.home / "state")})
        env.start()
        self.addCleanup(env.stop)

    def skill(self, root):
        root.mkdir(parents=True)
        (root / "SKILL.md").write_text("---\nname: test\n---\n")
        (root / "references").mkdir()
        (root / "references/example.md").write_text("full skill resources")
        return root

    def test_package_skill_keeps_references_and_second_sync_is_unchanged(self):
        source = self.skill(self.home / "package/terminal-browser")
        dest = self.home / ".agents/skills/terminal-browser"
        self.assertTrue(bt.safe_link(source, dest, {}))
        before = dest.lstat().st_mtime_ns
        self.assertFalse(bt.safe_link(source, dest, {}))
        self.assertEqual(before, dest.lstat().st_mtime_ns)
        self.assertEqual((dest / "references/example.md").read_text(), "full skill resources")

    def test_upgrade_repairs_recorded_dangling_link(self):
        source = self.skill(self.home / "new/terminal-browser")
        dest = self.home / "terminal-browser"
        previous = str(self.home / "deleted/terminal-browser")
        dest.symlink_to(previous)
        self.assertTrue(bt.safe_link(source, dest, {str(dest): previous}))
        self.assertEqual(dest.resolve(), source)

    def test_existing_directory_and_custom_link_survive(self):
        source = self.skill(self.home / "package/terminal-browser")
        custom = self.skill(self.home / "custom")
        dest = self.home / "link"
        dest.symlink_to(custom)
        self.assertFalse(bt.safe_link(source, custom, {}))
        self.assertFalse(bt.safe_link(source, dest, {}))
        self.assertEqual(dest.resolve(), custom)
        self.assertTrue((custom / "SKILL.md").is_file())

    def test_manifest_uses_codex_variant_without_editor_setup(self):
        root = self.home / "distribution"
        self.skill(root / "skills/default/terminal-browser")
        self.skill(root / "skills/codex/terminal-browser")
        (root / "skills/manifest").write_text("agent codex .codex/skills codex\nskill terminal-browser\n")
        (self.home / ".codex").mkdir()
        editor = self.home / "editor-settings.json"
        editor.write_text('{"terminal.integrated.enableImages":false}')
        with patch.object(bt, "terminal_root", return_value=root), patch.object(bt, "playwright_package", return_value=None):
            bt.sync_skills({})
            bt.sync_skills({})
        self.assertEqual((self.home / ".codex/skills/terminal-browser").resolve(), root / "skills/codex/terminal-browser")
        self.assertEqual(editor.read_text(), '{"terminal.integrated.enableImages":false}')

    def test_existing_playwright_is_checked_without_installing(self):
        with patch.object(bt, "playwright_package", return_value=self.home), patch.object(bt, "run") as run:
            bt.install_playwright({})
        self.assertEqual(run.call_args.args[0], ["playwright-cli", "--version"])
        self.assertEqual(run.call_count, 1)

    def test_matching_browser_is_repaired_after_cache_deletion(self):
        package = self.home / "package"
        package.mkdir()
        (package / "package.json").write_text('{"version":"1"}')
        browser = self.home / "cache/chromium"
        paths = {"browser": str(browser)}

        def execute(argv, **kwargs):
            if argv[:2] == ["playwright-cli", "install-browser"]:
                browser.parent.mkdir(exist_ok=True)
                browser.touch()
            return subprocess.CompletedProcess(argv, 0, "", "")

        with patch.object(bt, "playwright_package", return_value=package), patch.object(bt, "browser_supported", return_value=True), patch.object(bt, "core_paths", return_value=paths), patch.object(bt, "run", side_effect=execute) as run:
            bt.refresh_playwright({})
            self.assertEqual(run.call_count, 2)  # install + actual launch
            bt.refresh_playwright({})
            self.assertEqual(run.call_count, 2)
            browser.unlink()
            bt.refresh_playwright({})
            self.assertEqual(run.call_count, 4)

    def test_failed_launch_does_not_mark_browser_ready(self):
        package = self.home / "package"
        package.mkdir()
        (package / "package.json").write_text('{"version":"1"}')
        with patch.object(bt, "playwright_package", return_value=package), patch.object(bt, "browser_supported", return_value=True), patch.object(bt, "core_paths", return_value={"browser": "missing"}), patch.object(bt, "run", side_effect=[None, RuntimeError("libnss3 missing")]):
            with self.assertRaisesRegex(RuntimeError, "libnss3"):
                bt.refresh_playwright({})
        self.assertFalse((bt.state_home() / "chromium-ready.json").exists())

    def test_archive_rejects_escape_before_extracting(self):
        archive = self.home / "bad.tgz"
        with tarfile.open(archive, "w:gz") as tar:
            member = tarfile.TarInfo("../escaped")
            member.size = 3
            tar.addfile(member, io.BytesIO(b"bad"))
        with self.assertRaisesRegex(RuntimeError, "Unsafe"):
            bt.extract_release(archive, self.home / "unpack")
        self.assertFalse((self.home / "escaped").exists())

    def test_checksum_failure_preserves_existing_launcher(self):
        launcher = self.home / ".local/bin/terminal-browser"
        launcher.parent.mkdir(parents=True)
        launcher.symlink_to("/previous/terminal-browser/bin/terminal-browser")
        bt.atomic_text(bt.state_home() / "terminal-release.json", '{"version":"v0.1.0"}')
        manifest = {"version": "v1.0.0", "platforms": {"linux-x64": {
            "url": "https://terminal-browser.sh/install/dl/test", "sha256": "0" * 64}}}

        def execute(argv, **kwargs):
            if "-o" in argv:
                Path(argv[-1]).write_bytes(b"corrupted")
            return subprocess.CompletedProcess(argv, 0, json.dumps(manifest), "")

        with patch.object(bt.sys, "platform", "linux"), patch.object(bt.platform, "machine", return_value="x86_64"), patch.object(bt, "browser_supported", return_value=True), patch.object(bt, "terminal_root", return_value=launcher.resolve().parent.parent), patch.object(bt, "terminal_busy", return_value=False), patch.object(bt, "run", side_effect=execute):
            with self.assertRaisesRegex(RuntimeError, "checksum"):
                bt.install_terminal_browser(upgrade=True)
        self.assertEqual(os.readlink(launcher), "/previous/terminal-browser/bin/terminal-browser")

    def test_live_browser_upgrade_does_not_fetch_or_replace(self):
        launcher = self.home / ".local/bin/terminal-browser"
        launcher.parent.mkdir(parents=True)
        launcher.symlink_to("/previous/terminal-browser/bin/terminal-browser")
        bt.atomic_text(bt.state_home() / "terminal-release.json", '{"version":"v0.1.0"}')
        with patch.object(bt.sys, "platform", "linux"), patch.object(bt, "browser_supported", return_value=True), patch.object(bt, "terminal_root", return_value=launcher.resolve().parent.parent), patch.object(bt, "terminal_busy", return_value=True), patch.object(bt, "run") as run:
            bt.install_terminal_browser(upgrade=True)
        run.assert_not_called()
        self.assertEqual(os.readlink(launcher), "/previous/terminal-browser/bin/terminal-browser")

    def test_verified_fresh_install_and_second_apply_downloads_nothing(self):
        source = self.home / "release.tgz"
        with tarfile.open(source, "w:gz") as tar:
            for name, content in (("bin/terminal-browser", b"#!/bin/sh\necho terminal-browser v1.0.0\n"),
                                  ("skills/manifest", b"skill terminal-browser\n")):
                member = tarfile.TarInfo("terminal-browser/" + name)
                member.size = len(content)
                member.mode = 0o755
                tar.addfile(member, io.BytesIO(content))
        manifest = {"version": "v1.0.0", "platforms": {"linux-x64": {
            "url": "https://terminal-browser.sh/install/dl/test",
            "sha256": hashlib.sha256(source.read_bytes()).hexdigest()}}}

        def execute(argv, **kwargs):
            if "-o" in argv:
                Path(argv[-1]).write_bytes(source.read_bytes())
            return subprocess.CompletedProcess(argv, 0, json.dumps(manifest), "")

        with patch.object(bt.sys, "platform", "linux"), patch.object(bt.platform, "machine", return_value="x86_64"), patch.object(bt, "browser_supported", return_value=True), patch.object(bt.shutil, "which", return_value=None), patch.object(bt, "run", side_effect=execute) as run:
            bt.install_terminal_browser()
            count = run.call_count
            self.assertEqual(count, 3)  # manifest, archive, executable check
            bt.install_terminal_browser()
            self.assertEqual(run.call_count, count)
        launcher = self.home / ".local/bin/terminal-browser"
        self.assertTrue(launcher.is_file())
        self.assertIn("releases/v1.0.0", str(launcher.resolve()))
        self.assertEqual(json.loads((bt.state_home() / "terminal-release.json").read_text())["version"], "v1.0.0")

    def test_unrecognized_playwright_install_is_preserved(self):
        with patch.object(bt, "playwright_package", return_value=None), patch.object(bt.shutil, "which", return_value="/custom/playwright-cli"), patch.object(bt, "run") as run:
            with self.assertRaisesRegex(RuntimeError, "preserving"):
                bt.install_playwright({})
        run.assert_not_called()

    def test_foreign_terminal_install_cannot_be_upgraded(self):
        with patch.object(bt.sys, "platform", "linux"), patch.object(bt, "browser_supported", return_value=True), patch.object(bt, "run") as run:
            bt.install_terminal_browser(upgrade=True)
        run.assert_not_called()

    def test_refresh_never_downloads_chromium_by_default(self):
        with patch.object(bt.sys, "argv", ["helper", "refresh"]), patch.object(bt, "node_environment", return_value={}), patch.object(bt, "sync_skills") as sync, patch.object(bt, "refresh_playwright") as download:
            bt.main()
        sync.assert_called_once_with({}, terminal=True, playwright=True)
        download.assert_not_called()

    def test_preload_requires_enabled_playwright(self):
        with patch.object(bt, "node_environment", return_value={}), patch.object(bt, "sync_skills"), patch.object(bt, "refresh_playwright") as download:
            with patch.object(bt.sys, "argv", ["helper", "refresh", "--preload-chromium"]):
                bt.main()
            download.assert_called_once_with({})
            download.reset_mock()
            with patch.object(bt.sys, "argv", ["helper", "refresh", "--preload-chromium", "--skip-playwright"]):
                bt.main()
            download.assert_not_called()

    def test_disabled_tools_do_not_resolve_or_rewrite_their_skills(self):
        with patch.object(bt, "terminal_root") as terminal, patch.object(bt, "playwright_package") as playwright:
            bt.sync_skills({}, terminal=False, playwright=False)
        terminal.assert_not_called()
        playwright.assert_not_called()
        self.assertFalse((bt.state_home() / "skill-links.json").exists())


if __name__ == "__main__":
    unittest.main()
