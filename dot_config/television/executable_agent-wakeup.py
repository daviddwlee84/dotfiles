#!/usr/bin/env python3
"""Agent quota wakeup dashboard and scheduler.

Combines three data sources:

- live agent panes from ``agent-sessions.py panes``
- recent tmux pane capture for quota/rate-limit reset text
- queued pueue tasks in the ``agent-wakeup`` group

The parser is intentionally conservative. It only marks a pane as quota-waiting
when the pane contains explicit limit/reset wording; normal idle panes stay idle.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any


GROUP = "agent-wakeup"
LABEL_PREFIX = "agent-wakeup:"
DEFAULT_TEXT = "continue"
CAPTURE_LINES = 120
ACTIVE_TAIL_LINES = 24
ACTION_CONTINUE = "continue"
ACTION_ENTER = "enter"


@dataclass
class PaneRec:
    agent: str
    when: str
    sid: str
    cwd: str
    title: str
    specstory: str
    target: str
    pane_pid: str
    glyph: str
    pane_id: str = ""
    quota_message: str = ""
    reset_epoch: int = 0
    reset_display: str = ""
    state: str = "UNKNOWN"
    scheduled_display: str = ""
    scheduled_ids: str = ""
    action: str = ACTION_CONTINUE


@dataclass
class WakeTask:
    task_id: str
    pane_id: str
    status: str
    when_display: str
    command: str


def run(cmd: list[str], *, check: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=check,
    )


def script_path() -> Path:
    override = os.environ.get("AGENT_WAKEUP_SCRIPT")
    if override:
        return Path(override).expanduser()
    return Path(__file__).resolve()


def agent_sessions_script() -> Path:
    override = os.environ.get("AGENT_SESSIONS_SCRIPT")
    if override:
        return Path(override).expanduser()
    deployed = Path(__file__).with_name("agent-sessions.py")
    if deployed.exists():
        return deployed
    return Path(__file__).with_name("executable_agent-sessions.py")


def resolve_pane_id(target: str) -> str:
    cp = run(["tmux", "display-message", "-p", "-t", target, "#{pane_id}"])
    if cp.returncode != 0:
        return ""
    return cp.stdout.strip()


def capture_pane(target: str, lines: int = CAPTURE_LINES) -> str:
    cp = run(["tmux", "capture-pane", "-p", "-S", f"-{lines}", "-t", target])
    if cp.returncode != 0:
        return ""
    return cp.stdout


def _parse_agent_panes() -> list[PaneRec]:
    script = agent_sessions_script()
    cp = run([str(script), "panes"])
    if cp.returncode != 0:
        return []

    rows: list[PaneRec] = []
    for line in cp.stdout.splitlines():
        cols = line.split("\t")
        if len(cols) < 9:
            continue
        rec = PaneRec(
            agent=cols[0],
            when=cols[1],
            sid=cols[2],
            cwd=cols[3],
            title=cols[4],
            specstory=cols[5],
            target=cols[6],
            pane_pid=cols[7],
            glyph=cols[8],
        )
        rec.pane_id = resolve_pane_id(rec.target)
        rows.append(rec)
    return rows


_QUOTA_LINE_RE = re.compile(
    r"(session limit|rate limit|limit reached|usage .*limit|hit your .*limit|quota)",
    re.IGNORECASE,
)
_RESET_RE = re.compile(r"\bresets?\b(?:\s+in)?\s+([^)\n\r]+)", re.IGNORECASE)
_RATE_LIMIT_MENU_RE = re.compile(
    r"(/rate-limit-options|stop and wait for limit to reset|what do you want to do\?)",
    re.IGNORECASE,
)


def _format_dt(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%d %H:%M")


def _parse_reset_expr(expr: str, now: datetime) -> datetime | None:
    expr = expr.strip()
    expr = re.split(r"\s*[·|]\s*", expr, maxsplit=1)[0].strip()
    expr = re.sub(r"\s*\([^)]*\)\s*$", "", expr).strip()
    expr = expr.rstrip(".,; ")

    m = re.search(
        r"(?:(\d+)\s*h(?:ours?)?)?\s*(?:(\d+)\s*m(?:in(?:ute)?s?)?)",
        expr,
        re.IGNORECASE,
    )
    if m and (m.group(1) or m.group(2)):
        hours = int(m.group(1) or 0)
        mins = int(m.group(2) or 0)
        return now + timedelta(hours=hours, minutes=mins)

    m = re.search(r"\b(\d+)\s*(?:seconds?|secs?|s)\b", expr, re.IGNORECASE)
    if m:
        return now + timedelta(seconds=int(m.group(1)))

    m = re.search(r"\b(\d+)\s*(?:days?|d)\b", expr, re.IGNORECASE)
    if m:
        return now + timedelta(days=int(m.group(1)))

    time_match = re.search(r"\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b", expr, re.IGNORECASE)
    if time_match:
        hour = int(time_match.group(1))
        minute = int(time_match.group(2) or 0)
        ampm = (time_match.group(3) or "").lower()
        if ampm == "pm" and hour < 12:
            hour += 12
        elif ampm == "am" and hour == 12:
            hour = 0
        if hour > 23 or minute > 59:
            return None
        dt = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
        if dt <= now:
            dt += timedelta(days=1)
        return dt

    return None


def detect_quota(text: str, now: datetime | None = None) -> tuple[str, int, str]:
    now = now or datetime.now().astimezone()
    quota_lines = [line.strip() for line in text.splitlines() if _QUOTA_LINE_RE.search(line)]
    if not quota_lines:
        return ("", 0, "")

    reset_dt: datetime | None = None
    chosen = quota_lines[-1]
    for line in reversed(quota_lines):
        m = _RESET_RE.search(line)
        if not m:
            continue
        reset_dt = _parse_reset_expr(m.group(1), now)
        chosen = line
        if reset_dt:
            break

    if reset_dt:
        return (chosen, int(reset_dt.timestamp()), _format_dt(reset_dt))
    return (chosen, 0, "")


def recommended_action(text: str) -> str:
    if _RATE_LIMIT_MENU_RE.search(text):
        return ACTION_ENTER
    return ACTION_CONTINUE


def active_quota_text(text: str, action: str) -> str:
    if action == ACTION_ENTER:
        return text
    return "\n".join(text.splitlines()[-ACTIVE_TAIL_LINES:])


def _status_name(status: Any) -> str:
    if isinstance(status, str):
        return status
    if isinstance(status, dict) and status:
        return next(iter(status.keys()))
    return str(status)


def _datetime_from_status(task: dict[str, Any]) -> str:
    candidates: list[str] = []

    def walk(v: Any) -> None:
        if isinstance(v, dict):
            for key, val in v.items():
                if key in {"enqueue_at", "enqueued_at", "start", "created_at"} and isinstance(val, str):
                    candidates.append(val)
                walk(val)
        elif isinstance(v, list):
            for item in v:
                walk(item)

    walk(task.get("status"))
    if isinstance(task.get("created_at"), str):
        candidates.append(str(task["created_at"]))
    for value in candidates:
        try:
            return _format_dt(datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone())
        except ValueError:
            continue
    return ""


def _pueue_tasks() -> list[WakeTask]:
    if not shutil.which("pueue"):
        return []
    cp = run(["pueue", "status", "--json"])
    if cp.returncode != 0:
        return []
    try:
        data = json.loads(cp.stdout)
    except json.JSONDecodeError:
        return []

    tasks: list[WakeTask] = []
    for tid, task in (data.get("tasks") or {}).items():
        if not isinstance(task, dict):
            continue
        label = str(task.get("label") or "")
        if not label.startswith(LABEL_PREFIX):
            continue
        status = _status_name(task.get("status"))
        if status == "Done":
            continue
        pane_id = label[len(LABEL_PREFIX) :]
        tasks.append(
            WakeTask(
                task_id=str(task.get("id", tid)),
                pane_id=pane_id,
                status=status,
                when_display=_datetime_from_status(task),
                command=str(task.get("original_command") or task.get("command") or ""),
            )
        )
    return tasks


def _rows() -> tuple[list[PaneRec], list[WakeTask]]:
    panes = _parse_agent_panes()
    tasks = _pueue_tasks()
    tasks_by_pane: dict[str, list[WakeTask]] = {}
    for task in tasks:
        tasks_by_pane.setdefault(task.pane_id, []).append(task)

    now = datetime.now().astimezone()
    for pane in panes:
        text = capture_pane(pane.pane_id or pane.target)
        pane.action = recommended_action(text)
        msg, reset_epoch, reset_display = detect_quota(active_quota_text(text, pane.action), now)
        pane.quota_message = msg
        pane.reset_epoch = reset_epoch
        pane.reset_display = reset_display
        pane_tasks = tasks_by_pane.get(pane.pane_id, [])
        if pane_tasks:
            pane.state = "SCHEDULED"
            pane.scheduled_display = ", ".join(t.when_display or t.status for t in pane_tasks)
            pane.scheduled_ids = ",".join(t.task_id for t in pane_tasks)
        elif msg and pane.action == ACTION_ENTER:
            pane.state = "WAIT_MENU"
        elif msg and reset_epoch and reset_epoch <= int(now.timestamp()):
            pane.state = "READY"
        elif msg:
            pane.state = "WAIT_QUOTA"
        elif pane.glyph == "●":
            pane.state = "ACTIVE"
        elif pane.glyph == "○":
            pane.state = "IDLE"
        else:
            pane.state = "UNKNOWN"

    live_ids = {p.pane_id for p in panes if p.pane_id}
    for task in tasks:
        if task.pane_id in live_ids:
            continue
        panes.append(
            PaneRec(
                agent="[??]",
                when="",
                sid="",
                cwd="?",
                title="queued wakeup for missing pane",
                specstory="",
                target=task.pane_id,
                pane_pid="",
                glyph="",
                pane_id=task.pane_id,
                state="ORPHAN",
                scheduled_display=task.when_display or task.status,
                scheduled_ids=task.task_id,
            )
        )

    return panes, tasks


def _print_tsv(panes: list[PaneRec]) -> None:
    for p in panes:
        cols = [
            p.state,
            p.agent,
            p.target,
            p.pane_id,
            p.reset_display,
            str(p.reset_epoch or ""),
            p.scheduled_display,
            p.scheduled_ids,
            p.title,
            p.cwd,
            p.sid,
            p.quota_message,
            p.action,
        ]
        print("\t".join(c.replace("\t", " ").replace("\n", " ") for c in cols))


def _print_json(panes: list[PaneRec]) -> None:
    print(json.dumps([p.__dict__ for p in panes], ensure_ascii=False, indent=2))


def _print_table(panes: list[PaneRec]) -> None:
    widths = [12, 5, 28, 16, 16, 7]
    header = ("STATE", "AGENT", "PANE", "RESET", "WAKEUP", "TASKS")
    print("  ".join(h.ljust(w) for h, w in zip(header, widths)))
    print("  ".join("-" * w for w in widths))
    for p in panes:
        vals = (
            p.state,
            p.agent,
            p.target or p.pane_id,
            p.reset_display,
            p.scheduled_display,
            p.scheduled_ids,
        )
        print("  ".join(v[:w].ljust(w) for v, w in zip(vals, widths)))


def _select_pane(explicit: str | None, current: bool = False) -> str:
    if explicit:
        pane = resolve_pane_id(explicit)
        return pane or explicit
    if current:
        pane = os.environ.get("TMUX_PANE", "")
        if pane:
            return pane
    panes = [p for p in _parse_agent_panes() if p.pane_id]
    if len(panes) == 1:
        return panes[0].pane_id
    if sys.stdin.isatty() and shutil.which("fzf") and panes:
        choices = "\n".join(f"{p.pane_id}\t{p.agent} {p.target} {p.title} {p.cwd}" for p in panes)
        cp = subprocess.run(
            ["fzf", "--with-nth=2..", "--delimiter=\t", "--prompt=agent pane> "],
            input=choices,
            text=True,
            stdout=subprocess.PIPE,
        )
        if cp.returncode == 0 and cp.stdout.strip():
            return cp.stdout.split("\t", 1)[0].strip()
    print("agent-wakeup: specify --pane; candidates:", file=sys.stderr)
    for p in panes:
        print(f"  {p.pane_id}\t{p.agent}\t{p.target}\t{p.title}\t{p.cwd}", file=sys.stderr)
    raise SystemExit(2)


def _delay_arg(args: argparse.Namespace) -> str:
    if args.at_epoch:
        ts = int(args.at_epoch) + int(args.buffer_minutes or 0) * 60
        return datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M:%S")
    if args.delay:
        return args.delay
    if args.at:
        return args.at
    if args.when:
        s = args.when.strip()
        if re.fullmatch(r"\d+\s*[smhd](?:\s+\d+\s*[smhd])*", s, re.IGNORECASE):
            return s
        return s
    raise SystemExit("agent-wakeup schedule: pass --at, --delay, --when, or --at-epoch")


def _ensure_group() -> None:
    if not shutil.which("pueue"):
        raise SystemExit("agent-wakeup: pueue not installed")
    run(["pueue", "group", "add", GROUP])
    run(["pueue", "parallel", "-g", GROUP, "1"])


def cmd_schedule(args: argparse.Namespace) -> int:
    pane = _select_pane(args.pane, args.current)
    if not pane.startswith("%"):
        resolved = resolve_pane_id(pane)
        if resolved:
            pane = resolved
    text = args.text or DEFAULT_TEXT
    delay = _delay_arg(args)
    action = ACTION_ENTER if args.enter_only else ACTION_CONTINUE
    if args.auto:
        action = recommended_action(capture_pane(pane))
    expect_quota = False
    if not args.no_expect_quota:
        msg, _, _ = detect_quota(capture_pane(pane))
        expect_quota = bool(msg)

    cmd = [
        shlex.quote(str(script_path())),
        "send-now",
        "--pane",
        shlex.quote(pane),
    ]
    if action == ACTION_ENTER:
        cmd.append("--enter-only")
    else:
        cmd.extend(["--text", shlex.quote(text)])
    if expect_quota:
        cmd.append("--expect-quota")
    if args.auto:
        cmd.append("--auto")
    if args.force:
        cmd.append("--force")
    command = " ".join(cmd)
    label = f"{LABEL_PREFIX}{pane}"

    if args.dry_run:
        print(
            " ".join(
                [
                    "pueue",
                    "add",
                    "-g",
                    shlex.quote(GROUP),
                    "--label",
                    shlex.quote(label),
                    "--delay",
                    shlex.quote(delay),
                    shlex.quote(command),
                ]
            )
        )
        return 0

    _ensure_group()
    cp = run(
        [
            "pueue",
            "add",
            "-g",
            GROUP,
            "--label",
            label,
            "--delay",
            delay,
            "--print-task-id",
            command,
        ]
    )
    if cp.returncode != 0:
        print(cp.stderr or cp.stdout, file=sys.stderr, end="")
        return cp.returncode
    task_id = cp.stdout.strip()
    print(f"scheduled {label} at {delay} (task {task_id})")
    return 0


def cmd_send_now(args: argparse.Namespace) -> int:
    pane = _select_pane(args.pane, args.current)
    action = ACTION_ENTER if args.enter_only else ACTION_CONTINUE
    if args.auto:
        action = recommended_action(capture_pane(pane))
    if args.expect_quota and not args.force:
        msg, _, _ = detect_quota(capture_pane(pane))
        if not msg:
            print(f"agent-wakeup: quota marker gone for {pane}; aborting", file=sys.stderr)
            return 3
    if not resolve_pane_id(pane):
        print(f"agent-wakeup: pane not found: {pane}", file=sys.stderr)
        return 2
    if action == ACTION_ENTER:
        cmd = ["tmux", "send-keys", "-t", pane, "Enter"]
        sent = "Enter"
    else:
        text = args.text or DEFAULT_TEXT
        cmd = ["tmux", "send-keys", "-t", pane, "C-u", text, "Enter"]
        sent = repr(text)
    if args.dry_run:
        print(" ".join(shlex.quote(part) for part in cmd))
        return 0
    cp = run(cmd)
    if cp.returncode != 0:
        print(cp.stderr or cp.stdout, file=sys.stderr, end="")
        return cp.returncode
    print(f"sent {sent} to {pane}")
    return 0


def cmd_cancel(args: argparse.Namespace) -> int:
    pane = _select_pane(args.pane, args.current)
    if not pane.startswith("%"):
        pane = resolve_pane_id(pane) or pane
    tasks = [t for t in _pueue_tasks() if t.pane_id == pane]
    if not tasks:
        print(f"no queued wakeup tasks for {pane}")
        return 0
    rc = 0
    for task in tasks:
        cp = run(["pueue", "remove", task.task_id])
        if cp.returncode != 0:
            run(["pueue", "kill", task.task_id])
            cp = run(["pueue", "remove", task.task_id])
        if cp.returncode == 0:
            print(f"removed task {task.task_id} for {pane}")
        else:
            print(cp.stderr or cp.stdout, file=sys.stderr, end="")
            rc = cp.returncode
    return rc


def cmd_status(args: argparse.Namespace) -> int:
    panes, _ = _rows()
    if args.json:
        _print_json(panes)
    elif args.tsv:
        _print_tsv(panes)
    else:
        _print_table(panes)
    return 0


def cmd_preview(args: argparse.Namespace) -> int:
    pane = args.pane
    if not pane:
        return 0
    print(capture_pane(pane, lines=args.lines), end="")
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="agent-wakeup")
    sub = p.add_subparsers(dest="cmd", required=False)

    s = sub.add_parser("status", help="Show live agent panes and wakeup tasks")
    s.add_argument("--tsv", action="store_true", help="Print TV-friendly TSV")
    s.add_argument("--json", action="store_true", help="Print JSON")
    s.set_defaults(func=cmd_status)

    s = sub.add_parser("schedule", help="Schedule a continue for a pane")
    s.add_argument("--pane", help="tmux pane target or pane id")
    s.add_argument("--current", action="store_true", help="Use $TMUX_PANE")
    s.add_argument("--at", help="Absolute time expression for pueue --delay")
    s.add_argument("--delay", help="Relative delay for pueue --delay, e.g. 70m")
    s.add_argument("--when", help="Time/delay expression; relative forms use pueue --delay")
    s.add_argument("--at-epoch", type=int, help="Epoch seconds, converted to local time")
    s.add_argument("--buffer-minutes", type=int, default=0, help="Add minutes to --at-epoch")
    s.add_argument("--text", default=DEFAULT_TEXT, help="Text to send before Enter")
    s.add_argument("--enter-only", action="store_true", help="Send only Enter")
    s.add_argument("--auto", action="store_true", help="Choose Enter for rate-limit menus, otherwise continue")
    s.add_argument("--no-expect-quota", action="store_true", help="Do not abort if quota marker disappears")
    s.add_argument("--force", action="store_true", help="Force send even if expected quota marker is gone")
    s.add_argument("--dry-run", action="store_true")
    s.set_defaults(func=cmd_schedule)

    s = sub.add_parser("send-now", help="Send continue to a pane now")
    s.add_argument("--pane", help="tmux pane target or pane id")
    s.add_argument("--current", action="store_true", help="Use $TMUX_PANE")
    s.add_argument("--text", default=DEFAULT_TEXT)
    s.add_argument("--enter-only", action="store_true", help="Send only Enter")
    s.add_argument("--auto", action="store_true", help="Choose Enter for rate-limit menus, otherwise continue")
    s.add_argument("--expect-quota", action="store_true")
    s.add_argument("--force", action="store_true")
    s.add_argument("--dry-run", action="store_true")
    s.set_defaults(func=cmd_send_now)

    s = sub.add_parser("cancel", help="Cancel queued wakeups for a pane")
    s.add_argument("--pane", help="tmux pane target or pane id")
    s.add_argument("--current", action="store_true", help="Use $TMUX_PANE")
    s.set_defaults(func=cmd_cancel)

    s = sub.add_parser("preview", help="Print live pane capture")
    s.add_argument("--pane", required=True)
    s.add_argument("--lines", type=int, default=CAPTURE_LINES)
    s.set_defaults(func=cmd_preview)

    return p


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not hasattr(args, "func"):
        args = parser.parse_args(["status", *(argv or [])])
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
