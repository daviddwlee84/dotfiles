"""fleet tmux — cross-host tmux session summary.

Fan-out a single command over the fleet inventory:

  1. Prefer remote ~/.config/tmux/tmux-session-summary.py --json (chezmoi
     deploys it on every managed host).
  2. Fallback: raw `tmux list-sessions -F ...` + `tmux list-windows -a -F ...`,
     reconstructed into the same Session/Window schema locally.
  3. If both fail (no tmux server, unreachable host, …): row renders "N/A"
     and the run continues — per-host failures never abort the fleet.

Output: Rich table by default; `--json` for pipeable per-host records.

This module is invoked by `bin/fleet tmux ...` (the umbrella binary) and
shares its inventory + asyncssh plumbing with `scripts/fleet_apply.py` via
`from scripts.fleet import ...`.
"""
from __future__ import annotations

import asyncio
import dataclasses
import json
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Annotated

import asyncssh
import tyro
from rich.console import Console
from rich.table import Table

from scripts.fleet import (
    DEFAULT_CONFIG_PATH,
    Host,
    _connect_kwargs,
    load_hosts,
)


# Single bash blob; remote dispatcher tries .py then falls back to raw tmux.
# Stays a heredoc-free oneliner so the SSH wire format is one line.
_REMOTE_CMD = r"""
set +e
PY="$HOME/.config/tmux/tmux-session-summary.py"
DEEP=""
if [ "${TSUM_DEEP:-0}" = "1" ]; then DEEP="--deep"; fi
if [ -x "$PY" ]; then
  out=$("$PY" --json $DEEP 2>/dev/null)
  rc=$?
  if [ "$rc" = 0 ] && [ -n "$out" ]; then
    printf 'TSUM_SOURCE=py\n'
    printf '%s\n' "$out"
    exit 0
  fi
fi
if ! command -v tmux >/dev/null 2>&1; then
  printf 'TSUM_SOURCE=none\n'
  exit 0
fi
sessions=$(tmux list-sessions -F '#{session_name}'$'\t''#{session_created}'$'\t''#{session_attached}'$'\t''#{session_last_attached}' 2>/dev/null)
if [ -z "$sessions" ]; then
  printf 'TSUM_SOURCE=raw\n'
  printf 'SESSIONS_EMPTY\n'
  exit 0
fi
windows=$(tmux list-windows -a -F '#{session_name}'$'\t''#{window_index}'$'\t''#{window_name}'$'\t''#{window_active}'$'\t''#{pane_current_path}'$'\t''#{pane_current_command}'$'\t''#{window_panes}' 2>/dev/null)
printf 'TSUM_SOURCE=raw\n'
printf 'SESSIONS_BEGIN\n'
printf '%s\n' "$sessions"
printf 'SESSIONS_END\n'
printf 'WINDOWS_BEGIN\n'
printf '%s\n' "$windows"
printf 'WINDOWS_END\n'
"""


@dataclass
class WindowRec:
    index: int
    name: str
    active: bool
    cwd: str
    cmd: str
    panes: int


@dataclass
class SessionRec:
    name: str
    created: int
    attached: bool
    last_attached: int
    windows: list[WindowRec] = field(default_factory=list)
    active_pane_tail: str = ""
    active_pane_skipped: bool = False


@dataclass
class HostResult:
    host: str
    source: str  # "py" | "raw" | "none" | "N/A"
    sessions: list[SessionRec] = field(default_factory=list)
    error: str | None = None
    elapsed_ms: int = 0


def _parse_py_json(blob: str) -> list[SessionRec]:
    """Parse the JSON emitted by tmux-session-summary.py --json."""
    data = json.loads(blob)
    out: list[SessionRec] = []
    for s in data:
        wins = [
            WindowRec(
                index=int(w["index"]),
                name=str(w.get("name", "")),
                active=bool(w.get("active", False)),
                cwd=str(w.get("cwd", "")),
                cmd=str(w.get("cmd", "")),
                panes=int(w.get("panes", 1)),
            )
            for w in s.get("windows", [])
        ]
        out.append(
            SessionRec(
                name=str(s["name"]),
                created=int(s.get("created", 0)),
                attached=bool(s.get("attached", False)),
                last_attached=int(s.get("last_attached", 0)),
                windows=wins,
                active_pane_tail=str(s.get("active_pane_tail", "")),
                active_pane_skipped=bool(s.get("active_pane_skipped", False)),
            )
        )
    return out


