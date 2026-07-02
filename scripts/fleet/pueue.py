"""fleet pueue — cross-host pueue queue summary.

Fan-out `pueue status --json` over the fleet inventory:

  1. Each host's stdout is parsed by piping through the LOCAL `pqsum` binary
     (`pqsum json --raw-stdin --host=NAME`) so the JSON parser stays in one place.
  2. AI mode merges all host snapshots into a JSON list and pipes to
     `pqsum ai --stdin-json --multi-host`, which holds the prompt template,
     agent dispatch, and cache. Fleet never re-implements any of that.
  3. Per-host failures (pueue not installed / daemon offline / SSH unreachable)
     never abort the run — the row renders with an explicit status string.

Output: Rich table by default (one row per (host, group)); `--json` for pipeable
per-host records; `--ai` for AI summary; `--ai --report [--out PATH]` for markdown.

This module is invoked by `dot_dotfiles/bin/executable_fleet pueue ...` and
shares its inventory + asyncssh plumbing with `scripts/fleet/apply.py` via
`from scripts.fleet import ...`.

Why subprocess to pqsum (not Python import): pqsum is a deployed uv-script
binary, not a Python module. Subprocess via PATH works identically in source-
tree dev (resolves to `dot_dotfiles/bin/executable_pqsum`) and deployed
(`~/.dotfiles/bin/pqsum`). Overhead is negligible vs the SSH and AI calls.
"""
from __future__ import annotations

import asyncio
import json
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Annotated, Any

import asyncssh
import tyro
from rich.console import Console
from rich.table import Table

from scripts.fleet import (
    DEFAULT_CONFIG_PATH,
    Host,
    connect_host,
    load_hosts,
    resolve_ssh_login_passwords,
)

# Remote sentinel-prefixed wire format so a host that's missing pueue, has the
# daemon down, or returns mangled output never aborts the fleet — and we can
# tell the three apart for accurate rendering.
#
# PATH augmentation is load-bearing: asyncssh's `conn.run()` opens a
# non-interactive non-login shell, which on most systems gets a minimal PATH
# (macOS: `/usr/bin:/bin:/usr/sbin:/sbin`; Ubuntu: same + `/snap/bin`). pueue
# is typically installed by users to `/opt/homebrew/bin` (Apple Silicon brew),
# `/usr/local/bin` (Intel brew / Linux), `~/.cargo/bin` (Rust), `~/.local/bin`
# (uv tool), `~/.dotfiles/bin` (chezmoi-deployed), or `~/bin` (legacy). Without
# this prepend `command -v pueue` returns false on every host with a non-system
# install, producing a fleetwide false-negative `not-installed`.
#
# Order rationale (DIFFERS from the user's interactive shell PATH on purpose):
#   1. ~/.dotfiles/bin  — chezmoi-deployed wrappers; we own the version
#   2. ~/.cargo/bin     — `cargo install pueue --locked`; tracks upstream releases
#   3. ~/.local/bin     — uv-tool / pipx; same "fresh from package manager" tier
#   4. ~/bin            — legacy user-placed (transitional per bin-migration);
#                         deliberately ranked BELOW package-manager dirs so a
#                         stale ~/bin/pueue (e.g. a 4.0.1 download lingering
#                         after the user switched to cargo's 4.0.2) does not
#                         shadow the fresher cargo binary and trigger a daemon-
#                         client protocol-mismatch on every probe.
#   5. /opt/homebrew/bin / /usr/local/bin / linuxbrew — system package managers
# The user's interactive shell currently puts ~/bin at slot 2 (per
# dot_config/shell/00_exports.sh.tmpl) — that PATH is for THEIR daily commands
# where they might legitimately override the package-manager version. For
# cross-host probing we want "best available", which is the package-manager
# version.
#
# We also catch the pueue daemon/client version-mismatch case (`pueue` exits 0
# but writes `Error: Couldn't deserialize message: ...` to stdout because the
# socket protocol drifted). That's a real-world `daemon-offline` scenario;
# falling through to `PQSUM_SOURCE=ok` would feed garbage to pqsum's parser.
_REMOTE_CMD = r"""
set +e
export PATH="$HOME/.dotfiles/bin:$HOME/.cargo/bin:$HOME/.local/bin:$HOME/bin:/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:$HOME/.linuxbrew/bin:$PATH"
if ! command -v pueue >/dev/null 2>&1; then
  printf 'PQSUM_SOURCE=missing\n'
  exit 0
fi
out=$(pueue status --json 2>/dev/null)
rc=$?
if [ "$rc" != 0 ] || [ -z "$out" ]; then
  printf 'PQSUM_SOURCE=offline\n'
  exit 0
fi
case "$out" in
  Error:*|error:*)
    printf 'PQSUM_SOURCE=offline\n'
    exit 0
    ;;
esac
printf 'PQSUM_SOURCE=ok\n'
printf '%s\n' "$out"
"""

