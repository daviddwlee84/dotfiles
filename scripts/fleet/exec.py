"""fleet exec — cross-host ad-hoc command runner.

Fan-out an argv-list command (or shell string) over the fleet inventory:

  1. Default: argv list after `--`, no shell expansion (safe by construction).
     `fleet exec -- pueue --version` runs `pueue --version` literally on each
     host via asyncssh; per-arg shlex.quote keeps it injection-safe.
  2. `--shell <bin>` opt-in: wraps in `<bin> -c '<argv joined>'` so the user
     can use pipes / globs / redirects / env-prefixes.
  3. `--login` opt-in: wraps in `<shell> -lc '...'` so the remote rc files
     load (gives access to nvm / mise / conda / aliases). Slower per host.
  4. `--ai` summarises results into succeeded/differed/failed tiers via the
     copy-pasted AICAP block (4th Python consumer of `04_ai_agents.sh`;
     extraction TODO is the next priority — see `backlog/fleet-exec.md`).

Per-host failures (SSH timeout, command exit ≠ 0) never abort the run; each
shows up as its own row with rc + first line of stderr.

Output: Rich table by default; `--json` for piping; `--out-dir DIR` writes
per-host stdout/stderr/json files; `--full-output` expands the table into
per-host blocks.

This module is invoked by `dot_dotfiles/bin/executable_fleet exec ...` and
shares its inventory + asyncssh plumbing with `scripts/fleet/apply.py` via
`from scripts.fleet import ...`.

Argparse (not tyro) is used here because the `--` separator + REMAINDER-style
positional argv list maps cleanly onto argparse's native option-parser stop
behaviour. The other fleet modules use tyro because they don't have a
positional argv list.
"""
from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import os
import re
import shlex
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any

import asyncssh
from rich.console import Console
from rich.table import Table
from rich.text import Text

from scripts.fleet import (
    DEFAULT_CONFIG_PATH,
    Host,
    _connect_kwargs,
    load_hosts,
)

err = Console(stderr=True)


# ---------------------------------------------------------------------------
# AICAP SSOT loader — copy-pasted from dot_dotfiles/bin/executable_pqsum.
# CLAUDE.md AI agent autodetect row counts this as the FOURTH Python consumer
# of dot_config/shell/04_ai_agents.sh. Extraction into a shared module is the
# next priority — see TODO.md `Extract AICAP Python dispatch into shared module`.
# ---------------------------------------------------------------------------
_SSOT_PATH_CANDIDATES = (
    "~/.config/shell/04_ai_agents.sh",
    "~/.local/share/chezmoi/dot_config/shell/04_ai_agents.sh",
)
_SSOT_LINE = re.compile(r'^\s*:\s*"\$\{(AICAP_\w+):=([^}]*)\}"\s*$')


def _load_ssot_defaults() -> dict[str, str]:
    for raw in _SSOT_PATH_CANDIDATES:
        p = Path(os.path.expanduser(raw))
        if not p.is_file():
            continue
        out: dict[str, str] = {}
        try:
            for line in p.read_text(encoding="utf-8").splitlines():
                m = _SSOT_LINE.match(line)
                if m:
                    out[m.group(1)] = m.group(2)
        except OSError:
            return {}
        return out
    return {}


_SSOT = _load_ssot_defaults()


def _env_or_ssot(key: str, fallback: str = "") -> str:
    val = os.environ.get(key)
    if val is not None:
        return val
    return _SSOT.get(key, fallback)


