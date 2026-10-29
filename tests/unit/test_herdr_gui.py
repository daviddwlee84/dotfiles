"""Exercise GUI compatibility against the real Ansible tasks without downloads."""
import json
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
TASKS = REPO / 'dot_ansible/roles/gui_apps_linux/tasks/herdr-gui.yml'
ANSIBLE = shutil.which('ansible-playbook')
# Prefer Ansible's own interpreter (e.g. uv tools) over an unrelated host Python.
PYTHON = sys.executable
if ANSIBLE:
    shebang = Path(ANSIBLE).read_text().splitlines()[0].removeprefix('#!')
    if Path(shebang).is_file():
        PYTHON = shebang


@unittest.skipUnless(shutil.which('ansible-playbook'), 'ansible-playbook required')
class HerdrGuiCompatibilityTest(unittest.TestCase):
    def run_case(self, *, libc='2.39', arch='x86_64', no_root=False,
                 family='Debian', existing=False, supported=True):
        with tempfile.TemporaryDirectory(prefix='herdr-gui-test-') as tmp:
            root = Path(tmp)
            stub = root / 'getconf'
            stub.write_text('#!/bin/sh\nprintf "glibc ' + libc + '\\n"\n')
            stub.chmod(0o755)
            if existing:
                stub = root / 'herdr-gpui'
                stub.write_text('#!/bin/sh\nexit 0\n')
                stub.chmod(0o755)
            path = str(root) + os.pathsep + os.environ['PATH']
            play = [{
                'hosts': 'localhost', 'connection': 'local', 'gather_facts': False,
                'environment': {'PATH': path},
                'vars': {
                    'ansible_python_interpreter': PYTHON,
                    'ansible_facts': {'os_family': family, 'env': {'HOME': tmp, 'PATH': path}},
                    'target_architecture': arch, 'gui_apps_linux_no_root': no_root,
                },
                'tasks': [
                    {'ansible.builtin.import_tasks': str(TASKS)},
                    {'ansible.builtin.assert': {'that': [
                        'herdr_gui_libc.rc == 0',
                        'herdr_gui_supported | bool == ' + str(supported).lower(),
                        'herdr_gui_available.rc == ' + ('0' if existing else '1'),
                    ]}},
                ],
            }]
            playfile = root / 'play.json'
            playfile.write_text(json.dumps(play))
            # Compatible missing install is check-only; other cases also prove
            # a real apply cannot enter the network/package block.
            args = ['ansible-playbook', '-i', 'localhost,', str(playfile)]
            if supported and not existing:
                args.append('--check')
            result = subprocess.run(args, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('changed=0', result.stdout)

    def test_compatible_missing_check_mode(self):
        self.run_case()

    def test_existing_arm64_install_is_preserved(self):
        self.run_case(arch='aarch64', existing=True)

    def test_old_glibc_skips(self):
        self.run_case(libc='2.35', supported=False)

    def test_no_root_skips(self):
        self.run_case(no_root=True, supported=False)

    def test_unsupported_architecture_skips(self):
        self.run_case(arch='armv7l', supported=False)

    def test_other_distribution_skips(self):
        self.run_case(family='RedHat', supported=False)

    def run_failure_case(self, failure):
        # Run the actual download/rescue/cleanup tasks against local HTTP
        # fixtures. Replace only apt itself so this cannot install software.
        with tempfile.TemporaryDirectory(prefix='herdr-gui-download-') as tmp:
            package = b'fixture package'
            asset = 'Herdr-20261029.1-x86_64-unknown-linux-gnu.deb'
            checksum = hashlib.sha256(package).hexdigest()
            if failure == 'checksum':
                checksum = '0' * 64

            class Handler(BaseHTTPRequestHandler):
                def log_message(self, *_args):
                    pass

                def do_GET(self):
                    if self.path == '/release':
                        body = json.dumps({'assets': [{
                            'name': asset,
                            'browser_download_url': base + '/' + asset,
                        }]}).encode()
                    elif self.path.endswith('.sha256'):
                        body = (checksum + '  ' + asset + '\n').encode()
                    elif failure == 'download':
                        self.send_error(503)
                        return
                    else:
                        body = package
                    self.send_response(200)
                    if self.path == '/release':
                        self.send_header('Content-Type', 'application/json')
                    self.end_headers()
                    self.wfile.write(body)

            server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
            base = 'http://127.0.0.1:' + str(server.server_port)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                tasks = json.loads(subprocess.check_output([
                    PYTHON, '-c',
                    'import yaml,json,sys; print(json.dumps(yaml.safe_load(open(sys.argv[1]))))',
                    str(TASKS),
                ], text=True))
                # Compatibility and presence are tested separately above.
                install = tasks[-1]
                install.pop('when')
                install['block'][0]['ansible.builtin.uri']['url'] = base + '/release'
                install['block'][-1] = {
                    'name': 'Fixture package manager failure',
                    'ansible.builtin.fail': {'msg': 'fixture apt failure'},
                }
                play = [{
                    'hosts': 'localhost', 'connection': 'local', 'gather_facts': False,
                    'vars': {'ansible_python_interpreter': PYTHON,
                             'target_architecture': 'x86_64'},
                    'tasks': [install, {
                        'ansible.builtin.stat': {'path': '{{ herdr_gui_tmp.path }}'},
                        'register': 'download_dir',
                    }, {'ansible.builtin.assert': {'that': ['not download_dir.stat.exists']}}],
                }]
                path = Path(tmp) / 'play.json'
                path.write_text(json.dumps(play))
                result = subprocess.run(['ansible-playbook', '-i', 'localhost,', str(path)],
                                        text=True, capture_output=True)
                output = result.stdout + result.stderr
                self.assertEqual(result.returncode, 0, output)
                self.assertIn('Herdr UI installation failed:', output)
                if failure == 'checksum':
                    self.assertIn('checksum', output.lower())
                if failure == 'download':
                    self.assertIn('503', output)
                if failure == 'install':
                    self.assertIn('fixture apt failure', output)
                else:
                    self.assertNotIn('TASK [Fixture package manager failure]', output)
            finally:
                server.shutdown()
                server.server_close()
                thread.join()

    def test_checksum_mismatch_cannot_reach_package_install(self):
        self.run_failure_case('checksum')

    def test_download_failure_cannot_reach_package_install(self):
        self.run_failure_case('download')

    def test_install_failure_is_reported_and_downloads_are_cleaned(self):
        self.run_failure_case('install')
