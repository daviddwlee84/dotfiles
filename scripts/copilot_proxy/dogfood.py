#!/usr/bin/env python3
"""Run a bounded, loopback-only Copilot upgrade trial on the selected host.

Run this script ON the dogfood host, with reviewed archives and a staged shim.
It never invokes the public proxy updater/stop helpers or changes HOME/CODEX_HOME.
All child processes, package caches, credentials, metrics and output are isolated.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import http.client
import http.server
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import tarfile
import threading
import time
import urllib.error
import urllib.request


VERSIONS = {
    "2.3.4": "yRMH3wQAH74a0K/3Gl0S3itSL7Dza/7qOGG32PXV3tKRd4feG3utpuIQf42HhnhIdcBwMz3qhmeWBPQrPxZQMQ==",
    "2.5.2": "bMVpuniekbKKq0LMtmZZJKjDVpaOODAHs19akwkP/hyGfgcx+YK0X22jfB46lQb0p9EoywDrJMyTcAfLr18jEQ==",
}
PORTS = {"2.3.4": (4241, 4242), "2.5.2": (4243, 4244)}
HOP_HEADERS = {"connection", "transfer-encoding", "content-length", "keep-alive"}
LOCAL_HTTP = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def save_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def reserve_budget(path: Path, value: object) -> None:
    # Exclusive creation makes concurrent invocations fail before either can
    # obtain a second allocation. A partial/crashed reservation also fails closed.
    with path.open("x", encoding="utf-8") as output:
        output.write(json.dumps(value, indent=2) + "\n")
        output.flush()
        os.fsync(output.fileno())


def trial_root(value: str) -> Path:
    root = Path(value).resolve()
    if not root.name.startswith("copilot-dogfood-") or root.parent == root:
        raise ValueError("trial root must be a dedicated copilot-dogfood-* directory")
    if root in (Path.home(), Path.cwd(), Path("/")):
        raise ValueError("refusing a broad trial root")
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    root.chmod(0o700)
    return root


def child_env(root: Path) -> dict[str, str]:
    env = os.environ.copy()
    env.pop("COPILOT_API_GITHUB_TOKEN", None)
    for key in ("CONFIG", "DATA", "STATE"):
        env[f"XDG_{key}_HOME"] = str(root / key.lower())
    env["XDG_CACHE_HOME"] = str(root / "shared-cache")
    env["npm_config_cache"] = str(root / "npm-cache")
    env["BUN_INSTALL_CACHE_DIR"] = str(root / "bun-cache")
    env["NODE_ENV"] = "production"
    return env


def terminate(process: subprocess.Popen, grace: float = 8) -> None:
    # Only handles created by this runner; never kill by command-name matching.
    # The group may still contain descendants after its leader has exited.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        process.poll()
        return
    deadline = time.monotonic() + grace
    while time.monotonic() < deadline:
        process.poll()  # reap the leader before checking whether its group remains
        try:
            os.killpg(process.pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.05)
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    if process.poll() is None:
        process.wait(timeout=5)


def command(argv: list[str], env: dict[str, str], log: Path, timeout: int = 240,
            cwd: Path | None = None) -> None:
    with log.open("ab") as output:
        process = subprocess.Popen(argv, env=env, cwd=cwd, stdin=subprocess.DEVNULL,
                                   stdout=output, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        finally:
            terminate(process)
    if code:
        raise RuntimeError(f"{Path(argv[0]).name} failed ({code}); inspect {log}")


def verified_runtime(archive: Path, installed: Path, version: str) -> dict[str, str]:
    actual = base64.b64encode(hashlib.sha512(archive.read_bytes()).digest()).decode()
    if actual != VERSIONS[version]:
        raise ValueError(f"archive integrity mismatch for {version}")
    hashes = {}
    with tarfile.open(archive, "r:gz") as package:
        for member in package.getmembers():
            if not member.isfile():
                continue
            relative = Path(member.name).relative_to("package")
            if ".." in relative.parts or relative.is_absolute():
                raise ValueError("unsafe archive member")
            source = package.extractfile(member)
            assert source is not None
            expected = source.read()
            target = installed / relative
            if not target.is_file() or target.read_bytes() != expected:
                raise ValueError(f"staged runtime differs from archive: {relative}")
            hashes[str(relative)] = hashlib.sha256(expected).hexdigest()
    return hashes


def prepare(args: argparse.Namespace, root: Path) -> None:
    if (root / "run-report.json").exists():
        raise ValueError("cannot prepare over a trial that already allocated live traffic")
    seed = Path(args.backend_home).resolve()
    oauth = os.environ.get("COPILOT_API_OAUTH_APP", "").strip()
    if Path(oauth).is_absolute() or ".." in Path(oauth).parts:
        raise ValueError("invalid OAuth app path")
    prefix = "ent_" if os.environ.get("COPILOT_API_ENTERPRISE_URL") else ""
    token_relative = Path(oauth) / f"{prefix}github_token"
    credential = seed / token_relative
    if not credential.is_file() or not credential.stat().st_size:
        raise ValueError("existing remote Copilot credential is missing; no login attempted")
    env = child_env(root)
    shim = Path(args.shim).resolve()
    if shim != root / "copilot-throttle-shim.js":
        shutil.copyfile(shim, root / "copilot-throttle-shim.js")
    for version in VERSIONS:
        slot = root / version
        slot.mkdir(mode=0o700, exist_ok=True)
        home = slot / "backend-home"
        home.mkdir(mode=0o700, exist_ok=True)
        target = home / token_relative
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        shutil.copyfile(credential, target)
        target.chmod(0o600)
        if (seed / "config.json").exists():
            shutil.copyfile(seed / "config.json", home / "config.json")
            shutil.copyfile(seed / "config.json", slot / "config.before.json")
        archive = Path(getattr(args, "archive_" + version.replace(".", "_"))).resolve()
        digest = base64.b64encode(hashlib.sha512(archive.read_bytes()).digest()).decode()
        if digest != VERSIONS[version]:
            raise ValueError(f"archive integrity mismatch for {version}")
        package_dir = slot / "pkg"
        package_dir.mkdir(exist_ok=True)
        command([args.npm, "install", "--prefix", str(package_dir), "--ignore-scripts",
                 "--no-audit", "--no-fund", str(archive)], env, slot / "install.log")
        installed = package_dir / "node_modules/@jeffreycao/copilot-api"
        hashes = verified_runtime(archive, installed, version)
        command([args.node, str(installed / "dist/main.js"), "--help"], env,
                slot / "help.log", timeout=30)
        save_json(slot / "runtime-hashes.json", hashes)
        print(f"prepared {version}: {len(hashes)} archive files verified", flush=True)
    client = root / "client"
    client.mkdir(exist_ok=True)
    command([args.npm, "install", "--prefix", str(client), "--ignore-scripts",
             "--no-audit", "--no-fund", "@openai/codex@0.153.4"], env,
            root / "codex-install.log")
    command([str(client / "node_modules/.bin/codex"), "--version"], env,
            root / "codex-version.log", timeout=30)
    if (root / "codex-version.log").read_text().strip() != "codex-cli 0.153.4":
        raise ValueError("staged client does not match Codex 0.153.4")
    save_json(root / "trial.json", {
        "node": args.node, "bun": args.bun,
        "shim_sha256": hashlib.sha256(shim.read_bytes()).hexdigest(),
        "versions": list(VERSIONS), "codex": "0.153.4", "ports": PORTS,
        "max_logical_requests": 12, "max_backend_dispatches": 24,
    })


def get_json(port: int, endpoint: str, timeout: int = 3) -> dict:
    with LOCAL_HTTP.open(f"http://127.0.0.1:{port}{endpoint}", timeout=timeout) as response:
        return json.load(response)


class BudgetProxy(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, upstream_port: int, allowance: int):
        self.upstream_port = upstream_port
        self.allowance = allowance
        self.dispatched = 0
        self.admission_closed = False
        self.lock = threading.Lock()
        super().__init__(("127.0.0.1", 0), BudgetHandler)

    def close_admission(self) -> int:
        with self.lock:
            self.admission_closed = True
            return self.dispatched


class BudgetHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args: object) -> None:
        pass

    def do_GET(self) -> None:
        self.forward()

    def do_POST(self) -> None:
        if self.path.rstrip("/") not in ("/responses", "/v1/responses"):
            self.send_error(405, "dogfood permits only Responses inference")
            return
        with self.server.lock:
            if self.server.admission_closed:
                self.send_error(503, "dogfood trial admission is closed")
                return
            if self.server.dispatched >= self.server.allowance:
                self.send_error(429, "dogfood request budget exhausted")
                return
            self.server.dispatched += 1
        self.forward()

    def forward(self) -> None:
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP_HEADERS}
        upstream = http.client.HTTPConnection("127.0.0.1", self.server.upstream_port, timeout=360)
        try:
            upstream.request(self.command, self.path, body=body or None, headers=headers)
            response = upstream.getresponse()
            self.send_response(response.status)
            for key, value in response.getheaders():
                if key.lower() not in HOP_HEADERS:
                    self.send_header(key, value)
            self.send_header("Connection", "close")
            self.end_headers()
            while chunk := response.read1(8192):
                self.wfile.write(chunk)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            upstream.close()
            self.close_connection = True


def wait_ready(port: int, endpoint: str, process: subprocess.Popen, seconds: int = 60) -> dict:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("trial process exited during startup; inspect its private log")
        try:
            return get_json(port, endpoint)
        except (OSError, ValueError):
            time.sleep(0.25)
    raise TimeoutError("trial startup exceeded deadline; inspect private logs")


def check_ports(ports: tuple[int, int]) -> None:
    for port in ports:
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", port))


def metrics(path: Path) -> list[dict]:
    if not path.exists():
        return []
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    with connection:
        columns = {row[1] for row in connection.execute("PRAGMA table_info(request_metrics)")}
        wanted = [c for c in ("endpoint", "model", "status", "attempts", "retries", "error_kind",
                             "terminal_event", "request_kind", "timeout_owner", "drain_outcome",
                             "e2e_ms", "first_byte_ms") if c in columns]
        rows = [dict(row) for row in connection.execute(
            "SELECT " + ",".join(wanted) + " FROM request_metrics ORDER BY id")]
    connection.close()
    return rows


def coding_task(root: Path, slot: Path, port: int, env: dict[str, str],
                sandbox_mode: str = "workspace-write", tag: str = "") -> dict:
    workspace = slot / "workspace"
    workspace.mkdir(exist_ok=True)
    (workspace / "labels.py").write_text("def normalize_labels(values):\n    raise NotImplementedError\n")
    (workspace / "test_labels.py").write_text(
        "import unittest\nfrom labels import normalize_labels\n"
        "class LabelsTest(unittest.TestCase):\n"
        " def test_trim_deduplicate(self):\n"
        "  self.assertEqual(normalize_labels([' A ', 'a', '', 'B', ' b ']), ['A', 'B'])\n"
        " def test_unicode(self):\n"
        "  self.assertEqual(normalize_labels(['Straße', 'STRASSE', '繁體']), ['Straße', '繁體'])\n"
        " def test_empty(self):\n"
        "  self.assertEqual(normalize_labels([]), [])\n"
        " def test_invalid(self):\n"
        "  with self.assertRaises(TypeError): normalize_labels(['ok', None])\n")
    prompt = ("Implement normalize_labels(values) in labels.py: strip whitespace, discard empty "
              "strings, deduplicate with Unicode casefold, keep first spelling and original order. "
              "Non-string elements raise TypeError. Only edit labels.py. Inspect the existing tests "
              "and run python3 -m unittest -v. Do not access network or files outside this workspace. "
              "Finish with DOGFOOD_OK only after all tests pass.")
    client_env = env | {"COPILOT_DOGFOOD_KEY": "local-only"}
    args = [str(root / "client/node_modules/.bin/codex"), "exec", "--ephemeral",
            "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check",
            "--sandbox", sandbox_mode, "--json", "-C", str(workspace)]
    for setting in (
        'model="gpt-6-astra"', 'model_reasoning_effort="low"', 'model_provider="copilot_api"',
        'model_providers.copilot_api.name="OpenAI"',
        f'model_providers.copilot_api.base_url="http://127.0.0.1:{port}"',
        'model_providers.copilot_api.env_key="COPILOT_DOGFOOD_KEY"',
        'model_providers.copilot_api.requires_openai_auth=true',
        'model_providers.copilot_api.supports_websockets=false',
        'model_providers.copilot_api.wire_api="responses"',
        'model_providers.copilot_api.request_max_retries=0',
        'model_providers.copilot_api.stream_max_retries=0',
        'model_providers.copilot_api.stream_idle_timeout_ms=360000',
        'features.remote_compaction_v2=true', 'approval_policy="never"', 'web_search="disabled"',
    ):
        args.extend(["-c", setting])
    args.append(prompt)
    started = time.monotonic()
    command(args, client_env, slot / f"{tag}codex.jsonl", timeout=600)
    command([sys.executable, "-m", "unittest", "-v"], client_env,
            slot / f"{tag}task-tests.log", timeout=30, cwd=workspace)
    return {"tests_passed": True, "sandbox_mode": sandbox_mode,
            "elapsed_s": round(time.monotonic() - started, 2)}


def responses_call(port: int, input_items: list[dict]) -> dict:
    payload = {"model": "gpt-6-astra", "input": input_items, "stream": True,
               "store": False, "reasoning": {"effort": "low"}}
    request = urllib.request.Request(f"http://127.0.0.1:{port}/responses",
                                     data=json.dumps(payload).encode(),
                                     headers={"Content-Type": "application/json"})
    terminal = None
    with LOCAL_HTTP.open(request, timeout=360) as response:
        for line in response:
            if not line.startswith(b"data:"):
                continue
            try:
                event = json.loads(line[5:])
            except ValueError:
                continue
            if event.get("type") in ("response.completed", "response.failed", "response.incomplete"):
                terminal = event
    if terminal is None:
        raise RuntimeError("Responses ended without a terminal event")
    if terminal["type"] != "response.completed":
        raise RuntimeError("Responses terminal outcome: " + terminal["type"])
    return terminal["response"]


def compact_probe(port: int) -> dict:
    # Synthetic non-sensitive conversation; output/compaction ciphertext stays in memory.
    identifier = "DOGFOOD-CEDAR-482"
    compacted = responses_call(port, [
        {"role": "user", "content": f"Remember the release identifier {identifier}. "
         "Our task is implementing Unicode-aware stable label deduplication. "
         "After summarization retain the identifier and the requirement to preserve first spelling."},
        {"role": "assistant", "content": "I will preserve the release identifier and first spelling."},
        {"type": "compaction_trigger"},
    ])
    items = compacted.get("output", [])
    if not any(item.get("type") == "compaction" for item in items):
        raise RuntimeError("compact request completed without a compaction item")
    resumed = responses_call(port, items + [
        {"role": "user", "content": "Return only the release identifier retained from before compaction."}
    ])
    text = "".join(content.get("text", "") for item in resumed.get("output", [])
                   for content in item.get("content", []) if isinstance(content, dict))
    if identifier not in text:
        raise RuntimeError("post-compact continuation did not retain the synthetic identifier")
    return {"compaction_item": True, "continuity_verified": True,
            "scope": "small synthetic Responses-v2 protocol probe, not a large-context measurement"}


def run_slot(args: argparse.Namespace, root: Path, version: str, allowance: int,
             tag: str = "") -> dict:
    slot = root / version
    backend_port, shim_port = PORTS[version]
    check_ports(PORTS[version])
    env = child_env(root) | {
        "COPILOT_API_HOME": str(slot / "backend-home"),
        "COPILOT_API_SQLITE_DB_PATH": str(slot / "backend-home/copilot-api.sqlite"),
        "COPILOT_SHIM_HOST": "127.0.0.1", "HOST": "127.0.0.1",
        "COPILOT_SHIM_PORT": str(shim_port),
        "COPILOT_SHIM_UPSTREAM": f"http://127.0.0.1:{backend_port}",
        "COPILOT_SHIM_MIN": "4", "COPILOT_SHIM_MAX": "4",
        "COPILOT_SHIM_RETRIES": "1", "COPILOT_SHIM_STALL_MS": "330000",
        "COPILOT_SHIM_METRICS_DB": str(slot / "metrics.sqlite"),
        "COPILOT_SHIM_BACKEND_VERSION": version,
    }
    processes = []
    logs = []
    budget = None
    previous_rows = len(metrics(slot / "metrics.sqlite"))
    report = {"version": version, "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    try:
        backend = [args.node, str(slot / "pkg/node_modules/@jeffreycao/copilot-api/dist/main.js"),
                   "start", "--port", str(backend_port)]
        if version == "2.5.2":
            backend.extend(["--host", "127.0.0.1"])
        if args.proxy_env:
            backend.append("--proxy-env")
        for name, argv in (("backend", backend),
                           ("shim", [args.bun, str(root / "copilot-throttle-shim.js")])):
            log = (slot / f"{tag}{name}.log").open("ab")
            logs.append(log)
            process = subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL, stdout=log,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            processes.append(process)
            save_json(slot / "owned-processes.json", {"pids": [p.pid for p in processes]})
            result = wait_ready(backend_port if name == "backend" else shim_port,
                                "/v1/models" if name == "backend" else "/_shim/health", process)
            if name == "backend":
                if not any(m.get("id") == "gpt-6-astra" for m in result.get("data", [])):
                    raise RuntimeError("Astra is absent from the authenticated remote catalog")
            else:
                report["initial_health"] = result
        listeners = subprocess.check_output(["ss", "-ltnp"], text=True)
        for port, process in zip(PORTS[version], processes):
            matching = [line for line in listeners.splitlines() if line.split()[3].endswith(f":{port}")]
            if not matching or any(line.split()[3] != f"127.0.0.1:{port}" for line in matching):
                raise RuntimeError("trial listener is not exclusively IPv4 loopback")
            if any(f"pid={process.pid}," not in line for line in matching):
                raise RuntimeError("trial listener is not owned by its recorded child process")
        budget = BudgetProxy(shim_port, allowance)
        threading.Thread(target=budget.serve_forever, daemon=True).start()
        report["coding_task"] = coding_task(root, slot, budget.server_port, env,
                                             args.sandbox_mode, tag)
        if budget.allowance - budget.dispatched < 2:
            report["compact_probe"] = {"skipped": "remaining request budget below two"}
        else:
            report["compact_probe"] = compact_probe(budget.server_port)
    except Exception as error:
        report["error"] = str(error)
    finally:
        if budget is not None:
            report["logical_requests"] = budget.close_admission()
            budget.shutdown()
            budget.server_close()
        if len(processes) == 2 and processes[1].poll() is None:
            deadline = time.monotonic() + 340
            while time.monotonic() < deadline:
                try:
                    health = get_json(shim_port, "/_shim/health")
                    report["final_health"] = health
                    if not health.get("active") and not health.get("draining"):
                        break
                    if health.get("unknown"):
                        report["controlled_trial_recovery"] = True
                        break
                except OSError:
                    break
                time.sleep(1)
        cleanup_errors = []
        for process in reversed(processes):
            try:
                terminate(process)
            except (OSError, subprocess.TimeoutExpired) as error:
                cleanup_errors.append(type(error).__name__)
        for log in logs:
            log.close()
        report["metrics"] = metrics(slot / "metrics.sqlite")[previous_rows:]
        report["physical_attempts"] = sum(row.get("attempts", 0) for row in report["metrics"])
        report["all_owned_processes_stopped"] = all(p.poll() is not None for p in processes)
        if cleanup_errors:
            report["all_owned_processes_stopped"] = False
            report["error"] = "owned process cleanup failed: " + ", ".join(cleanup_errors)
        save_json(slot / f"{tag}report.json", report)
    return report


def main() -> None:
    os.umask(0o077)
    def interrupted(_signum, _frame):
        raise KeyboardInterrupt
    for signum in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, interrupted)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("prepare", "run", "verify-candidate"))
    parser.add_argument("--root", required=True)
    parser.add_argument("--expected-host", default="David-Ubuntu")
    parser.add_argument("--node", required=True)
    parser.add_argument("--bun", required=True)
    parser.add_argument("--npm", default="npm")
    parser.add_argument("--shim")
    parser.add_argument("--backend-home", default=str(Path.home() / ".local/share/copilot-api"))
    parser.add_argument("--archive-2-3-4")
    parser.add_argument("--archive-2-5-2")
    parser.add_argument("--proxy-env", action="store_true")
    parser.add_argument("--sandbox-mode", choices=("workspace-write", "danger-full-access"),
                        default="workspace-write",
                        help="per-process test client policy; never changes host/user configuration")
    args = parser.parse_args()
    if socket.gethostname() != args.expected_host:
        parser.error("host mismatch: refusing to access credentials or start trial processes")
    root = trial_root(args.root)
    if args.phase == "prepare":
        if not all((args.shim, args.archive_2_3_4, args.archive_2_5_2)):
            parser.error("prepare requires --shim and both reviewed archives")
        prepare(args, root)
    elif args.phase == "verify-candidate":
        previous = json.loads((root / "run-report.json").read_text())
        if not isinstance(previous, list) or not all(r.get("all_owned_processes_stopped") for r in previous):
            parser.error("candidate verification requires a completed, stopped initial trial")
        used = sum(r.get("logical_requests", 0) for r in previous)
        remaining = 12 - used
        if remaining <= 0 or (root / "verification-report.json").exists():
            parser.error("the original request budget is exhausted or already allocated")
        # Reserve the remaining budget durably before starting; interruption cannot reset it.
        reserve_budget(root / "verification-report.json", {"status": "started", "allowance": remaining,
                                                            "previous_logical_requests": used})
        report = run_slot(args, root, "2.5.2", remaining, "verification-")
        report["total_logical_requests"] = used + report.get("logical_requests", 0)
        report["total_physical_attempts"] = sum(r.get("physical_attempts", 0) for r in previous) + report["physical_attempts"]
        save_json(root / "verification-report.json", report)
        print(json.dumps({k: v for k, v in report.items() if k != "metrics"}), flush=True)
        if "error" in report:
            raise SystemExit(1)
    else:
        if (root / "run-report.json").exists():
            parser.error("use a fresh trial root; re-running would reset the live request budget")
        # Each version gets <=6 logical calls. Shim replay=1 yields <=24 total dispatches.
        save_json(root / "run-artifacts.json", {
            "shim_sha256": hashlib.sha256((root / "copilot-throttle-shim.js").read_bytes()).hexdigest(),
            "node": args.node, "bun": args.bun,
            "codex_version": (root / "codex-version.log").read_text().strip(),
        })
        reserve_budget(root / "run-report.json", {"status": "started", "budget": 12})
        reports = []
        for version in VERSIONS:
            report = run_slot(args, root, version, 6)
            reports.append(report)
            print(json.dumps({k: v for k, v in report.items() if k != "metrics"}), flush=True)
        save_json(root / "run-report.json", reports)
        if any("error" in report for report in reports):
            raise SystemExit(1)


if __name__ == "__main__":
    main()
