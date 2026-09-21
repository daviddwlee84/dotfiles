"""Behavioral fixtures for the personal suite; no live package manager/network."""
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "dot_ansible/roles/personal_tools/files/personal_tools.py"
spec = importlib.util.spec_from_file_location("personal_tools", SCRIPT)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class SelectionTests(unittest.TestCase):
    def test_modes_keep_legacy_but_select_all_without_extra_runtimes(self):
        tools = m.load_tools()
        for system in ("Darwin", "Linux"):
            for extra in (False, True):
                with self.subTest(system=system, extra=extra):
                    self.assertEqual(m.selection(tools, "disabled", system, extra), [])
                    enabled = m.selection(tools, "enabled", system, extra)
                    self.assertEqual(len(enabled), 7)
                    self.assertEqual({t["method"] for t in enabled}, {"brew" if system == "Darwin" else "release"})
                    legacy = m.selection(tools, "legacy", system, extra)
                    expected = {"dev-cli", "translate"} if system == "Darwin" else set()
                    if extra:
                        expected |= {"dev-cli", "translate", "lazyclash"}
                    self.assertEqual({t["id"] for t in legacy}, expected)

    def test_disabled_cli_makes_no_installer_calls(self):
        with patch.object(m.Installer, "execute", side_effect=AssertionError("must not install")):
            with patch("sys.stdout", new_callable=io.StringIO):
                self.assertEqual(m.main(["install", "--mode", "disabled", "--extra-runtimes", "false"]), 0)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name).resolve()
        self.env = patch.dict(os.environ, {"HOME": str(self.home), "XDG_DATA_HOME": str(self.home / "data"), "PATH": str(self.home / ".local/bin") + ":/usr/bin:/bin"})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.tool = next(t for t in m.selection(m.load_tools(), "enabled", "Linux", False) if t["id"] == "lazypueue")
        self.installer = m.Installer(self.home, "Linux", "x86_64")
        self.target = self.installer.target(self.tool)
        self.calls = []

    def downloads(self, version="v0.1.0", checksum_good=True, symlink=False):
        archive = self.home / "fixture.tar.gz"
        payload = f"#!/bin/sh\nprintf 'lazypueue {version}\\n'\n".encode()
        with tarfile.open(archive, "w:gz") as output:
            info = tarfile.TarInfo("lazypueue")
            info.size = len(payload)
            if symlink:
                info.type = tarfile.SYMTYPE
                info.linkname = "/bin/sh"
            output.addfile(info, io.BytesIO(payload))
        def download(url, dest):
            self.calls.append(url)
            if url.endswith(".tar.gz"):
                Path(dest).write_bytes(archive.read_bytes())
            else:
                selected_tag = url.split("/download/")[1].split("/")[0]
                asset = self.tool["archive"].format(repo=self.tool["id"], tag=selected_tag, version=selected_tag[1:], os="linux", arch="amd64")
                checksum = m.digest(archive) if checksum_good else "0" * 64
                Path(dest).write_text(f"{checksum}  {asset}\n")
        return patch.object(m, "fetch", side_effect=download)

    def install(self):
        with self.downloads():
            self.assertTrue(self.installer.execute(self.tool, "install")["changed"])

    def test_install_is_receipted_and_second_apply_does_not_download(self):
        self.install()
        receipt = self.installer.receipt(self.tool)
        self.assertEqual(receipt["version"], "v0.1.0")
        self.assertEqual(receipt["sha256"], m.digest(self.target))
        with patch.object(m, "fetch", side_effect=AssertionError("apply must not upgrade")):
            result = self.installer.execute(self.tool, "install")
        self.assertFalse(result["changed"])

    def test_upgrade_missing_never_installs_or_creates_state(self):
        with patch.object(m, "fetch", side_effect=AssertionError("no network")):
            self.assertEqual(self.installer.execute(self.tool, "upgrade")["status"], "not-installed")
        self.assertFalse(self.installer.state.exists())

    def test_bad_checksum_or_candidate_version_preserves_previous_install(self):
        self.install()
        before = self.target.read_bytes()
        receipt = self.installer.receipt_path(self.tool).read_bytes()
        for version, good in (("v0.1.1", False), ("v9.9.9", True)):
            with self.subTest(version=version), self.downloads(version, good), patch.object(m, "latest", return_value="v0.1.1"):
                with self.assertRaises(m.InstallError):
                    self.installer.execute(self.tool, "upgrade")
            self.assertEqual(self.target.read_bytes(), before)
            self.assertEqual(self.installer.receipt_path(self.tool).read_bytes(), receipt)

    def test_receipt_failure_rolls_back_binary(self):
        self.install()
        before = self.target.read_bytes()
        receipt = self.installer.receipt_path(self.tool).read_bytes()
        with self.downloads("v0.1.1"), patch.object(m, "latest", return_value="v0.1.1"), patch.object(self.installer, "save_receipt", side_effect=OSError("read-only state")):
            with self.assertRaises(OSError):
                self.installer.execute(self.tool, "upgrade")
        self.assertEqual(self.target.read_bytes(), before)
        self.assertEqual(self.installer.receipt_path(self.tool).read_bytes(), receipt)

    def test_unmanaged_and_symlink_candidates_are_preserved(self):
        self.target.parent.mkdir(parents=True)
        self.target.write_text("#!/bin/sh\necho local\n")
        self.target.chmod(0o755)
        with patch.object(self.installer, "legacy_go", return_value=False), patch.object(m, "fetch", side_effect=AssertionError("no download")):
            self.assertEqual(self.installer.execute(self.tool, "install")["status"], "unmanaged")
        self.target.unlink()
        with self.downloads(symlink=True):
            with self.assertRaises(m.InstallError):
                self.installer.execute(self.tool, "install")
        self.assertFalse(self.target.exists())

    def test_unsupported_arch_does_not_fall_back_to_go(self):
        self.installer.arch = "armv7l"
        with patch.object(self.installer, "source", side_effect=AssertionError("no fallback")):
            with self.assertRaises(m.InstallError):
                self.installer.execute(self.tool, "install")
        self.assertFalse(self.target.exists())

    def test_dry_run_and_successful_upgrade(self):
        with patch.object(m, "fetch", side_effect=AssertionError("dry run network")):
            self.assertEqual(self.installer.execute(self.tool, "install", True)["status"], "planned")
        self.assertFalse(self.installer.state.exists())
        self.install()
        with self.downloads("v0.1.1"), patch.object(m, "latest", return_value="v0.1.1"):
            self.assertTrue(self.installer.execute(self.tool, "upgrade")["changed"])
        self.assertEqual(m.check_version(self.target), "v0.1.1")

    def test_rechecks_destination_after_download(self):
        self.install()
        original = self.downloads("v0.1.1")
        with original, patch.object(m, "latest", return_value="v0.1.1"):
            real_extract = m.extract_binary
            def racing_extract(*args):
                real_extract(*args)
                self.target.write_text("concurrent user build")
            with patch.object(m, "extract_binary", side_effect=racing_extract):
                with self.assertRaises(m.InstallError):
                    self.installer.execute(self.tool, "upgrade")
        self.assertEqual(self.target.read_text(), "concurrent user build")

    def test_upgrade_preserves_actual_source_owner(self):
        self.target.parent.mkdir(parents=True)
        self.target.write_text("source fixture")
        self.target.chmod(0o755)
        self.installer.save_receipt(self.tool, "go", self.target, "v0.1.0")
        with patch.object(self.installer, "source", return_value=False) as source, patch.object(self.installer, "release", side_effect=AssertionError("channel changed")):
            self.installer.execute(self.tool, "upgrade")
        source.assert_called_once_with(self.tool, upgrade=True)

    def test_brew_migration_verifies_candidate_and_preserves_backup(self):
        self.installer.system = "Darwin"
        self.tool["method"] = "brew"
        self.target.parent.mkdir(parents=True)
        self.target.write_text("#!/bin/sh\necho 'lazypueue v0.0.1'\n")
        self.target.chmod(0o755)
        old = self.target.read_bytes()
        prefix = self.home / "Cellar/lazypueue/0.1.0"
        binary = prefix / "bin/lazypueue"
        binary.parent.mkdir(parents=True)
        binary.write_text("#!/bin/sh\necho 'lazypueue v0.1.0'\n")
        binary.chmod(0o755)
        real_run = m.run
        calls = []
        def runner(argv, **kwargs):
            if argv[0] == "/fixture/brew":
                calls.append(argv)
                if "--prefix" in argv:
                    return str(prefix)
                return ""
            return real_run(argv, **kwargs)
        real_which = m.shutil.which
        with patch.object(self.installer, "legacy_go", return_value=True), patch.object(m, "run", side_effect=runner), patch.object(m.shutil, "which", side_effect=lambda name: "/fixture/brew" if name == "brew" else real_which(name)), patch.object(m.subprocess, "run", wraps=m.subprocess.run) as command:
            original = command.side_effect
            real_subprocess = command._mock_wraps
            command.side_effect = lambda argv, **kwargs: subprocess.CompletedProcess(argv, 0, "", "") if argv[0] == "/fixture/brew" else real_subprocess(argv, **kwargs)
            self.assertTrue(self.installer.execute(self.tool, "install")["changed"])
        self.assertFalse(self.target.exists())
        receipt = self.installer.receipt(self.tool)
        self.assertEqual(Path(receipt["backup"]).read_bytes(), old)
        self.assertEqual(receipt["method"], "brew")
        self.assertTrue(any("install" in argv for argv in calls))

    def test_other_brew_formula_is_not_adopted(self):
        other = self.home / "Cellar/another-tool/1.0/bin/lazypueue"
        other.parent.mkdir(parents=True)
        other.write_text("other owner's binary")
        self.target.parent.mkdir(parents=True)
        self.target.symlink_to(other)
        self.assertEqual(self.installer.owner(self.tool, self.target), "unknown")

    def test_unresolved_mise_shim_cannot_bootstrap_go_from_probe(self):
        def which(name):
            return {"mise": "/fixture/mise", "go": str(self.home / ".local/share/mise/shims/go")}.get(name)
        with patch.object(m.shutil, "which", side_effect=which), patch.object(m, "run", side_effect=m.InstallError("runtime absent")):
            self.assertIsNone(self.installer.go_command())

    def test_legacy_source_build_is_staged_and_receipted_without_other_runtimes(self):
        tool = next(t for t in m.selection(m.load_tools(), "legacy", "Linux", True) if t["id"] == "lazyclash")
        calls = []
        def fake_go(argv, **kwargs):
            calls.append(argv)
            if argv[1] == "install":
                self.assertEqual(argv[2], tool["source"] + "@v0.1.7")
                env = kwargs["env"]
                self.assertEqual(env["GOPATH"], str(self.home / ".local/share/go"))
                self.assertNotEqual(env["GOBIN"], str(self.home / ".local/bin"))
                candidate = Path(env["GOBIN"]) / "lazyclash"
                candidate.write_text("#!/bin/sh\necho 'lazyclash v0.1.7'\n")
                candidate.chmod(0o755)
                return ""
            return f"/candidate:\n\tpath\t{tool['source']}\n\tmod\tgithub.com/{tool['repo']}\tv0.1.7\th1:fixture\n"
        with patch.object(self.installer, "go_command", return_value="/fixture/go"), patch.object(m, "run", side_effect=fake_go):
            self.assertTrue(self.installer.execute(tool, "install")["changed"])
            self.assertFalse(self.installer.execute(tool, "install")["changed"])
        self.assertEqual(sum(argv[1] == "install" for argv in calls), 1)
        self.assertEqual(self.installer.receipt(tool)["method"], "go")


