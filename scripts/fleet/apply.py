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
scripts/fleet/apply.py — Run `chezmoi update --init` (or `apply` / `diff`)
across a fleet of remote hosts in parallel, with optional sudo password
injection. (Renamed from `scripts/fleet_apply.py` on 2026-05-13 alongside
the `fleet chezmoi` namespace refactor.)

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
import re
import shlex
import subprocess
import sys
import time
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
# Per-run log dir on the remote. fleet-apply tees chezmoi's combined output
# here so a dropped SSH session doesn't lose progress visibility — `just
# fleet-apply-tail HOST` reads the latest file. Survives across runs (one
# file per timestamp); see _gc_local_logs / `--keep-logs` for retention.
REMOTE_LOG_DIR = ".cache/chezmoi-fleet/logs"
# Same layout for local hosts so --status / --tail can probe both kinds
# uniformly. Absolute path; the SSH side uses the relative form because
# the remote shell starts in $HOME.
LOCAL_LOG_DIR = Path.home() / ".cache" / "chezmoi-fleet" / "logs"


def build_remote_command(
    host: Host,
    mode: Literal["update", "apply", "diff"],
    init: bool,
    force: bool = False,
    keep_going: bool = False,
    run_id: str = "adhoc",
    keep_logs: int = 10,
    apply_path: str = "",
    branch: str = "",
    force_checkout: bool = False,
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
        # apply_path mode: scope to one target + skip run_* scripts so an
        # ansible / Brewfile change doesn't trigger the slow re-run when
        # all you wanted was to push a dotfile edit. `--exclude=scripts`
        # is the chezmoi knob; the path is appended last so any per-mode
        # flags (--force, --keep-going) come first.
        #
        # IMPORTANT: this branch deliberately bypasses `chezmoi update`,
        # which means the remote source dir is NOT auto-pulled. Prepend an
        # explicit `git pull` of the source-path so the remote checkout
        # has the latest commit before we re-render the target. We use
        # `chezmoi source-path` (no args) to discover the source dir on
        # the remote — works regardless of where the user installed it.
        # NB: when --branch is set the git prelude below replaces this
        # plain pull with a checkout-of-branch sequence, so we skip it
        # to avoid double-pulling.
        if apply_path and not branch:
            sub = (
                f'_src=$({cz_global} source-path) && '
                f'git -C "$_src" pull --ff-only --quiet && '
                f"{sub} --exclude=scripts {shlex.quote(apply_path)}"
            )
        elif apply_path:
            sub = f"{sub} --exclude=scripts {shlex.quote(apply_path)}"
    else:  # diff
        # `chezmoi diff` doesn't take --force / --keep-going — it's
        # read-only and never prompts.
        sub = f"{cz_global} diff"
        if apply_path:
            sub += f" {shlex.quote(apply_path)}"

    # --branch BRANCH: pin the remote source dir to a feature branch
    # before the chezmoi invocation, so you can iterate on a topic branch
    # without polluting main. Default merge strategy is --ff-only (fail
    # loud on divergence so you notice). --force-checkout swaps in
    # `reset --hard origin/BRANCH` to nuke any local divergence — useful
    # when you're rebasing the topic branch and want hosts to follow.
    #
    # Implementation: fetch only that ref, checkout (creating local
    # tracking branch on first run via -B), then sync. We use chezmoi's
    # configured source dir (not assumed path) for portability across
    # hosts that installed chezmoi to different prefixes.
    if branch:
        br = shlex.quote(branch)
        if force_checkout:
            sync = f'git -C "$_src" reset --hard origin/{branch} --quiet'
        else:
            sync = f'git -C "$_src" merge --ff-only origin/{branch} --quiet'
        prelude = (
            f'_src=$({cz_global} source-path) && '
            f'git -C "$_src" fetch origin {br} --quiet && '
            f'git -C "$_src" checkout -B {br} origin/{branch} --quiet && '
            f"{sync}"
        )
        # If sub already starts with a `_src=…` prefix (apply_path branch
        # above), strip it — the prelude defines _src already.
        if sub.startswith("_src="):
            # Find the first ' && ' after _src=... and take everything after
            # the next chezmoi/source-path stanza. Easier: just rebuild.
            # The apply_path branch sets sub to "_src=… && git pull && CHEZMOI…"
            # — we want only the CHEZMOI part. Split on ' && ' and keep the
            # last segment(s).
            parts = sub.split(" && ", 2)
            sub = parts[-1] if len(parts) >= 3 else sub
        sub = f"{prelude} && {sub}"

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
    #
    # Tee to ~/.cache/chezmoi-fleet/logs/<run_id>.log via process
    # substitution so the controller's `--tail` mode (or a plain
    # `ssh HOST tail -f`) can follow progress even after the SSH session
    # this command was launched from disappears. `$!` after process
    # substitution is the BACKGROUND chezmoi job, not tee — confirmed in
    # bash 4+/zsh 5+ which is what we target. The `.exit` sidecar file lets
    # `--status` distinguish "still running" from "finished, here's the rc"
    # without having to pgrep again.
    log_path = f"{REMOTE_LOG_DIR}/{run_id}.log"
    exit_path = f"{REMOTE_LOG_DIR}/{run_id}.exit"
    log_q = shlex.quote(log_path)
    exit_q = shlex.quote(exit_path)
    log_setup = (
        f"mkdir -p {shlex.quote(REMOTE_LOG_DIR)}; "
        f"rm -f {exit_q}; "
    )
    # Log GC: keep only the N most recent .log files (and matching .exit
    # sentinels) in REMOTE_LOG_DIR. Runs AFTER chezmoi finishes, BEFORE
    # `exit $_rc`, so if it crashes the rc proxy still works. `tail -n
    # +N+1` selects everything past the keep window. keep_logs=0 disables.
    if keep_logs > 0:
        gc = (
            f"_d={shlex.quote(REMOTE_LOG_DIR)}; "
            f"_keep={keep_logs}; "
            f"ls -1t \"$_d\"/*.log 2>/dev/null | tail -n +$((_keep+1)) | "
            f"  while read -r _f; do "
            f"    rm -f \"$_f\" \"${{_f%.log}}.exit\"; "
            f"  done; "
        )
    else:
        gc = ""
    return (
        f"{pre}"
        f"{log_setup}"
        f"_cleanup() {{ "
        f"  [ -n \"${{_cz_pid:-}}\" ] && {{ "
        f"    pkill -TERM -P $_cz_pid 2>/dev/null; "
        f"    kill -TERM $_cz_pid 2>/dev/null; "
        f"  }};{cleanup_extra} "
        f"}}; "
        f"trap _cleanup INT TERM HUP; "
        f"{env_prefix}{sub} </dev/null > >(tee -a {log_q}) 2>&1 & "
        f"_cz_pid=$!; "
        f"wait $_cz_pid; _rc=$?; "
        f"echo $_rc > {exit_q} 2>/dev/null || true; "
        f"{gc}"
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
    # pending | connecting | running | done | failed | skipped | drift
    # `drift` = chezmoi exited non-zero but the only error was its inability
    #           to prompt for an unexpected target change while running
    #           non-interactively (i.e. a real drift on the remote machine
    #           that --keep-going skipped). Treated as a warning, not a fail.
    state: str = "pending"
    last_line: str = ""
    started_at: float | None = None
    finished_at: float | None = None
    rc: int | None = None
    log_path: Path | None = None
    error: str | None = None
    drift_files: list[str] = dataclasses.field(default_factory=list)


# Regex matching the chezmoi error emitted when --keep-going hits a target
# whose contents changed since chezmoi last wrote it AND there is no TTY to
# prompt the user with. Captured group 1 is the relative target path so we
# can list it in the summary. Example line:
#   chezmoi: .config/television/cable/ssh-config.toml: could not open a new
#       TTY: open /dev/tty: device not configured
_DRIFT_RE = re.compile(
    r"^chezmoi: (\S+): could not open a new TTY: open /dev/tty: ",
)


def _classify_drift(diag_lines: list[str]) -> tuple[bool, list[str]]:
    """Return (is_pure_drift, [drift_paths]).

    `is_pure_drift` is True iff every non-blank input line matches
    `_DRIFT_RE`. Used by run_one()/run_one_local() to demote rc!=0 from
    `failed` to `drift`.

    Callers feed the lines this should consider:
      * run_one_local() passes real stderr lines (chezmoi runs directly).
      * run_one() passes only `chezmoi:`-prefixed lines from the merged
        stdout+stderr stream, since the remote wrapper does
        `> >(tee -a $log) 2>&1` and we still want to ignore git-pull
        progress, "Already up to date.", etc.

    Conservative on purpose: any unrecognised line means we keep the
    `failed` classification so real errors are not silently swallowed.
    """
    drift_paths: list[str] = []
    for raw in diag_lines:
        line = raw.strip()
        if not line:
            continue
        m = _DRIFT_RE.match(line)
        if m:
            drift_paths.append(m.group(1))
            continue
        # Anything else in stderr → not a pure-drift case.
        return False, []
    return bool(drift_paths), drift_paths


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


def _gc_local_logs(keep: int) -> None:
    """Trim LOCAL_LOG_DIR to the `keep` most recent .log files (+ .exit).

    Mirrors the remote GC done by build_remote_command. keep<=0 disables.
    Silent on errors (best-effort cleanup).
    """
    if keep <= 0:
        return
    try:
        logs = sorted(
            LOCAL_LOG_DIR.glob("*.log"),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
    except OSError:
        return
    for stale in logs[keep:]:
        for ext in (".log", ".exit"):
            try:
                (LOCAL_LOG_DIR / f"{stale.stem}{ext}").unlink(missing_ok=True)
            except OSError:
                pass


async def run_one_local(
    status: HostStatus,
    log_dir: Path,
    mode: Literal["update", "apply", "diff"],
    init: bool,
    command_timeout: int,
    force: bool = False,
    keep_going: bool = False,
    keep_logs: int = 10,
    apply_path: str = "",
    branch_warning: str = "",
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
    # apply_path mode: skip run_* scripts and scope to the single target.
    # Mirrors build_remote_command's apply_path branch above.
    if apply_path and mode == "apply":
        argv.extend(["--exclude=scripts", apply_path])
    elif apply_path and mode == "diff":
        argv.append(apply_path)

    log_fp = log_path.open("w", buffering=1)
    log_fp.write(f"# fleet-apply host={host.name} mode={mode} init={init} (local)\n")
    if branch_warning:
        # Surface the skip explicitly in the log so users grepping for
        # "branch" don't think the flag was honoured silently.
        log_fp.write(
            f"# warning: --branch={branch_warning} ignored for local host "
            f"(local source is your editor's working tree; switch branches "
            f"manually with git if you really mean to)\n"
        )
    log_fp.write(f"# argv: {argv}\n\n")

    # Mirror the remote layout: write a second copy to LOCAL_LOG_DIR/<run_id>.log
    # so `just fleet-apply-status` / `--tail self` (= local) can find this run
    # using the same code path as SSH hosts. Also drop a .exit sentinel when
    # done. log_dir.name is the timestamp like "20260422T140446Z".
    LOCAL_LOG_DIR.mkdir(parents=True, exist_ok=True)
    cache_log = LOCAL_LOG_DIR / f"{log_dir.name}.log"
    cache_exit = LOCAL_LOG_DIR / f"{log_dir.name}.exit"
    cache_exit.unlink(missing_ok=True)
    cache_fp = cache_log.open("w", buffering=1)

    env = {**os.environ, "PAGER": "cat", "GIT_PAGER": "cat", **host.extra_env}
    proc = None
    stderr_lines: list[str] = []
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
                cache_fp.write(f"{text}\n")  # plain combined for tail -F
                status.last_line = text
                if prefix == "err":
                    stderr_lines.append(text)

        async with asyncio.timeout(command_timeout):
            # Spawn the three coroutines but key the wait on a kill -0 poll —
            # NOT on proc.wait() OR an asyncio.gather of all three. Reason:
            # chezmoi's run_onchange_* scripts (ansible, brew bundle, mas,
            # etc.) routinely leave background children that inherit our
            # stdout/stderr fds and outlive their parent script.
            #
            # Two layers of asyncio quirk make this tricky:
            #   1. asyncio.gather(_drain, _drain, proc.wait) blocks because
            #      _drain waits on stream EOF, which only fires when ALL fd
            #      holders close — orphan grandchildren never close ours.
            #   2. proc.wait() ALONE also blocks: asyncio's
            #      BaseSubprocessTransport._try_finish only fires
            #      _process_exited when proc.returncode is set AND all
            #      stdin/stdout/stderr pipes are closed. So even
            #      `await proc.wait()` waits for the orphans.
            #
            # Workaround: poll `os.kill(pid, 0)` (signal 0 = existence check,
            # doesn't actually signal) at 100ms intervals. When that throws
            # ProcessLookupError, chezmoi itself is gone — the orphans are
            # someone else's problem. We don't waitpid() directly because
            # asyncio's child watcher owns the zombie reap.
            #
            # See pitfalls/fleet-apply-self-stuck-running.md for the full
            # debugging story including the failed first-fix attempt.
            stdout_task = asyncio.create_task(_drain(proc.stdout, "out"))  # type: ignore[arg-type]
            stderr_task = asyncio.create_task(_drain(proc.stderr, "err"))  # type: ignore[arg-type]

            async def _wait_for_chezmoi_exit() -> None:
                while True:
                    try:
                        os.kill(proc.pid, 0)
                        await asyncio.sleep(0.1)
                    except ProcessLookupError:
                        # chezmoi is gone. Give asyncio's watcher up to 5s to
                        # set returncode (it'll do so once the SIGCHLD fires
                        # and the child watcher reaps).
                        for _ in range(50):
                            if proc.returncode is not None:
                                return
                            await asyncio.sleep(0.1)
                        return

            # Phase 1: wait for chezmoi itself to exit (not the orphans).
            await _wait_for_chezmoi_exit()
            # Phase 2: give drains a short grace period to flush any
            # buffered output that's already in flight, then cancel them.
            # 5s is enough for any sane buffer; orphan-held pipes will
            # never EOF so we MUST cancel rather than wait.
            grace = 5.0
            done, pending = await asyncio.wait(
                [stdout_task, stderr_task],
                timeout=grace,
                return_when=asyncio.ALL_COMPLETED,
            )
            for task in pending:
                task.cancel()
            if pending:
                await asyncio.gather(*pending, return_exceptions=True)
                # Note for future debugging: if pending is non-empty,
                # an orphan child of chezmoi is holding our pipes open.
                # Most common offenders on macOS: brew bundle, mas
                # install, ansible homebrew tasks. Use lsof -p $$ |
                # grep -i pipe + pgrep -af 'brew|mas|ansible' to find
                # them. This is benign — chezmoi's exit code is correct.
                log_fp.write(
                    f"\n# fleet-apply: {len(pending)} stream(s) still open "
                    f"{grace}s after chezmoi exit (orphan child holding "
                    f"stdout/stderr fds — see pitfalls/"
                    f"fleet-apply-self-stuck-running.md). Output below "
                    f"this point may be truncated.\n"
                )
            # If asyncio still hasn't set returncode (very rare — child
            # watcher race), reap manually so status.rc isn't None.
            if proc.returncode is None:
                try:
                    pid, raw_status = os.waitpid(proc.pid, os.WNOHANG)
                    if pid != 0 and hasattr(proc, "_transport"):
                        proc._transport._returncode = (  # type: ignore[attr-defined]
                            os.waitstatus_to_exitcode(raw_status)
                        )
                except (ChildProcessError, AttributeError, OSError):
                    pass
        status.rc = proc.returncode or 0
        if status.rc == 0:
            status.state = "done"
        else:
            is_drift, paths = _classify_drift(stderr_lines)
            if is_drift:
                status.state = "drift"
                status.drift_files = paths
            else:
                status.state = "failed"
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
        # Freeze elapsed by stamping finished_at — the live renderer keys
        # off this field to stop the clock (see _render_table). Setting a
        # bare `status.elapsed` attr (the previous bug) was a no-op because
        # HostStatus doesn't declare it AND the renderer never reads it,
        # so the `self` row kept ticking even after state=done.
        status.finished_at = loop.time()
        log_fp.close()
        cache_fp.close()
        # Write the sentinel last so a `--status` poll sees the rc only
        # after the cache log has been fully flushed (avoids the race
        # where a probe sees "finished" but tail -F is still mid-line).
        try:
            cache_exit.write_text(f"{status.rc if status.rc is not None else -1}\n")
        except OSError:
            pass
        # GC after writing sentinel so the just-finished run is itself
        # in the keep window.
        _gc_local_logs(keep_logs)


async def run_one(
    status: HostStatus,
    log_dir: Path,
    mode: Literal["update", "apply", "diff"],
    init: bool,
    connect_timeout: int,
    command_timeout: int,
    force: bool = False,
    keep_going: bool = False,
    keep_logs: int = 10,
    apply_path: str = "",
    branch: str = "",
    force_checkout: bool = False,
) -> None:
    """Execute one host: connect, stream output to log + status, set rc/state."""
    host = status.host
    if host.local:
        # --branch is intentionally NOT honoured for local hosts: the local
        # source dir IS your editor's working tree, switching it under your
        # feet would be hostile. Warn (via the log) but continue with the
        # local working tree as-is.
        await run_one_local(
            status, log_dir, mode, init, command_timeout,
            force=force, keep_going=keep_going, keep_logs=keep_logs,
            apply_path=apply_path, branch_warning=branch,
        )
        return
    log_path = log_dir / f"{host.name}.log"
    status.log_path = log_path
    loop = asyncio.get_running_loop()
    status.started_at = loop.time()

    cmd = build_remote_command(
        host, mode=mode, init=init, force=force, keep_going=keep_going,
        run_id=log_dir.name, keep_logs=keep_logs, apply_path=apply_path,
        branch=branch, force_checkout=force_checkout,
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

            # The remote wrapper does `> >(tee -a $log) 2>&1`, so chezmoi's
            # stderr is merged into stdout before asyncssh sees it — i.e.
            # `proc.stderr` is effectively always empty here. To classify
            # drift we collect chezmoi's own diagnostic lines (those
            # prefixed with `chezmoi:`) from BOTH streams. Non-chezmoi
            # output (git pull progress, "Already up to date.", etc.) is
            # excluded so it doesn't trip _classify_drift's conservative
            # "any unrecognised line → failed" rule. See pitfalls notes
            # and CLAUDE.md "Process substitution + sentinel are
            # load-bearing" — we cannot un-merge the streams.
            diag_lines: list[str] = []

            async def _drain(stream, label: str) -> None:
                async for line in stream:
                    text = line.rstrip("\n")
                    log_fp.write(f"[{label}] {text}\n")
                    if text.strip():
                        status.last_line = text[:120]
                    if text.lstrip().startswith("chezmoi:"):
                        diag_lines.append(text)

            async with asyncio.timeout(command_timeout):
                await asyncio.gather(
                    _drain(proc.stdout, "out"),
                    _drain(proc.stderr, "err"),
                )
                result = await proc.wait()
            status.rc = result.exit_status if result.exit_status is not None else 1
            if status.rc == 0:
                status.state = "done"
            else:
                is_drift, paths = _classify_drift(diag_lines)
                if is_drift:
                    status.state = "drift"
                    status.drift_files = paths
                else:
                    status.state = "failed"
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
    "drift": "yellow bold",
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
    """Print summary; return number of failed hosts.

    `drift` hosts are reported as warnings but do NOT count toward the
    return value — a drift means chezmoi successfully ran every other file
    and only refused to overwrite a hand-edited target. The user is expected
    to resolve them manually (re-run with --force, or merge changes back to
    source). See docs/this_repo/fleet-apply.md → Conflict handling.
    """
    fails = [s for s in statuses if s.state == "failed"]
    skips = [s for s in statuses if s.state == "skipped"]
    drifts = [s for s in statuses if s.state == "drift"]
    console.print()
    console.print(
        f"[bold]Summary[/]: {len(statuses)} hosts, "
        f"[green]{sum(1 for s in statuses if s.state == 'done')} ok[/], "
        f"[red]{len(fails)} failed[/], "
        f"[yellow]{len(drifts)} drift[/], "
        f"[magenta]{len(skips)} skipped[/]"
    )
    for s in fails:
        console.print(
            f"  [red]✗[/] {s.host.name}  rc={s.rc}  "
            f"log=[cyan]{s.log_path}[/]"
            + (f"  err={s.error}" if s.error else "")
        )
    for s in drifts:
        files = ", ".join(s.drift_files) if s.drift_files else "?"
        console.print(
            f"  [yellow]⚠[/] {s.host.name}  drift in: {files}  "
            f"log=[cyan]{s.log_path}[/]  "
            f"[dim](resolve: --force, or sync edits back to source)[/]"
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
                "1–5 min — drop to e.g. 600 once your fleet is past first-run. "
                "Note: this is the BLUNT outer timeout that kills the entire "
                "chezmoi+ansible chain via SIGHUP; ansible has no per-task "
                "timeout, so a stuck `npm install` / `apt update` will burn "
                "the whole budget. If a host is stuck, use --status to see "
                "where, then --command-timeout 600 + fleet-apply-kill to "
                "force-bound the next attempt."
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
    status: Annotated[
        bool,
        tyro.conf.arg(
            help=(
                "Connect to each selected host and report whether a chezmoi "
                "or ansible-playbook process is still running (typically "
                "leftover from a fleet-apply whose SSH session you killed "
                "locally). For each host shows: state (running/idle), the "
                "active PIDs, the most recent fleet-apply run id, and the "
                "last few lines of its remote log. Read-only — does not "
                "kill or apply."
            )
        ),
    ] = False,
    tail: Annotated[
        str,
        tyro.conf.arg(
            help=(
                "Live-tail the remote fleet-apply log of HOST (single host "
                "name). Use after killing your local SSH session to follow "
                "the still-running chezmoi/ansible on the other side. "
                "Defaults to the most recent run on that host; pass "
                "`HOST:RUN_ID` (e.g. `lab-box:20260422T133615Z`) to pin a "
                "specific run. Exits when the remote run finishes (sentinel "
                "file appears) or you Ctrl+C — neither stops the remote."
            )
        ),
    ] = "",
    compact: Annotated[
        bool,
        tyro.conf.arg(
            help=(
                "Compact post-mortem view of a finished (or hung) run across "
                "all selected hosts. By default each host picks its newest "
                "log independently; pin to a specific run with "
                "--compact-run-id RUN_ID to compare the same run across the "
                "fleet. For each host shows: final TASK number reached, "
                "total ansible runtime, top 5 slow tasks, which run_* "
                "script failed (if any), and final exit code. Read-only — "
                "pulls log + sentinel via SSH and parses locally. Use after "
                "a broadcast finishes when --tail per host is too noisy and "
                "--status doesn't give enough detail."
            )
        ),
    ] = False,
    compact_run_id: Annotated[
        str,
        tyro.conf.arg(
            help=(
                "Pin --compact to a specific RUN_ID (e.g. "
                "`20260422T151551Z`). Default empty = each host picks its "
                "own latest log."
            )
        ),
    ] = "",
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
    keep_logs: Annotated[
        int,
        tyro.conf.arg(
            help=(
                "Retain at most N most-recent fleet-apply logs in "
                "~/.cache/chezmoi-fleet/logs/ on each host (and locally for "
                "self). Older .log + .exit pairs are deleted at the end of "
                "each run. Default 10. Pass 0 to disable GC and accumulate "
                "logs forever (you'll want to `rm -rf ~/.cache/chezmoi-fleet/"
                "logs` periodically)."
            )
        ),
    ] = 10,
    watch: Annotated[
        int,
        tyro.conf.arg(
            help=(
                "After --status, repeat every N seconds until every host "
                "reports finished/idle (or you Ctrl+C). 0 = single shot "
                "(default). Useful when you've Ctrl+C'd a long fleet-apply "
                "and want to passively wait for the remotes to wrap up "
                "without manually re-running --status. Honoured ONLY with "
                "--status (no effect on apply / tail / kill)."
            )
        ),
    ] = 0,
    apply_only_path: Annotated[
        str,
        tyro.conf.arg(
            help=(
                "Run `chezmoi apply --exclude=scripts <PATH>` instead of "
                "the default `chezmoi update --init`. PATH is a chezmoi "
                "TARGET path (i.e. relative to $HOME, like "
                "`.config/zsh/aliases.zsh` — NOT a source path). On remote "
                "hosts an explicit `git -C <source> pull --ff-only` is run "
                "first so the host's checkout has your latest commit; "
                "run_* scripts (ansible / Brewfile) are skipped via "
                "--exclude=scripts. Local hosts skip the git pull (the "
                "source IS the working tree). Intended for vibe loops "
                "where you've edited one dotfile and want fast feedback "
                "across the fleet without 5–30 min full apply. You still "
                "need to `git push` first for remotes to see the edit. "
                "Empty = normal full-apply mode."
            )
        ),
    ] = "",
    branch: Annotated[
        str,
        tyro.conf.arg(
            help=(
                "Pin remote source dir to this branch instead of pulling "
                "main. Implementation: `git fetch origin BRANCH && git "
                "checkout -B BRANCH origin/BRANCH && git merge --ff-only "
                "origin/BRANCH` runs before chezmoi. Switches mode to "
                "`apply` (since `chezmoi update` would re-pull main). "
                "Default merge is --ff-only — fails loud on divergence so "
                "you notice. Use --force-checkout to nuke local divergence "
                "with `reset --hard` (needed when you rebase the topic "
                "branch). LOCAL hosts ignore this flag (their source dir "
                "IS your working tree; switching it would be hostile)."
            )
        ),
    ] = "",
    force_checkout: Annotated[
        bool,
        tyro.conf.arg(
            help=(
                "With --branch, replace `git merge --ff-only` with `git "
                "reset --hard origin/BRANCH`. Destroys uncommitted changes "
                "and any local divergence on the remote source dir. Useful "
                "when you've force-pushed a rebased topic branch and want "
                "every host to follow. No effect without --branch."
            )
        ),
    ] = False,
    readiness: Annotated[
        bool,
        tyro.conf.arg(
            help=(
                "Pre-flight readiness probe (`just fleet-status`). Connects "
                "to each selected host once and reports per-host state — "
                "would `fleet-apply` succeed right now? States: up-to-date, "
                "ready-to-update, behind, drift, dirty, busy, "
                "init-in-progress (chezmoi update/apply/init mid-flight), "
                "toml-mismatch "
                "(NEW prompt keys not yet answered — the david_ubuntu "
                "failure mode), not-init, no-source, no-chezmoi, "
                "unreachable. Read-only; "
                "always exits 0 (use --readiness-json for scripting). Pair "
                "with --hosts to scope. Cheaper than --dry-run (no full "
                "chezmoi diff) and more actionable than --status (which "
                "only sees live processes)."
            )
        ),
    ] = False,
    readiness_no_fetch: Annotated[
        bool,
        tyro.conf.arg(
            help=(
                "With --readiness, skip `git fetch` on the remote. Faster "
                "(saves ~0.5–2s per host) but the 'behind' state will be "
                "stale — you may apply without realising the remote has "
                "new commits. Useful offline or when you only care about "
                "drift / busy / init state."
            )
        ),
    ] = False,
    readiness_json: Annotated[
        bool,
        tyro.conf.arg(
            help=(
                "With --readiness, emit machine-readable JSON to stdout "
                "instead of the Rich table. Schema: list of "
                "{host, state, notes, behind, ahead, dirty, drift_count, "
                "branch, local_sha, remote_sha, busy_pids, error}. Pipe "
                "into `jq` for pre-apply gates in CI."
            )
        ),
    ] = False,
    no_preflight: Annotated[
        bool,
        tyro.conf.arg(
            help=(
                "Skip the pre-flight readiness probe that runs before "
                "`fleet-apply` and warns (with a 5s countdown) when any "
                "selected host is in `init-in-progress` state — i.e. a "
                "`chezmoi update --init` / `chezmoi init` is already running "
                "(often paused at an interactive prompt in another SSH "
                "session). Default behaviour is warn-don't-refuse: the "
                "countdown auto-continues so scripted/CI use is unaffected. "
                "No effect with --readiness / --status / --tail / --kill / "
                "--dry-run (they don't apply)."
            )
        ),
    ] = False,
) -> int:
    console = Console()

    try:
        all_hosts, _defaults = load_hosts(config)
    except FileNotFoundError as e:
        # Friendlier exit for --readiness (the "is my fleet ready?" probe):
        # missing inventory is the expected first-run state, not an error.
        # Apply / kill / status / tail all keep the exit-2 behaviour because
        # the user asked to do something and we can't.
        if readiness:
            console.print(f"[yellow]no fleet configured yet[/] — {e}")
            console.print(
                "[dim]hint:[/] run [bold]fleet edit[/] to add machines, "
                "then re-run [bold]fleet chezmoi status[/]."
            )
            return 0
        console.print(f"[red]error[/]: {e}")
        return 2
    except ValueError as e:
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
        if readiness:
            console.print(
                "[yellow]no hosts selected[/] — "
                "edit [bold]~/.config/fleet/machines.toml[/] "
                "(or run [bold]fleet edit[/])."
            )
            return 0
        console.print("[yellow]no hosts selected[/]")
        return 0

    if kill_orphans:
        return _run_kill(console, selected, connect_timeout)

    if readiness:
        return _run_readiness(
            console, selected, connect_timeout,
            no_fetch=readiness_no_fetch, json_out=readiness_json,
        )

    if status:
        return _run_status(console, selected, connect_timeout, watch=watch)

    if compact:
        return _run_compact(console, selected, compact_run_id, connect_timeout)

    if tail:
        # `tail` is a HOST or HOST:RUN_ID spec — resolve against `selected`
        # so --hosts filtering still applies (i.e. user can't tail an
        # excluded host without re-listing it).
        if ":" in tail:
            tname, run_id = tail.split(":", 1)
        else:
            tname, run_id = tail, ""
        match = next((h for h in selected if h.name == tname), None)
        if match is None:
            console.print(
                f"[red]error[/]: host {tname!r} not in selected set "
                f"({', '.join(h.name for h in selected)})"
            )
            return 2
        return _run_tail(console, match, run_id, connect_timeout)

    mode: Literal["update", "apply", "diff"] = (
        "diff" if dry_run else ("apply" if (no_init or apply_only_path or branch) else "update")
    )
    init = mode == "update"

    # Pre-flight readiness probe (only on real apply paths; --dry-run is
    # safe enough on its own, --status/--tail/--kill never reach here).
    # Warn-don't-refuse: 5s countdown auto-continues so scripted/CI use is
    # unaffected. Catches the david_ubuntu failure mode where a paused
    # `chezmoi update --init` (waiting for an interactive prompt in another
    # SSH session) would otherwise silently block the new fleet-apply.
    if mode != "diff" and not no_preflight:
        rc_preflight = _run_preflight(
            console, selected, connect_timeout,
        )
        if rc_preflight != 0:
            return rc_preflight

    rc = _run(
        console, selected, mode, init, log_dir, serial, max_parallel,
        connect_timeout, command_timeout, force=force, keep_going=keep_going,
        keep_logs=keep_logs, apply_path=apply_only_path,
        branch=branch, force_checkout=force_checkout,
    )
    # If the run was Ctrl+C'd locally, the remote chezmoi/ansible may still
    # be running (the wrapper's SIGHUP trap covers most cases but not all,
    # e.g. if asyncssh closed the channel cleanly without delivering HUP).
    # Print a cheat-sheet so the user knows their next move. We detect this
    # heuristically: any host left in connecting/running state means the
    # controller bailed before the remote signalled completion.
    # (Note: _run handles its own KeyboardInterrupt; here we just report.)
    return rc


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


# Probe script run on each host by --status. Emits one line per recognised
# state followed by short context. Format is parsed by _run_status() below;
# keep it stable. We use printf so the output is locale-independent (echo's
# behaviour with backslashes varies across shells).
_STATUS_PROBE_CMD = (
    # 1) Find live chezmoi/ansible PIDs owned by this user.
    #    POSITIVE filter on cmdline (not just process name) to avoid false
    #    positives from `chezmoi cd` interactive shells, `chezmoi shell`,
    #    or editor processes whose argv contains "chezmoi" because the
    #    workspace folder is named that. fleet-apply wrappers always
    #    invoke chezmoi with the verb `update` or `apply`; ansible-playbook
    #    is unambiguous (only ansible spawns it). awk filters the cmdline
    #    column from `pgrep -lf` output, then re-emits a comma-joined PID
    #    list compatible with the rest of this snippet. NB: `-l` works on
    #    both procps-ng (Linux) and BSD pgrep (macOS).
    #
    #    SELF-MATCH HAZARD: this probe snippet ITSELF contains the literal
    #    strings `chezmoi`, `update`, `apply` (in this very comment + the
    #    awk regex). pgrep -lf will see our wrapping shell's cmdline and
    #    match it. Workaround: exclude $$ (probe shell PID) and its parent
    #    (sshd or zsh -c). We can't use $PPID reliably across shells, so
    #    we capture both at the start.
    "_self_pid=$$; _parent_pid=$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' '); "
    "_pids=$(pgrep -u \"$(id -un)\" -lf 'chezmoi|ansible-playbook' 2>/dev/null "
    "  | awk -v self=\"$_self_pid\" -v parent=\"$_parent_pid\" "
    "        '{ pid=$1; if (pid==self || pid==parent) next; "
    "           $1=\"\"; sub(/^ /, \"\"); "
    "           if ($0 ~ /ansible-playbook/) { print pid; next } "
    "           if ($0 ~ /chezmoi/ && ($0 ~ / update/ || $0 ~ / apply/ || $0 ~ / init/)) { print pid } }' "
    "  | paste -sd, - || true); "
    # 2) Find the most recent run log + sentinel.
    "_dir=\"$HOME/.cache/chezmoi-fleet/logs\"; "
    "_latest=$(ls -t \"$_dir\"/*.log 2>/dev/null | head -1); "
    "_run_id=$(basename \"${_latest:-}\" .log 2>/dev/null); "
    # 3) Decide state.
    #    - running:   live PIDs found
    #    - finished:  log + sentinel both present (sentinel was written)
    #    - abandoned: log present BUT sentinel missing AND no live PIDs.
    #                 Means the wrapper got SIGKILL (not TERM/INT/HUP)
    #                 before its trap could write `echo $_rc > sentinel`.
    #                 Common cause: parent OOM-killed, manual `kill -9`,
    #                 or one of ansible's child processes (npm, apt, etc.)
    #                 cascaded into a process tree teardown.
    #    - idle:      no log at all (host has never been hit by fleet-apply,
    #                 or all logs were GC'd).
    "if [ -n \"$_pids\" ]; then "
    "  printf 'STATE=running\\n'; "
    "  printf 'PIDS=%s\\n' \"$_pids\"; "
    "elif [ -n \"$_latest\" ] && [ -f \"$_dir/$_run_id.exit\" ]; then "
    "  printf 'STATE=finished\\n'; "
    "  printf 'EXIT=%s\\n' \"$(cat \"$_dir/$_run_id.exit\" 2>/dev/null)\"; "
    "elif [ -n \"$_latest\" ]; then "
    "  printf 'STATE=abandoned\\n'; "
    "else "
    "  printf 'STATE=idle\\n'; "
    "fi; "
    "printf 'RUN_ID=%s\\n' \"${_run_id:-}\"; "
    # 4) Last 5 lines of the latest log (separator first so parser knows
    #    where structured fields end).
    "printf 'LOG_TAIL_BEGIN\\n'; "
    "[ -n \"$_latest\" ] && tail -5 \"$_latest\" 2>/dev/null; "
    "printf 'LOG_TAIL_END\\n'"
)


def _probe_local() -> tuple[dict, str]:
    """Local-host equivalent of _STATUS_PROBE_CMD.

    Reads LOCAL_LOG_DIR for the most recent run and looks for a
    chezmoi/ansible-playbook process owned by the current user. Cannot
    use the same shell snippet because we'd need to fork to a subprocess
    just for pgrep; reading /proc / running pgrep directly is simpler.
    """
    fields: dict[str, str] = {}
    # Find latest run via mtime, mirroring the remote `ls -t | head -1`.
    try:
        logs = sorted(
            LOCAL_LOG_DIR.glob("*.log"),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
    except OSError:
        logs = []
    latest = logs[0] if logs else None
    run_id = latest.stem if latest else ""

    # pgrep for live processes owned by us. We do POSITIVE matching on the
    # full cmdline because plain `pgrep -x chezmoi` matches:
    #   - `chezmoi cd` interactive shells (long-lived, common during dev)
    #   - `chezmoi shell` invocations
    #   - Editor extension hosts whose argv contains the word "chezmoi"
    #     because the workspace folder is named that (e.g. Cursor's
    #     "Cursor Helper (Plugin): extension-host chezmoi [...]")
    # All three are NOT fleet-apply siblings and would falsely flip self
    # into 'running'. fleet-apply wrappers always invoke chezmoi as either
    # `chezmoi … update …` or `chezmoi … apply …`, so match on those verbs
    # explicitly. ansible-playbook is unambiguous (only ansible spawns it).
    #
    # Trade-off: a hand-typed `chezmoi diff` from another shell would also
    # match our `--apply` filter? No — `diff` isn't in our positive list.
    # The cost is missing manual `chezmoi apply` from another shell — but
    # that's literally indistinguishable from a fleet-apply local run, and
    # the user wouldn't run both at once anyway.
    pid_list: list[str] = []
    try:
        # -lf: long format (PID + full cmdline) so we can grep verbs.
        # Works identically on Linux procps-ng and macOS BSD pgrep.
        result = subprocess.run(
            ["pgrep", "-u", str(os.getuid()), "-lf",
             "chezmoi|ansible-playbook"],
            capture_output=True, text=True, check=False,
        )
        for line in result.stdout.splitlines():
            parts = line.split(None, 1)
            if len(parts) != 2:
                continue
            pid_s, cmd = parts
            # Positive match: chezmoi running update/apply/init, OR ansible-playbook.
            if "ansible-playbook" in cmd:
                pid_list.append(pid_s)
            elif "chezmoi" in cmd and (
                " update" in cmd or " apply" in cmd or " init" in cmd
            ):
                pid_list.append(pid_s)
    except FileNotFoundError:
        pass
    pids = ",".join(pid_list)

    # Exclude our own PID and parents — the controller running this probe
    # IS chezmoi-adjacent in some setups (e.g. invoked from `chezmoi
    # execute-template`). Conservative filter: drop any PID in our own
    # ancestor chain.
    if pids:
        own = {os.getpid(), os.getppid()}
        pids = ",".join(p for p in pids.split(",") if int(p) not in own)

    if pids:
        fields["STATE"] = "running"
        fields["PIDS"] = pids
    elif latest and (LOCAL_LOG_DIR / f"{run_id}.exit").exists():
        fields["STATE"] = "finished"
        try:
            fields["EXIT"] = (LOCAL_LOG_DIR / f"{run_id}.exit").read_text().strip()
        except OSError:
            fields["EXIT"] = "?"
    elif latest:
        # Log present but no sentinel and no live PIDs → the wrapper was
        # SIGKILL'd (or never installed its trap). See _STATUS_PROBE_CMD
        # for full reasoning. Distinguishing this from 'idle' (no log at
        # all) lets `--watch` know there's nothing to wait for AND that
        # something went wrong.
        fields["STATE"] = "abandoned"
    else:
        fields["STATE"] = "idle"
    fields["RUN_ID"] = run_id

    tail = ""
    if latest:
        try:
            with latest.open() as fp:
                lines = fp.readlines()[-5:]
            tail = "".join(lines)
        except OSError:
            pass
    return fields, tail


def _run_status(
    console: Console, selected: list[Host], connect_timeout: int,
    watch: int = 0,
) -> int:
    """Show whether each host has a running chezmoi/ansible process.

    Use case: you Ctrl+C'd a fleet-apply run locally but suspect the remote
    chezmoi/ansible is still chugging along (the wrapper's SIGHUP trap
    doesn't always fire — e.g. asyncssh closing the channel "cleanly"
    skips HUP). This sub-command answers "what's still running where?"
    without disturbing anything. Read-only — no chezmoi command sent.

    `watch > 0` re-probes every `watch` seconds and exits when no host is
    in `running` state (or on Ctrl+C). Useful as a passive "wait until
    everyone's done" cursor after killing the controller. Polls are kept
    short to dominate latency, not host load — pgrep + a 1-line ls is
    fast enough to run every 5–10s on a 100-host fleet without strain.

    Output per host: state (running/finished/idle), the latest run id,
    PIDs (if running), exit code (if finished), and the last 5 log lines.
    Always returns 0 — this is a probe, not a verdict.
    """
    async def _probe_one(h: Host) -> tuple[Host, dict, str]:
        if h.local:
            return h, *_probe_local()
        try:
            async with asyncio.timeout(connect_timeout):
                conn = await asyncssh.connect(**_connect_kwargs(h))
            async with conn:
                result = await conn.run(_STATUS_PROBE_CMD, check=False)
            stdout = result.stdout or ""
        except (asyncssh.Error, OSError, TimeoutError) as e:
            return h, {"STATE": "error"}, f"{type(e).__name__}: {e}\n"
        # Parse KEY=VAL lines until LOG_TAIL_BEGIN; the rest is log tail.
        fields: dict[str, str] = {}
        log_lines: list[str] = []
        in_tail = False
        for line in stdout.splitlines():
            if line == "LOG_TAIL_BEGIN":
                in_tail = True
                continue
            if line == "LOG_TAIL_END":
                in_tail = False
                continue
            if in_tail:
                log_lines.append(line)
            elif "=" in line:
                k, _, v = line.partition("=")
                fields[k] = v
        return h, fields, "\n".join(log_lines) + ("\n" if log_lines else "")

    async def _orchestrate() -> list[tuple[Host, dict, str]]:
        return await asyncio.gather(*(_probe_one(h) for h in selected))

    def _render(results: list[tuple[Host, dict, str]], iteration: int) -> bool:
        """Render one probe pass; return True if any host still running."""
        suffix = f" (poll #{iteration})" if iteration > 1 else ""
        console.print(
            f"[bold]fleet-apply --status[/] on {len(selected)} host(s){suffix}"
        )
        table = Table(title="remote chezmoi state", expand=True)
        table.add_column("host", style="bold")
        table.add_column("state")
        table.add_column("run_id", overflow="fold")
        table.add_column("detail", overflow="fold")
        state_color = {
            "running": "yellow",
            "finished": "green",
            "abandoned": "red",
            "idle": "dim",
            "skipped": "magenta",
            "error": "red bold",
        }
        any_running = False
        for h, fields, _tail in results:
            st = fields.get("STATE", "?")
            if st == "running":
                any_running = True
                detail = f"pids={fields.get('PIDS', '?')}"
            elif st == "finished":
                detail = f"exit={fields.get('EXIT', '?')}"
            elif st == "abandoned":
                detail = "no sentinel — wrapper SIGKILL'd?"
            else:
                detail = ""
            color = state_color.get(st, "white")
            table.add_row(
                h.name,
                f"[{color}]{st}[/]",
                fields.get("RUN_ID", "") or "-",
                detail,
            )
        console.print(table)

        # Show log tails inline (under the table) so the user can see
        # context without a second `--tail` round-trip. Only for
        # non-idle hosts. Skip in watch mode after the first pass to
        # keep the polling output compact.
        if iteration <= 1:
            for h, fields, tail in results:
                if fields.get("STATE") in {"idle", "skipped"} or not tail.strip():
                    continue
                console.print(f"\n[bold cyan]── {h.name} (last 5 log lines) ──[/]")
                # markup=False because ansible's prettier callback wraps
                # task names in `[role : Task description]` which Rich
                # would otherwise eat as malformed markup tags (silently
                # dropping the bracketed text). highlight=False stops
                # Rich auto-colouring numeric values like (1.3s).
                console.print(tail.rstrip(), markup=False, highlight=False)

        if any_running:
            console.print(
                "\n[dim]Reattach a live tail with: "
                "[bold]fleet tail HOST[/] · "
                "force-stop with: [bold]fleet kill --hosts HOST[/][/]"
            )
        return any_running

    iteration = 0
    try:
        while True:
            iteration += 1
            results = asyncio.run(_orchestrate())
            still_running = _render(results, iteration)
            if watch <= 0 or not still_running:
                if watch > 0 and iteration > 1:
                    console.print(
                        f"\n[green]✓[/] watch: all hosts settled after "
                        f"{iteration} polls"
                    )
                return 0
            console.print(
                f"\n[dim]watch: re-polling in {watch}s (Ctrl+C to stop)[/]"
            )
            time.sleep(watch)
    except KeyboardInterrupt:
        console.print("\n[yellow]watch: interrupted by user[/]")
        return 130


# ---------------------------------------------------------------------------
# Readiness probe (--readiness / `just fleet-status`)
# ---------------------------------------------------------------------------
#
# Predicts what `just fleet-apply` would do on each host WITHOUT changing
# anything. fleet-apply defaults to `chezmoi update --init`, which is three
# things in sequence:
#
#   1. `git -C <source> pull`     — bring in new template commits
#   2. `chezmoi init`             — re-render ~/.config/chezmoi/chezmoi.toml
#                                    (re-evaluates promptBoolOnce / ...; NEW
#                                    keys without saved answers cause the
#                                    "could not open a new TTY" failure
#                                    non-interactively — the `david_ubuntu`
#                                    failure mode in the motivating bug)
#   3. `chezmoi apply`            — render templates, run run_* scripts
#
# The readiness probe inspects each host once over SSH and emits a per-host
# classification covering all three failure surfaces above PLUS the busy-host
# overlap with --status. Cheaper than --dry-run (which runs full chezmoi
# diff) and more actionable than --status (which only sees live processes,
# not pending drift / missing init / new prompt keys).


def _build_readiness_probe_cmd(no_fetch: bool) -> str:
    """Construct the per-host readiness probe shell snippet.

    Emits KEY=VALUE lines, then a DRIFT_BEGIN ... DRIFT_END block with
    `chezmoi status` output. Format is parsed by _parse_readiness_stdout;
    keep it stable. The snippet is non-fatal at every step (early
    `printf STATE=... + exit 0` for blocking states) so partial answers
    reach the orchestrator even when later steps would fail.
    Classification is done in Python (_classify_readiness), not in shell.
    """
    fetch = (
        ":"
        if no_fetch
        else 'git -C "$_src" fetch --quiet origin 2>/dev/null || true'
    )
    return (
        # Same PATH augmentation as build_remote_command so non-interactive
        # SSH shells (which don't source ~/.zshrc) find chezmoi installed
        # in any of the standard prefixes.
        'export PATH="$HOME/.local/bin:$HOME/bin:'
        '/home/linuxbrew/.linuxbrew/bin:/opt/homebrew/bin:'
        '/usr/local/bin:/snap/bin:$PATH"; '
        # 1) chezmoi binary present?
        '_cz=$(command -v chezmoi 2>/dev/null); '
        'if [ -z "$_cz" ]; then '
        '  printf "STATE=no-chezmoi\\n"; exit 0; '
        'fi; '
        'printf "CHEZMOI_BIN=%s\\n" "$_cz"; '
        # 2) chezmoi init done? Look for the on-disk config that `chezmoi
        #    init` writes. Honour XDG_CONFIG_HOME for parity with chezmoi.
        #    NB: we can't use `chezmoi dump-config` here because it
        #    re-evaluates the template — exactly the thing we are trying
        #    to detect missing prompts in.
        '_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/chezmoi/chezmoi.toml"; '
        'if [ ! -f "$_cfg" ]; then '
        '  printf "INIT=no\\nSTATE=not-init\\n"; exit 0; '
        'fi; '
        'printf "INIT=yes\\n"; '
        # 3) Source path + git state. `chezmoi source-path` (no args) prints
        #    the source directory; works regardless of where chezmoi was
        #    installed.
        '_src=$("$_cz" --no-pager source-path 2>/dev/null); '
        'if [ -z "$_src" ] || [ ! -d "$_src/.git" ]; then '
        # Before declaring permanent `no-source`, check whether a chezmoi
        # apply/update/init is *actively* running on this host. If yes, the
        # source dir absence is transient (mid-clone, mid-init, or paused at
        # an interactive prompt in another SSH session) and the host is
        # really `init-in-progress`, not `no-source`. Same self-exclusion
        # strategy as the main busy probe below.
        '  _self_pid=$$; '
        '  _parent_pid=$(ps -o ppid= -p $$ 2>/dev/null | tr -d " "); '
        '  _busy_pids=$(pgrep -u "$(id -un)" -lf "chezmoi|ansible-playbook" 2>/dev/null '
        '    | awk -v self="$_self_pid" -v parent="$_parent_pid" '
        '          \'{ pid=$1; if (pid==self || pid==parent) next; '
        '             $1=""; sub(/^ /, ""); '
        '             if ($0 ~ /ansible-playbook/) { print pid; next } '
        '             if ($0 ~ /chezmoi/ && ($0 ~ / update/ || $0 ~ / apply/ || $0 ~ / init/)) { print pid } }\' '
        '    | paste -sd, - || true); '
        '  if [ -n "$_busy_pids" ]; then '
        '    printf "STATE=init-in-progress\\nBUSY_PIDS=%s\\nSOURCE_PATH=%s\\n" "$_busy_pids" "${_src:-}"; exit 0; '
        '  fi; '
        '  printf "STATE=no-source\\nSOURCE_PATH=%s\\n" "${_src:-}"; exit 0; '
        'fi; '
        'printf "SOURCE_PATH=%s\\n" "$_src"; '
        # Fetch (or skip per --no-fetch) so behind/ahead counts are honest.
        f'{fetch}; '
        '_local_sha=$(git -C "$_src" rev-parse HEAD 2>/dev/null || echo ""); '
        '_remote_sha=$(git -C "$_src" rev-parse @{u} 2>/dev/null || echo ""); '
        '_behind=$(git -C "$_src" rev-list --count HEAD..@{u} 2>/dev/null || echo 0); '
        '_ahead=$(git -C "$_src" rev-list --count @{u}..HEAD 2>/dev/null || echo 0); '
        '_dirty=$(git -C "$_src" status --porcelain 2>/dev/null | wc -l | tr -d " "); '
        '_branch=$(git -C "$_src" rev-parse --abbrev-ref HEAD 2>/dev/null || echo ""); '
        'printf "LOCAL_SHA=%s\\nREMOTE_SHA=%s\\nBEHIND=%s\\nAHEAD=%s\\nDIRTY=%s\\nBRANCH=%s\\n" '
        '  "$_local_sha" "$_remote_sha" "$_behind" "$_ahead" "$_dirty" "$_branch"; '
        # 4) Extract top-level keys from the on-disk chezmoi.toml (under
        #    [data]). Comma-joined; orchestrator compares against the set
        #    of prompt keys grepped from the local .chezmoi.toml.tmpl and
        #    warns about any missing ones (the david_ubuntu failure mode).
        '_keys=$(awk -F"=" '
        '\'/^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/ '
        '{ gsub(/[[:space:]]/, "", $1); print $1 }\' '
        '"$_cfg" | sort -u | paste -sd, -); '
        'printf "TOML_KEYS=%s\\n" "$_keys"; '
        # 5) Busy probe — same self-exclusion strategy as _STATUS_PROBE_CMD.
        '_self_pid=$$; '
        '_parent_pid=$(ps -o ppid= -p $$ 2>/dev/null | tr -d " "); '
        '_pids=$(pgrep -u "$(id -un)" -lf "chezmoi|ansible-playbook" 2>/dev/null '
        '  | awk -v self="$_self_pid" -v parent="$_parent_pid" '
        '\'{ pid=$1; if (pid==self || pid==parent) next; '
        '   $1=""; sub(/^ /, ""); '
        '   if ($0 ~ /ansible-playbook/) { print pid; next } '
        '   if ($0 ~ /chezmoi/ && ($0 ~ / update/ || $0 ~ / apply/ || $0 ~ / init/)) { print pid } }\' '
        '  | paste -sd, - || true); '
        'printf "BUSY_PIDS=%s\\n" "${_pids:-}"; '
        # 6) chezmoi status — drift detection. Empty output = clean.
        #    Cap at 50 lines to bound transcript size (a host with hundreds
        #    of drifted files is broken in a different way; ssh in instead).
        'printf "DRIFT_BEGIN\\n"; '
        'PAGER=cat GIT_PAGER=cat "$_cz" --no-pager status 2>/dev/null | head -50 || true; '
        'printf "DRIFT_END\\n"'
    )


def _parse_readiness_stdout(stdout: str) -> tuple[dict[str, str], list[str]]:
    """Split the probe output into (KEY=VAL fields, drift lines)."""
    fields: dict[str, str] = {}
    drift: list[str] = []
    in_drift = False
    for line in stdout.splitlines():
        if line == "DRIFT_BEGIN":
            in_drift = True
            continue
        if line == "DRIFT_END":
            in_drift = False
            continue
        if in_drift:
            if line.strip():
                drift.append(line)
        elif "=" in line:
            k, _, v = line.partition("=")
            fields[k] = v
    return fields, drift


# Regex matching a chezmoi prompt call in .chezmoi.toml.tmpl. Captures the
# prompt KEY (second positional argument). Covers:
#   promptBool / promptBoolOnce
#   promptString / promptStringOnce
#   promptInt / promptIntOnce
#   promptChoice / promptChoiceOnce
# Pattern: `promptXxxOnce . "key"` — `.` is the chezmoi root context.
_PROMPT_KEY_RE = re.compile(
    r'prompt(?:Bool|String|Int|Choice)(?:Once)?\s+\.\s+"([^"]+)"'
)


def _extract_expected_prompt_keys(repo_root: Path) -> set[str]:
    """Return the set of prompt-key names declared in .chezmoi.toml.tmpl.

    Used to detect the david_ubuntu failure mode: a NEW promptBoolOnce was
    added to the template but the remote's saved chezmoi.toml predates it,
    so a `chezmoi update --init` would re-prompt non-interactively and
    crash. Best-effort: returns an empty set if the file isn't found
    (falls back to "we can't tell" — readiness check skips toml-mismatch).
    """
    tmpl = repo_root / ".chezmoi.toml.tmpl"
    if not tmpl.exists():
        return set()
    try:
        text = tmpl.read_text(errors="replace")
    except OSError:
        return set()
    return set(_PROMPT_KEY_RE.findall(text))


def _classify_readiness(
    fields: dict[str, str],
    drift: list[str],
    expected_keys: set[str],
) -> tuple[str, list[str]]:
    """Map probe fields → (primary state, list of secondary notes).

    Priority order (most actionable first):
      unreachable > no-chezmoi > not-init > init-in-progress > no-source
        > toml-mismatch > busy > dirty > drift > behind > ahead
        > ready-to-update > up-to-date

    `init-in-progress` outranks `no-source` because the former is a
    transient state (chezmoi is mid-clone or paused at an interactive
    prompt) while the latter is a permanent failure that needs human
    intervention. The probe's SSH script promotes `no-source` ⇒
    `init-in-progress` if it sees an active chezmoi update/apply/init
    PID; we just trust that signal here.

    Secondary notes carry context the primary state hides (e.g. a
    `behind` host with drift will show "drift: 2 files" in notes).
    """
    notes: list[str] = []

    # Hard blockers (early exit from probe → only STATE field set).
    state = fields.get("STATE", "")
    if state in {"no-chezmoi", "not-init", "no-source"}:
        return state, notes
    if state == "init-in-progress":
        busy_pids = fields.get("BUSY_PIDS") or ""
        if busy_pids:
            notes.append(f"pids={busy_pids}")
        return state, notes

    # toml-mismatch: prompt keys present in template but missing on remote.
    if expected_keys:
        remote_keys = set(
            k for k in (fields.get("TOML_KEYS") or "").split(",") if k
        )
        missing = expected_keys - remote_keys
        if missing:
            preview = ", ".join(sorted(missing)[:3])
            extra = (
                ""
                if len(missing) <= 3
                else f" (+{len(missing) - 3} more)"
            )
            notes.append(f"missing prompt keys: {preview}{extra}")
            return "toml-mismatch", notes

    busy_pids = fields.get("BUSY_PIDS") or ""
    if busy_pids:
        if busy_pids == "chezmoi-state-locked":
            notes.append("chezmoi state lock held (parallel run in progress)")
        else:
            notes.append(f"pids={busy_pids}")
        return "busy", notes

    behind = int(fields.get("BEHIND") or 0)
    ahead = int(fields.get("AHEAD") or 0)
    dirty = int(fields.get("DIRTY") or 0)
    drift_count = len(drift)

    # Build secondary notes regardless of primary state.
    branch = fields.get("BRANCH") or ""
    if branch and branch not in {"main", "master"}:
        notes.append(f"branch={branch}")
    if behind:
        notes.append(f"behind: {behind} commit{'s' if behind != 1 else ''}")
    if ahead:
        notes.append(f"ahead: {ahead} commit{'s' if ahead != 1 else ''}")
    if dirty:
        notes.append(f"dirty: {dirty} file{'s' if dirty != 1 else ''}")
    if drift_count:
        # First drift entry as preview; chezmoi status format is
        # "MM <relpath>" (two status chars + path) so strip the prefix.
        first = drift[0]
        first_path = first[3:] if len(first) > 3 and first[2] == " " else first
        more = (
            ""
            if drift_count == 1
            else f" (+{drift_count - 1} more)"
        )
        notes.append(f"drift: {first_path}{more}")

    # Primary classification.
    if dirty:
        return "dirty", notes
    if ahead and not behind:
        return "ahead", notes
    if drift_count:
        # Drift without git changes = remote target was hand-edited.
        # Counts as actionable (would block apply without --force) but
        # apply itself would proceed past it with --keep-going (default).
        return "drift", notes
    if behind:
        return "ready-to-update", notes
    return "up-to-date", notes


def _probe_readiness_local(no_fetch: bool) -> tuple[dict[str, str], list[str]]:
    """Local-host equivalent of the SSH readiness probe.

    Mirrors _build_readiness_probe_cmd but uses Python subprocess + Path
    APIs directly. Skips the busy probe filter for self-process / parent
    (mirrors _probe_local). Returns the same (fields, drift_lines) shape.
    """
    fields: dict[str, str] = {}
    drift: list[str] = []

    # 1) chezmoi binary
    cz = subprocess.run(
        ["command", "-v", "chezmoi"],
        capture_output=True, text=True, check=False,
    ).stdout.strip() if False else None
    # `command -v` is a shell builtin, not an executable — use shutil.which.
    import shutil
    cz_path = shutil.which("chezmoi")
    if not cz_path:
        fields["STATE"] = "no-chezmoi"
        return fields, drift
    fields["CHEZMOI_BIN"] = cz_path

    # 2) chezmoi.toml present?
    cfg = Path(
        os.environ.get("XDG_CONFIG_HOME") or (Path.home() / ".config")
    ) / "chezmoi" / "chezmoi.toml"
    if not cfg.exists():
        fields["INIT"] = "no"
        fields["STATE"] = "not-init"
        return fields, drift
    fields["INIT"] = "yes"

    # 3) Source path + git state
    src = ""
    locked = False
    try:
        r = subprocess.run(
            [cz_path, "--no-pager", "source-path"],
            capture_output=True, text=True, check=False, timeout=10,
        )
        src = r.stdout.strip()
        # chezmoi may be holding the persistent-state lock from a parallel
        # fleet-apply / chezmoi run. The error goes to stderr and stdout
        # is empty. Detect & fall back to $PWD (when run from inside the
        # source dir via `just`) so the rest of the probe still works.
        if not src and "persistent state lock" in (r.stderr or ""):
            locked = True
            cwd_top = subprocess.run(
                ["git", "-C", str(Path.cwd()), "rev-parse", "--show-toplevel"],
                capture_output=True, text=True, check=False, timeout=5,
            ).stdout.strip()
            if cwd_top and (Path(cwd_top) / ".chezmoiroot").exists() or (
                cwd_top and (Path(cwd_top) / ".chezmoi.toml.tmpl").exists()
            ):
                src = cwd_top
    except (subprocess.TimeoutExpired, OSError):
        src = ""
    if not src or not (Path(src) / ".git").is_dir():
        fields["STATE"] = "no-source"
        fields["SOURCE_PATH"] = src
        if locked:
            # Surface the real cause so the user doesn't chase a phantom
            # "no source" diagnosis. Promote to its own state for clarity.
            fields["STATE"] = "busy"
            fields["BUSY_PIDS"] = "chezmoi-state-locked"
        else:
            # Source missing AND no state lock — could still be transient
            # if a chezmoi update/apply/init is mid-clone. Promote to
            # init-in-progress in that case (mirrors the SSH probe's
            # logic). See pitfall: david_ubuntu was running
            # `chezmoi update --init` paused at an interactive prompt.
            try:
                r = subprocess.run(
                    ["pgrep", "-u", str(os.getuid()), "-lf",
                     "chezmoi|ansible-playbook"],
                    capture_output=True, text=True, check=False, timeout=5,
                )
                own = {os.getpid(), os.getppid()}
                in_progress: list[str] = []
                for line in r.stdout.splitlines():
                    parts = line.split(None, 1)
                    if len(parts) != 2:
                        continue
                    try:
                        pid_i = int(parts[0])
                    except ValueError:
                        continue
                    if pid_i in own:
                        continue
                    cmd = parts[1]
                    if "chezmoi" in cmd and (
                        " update" in cmd or " apply" in cmd or " init" in cmd
                    ):
                        in_progress.append(parts[0])
                if in_progress:
                    fields["STATE"] = "init-in-progress"
                    fields["BUSY_PIDS"] = ",".join(in_progress)
            except (FileNotFoundError, subprocess.TimeoutExpired):
                pass
        return fields, drift
    fields["SOURCE_PATH"] = src
    if locked:
        # We recovered via $PWD fallback, but still flag that chezmoi
        # itself is locked — `chezmoi status` below will fail too.
        fields["CHEZMOI_LOCKED"] = "1"

    def _git(*args: str, default: str = "") -> str:
        try:
            r = subprocess.run(
                ["git", "-C", src, *args],
                capture_output=True, text=True, check=False, timeout=15,
            )
            return r.stdout.strip() or default
        except (subprocess.TimeoutExpired, OSError):
            return default

    if not no_fetch:
        # Best-effort fetch; ignore failures (offline, auth, etc.).
        _git("fetch", "--quiet", "origin")

    fields["LOCAL_SHA"] = _git("rev-parse", "HEAD")
    fields["REMOTE_SHA"] = _git("rev-parse", "@{u}")
    fields["BEHIND"] = _git("rev-list", "--count", "HEAD..@{u}", default="0")
    fields["AHEAD"] = _git("rev-list", "--count", "@{u}..HEAD", default="0")
    dirty_out = _git("status", "--porcelain")
    fields["DIRTY"] = str(len([l for l in dirty_out.splitlines() if l.strip()]))
    fields["BRANCH"] = _git("rev-parse", "--abbrev-ref", "HEAD")

    # 4) Top-level keys in chezmoi.toml
    keys: list[str] = []
    try:
        for raw in cfg.read_text(errors="replace").splitlines():
            stripped = raw.lstrip()
            if not stripped or stripped.startswith("#") or stripped.startswith("["):
                continue
            head, sep, _ = stripped.partition("=")
            if sep and head.strip().replace("_", "").isalnum():
                keys.append(head.strip())
    except OSError:
        pass
    fields["TOML_KEYS"] = ",".join(sorted(set(keys)))

    # 5) Busy probe (reuse _probe_local's pgrep logic, sans log probe)
    pid_list: list[str] = []
    try:
        result = subprocess.run(
            ["pgrep", "-u", str(os.getuid()), "-lf",
             "chezmoi|ansible-playbook"],
            capture_output=True, text=True, check=False,
        )
        own = {os.getpid(), os.getppid()}
        for line in result.stdout.splitlines():
            parts = line.split(None, 1)
            if len(parts) != 2:
                continue
            pid_s, cmd = parts
            try:
                pid_i = int(pid_s)
            except ValueError:
                continue
            if pid_i in own:
                continue
            if "ansible-playbook" in cmd:
                pid_list.append(pid_s)
            elif "chezmoi" in cmd and (
                " update" in cmd or " apply" in cmd or " init" in cmd
            ):
                pid_list.append(pid_s)
    except FileNotFoundError:
        pass
    fields["BUSY_PIDS"] = ",".join(pid_list)

    # 6) chezmoi status (drift) — skip if state lock is held (would just
    #    timeout uselessly; the lock state itself already tells the user
    #    something is in progress).
    if not fields.get("CHEZMOI_LOCKED"):
        try:
            r = subprocess.run(
                [cz_path, "--no-pager", "status"],
                capture_output=True, text=True, check=False, timeout=30,
                env={**os.environ, "PAGER": "cat", "GIT_PAGER": "cat"},
            )
            for line in r.stdout.splitlines()[:50]:
                if line.strip():
                    drift.append(line)
        except (subprocess.TimeoutExpired, OSError):
            pass

    return fields, drift


# Style + symbol per readiness state. Symbol is shown in the host column
# of the table (so the eye can scan a long fleet quickly), full state name
# in its own column.
_READINESS_STYLE: dict[str, tuple[str, str]] = {
    "up-to-date":      ("✓", "green"),
    "ready-to-update": ("↻", "blue"),
    "behind":          ("→", "cyan"),
    "ahead":           ("?", "magenta"),
    "drift":           ("⚠", "yellow"),
    "dirty":           ("⚠", "yellow"),
    "busy":            ("⏳", "yellow"),
    "init-in-progress":("⏳", "yellow"),
    "toml-mismatch":   ("!", "yellow bold"),
    "not-init":        ("✗", "red"),
    "no-source":       ("✗", "red"),
    "no-chezmoi":      ("✗", "red"),
    "unreachable":     ("✗", "red"),
}


# Per-state recovery hint for the footer. None means "no action needed".
_READINESS_HINT: dict[str, str] = {
    "no-chezmoi":    "ssh in & install chezmoi (curl https://chezmoi.io/get | sh) — see README Quick Setup",
    "not-init":      "ssh in & run `chezmoi init` interactively (one-off; needs TTY for prompts)",
    "no-source":     "ssh in: chezmoi source dir missing or not a git repo — re-init may be needed",
    "toml-mismatch": "ssh in & re-run `chezmoi init` to answer the new prompts (their default values are usually fine)",
    "drift":         "`fleet chezmoi apply --hosts HOST --force` (overwrite) OR migrate to a *.local override",
    "dirty":         "ssh in & commit/stash uncommitted changes in the source dir before applying",
    "ahead":         "ssh in: source dir has unpushed local commits — `git push` or reset before applying",
    "busy":          "wait for the running run, OR `fleet chezmoi status --live --hosts HOST` for live state",
    "init-in-progress": "chezmoi is initializing the source dir (or paused at an interactive prompt in another SSH session) — wait or `ssh HOST` to check",
    "behind":        "`fleet chezmoi apply --hosts HOST` (or whole fleet)",
    "ready-to-update": "`fleet chezmoi apply --hosts HOST` (or whole fleet)",
    "unreachable":   "check ssh_alias / network / sudo / 1Password agent",
    "up-to-date":    "",
}


def _run_preflight(
    console: Console,
    selected: list[Host],
    connect_timeout: int,
) -> int:
    """Pre-flight readiness probe for `fleet-apply` — warn on init-in-progress.

    Runs the readiness probe (no-fetch for speed; we only care about
    transient mid-flight state, not behind/ahead counts) and warns with a
    5s countdown if any selected host is in `init-in-progress` state.
    Always returns 0 (warn-don't-refuse) — the countdown auto-continues
    so scripted/CI use is unaffected. User can Ctrl+C during the
    countdown to abort.

    Probe failures (unreachable / SSH error) are surfaced as a single
    dim line but do NOT block apply — fleet-apply itself will report
    those hosts as failed via its normal error path.
    """
    try:
        rows = _collect_readiness_rows(
            selected, connect_timeout, no_fetch=True,
        )
    except Exception as e:  # noqa: BLE001
        # Probe infrastructure failure (e.g. cwd not a chezmoi source dir).
        # Don't block apply — print a dim warning and continue.
        console.print(
            f"[dim]preflight: probe failed ({type(e).__name__}: {e}); "
            f"continuing without check[/]"
        )
        return 0

    busy_rows = [r for r in rows if r["state"] == "init-in-progress"]
    if not busy_rows:
        return 0

    console.print(
        f"[bold yellow]⏳ preflight:[/] "
        f"{len(busy_rows)} host(s) in [yellow]init-in-progress[/] state"
    )
    for r in busy_rows:
        pids = r["fields"].get("BUSY_PIDS") or "?"
        console.print(
            f"  [yellow]·[/] [bold]{r['host']}[/] — "
            f"chezmoi update/apply/init running (pid {pids}); "
            f"may be paused at an interactive prompt in another SSH session"
        )
    console.print(
        "[dim]hint:[/] `ssh HOST` to check, "
        "or `fleet chezmoi apply --no-preflight` to skip this check.\n"
        "[dim]continuing in 5s — Ctrl+C to abort[/]"
    )

    # 5s countdown with single-line update (Rich Live would be overkill
    # here; rewrite the same line via \r-style print).
    import time
    try:
        for remaining in (5, 4, 3, 2, 1):
            console.print(
                f"[dim]  starting fleet-apply in {remaining}s...[/]",
                end="\r",
            )
            time.sleep(1)
        console.print(" " * 60, end="\r")  # clear countdown line
    except KeyboardInterrupt:
        console.print("\n[red]aborted by user[/]")
        return 130
    return 0


def _collect_readiness_rows(
    selected: list[Host], connect_timeout: int, no_fetch: bool,
) -> list[dict]:
    """Run the readiness probe over `selected` and return classified rows.

    Shared between `_run_readiness` (`just fleet-status`) and the
    `_run_apply` pre-flight hook. Each row dict has keys:
      host, state, notes, fields, drift, error
    See `_classify_readiness` for the state vocabulary.
    """
    expected_keys = _extract_expected_prompt_keys(Path.cwd())
    probe_cmd = _build_readiness_probe_cmd(no_fetch)
    # stderr console for the spinner so stdout (machine-readable --json /
    # piped output) stays uncontaminated. Matches scripts/fleet/{tmux,
    # pueue,exec}.py's pattern.
    err = Console(stderr=True)

    async def _probe_one(h: Host) -> dict:
        row: dict = {
            "host": h.name,
            "state": "unreachable",
            "notes": [],
            "fields": {},
            "drift": [],
            "error": None,
        }
        if h.local:
            try:
                fields, drift = _probe_readiness_local(no_fetch)
            except Exception as e:  # noqa: BLE001
                row["error"] = f"{type(e).__name__}: {e}"
                return row
            row["fields"] = fields
            row["drift"] = drift
            state, notes = _classify_readiness(fields, drift, expected_keys)
            row["state"] = state
            row["notes"] = notes
            return row
        try:
            async with asyncio.timeout(connect_timeout):
                conn = await asyncssh.connect(**_connect_kwargs(h))
            async with conn:
                result = await conn.run(probe_cmd, check=False)
            stdout = result.stdout or ""
        except (asyncssh.Error, OSError, TimeoutError) as e:
            row["error"] = f"{type(e).__name__}: {e}"
            return row
        fields, drift = _parse_readiness_stdout(stdout)
        row["fields"] = fields
        row["drift"] = drift
        state, notes = _classify_readiness(fields, drift, expected_keys)
        row["state"] = state
        row["notes"] = notes
        return row

    total = len(selected)
    done_count = 0

    async def _bounded(h: Host) -> dict:
        nonlocal done_count
        try:
            return await _probe_one(h)
        finally:
            done_count += 1

    async def _orchestrate(status: object | None) -> list[dict]:
        async def _ticker() -> None:
            while True:
                if status is not None:
                    status.update(f"probing readiness on {done_count}/{total} hosts...")
                await asyncio.sleep(0.1)
        tick = asyncio.create_task(_ticker()) if status is not None else None
        try:
            return await asyncio.gather(*(_bounded(h) for h in selected))
        finally:
            if tick is not None:
                tick.cancel()

    async def _run_with_status() -> list[dict]:
        if err.is_terminal:
            with err.status(f"probing readiness on {total} hosts...", spinner="dots") as status:
                return await _orchestrate(status)
        return await _orchestrate(None)

    return asyncio.run(_run_with_status())


def _run_readiness(
    console: Console,
    selected: list[Host],
    connect_timeout: int,
    no_fetch: bool,
    json_out: bool,
) -> int:
    """Probe each host's readiness; render table + actionable hints.

    Always returns 0 (probe is informational, not a verdict — matches
    --status / --compact). Use --json for machine-readable output suitable
    for `jq` / scripting / pre-apply gates in CI.

    Note: fleet-apply defaults to `chezmoi update --init` (= git pull +
    re-render chezmoi.toml + apply). The probe predicts ALL three
    sub-steps' failure modes:
      * pull:  behind / ahead / dirty
      * init:  toml-mismatch (NEW prompt keys not yet answered)
      * apply: drift (target hand-edited on remote)
    """
    rows = _collect_readiness_rows(selected, connect_timeout, no_fetch)

    if json_out:
        import json
        # Drop verbose `fields` dict from JSON to keep it readable; expose
        # the classification + key counts. Callers wanting raw fields can
        # parse the probe output themselves.
        slim = []
        for r in rows:
            slim.append({
                "host": r["host"],
                "state": r["state"],
                "notes": r["notes"],
                "behind": int(r["fields"].get("BEHIND") or 0),
                "ahead": int(r["fields"].get("AHEAD") or 0),
                "dirty": int(r["fields"].get("DIRTY") or 0),
                "drift_count": len(r["drift"]),
                "branch": r["fields"].get("BRANCH") or "",
                "local_sha": (r["fields"].get("LOCAL_SHA") or "")[:7],
                "remote_sha": (r["fields"].get("REMOTE_SHA") or "")[:7],
                "busy_pids": r["fields"].get("BUSY_PIDS") or "",
                "error": r["error"],
            })
        print(json.dumps(slim, indent=2))
        return 0

    console.print(
        f"[bold]fleet-status[/] — readiness probe across "
        f"{len(selected)} host(s)"
        + (" [dim](no fetch)[/]" if no_fetch else "")
    )
    table = Table(title="readiness probe", expand=True, show_lines=False)
    table.add_column("host", style="bold")
    table.add_column("state")
    table.add_column("notes", overflow="fold")

    # Group hosts by state for the hints section.
    by_state: dict[str, list[str]] = {}
    for row in rows:
        symbol, color = _READINESS_STYLE.get(
            row["state"], ("?", "white")
        )
        # Compose notes; for unreachable show the error.
        notes_str = ", ".join(row["notes"]) if row["notes"] else ""
        if row["error"] and not notes_str:
            notes_str = row["error"]
        elif row["error"]:
            notes_str = f"{notes_str}; {row['error']}"
        table.add_row(
            row["host"],
            f"[{color}]{symbol} {row['state']}[/]",
            notes_str,
        )
        by_state.setdefault(row["state"], []).append(row["host"])

    console.print(table)

    # Hints footer — one bullet per non-green state, listing affected hosts
    # and the recovery command. Suppressed when everything is up-to-date.
    actionable = {
        s: hosts
        for s, hosts in by_state.items()
        if s != "up-to-date" and _READINESS_HINT.get(s)
    }
    if actionable:
        console.print("\n[bold]Hints:[/]")
        # Stable order: most-blocking states first.
        priority = [
            "unreachable", "no-chezmoi", "not-init", "init-in-progress",
            "no-source", "toml-mismatch", "busy", "dirty", "ahead", "drift",
            "behind", "ready-to-update",
        ]
        for state in priority:
            hosts_for_state = actionable.get(state)
            if not hosts_for_state:
                continue
            symbol, color = _READINESS_STYLE.get(state, ("?", "white"))
            host_list = ", ".join(hosts_for_state)
            hint = _READINESS_HINT[state]
            console.print(
                f"  [{color}]{symbol}[/] [{color}]{state}[/] "
                f"({len(hosts_for_state)}: {host_list})"
            )
            console.print(f"      → {hint}")

    # Summary line: how many can fleet-apply right now without surprise?
    ready_states = {"up-to-date", "behind", "ready-to-update"}
    ready_count = sum(
        1 for r in rows if r["state"] in ready_states
    )
    blocked_count = len(rows) - ready_count
    console.print(
        f"\n[dim]Summary: {ready_count}/{len(rows)} hosts ready for "
        f"`fleet chezmoi apply`"
        + (f", {blocked_count} need attention" if blocked_count else "")
        + "[/]"
    )
    return 0



    """Extract a one-row summary from a fleet-apply log.

    Greps for the patterns the chezmoi run_* scripts + ansible
    `pretty_compact` callback emit. Pure parsing — no I/O. Returns
    a dict suitable for rendering as a Rich table row.

    Patterns matched:
      - `[N] TASK · [role : task name]` → final task number reached
      - `PLAY RECAP  (Xm Ys)` → total ansible runtime (last occurrence wins)
      - `Slow tasks (>5s):` block followed by `  ⏱ ... (Xs)` lines
      - `chezmoi: <script>: exit status N` → which run_* failed
    """
    last_task_num = 0
    last_task_name = ""
    play_recap_runtime = ""
    slow_tasks: list[str] = []
    failed_script = ""

    in_slow = False
    for line in log_text.splitlines():
        # Task counter — `[N] TASK · [role : description]`
        m = re.match(r"^\[(\d+)\] TASK · (.+)$", line)
        if m:
            last_task_num = int(m.group(1))
            last_task_name = m.group(2).strip().lstrip("[").rstrip("]")
            in_slow = False
            continue

        # PLAY RECAP timing — `PLAY RECAP  (1m7s)` or `(45s)` etc.
        m = re.match(r"^PLAY RECAP\s+\(([^)]+)\)", line)
        if m:
            play_recap_runtime = m.group(1)
            in_slow = False
            continue

        # Slow tasks block opens
        if line.startswith("Slow tasks"):
            in_slow = True
            continue
        # Slow task entry — `  ⏱ task name (1m6s)`
        if in_slow:
            m = re.match(r"^\s*⏱\s+(.+?)\s+\(([^)]+)\)\s*$", line)
            if m:
                slow_tasks.append(f"{m.group(2)} {m.group(1)}")
                continue
            # Blank or non-matching line ends the slow-task block
            if line.strip() == "" or not line.startswith(" "):
                in_slow = False

        # `chezmoi: 20_ansible_roles.sh: exit status 2`
        m = re.match(r"^chezmoi: (\S+):\s*exit status\s+(\d+)", line)
        if m:
            failed_script = f"{m.group(1)} (rc={m.group(2)})"

    return {
        "last_task_num": last_task_num,
        "last_task_name": last_task_name,
        "play_recap_runtime": play_recap_runtime,
        "slow_tasks": slow_tasks[:5],
        "failed_script": failed_script,
    }


def _run_compact(
    console: Console, selected: list[Host], run_id: str, connect_timeout: int
) -> int:
    """Post-mortem compact summary: pull log+sentinel from each host, parse, render.

    Per-host workflow:
      1. SSH-fetch the requested run's `.log` and `.exit` from
         `~/.cache/chezmoi-fleet/logs/`. Empty `run_id` = `ls -t | head -1`
         on the remote so each host picks its own latest independently.
      2. Parse with `_parse_compact_log`.
      3. Render row in a Rich table.

    Local hosts read from `LOCAL_LOG_DIR` directly without SSH.
    Returns 0 always (read-only diagnostic).
    """
    if run_id:
        # Same run on every host — single-line summary header
        console.print(
            f"[bold]fleet-apply --compact[/] for run [cyan]{run_id}[/] "
            f"on {len(selected)} host(s)"
        )
    else:
        console.print(
            f"[bold]fleet-apply --compact[/] (latest run per host) "
            f"on {len(selected)} host(s)"
        )

    # Bash snippet: pick run, dump LOG/EXIT/RUN_ID via printf delimiters so
    # we can parse a single SSH stream per host. Empty run_id → latest.
    def _fetch_cmd(rid: str) -> str:
        if rid:
            picker = f'_run_id="{rid}"; _log="$_dir/$_run_id.log"'
        else:
            picker = (
                "_log=$(ls -t \"$_dir\"/*.log 2>/dev/null | head -1); "
                "_run_id=$(basename \"${_log:-}\" .log)"
            )
        return (
            "_dir=\"$HOME/.cache/chezmoi-fleet/logs\"; "
            f"{picker}; "
            "if [ -z \"$_run_id\" ] || [ ! -f \"$_log\" ]; then "
            "  printf 'RUN_ID=\\nMISSING=1\\n'; exit 0; fi; "
            "_exit=\"$_dir/$_run_id.exit\"; "
            "printf 'RUN_ID=%s\\n' \"$_run_id\"; "
            "printf 'EXIT=%s\\n' \"$([ -f \"$_exit\" ] && cat \"$_exit\" || echo '?')\"; "
            "printf '---LOG---\\n'; "
            "cat \"$_log\""
        )

    rows: list[dict] = []

    async def _fetch_one(h: Host) -> dict:
        row = {"host": h.name, "run_id": "", "exit": "?", "missing": False, "parsed": {}}
        if h.local:
            # Read locally
            if run_id:
                log_path = LOCAL_LOG_DIR / f"{run_id}.log"
                resolved_rid = run_id
            else:
                logs = sorted(LOCAL_LOG_DIR.glob("*.log"),
                              key=lambda p: p.stat().st_mtime, reverse=True)
                log_path = logs[0] if logs else None
                resolved_rid = log_path.stem if log_path else ""
            if not log_path or not log_path.exists():
                row["missing"] = True
                return row
            row["run_id"] = resolved_rid
            exit_path = LOCAL_LOG_DIR / f"{resolved_rid}.exit"
            row["exit"] = exit_path.read_text().strip() if exit_path.exists() else "?"
            row["parsed"] = _parse_compact_log(log_path.read_text(errors="replace"))
            return row

        try:
            async with asyncio.timeout(connect_timeout):
                conn = await asyncssh.connect(**_connect_kwargs(h))
            async with conn:
                result = await conn.run(_fetch_cmd(run_id), check=False)
            stdout = result.stdout or ""
            if "MISSING=1" in stdout.split("---LOG---", 1)[0]:
                row["missing"] = True
                # Still try to capture RUN_ID for reporting
                m = re.search(r"^RUN_ID=(.*)$", stdout, re.MULTILINE)
                if m:
                    row["run_id"] = m.group(1)
                return row
            head, _, log_text = stdout.partition("---LOG---\n")
            for ln in head.splitlines():
                if ln.startswith("RUN_ID="):
                    row["run_id"] = ln[7:]
                elif ln.startswith("EXIT="):
                    row["exit"] = ln[5:]
            row["parsed"] = _parse_compact_log(log_text)
            return row
        except (asyncssh.Error, OSError, TimeoutError) as e:
            row["missing"] = True
            row["error"] = str(e)
            return row

    async def _gather() -> None:
        results = await asyncio.gather(
            *(_fetch_one(h) for h in selected), return_exceptions=False
        )
        rows.extend(results)

    asyncio.run(_gather())

    # Render
    table = Table(title="fleet compact summary", show_lines=True)
    table.add_column("host", style="bold")
    table.add_column("run_id", style="dim")
    table.add_column("exit")
    table.add_column("last task")
    table.add_column("ansible runtime")
    table.add_column("slow tasks")
    table.add_column("failed script")

    for row in rows:
        if row["missing"]:
            err = row.get("error", "no log on remote")
            table.add_row(row["host"], row.get("run_id", "—") or "—",
                          "[dim]—[/]", f"[dim]{err}[/]", "—", "—", "—")
            continue
        p = row["parsed"]
        exit_color = "green" if row["exit"] == "0" else "red"
        last_task = (
            f"#{p['last_task_num']} {p['last_task_name'][:50]}"
            if p["last_task_num"] else "[dim](no ansible)[/]"
        )
        slow = "\n".join(p["slow_tasks"]) if p["slow_tasks"] else "[dim]none[/]"
        failed = (
            f"[red]{p['failed_script']}[/]" if p["failed_script"]
            else "[dim]—[/]"
        )
        table.add_row(
            row["host"], row["run_id"],
            f"[{exit_color}]{row['exit']}[/]",
            last_task,
            p["play_recap_runtime"] or "[dim]—[/]",
            slow, failed,
        )

    console.print(table)
    return 0


def _run_tail(
    console: Console, host: Host, run_id: str, connect_timeout: int
) -> int:
    """Stream the remote fleet-apply log for HOST until it ends or user Ctrl+Cs.

    The remote wrapper tees chezmoi's combined stdout/stderr into
    ~/.cache/chezmoi-fleet/logs/<run_id>.log AND drops a sentinel
    <run_id>.exit file containing the exit code when chezmoi finishes.
    We follow the log file with `tail -f` and stop when either:
      - The sentinel appears (clean finish, print exit code).
      - Local Ctrl+C (does NOT stop the remote — just our viewer).

    `run_id` empty means "the most recent log on the remote", resolved
    server-side by `ls -t … | head -1`.
    """
    if host.local:
        # Local: just `tail -F` the local cache file. Resolve `run_id` to
        # newest if empty. No SSH needed, no sentinel polling needed
        # (subprocess will exit when we Ctrl+C).
        if not run_id:
            try:
                logs = sorted(
                    LOCAL_LOG_DIR.glob("*.log"),
                    key=lambda p: p.stat().st_mtime,
                    reverse=True,
                )
                if not logs:
                    console.print(
                        f"[red]✗[/] no local fleet-apply log in {LOCAL_LOG_DIR}"
                    )
                    return 3
                run_id = logs[0].stem
            except OSError as e:
                console.print(f"[red]✗[/] read {LOCAL_LOG_DIR}: {e}")
                return 3
        log_file = LOCAL_LOG_DIR / f"{run_id}.log"
        exit_file = LOCAL_LOG_DIR / f"{run_id}.exit"
        if not log_file.exists():
            console.print(f"[red]✗[/] not found: {log_file}")
            return 3
        console.print(
            f"[dim]fleet-tail (local): following {log_file} "
            f"(Ctrl+C stops viewer; local run continues if active)[/]"
        )
        # Use plain `tail -F` and poll the sentinel from a sibling task.
        try:

            async def _local_follow() -> int:
                proc = await asyncio.create_subprocess_exec(
                    "tail", "-n", "+1", "-F", str(log_file),
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                )

                async def _drain(stream, is_err):
                    async for line in stream:
                        text = line.decode("utf-8", errors="replace").rstrip("\n")
                        # markup=False to avoid Rich eating ansible's
                        # `[role : task]` brackets as malformed tags.
                        # Use the `style=` kwarg for dim instead of inline
                        # `[dim]...[/]` markup which would be disabled.
                        console.print(
                            text,
                            markup=False,
                            highlight=False,
                            style="dim" if is_err else None,
                        )

                async def _watch_sentinel():
                    while True:
                        if exit_file.exists():
                            await asyncio.sleep(1)  # let tail flush
                            proc.terminate()
                            try:
                                rc = exit_file.read_text().strip()
                            except OSError:
                                rc = "?"
                            console.print(
                                f"\n[dim]fleet-tail: local run {run_id} "
                                f"finished, rc={rc}[/]"
                            )
                            return
                        await asyncio.sleep(2)

                await asyncio.gather(
                    _drain(proc.stdout, False),
                    _drain(proc.stderr, True),
                    _watch_sentinel(),
                    return_exceptions=True,
                )
                return 0

            return asyncio.run(_local_follow())
        except KeyboardInterrupt:
            console.print(
                "\n[yellow]fleet-tail: viewer interrupted; "
                "local run (if active) continues.[/]"
            )
            return 130

    # Resolve `run_id` on the remote so the user can pass `""` to mean
    # "newest". Then `tail -F` (follow + retry) on the picked log, and a
    # parallel poll loop watches for the .exit sentinel — when it appears
    # we print the exit code and break out, killing tail.
    remote_cmd = (
        "_dir=\"$HOME/.cache/chezmoi-fleet/logs\"; "
        f"_run={shlex.quote(run_id)}; "
        "if [ -z \"$_run\" ]; then "
        "  _run=$(ls -t \"$_dir\"/*.log 2>/dev/null | head -1 | xargs -I{} basename {} .log); "
        "fi; "
        "if [ -z \"$_run\" ] || [ ! -f \"$_dir/$_run.log\" ]; then "
        "  printf 'fleet-tail: no remote log found in %s\\n' \"$_dir\" >&2; "
        "  exit 3; "
        "fi; "
        "printf 'fleet-tail: following %s/%s.log (Ctrl+C stops viewer, NOT remote)\\n' "
        "  \"$_dir\" \"$_run\" >&2; "
        # `tail -F` on the log, in background; poll every 1s for the
        # sentinel file. When sentinel appears, print final rc and kill
        # tail. `--pid` would be cleaner but tail's --pid is GNU-only.
        "tail -n +1 -F \"$_dir/$_run.log\" & _tpid=$!; "
        "while :; do "
        "  if [ -f \"$_dir/$_run.exit\" ]; then "
        "    sleep 1; "  # let tail flush remaining output
        "    kill $_tpid 2>/dev/null; "
        "    printf '\\nfleet-tail: remote run %s finished, rc=%s\\n' "
        "      \"$_run\" \"$(cat \"$_dir/$_run.exit\" 2>/dev/null)\" >&2; "
        "    exit 0; "
        "  fi; "
        "  sleep 2; "
        "done"
    )

    async def _do_tail() -> int:
        try:
            async with asyncio.timeout(connect_timeout):
                conn = await asyncssh.connect(**_connect_kwargs(host))
        except (asyncssh.Error, OSError, TimeoutError) as e:
            console.print(f"[red]✗[/] connect {host.name}: {type(e).__name__}: {e}")
            return 1
        async with conn:
            try:
                proc = await conn.create_process(remote_cmd)
                # Stream stdout + stderr to local console.

                async def _drain(stream, is_err: bool) -> None:
                    async for line in stream:
                        text = line.rstrip("\n")
                        # See remote-tail _drain above for markup=False rationale
                        # (ansible `[role : task]` brackets get eaten by Rich).
                        console.print(
                            text,
                            markup=False,
                            highlight=False,
                            style="dim" if is_err else None,
                        )

                await asyncio.gather(
                    _drain(proc.stdout, False),
                    _drain(proc.stderr, True),
                )
                result = await proc.wait()
                return result.exit_status or 0
            except asyncio.CancelledError:
                console.print(
                    "\n[yellow]fleet-tail: viewer interrupted; "
                    "remote run continues. Re-attach with the same command.[/]"
                )
                return 130

    try:
        return asyncio.run(_do_tail())
    except KeyboardInterrupt:
        console.print(
            "\n[yellow]fleet-tail: viewer interrupted; "
            "remote run continues. Re-attach with the same command.[/]"
        )
        return 130


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
    keep_logs: int = 10,
    apply_path: str = "",
    branch: str = "",
    force_checkout: bool = False,
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
                keep_logs=keep_logs,
                apply_path=apply_path,
                branch=branch,
                force_checkout=force_checkout,
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