AICAP_AGENT = os.environ.get("AICAP_AGENT", "")
AICAP_CLAUDE_MODEL = _env_or_ssot("AICAP_CLAUDE_MODEL", "haiku")
AICAP_OPENCODE_MODEL = _env_or_ssot("AICAP_OPENCODE_MODEL", "github-copilot/claude-haiku-4.5")
AICAP_CODEX_MODEL = _env_or_ssot("AICAP_CODEX_MODEL", "")
AICAP_CURSOR_MODEL = _env_or_ssot("AICAP_CURSOR_MODEL", "")
AICAP_HTTP_URL = _env_or_ssot("AICAP_HTTP_URL", "https://openrouter.ai/api/v1/chat/completions")
AICAP_HTTP_MODEL = _env_or_ssot("AICAP_HTTP_MODEL", "openrouter/free")
AICAP_HTTP_API_KEY = os.environ.get("AICAP_HTTP_API_KEY") or os.environ.get("OPENROUTER_API_KEY", "")
AICAP_AGENT_PRIORITY = _env_or_ssot("AICAP_AGENT_PRIORITY", "opencode claude codex cursor-agent").split()
FLEETEXEC_MIN_REFRESH_INTERVAL = int(os.environ.get("FLEETEXEC_MIN_REFRESH_INTERVAL", "120"))
FLEETEXEC_TIMEOUT = float(os.environ.get("FLEETEXEC_TIMEOUT", "60"))


def _with_model(flag: str, value: str) -> list[str]:
    return [flag, value] if value else []


AGENT_CONFIG = {
    "opencode":     {"base": ["opencode", "run", *_with_model("-m", AICAP_OPENCODE_MODEL)]},
    "claude":       {"base": ["claude", "-p", *_with_model("--model", AICAP_CLAUDE_MODEL)]},
    "codex":        {"base": ["codex", "exec", *_with_model("-m", AICAP_CODEX_MODEL)]},
    "agyc":         {"base": ["agyc", "-p"]},  # Antigravity CLI — collision-free symlink, no --model flag
    "cursor-agent": {"base": ["cursor-agent", "-p", *_with_model("--model", AICAP_CURSOR_MODEL)]},
    "http":         {"base": []},
}


# ---------------------------------------------------------------------------
# AI prompt — succeeded / differed / failed classifier
# ---------------------------------------------------------------------------
AIEXEC_PROMPT_PREAMBLE = """\
You are reviewing the per-host output of a single shell command run across a \
developer's fleet. Identify the cluster-majority output, then classify each \
host:

  - "succeeded"  → rc=0 AND stdout matches the majority pattern (semantically
                   equivalent; e.g. minor whitespace / order is fine).
  - "differed"   → rc=0 BUT stdout meaningfully differs (version drift, \
config drift, different OS path, anomalous tail, etc.).
  - "failed"     → rc≠0 OR SSH/timeout error (`rc` may be null in that case).

For each host emit a <=60-char `summary` (e.g. "pueue 4.0.1 — older than \
cluster majority"; "permission denied on /var/log"; "host unreachable: \
asyncssh.PermissionDenied"). Cite the specific differing line or exit reason \
where useful — don't just say "differs".

Provide a `fleet_summary` (<=160 chars) highlighting the most actionable \
divergence — version laggards, failing hosts, anomalous configs. If \
everything matches, say so concisely.

Respond with STRICT JSON only (no prose, no fences):
{
  "command": "<argv joined for display>",
  "majority_output": "<one-line summary of the cluster-majority stdout, may be empty>",
  "hosts": [
    {"host": "<name>", "tier": "succeeded" | "differed" | "failed",
     "summary": "<<=60 chars>", "rc": <int or null>, "elapsed_ms": <int>}
  ],
  "fleet_summary": "<<=160 chars>"
}
"""


# ---------------------------------------------------------------------------
# Remote command construction
# ---------------------------------------------------------------------------
# Same PATH prelude as scripts/fleet/pueue.py — see that file's _REMOTE_CMD
# header comment for why this order DIFFERS from the user's interactive PATH.
_PATH_PRELUDE = (
    "$HOME/.dotfiles/bin:$HOME/.cargo/bin:$HOME/.local/bin:$HOME/bin:"
    "/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:"
    "$HOME/.linuxbrew/bin:$PATH"
)