def _parse_raw(text: str) -> list[SessionRec]:
    """Parse raw tmux list-sessions + list-windows output back to schema."""
    if "SESSIONS_EMPTY" in text:
        return []
    sessions: dict[str, SessionRec] = {}
    in_sessions = False
    in_windows = False
    for line in text.splitlines():
        if line == "SESSIONS_BEGIN":
            in_sessions = True
            continue
        if line == "SESSIONS_END":
            in_sessions = False
            continue
        if line == "WINDOWS_BEGIN":
            in_windows = True
            continue
        if line == "WINDOWS_END":
            in_windows = False
            continue
        if in_sessions:
            parts = line.split("\t")
            if len(parts) < 4:
                continue
            name, created, attached, last_attached = parts[:4]
            sessions[name] = SessionRec(
                name=name,
                created=int(created or 0),
                attached=bool(int(attached or 0)),
                last_attached=int(last_attached or 0),
            )
        elif in_windows:
            parts = line.split("\t")
            if len(parts) < 7:
                continue
            sname, idx, wname, active, cwd, cmd, panes = parts[:7]
            sess = sessions.get(sname)
            if sess is None:
                continue
            sess.windows.append(
                WindowRec(
                    index=int(idx or 0),
                    name=wname,
                    active=bool(int(active or 0)),
                    cwd=cwd,
                    cmd=cmd,
                    panes=int(panes or 1),
                )
            )
    return list(sessions.values())


def _parse_remote_output(stdout: str) -> tuple[str, list[SessionRec]]:
    """Pull TSUM_SOURCE marker, then parse the rest accordingly."""
    if not stdout:
        return "N/A", []
    lines = stdout.splitlines()
    source = "N/A"
    body_start = 0
    for i, line in enumerate(lines):
        if line.startswith("TSUM_SOURCE="):
            source = line.split("=", 1)[1].strip() or "N/A"
            body_start = i + 1
            break
    body = "\n".join(lines[body_start:])
    if source == "py":
        try:
            return "py", _parse_py_json(body)
        except (json.JSONDecodeError, KeyError, ValueError) as e:
            return "N/A", []
    if source == "raw":
        return "raw", _parse_raw(body)
    if source == "none":
        return "none", []
    return "N/A", []


