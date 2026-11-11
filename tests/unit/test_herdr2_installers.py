"""Exercise the Herdr 2 installer tasks (Herdr App, herdr-core) without installing.

Both tasks download a pinned upstream installer, verify its SHA-256 and only
then run it. These tests drive the real task YAML against local fixtures: the
presence/arch gates, and that a checksum mismatch is reported through the
rescue without ever reaching the installer.
"""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest

REPO = Path(__file__).resolve().parents[2]
APP_TASKS = REPO / 'dot_ansible/roles/gui_apps_linux/tasks/herdr-app.yml'
DEVTOOLS = REPO / 'dot_ansible/roles/devtools/tasks/main.yml'
CORE_TASK_NAMES = (
    'Check if herdr-core is installed',
    'Install herdr-core with the pinned upstream installer (user-level)',
)
ANSIBLE = shutil.which('ansible-playbook')
PYTHON = sys.executable
if ANSIBLE:
    shebang = Path(ANSIBLE).read_text().splitlines()[0].removeprefix('#!')
    if Path(shebang).is_file():
        PYTHON = shebang


def load_yaml(path):
    return json.loads(subprocess.check_output([
        PYTHON, '-c',
        'import yaml,json,sys; print(json.dumps(yaml.safe_load(open(sys.argv[1]))))',
        str(path),
    ], text=True))


# Safety net: unless a test explicitly points it at a fixture server, the
# installer URL is unreachable, so a presence-check regression can never run
# the real upstream installer against the developer's machine.
DISARMED = 'http://127.0.0.1:9/never-download.sh'


def app_tasks():
    tasks = load_yaml(APP_TASKS)
    tasks[-1]['vars']['herdr_app_installer_url'] = DISARMED
    return tasks


def core_tasks():
    tasks = [t for t in load_yaml(DEVTOOLS) if t.get('name') in CORE_TASK_NAMES]
    assert [t['name'] for t in tasks] == list(CORE_TASK_NAMES), tasks
    tasks[-1]['vars']['herdr_core_installer_url'] = DISARMED
    return tasks


@unittest.skipUnless(ANSIBLE, 'ansible-playbook required')
class Herdr2InstallerTest(unittest.TestCase):
    def play(self, tmp, tasks, *, family='Debian', arch='x86_64', check=False):
        # Drop the real host's home dirs (~/.local/bin may hold real Herdr
        # binaries) so presence checks only see this test's fixtures.
        home = os.path.expanduser('~')
        host_path = [d for d in os.environ['PATH'].split(os.pathsep)
                     if d and not d.startswith(home)]
        path = os.pathsep.join([str(Path(tmp) / 'bin')] + host_path)
        play = [{
            'hosts': 'localhost', 'connection': 'local', 'gather_facts': False,
            # XDG_DATA_HOME too: a host export would point the presence
            # check at the developer's real data dir.
            'environment': {'PATH': path, 'HOME': tmp,
                            'XDG_DATA_HOME': str(Path(tmp) / '.local/share')},
            'vars': {
                'ansible_python_interpreter': PYTHON,
                'ansible_facts': {'os_family': family, 'env': {'HOME': tmp, 'PATH': path}},
                'target_architecture': arch,
            },
            'tasks': tasks,
        }]
        playfile = Path(tmp) / 'play.json'
        playfile.write_text(json.dumps(play))
        args = ['ansible-playbook', '-i', 'localhost,', str(playfile)]
        if check:
            args.append('--check')
        result = subprocess.run(args, text=True, capture_output=True)
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        return output

    def stub(self, tmp, name):
        bindir = Path(tmp) / 'bin'
        bindir.mkdir(exist_ok=True)
        exe = bindir / name
        exe.write_text('#!/bin/sh\nexit 0\n')
        exe.chmod(0o755)

    # --- Herdr App ---------------------------------------------------------
    def test_app_missing_compatible_is_check_only(self):
        with tempfile.TemporaryDirectory(prefix='herdr-app-test-') as tmp:
            out = self.play(tmp, app_tasks() + [{'ansible.builtin.assert': {'that': [
                'herdr_app_available.rc != 0', 'herdr_app_supported | bool']}}], check=True)
            self.assertIn('changed=0', out)

    def test_app_on_path_is_preserved(self):
        with tempfile.TemporaryDirectory(prefix='herdr-app-test-') as tmp:
            self.stub(tmp, 'herdr-app')
            out = self.play(tmp, app_tasks() + [{'ansible.builtin.assert': {'that': [
                'herdr_app_available.rc == 0']}}])
            self.assertIn('changed=0', out)

    def test_app_data_dir_counts_as_installed(self):
        with tempfile.TemporaryDirectory(prefix='herdr-app-test-') as tmp:
            (Path(tmp) / '.local/share/herdr-app').mkdir(parents=True)
            self.play(tmp, app_tasks() + [{'ansible.builtin.assert': {'that': [
                'herdr_app_available.rc == 0']}}])

    def test_app_unsupported_arch_skips(self):
        with tempfile.TemporaryDirectory(prefix='herdr-app-test-') as tmp:
            out = self.play(tmp, app_tasks(), arch='armv7l')
            self.assertIn('Herdr App skipped', out)
            self.assertIn('changed=0', out)

    # --- herdr-core --------------------------------------------------------
    def test_core_existing_is_preserved(self):
        with tempfile.TemporaryDirectory(prefix='herdr-core-test-') as tmp:
            self.stub(tmp, 'herdr-core')
            out = self.play(tmp, core_tasks() + [{'ansible.builtin.assert': {'that': [
                'herdr_core_check.rc == 0']}}], family='Darwin')
            self.assertIn('changed=0', out)

    def test_core_unsupported_os_family_skips(self):
        with tempfile.TemporaryDirectory(prefix='herdr-core-test-') as tmp:
            out = self.play(tmp, core_tasks(), family='Alpine')
            self.assertIn('changed=0', out)

    # --- checksum refusal (both) -------------------------------------------
    def checksum_refusal(self, tasks, url_var, failure_text):
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_GET(self):
                body = b'#!/bin/sh\necho SHOULD-NOT-RUN\n'
                self.send_response(200)
                self.end_headers()
                self.wfile.write(body)

        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            install = tasks[-1]
            install['vars'][url_var] = 'http://127.0.0.1:%d/install.sh' % server.server_port
            with tempfile.TemporaryDirectory(prefix='herdr2-sum-') as tmp:
                out = self.play(tmp, tasks)
                self.assertIn(failure_text, out)
                self.assertIn('checksum', out.lower())
                self.assertNotIn('SHOULD-NOT-RUN', out)
                self.assertNotIn('TASK [Run the', out)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_app_checksum_mismatch_never_runs_installer(self):
        self.checksum_refusal(app_tasks(), 'herdr_app_installer_url',
                              'Herdr App installation failed:')

    def test_core_checksum_mismatch_never_runs_installer(self):
        self.checksum_refusal(core_tasks(), 'herdr_core_installer_url',
                              'herdr-core installation failed:')


if __name__ == '__main__':
    unittest.main()
