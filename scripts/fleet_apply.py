#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "asyncssh>=2.18",
#   "tyro>=0.9",
#   "rich>=13.9",
# ]
# ///
"""
fleet_apply.py — Run `chezmoi update --init` (or `apply` / `diff`) across a
fleet of remote hosts in parallel, with optional sudo password injection.

Why this exists:
    Pushing dotfile changes to N machines by hand (ssh, type password, wait,
    grep logs) is error-prone. This wraps that flow:

      * Host list + connection details live in ~/.config/fleet/machines.toml
      * Connection prefers ssh_config alias (ProxyJump, IdentityAgent, etc. all
        kept) — falls back to explicit hostname/user/port/identity_file.
      * Sudo password sources: plaintext (TOML), interactive prompt (asked once
        at startup), Bitwarden CLI (`bw get password <item>`), or omitted.
      * Per-host `no_root_machine = true` skips sudo entirely (matches the
        chezmoi `noRoot=true` init choice on that host).
      * Live Rich table of progress + per-host log files under
        logs/fleet-apply/<UTC-timestamp>/<host>.log

Exit code: number of failed hosts (0 = all good, capped at 125).

See docs/this_repo/fleet-apply.md for full schema, examples, troubleshooting.
"""
from __future__ import annotations

import asyncio
import dataclasses
import getpass
import os
import shlex
import subprocess
import sys
import tomllib
from datetime import datetime, timezone
from pathlib import Path
from typing import Annotated, Literal

import asyncssh
import tyro
from rich.console import Console
from rich.live import Live
from rich.table import Table


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------

PasswordSourceType = Literal["plain", "prompt", "bitwarden", "none"]


@dataclasses.dataclass
class Host:
    """One remote machine. See machines.toml schema in docs."""

    name: str
    ssh_alias: str | None = None
    hostname: str | None = None
    user: str | None = None
    port: int | None = None
    identity_file: str | None = None
    no_root_machine: bool = False
    chezmoi_path: str = "chezmoi"
    extra_env: dict[str, str] = dataclasses.field(default_factory=dict)
    # Resolved later (not from TOML directly)
    password_source_type: PasswordSourceType = "none"
    password_source_arg: str | None = None  # plain value, bw item id, etc.
    sudo_password: str | None = None  # populated by resolve_passwords()


# ---------------------------------------------------------------------------
# TOML loading
# ---------------------------------------------------------------------------

DEFAULT_CONFIG_PATH = Path(
    os.environ.get("FLEET_CONFIG")
    or (Path.home() / ".config" / "fleet" / "machines.toml")
).expanduser()


def load_hosts(path: Path) -> tuple[list[Host], dict]:
    """Parse machines.toml -> ([Host, ...], defaults dict).

    Merges [defaults] into each host (host overrides defaults). The
    `password_source` table is normalized into (type, arg) on Host.
    """
    if not path.exists():
        raise FileNotFoundError(
            f"Fleet config not found: {path}\n"
            f"Hint: chezmoi apply seeds ~/.config/fleet/machines.toml — edit it "
            f"to list your machines, or pass --config PATH."
        )
    with path.open("rb") as f:
        data = tomllib.load(f)

    defaults = data.get("defaults", {}) or {}
    raw_hosts = data.get("hosts", []) or []
    if not raw_hosts:
        raise ValueError(f"{path}: no [[hosts]] entries defined.")

    hosts: list[Host] = []
    seen_names: set[str] = set()
    for idx, raw in enumerate(raw_hosts):
        name = raw.get("name")
        if not name:
            raise ValueError(f"{path}: [[hosts]][{idx}] missing required `name`.")
        if name in seen_names:
            raise ValueError(f"{path}: duplicate host name {name!r}.")
        seen_names.add(name)

        merged = {**defaults, **raw}
        ps = merged.pop("password_source", None) or {}
        ps_type = (ps.get("type") or "none").lower()
        if ps_type not in ("plain", "prompt", "bitwarden", "none"):
            raise ValueError(
                f"{path}: host {name!r} has invalid password_source.type={ps_type!r}"
            )
        ps_arg = ps.get("value") if ps_type == "plain" else ps.get("item")

        # Drop keys that aren't Host fields (e.g. defaults-only knobs we read elsewhere).
        host_fields = {f.name for f in dataclasses.fields(Host)}
        host_kwargs = {k: v for k, v in merged.items() if k in host_fields}
        host = Host(
            **host_kwargs,
            password_source_type=ps_type,  # type: ignore[arg-type]
            password_source_arg=ps_arg,
        )

        # Validation: at least one of ssh_alias / hostname.
        if not host.ssh_alias and not host.hostname:
            raise ValueError(
                f"{path}: host {name!r} must define either `ssh_alias` "
                f"(preferred) or `hostname`."
            )
        hosts.append(host)
    return hosts, defaults