def _build_remote_cmd(argv: list[str], *, shell: str, login: bool, no_augment_path: bool) -> str:
    """Construct the shell string to send over SSH.

    Decision matrix:
      shell="" + login=False + no_augment_path=False → PATH prelude + exec <quoted argv>
      shell="" + login=False + no_augment_path=True  → exec <quoted argv>
      shell=<bin> + login=False                       → PATH prelude + <bin> -c '<argv-joined>'
      shell="" + login=True                           → bash -lc '<quoted argv>'
      shell=<bin> + login=True                        → <bin> -lc '<argv-joined>'

    In --shell modes the argv is joined with literal spaces (no shlex.quote)
    so users get shell-expansion as advertised. In non-shell modes each arg
    is shlex.quoted so the remote /bin/sh -c invocation (asyncssh always
    wraps in sh -c when run() gets a string) doesn't re-parse globs etc.
    """
    if shell:
        inner = " ".join(argv)
        shell_bin = shell
        flag = "-lc" if login else "-c"
        wrapped = f"{shell_bin} {flag} {shlex.quote(inner)}"
    elif login:
        inner = " ".join(shlex.quote(a) for a in argv)
        wrapped = f"bash -lc {shlex.quote(inner)}"
    else:
        wrapped = " ".join(shlex.quote(a) for a in argv)

    # PATH prelude only when NOT login (login shells load PATH from rc files)
    # and NOT --no-augment-path.
    if not login and not no_augment_path:
        return f'export PATH="{_PATH_PRELUDE}"; {wrapped}'
    return wrapped


# ---------------------------------------------------------------------------
# Per-host execution
# ---------------------------------------------------------------------------
@dataclass
class HostResult:
    host: str
    rc: int | None  # None = SSH/timeout error
    stdout: str
    stderr: str
    elapsed_ms: int
    error: str | None = None  # SSH/timeout class name + message


