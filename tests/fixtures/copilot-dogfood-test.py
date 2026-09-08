#!/usr/bin/env python3
"""Offline checks for the isolated dogfood runner; no credentials or inference."""

import http.server
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import threading
import unittest
import urllib.error
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[2] / "scripts/copilot_proxy/dogfood.py"
SPEC = importlib.util.spec_from_file_location("dogfood", SCRIPT)
dogfood = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(dogfood)


class DogfoodTest(unittest.TestCase):
    def test_budget_reservation_cannot_be_reset(self):
        with tempfile.TemporaryDirectory() as temporary:
            marker = Path(temporary) / "run.json"
            dogfood.reserve_budget(marker, {"remaining": 6})
            with self.assertRaises(FileExistsError):
                dogfood.reserve_budget(marker, {"remaining": 12})
            self.assertEqual(json.loads(marker.read_text()), {"remaining": 6})

    def test_refuses_broad_root(self):
        with self.assertRaises(ValueError):
            dogfood.trial_root("/tmp")
        with self.assertRaises(ValueError):
            dogfood.trial_root(str(Path.home()))

    def test_environment_isolation_without_changing_home(self):
        with patch.dict(dogfood.os.environ, {"HOME": "/existing", "CODEX_HOME": "/client",
                                           "COPILOT_API_GITHUB_TOKEN": "do-not-forward"}):
            env = dogfood.child_env(Path("/tmp/copilot-dogfood-fixture"))
        self.assertEqual(env["HOME"], "/existing")
        self.assertEqual(env["CODEX_HOME"], "/client")
        self.assertNotIn("COPILOT_API_GITHUB_TOKEN", env)
        self.assertTrue(env["XDG_DATA_HOME"].endswith("/data"))
        self.assertTrue(env["XDG_CACHE_HOME"].endswith("/shared-cache"))

    def test_artifact_verification_detects_changed_installed_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "package.tgz"
            with tarfile.open(archive, "w:gz") as package:
                info = tarfile.TarInfo("package/package.json")
                content = b'{"version":"fixture"}'
                info.size = len(content)
                package.addfile(info, io.BytesIO(content))
            installed = root / "installed"
            installed.mkdir()
            (installed / "package.json").write_bytes(content)
            integrity = dogfood.base64.b64encode(dogfood.hashlib.sha512(archive.read_bytes()).digest()).decode()
            with patch.dict(dogfood.VERSIONS, {"fixture": integrity}):
                self.assertIn("package.json", dogfood.verified_runtime(archive, installed, "fixture"))
                (installed / "package.json").write_bytes(b"changed")
                with self.assertRaises(ValueError):
                    dogfood.verified_runtime(archive, installed, "fixture")

    def test_timeout_stops_only_the_owned_process_group(self):
        original = dogfood.subprocess.Popen
        sibling = original([dogfood.sys.executable, "-c", "import time; time.sleep(30)"],
                           start_new_session=True)
        owned = []

        def capture(*args, **kwargs):
            process = original(*args, **kwargs)
            owned.append(process)
            return process

        try:
            with tempfile.TemporaryDirectory() as temporary:
                with patch.object(dogfood.subprocess, "Popen", side_effect=capture):
                    with self.assertRaises(dogfood.subprocess.TimeoutExpired):
                        dogfood.command([dogfood.sys.executable, "-c", "import time; time.sleep(30)"],
                                        dogfood.os.environ.copy(), Path(temporary) / "child.log", timeout=1)
            self.assertEqual(len(owned), 1)
            self.assertIsNotNone(owned[0].poll())
            self.assertIsNone(sibling.poll())
        finally:
            dogfood.terminate(sibling)

    def test_exited_leader_does_not_leave_its_descendant_running(self):
        script = ("import subprocess,sys; p=subprocess.Popen([sys.executable,'-c',"
                  "'import time; time.sleep(30)']); print(p.pid,flush=True)")
        parent = dogfood.subprocess.Popen([dogfood.sys.executable, "-c", script],
                                           stdout=dogfood.subprocess.PIPE,
                                           text=True, start_new_session=True)
        child_pid = int(parent.stdout.readline())
        parent.stdout.close()
        parent.wait(timeout=5)
        dogfood.terminate(parent, grace=0.3)
        check = dogfood.subprocess.run(["ps", "-p", str(child_pid), "-o", "stat="],
                                        capture_output=True, text=True, check=False)
        self.assertTrue(check.returncode != 0 or check.stdout.strip().startswith("Z"),
                        "owned descendant remained runnable after its parent exited")

    def test_budget_is_enforced_before_upstream_dispatch(self):
        calls = []

        class FakeUpstream(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_POST(self):
                calls.append(self.rfile.read(int(self.headers["Content-Length"])))
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                event = {"type": "response.completed", "response": {"status": "completed"}}
                self.wfile.write(("event: response.completed\ndata: " + json.dumps(event) + "\n\n").encode())

        upstream = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeUpstream)
        proxy = dogfood.BudgetProxy(upstream.server_port, 1)
        threads = [threading.Thread(target=server.serve_forever, daemon=True)
                   for server in (upstream, proxy)]
        for thread in threads:
            thread.start()
        try:
            self.assertEqual(dogfood.responses_call(proxy.server_port, []), {"status": "completed"})
            with self.assertRaises(urllib.error.HTTPError) as error:
                dogfood.responses_call(proxy.server_port, [])
            self.assertEqual(error.exception.code, 429)
            error.exception.close()
            self.assertEqual(len(calls), 1)
            self.assertEqual(proxy.dispatched, 1)
            self.assertEqual(proxy.close_admission(), 1)
            with self.assertRaises(urllib.error.HTTPError) as closed:
                dogfood.responses_call(proxy.server_port, [])
            self.assertEqual(closed.exception.code, 503)
            closed.exception.close()
            self.assertEqual(proxy.close_admission(), 1)
            self.assertEqual(len(calls), 1)
        finally:
            for server in (proxy, upstream):
                server.shutdown()
                server.server_close()


if __name__ == "__main__":
    unittest.main()
