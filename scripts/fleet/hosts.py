#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   # hosts.py itself only needs stdlib (tomllib, argparse, subprocess), but
#   # `from scripts.fleet import ...` transitively imports apply.py whose
#   # top-level `import asyncssh` / tyro / rich would otherwise fail under
#   # `uv run --script scripts/fleet/hosts.py` (the dispatcher in
#   # dot_dotfiles/bin/executable_fleet already pulls these in via its own
#   # PEP 723 header). Keep this list in sync with apply.py.
#   "asyncssh>=2.18",
#   "tyro>=0.9",
#   "rich>=13.9",
# ]
# ///
"""fleet hosts — pick a fleet-configured host, SSH into it.

Three entry points:

  fleet hosts                 Interactive picker via `tv fleet-hosts`. Falls
                              back to a numbered-stdin menu if `tv` is not on
                              PATH (e.g. headless CI).
  fleet hosts NAME            SSH directly into NAME (skip the picker). Uses
                              ssh_alias if set; otherwise constructs
                              `ssh -p PORT -i KEY user@hostname`.
  fleet hosts --list*         Script-friendly inventory dumps — also used by
                              the TV cable + your own shell glue:
                                --list        plain names, one per line
                                --list-tsv    name<TAB>target<TAB>kind
                                --list-json   full inventory JSON
                                --describe N  preview block for N
                                --probe N     BatchMode SSH probe of N

Mirrors `dot_config/television/cable/ssh-config.toml` (which is sourced from
~/.ssh/config), but reads ~/.config/fleet/machines.toml instead so explicit
hostname/user/port/identity_file hosts (no ssh_config alias) are reachable.

The TV cable at `dot_config/television/cable/fleet-hosts.toml` shells out to
`fleet hosts --list-tsv` (source), `fleet hosts --describe '{...}'` (preview),
and `fleet hosts '{...}'` (Enter action). This module is the SSOT for fleet
inventory introspection — the only TOML parser is `load_hosts()` in apply.py.

`local = true` hosts are hidden from `--list-tsv` (picker) by default — SSH'ing
into yourself is silly. Use `--include-local` to override, or run
`fleet hosts NAME` on a local host (prints a no-op message and exits 0).
"""
from __future__ import annotations

import argparse
import dataclasses
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

# Bootstrap: when invoked directly (not via the `fleet hosts` dispatcher in
# dot_dotfiles/bin/executable_fleet), put the chezmoi source dir on sys.path
# so `from scripts.fleet import ...` works regardless of cwd.
_SRC = Path(__file__).resolve().parent.parent.parent  # hosts.py -> fleet -> scripts -> src
if str(_SRC) not in sys.path:
    sys.path.insert(0, str(_SRC))

from scripts.fleet import DEFAULT_CONFIG_PATH, Host, load_hosts  # noqa: E402


# ---------------------------------------------------------------------------
# Host introspection helpers
# ---------------------------------------------------------------------------


def _kind(host: Host) -> str:
    """Compact connection-style summary for the picker's 3rd column."""
    if host.local:
        return "LOCAL"
    if host.ssh_alias:
        return f"alias:{host.ssh_alias}"
    parts: list[str] = []
    if host.user:
        parts.append(f"{host.user}@")
    parts.append(host.hostname or "?")
    if host.port and host.port != 22:
        parts.append(f":{host.port}")
    return "explicit:" + "".join(parts)


def _target(host: Host) -> str:
    """Resolved SSH target for the picker's 2nd column."""
    if host.local:
        return "(local)"
    if host.ssh_alias:
        return host.ssh_alias
    return host.hostname or "?"


def _ssh_argv(host: Host) -> list[str]:
    """argv for `ssh ...`. Mirrors apply.py:_connect_kwargs precedence —
    ssh_alias wins (let ssh_config resolve everything); otherwise build from
    hostname/user/port/identity_file."""
    if host.ssh_alias:
        return ["ssh", host.ssh_alias]
    argv: list[str] = ["ssh"]
    if host.port:
        argv += ["-p", str(host.port)]
    if host.identity_file:
        argv += ["-i", str(Path(host.identity_file).expanduser())]
    target = f"{host.user}@{host.hostname}" if host.user else (host.hostname or "")
    argv.append(target)
    return argv