async def _run_one(
    host: Host,
    argv: list[str],
    *,
    shell: str,
    login: bool,
    no_augment_path: bool,
    connect_timeout: float,
    cmd_timeout: float,
) -> HostResult:
    started = time.monotonic()
    cmd = _build_remote_cmd(argv, shell=shell, login=login, no_augment_path=no_augment_path)
    try:
        if host.local:
            proc = await asyncio.create_subprocess_exec(
                "bash", "-c", cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            try:
                stdout_b, stderr_b = await asyncio.wait_for(proc.communicate(), timeout=cmd_timeout)
            except asyncio.TimeoutError:
                proc.kill()
                raise TimeoutError(f"local cmd exceeded {cmd_timeout}s")
            rc = proc.returncode
            stdout = stdout_b.decode("utf-8", errors="replace")
            stderr = stderr_b.decode("utf-8", errors="replace")
        else:
            connect_kw = _connect_kwargs(host)
            async with asyncio.timeout(connect_timeout):
                conn = await asyncssh.connect(**connect_kw)
            try:
                async with asyncio.timeout(cmd_timeout):
                    result = await conn.run(cmd, check=False)
                rc = result.exit_status
                stdout = (result.stdout or "") if isinstance(result.stdout, str) else (result.stdout or b"").decode("utf-8", errors="replace")
                stderr = (result.stderr or "") if isinstance(result.stderr, str) else (result.stderr or b"").decode("utf-8", errors="replace")
            finally:
                conn.close()
                await conn.wait_closed()
        return HostResult(
            host=host.name,
            rc=rc if rc is not None else 0,
            stdout=stdout,
            stderr=stderr,
            elapsed_ms=int((time.monotonic() - started) * 1000),
        )
    except (asyncssh.Error, OSError, asyncio.TimeoutError, TimeoutError) as e:
        return HostResult(
            host=host.name,
            rc=None,
            stdout="",
            stderr="",
            error=f"{type(e).__name__}: {e}",
            elapsed_ms=int((time.monotonic() - started) * 1000),
        )


async def discover_exec(
    hosts: list[Host],
    argv: list[str],
    *,
    shell: str,
    login: bool,
    no_augment_path: bool,
    parallelism: int = 8,
    serial: bool = False,
    connect_timeout: float = 15.0,
    cmd_timeout: float = 60.0,
) -> list[HostResult]:
    parallelism = 1 if serial else max(1, parallelism)
    sem = asyncio.Semaphore(parallelism)
    done_count = 0

    async def _bounded(h: Host) -> HostResult:
        nonlocal done_count
        async with sem:
            try:
                return await _run_one(
                    h, argv,
                    shell=shell, login=login, no_augment_path=no_augment_path,
                    connect_timeout=connect_timeout, cmd_timeout=cmd_timeout,
                )
            finally:
                done_count += 1

    total = len(hosts)

    async def _ticker(status: Any) -> None:
        while True:
            status.update(f"executing on {done_count}/{total} hosts...")
            await asyncio.sleep(0.1)

    if err.is_terminal:
        with err.status(f"executing on {total} hosts...", spinner="dots") as status:
            tick = asyncio.create_task(_ticker(status))
            try:
                return list(await asyncio.gather(*(_bounded(h) for h in hosts)))
            finally:
                tick.cancel()
    return list(await asyncio.gather(*(_bounded(h) for h in hosts)))


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------
def _first_line(s: str, fallback: str = "—") -> str:
    if not s:
        return fallback
    return s.splitlines()[0] if s.splitlines() else s.strip() or fallback


def render_table(results: list[HostResult], argv: list[str], full_output: bool, console: Console) -> None:
    title = f"fleet exec — {' '.join(shlex.quote(a) for a in argv)}"
    table = Table(title=title, header_style="bold cyan")
    table.add_column("HOST", style="bold")
    table.add_column("RC", justify="right")
    table.add_column("STDOUT (1L)" if not full_output else "STDOUT/STDERR")
    table.add_column("ms", justify="right", style="dim")

    for r in results:
        if r.rc is None:
            table.add_row(r.host, "[red]N/A[/red]", f"[red]{(r.error or '')[:80]}[/red]", str(r.elapsed_ms))
            continue
        rc_cell = f"[green]{r.rc}[/green]" if r.rc == 0 else f"[red]{r.rc}[/red]"
        body = _first_line(r.stdout) if r.rc == 0 else _first_line(r.stderr, fallback=_first_line(r.stdout))
        table.add_row(r.host, rc_cell, body, str(r.elapsed_ms))
    console.print(table)

    if full_output:
        for r in results:
            console.print()
            header = Text()
            header.append(f"── {r.host} ──", style="bold cyan")
            console.print(header)
            if r.error:
                console.print(Text(r.error, style="red"))
                continue
            if r.stdout:
                console.print(Text("[stdout]", style="bold dim"))
                console.print(r.stdout.rstrip())
            if r.stderr:
                console.print(Text("[stderr]", style="bold red"))
                console.print(r.stderr.rstrip())


def emit_json(results: list[HostResult]) -> None:
    print(json.dumps([asdict(r) for r in results], indent=2, default=str))


def write_out_dir(results: list[HostResult], out_dir: str, argv: list[str]) -> None:
    base = Path(out_dir)
    base.mkdir(parents=True, exist_ok=True)
    for r in results:
        safe_host = re.sub(r"[^A-Za-z0-9._-]", "_", r.host)
        (base / f"{safe_host}.stdout").write_text(r.stdout, encoding="utf-8")
        (base / f"{safe_host}.stderr").write_text(r.stderr, encoding="utf-8")
        (base / f"{safe_host}.json").write_text(json.dumps({
            "host": r.host,
            "rc": r.rc,
            "elapsed_ms": r.elapsed_ms,
            "error": r.error,
            "argv": argv,
        }, indent=2), encoding="utf-8")
    err.print(f"[dim]fleet exec: wrote {len(results)} hosts × 3 files to {out_dir}[/dim]")


# ---------------------------------------------------------------------------
# AI: agent dispatch + cache + prompt + render
# (Copy-pasted from dot_dotfiles/bin/executable_pqsum. 4th consumer of the
# AICAP SSOT — extraction is the next priority.)
# ---------------------------------------------------------------------------
def detect_agent() -> str | None:
    if AICAP_AGENT:
        if AICAP_AGENT == "http" or shutil.which(AICAP_AGENT):
            return AICAP_AGENT
        err.print(f"[red]AICAP_AGENT={AICAP_AGENT!r} but that CLI isn't on PATH.[/red]")
        return None
    for cand in AICAP_AGENT_PRIORITY:
        if shutil.which(cand):
            return cand
    return None


def model_for(agent: str) -> str:
    return {
        "claude": AICAP_CLAUDE_MODEL or "(default)",
        "opencode": AICAP_OPENCODE_MODEL or "(default)",
        "codex": AICAP_CODEX_MODEL or "(default)",
        "agyc": "(account)",
        "cursor-agent": AICAP_CURSOR_MODEL or "(default)",
        "http": AICAP_HTTP_MODEL,
    }.get(agent, "?")


def invoke_agent(agent: str, prompt: str, timeout: float) -> str:
    if agent == "http":
        return _invoke_http(prompt, timeout)
    base = AGENT_CONFIG[agent]["base"]
    try:
        result = subprocess.run([*base, prompt], capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        err.print(f"[red]{agent} timed out after {timeout:.0f}s[/red]")
        return ""
    except FileNotFoundError:
        err.print(f"[red]{agent} not on PATH (race vs detect_agent)[/red]")
        return ""
    if result.returncode != 0:
        err.print(f"[red]{agent} exited {result.returncode}[/red]")
        if result.stderr.strip():
            err.print(f"[dim]{result.stderr.strip()[:500]}[/dim]")
        return ""
    return result.stdout


def _invoke_http(prompt: str, timeout: float) -> str:
    payload = json.dumps({
        "model": AICAP_HTTP_MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "stream": False,
    }).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    if AICAP_HTTP_API_KEY:
        headers["Authorization"] = f"Bearer {AICAP_HTTP_API_KEY}"
    req = urllib.request.Request(AICAP_HTTP_URL, data=payload, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8", errors="replace")
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as e:
        err.print(f"[red]http: {e}[/red]")
        return ""
    try:
        parsed = json.loads(body)
        return parsed["choices"][0]["message"]["content"]
    except (json.JSONDecodeError, KeyError, IndexError, TypeError):
        err.print(f"[red]http: unexpected response shape[/red] [dim]{body[:300]}[/dim]")
        return ""


_CACHE_VERSION = "v1"
_AI_OUTPUT_CAP = 4000  # per-host stdout/stderr cap when building the prompt


def _cache_path(prompt_hash: str) -> Path:
    base = os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")
    d = Path(base) / "fleet-exec"
    d.mkdir(parents=True, exist_ok=True)
    host = socket.gethostname().split(".")[0] or "host"
    return d / f"{host}-{prompt_hash}.json"


def _cache_lookup(prompt_hash: str) -> dict | None:
    p = _cache_path(prompt_hash)
    if not p.is_file():
        return None
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None
    if data.get("version") != _CACHE_VERSION:
        return None
    if data.get("prompt_hash") != prompt_hash:
        return None
    age = time.time() - float(data.get("generated_at", 0))
    parsed = data.get("parsed")
    if not isinstance(parsed, dict):
        return None
    if age > FLEETEXEC_MIN_REFRESH_INTERVAL > 0:
        return None
    return parsed


def _cache_save(prompt_hash: str, parsed: dict) -> None:
    p = _cache_path(prompt_hash)
    try:
        p.write_text(json.dumps({
            "version": _CACHE_VERSION,
            "prompt_hash": prompt_hash,
            "generated_at": time.time(),
            "parsed": parsed,
        }, indent=2), encoding="utf-8")
    except OSError as e:
        err.print(f"[yellow]fleet exec: cache write failed: {e}[/yellow]")


def _truncate_for_ai(s: str) -> str:
    if len(s) <= _AI_OUTPUT_CAP:
        return s
    return s[:_AI_OUTPUT_CAP] + f"\n[... {len(s) - _AI_OUTPUT_CAP} more chars truncated ...]"


def build_ai_prompt(results: list[HostResult], argv: list[str]) -> str:
    # NOTE: elapsed_ms is intentionally NOT in this payload — it varies every
    # run and would bust the cache key on every invocation. The LLM classifies
    # based on stdout/stderr/rc, which are the stable signals.
    payload = {
        "command": " ".join(shlex.quote(a) for a in argv),
        "hosts": [
            {
                "host": r.host,
                "rc": r.rc,
                "error": r.error,
                "stdout": _truncate_for_ai(r.stdout),
                "stderr": _truncate_for_ai(r.stderr),
            }
            for r in results
        ],
    }
    return AIEXEC_PROMPT_PREAMBLE + "\n--- INPUT ---\n" + json.dumps(payload, indent=2, default=str) + "\nReturn JSON now.\n"


_TIERS = ("succeeded", "differed", "failed")


def parse_reply(reply: str) -> dict | None:
    if not reply.strip():
        return None
    s = reply.strip()
    if s.startswith("```"):
        s = s.split("\n", 1)[1] if "\n" in s else s
        if s.endswith("```"):
            s = s.rsplit("```", 1)[0]
        s = s.strip()
    start, end = s.find("{"), s.rfind("}")
    if start == -1 or end == -1 or end < start:
        return None
    try:
        parsed = json.loads(s[start:end + 1])
    except json.JSONDecodeError:
        return None
    if not isinstance(parsed, dict) or not isinstance(parsed.get("hosts"), list):
        return None

    cleaned_hosts: list[dict] = []
    for h in parsed["hosts"]:
        if not isinstance(h, dict):
            continue
        tier = str(h.get("tier", "")).strip().lower()
        if tier not in _TIERS:
            tier = "failed"
        rc_raw = h.get("rc")
        try:
            rc = int(rc_raw) if rc_raw is not None else None
        except (TypeError, ValueError):
            rc = None
        elapsed_raw = h.get("elapsed_ms")
        try:
            elapsed = int(elapsed_raw) if elapsed_raw is not None else 0
        except (TypeError, ValueError):
            elapsed = 0
        cleaned_hosts.append({
            "host": str(h.get("host", "")).strip()[:80],
            "tier": tier,
            "summary": str(h.get("summary", "")).strip()[:200],
            "rc": rc,
            "elapsed_ms": elapsed,
        })
    return {
        "command": str(parsed.get("command", "")).strip()[:400],
        "majority_output": str(parsed.get("majority_output", "")).strip()[:400],
        "hosts": cleaned_hosts,
        "fleet_summary": str(parsed.get("fleet_summary", "")).strip()[:400],
    }


def invoke_ai(results: list[HostResult], argv: list[str], *, refresh: bool, no_cache: bool, dry_run: bool) -> dict | None:
    prompt = build_ai_prompt(results, argv)
    if dry_run:
        print(prompt)
        return None
    prompt_hash = hashlib.sha256(prompt.encode("utf-8")).hexdigest()[:16]
    if not refresh and not no_cache:
        cached = _cache_lookup(prompt_hash)
        if cached is not None:
            return cached
    agent = detect_agent()
    if agent is None:
        tried = ", ".join(AICAP_AGENT_PRIORITY)
        err.print(f"[red]No coding-agent CLI on PATH (tried: {tried}).[/red]")
        err.print("[dim]Install one, or set AICAP_AGENT=http with AICAP_HTTP_API_KEY.[/dim]")
        return None
    with err.status(f"[dim]{agent} ({model_for(agent)}) thinking…[/dim]", spinner="dots"):
        reply = invoke_agent(agent, prompt, FLEETEXEC_TIMEOUT)
    parsed = parse_reply(reply)
    if parsed is None:
        err.print("[yellow]fleet exec: LLM returned no parseable JSON[/yellow]")
        if reply.strip():
            err.print(f"[dim]{reply.strip()[:400]}[/dim]")
        return None
    if not no_cache:
        _cache_save(prompt_hash, parsed)
    return parsed


_TIER_GLYPHS = {"succeeded": "🟢", "differed": "🟡", "failed": "🔴"}
_TIER_COLORS = {"succeeded": "green", "differed": "yellow", "failed": "red"}


def render_ai(parsed: dict, console: Console) -> None:
    fleet = parsed.get("fleet_summary") or ""
    if fleet:
        console.print(Text(f"🌐 {fleet}", style="bold cyan"))
        console.print()
    majority = parsed.get("majority_output") or ""
    if majority:
        console.print(Text(f"majority: {majority}", style="dim italic"))
        console.print()
    # Group by tier for readability
    by_tier: dict[str, list[dict]] = {t: [] for t in _TIERS}
    for h in parsed.get("hosts", []):
        by_tier.setdefault(h.get("tier", "failed"), []).append(h)
    for tier in _TIERS:
        hosts = by_tier.get(tier, [])
        if not hosts:
            continue
        glyph = _TIER_GLYPHS.get(tier, "⚪")
        color = _TIER_COLORS.get(tier, "white")
        console.print(Text(f"{glyph} {tier} ({len(hosts)})", style=f"bold {color}"))
        for h in hosts:
            line = Text()
            line.append("  ")
            line.append(f"{h.get('host', '?'):<16}", style="bold")
            rc = h.get("rc")
            rc_str = "N/A" if rc is None else str(rc)
            line.append(f"rc={rc_str:<4}", style="dim")
            line.append(f"  {h.get('summary', '')}", style="white")
            console.print(line)
        console.print()


def render_ai_report(parsed: dict, results: list[HostResult], argv: list[str]) -> str:
    lines: list[str] = []
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    cmd_str = " ".join(shlex.quote(a) for a in argv)
    lines.append(f"# fleet exec report — {ts}")
    lines.append("")
    lines.append(f"**Command:** `{cmd_str}`")
    lines.append("")
    fleet = parsed.get("fleet_summary") or ""
    if fleet:
        lines.append(f"**Fleet:** {fleet}")
        lines.append("")
    majority = parsed.get("majority_output") or ""
    if majority:
        lines.append(f"**Majority output:** {majority}")
        lines.append("")

    by_tier: dict[str, list[dict]] = {t: [] for t in _TIERS}
    for h in parsed.get("hosts", []):
        by_tier.setdefault(h.get("tier", "failed"), []).append(h)
    for tier in _TIERS:
        hosts = by_tier.get(tier, [])
        if not hosts:
            continue
        lines.append(f"## {tier.title()} ({len(hosts)})")
        lines.append("")
        for h in hosts:
            rc = h.get("rc")
            rc_str = "N/A" if rc is None else str(rc)
            lines.append(f"- **{h.get('host', '?')}** (rc={rc_str}, {h.get('elapsed_ms', 0)}ms) — {h.get('summary', '')}")
        lines.append("")

    lines.append("## Raw outputs")
    lines.append("")
    lines.append("<details>")
    lines.append("<summary>per-host stdout/stderr</summary>")
    lines.append("")
    for r in results:
        lines.append(f"### {r.host}")
        lines.append("")
        lines.append(f"rc={r.rc if r.rc is not None else 'N/A'}  elapsed={r.elapsed_ms}ms")
        lines.append("")
        if r.error:
            lines.append(f"**Error:** `{r.error}`")
            lines.append("")
            continue
        if r.stdout.strip():
            lines.append("```")
            lines.append(r.stdout.rstrip())
            lines.append("```")
            lines.append("")
        if r.stderr.strip():
            lines.append("stderr:")
            lines.append("```")
            lines.append(r.stderr.rstrip())
            lines.append("```")
            lines.append("")
    lines.append("</details>")
    lines.append("")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def _filter_hosts(hosts: list[Host], include: str | None, exclude: str | None) -> list[Host]:
    if include:
        wanted = {h.strip() for h in include.split(",") if h.strip()}
        hosts = [h for h in hosts if h.name in wanted]
    if exclude:
        unwanted = {h.strip() for h in exclude.split(",") if h.strip()}
        hosts = [h for h in hosts if h.name not in unwanted]
    return hosts


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="fleet exec",
        description="Run an ad-hoc command across the fleet (argv list after `--`).",
        usage="fleet exec [OPTIONS] -- COMMAND [ARG...]",
    )
    p.add_argument("--hosts", default=None, help="Comma-separated host names to include")
    p.add_argument("--exclude", default=None, help="Comma-separated host names to exclude")
    p.add_argument("--config", default=str(DEFAULT_CONFIG_PATH), help="Path to machines.toml")
    p.add_argument("--shell", default="", help="Wrap command in `<SHELL> -c` (e.g. bash, zsh, sh). Default off.")
    p.add_argument("--login", action="store_true", help="Wrap in `-lc` so the host's rc files load (slower).")
    p.add_argument("--no-augment-path", action="store_true",
                   help="Skip the standard PATH prelude (default: ~/.dotfiles/bin → cargo → uv → ~/bin → brew). Mutually exclusive with --login.")
    p.add_argument("--json", dest="json_out", action="store_true", help="Emit per-host JSON to stdout.")
    p.add_argument("--out-dir", default="", help="Write per-host .stdout/.stderr/.json files under DIR.")
    p.add_argument("--full-output", action="store_true", help="Render full stdout/stderr blocks below the table.")
    p.add_argument("--ai", action="store_true", help="Summarize results into succeeded/differed/failed tiers via the configured LLM.")
    p.add_argument("--report", action="store_true", help="With --ai: emit markdown report.")
    p.add_argument("--out", default="", help="With --ai --report: write to PATH (default stdout).")
    p.add_argument("--refresh", action="store_true", help="With --ai: bypass cache.")
    p.add_argument("--no-cache", action="store_true", help="With --ai: don't read or write the cache.")
    p.add_argument("--dry-run", action="store_true", help="With --ai: print prompt; no LLM call.")
    p.add_argument("--serial", action="store_true", help="Process hosts one at a time (debug).")
    p.add_argument("--max-parallel", type=int, default=0, help="Max concurrent SSH connections (default min(8, len(hosts))).")
    p.add_argument("--connect-timeout", type=float, default=15.0, help="Per-host SSH connect timeout (seconds).")
    p.add_argument("--command-timeout", type=float, default=60.0, help="Per-host remote command timeout (seconds).")
    p.add_argument("argv", nargs=argparse.REMAINDER, help="Command + args after `--`.")
    return p.parse_args(argv)


def main() -> int:
    args = parse_args(sys.argv[1:])

    # Strip leading `--` if present (argparse.REMAINDER keeps it).
    inner_argv = list(args.argv)
    if inner_argv and inner_argv[0] == "--":
        inner_argv = inner_argv[1:]
    if not inner_argv:
        err.print("[red]fleet exec: missing command after `--`[/red]")
        err.print("[dim]Usage: fleet exec [OPTIONS] -- COMMAND [ARG...][/dim]")
        return 2

    if args.no_augment_path and args.login:
        err.print("[red]fleet exec: --no-augment-path and --login are mutually exclusive[/red]")
        err.print("[dim]Login shells load PATH from rc files; augmentation is redundant.[/dim]")
        return 2

    if args.ai and args.out_dir:
        err.print("[yellow]fleet exec: --ai overrides --out-dir; AI output mode used[/yellow]")

    try:
        all_hosts, _defaults = load_hosts(Path(args.config))
    except (FileNotFoundError, ValueError) as e:
        err.print(f"[red]error loading {args.config}: {e}[/red]")
        return 2

    selected = _filter_hosts(all_hosts, args.hosts, args.exclude)
    if not selected:
        err.print("[yellow]no hosts matched filter[/yellow]")
        return 0

    parallelism = 1 if args.serial else (args.max_parallel or min(8, len(selected)))
    results = asyncio.run(discover_exec(
        selected, inner_argv,
        shell=args.shell, login=args.login, no_augment_path=args.no_augment_path,
        parallelism=parallelism, serial=args.serial,
        connect_timeout=args.connect_timeout, cmd_timeout=args.command_timeout,
    ))

    if args.ai:
        parsed = invoke_ai(results, inner_argv,
                           refresh=args.refresh, no_cache=args.no_cache, dry_run=args.dry_run)
        if args.dry_run:
            return 0
        if parsed is None:
            return 1
        if args.report or args.out:
            report = render_ai_report(parsed, results, inner_argv)
            if args.out:
                try:
                    Path(args.out).write_text(report, encoding="utf-8")
                    err.print(f"[dim]fleet exec: wrote {args.out}[/dim]")
                except OSError as e:
                    err.print(f"[red]fleet exec: failed to write {args.out}: {e}[/red]")
                    return 1
            else:
                print(report)
        else:
            render_ai(parsed, Console())
    elif args.json_out:
        emit_json(results)
    else:
        render_table(results, inner_argv, full_output=args.full_output, console=Console())
        if args.out_dir:
            write_out_dir(results, args.out_dir, inner_argv)

    failed = sum(1 for r in results if r.rc is None or r.rc != 0)
    return min(failed, 125)


if __name__ == "__main__":
    sys.exit(main())
