"""fleet info — cross-host system status snapshot.

Fans out a curated probe across the fleet inventory and renders one row per
host. Each module is captured in a POSIX bash blob that emits machine-readable
`MOD_<name>=<value>` lines (or `MOD_<name>=ERR:<msg>` on failure) so per-module
failures never abort the host — the column just renders "—".

Modules:
  Default curated (8): os cpu mem disk load uptime docker chezmoi
  Extras (--full):     + gpu network
  Fastfetch (--ff):    runs `fastfetch --format json` (no aggregation; per-host
                       section in output, or `--json` for piping)

Cross-platform: the bash blob detects `uname -s` and dispatches between
linux/darwin command variants per module. Optional tools (docker, nvidia-smi,
fastfetch, chezmoi) are guarded by `command -v` and emit ERR:<msg> on absence.
"""
from __future__ import annotations

import asyncio
import dataclasses
import json
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
    _connect_kwargs,
    load_hosts,
)


_DEFAULT_MODULES = ["os", "cpu", "mem", "disk", "load", "uptime", "docker", "chezmoi"]
_EXTRA_MODULES = ["gpu", "network"]
_ALL_MODULES = _DEFAULT_MODULES + _EXTRA_MODULES


# One big bash blob; emits MOD_<name>=<val> for each module. macOS vs Linux
# branched via uname -s. Optional tools guarded by `command -v`. We always
# emit all base modules; Python-side filters by --modules selection so the
# bash stays branchless and easy to debug by hand.
_BASH_PROBE = r"""
set +e
OS=$(uname -s 2>/dev/null || echo unknown)
_human_n() { awk -v n="$1" 'BEGIN{ if(n<1024) printf "%dB", n; else if(n<1048576) printf "%.0fK", n/1024; else if(n<1073741824) printf "%.1fM", n/1048576; else printf "%.1fG", n/1073741824 }'; }

# --- os ---
if [ "$OS" = "Darwin" ]; then
  pn=$(sw_vers -productName 2>/dev/null); pv=$(sw_vers -productVersion 2>/dev/null)
  if [ -n "$pn" ]; then printf 'MOD_os=%s %s\n' "$pn" "$pv"
  else printf 'MOD_os=ERR:sw_vers\n'; fi
else
  if command -v lsb_release >/dev/null 2>&1; then
    val=$(lsb_release -ds 2>/dev/null | tr -d '"')
  elif [ -f /etc/os-release ]; then
    val=$(. /etc/os-release && printf '%s' "$PRETTY_NAME")
  else val=""; fi
  if [ -n "$val" ]; then printf 'MOD_os=%s\n' "$val"
  else printf 'MOD_os=ERR:no-release\n'; fi
fi

# --- cpu ---
if [ "$OS" = "Darwin" ]; then
  model=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
  cores=$(sysctl -n hw.ncpu 2>/dev/null)
else
  model=$(awk -F: '/^model name/{gsub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null)
  cores=$(nproc 2>/dev/null)
fi
if [ -n "$model" ] && [ -n "$cores" ]; then printf 'MOD_cpu=%s|%s\n' "$model" "$cores"
else printf 'MOD_cpu=ERR:probe-failed\n'; fi

# --- mem (used_bytes|total_bytes) ---
if [ "$OS" = "Darwin" ]; then
  total=$(sysctl -n hw.memsize 2>/dev/null)
  pagesize=$(sysctl -n hw.pagesize 2>/dev/null || echo 16384)
  # vm_stat counts pages; sum (active + wired + compressed) ≈ used.
  used_pages=$(vm_stat 2>/dev/null | awk '
    /Pages active/        {gsub(/\./,""); a=$3}
    /Pages wired down/    {gsub(/\./,""); w=$4}
    /occupied by compressor/ {gsub(/\./,""); c=$5}
    END {print (a+w+c)}
  ')
  if [ -n "$total" ] && [ -n "$used_pages" ]; then
    used=$((used_pages * pagesize))
    printf 'MOD_mem=%s|%s\n' "$used" "$total"
  else printf 'MOD_mem=ERR:vm_stat\n'; fi
else
  awk '
    /^MemTotal:/     {t=$2}
    /^MemAvailable:/ {a=$2}
    END {if (t && a) printf "MOD_mem=%d|%d\n", (t-a)*1024, t*1024; else print "MOD_mem=ERR:no-meminfo"}
  ' /proc/meminfo 2>/dev/null || printf 'MOD_mem=ERR:no-meminfo\n'
fi

# --- disk (root used_bytes|total_bytes) ---
df -k / 2>/dev/null | awk 'NR==2{printf "MOD_disk=%d|%d\n", $3*1024, $2*1024}' \
  || printf 'MOD_disk=ERR:df\n'

# --- load (1|5|15) ---
if [ "$OS" = "Darwin" ]; then
  sysctl -n vm.loadavg 2>/dev/null | sed 's/[{}]//g' | awk '{printf "MOD_load=%s|%s|%s\n", $1, $2, $3}' \
    || printf 'MOD_load=ERR:sysctl\n'
else
  awk '{printf "MOD_load=%s|%s|%s\n", $1, $2, $3}' /proc/loadavg 2>/dev/null \
    || printf 'MOD_load=ERR:loadavg\n'
fi

# --- uptime (seconds) ---
if [ "$OS" = "Darwin" ]; then
  boot=$(sysctl -n kern.boottime 2>/dev/null | awk -F'[ ,]' '{print $4}')
  now=$(date +%s)
  if [ -n "$boot" ] && [ -n "$now" ]; then printf 'MOD_uptime=%s\n' "$((now - boot))"
  else printf 'MOD_uptime=ERR:boottime\n'; fi
else
  awk '{printf "MOD_uptime=%d\n", int($1)}' /proc/uptime 2>/dev/null \
    || printf 'MOD_uptime=ERR:uptime\n'
fi

# --- docker (running|total) ---
if ! command -v docker >/dev/null 2>&1; then
  printf 'MOD_docker=ERR:not-installed\n'
else
  r=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
  t=$(docker ps -aq 2>/dev/null | wc -l | tr -d ' ')
  if [ -z "$r" ] || [ -z "$t" ]; then printf 'MOD_docker=ERR:daemon-down\n'
  else printf 'MOD_docker=%s|%s\n' "$r" "$t"; fi
fi

# --- chezmoi (status_lines|commits_behind) ---
if ! command -v chezmoi >/dev/null 2>&1; then
  printf 'MOD_chezmoi=ERR:not-installed\n'
else
  st=$(chezmoi --no-pager status 2>/dev/null | wc -l | tr -d ' ')
  src=$(chezmoi source-path 2>/dev/null)
  if [ -n "$src" ] && [ -d "$src" ]; then
    behind=$(cd "$src" && git rev-list --count HEAD..@{u} 2>/dev/null)
  fi
  [ -z "$behind" ] && behind="?"
  [ -z "$st" ] && st="?"
  printf 'MOD_chezmoi=%s|%s\n' "$st" "$behind"
fi

# --- gpu ---
if command -v nvidia-smi >/dev/null 2>&1; then
  out=$(nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
  if [ -n "$out" ]; then
    printf 'MOD_gpu=%s\n' "$(echo "$out" | tr -d ' ' | tr ',' '|')"
  else printf 'MOD_gpu=ERR:nvidia-smi\n'; fi
elif [ "$OS" = "Darwin" ]; then
  chip=$(system_profiler SPDisplaysDataType 2>/dev/null | awk -F: '/Chipset Model/{gsub(/^ +/,"",$2); print $2; exit}')
  if [ -n "$chip" ]; then printf 'MOD_gpu=%s\n' "$chip"
  else printf 'MOD_gpu=ERR:system_profiler\n'; fi
else
  printf 'MOD_gpu=ERR:no-gpu-probe\n'
fi

# --- network (hostname|primary_ipv4) ---
if [ "$OS" = "Darwin" ]; then
  h=$(hostname 2>/dev/null)
  ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)
else
  h=$(hostname -f 2>/dev/null || hostname 2>/dev/null)
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
fi
[ -z "$ip" ] && ip="?"
[ -z "$h" ] && h="?"
printf 'MOD_network=%s|%s\n' "$h" "$ip"

# --- fastfetch (optional, behind sentinel) ---
if [ "${FLEET_FF:-0}" = "1" ]; then
  if command -v fastfetch >/dev/null 2>&1; then
    printf 'FF_BEGIN\n'
    fastfetch --format json 2>/dev/null
    printf '\nFF_END\n'
  else
    printf 'FF_BEGIN\nERR:not-installed\nFF_END\n'
  fi
fi
"""


