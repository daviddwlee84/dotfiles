#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "rich>=13.9",
# ]
# ///
"""bench_ai_agents — measure end-to-end latency of each AICAP_AGENT path.

Runs the same aifix-shape prompt (~500 chars in, ~200 chars out) through
every available agent: claude, opencode, codex, cursor-agent, plus the
http(OpenRouter) and http(Ollama) variants. Output is a markdown table
for the dotfiles benchmark docs.

Usage:
  source ~/.shellrc.adhoc   # to get OPENROUTER_API_KEY into env
  scripts/bench_ai_agents.py [--runs N] [--prompt-file PATH] [--markdown]

Why this exists: when adding a new AICAP_* configuration or after a
provider model swap, you want to re-evaluate which agent is fastest /
which is reliable. Single-shot ad-hoc timing isn't reproducible — this
script is.

The HTTP runs only execute when the relevant connectivity holds (Ollama
on :11434, OpenRouter with OPENROUTER_API_KEY set). Missing prereqs skip
that row cleanly.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import statistics
import subprocess
import time
import urllib.error
import urllib.request

from dataclasses import dataclass, field
from typing import Any

from rich.console import Console

err = Console(stderr=True)


# Realistic aifix-shape prompt: shell command + error output + ask for fix.
# ~500 chars in, expects ~150-300 chars out.
DEFAULT_PROMPT = """\
Here is a command I ran in my terminal and its output. Diagnose any errors \
and suggest a concrete fix. Be brief and specific.

$ git push origin main
To github.com:user/repo.git
 ! [rejected]        main -> main (non-fast-forward)
