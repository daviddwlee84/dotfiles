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
    chezmoi_path: str = "auto"
    # When True, bypass SSH entirely and run chezmoi as a local
    # subprocess on the orchestrator machine. Useful for including the
    # control box itself in a fleet apply (e.g. you keep your own
    # workstation in sync with the same `just fleet-apply` invocation).
    # Local hosts skip all SSH-specific config (ssh_alias/hostname/
    # user/port/identity_file are ignored) and reuse the caller's
    # ambient PATH so chezmoi_path = "auto" still works without the
    # remote-style PATH augmentation. Sudo password injection is
    # skipped — chezmoi inherits the caller's tty/sudoers state.
    local: bool = False
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

        # Validation: at least one of ssh_alias / hostname (skipped for local hosts).
        if not host.local and not host.ssh_alias and not host.hostname:
            raise ValueError(
                f"{path}: host {name!r} must define either `ssh_alias` "
                f"(preferred) or `hostname` (or set `local = true` to run "
                f"on the orchestrator machine without SSH)."
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
    force: bool = False,
    keep_going: bool = False,
) -> str:
    """Build the single shell command sent over SSH.

    Three concerns are baked in:

    1. Sudo password injection (when host.sudo_password is set): write password
       to ~/.cache/chezmoi-fleet/sudo.pass (0600 via umask 077), export
       CHEZMOI_SUDO_PASSWORD_FILE, run chezmoi, then `trap … EXIT` removes
       the pass file even if chezmoi crashes.

    2. Pager neutralisation: `PAGER=cat` and chezmoi-specific overrides force
       non-paged output. ts_nas-style hosts where `bat` panics on a missing
       theme would otherwise hang forever in a pager subprocess (no TTY → bat
       still tries to spawn).

    3. Process-group cleanup so a local Ctrl+C / SSH channel close kills the
       remote chezmoi tree, not just the wrapper shell:
         * `set -m` enables job control so each backgrounded child gets its
           own process group (= -$pid kills the whole tree).
         * `trap '… kill -TERM -$cz_pid …' INT TERM HUP` propagates the
           controller's signal — asyncssh sends SIGHUP when the channel
           closes (request_pty=True ensures the remote side delivers it).
         * `wait $cz_pid` then proxies chezmoi's real exit status back.
       Without this, an interrupted run leaves an orphan `chezmoi update`
       on the remote that holds the git source dir lock and burns CPU until
       it self-terminates.
    """
    # `--no-pager` is a chezmoi global flag — it tells chezmoi to write
    # paged subcommand output (diff, status) straight to stdout instead of
    # spawning the configured pager. Critical for non-TTY runs because
    # chezmoi's default pager is whatever the user configured (often bat /
    # less), which can panic or block forever when its own stdin/stdout
    # aren't a terminal. Setting `PAGER=cat` is NOT enough — chezmoi reads
    # its own `pager` config key and ignores PAGER.
    #
    # `chezmoi_path == "auto"` (the default) defers binary lookup to the
    # remote: PATH is augmented with every plausible install location
    # (Linuxbrew, Homebrew x86/arm64, snap, ~/.local/bin, ~/bin) so a
    # non-interactive shell — which doesn't source ~/.zshrc and therefore
    # often lacks ~/.local/bin — still finds chezmoi. To pin a specific
    # binary, set `chezmoi_path = "/abs/path/to/chezmoi"` per-host.
    # Bare "chezmoi" (no slash, no path) is treated the same as "auto" —
    # users who hand-wrote that value still benefit from PATH augmentation,
    # because rc=127 "command not found" is the most common first-run
    # failure on hosts where ~/.local/bin isn't in non-interactive PATH.
    chezmoi_path = host.chezmoi_path or "auto"
    if chezmoi_path == "auto" or "/" not in chezmoi_path:
        cz = shlex.quote(chezmoi_path if chezmoi_path != "auto" else "chezmoi")
        path_prefix = (
            'export PATH="$HOME/.local/bin:$HOME/bin:'
            '/home/linuxbrew/.linuxbrew/bin:/opt/homebrew/bin:'
            '/usr/local/bin:/snap/bin:$PATH"; '
        )
    else:
        cz = shlex.quote(chezmoi_path)
        path_prefix = ""
    cz_global = f"{cz} --no-pager"
    # `--force` makes chezmoi auto-overwrite local drift on the remote
    # (the "X has changed since chezmoi last wrote it" prompt) instead of
    # opening /dev/tty for input — we run without a PTY, so the prompt
    # would die with "could not open a new TTY". `--keep-going` continues
    # past per-file errors so one bad template doesn't abort the whole
    # apply. Both are off by default; opt in via CLI.
    #
    # `--force` is destructive: any hand-edits made on the remote box are
    # silently replaced with the canonical template render. Acceptable
    # for a "push the dotfiles repo to my fleet" workflow because managed
    # files shouldn't be edited in place.
    sub_flags = ""
    if force:
        sub_flags += " --force"
    if keep_going:
        sub_flags += " --keep-going"
    if mode == "update":
        sub = f"{cz_global} update{sub_flags}"
        if init:
            sub += " --init"
    elif mode == "apply":
        sub = f"{cz_global} apply{sub_flags}"
    else:  # diff
        # `chezmoi diff` doesn't take --force / --keep-going — it's
        # read-only and never prompts.
        sub = f"{cz_global} diff"

    # Belt-and-braces: if any sub-tool chezmoi invokes (git, ansible) honours
    # PAGER / GIT_PAGER, force them non-paged too. NB: chezmoi itself does
    # NOT honour these — that's why --no-pager above is required.
    pager_env = "PAGER=cat GIT_PAGER=cat "
    extra_env = " ".join(f"{k}={shlex.quote(v)}" for k, v in host.extra_env.items())
    env_prefix = path_prefix + pager_env + (f"{extra_env} " if extra_env else "")

    pass_path = shlex.quote(REMOTE_SUDO_PASS_PATH)
    if host.sudo_password is None:
        pre = ""
        cleanup_extra = ""
    else:
        pre = (
            f"umask 077; "
            f"mkdir -p \"$(dirname {pass_path})\"; "
            f"cat > {pass_path}; chmod 600 {pass_path}; "
            f"export CHEZMOI_SUDO_PASSWORD_FILE=\"$PWD/{REMOTE_SUDO_PASS_PATH}\"; "
        )
        cleanup_extra = f" rm -f {pass_path};"

    # Process-tree cleanup: a `trap` on INT/TERM/HUP forwards the signal to
    # chezmoi's PID, then to its whole subtree via `pkill -P`. Combined with
    # request_pty=True on the asyncssh side (which causes SSH to deliver
    # SIGHUP to the remote shell when the channel closes), this guarantees a
    # local Ctrl+C / dropped connection actually stops chezmoi instead of
    # leaving an orphan that holds the source-dir git lock and burns CPU.
    # `wait $_cz_pid` proxies chezmoi's real exit status back to the SSH client.
    return (
        f"{pre}"
        f"_cleanup() {{ "
        f"  [ -n \"${{_cz_pid:-}}\" ] && {{ "
        f"    pkill -TERM -P $_cz_pid 2>/dev/null; "
        f"    kill -TERM $_cz_pid 2>/dev/null; "
        f"  }};{cleanup_extra} "
        f"}}; "
        f"trap _cleanup INT TERM HUP; "
        f"{env_prefix}{sub} </dev/null & "
        f"_cz_pid=$!; "
        f"wait $_cz_pid; _rc=$?; "
        f"trap - INT TERM HUP;{cleanup_extra} "
        f"exit $_rc"
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


async def run_one_local(
    status: HostStatus,
    log_dir: Path,
    mode: Literal["update", "apply", "diff"],
    init: bool,
    command_timeout: int,
    force: bool = False,
    keep_going: bool = False,
) -> None:
    """Execute one local host: spawn `chezmoi` directly via subprocess.

    Bypasses asyncssh entirely. Reuses the orchestrator's PATH, sudoers
    state (no password injection — chezmoi inherits the parent tty),
    and `~/.local/share/chezmoi` source. Output is streamed to the same
    per-host log file used by SSH hosts so the rich live table is
    consistent. command_timeout is honoured via asyncio.wait_for.
    """
    host = status.host
    log_path = log_dir / f"{host.name}.log"
    status.log_path = log_path
    loop = asyncio.get_running_loop()
    status.started_at = loop.time()

    # Build a flat argv (no shell) so we don't need quoting / pager dance.
    chezmoi_bin = host.chezmoi_path if (host.chezmoi_path and host.chezmoi_path != "auto") else "chezmoi"
    argv: list[str] = [chezmoi_bin, "--no-pager"]
    if mode == "update":
        argv.append("update")
        if init:
            argv.append("--init")
    elif mode == "apply":
        argv.append("apply")
    else:
        argv.append("diff")
    if mode != "diff":
        if force:
            argv.append("--force")
        if keep_going:
            argv.append("--keep-going")

    log_fp = log_path.open("w", buffering=1)
    log_fp.write(f"# fleet-apply host={host.name} mode={mode} init={init} (local)\n")
    log_fp.write(f"# argv: {argv}\n\n")

    env = {**os.environ, "PAGER": "cat", "GIT_PAGER": "cat", **host.extra_env}
    proc = None
    try:
        status.state = "running"
        proc = await asyncio.create_subprocess_exec(
            *argv,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=env,
        )

        async def _drain(stream: asyncio.StreamReader, prefix: str) -> None:
            while True:
                line = await stream.readline()
                if not line:
                    return
                text = line.decode("utf-8", errors="replace").rstrip("\n")
                log_fp.write(f"[{prefix}] {text}\n")
                status.last_line = text

        async with asyncio.timeout(command_timeout):
            await asyncio.gather(
                _drain(proc.stdout, "out"),  # type: ignore[arg-type]
                _drain(proc.stderr, "err"),  # type: ignore[arg-type]
                proc.wait(),
            )
        status.rc = proc.returncode or 0
        status.state = "done" if status.rc == 0 else "failed"
    except TimeoutError:
        status.state = "failed"
        status.rc = -1
        status.error = f"command_timeout {command_timeout}s exceeded"
        if proc and proc.returncode is None:
            proc.terminate()
            try:
                await asyncio.wait_for(proc.wait(), timeout=5)
            except TimeoutError:
                proc.kill()
    except Exception as e:  # noqa: BLE001
        status.state = "failed"
        status.rc = -1
        status.error = str(e)
        log_fp.write(f"\n# exception: {type(e).__name__}: {e}\n")
    finally:
        status.elapsed = loop.time() - (status.started_at or loop.time())
        log_fp.close()


async def run_one(
    status: HostStatus,
    log_dir: Path,
    mode: Literal["update", "apply", "diff"],
    init: bool,
    connect_timeout: int,
    command_timeout: int,
    force: bool = False,
    keep_going: bool = False,
) -> None:
    """Execute one host: connect, stream output to log + status, set rc/state."""
    host = status.host
    if host.local:
        await run_one_local(
            status, log_dir, mode, init, command_timeout,
            force=force, keep_going=keep_going,
        )
        return
    log_path = log_dir / f"{host.name}.log"
    status.log_path = log_path
    loop = asyncio.get_running_loop()
    status.started_at = loop.time()

    cmd = build_remote_command(
        host, mode=mode, init=init, force=force, keep_going=keep_going,
    )
    log_fp = log_path.open("w", buffering=1)  # line-buffered
    log_fp.write(f"# fleet-apply host={host.name} mode={mode} init={init}\n")
    log_fp.write(f"# remote-cmd: {cmd}\n\n")

    proc = None
    conn = None
    try:
        status.state = "connecting"
        async with asyncio.timeout(connect_timeout):
            conn = await asyncssh.connect(**_connect_kwargs(host))
        try:
            status.state = "running"
            # Feed password (if any) via stdin: build_remote_command's `cat >`
            # reads exactly until EOF, so we send the password line then EOF.
            # asyncssh streams default to text mode (encoding='utf-8'); we
            # write str, not bytes — passing bytes triggers
            # `TypeError: utf_8_encode() argument 1 must be str, not bytes`.
            stdin_text = (host.sudo_password + "\n") if host.sudo_password else ""
            # NB: we deliberately do NOT request a PTY here. Two reasons:
            #   1. With a PTY, the wrapper's `cat > sudo.pass` reads from a
            #      TTY where stdin EOF requires a literal Ctrl+D byte; our
            #      `proc.stdin.write_eof()` becomes a no-op and `cat` hangs.
            #   2. PTY-attached chezmoi may re-enable colored output / sniff
            #      the terminal width. PAGER=cat already covers the pager
            #      side; lack-of-TTY makes the rest behave like CI.
            # Cleanup on local Ctrl+C / timeout is handled by:
            #   * Wrapper's `trap … pkill -TERM -P $_cz_pid` (in build_remote_command).
            #   * Explicit `proc.terminate()` + `conn.close()` in the
            #     except/finally clauses below — closing the SSH channel
            #     causes the remote shell to get SIGPIPE on its next write,
            #     and the wrapper's trap fires.
            proc = await conn.create_process(cmd, stdin=asyncssh.PIPE)
            if stdin_text:
                proc.stdin.write(stdin_text)
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
        finally:
            if conn is not None:
                conn.close()
                try:
                    await conn.wait_closed()
                except Exception:
                    pass
    except asyncio.CancelledError:
        # User Ctrl+C or task-group cancellation: best-effort terminate the
        # remote process before re-raising. proc.terminate() sends SIGTERM
        # via the SSH channel; closing the connection then triggers SIGHUP
        # on the remote shell as a belt-and-braces backstop.
        status.state = "failed"
        status.error = "cancelled by controller"
        log_fp.write(f"\n[fleet-apply] CANCELLED: terminating remote process\n")
        if proc is not None:
            try:
                proc.terminate()
            except Exception:
                pass
        if conn is not None:
            try:
                conn.close()
            except Exception:
                pass
        raise
    except (asyncssh.Error, OSError, TimeoutError) as e:
        status.state = "failed"
        status.rc = status.rc or 1
        status.error = f"{type(e).__name__}: {e}"
        log_fp.write(f"\n[fleet-apply] FAILED: {status.error}\n")
        # If timeout fired while chezmoi was still running, terminate it so
        # we don't leave an orphan on the remote.
        if proc is not None and proc.exit_status is None:
            try:
                proc.terminate()
            except Exception:
                pass
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
    connect_timeout: Annotated[
        int, tyro.conf.arg(help="SSH connect timeout per host (seconds)")
    ] = 30,
    command_timeout: Annotated[
        int,
        tyro.conf.arg(
            help=(
                "Remote chezmoi command timeout (seconds). Default 7200 = 2 h "
                "to accommodate first-run apply (Linuxbrew install + 22 ansible "
                "roles + GUI cask downloads can easily exceed 30 min). "
                "Steady-state re-apply on a warm machine usually finishes in "
                "1–5 min — drop to e.g. 600 once your fleet is past first-run."
            )
        ),
    ] = 7200,
    kill_orphans: Annotated[
        bool,
        tyro.conf.arg(
            help=(
                "Connect to each host and kill any leftover chezmoi / ansible "
                "processes owned by the SSH user, then exit. Use this to clean "
                "up after an interrupted run that left orphans (e.g. you "
                "Ctrl+C'd before the cleanup trap could fire). Skips the "
                "normal apply flow — no chezmoi command is sent."
            )
        ),
    ] = False,
    force: Annotated[
        bool,
        tyro.conf.arg(
            help=(
                "Pass --force to chezmoi update/apply on every host: silently "
                "overwrite local drift instead of prompting on a non-existent "
                "TTY (the prompt would die with 'could not open a new TTY'). "
                "Destructive — replaces hand-edits to managed files with the "
                "canonical template render. Recommended for fleet workflows "
                "where the repo is the source of truth."
            )
        ),
    ] = False,
    keep_going: Annotated[
        bool,
        tyro.conf.arg(
            help=(
                "Pass -k/--keep-going to chezmoi (default ON): continue past "
                "per-file errors instead of aborting the whole apply on the "
                "first failure. This includes the 'could not open a new TTY' "
                "error from a non-PTY conflict prompt — the conflicting file "
                "is left UNCHANGED (no override) and chezmoi proceeds to the "
                "next file. The host still reports rc!=0 in the summary so "
                "you know there was drift; use --force to actually overwrite. "
                "Pass --no-keep-going to disable (fail-fast)."
            )
        ),
    ] = True,
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

    if kill_orphans:
        return _run_kill(console, selected, connect_timeout)

    mode: Literal["update", "apply", "diff"] = (
        "diff" if dry_run else ("apply" if no_init else "update")
    )
    init = mode == "update"

    return _run(
        console, selected, mode, init, log_dir, serial, max_parallel,
        connect_timeout, command_timeout, force=force, keep_going=keep_going,
    )


def _run_kill(
    console: Console, selected: list[Host], connect_timeout: int
) -> int:
    """Connect to each host and SIGTERM stray chezmoi/ansible-playbook processes.

    Use case: a previous fleet-apply was Ctrl+C'd, the local SSH client died
    before the remote wrapper's trap could fire, and `chezmoi update` is now
    an orphan holding the source-dir git lock. This sub-command does no
    chezmoi work — it just runs `pkill -TERM` for the SSH user.

    Output is direct stdout (no Live table — the operation is fast and
    one-shot, table refresh would mostly show empty rows).
    """
    # `|| true` so pkill returning 1 (= no match) doesn't trip set -e.
    # Two-pass: chezmoi first, then ansible-playbook (chezmoi spawns ansible).
    kill_cmd = (
        "for p in chezmoi ansible-playbook ansible; do "
        "  pkill -TERM -u \"$(id -un)\" -x \"$p\" 2>/dev/null || true; "
        "done; "
        "sleep 1; "
        "for p in chezmoi ansible-playbook ansible; do "
        "  pkill -KILL -u \"$(id -un)\" -x \"$p\" 2>/dev/null || true; "
        "done; "
        "echo done"
    )
    failures = 0

    async def _kill_one(h: Host) -> None:
        nonlocal failures
        if h.local:
            # Local hosts share the orchestrator's process namespace; killing
            # `chezmoi` here would kill THIS process if `just fleet-apply
            # --kill-orphans` was itself launched from a chezmoi wrapper.
            # Use plain `pkill` outside fleet-apply if you actually need this.
            console.print(f"[yellow]·[/] {h.name} (local) — skipped")
            return
        target = h.ssh_alias or h.hostname
        try:
            async with asyncio.timeout(connect_timeout):
                conn = await asyncssh.connect(**_connect_kwargs(h))
            async with conn:
                result = await conn.run(kill_cmd, check=False)
            console.print(
                f"[green]✓[/] {h.name} ({target}) "
                f"rc={result.exit_status} "
                f"{(result.stdout or '').strip()}"
            )
        except (asyncssh.Error, OSError, TimeoutError) as e:
            failures += 1
            console.print(f"[red]✗[/] {h.name} ({target}) {type(e).__name__}: {e}")

    async def _orchestrate() -> None:
        await asyncio.gather(*(_kill_one(h) for h in selected))

    console.print(
        f"[bold]fleet-apply --kill-orphans[/] on {len(selected)} host(s) "
        f"(SIGTERM → 1s → SIGKILL on chezmoi/ansible-playbook/ansible)"
    )
    asyncio.run(_orchestrate())
    return min(failures, 125)


def _run(
    console: Console,
    selected: list[Host],
    mode: Literal["update", "apply", "diff"],
    init: bool,
    log_dir_base: Path,
    serial: bool,
    max_parallel: int,
    connect_timeout: int,
    command_timeout: int,
    force: bool = False,
    keep_going: bool = False,
) -> int:
    # Resolve passwords up-front (interactive prompts happen here).
    resolve_passwords(selected, console)

    # Warn about hosts that need sudo but have no password resolved.
    statuses: list[HostStatus] = []
    runnable: list[HostStatus] = []
    for h in selected:
        st = HostStatus(host=h)
        # Local hosts inherit the orchestrator's sudoers / TTY state, so they
        # never need the wrapper-injected sudo password — skip the password
        # gate entirely. If the apply needs sudo, chezmoi will prompt on the
        # parent terminal (or fail noisily under no-tty).
        if not h.local and not h.no_root_machine and h.sudo_password is None:
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
                connect_timeout=connect_timeout,
                command_timeout=command_timeout,
                force=force,
                keep_going=keep_going,
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