_REPO_ROOT = Path(__file__).resolve().parents[2]
_LOCAL_PQSUM = _REPO_ROOT / "dot_dotfiles" / "bin" / "executable_pqsum"


def _pqsum_cmd() -> list[str]:
    """Resolve `pqsum` binary: deployed (~/.dotfiles/bin/pqsum) or source tree."""
    deployed = shutil.which("pqsum")
    if deployed:
        return [deployed]
    if _LOCAL_PQSUM.is_file():
        return [str(_LOCAL_PQSUM)]
    raise RuntimeError("pqsum binary not found (tried PATH and source tree)")


@dataclass
class HostResult:
    host: str
    # "ok" | "missing" | "offline" | "parse-error" | "N/A"
    source: str
    snapshot: dict[str, Any] | None = None
    error: str | None = None
    elapsed_ms: int = 0


def _parse_remote(stdout: str, host: str) -> tuple[str, str | None]:
    """Pull PQSUM_SOURCE marker; return (source, body) where body is raw JSON or None."""
    if not stdout:
        return "N/A", None
    lines = stdout.splitlines()
    for i, line in enumerate(lines):
        if line.startswith("PQSUM_SOURCE="):
            source = line.split("=", 1)[1].strip() or "N/A"
            body = "\n".join(lines[i + 1:])
            return source, body if body.strip() else None
    return "N/A", None


def _parse_via_pqsum(raw_json: str, host: str) -> dict[str, Any] | None:
    """Pipe raw pueue JSON through local `pqsum json --raw-stdin --host=NAME`."""
    try:
        result = subprocess.run(
            [*_pqsum_cmd(), "json", "--raw-stdin", f"--host={host}"],
            input=raw_json,
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError, RuntimeError):
        return None
    if result.returncode != 0:
        return None
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None
    if not isinstance(data, list) or not data:
        return None
    return data[0] if isinstance(data[0], dict) else None