@dataclass
class HostInfo:
    host: str
    status: str  # "ok" | "N/A"
    modules: dict[str, Any] = field(default_factory=dict)
    fastfetch: dict | str | None = None
    error: str | None = None
    elapsed_ms: int = 0


def _parse_value(mod: str, raw: str) -> Any:
    """Translate MOD_<name>=<raw> into a structured value.

    Returns either a dict, the raw string, or {"_err": msg} for ERR:<msg>.
    """
    if raw.startswith("ERR:"):
        return {"_err": raw[4:]}
    if mod == "cpu":
        parts = raw.split("|", 1)
        return {"model": parts[0], "cores": int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else None}
    if mod in {"mem", "disk"}:
        parts = raw.split("|")
        if len(parts) != 2 or not all(p.isdigit() for p in parts):
            return {"_err": "parse"}
        used, total = int(parts[0]), int(parts[1])
        return {"used_bytes": used, "total_bytes": total, "used_pct": (used / total * 100) if total else 0}
    if mod == "load":
        parts = raw.split("|")
        if len(parts) != 3:
            return {"_err": "parse"}
        try:
            return {"l1": float(parts[0]), "l5": float(parts[1]), "l15": float(parts[2])}
        except ValueError:
            return {"_err": "parse"}
    if mod == "uptime":
        try:
            return {"seconds": int(raw)}
        except ValueError:
            return {"_err": "parse"}
    if mod == "docker":
        parts = raw.split("|")
        if len(parts) != 2:
            return {"_err": "parse"}
        try:
            return {"running": int(parts[0]), "total": int(parts[1])}
        except ValueError:
            return {"_err": "parse"}
    if mod == "chezmoi":
        parts = raw.split("|")
        return {"status_lines": parts[0], "commits_behind": parts[1] if len(parts) > 1 else "?"}
    if mod == "gpu":
        parts = raw.split("|")
        if len(parts) == 3:  # nvidia-smi: name|used_mb|total_mb
            try:
                return {"name": parts[0], "vram_used_mb": int(parts[1]), "vram_total_mb": int(parts[2])}
            except ValueError:
                return {"name": raw, "vram_used_mb": None, "vram_total_mb": None}
        return {"name": raw, "vram_used_mb": None, "vram_total_mb": None}
    if mod == "network":
        parts = raw.split("|")
        return {"hostname": parts[0], "ip": parts[1] if len(parts) > 1 else "?"}
    return raw  # os, fallback