async def _run_one(host: Host, deep: bool, connect_timeout: float, cmd_timeout: float) -> HostResult:
    """One host: SSH (or local subprocess) + parse output."""
    started = time.monotonic()
    env_prefix = "TSUM_DEEP=1 " if deep else ""
    cmd = env_prefix + _REMOTE_CMD

    try:
        if host.local:
            proc = await asyncio.create_subprocess_exec(
                "bash", "-c", cmd,
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
            connect_kw = _connect_kwargs(host)
            async with asyncio.timeout(connect_timeout):
                conn = await asyncssh.connect(**connect_kw)
            try:
                async with asyncio.timeout(cmd_timeout):
                    result = await conn.run(cmd, check=False)
                out = (result.stdout or "") if isinstance(result.stdout, str) else (result.stdout or b"").decode("utf-8", errors="replace")
            finally:
                conn.close()
                await conn.wait_closed()
        source, sessions = _parse_remote_output(out)
        return HostResult(
            host=host.name,
            source=source,
            sessions=sessions,
            elapsed_ms=int((time.monotonic() - started) * 1000),
        )
    except (asyncssh.Error, OSError, asyncio.TimeoutError, TimeoutError) as e:
        return HostResult(
            host=host.name,
            source="N/A",
            error=f"{type(e).__name__}: {e}",
            elapsed_ms=int((time.monotonic() - started) * 1000),
        )


def _humanize_ts(ts: int) -> str:
    if not ts:
        return "—"
    try:
        return datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M")
    except (OSError, ValueError, OverflowError):
        return "—"


def _top_session(sessions: list[SessionRec]) -> str:
    if not sessions:
        return "—"
    # Most windows; tie → most recent last_attached.
    return max(sessions, key=lambda s: (len(s.windows), s.last_attached)).name


def _render_table(results: list[HostResult], console: Console) -> None:
    table = Table(title="fleet tmux", header_style="bold cyan")
    table.add_column("HOST", style="bold")
    table.add_column("SOURCE", style="dim")
    table.add_column("SESSIONS", justify="right")
    table.add_column("WINDOWS", justify="right")
    table.add_column("ATTACHED", justify="right")
    table.add_column("LAST_ATTACHED")
    table.add_column("TOP_SESSION")
    table.add_column("ms", justify="right", style="dim")

    for r in results:
        if r.source == "N/A":
            table.add_row(
                r.host,
                "[red]N/A[/red]",
                "—", "—", "—",
                "—",
                f"[red]{(r.error or '')[:48]}[/red]",
                str(r.elapsed_ms),
            )
            continue
        total_windows = sum(len(s.windows) for s in r.sessions)
        attached = sum(1 for s in r.sessions if s.attached)
        last_ts = max((s.last_attached for s in r.sessions), default=0)
        src_style = {"py": "green", "raw": "yellow", "none": "dim"}.get(r.source, "white")
        table.add_row(
            r.host,
            f"[{src_style}]{r.source}[/{src_style}]",
            str(len(r.sessions)),
            str(total_windows),
            str(attached),
            _humanize_ts(last_ts),
            _top_session(r.sessions),
            str(r.elapsed_ms),
        )
    console.print(table)


def _emit_json(results: list[HostResult]) -> None:
    out = [
        {
            "host": r.host,
            "source": r.source,
            "error": r.error,
            "elapsed_ms": r.elapsed_ms,
            "sessions": [dataclasses.asdict(s) for s in r.sessions],
        }
        for r in results
    ]
    print(json.dumps(out, indent=2, default=str))


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
    deep: Annotated[bool, tyro.conf.arg(help="Pass --deep to remote tsum (captures pane tails)")] = False,
    json_out: Annotated[bool, tyro.conf.arg(name="json", help="Emit per-host JSON to stdout instead of Rich table")] = False,
    serial: Annotated[bool, tyro.conf.arg(help="Process hosts one at a time (debug)")] = False,
    max_parallel: Annotated[int, tyro.conf.arg(help="Max concurrent SSH connections (default min(8, len(hosts)))")] = 0,
    connect_timeout: Annotated[float, tyro.conf.arg(help="Per-host SSH connect timeout (seconds)")] = 15.0,
    command_timeout: Annotated[float, tyro.conf.arg(help="Per-host remote command timeout (seconds)")] = 60.0,
    with_summary: Annotated[bool, tyro.conf.arg(help="Pipe results through LLM aggregator (NOT YET IMPLEMENTED)")] = False,
) -> int:
    """Cross-host tmux session summary. See module docstring."""
    console = Console()
    err = Console(stderr=True)

    if with_summary:
        err.print("[red]fleet tmux --with-summary is not yet implemented.[/red]\n"
                  "[dim]Use `tsum` locally for per-host AI summary, or run `fleet tmux --json | …`.[/dim]")
        return 2

    try:
        all_hosts, _defaults = load_hosts(config)
    except (FileNotFoundError, ValueError) as e:
        err.print(f"[red]error loading {config}: {e}[/red]")
        return 2

    selected = _filter_hosts(all_hosts, hosts, exclude)
    if not selected:
        err.print("[yellow]no hosts matched filter[/yellow]")
        return 0

    parallelism = 1 if serial else (max_parallel or min(8, len(selected)))
    sem = asyncio.Semaphore(parallelism)
    done_count = 0

    async def _bounded(h: Host) -> HostResult:
        nonlocal done_count
        async with sem:
            try:
                return await _run_one(h, deep, connect_timeout, command_timeout)
            finally:
                done_count += 1

    async def _orchestrate(status: Any) -> list[HostResult]:
        total = len(selected)
        # Polls done_count every 100ms while the gather runs, updating the
        # spinner text. Cancelled when gather returns.
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

    # Spinner on stderr — skipped automatically when stderr isn't a TTY (Rich
    # detects this) and when --json (we still show it; stderr won't pollute
    # stdout for piping).
    async def _run_with_status() -> list[HostResult]:
        if err.is_terminal:
            with err.status(f"querying {len(selected)} hosts...", spinner="dots") as status:
                return await _orchestrate(status)
        return await _orchestrate(None)

    results = asyncio.run(_run_with_status())

    if json_out:
        _emit_json(results)
    else:
        _render_table(results, console)

    # Exit code = number of N/A (errored) hosts. 0 = healthy.
    failed = sum(1 for r in results if r.source == "N/A")
    return min(failed, 125)


def main() -> int:
    return tyro.cli(cli)


if __name__ == "__main__":
    sys.exit(main())