async def _run_one(host: Host, connect_timeout: float, cmd_timeout: float) -> HostResult:
    started = time.monotonic()
    try:
        if host.local:
            proc = await asyncio.create_subprocess_exec(
                "bash", "-c", _REMOTE_CMD,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            try:
                stdout, _stderr = await asyncio.wait_for(proc.communicate(), timeout=cmd_timeout)
            except asyncio.TimeoutError:
                proc.kill()
                raise TimeoutError(f"local cmd exceeded {cmd_timeout}s")
            out = stdout.decode("utf-8", errors="replace")
        else:
            conn = await connect_host(host, connect_timeout)
            try:
                async with asyncio.timeout(cmd_timeout):
                    result = await conn.run(_REMOTE_CMD, check=False)
                out = (result.stdout or "") if isinstance(result.stdout, str) else (result.stdout or b"").decode("utf-8", errors="replace")
            finally:
                conn.close()
                await conn.wait_closed()

        source, body = _parse_remote(out, host.name)
        elapsed = int((time.monotonic() - started) * 1000)
        if source == "ok" and body:
            snap = _parse_via_pqsum(body, host.name)
            if snap is None:
                return HostResult(host=host.name, source="parse-error", error="pqsum parse failed", elapsed_ms=elapsed)
            return HostResult(host=host.name, source="ok", snapshot=snap, elapsed_ms=elapsed)
        return HostResult(host=host.name, source=source, elapsed_ms=elapsed)
    except (asyncssh.Error, OSError, asyncio.TimeoutError, TimeoutError) as e:
        return HostResult(
            host=host.name,
            source="N/A",
            error=f"{type(e).__name__}: {e}",
            elapsed_ms=int((time.monotonic() - started) * 1000),
        )


def _fmt_duration(s: float | None) -> str:
    if s is None:
        return "—"
    s_int = int(s)
    if s_int < 60:
        return f"{s_int}s"
    if s_int < 3600:
        return f"{s_int // 60}m"
    return f"{s_int // 3600}h"


def _fmt_pct(p: float | None) -> str:
    if p is None:
        return "—"
    return f"{round(p * 10) / 10:.1f}%"


def _breakdown(b: dict[str, int] | None) -> str:
    if not b:
        return "—"
    return ", ".join(f"{k}={v}" for k, v in sorted(b.items()))


def _render_table(results: list[HostResult], console: Console) -> None:
    table = Table(title="fleet pueue", header_style="bold cyan")
    table.add_column("HOST", style="bold")
    table.add_column("GROUP")
    table.add_column("DAEMON")
    table.add_column("PAR", justify="right")
    table.add_column("TOTAL", justify="right")
    table.add_column("DONE", justify="right")
    table.add_column("PCT", justify="right")
    table.add_column("ETA", justify="right")
    table.add_column("STATUSES")
    table.add_column("ms", justify="right", style="dim")

    for r in results:
        if r.source == "ok" and r.snapshot:
            groups = r.snapshot.get("groups") or []
            if not groups:
                table.add_row(r.host, "—", "—", "—", "0", "0", "—", "—", "no groups", str(r.elapsed_ms))
                continue
            for i, g in enumerate(groups):
                host_label = r.host if i == 0 else ""
                ms_label = str(r.elapsed_ms) if i == 0 else ""
                table.add_row(
                    host_label,
                    str(g.get("name", "?")),
                    str(g.get("daemon_status", "?")),
                    str(g.get("parallel_tasks", "?")),
                    str(g.get("total", 0)),
                    str(g.get("done", 0)),
                    _fmt_pct(g.get("pct")),
                    _fmt_duration(g.get("eta_s")),
                    _breakdown(g.get("status_breakdown")),
                    ms_label,
                )
            continue
        if r.source == "missing":
            label = "[dim]not-installed[/dim]"
        elif r.source == "offline":
            label = "[yellow]daemon-offline[/yellow]"
        elif r.source == "parse-error":
            label = "[red]parse-error[/red]"
        else:
            label = f"[red]{(r.error or 'N/A')[:48]}[/red]"
        table.add_row(r.host, "—", label, "—", "—", "—", "—", "—", "—", str(r.elapsed_ms))
    console.print(table)


def _emit_json(results: list[HostResult]) -> None:
    out = []
    for r in results:
        rec: dict[str, Any] = {
            "host": r.host,
            "source": r.source,
            "error": r.error,
            "elapsed_ms": r.elapsed_ms,
        }
        if r.snapshot:
            rec.update({k: v for k, v in r.snapshot.items() if k != "host"})
        out.append(rec)
    print(json.dumps(out, indent=2, default=str))


def _ai_input(results: list[HostResult]) -> list[dict[str, Any]]:
    """Build the list-of-snapshots payload for `pqsum ai --stdin-json`.

    Hosts in error states (missing/offline/N/A) are still included so the LLM
    can mention them in the cross-host summary — with daemon_reachable=False
    and an error field so it doesn't try to classify their (empty) groups.
    """
    out: list[dict[str, Any]] = []
    for r in results:
        if r.source == "ok" and r.snapshot:
            out.append(r.snapshot)
            continue
        out.append({
            "host": r.host,
            "daemon_reachable": False,
            "error": r.source if r.source != "N/A" else (r.error or "N/A"),
            "total_tasks": 0,
            "total_done": 0,
            "overall_pct": 0.0,
            "avg_done_s": None,
            "eta_s": None,
            "status_breakdown": {},
            "groups": [],
            "tasks": [],
        })
    return out


def _run_pqsum_ai(results: list[HostResult], report: bool, out_path: str, deep: bool, refresh: bool) -> int:
    payload = json.dumps(_ai_input(results), default=str)
    cmd = [*_pqsum_cmd(), "ai", "--stdin-json", "--multi-host"]
    if report:
        cmd.append("--report")
    if out_path:
        cmd.extend(["--out", out_path])
    if deep:
        cmd.append("--deep")
    if refresh:
        cmd.append("--refresh")
    try:
        proc = subprocess.run(cmd, input=payload, text=True, check=False)
    except FileNotFoundError as e:
        Console(stderr=True).print(f"[red]fleet pueue: {e}[/red]")
        return 1
    return proc.returncode


def _filter_hosts(hosts: list[Host], include: str | None, exclude: str | None) -> list[Host]:
    if include:
        wanted = {h.strip() for h in include.split(",") if h.strip()}
        hosts = [h for h in hosts if h.name in wanted]
    if exclude:
        unwanted = {h.strip() for h in exclude.split(",") if h.strip()}
        hosts = [h for h in hosts if h.name not in unwanted]
    return hosts


def cli(
    hosts: Annotated[str | None, tyro.conf.arg(help="Comma-separated host names to include")] = None,
    exclude: Annotated[str | None, tyro.conf.arg(help="Comma-separated host names to exclude")] = None,
    config: Annotated[Path, tyro.conf.arg(help="Path to machines.toml")] = DEFAULT_CONFIG_PATH,
    group: Annotated[str, tyro.conf.arg(help="Restrict each host to one pueue group (post-merge filter)")] = "",
    json_out: Annotated[bool, tyro.conf.arg(name="json", help="Emit per-host JSON to stdout instead of Rich table")] = False,
    ai: Annotated[bool, tyro.conf.arg(help="Pipe merged JSON to `pqsum ai --stdin-json --multi-host`")] = False,
    report: Annotated[bool, tyro.conf.arg(help="With --ai: emit markdown report instead of Rich blocks")] = False,
    out: Annotated[str, tyro.conf.arg(help="With --ai --report: write to PATH (default stdout)")] = "",
    deep: Annotated[bool, tyro.conf.arg(help="With --ai: include extra recovery context (more tokens)")] = False,
    refresh: Annotated[bool, tyro.conf.arg(help="With --ai: bypass pqsum cache")] = False,
    serial: Annotated[bool, tyro.conf.arg(help="Process hosts one at a time (debug)")] = False,
    max_parallel: Annotated[int, tyro.conf.arg(help="Max concurrent SSH connections (default min(8, len(hosts)))")] = 0,
    connect_timeout: Annotated[float, tyro.conf.arg(help="Per-host SSH connect timeout (seconds)")] = 15.0,
    command_timeout: Annotated[float, tyro.conf.arg(help="Per-host remote command timeout (seconds)")] = 60.0,
) -> int:
    """Cross-host pueue queue summary. See module docstring."""
    console = Console()
    err = Console(stderr=True)

    try:
        all_hosts, _defaults = load_hosts(config)
    except (FileNotFoundError, ValueError) as e:
        err.print(f"[red]error loading {config}: {e}[/red]")
        return 2

    selected = _filter_hosts(all_hosts, hosts, exclude)
    if not selected:
        err.print("[yellow]no hosts matched filter[/yellow]")
        return 0
    resolve_ssh_login_passwords(selected, err)

    parallelism = 1 if serial else (max_parallel or min(8, len(selected)))
    sem = asyncio.Semaphore(parallelism)
    done_count = 0

    async def _bounded(h: Host) -> HostResult:
        nonlocal done_count
        async with sem:
            try:
                return await _run_one(h, connect_timeout, command_timeout)
            finally:
                done_count += 1

    async def _orchestrate(status: Any) -> list[HostResult]:
        total = len(selected)

        async def _ticker() -> None:
            while True:
                if status is not None:
                    status.update(f"querying {done_count}/{total} hosts...")
                await asyncio.sleep(0.1)
        tick = asyncio.create_task(_ticker()) if status is not None else None
        try:
            return list(await asyncio.gather(*(_bounded(h) for h in selected)))
        finally:
            if tick is not None:
                tick.cancel()

    async def _run_with_status() -> list[HostResult]:
        if err.is_terminal:
            with err.status(f"querying {len(selected)} hosts...", spinner="dots") as status:
                return await _orchestrate(status)
        return await _orchestrate(None)

    results = asyncio.run(_run_with_status())

    if group:
        for r in results:
            if r.snapshot:
                r.snapshot["groups"] = [
                    g for g in (r.snapshot.get("groups") or [])
                    if g.get("name") == group
                ]

    if ai:
        return _run_pqsum_ai(results, report=report, out_path=out, deep=deep, refresh=refresh)

    if json_out:
        _emit_json(results)
    else:
        _render_table(results, console)

    failed = sum(1 for r in results if r.source == "N/A")
    return min(failed, 125)


def main() -> int:
    return tyro.cli(cli)


if __name__ == "__main__":
    sys.exit(main())
