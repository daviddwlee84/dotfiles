#!/usr/bin/env python3
"""Live Herdr pane inventory and actions for the herdr-panes TV channel."""

from __future__ import annotations

import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

TIMEOUT = 5
SHELLS = frozenset({
    "sh", "bash", "zsh", "fish", "dash", "ash", "ksh", "ksh93", "mksh",
    "csh", "tcsh", "nu", "pwsh", "powershell", "powershell.exe", "cmd.exe",
})
VIEWS = ("non-shell", "agent", "process", "shell")


class PaneError(RuntimeError):
    pass


def clean(value: object) -> str:
    """One printable TSV field; do not let titles inject terminal controls."""
    return " ".join("".join(c if c.isprintable() else " " for c in str(value or "")).split())


def run(socket: str, *args: str) -> str:
    try:
        result = subprocess.run(
            ["herdr", *args], env=dict(os.environ, HERDR_SOCKET_PATH=socket),
            capture_output=True, text=True, errors="replace", timeout=TIMEOUT,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise PaneError(f"{' '.join(args[:2])}: {exc}") from exc
    if result.returncode:
        raise PaneError(clean(result.stderr or result.stdout) or "Herdr command failed")
    return result.stdout


def query(socket: str, key: str, *args: str):
    try:
        return json.loads(run(socket, *args))["result"][key]
    except (ValueError, KeyError, TypeError) as exc:
        raise PaneError(f"{' '.join(args[:2])}: invalid Herdr response") from exc


def process_names(info: dict) -> list[str]:
    processes = info.get("foreground_processes")
    if not isinstance(processes, list) or not processes:
        raise PaneError("No foreground process information")
    names = set()
    for process in processes:
        if not isinstance(process, dict):
            raise PaneError("Invalid foreground process information")
        name = process.get("argv0") or process.get("name")
        if not isinstance(name, str) or not name:
            raise PaneError("Foreground executable is unknown")
        names.add(name.replace("\\", "/").rsplit("/", 1)[-1].lstrip("-"))
    return sorted(names)


def classify(pane: dict, info: dict) -> tuple[str, list[str]]:
    names = process_names(info)
    if pane.get("agent"):
        return "agent", names
    return ("shell" if all(name.lower() in SHELLS for name in names) else "process"), names


def encode(route: dict) -> str:
    return base64.urlsafe_b64encode(
        json.dumps(route, ensure_ascii=False, separators=(",", ":")).encode()
    ).decode().rstrip("=")


def decode(token: str) -> dict:
    if not re.fullmatch(r"[A-Za-z0-9_-]+", token):
        raise PaneError("Invalid selection token")
    try:
        route = json.loads(base64.urlsafe_b64decode(token + "=" * (-len(token) % 4)))
    except (ValueError, UnicodeError) as exc:
        raise PaneError("Invalid selection token") from exc
    if not isinstance(route, dict):
        raise PaneError("Invalid selection token")
    if isinstance(route.get("notice"), str):
        return route
    if type(route.get("schema_version")) is not int or route["schema_version"] != 1:
        raise PaneError("Invalid route version")
    for key in ("socket_path", "workspace_id", "tab_id", "pane_id"):
        value = route.get(key)
        if not isinstance(value, str) or not value or "\0" in value:
            raise PaneError(f"Invalid route field: {key}")
    return route


def row(route: dict) -> str:
    if "notice" in route:
        return f"{encode(route)}\t{clean(route['notice'])}\t-"
    location = f"{route['workspace']} / {route['tab']} / {route['pane_id']}"
    program = ", ".join(route["programs"]) or "?"
    if route["kind"] == "agent":
        program = f"{route['agent']} [{route['agent_status']}]"
    summary = route["title"] or route["cwd"]
    display = " │ ".join(map(clean, (route["kind"], location, program, summary)))
    return f"{encode(route)}\t{display}\t{clean(route['pane_id'])}"


def inventory(socket: str, view: str) -> list[dict]:
    workspaces = query(socket, "workspaces", "workspace", "list")
    tabs = query(socket, "tabs", "tab", "list")
    panes = query(socket, "panes", "pane", "list")
    if not all(isinstance(items, list) and all(isinstance(p, dict) for p in items)
               for items in (workspaces, tabs, panes)):
        raise PaneError("Invalid Herdr inventory")
    ws = {w["workspace_id"]: w for w in workspaces}
    ts = {t["tab_id"]: t for t in tabs}
    ws_order = {w["workspace_id"]: i for i, w in enumerate(workspaces)}
    tab_order = {t["tab_id"]: i for i, t in enumerate(tabs)}
    # The caller is the shell/command pane occupied by this picker.
    panes = [p for p in panes if p["pane_id"] != os.environ.get("HERDR_PANE_ID")]
    panes.sort(key=lambda p: (ws_order.get(p["workspace_id"], len(ws)),
                              tab_order.get(p["tab_id"], len(ts))))

    def inspect(pane: dict) -> dict:
        problem = ""
        try:
            info = query(socket, "process_info", "pane", "process-info", "--pane", pane["pane_id"])
            if not isinstance(info, dict):
                raise PaneError("Invalid process information")
            kind, names = classify(pane, info)
        except PaneError as exc:
            kind, names, problem = "unknown", [], str(exc)
        return dict(
            schema_version=1, socket_path=socket,
            workspace_id=pane["workspace_id"], tab_id=pane["tab_id"], pane_id=pane["pane_id"],
            workspace=ws.get(pane["workspace_id"], {}).get("label") or pane["workspace_id"],
            tab=ts.get(pane["tab_id"], {}).get("label") or pane["tab_id"],
            kind=kind, programs=names, agent=pane.get("agent") or "",
            agent_status=pane.get("agent_status") or "unknown",
            title=pane.get("terminal_title_stripped") or pane.get("terminal_title") or "",
            cwd=pane.get("foreground_cwd") or pane.get("cwd") or "",
            problem=problem,
        )

    with ThreadPoolExecutor(max_workers=4) as pool:
        routes = list(pool.map(inspect, panes))
    return [r for r in routes if (r["kind"] != "shell" if view == "non-shell" else r["kind"] == view)]


def current_pane(route: dict) -> dict:
    pane = query(route["socket_path"], "pane", "pane", "get", route["pane_id"])
    if not isinstance(pane, dict) or any(pane.get(k) != route[k] for k in ("pane_id", "workspace_id", "tab_id")):
        raise PaneError("Pane moved or disappeared; press Ctrl+R to reload")
    return pane


def preview(route: dict) -> None:
    if "notice" in route:
        print(clean(route["notice"]))
        return
    pane = current_pane(route)
    print(f"{clean(route['workspace'])} / {clean(route['tab'])} / {clean(route['pane_id'])}")
    print(f"socket: {clean(route['socket_path'])}")
    try:
        info = query(route["socket_path"], "process_info", "pane", "process-info", "--pane", route["pane_id"])
        kind, names = classify(pane, info)
        print(f"type: {kind}   foreground: {clean(', '.join(names))}")
    except (PaneError, AttributeError) as exc:
        print(f"type: unknown   {clean(exc)}")
        kind = "unknown"
    if pane.get("agent"):
        print(f"agent: {clean(pane['agent'])}   status: {clean(pane.get('agent_status'))}")
    print(f"title: {clean(pane.get('terminal_title_stripped') or pane.get('terminal_title'))}")
    print(f"cwd: {clean(pane.get('foreground_cwd') or pane.get('cwd'))}")
    if kind == "shell":
        print("Foreground shell only; background jobs have NOT been checked. This is not a safe-to-close verdict.")
    print("\n── current visible pane ──")
    print(run(route["socket_path"], "pane", "read", route["pane_id"], "--source", "visible", "--lines", "80", "--format", "text"), end="")


def focus(token: str) -> int:
    config = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
    helper = config / "herdr" / "focus-pane.py"
    if not helper.is_file():
        raise PaneError(f"Missing focus helper: {helper}")
    return subprocess.call([sys.executable, str(helper), "--route-token", token])


def close(route: dict) -> None:
    current_pane(route)
    print(f"Close {clean(route['workspace'])} / {clean(route['tab'])} / {clean(route['pane_id'])}?")
    print("This terminates the pane and its running programs.")
    try:
        answer = input("Close this pane? [y/N] ")
    except EOFError:
        answer = ""
    if answer.strip().lower() not in {"y", "yes"}:
        print("Cancelled.")
        return
    current_pane(route)  # Revalidate after the confirmation, before the mutation.
    run(route["socket_path"], "pane", "close", route["pane_id"])
    print(f"Closed {clean(route['pane_id'])}.")


def copy(route: dict, field: str) -> None:
    pane = current_pane(route)
    text = route["pane_id"] if field == "id" else pane.get("foreground_cwd") or pane.get("cwd")
    if not isinstance(text, str) or not text:
        raise PaneError("No directory available to copy")
    for command in (["pbcopy"], ["wl-copy"], ["xclip", "-selection", "clipboard"]):
        if shutil.which(command[0]):
            subprocess.run(command, input=text.encode(), check=True, timeout=TIMEOUT)
            return
    with open("/dev/tty", "w") as tty:
        tty.write(f"\033]52;c;{base64.b64encode(text.encode()).decode()}\007")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("list", "preview", "focus", "close", "copy-id", "copy-dir"))
    parser.add_argument("selection", help="view name for list, otherwise the selected route token")
    args = parser.parse_args(argv)
    try:
        if os.environ.get("HERDR_ENV") != "1":
            raise PaneError("Run tv herdr-panes inside Herdr")
        if args.action == "list":
            if args.selection not in VIEWS:
                raise PaneError(f"Unknown view: {args.selection}")
            socket = os.environ.get("HERDR_SOCKET_PATH")
            if not socket:
                raise PaneError("No inherited Herdr socket; reopen the picker inside Herdr")
            routes = inventory(socket, args.selection)
            for route in routes:
                print(row(route))
            if not routes:
                print(row({"notice": f"No {args.selection} panes · Ctrl+S next view · Ctrl+R reload"}))
            return 0
        route = decode(args.selection)
        if "notice" in route and args.action != "preview":
            raise PaneError(route["notice"])
        if args.action == "preview":
            preview(route)
        elif args.action == "focus":
            return focus(args.selection)
        elif args.action == "close":
            close(route)
        else:
            copy(route, args.action.removeprefix("copy-"))
        return 0
    except (PaneError, OSError, subprocess.SubprocessError, KeyError, TypeError) as exc:
        message = f"herdr-panes: {clean(exc)}"
        if args.action == "list":
            # TV must show server failures rather than an apparently empty inventory.
            print(row({"notice": f"ERROR: {message} · Ctrl+R reload"}))
        elif args.action == "preview":
            print(f"{message}\nPane unavailable; press Ctrl+R to reload.")
        else:
            print(message, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