def _load(config: Path) -> list[Host]:
    try:
        hosts, _defaults = load_hosts(config)
    except (FileNotFoundError, ValueError) as e:
        print(f"fleet hosts: {e}", file=sys.stderr)
        sys.exit(2)
    return hosts


def _find_host(name: str, hosts: list[Host]) -> Host:
    for h in hosts:
        if h.name == name:
            return h
    available = ", ".join(h.name for h in hosts) or "(none)"
    print(
        f"fleet hosts: unknown host {name!r}. Available: {available}",
        file=sys.stderr,
    )
    sys.exit(2)


# ---------------------------------------------------------------------------
# Listing modes
# ---------------------------------------------------------------------------


def _cmd_list_plain(hosts: list[Host]) -> int:
    for h in hosts:
        print(h.name)
    return 0


def _cmd_list_tsv(hosts: list[Host], include_local: bool) -> int:
    for h in hosts:
        if h.local and not include_local:
            continue
        print(f"{h.name}\t{_target(h)}\t{_kind(h)}")
    return 0


def _cmd_list_json(hosts: list[Host], config: Path) -> int:
    payload = []
    for h in hosts:
        d = dataclasses.asdict(h)
        # Never leak a resolved sudo_password / ssh_login_password (they'd
        # be None at this point — resolve_passwords()/
        # resolve_ssh_login_passwords() never ran — but be defensive in
        # case that changes).
        d.pop("sudo_password", None)
        d.pop("ssh_login_password", None)
        # For plain-type password sources, the TOML file itself is 0600 but
        # JSON dump goes to stdout (could be piped into logs/screenshots).
        if d.get("password_source_type") == "plain":
            d["password_source_arg"] = "(redacted — type=plain)"
        if d.get("ssh_login_password_source_type") == "plain":
            d["ssh_login_password_source_arg"] = "(redacted — type=plain)"
        payload.append(d)
    json.dump(
        {"config": str(config), "hosts": payload},
        sys.stdout,
        indent=2,
        default=str,
    )
    sys.stdout.write("\n")
    return 0


# ---------------------------------------------------------------------------
# Describe (TV preview pane)
# ---------------------------------------------------------------------------