def _parse_probe(stdout: str) -> tuple[dict[str, Any], dict | str | None]:
    """Parse the probe output into (modules dict, fastfetch obj-or-None)."""
    modules: dict[str, Any] = {}
    fastfetch: dict | str | None = None
    in_ff = False
    ff_lines: list[str] = []
    for line in stdout.splitlines():
        if line == "FF_BEGIN":
            in_ff = True
            continue
        if line == "FF_END":
            in_ff = False
            ff_raw = "\n".join(ff_lines).strip()
            if ff_raw.startswith("ERR:"):
                fastfetch = {"_err": ff_raw[4:]}
            else:
                try:
                    fastfetch = json.loads(ff_raw)
                except json.JSONDecodeError:
                    fastfetch = {"_err": "fastfetch-not-json"}
            continue
        if in_ff:
            ff_lines.append(line)
            continue
        if line.startswith("MOD_"):
            key, _, val = line[4:].partition("=")
            modules[key] = _parse_value(key, val)
    return modules, fastfetch


async def _run_one(host: Host, want_ff: bool, connect_timeout: float, cmd_timeout: float) -> HostInfo:
    started = time.monotonic()
    cmd = ("FLEET_FF=1 " if want_ff else "") + _BASH_PROBE

    try:
        if host.local:
            proc = await asyncio.create_subprocess_exec(
                "bash", "-c", cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            try:
                stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=cmd_timeout)
            except asyncio.TimeoutError:
                proc.kill()
                raise TimeoutError(f"local probe exceeded {cmd_timeout}s")
            out = stdout.decode("utf-8", errors="replace")
        else:
            connect_kw = _connect_kwargs(host)
            async with asyncio.timeout(connect_timeout):
                conn = await asyncssh.connect(**connect_kw)
            try:
                async with asyncio.timeout(cmd_timeout):
                    result = await conn.run(cmd, check=False)
                raw_out = result.stdout or ""
                out = raw_out if isinstance(raw_out, str) else raw_out.decode("utf-8", errors="replace")
            finally:
                conn.close()
                await conn.wait_closed()
        modules, fastfetch = _parse_probe(out)
        return HostInfo(
            host=host.name,
            status="ok",
            modules=modules,
            fastfetch=fastfetch,
            elapsed_ms=int((time.monotonic() - started) * 1000),
        )
    except (asyncssh.Error, OSError, asyncio.TimeoutError, TimeoutError) as e:
        return HostInfo(
            host=host.name,
            status="N/A",
            error=f"{type(e).__name__}: {e}",
            elapsed_ms=int((time.monotonic() - started) * 1000),
        )