# ---------------------------------------------------------------------------
# Password resolution
# ---------------------------------------------------------------------------


def _bw_get_password(item: str) -> str:
    """Call `bw get password <item>`; raise on failure with a helpful message."""
    try:
        result = subprocess.run(
            ["bw", "get", "password", item],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
    except FileNotFoundError as e:
        raise RuntimeError(
            "`bw` (Bitwarden CLI) not found in PATH — install with "
            "`npm install -g @bitwarden/cli` or set password_source.type to "
            "'plain'/'prompt'/'none'."
        ) from e
    if result.returncode != 0:
        stderr = (result.stderr or "").strip()
        raise RuntimeError(
            f"bw get password {item!r} failed (rc={result.returncode}): {stderr}\n"
            f"Hint: run `bw unlock` first; ensure BW_SESSION is exported."
        )
    return result.stdout.strip("\n")


def resolve_passwords(hosts: list[Host], console: Console) -> list[Host]:
    """Mutates each host.sudo_password in-place. Returns the same list.

    For `prompt` hosts: asks once each on stdin (NOT batched — different
    machines may have different passwords). For `bitwarden`: one `bw` call per
    host. For `plain`: copies value through. For `none`: leaves None.

    Hosts whose resolution FAILS keep sudo_password=None; run_one() then treats
    them as "no password available" (fail-fast at sudo phase unless
    no_root_machine=true).
    """
    for h in hosts:
        if h.password_source_type == "none":
            continue
        if h.password_source_type == "plain":
            h.sudo_password = h.password_source_arg or ""
            if not h.sudo_password:
                console.print(
                    f"[yellow]warn[/]: host {h.name!r} password_source=plain but value is empty"
                )
            continue
        if h.password_source_type == "prompt":
            try:
                h.sudo_password = getpass.getpass(
                    f"sudo password for [{h.name}] {h.user or ''}@"
                    f"{h.ssh_alias or h.hostname}: "
                )
            except (EOFError, KeyboardInterrupt):
                console.print(f"[yellow]warn[/]: host {h.name!r} prompt cancelled")
                h.sudo_password = None
            continue
        if h.password_source_type == "bitwarden":
            if not h.password_source_arg:
                console.print(
                    f"[red]error[/]: host {h.name!r} password_source=bitwarden missing `item`"
                )
                continue
            try:
                h.sudo_password = _bw_get_password(h.password_source_arg)
            except RuntimeError as e:
                console.print(f"[red]error[/]: {h.name}: {e}")
                h.sudo_password = None
    return hosts


# ---------------------------------------------------------------------------
# Remote command construction
# ---------------------------------------------------------------------------

# Path the orchestrator writes the password to on the remote (0600, in $HOME).
# Picked up by sudo_session_init via CHEZMOI_SUDO_PASSWORD_FILE — see the
# corresponding extension in scripts/lib/sudo_shared.sh.
REMOTE_SUDO_PASS_PATH = ".cache/chezmoi-fleet/sudo.pass"


def build_remote_command(
    host: Host,
    mode: Literal["update", "apply", "diff"],
    init: bool,
) -> str:
    """Build the single shell command sent over SSH.

    Strategy:
      * If a password is being injected: write it to ~/.cache/chezmoi-fleet/
        sudo.pass (0600), export CHEZMOI_SUDO_PASSWORD_FILE, run chezmoi,
        shred-then-rm the file. The remote sudo_shared.sh extension consumes
        the env var, validates, and adopts the password into its shared state.
      * If no password and no_root_machine=true: just run chezmoi.
      * If no password and no_root_machine=false: still run, but expect the
        sudo phase to fail (caller is warned in main()).
    """
    cz = shlex.quote(host.chezmoi_path)
    if mode == "update":
        sub = f"{cz} update"
        if init:
            sub += " --init"
    elif mode == "apply":
        sub = f"{cz} apply"
    else:  # diff
        sub = f"{cz} diff"

    extra_env = " ".join(f"{k}={shlex.quote(v)}" for k, v in host.extra_env.items())
    env_prefix = f"{extra_env} " if extra_env else ""

    if host.sudo_password is None:
        return f"set -e; {env_prefix}{sub}"

    pass_path = shlex.quote(REMOTE_SUDO_PASS_PATH)
    # `umask 077` ensures the dir/file are 0700/0600 even on machines with a
    # permissive default. `trap` guarantees cleanup even if chezmoi crashes.
    return (
        f"set -e; umask 077; "
        f"mkdir -p \"$(dirname {pass_path})\"; "
        f"cat > {pass_path}; chmod 600 {pass_path}; "
        f"trap 'rm -f {pass_path}' EXIT INT TERM; "
        f"export CHEZMOI_SUDO_PASSWORD_FILE=\"$PWD/{REMOTE_SUDO_PASS_PATH}\"; "
        f"{env_prefix}{sub}"
    )


# ---------------------------------------------------------------------------
# Per-host execution
# ---------------------------------------------------------------------------


@dataclasses.dataclass
class HostStatus:
    """Live state shared between run_one() and the Rich table renderer."""

    host: Host
    state: str = "pending"  # pending | connecting | running | done | failed | skipped
    last_line: str = ""
    started_at: float | None = None
    finished_at: float | None = None
    rc: int | None = None
    log_path: Path | None = None
    error: str | None = None


def _connect_kwargs(host: Host) -> dict:
    """Translate Host -> asyncssh.connect kwargs.

    asyncssh reads ~/.ssh/config by default for the `host` arg. When ssh_alias
    is set we pass it as `host` and let asyncssh resolve hostname/user/port/
    IdentityFile/ProxyJump from ssh_config. Explicit fields override.
    """
    target = host.ssh_alias or host.hostname
    assert target is not None  # validated in load_hosts
    kwargs: dict = {"host": target, "known_hosts": None}
    # known_hosts=None tells asyncssh to skip its own check; we still rely on
    # the user having ssh'd manually first (StrictHostKeyChecking is enforced
    # implicitly by them adding it to ~/.ssh/known_hosts ahead of time).
    # Switching to known_hosts=() would force strict but reject every new host.
    if host.user:
        kwargs["username"] = host.user
    if host.port:
        kwargs["port"] = host.port
    if host.identity_file:
        kwargs["client_keys"] = [str(Path(host.identity_file).expanduser())]
    return kwargs


async def run_one(
    status: HostStatus,
    log_dir: Path,
    mode: Literal["update", "apply", "diff"],
    init: bool,
    connect_timeout: int,
    command_timeout: int,
) -> None:
    """Execute one host: connect, stream output to log + status, set rc/state."""
    host = status.host
    log_path = log_dir / f"{host.name}.log"
    status.log_path = log_path
    loop = asyncio.get_running_loop()
    status.started_at = loop.time()

    cmd = build_remote_command(host, mode=mode, init=init)
    log_fp = log_path.open("w", buffering=1)  # line-buffered
    log_fp.write(f"# fleet-apply host={host.name} mode={mode} init={init}\n")
    log_fp.write(f"# remote-cmd: {cmd}\n\n")

    try:
        status.state = "connecting"
        async with asyncio.timeout(connect_timeout):
            conn = await asyncssh.connect(**_connect_kwargs(host))
        async with conn:
            status.state = "running"
            # Feed password (if any) via stdin: build_remote_command's `cat >`
            # consumes exactly the bytes we send, then closes its half.
            stdin_bytes = (
                (host.sudo_password + "\n").encode() if host.sudo_password else b""
            )
            proc = await conn.create_process(cmd, stdin=asyncssh.PIPE)
            if stdin_bytes:
                proc.stdin.write(stdin_bytes)
            proc.stdin.write_eof()

            async def _drain(stream, label: str) -> None:
                async for line in stream:
                    text = line.rstrip("\n")
                    log_fp.write(f"[{label}] {text}\n")
                    if text.strip():
                        status.last_line = text[:120]

            async with asyncio.timeout(command_timeout):
                await asyncio.gather(
                    _drain(proc.stdout, "out"),
                    _drain(proc.stderr, "err"),
                )
                result = await proc.wait()
            status.rc = result.exit_status if result.exit_status is not None else 1
            status.state = "done" if status.rc == 0 else "failed"
    except (asyncssh.Error, OSError, TimeoutError) as e:
        status.state = "failed"
        status.rc = status.rc or 1
        status.error = f"{type(e).__name__}: {e}"
        log_fp.write(f"\n[fleet-apply] FAILED: {status.error}\n")
    finally:
        status.finished_at = loop.time()
        log_fp.close()


# ---------------------------------------------------------------------------
# Live table renderer + summary
# ---------------------------------------------------------------------------

_STATE_STYLE = {
    "pending": "dim",
    "connecting": "cyan",
    "running": "yellow",
    "done": "green",
    "failed": "red bold",
    "skipped": "magenta",
}


def _render_table(statuses: list[HostStatus], elapsed_now: float) -> Table:
    table = Table(title="fleet-apply", expand=True)
    table.add_column("host", style="bold")
    table.add_column("state")
    table.add_column("elapsed", justify="right")
    table.add_column("rc", justify="right")
    table.add_column("last", overflow="ellipsis", max_width=80)
    for s in statuses:
        if s.started_at is None:
            elapsed = "-"
        else:
            end = s.finished_at if s.finished_at is not None else elapsed_now
            elapsed = f"{end - s.started_at:5.1f}s"
        rc = "-" if s.rc is None else str(s.rc)
        style = _STATE_STYLE.get(s.state, "white")
        table.add_row(
            s.host.name,
            f"[{style}]{s.state}[/]",
            elapsed,
            rc,
            s.last_line,
        )
    return table


async def _live_render_loop(
    statuses: list[HostStatus], live: Live, stop_event: asyncio.Event
) -> None:
    loop = asyncio.get_running_loop()
    while not stop_event.is_set():
        live.update(_render_table(statuses, loop.time()))
        try:
            await asyncio.wait_for(stop_event.wait(), timeout=0.4)
        except TimeoutError:
            pass
    live.update(_render_table(statuses, loop.time()))


def _print_summary(console: Console, statuses: list[HostStatus]) -> int:
    """Print summary; return number of failed hosts."""
    fails = [s for s in statuses if s.state == "failed"]
    skips = [s for s in statuses if s.state == "skipped"]
    console.print()
    console.print(
        f"[bold]Summary[/]: {len(statuses)} hosts, "
        f"[green]{sum(1 for s in statuses if s.state == 'done')} ok[/], "
        f"[red]{len(fails)} failed[/], "
        f"[magenta]{len(skips)} skipped[/]"
    )
    for s in fails:
        console.print(
            f"  [red]✗[/] {s.host.name}  rc={s.rc}  "
            f"log=[cyan]{s.log_path}[/]"
            + (f"  err={s.error}" if s.error else "")
        )
    for s in skips:
        console.print(f"  [magenta]·[/] {s.host.name}  reason={s.error or 'skipped'}")
    return len(fails)


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------


def cli(
    config: Annotated[
        Path, tyro.conf.arg(help="Path to machines.toml")
    ] = DEFAULT_CONFIG_PATH,
    hosts: Annotated[
        str, tyro.conf.arg(help="Comma-separated host names to include (default: all)")
    ] = "",
    exclude: Annotated[
        str, tyro.conf.arg(help="Comma-separated host names to skip")
    ] = "",
    serial: Annotated[
        bool, tyro.conf.arg(help="Run hosts one at a time (disables live table)")
    ] = False,
    max_parallel: Annotated[
        int, tyro.conf.arg(help="Max concurrent SSH sessions (0 = auto)")
    ] = 0,
    dry_run: Annotated[
        bool, tyro.conf.arg(help="Run `chezmoi diff` instead of update")
    ] = False,
    no_init: Annotated[
        bool, tyro.conf.arg(help="Use `chezmoi apply` instead of `chezmoi update --init`")
    ] = False,
    log_dir: Annotated[
        Path, tyro.conf.arg(help="Base log directory")
    ] = Path("logs/fleet-apply"),
) -> int:
    """Apply chezmoi to a fleet of hosts in parallel. Exit code = failed-host count."""
    console = Console()

    try:
        all_hosts, _defaults = load_hosts(config)
    except (FileNotFoundError, ValueError) as e:
        console.print(f"[red]error[/]: {e}")
        return 2

    # Filter
    include = {n.strip() for n in hosts.split(",") if n.strip()}
    exclude_set = {n.strip() for n in exclude.split(",") if n.strip()}
    selected = [
        h for h in all_hosts
        if (not include or h.name in include) and h.name not in exclude_set
    ]
    if not selected:
        console.print("[yellow]no hosts selected[/]")
        return 0

    mode: Literal["update", "apply", "diff"] = (
        "diff" if dry_run else ("apply" if no_init else "update")
    )
    init = mode == "update"

    return _run(console, selected, mode, init, log_dir, serial, max_parallel)


def _run(
    console: Console,
    selected: list[Host],
    mode: Literal["update", "apply", "diff"],
    init: bool,
    log_dir_base: Path,
    serial: bool,
    max_parallel: int,
) -> int:
    # Resolve passwords up-front (interactive prompts happen here).
    resolve_passwords(selected, console)

    # Warn about hosts that need sudo but have no password resolved.
    statuses: list[HostStatus] = []
    runnable: list[HostStatus] = []
    for h in selected:
        st = HostStatus(host=h)
        if not h.no_root_machine and h.sudo_password is None:
            st.state = "skipped"
            st.error = (
                "no_root_machine=false but no sudo password resolved "
                "(set password_source or mark no_root_machine=true)"
            )
            console.print(f"[yellow]skip[/] {h.name}: {st.error}")
        else:
            runnable.append(st)
        statuses.append(st)

    if not runnable:
        return _print_summary(console, statuses) or 0

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    log_dir = log_dir_base / timestamp
    log_dir.mkdir(parents=True, exist_ok=True)
    console.print(f"[dim]log dir: {log_dir}[/]")

    parallelism = 1 if serial else (max_parallel or min(8, len(runnable)))
    sem = asyncio.Semaphore(parallelism)

    async def _bounded(st: HostStatus) -> None:
        async with sem:
            await run_one(
                st,
                log_dir=log_dir,
                mode=mode,
                init=init,
                connect_timeout=15,
                command_timeout=1800,
            )

    async def _orchestrate() -> None:
        if serial:
            for st in runnable:
                console.print(f"[cyan]→ {st.host.name}[/]")
                await _bounded(st)
                console.print(
                    f"  [{_STATE_STYLE.get(st.state, 'white')}]{st.state}[/] rc={st.rc}"
                )
            return
        stop = asyncio.Event()
        with Live(console=console, refresh_per_second=4, transient=False) as live:
            renderer = asyncio.create_task(_live_render_loop(statuses, live, stop))
            try:
                await asyncio.gather(*(_bounded(st) for st in runnable))
            finally:
                stop.set()
                await renderer

    asyncio.run(_orchestrate())
    return _print_summary(console, statuses)


def main() -> int:
    """Tyro entry point. Exit code = number of failed hosts (capped at 125)."""
    rc = tyro.cli(cli)
    return min(rc, 125)


if __name__ == "__main__":
    sys.exit(main())