def _ssh_g_lines(alias: str, wanted: tuple[str, ...]) -> list[str]:
    """Run `ssh -G ALIAS` and return matching `key value` lines."""
    if not shutil.which("ssh"):
        return []
    try:
        out = subprocess.run(
            ["ssh", "-G", alias],
            capture_output=True,
            text=True,
            timeout=3,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return []
    if out.returncode != 0:
        return []
    matched: list[str] = []
    for line in out.stdout.splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2 and parts[0] in wanted:
            matched.append(line)
    return matched


def _identity_paths_from_ssh_g(alias: str) -> list[str]:
    out: list[str] = []
    for line in _ssh_g_lines(alias, ("identityfile",)):
        parts = line.split(None, 1)
        if len(parts) == 2:
            out.append(parts[1])
    return out


def _expand_key_path(p: str) -> Path:
    return Path(p.replace("~", str(Path.home()))).expanduser()


def _cmd_describe(name: str, hosts: list[Host], config: Path) -> int:
    h = _find_host(name, hosts)

    print(f"# host: {h.name}        (defined in: {config})")
    print()

    print("connection:")
    if h.local:
        print("  local           true   (runs on orchestrator — no SSH)")
    elif h.ssh_alias:
        print(f"  ssh_alias       {h.ssh_alias}")
        print(f"  user            {h.user or '(from ssh_config)'}")
        print(f"  hostname        {h.hostname or '(from ssh_config)'}")
        print(f"  port            {h.port if h.port is not None else '(from ssh_config)'}")
        print(f"  identity_file   {h.identity_file or '(from ssh_config)'}")
    else:
        print("  ssh_alias       (none — explicit fields below)")
        print(f"  user            {h.user or '(default)'}")
        print(f"  hostname        {h.hostname}")
        print(f"  port            {h.port if h.port is not None else 22}")
        print(f"  identity_file   {h.identity_file or '(default agent / key)'}")
    print()

    print("fleet metadata:")
    print(f"  local                {str(h.local).lower()}")
    print(f"  no_root_machine      {str(h.no_root_machine).lower()}")
    print(f"  chezmoi_path         {h.chezmoi_path}")
    ps_label = h.password_source_type
    if h.password_source_arg and h.password_source_type != "plain":
        ps_label += f" (item={h.password_source_arg})"
    elif h.password_source_type == "plain":
        ps_label += " (value redacted)"
    print(f"  password_source      {ps_label}")
    ssh_ps_label = h.ssh_login_password_source_type
    if h.ssh_login_password_source_arg and h.ssh_login_password_source_type != "plain":
        ssh_ps_label += f" (item={h.ssh_login_password_source_arg})"
    elif h.ssh_login_password_source_type == "plain":
        ssh_ps_label += " (value redacted)"
    print(f"  ssh_login_password_source  {ssh_ps_label}")
    if h.extra_env:
        print(f"  extra_env            {', '.join(h.extra_env.keys())}")
    else:
        print("  extra_env            (none)")
    print()

    if h.ssh_alias:
        print(f"ssh -G {h.ssh_alias!r} (resolved by ssh_config):")
        wanted = (
            "hostname", "user", "port", "identityfile",
            "proxycommand", "proxyjump", "forwardagent", "identityagent",
        )
        lines = _ssh_g_lines(h.ssh_alias, wanted)
        if not lines:
            print("  (ssh -G unavailable or returned nothing)")
        else:
            for line in lines:
                print(f"  {line}")
        print()

    if not h.local:
        print("local key check (offline):")
        paths: list[str] = []
        if h.identity_file:
            paths.append(h.identity_file)
        elif h.ssh_alias:
            paths = _identity_paths_from_ssh_g(h.ssh_alias)
        if not paths:
            print("  (no identityfile to check)")
        else:
            found = False
            for p in paths:
                f = _expand_key_path(p)
                if f.is_file():
                    print(f"  [OK]   {f}")
                    found = True
                else:
                    print(f"  [miss] {f}")
            if not found:
                print()
                print(
                    "  => no IdentityFile present locally —"
                    " password / agent login required"
                )
        print()

    return 0


# ---------------------------------------------------------------------------
# Probe (TV Alt+T action)
# ---------------------------------------------------------------------------


def _cmd_probe(name: str, hosts: list[Host]) -> int:
    h = _find_host(name, hosts)
    if h.local:
        print(f"# {h.name} is local=true — no SSH probe needed.")
        return 0
    target = h.ssh_alias or h.hostname or "?"
    print(f"# Probing {target!r} with BatchMode=yes (ConnectTimeout=3)")
    print(
        "# Exit 0 = passwordless login works; non-zero = needs password /"
        " key not authorized / unreachable"
    )
    print()

    argv = _ssh_argv(h)
    argv = [
        argv[0],
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=3",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "PreferredAuthentications=publickey,hostbased,gssapi-with-mic",
        *argv[1:],
        "true",
    ]
    rc = subprocess.call(argv)
    print()
    if rc == 0:
        print(f"[OK] passwordless login works for {target!r}")
    elif rc == 255:
        print("[FAIL] connection / auth error (exit 255) — needs password,"
              " key not authorized, or host unreachable")
    else:
        print(f"[FAIL] remote command failed (exit {rc}) — auth probably OK"
              " but 'true' failed")
    return rc


# ---------------------------------------------------------------------------
# Direct SSH (positional NAME)
# ---------------------------------------------------------------------------


def _cmd_connect(name: str, hosts: list[Host]) -> int:
    h = _find_host(name, hosts)
    if h.local:
        print(
            f"fleet hosts: '{h.name}' is local = true — nothing to SSH into "
            "(you're already on the orchestrator).",
            file=sys.stderr,
        )
        return 0
    argv = _ssh_argv(h)
    # os.execvp replaces this process with ssh, so the user's terminal
    # becomes the SSH session directly — matches Enter in `tv ssh-config`.
    try:
        os.execvp(argv[0], argv)
    except OSError as e:
        print(f"fleet hosts: failed to exec {argv[0]}: {e}", file=sys.stderr)
        return 127
    return 0  # unreachable


# ---------------------------------------------------------------------------
# Picker (no args)
# ---------------------------------------------------------------------------


def _cmd_picker(hosts: list[Host]) -> int:
    tv = shutil.which("tv")
    if tv:
        try:
            os.execvp(tv, [tv, "fleet-hosts"])
        except OSError as e:
            print(f"fleet hosts: failed to exec tv: {e}", file=sys.stderr)
            # fall through to text menu

    pickable = [h for h in hosts if not h.local]
    if not pickable:
        print(
            "fleet hosts: no SSH-able hosts in inventory (all `local = true`).",
            file=sys.stderr,
        )
        return 2
    print("Fleet hosts (pick one to SSH into):")
    for i, h in enumerate(pickable, 1):
        print(f"  {i:>2}. {h.name:<24}  {_kind(h)}")
    print()
    try:
        choice = input("Number (or empty to abort): ").strip()
    except (EOFError, KeyboardInterrupt):
        print()
        return 130
    if not choice:
        return 0
    try:
        idx = int(choice) - 1
        if idx < 0 or idx >= len(pickable):
            raise ValueError
    except ValueError:
        print(f"fleet hosts: invalid choice {choice!r}", file=sys.stderr)
        return 2
    return _cmd_connect(pickable[idx].name, hosts)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="fleet hosts",
        description=(
            "Pick a fleet-configured host and SSH in. Mirrors `tv ssh-config`,"
            " but sourced from ~/.config/fleet/machines.toml."
        ),
    )
    p.add_argument(
        "name",
        nargs="?",
        help="Host name to SSH into (skip the picker). Use `--list` to enumerate.",
    )
    modes = p.add_mutually_exclusive_group()
    modes.add_argument(
        "--list",
        action="store_true",
        help="Plain host names, one per line.",
    )
    modes.add_argument(
        "--list-tsv",
        action="store_true",
        dest="list_tsv",
        help="TSV `name<TAB>target<TAB>kind` (used by the TV cable source).",
    )
    modes.add_argument(
        "--list-json",
        action="store_true",
        dest="list_json",
        help="Full inventory as JSON (plain password values are redacted).",
    )
    modes.add_argument(
        "--describe",
        metavar="NAME",
        help="Print the preview block for NAME (used by the TV cable preview).",
    )
    modes.add_argument(
        "--probe",
        metavar="NAME",
        help="BatchMode SSH probe of NAME (used by the TV cable Alt+T action).",
    )
    p.add_argument(
        "--include-local",
        action="store_true",
        help="Include `local = true` hosts in --list-tsv (default: hidden).",
    )
    p.add_argument(
        "--config",
        type=Path,
        default=DEFAULT_CONFIG_PATH,
        help=f"Fleet inventory path (default: {DEFAULT_CONFIG_PATH}).",
    )
    return p


def main() -> int:
    args = _build_parser().parse_args()
    hosts = _load(args.config)

    if args.list:
        return _cmd_list_plain(hosts)
    if args.list_tsv:
        return _cmd_list_tsv(hosts, include_local=args.include_local)
    if args.list_json:
        return _cmd_list_json(hosts, args.config)
    if args.describe:
        return _cmd_describe(args.describe, hosts, args.config)
    if args.probe:
        return _cmd_probe(args.probe, hosts)
    if args.name:
        return _cmd_connect(args.name, hosts)
    return _cmd_picker(hosts)


if __name__ == "__main__":
    sys.exit(main())