error: failed to push some refs to 'github.com:user/repo.git'
hint: Updates were rejected because the tip of your current branch is behind
hint: its remote counterpart. If you intend to push your own history after
hint: someone else pushed, use 'git push --force-with-lease'. Otherwise, you
hint: may want to integrate the remote changes (e.g., 'git pull ...') before
hint: pushing again.
hint: See the 'Note about fast-forwards' in 'git push --help' for details.\
"""


@dataclass
class Config:
    name: str             # display name for the markdown table
    kind: str             # "cli" or "http"
    cmd: list[str] = field(default_factory=list)   # for kind=cli
    url: str = ""         # for kind=http
    model: str = ""       # for kind=http
    auth_env: str = ""    # env var name holding bearer token (empty for Ollama)
    available: bool = True  # set in _check_prereqs


def _check_prereqs(c: Config) -> tuple[bool, str]:
    if c.kind == "cli":
        if not c.cmd:
            return False, "empty cmd"
        if not shutil.which(c.cmd[0]):
            return False, f"{c.cmd[0]!r} not on PATH"
        return True, ""
    if c.kind == "http":
        # Probe URL with a HEAD-ish request; just check connectivity, not auth.
        host_probe = c.url.rsplit("/", 3)[0]  # strip /api/v1/chat/completions
        try:
            req = urllib.request.Request(host_probe, method="GET")
            with urllib.request.urlopen(req, timeout=2) as _:
                pass
        except urllib.error.HTTPError:
            pass  # 4xx/5xx is fine — server is reachable
        except (urllib.error.URLError, TimeoutError):
            return False, f"{host_probe} unreachable"
        if c.auth_env and not os.environ.get(c.auth_env):
            return False, f"{c.auth_env} unset"
        return True, ""
    return False, f"unknown kind {c.kind!r}"


CONFIGS = [
    Config(name="claude (haiku)", kind="cli",
           cmd=["claude", "-p", "--model", "haiku"]),
    Config(name="opencode (github-copilot/claude-haiku-4.5)", kind="cli",
           cmd=["opencode", "run", "-m", "github-copilot/claude-haiku-4.5"]),
    Config(name="codex (account default)", kind="cli",
           cmd=["codex", "exec"]),
    Config(name="cursor-agent (composer-2-fast)", kind="cli",
           cmd=["cursor-agent", "-p"]),
    Config(name="http OpenRouter (google/gemma-4-26b-a4b-it:free)", kind="http",
           url="https://openrouter.ai/api/v1/chat/completions",
           model="google/gemma-4-26b-a4b-it:free",
           auth_env="OPENROUTER_API_KEY"),
    Config(name="http OpenRouter (openai/gpt-oss-20b:free)", kind="http",
           url="https://openrouter.ai/api/v1/chat/completions",
           model="openai/gpt-oss-20b:free",
           auth_env="OPENROUTER_API_KEY"),
    Config(name="http OpenRouter (qwen/qwen3-coder:free)", kind="http",
           url="https://openrouter.ai/api/v1/chat/completions",
           model="qwen/qwen3-coder:free",
           auth_env="OPENROUTER_API_KEY"),
    Config(name="http Ollama (qwen2.5-coder:3b, local)", kind="http",
           url="http://localhost:11434/v1/chat/completions",
           model="qwen2.5-coder:3b"),
    Config(name="http Ollama (llama3.2:latest, local)", kind="http",
           url="http://localhost:11434/v1/chat/completions",
           model="llama3.2:latest"),
]


def _invoke(c: Config, prompt: str, timeout: float = 180.0) -> tuple[bool, float, int, str]:
    """Run one invocation; return (ok, wall_seconds, reply_chars, error_snippet)."""
    t0 = time.perf_counter()
    if c.kind == "cli":
        try:
            r = subprocess.run([*c.cmd, prompt], capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            return False, time.perf_counter() - t0, 0, "timeout"
        except FileNotFoundError as e:
            return False, time.perf_counter() - t0, 0, str(e)
        dt = time.perf_counter() - t0
        if r.returncode != 0:
            return False, dt, 0, (r.stderr or "rc!=0").strip()[:120]
        return True, dt, len(r.stdout), ""
    if c.kind == "http":
        payload = json.dumps({
            "model": c.model,
            "messages": [{"role": "user", "content": prompt}],
            "stream": False,
        }).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        if c.auth_env:
            key = os.environ.get(c.auth_env, "")
            if key:
                headers["Authorization"] = f"Bearer {key}"
        req = urllib.request.Request(c.url, data=payload, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                body = resp.read().decode("utf-8", errors="replace")
        except urllib.error.HTTPError as e:
            return False, time.perf_counter() - t0, 0, f"HTTP {e.code}"
        except (urllib.error.URLError, TimeoutError) as e:
            return False, time.perf_counter() - t0, 0, str(e)[:120]
        dt = time.perf_counter() - t0
        try:
            parsed = json.loads(body)
            reply = parsed["choices"][0]["message"]["content"]
        except (json.JSONDecodeError, KeyError, IndexError, TypeError):
            return False, dt, 0, f"bad shape: {body[:120]}"
        return True, dt, len(reply), ""
    return False, 0.0, 0, "unknown kind"


def _detect_hardware() -> str:
    """Best-effort host hardware tag for the report header."""
    try:
        import platform
        sysname = platform.system()
        if sysname == "Darwin":
            # macOS: sysctl gives the chip + RAM cleanly.
            chip = subprocess.run(
                ["sysctl", "-n", "machdep.cpu.brand_string"],
                capture_output=True, text=True, timeout=2,
            ).stdout.strip()
            mem_bytes = subprocess.run(
                ["sysctl", "-n", "hw.memsize"],
                capture_output=True, text=True, timeout=2,
            ).stdout.strip()
            mem_gb = int(mem_bytes) // (1024**3) if mem_bytes.isdigit() else 0
            return f"{chip} / {mem_gb} GB / macOS {platform.mac_ver()[0]}"
        if sysname == "Linux":
            cpu = ""
            try:
                with open("/proc/cpuinfo") as f:
                    for line in f:
                        if line.startswith("model name"):
                            cpu = line.split(":", 1)[1].strip()
                            break
            except OSError:
                pass
            mem_kb = 0
            try:
                with open("/proc/meminfo") as f:
                    for line in f:
                        if line.startswith("MemTotal:"):
                            mem_kb = int(line.split()[1])
                            break
            except OSError:
                pass
            return f"{cpu} / {mem_kb // (1024**2)} GB / Linux {platform.release()}"
        return f"{sysname} {platform.machine()}"
    except Exception:
        return "unknown hardware"


def main() -> int:
    p = argparse.ArgumentParser(description="Benchmark AICAP agent latencies.")
    p.add_argument("--warm-runs", type=int, default=2,
                   help="Warm trials per agent AFTER the cold run (default: 2).")
    p.add_argument("--prompt-file", help="Path to a custom prompt file (default: built-in aifix prompt).")
    p.add_argument("--markdown", action="store_true",
                   help="Emit a markdown table only (no decorative output).")
    p.add_argument("--timeout", type=float, default=180.0, help="Per-call timeout in seconds.")
    args = p.parse_args()

    prompt = DEFAULT_PROMPT
    if args.prompt_file:
        with open(args.prompt_file, encoding="utf-8") as f:
            prompt = f.read()

    hardware = _detect_hardware()

    if not args.markdown:
        err.print(f"[bold]Hardware:[/bold] {hardware}")
        err.print(f"[bold]Prompt:[/bold] {len(prompt)} chars input")
        err.print(f"[bold]Cold + {args.warm_runs} warm runs per agent[/bold]")
        err.print(f"[bold]Timeout:[/bold] {args.timeout:.0f}s\n")

    # Probe prereqs.
    for c in CONFIGS:
        ok, why = _check_prereqs(c)
        c.available = ok
        if not ok and not args.markdown:
            err.print(f"[dim]skip[/dim] {c.name}: {why}")
        elif not args.markdown:
            err.print(f"[green]ready[/green] {c.name}")
    if not args.markdown:
        err.print("")

    rows: list[dict[str, Any]] = []
    total_runs = args.warm_runs + 1  # 1 cold + N warm
    for c in CONFIGS:
        if not c.available:
            rows.append({"name": c.name, "skip": True, "reason": "prereq missing"})
            continue
        cold_dt: float | None = None
        cold_size: int = 0
        warm_times: list[float] = []
        warm_sizes: list[int] = []
        failures: list[str] = []
        for i in range(total_runs):
            label = "cold" if i == 0 else f"warm {i}/{args.warm_runs}"
            if not args.markdown:
                err.print(f"  [{c.name}] {label}…", end="")
            ok, dt, size, errmsg = _invoke(c, prompt, timeout=args.timeout)
            if ok:
                if i == 0:
                    cold_dt = dt
                    cold_size = size
                else:
                    warm_times.append(dt)
                    warm_sizes.append(size)
                if not args.markdown:
                    err.print(f" [green]{dt:.1f}s[/green] ({size} chars)")
            else:
                failures.append(f"{label}: {errmsg}")
                if not args.markdown:
                    err.print(f" [red]FAIL[/red] {errmsg}")
        rows.append({
            "name": c.name, "skip": False,
            "cold_dt": cold_dt, "cold_size": cold_size,
            "warm_times": warm_times, "warm_sizes": warm_sizes,
            "failures": failures,
        })

    # Markdown output.
    print()
    print(f"_Hardware: {hardware}; prompt: {len(prompt)} chars; 1 cold + {args.warm_runs} warm runs per agent._")
    print()
    print("| Agent | Cold | Warm median | Warm range | Avg reply | Status |")
    print("|---|---:|---:|---:|---:|---|")
    for r in rows:
        if r.get("skip"):
            print(f"| {r['name']} | — | — | — | — | skipped ({r['reason']}) |")
            continue
        cold_s = f"{r['cold_dt']:.1f}s" if r["cold_dt"] is not None else "—"
        if r["warm_times"]:
            med = statistics.median(r["warm_times"])
            lo = min(r["warm_times"])
            hi = max(r["warm_times"])
            warm_med = f"**{med:.1f}s**"
            warm_range = f"{lo:.1f}-{hi:.1f}s" if lo != hi else f"{lo:.1f}s"
        else:
            warm_med = "—"
            warm_range = "—"
        sizes = [r["cold_size"], *r["warm_sizes"]]
        sizes = [s for s in sizes if s > 0]
        avg_size = int(statistics.mean(sizes)) if sizes else 0
        if r["failures"]:
            status = f"⚠ {len(r['failures'])} fail"
        elif r["cold_dt"] is None:
            status = "❌ all fail"
        else:
            status = "✅"
        print(f"| {r['name']} | {cold_s} | {warm_med} | {warm_range} | {avg_size} ch | {status} |")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