@unittest.skipUnless(m.shutil.which("chezmoi"), "chezmoi unavailable")
class TemplateTests(unittest.TestCase):
    def test_selected_suite_survives_extra_runtime_gate_and_no_root(self):
        hook = (ROOT / ".chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl").read_text()
        brew = (ROOT / "dot_config/homebrew/Brewfile.tmpl").read_text()
        for system, profile in (("darwin", "macos"), ("linux", "ubuntu_server")):
            for enabled in (None, False, True):
                for extra in (False, True):
                    for no_root in (False, True):
                        with self.subTest(system=system, enabled=enabled, extra=extra, no_root=no_root):
                            data = {"profile": profile, "installExtraRuntimes": extra, "noRoot": no_root,
                                    "chezmoi": {"os": system, "arch": "arm64", "sourceDir": str(ROOT)}}
                            if enabled is not None:
                                data["installPersonalTools"] = enabled
                            args = ["chezmoi", "--source", str(ROOT), "execute-template", "--override-data", json.dumps(data)]
                            result = subprocess.run(args, input=hook, capture_output=True, text=True, check=True)
                            mode = "legacy" if enabled is None else "enabled" if enabled else "disabled"
                            self.assertIn("personal_tools_mode=" + mode, result.stdout)
                            self.assertIn(",personal_tools,", result.stdout)
                            self.assertNotIn('TAGS="${TAGS//,personal_tools/}"', result.stdout)
                            self.assertEqual('TAGS="${TAGS//,go_tools/}"' in result.stdout, not extra)
                            rendered = subprocess.run(args, input=brew, capture_output=True, text=True, check=True).stdout
                            self.assertNotIn('brew "daviddwlee84/tap/', rendered)


class AnsibleTests(unittest.TestCase):
    @unittest.skipUnless(m.shutil.which("ansible-playbook"), "ansible-playbook unavailable")
    def test_real_role_disabled_and_check_mode_do_not_install(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            config = tmp / "ansible.cfg"
            config.write_text("[defaults]\nroles_path = " + str(ROOT / "dot_ansible/roles") + "\n")
            play = tmp / "play.yml"
            play.write_text(f'''- hosts: localhost
  gather_facts: false
  vars:
    personal_tools_mode: disabled
    personal_tools_extra_runtimes: false
    ansible_facts:
      system: Linux
      architecture: x86_64
      python:
        executable: {sys.executable}
      env:
        HOME: {tmp}
        PATH: /usr/bin:/bin
  roles:
    - personal_tools
''')
            env = dict(os.environ, ANSIBLE_CONFIG=str(config), ANSIBLE_LOCAL_TEMP=str(tmp / "local"), ANSIBLE_REMOTE_TEMP=str(tmp / "remote"))
            for extra in ([], ["--check"]):
                result = subprocess.run(["ansible-playbook", "-i", "localhost,", "-c", "local", str(play), *extra], env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse((tmp / ".local/bin").exists())


if __name__ == "__main__":
    unittest.main()
