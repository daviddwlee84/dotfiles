"""Exercise Tasks installer guards and loopback releases with real Ansible.

The complete suite must not contact a package manager; an unusable companion
must not let configuration bootstrap claim the installation is ready.
Release fixtures contain shell executables, not platform-native release builds.
The extraction cases require GNU tar, just like the Linux unarchive module;
checksum rejection and guard tests also run on macOS without installing GNU tar.
"""

import functools
import hashlib
import http.server
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[2]
INSTALLER = ROOT / "dot_ansible/roles/coding_agents/tasks/tasks.yml"


def has_gnu_tar():
    tar = shutil.which("gtar") or shutil.which("tar")
    if not tar:
        return False
    result = subprocess.run([tar, "--version"], capture_output=True, text=True)
    return result.returncode == 0 and "GNU tar" in result.stdout


@unittest.skipUnless(shutil.which("ansible-playbook"), "ansible-playbook required")
class TasksInstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="tasks-installer-")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.bin = self.home / ".local/bin"
        self.bin.mkdir(parents=True)
        for name in ("tasks", "tasks-tui", "tasks-api"):
            self.executable(name, f'#!/bin/sh\n[ "$1" = --version ] || exit 91\nprintf "{name} v1.0.0\\n"\n')
        self.executable("brew", '#!/bin/sh\nprintf "%s\\n" "$*" >> "$HOME/brew-calls"\nexit 0\n')

        # Preserve the production installer verbatim. Its bootstrap dependency
        # is replaced by a marker; the separate config tests cover that file.
        self.installer = self.home / "tasks.yml"
        self.installer.write_text(INSTALLER.read_text())
        (self.home / "tasks-config.yml").write_text(
            '- name: Fixture bootstrap marker\n'
            '  ansible.builtin.debug:\n'
            '    msg: "BOOTSTRAP_READY {{ tasks_suite_available }} {{ tasks_cli_path }}"\n'
        )
        config = self.home / "ansible.cfg"
        config.write_text("[defaults]\ninject_facts_as_vars = False\n")
        self.env = dict(
            os.environ,
            ANSIBLE_CONFIG=str(config),
            ANSIBLE_NOCOLOR="1",
            ANSIBLE_STDOUT_CALLBACK="default",
            ANSIBLE_LOCAL_TEMP=str(self.home / "ansible-local"),
            ANSIBLE_REMOTE_TEMP=str(self.home / "ansible-remote"),
        )
        self.downloads = self.home / "downloads"
        self.downloads.mkdir()

    def executable(self, name, contents):
        path = self.bin / name
        path.write_text(contents)
        path.chmod(0o755)

    def run_installer(self, *, check=False, arch="aarch64"):
        play = [{
            "hosts": "localhost", "connection": "local", "gather_facts": False,
            "environment": {"HOME": str(self.home), "TMPDIR": str(self.downloads),
                            "NO_PROXY": "127.0.0.1,localhost", "no_proxy": "127.0.0.1,localhost"},
            "vars": {
                "ansible_python_interpreter": sys.executable,
                "ansible_facts": {
                    "os_family": "Debian", "architecture": arch,
                    "python": {"executable": sys.executable},
                    "env": {"HOME": str(self.home), "PATH": "/usr/bin:/bin"},
                },
            },
            "tasks": [{"ansible.builtin.import_tasks": str(self.installer),
                       "tags": ["coding_agents_tasks"]}],
        }]
        path = self.home / "play.json"
        path.write_text(json.dumps(play))
        argv = ["ansible-playbook", "-i", "localhost,", str(path), "--tags", "coding_agents_tasks"]
        if check:
            argv.append("--check")
        result = subprocess.run(argv, env=self.env, capture_output=True, text=True, timeout=90)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def release_fixture(self, *, checksum_ok=True, missing=(), invalid=()):
        """Replace only fixture inputs; Ansible performs the actual install flow."""
        if not hasattr(self, "release_root"):
            self.release_root = self.home / "releases"
            self.release_root.mkdir()
            self.requests = []
            self.stages_seen = set()
            requests = self.requests
            stages_seen = self.stages_seen
            downloads = self.downloads

            class Handler(http.server.SimpleHTTPRequestHandler):
                def guess_type(self, path):
                    if path.endswith("/releases/latest"):
                        return "application/json"
                    return super().guess_type(path)

                def do_GET(self):
                    requests.append(self.path)
                    stages_seen.update(downloads.glob("tasks-install-*"))
                    super().do_GET()

                def log_message(self, *_args):
                    pass

            server = http.server.ThreadingHTTPServer(
                ("127.0.0.1", 0), functools.partial(Handler, directory=str(self.release_root)))
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()

            def close_server():
                server.shutdown()
                thread.join(timeout=5)
                server.server_close()

            self.addCleanup(close_server)
            self.release_url = f"http://127.0.0.1:{server.server_port}"
            source = INSTALLER.read_text()
            self.assertIn("https://api.github.com/repos/marcus/tasks/releases/latest", source)
            self.assertIn("https://github.com/marcus/tasks/releases/download/", source)
            installer = source.replace(
                "https://api.github.com/repos/marcus/tasks/releases/latest",
                self.release_url + "/releases/latest",
            ).replace(
                "https://github.com/marcus/tasks/releases/download/{{ tasks_suite_release.json.tag_name }}",
                self.release_url + "/download/{{ tasks_suite_release.json.tag_name }}",
            ).replace(
                "{{ ansible_facts['env']['HOME'] }}/.local/bin:/opt/homebrew/bin:/usr/local/bin:{{ ansible_facts['env']['HOME'] }}/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/bin:{{ ansible_facts['env']['PATH'] }}",
                "{{ ansible_facts['env']['HOME'] }}/.local/bin:{{ ansible_facts['env']['PATH'] }}",
            )
            self.assertNotIn("https://api.github.com/", installer)
            self.assertNotIn("https://github.com/", installer)
            self.installer.write_text(installer)

        release = self.release_root / "download/v9.8.7"
        release.mkdir(parents=True, exist_ok=True)
        metadata = self.release_root / "releases/latest"
        metadata.parent.mkdir(exist_ok=True)
        metadata.write_text(json.dumps({"tag_name": "v9.8.7"}))
        wrapper = "tasks_9.8.7_linux_arm64"
        archive = release / (wrapper + ".tar.gz")
        with tarfile.open(archive, "w:gz") as output:
            for name in ("tasks", "tasks-tui", "tasks-api"):
                if name in missing:
                    continue
                version = "different task service 9.8.7" if name in invalid else name + " v9.8.7"
                payload = ('#!/bin/sh\n[ "$1" = --version ] || exit 91\n'
                           f"printf '{version}\\n'\n").encode()
                member = tarfile.TarInfo(wrapper + "/" + name)
                member.mode = 0o755
                member.size = len(payload)
                output.addfile(member, io.BytesIO(payload))
        checksum = hashlib.sha256(archive.read_bytes()).hexdigest() if checksum_ok else "0" * 64
        (release / "checksums.txt").write_text(f"{checksum}  {archive.name}\n")

    def remove_companions(self):
        for name in ("tasks-tui", "tasks-api"):
            (self.bin / name).unlink()

    def assert_release_was_downloaded_and_cleaned(self):
        self.assertIn("/releases/latest", self.requests)
        self.assertIn("/download/v9.8.7/checksums.txt", self.requests)
        self.assertIn("/download/v9.8.7/tasks_9.8.7_linux_arm64.tar.gz", self.requests)
        self.assertTrue(self.stages_seen, "the download must use the private staging directory")
        self.assertTrue(all(not path.exists() for path in self.stages_seen), "staging directories must be removed")
        self.assertEqual(list(self.downloads.glob("tasks-install-*")), [])

    def test_complete_suite_skips_package_managers_and_bootstraps_under_narrow_tag(self):
        output = self.run_installer()
        self.assertIn("BOOTSTRAP_READY True " + str(self.bin / "tasks"), output)
        self.assertRegex(output, r"changed=0\s")
        self.assertFalse((self.home / "brew-calls").exists())

    def test_check_mode_probes_companions_without_installing_or_bootstrapping(self):
        self.executable("tasks-api", "#!/bin/sh\nprintf 'different task service 4.0\\n'\n")
        output = self.run_installer(check=True)
        self.assertIn("Tasks suite is unavailable or incomplete: tasks-api", output)
        self.assertNotIn("BOOTSTRAP_READY True", output)
        self.assertRegex(output, r"changed=0\s")
        self.assertEqual((self.home / "brew-calls").read_text(), "--prefix\n")

    def test_unsupported_arch_skips_downloads_and_preserves_existing_commands(self):
        self.executable("tasks-api", "#!/bin/sh\nexit 7\n")
        before = {path.name: path.read_bytes() for path in self.bin.iterdir()}
        output = self.run_installer(arch="armv7l")
        self.assertIn("unsupported architecture armv7l", output)
        self.assertNotIn("BOOTSTRAP_READY True", output)
        self.assertEqual(before, {path.name: path.read_bytes() for path in self.bin.iterdir()})
        self.assertEqual((self.home / "brew-calls").read_text(), "--prefix\n")

    @unittest.skipUnless(has_gnu_tar(), "GNU tar required for the real Linux extraction fixture")
    def test_verified_release_fills_missing_commands_without_upgrading_present_binary(self):
        self.remove_companions()
        before = (self.bin / "tasks").read_bytes()
        self.release_fixture()
        output = self.run_installer()
        self.assertIn("BOOTSTRAP_READY True", output)
        self.assertEqual((self.bin / "tasks").read_bytes(), before)
        for name in ("tasks-tui", "tasks-api"):
            result = subprocess.run([str(self.bin / name), "--version"], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout.strip(), name + " v9.8.7")
        self.assert_release_was_downloaded_and_cleaned()
        request_count = len(self.requests)
        output = self.run_installer()
        self.assertRegex(output, r"changed=0\s")
        self.assertEqual(len(self.requests), request_count, "second apply must not fetch or upgrade")

    def test_checksum_mismatch_prevents_extraction_and_installation(self):
        self.remove_companions()
        before = (self.bin / "tasks").read_bytes()
        self.release_fixture(checksum_ok=False)
        output = self.run_installer()
        self.assertIn("Tasks release installation failed", output)
        self.assertNotIn("Verify all Tasks release commands start", output)
        self.assertNotIn("BOOTSTRAP_READY True", output)
        self.assertEqual((self.bin / "tasks").read_bytes(), before)
        self.assertFalse((self.bin / "tasks-tui").exists())
        self.assertFalse((self.bin / "tasks-api").exists())
        self.assert_release_was_downloaded_and_cleaned()

    @unittest.skipUnless(has_gnu_tar(), "GNU tar required for the real Linux extraction fixture")
    def test_incomplete_or_wrong_product_candidate_prevents_all_destination_writes(self):
        self.remove_companions()
        before = (self.bin / "tasks").read_bytes()
        for options in ({"missing": ("tasks-api",)}, {"invalid": ("tasks-api",)}):
            with self.subTest(options=options):
                self.release_fixture(**options)
                output = self.run_installer()
                self.assertIn("Tasks release installation failed", output)
                self.assertIn("Verify all Tasks release commands start", output)
                self.assertNotIn("BOOTSTRAP_READY True", output)
                self.assertEqual((self.bin / "tasks").read_bytes(), before)
                self.assertFalse((self.bin / "tasks-tui").exists())
                self.assertFalse((self.bin / "tasks-api").exists())
                self.assert_release_was_downloaded_and_cleaned()


if __name__ == "__main__":
    unittest.main()