def _humanize_bytes(n: int) -> str:
    for unit in ("B", "K", "M", "G", "T"):
        if n < 1024:
            return f"{n:.0f}{unit}" if unit == "B" else f"{n:.1f}{unit}"
        n /= 1024  # type: ignore[assignment]
    return f"{n:.1f}P"  # type: ignore[str-bytes-safe]


def _humanize_seconds(s: int) -> str:
    d, s = divmod(s, 86400)
    h, s = divmod(s, 3600)
    m, _ = divmod(s, 60)
    if d:
        return f"{d}d{h}h"
    if h:
        return f"{h}h{m}m"
    return f"{m}m"


def _cell(mod: str, val: Any) -> str:
    """Render one module's value as a Rich-compatible table cell string."""
    if val is None:
        return "—"
    if isinstance(val, dict) and "_err" in val:
        return f"[dim]—[/dim]"
    if mod == "os":
        return str(val)
    if mod == "cpu":
        cores = val.get("cores")
        return f"{val.get('model', '?')}" + (f" ×{cores}" if cores else "")
    if mod == "mem":
        return f"{_humanize_bytes(val['used_bytes'])}/{_humanize_bytes(val['total_bytes'])} ({val['used_pct']:.0f}%)"
    if mod == "disk":
        return f"{val['used_pct']:.0f}% ({_humanize_bytes(val['used_bytes'])}/{_humanize_bytes(val['total_bytes'])})"
    if mod == "load":
        return f"{val['l1']:.2f} {val['l5']:.2f} {val['l15']:.2f}"
    if mod == "uptime":
        return _humanize_seconds(val["seconds"])
    if mod == "docker":
        return f"{val['running']}/{val['total']}"
    if mod == "chezmoi":
        s = val.get("status_lines", "?")
        b = val.get("commits_behind", "?")
        return f"st={s} behind={b}"
    if mod == "gpu":
        name = val.get("name", "?")
        u = val.get("vram_used_mb")
        t = val.get("vram_total_mb")
        if u is not None and t is not None and t:
            return f"{name} ({u}/{t}M)"
        return str(name)
    if mod == "network":
        return f"{val.get('hostname', '?')} {val.get('ip', '?')}"
    return str(val)


def _render_table(results: list[HostInfo], modules: list[str], console: Console) -> None:
    table = Table(title="fleet info", header_style="bold cyan")
    table.add_column("HOST", style="bold")
    table.add_column("STATUS", style="dim")
    for m in modules:
        table.add_column(m.upper())
    table.add_column("ms", justify="right", style="dim")

    for r in results:
        cells = [r.host]
        if r.status == "N/A":
            cells.append("[red]N/A[/red]")
            cells.extend("—" for _ in modules)
            cells.append(str(r.elapsed_ms))
            table.add_row(*cells)
            continue
        cells.append("[green]ok[/green]")
        for m in modules:
            cells.append(_cell(m, r.modules.get(m)))
        cells.append(str(r.elapsed_ms))
        table.add_row(*cells)
    console.print(table)


def _render_fastfetch(results: list[HostInfo], console: Console) -> None:
    """Section-per-host fastfetch dump."""
    for r in results:
        console.rule(f"[bold]{r.host}[/bold]")
        if r.fastfetch is None:
            console.print("[dim]fastfetch not requested[/dim]")
            continue
        if isinstance(r.fastfetch, dict) and "_err" in r.fastfetch:
            console.print(f"[red]fastfetch error: {r.fastfetch['_err']}[/red]")
            continue
        console.print(json.dumps(r.fastfetch, indent=2)[:4000])  # cap to avoid spam


def _emit_json(results: list[HostInfo]) -> None:
    out = [dataclasses.asdict(r) for r in results]
    print(json.dumps(out, indent=2, default=str))


def _filter_hosts(hosts: list[Host], include: str | None, exclude: str | None) -> list[Host]:
    if include:
        wanted = {h.strip() for h in include.split(",") if h.strip()}
        hosts = [h for h in hosts if h.name in wanted]
    if exclude:
        unwanted = {h.strip() for h in exclude.split(",") if h.strip()}
        hosts = [h for h in hosts if h.name not in unwanted]
    return hosts


def _select_modules(full: bool, modules: str | None, verbose: Console) -> list[str]:
    if modules:
        wanted = [m.strip() for m in modules.split(",") if m.strip()]
        unknown = [m for m in wanted if m not in _ALL_MODULES]
        if unknown:
            verbose.print(f"[yellow]warn[/yellow]: unknown modules ignored: {unknown}")
        return [m for m in wanted if m in _ALL_MODULES]
    return _ALL_MODULES if full else _DEFAULT_MODULES


def cli(
    hosts: Annotated[str | None, tyro.conf.arg(help="Comma-separated host names to include")] = None,
    exclude: Annotated[str | None, tyro.conf.arg(help="Comma-separated host names to exclude")] = None,
    config: Annotated[Path, tyro.conf.arg(help="Path to machines.toml")] = DEFAULT_CONFIG_PATH,
    ff: Annotated[bool, tyro.conf.arg(help="Run fastfetch --format json on each host; render per-host section")] = False,
    full: Annotated[bool, tyro.conf.arg(help="Include all built-in modules (adds gpu, network)")] = False,
    modules: Annotated[str | None, tyro.conf.arg(help=f"Comma-separated module names. Catalog: {','.join(_ALL_MODULES)}")] = None,
    json_out: Annotated[bool, tyro.conf.arg(name="json", help="Emit per-host JSON to stdout instead of Rich table")] = False,
    serial: Annotated[bool, tyro.conf.arg(help="Process hosts one at a time (debug)")] = False,
    max_parallel: Annotated[int, tyro.conf.arg(help="Max concurrent SSH connections (default min(8, len(hosts)))")] = 0,
    connect_timeout: Annotated[float, tyro.conf.arg(help="Per-host SSH connect timeout (seconds)")] = 15.0,
    command_timeout: Annotated[float, tyro.conf.arg(help="Per-host probe timeout (seconds)")] = 30.0,
) -> int:
    """Curated system status across the fleet. See module docstring."""
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

    selected_modules = _select_modules(full, modules, err)
    parallelism = 1 if serial else (max_parallel or min(8, len(selected)))
    sem = asyncio.Semaphore(parallelism)
    done_count = 0

    async def _bounded(h: Host) -> HostInfo:
        nonlocal done_count
        async with sem:
            try:
                return await _run_one(h, ff, connect_timeout, command_timeout)
            finally:
                done_count += 1

    async def _orchestrate(status: Any) -> list[HostInfo]:
        total = len(selected)
        async def _ticker() -> None:
            while True:
                if status is not None:
                    status.update(f"probing {done_count}/{total} hosts...")
                await asyncio.sleep(0.1)
        tick = asyncio.create_task(_ticker()) if status is not None else None
        try:
            return list(await asyncio.gather(*(_bounded(h) for h in selected)))
        finally:
            if tick is not None:
                tick.cancel()

    async def _run_with_status() -> list[HostInfo]:
        if err.is_terminal:
            with err.status(f"probing {len(selected)} hosts...", spinner="dots") as status:
                return await _orchestrate(status)
        return await _orchestrate(None)

    results = asyncio.run(_run_with_status())

    if json_out:
        _emit_json(results)
    else:
        _render_table(results, selected_modules, console)
        if ff:
            _render_fastfetch(results, console)

    failed = sum(1 for r in results if r.status == "N/A")
    return min(failed, 125)


def main() -> int:
    return tyro.cli(cli)


if __name__ == "__main__":
    sys.exit(main())
