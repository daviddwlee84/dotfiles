#!/usr/bin/env python3
"""Agent quota wakeup dashboard and scheduler.

Combines three data sources:

- live agent panes from tmux ``agent-sessions.py panes`` and Herdr agent APIs
- recent tmux/Herdr pane capture for quota/rate-limit reset text
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
    backend: str = "tmux"
    backend_session: str = ""
    agent_session_id: str = ""
    native_status: str = ""


@dataclass
class WakeTask:
    task_id: str
    pane_id: str
    status: str
    when_display: str
    command: str
    backend: str = "tmux"
    backend_session: str = ""
    agent_session_id: str = ""


def run(cmd: list[str], *, check: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=check,
    )


def _json_result(cp: subprocess.CompletedProcess[str]) -> dict[str, Any]:
    if cp.returncode != 0:
        return {}
    try:
        data = json.loads(cp.stdout)
    except json.JSONDecodeError:
        return {}
    if isinstance(data, dict) and isinstance(data.get("result"), dict):
        return data["result"]
    return data if isinstance(data, dict) else {}


def _herdr(session: str, *args: str) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["HERDR_SESSION"] = session
    return subprocess.run(
        ["herdr", *args], text=True, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, env=env,
    )


def _running_herdr_sessions() -> list[str]:
    if not shutil.which("herdr"):
        return []
    sessions = _json_result(run(["herdr", "session", "list", "--json"])).get("sessions", [])
    return [
        str(item.get("name")) for item in sessions
        if isinstance(item, dict) and item.get("running") and item.get("name")
    ]


def _default_herdr_session(explicit: str | None = None) -> str:
    sessions = _running_herdr_sessions()
    if explicit:
        if explicit in sessions:
            return explicit
        raise SystemExit(f"agent-wakeup: Herdr session {explicit!r} is not running")
    ambient = os.environ.get("HERDR_SESSION", "")
    if ambient in sessions:
        return ambient
    cp = run(["herdr", "session", "list", "--json"]) if shutil.which("herdr") else None
    data = _json_result(cp) if cp else {}
    ambient_socket = os.environ.get("HERDR_SOCKET_PATH", "")
    socket_matches = [
        str(item.get("name")) for item in data.get("sessions", [])
        if isinstance(item, dict) and item.get("running") and item.get("socket_path") == ambient_socket
    ]
    if len(socket_matches) == 1:
        return socket_matches[0]
    defaults = [
        str(item.get("name")) for item in data.get("sessions", [])
        if isinstance(item, dict) and item.get("running") and item.get("default")
    ]
    if len(defaults) == 1:
        return defaults[0]
    if len(sessions) == 1:
        return sessions[0]
    if not sessions:
        raise SystemExit("agent-wakeup: no running Herdr session")
    raise SystemExit("agent-wakeup: multiple Herdr sessions are running; pass --herdr-session")


def _backend_for(args: argparse.Namespace, *, status: bool = False) -> str:
    requested = getattr(args, "backend", "auto")
    if requested != "auto":
        return requested
    if os.environ.get("HERDR_PANE_ID") or (os.environ.get("HERDR_ENV") == "1" and os.environ.get("HERDR_SESSION")):
        return "herdr"
    if os.environ.get("TMUX") or os.environ.get("TMUX_PANE"):
        return "tmux"
    return "all" if status else ("herdr" if _running_herdr_sessions() else "tmux")


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


def capture_target(
    target: str, *, backend: str = "tmux", session: str = "", lines: int = CAPTURE_LINES
) -> str:
    if backend == "herdr":
        cp = _herdr(session, "agent", "read", target, "--source", "visible", "--lines", str(lines))
        result = _json_result(cp)
        for key in ("text", "output", "content"):
            if isinstance(result.get(key), str):
                return str(result[key])
        return cp.stdout if cp.returncode == 0 else ""
    return capture_pane(target, lines)


def _parse_agent_panes(*, strict: bool = False) -> list[PaneRec]:
    script = agent_sessions_script()
    cp = run([str(script), "panes"])
    if cp.returncode != 0:
        if strict:
            raise RuntimeError(cp.stderr.strip() or "tmux agent pane discovery failed")
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


def _agent_session_value(item: dict[str, Any]) -> str:
    session = item.get("agent_session")
    if isinstance(session, dict):
        return str(session.get("value") or "")
    return ""


def _parse_herdr_panes(session: str) -> list[PaneRec]:
    cp = _herdr(session, "agent", "list")
    if cp.returncode != 0:
        raise RuntimeError(cp.stderr.strip() or f"Herdr session {session} agent list failed")
    agents = _json_result(cp).get("agents", [])
    rows: list[PaneRec] = []
    for item in agents:
        if not isinstance(item, dict):
            continue
        pane = str(item.get("pane_id") or "")
        if not pane:
            continue
        native = str(item.get("agent_status") or "unknown")
        glyph = "●" if native == "working" else "○" if native in {"idle", "done"} else ""
        rows.append(PaneRec(
            agent=str(item.get("agent") or "[??]"), when="",
            sid=_agent_session_value(item), cwd=str(item.get("cwd") or "?"),
            title=str(item.get("terminal_title_stripped") or item.get("terminal_title") or ""),
            specstory="", target=pane, pane_pid="", glyph=glyph, pane_id=pane,
            backend="herdr", backend_session=session,
            agent_session_id=_agent_session_value(item), native_status=native,
        ))
    return rows


def _find_herdr_agent(session: str, agent_session_id: str, pane: str = "") -> PaneRec | None:
    rows = _parse_herdr_panes(session)
    if agent_session_id:
        return next((row for row in rows if row.agent_session_id == agent_session_id), None)
    return next((row for row in rows if row.pane_id == pane), None)


_ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
# Word-boundary anchored so we don't fire on "quotation"/"quotas"/incidental
# substrings; "hit your <plan> limit" stays flexible but bounded.
_QUOTA_LINE_RE = re.compile(
    r"\b(?:session limit|rate limit|limit reached|quota)\b"
    r"|\bhit your\b.+?\blimit\b",
    re.IGNORECASE,
)
_RESET_RE = re.compile(r"\bresets?\b(?:\s+in)?\s+([^)\n\r]+)", re.IGNORECASE)
_RATE_LIMIT_MENU_RE = re.compile(
    r"(/rate-limit-options|stop and wait for limit to reset|what do you want to do\?)",
    re.IGNORECASE,
)
# claude-hud statusLine: a single line led (at start, or after a box "│") by a
# "Context"/"Usage" segment that also says "Limit reached". Self-contained so the
# classifier needs no post-hoc startswith/substring checks (the cache is stale —
# see pitfalls/claude-hud-usage-statusline-stale.md). A genuine agent message
# like "...your usage limit reached" is NOT led by Context/Usage, so it survives.
_CLAUDE_HUD_USAGE_RE = re.compile(
    r"(?:^|│\s*)(?:Context|Usage)\b.*\bLimit reached\b",
    re.IGNORECASE,
)


def _strip_ansi(text: str) -> str:
    return _ANSI_RE.sub("", text)


def _is_claude_hud_usage_line(line: str) -> bool:
    """claude-hud statusLine usage is cached/non-authoritative for wakeups."""
    return _CLAUDE_HUD_USAGE_RE.search(_strip_ansi(line).strip()) is not None


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
    quota_lines = [
        line.strip()
        for line in text.splitlines()
        if _QUOTA_LINE_RE.search(line) and not _is_claude_hud_usage_line(line)
    ]
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
        identity = label[len(LABEL_PREFIX) :]
        backend = "tmux"
        backend_session = agent_session_id = ""
        pane_id = identity
        if identity.startswith("herdr:"):
            parts = identity.split(":", 2)
            if len(parts) == 3:
                backend, backend_session, agent_session_id = parts
                pane_id = agent_session_id
        tasks.append(
            WakeTask(
                task_id=str(task.get("id", tid)),
                pane_id=pane_id,
                status=status,
                when_display=_datetime_from_status(task),
                command=str(task.get("original_command") or task.get("command") or ""),
                backend=backend,
                backend_session=backend_session,
                agent_session_id=agent_session_id,
            )
        )
    return tasks


def _identity(rec: PaneRec) -> str:
    if rec.backend == "herdr":
        return f"herdr:{rec.backend_session}:{rec.agent_session_id}"
    return rec.pane_id


def _task_identity(task: WakeTask) -> str:
    if task.backend == "herdr":
        return f"herdr:{task.backend_session}:{task.agent_session_id}"
    return task.pane_id


def _rows(backend: str = "auto", herdr_session: str | None = None) -> tuple[list[PaneRec], list[WakeTask], list[str]]:
    panes: list[PaneRec] = []
    errors: list[str] = []
    selected = backend
    if selected == "auto":
        selected = "herdr" if os.environ.get("HERDR_PANE_ID") else "tmux" if os.environ.get("TMUX_PANE") else "all"
    if selected in {"tmux", "all"}:
        try:
            panes.extend(_parse_agent_panes(strict=True))
        except (OSError, RuntimeError) as exc:
            errors.append(f"tmux: {exc}")
    if selected in {"herdr", "all"}:
        sessions = [_default_herdr_session(herdr_session)] if herdr_session else _running_herdr_sessions()
        if selected == "herdr" and not sessions:
            errors.append("herdr: no running session")
        for session in sessions:
            try:
                panes.extend(_parse_herdr_panes(session))
            except (OSError, RuntimeError) as exc:
                errors.append(f"herdr:{session}: {exc}")
    tasks = _pueue_tasks()
    tasks_by_pane: dict[str, list[WakeTask]] = {}
    for task in tasks:
        tasks_by_pane.setdefault(_task_identity(task), []).append(task)

    now = datetime.now().astimezone()
    for pane in panes:
        text = capture_target(
            pane.pane_id or pane.target, backend=pane.backend,
            session=pane.backend_session,
        )
        # Asymmetry by design: recommended_action() scans the FULL capture (the
        # /rate-limit-options menu can sit above the fold), but detect_quota()
        # only sees active_quota_text() — the last ACTIVE_TAIL_LINES for a
        # CONTINUE action — so a stale quota line that scrolled up does not keep
        # a now-active pane wrongly marked WAIT_QUOTA. ENTER (menu) keeps full text.
        pane.action = recommended_action(text)
        msg, reset_epoch, reset_display = detect_quota(active_quota_text(text, pane.action), now)
        pane.quota_message = msg
        pane.reset_epoch = reset_epoch
        pane.reset_display = reset_display
        pane_tasks = tasks_by_pane.get(_identity(pane), [])
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
        elif pane.backend == "herdr" and pane.native_status == "blocked":
            pane.state = "WAIT_USER"
        elif pane.glyph == "●":
            pane.state = "ACTIVE"
        elif pane.glyph == "○":
            pane.state = "IDLE"
        else:
            pane.state = "UNKNOWN"

    live_ids = {_identity(p) for p in panes if p.pane_id}
    for task in tasks:
        if _task_identity(task) in live_ids:
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
                backend=task.backend,
                backend_session=task.backend_session,
                agent_session_id=task.agent_session_id,
            )
        )

    return panes, tasks, errors


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
            p.backend,
            p.backend_session,
            p.agent_session_id,
        ]
        print("\t".join(c.replace("\t", " ").replace("\n", " ") for c in cols))


def _print_json(panes: list[PaneRec]) -> None:
    print(json.dumps([p.__dict__ for p in panes], ensure_ascii=False, indent=2))


def _print_table(panes: list[PaneRec]) -> None:
    widths = [12, 7, 5, 28, 16, 16, 7]
    header = ("STATE", "BACKEND", "AGENT", "PANE", "RESET", "WAKEUP", "TASKS")
    print("  ".join(h.ljust(w) for h, w in zip(header, widths)))
    print("  ".join("-" * w for w in widths))
    for p in panes:
        vals = (
            p.state,
            p.backend,
            p.agent,
            p.target or p.pane_id,
            p.reset_display,
            p.scheduled_display,
            p.scheduled_ids,
        )
        print("  ".join(v[:w].ljust(w) for v, w in zip(vals, widths)))


def _select_target(args: argparse.Namespace) -> PaneRec:
    backend = _backend_for(args)
    session = ""
    if backend == "herdr":
        session = _default_herdr_session(getattr(args, "herdr_session", None))
    explicit = getattr(args, "pane", None)
    agent_session_id = getattr(args, "agent_session_id", None) or ""
    if getattr(args, "current", False):
        if backend == "herdr":
            explicit = os.environ.get("HERDR_PANE_ID", "")
        else:
            explicit = os.environ.get("TMUX_PANE", "")
    if explicit:
        if backend == "herdr":
            found = _find_herdr_agent(session, agent_session_id, explicit)
            if found:
                return found
            raise SystemExit(f"agent-wakeup: Herdr agent not found: {agent_session_id or explicit}")
        pane = resolve_pane_id(explicit) or explicit
        return PaneRec("", "", "", "", "", "", pane, "", "", pane_id=pane)
    if backend == "herdr" and agent_session_id:
        found = _find_herdr_agent(session, agent_session_id)
        if found:
            return found
        raise SystemExit(f"agent-wakeup: Herdr agent session not found: {agent_session_id}")
    panes = _parse_herdr_panes(session) if backend == "herdr" else _parse_agent_panes()
    panes = [pane for pane in panes if pane.pane_id]
    if len(panes) == 1:
        return panes[0]
    if sys.stdin.isatty() and shutil.which("fzf") and panes:
        choices = "\n".join(f"{i}\t{p.agent} {p.backend}:{p.target} {p.title} {p.cwd}" for i, p in enumerate(panes))
        cp = subprocess.run(
            ["fzf", "--with-nth=2..", "--delimiter=\t", "--prompt=agent pane> "],
            input=choices,
            text=True,
            stdout=subprocess.PIPE,
        )
        if cp.returncode == 0 and cp.stdout.strip():
            return panes[int(cp.stdout.split("\t", 1)[0])]
    print("agent-wakeup: specify --pane/--agent-session-id; candidates:", file=sys.stderr)
    for p in panes:
        print(f"  {p.backend}:{p.backend_session}:{p.pane_id}\t{p.agent}\t{p.agent_session_id}\t{p.title}", file=sys.stderr)
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
    rec = _select_target(args)
    pane = rec.pane_id
    text = args.text or DEFAULT_TEXT
    delay = _delay_arg(args)
    action = ACTION_ENTER if args.enter_only else ACTION_CONTINUE
    if args.auto:
        action = recommended_action(capture_target(pane, backend=rec.backend, session=rec.backend_session))
    expect_quota = False
    if not args.no_expect_quota:
        msg, _, _ = detect_quota(capture_target(pane, backend=rec.backend, session=rec.backend_session))
        expect_quota = bool(msg)

    cmd = [
        shlex.quote(str(script_path())),
        "send-now",
        "--pane",
        shlex.quote(pane),
        "--backend",
        rec.backend,
    ]
    if rec.backend_session:
        cmd.extend(["--herdr-session", shlex.quote(rec.backend_session)])
    if rec.agent_session_id:
        cmd.extend(["--agent-session-id", shlex.quote(rec.agent_session_id)])
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
    label = f"{LABEL_PREFIX}{_identity(rec)}"

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
    rec = _select_target(args)
    pane = rec.pane_id
    capture = capture_target(pane, backend=rec.backend, session=rec.backend_session)
    action = ACTION_ENTER if args.enter_only else ACTION_CONTINUE
    if args.auto:
        action = recommended_action(capture)
    if args.expect_quota and not args.force:
        msg, _, _ = detect_quota(capture)
        if not msg:
            print(f"agent-wakeup: quota marker gone for {pane}; aborting", file=sys.stderr)
            return 3
    if rec.backend == "herdr":
        current = _find_herdr_agent(rec.backend_session, rec.agent_session_id, pane)
        if not current:
            print(f"agent-wakeup: Herdr agent identity no longer exists: {rec.agent_session_id or pane}", file=sys.stderr)
            return 2
        pane = current.pane_id
        if action == ACTION_ENTER:
            commands = [["agent", "send-keys", pane, "enter"]]
            sent = "Enter"
        else:
            text = args.text or DEFAULT_TEXT
            commands = [
                ["pane", "send-keys", pane, "ctrl+u"],
                ["pane", "send-text", pane, text],
                ["agent", "send-keys", pane, "enter"],
            ]
            sent = repr(text)
        if args.dry_run:
            for command in commands:
                print(" ".join(shlex.quote(part) for part in ["herdr", *command]))
            return 0
        for command in commands:
            cp = _herdr(rec.backend_session, *command)
            if cp.returncode != 0:
                print(cp.stderr or cp.stdout, file=sys.stderr, end="")
                return cp.returncode
    else:
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
    print(f"sent {sent} to {rec.backend}:{pane}")
    return 0


def cmd_cancel(args: argparse.Namespace) -> int:
    rec = _select_target(args)
    identity = _identity(rec)
    tasks = [t for t in _pueue_tasks() if _task_identity(t) == identity]
    if not tasks:
        print(f"no queued wakeup tasks for {identity}")
        return 0
    rc = 0
    for task in tasks:
        cp = run(["pueue", "remove", task.task_id])
        if cp.returncode != 0:
            run(["pueue", "kill", task.task_id])
            cp = run(["pueue", "remove", task.task_id])
        if cp.returncode == 0:
            print(f"removed task {task.task_id} for {identity}")
        else:
            print(cp.stderr or cp.stdout, file=sys.stderr, end="")
            rc = cp.returncode
    return rc


def cmd_status(args: argparse.Namespace) -> int:
    backend = _backend_for(args, status=True)
    panes, _, errors = _rows(backend, args.herdr_session)
    for error in errors:
        print(f"agent-wakeup: warning: {error}", file=sys.stderr)
    if args.json:
        _print_json(panes)
    elif args.tsv:
        _print_tsv(panes)
    else:
        _print_table(panes)
    return 2 if errors and not panes else 0


def cmd_preview(args: argparse.Namespace) -> int:
    pane = args.pane
    if not pane:
        return 0
    print(capture_target(
        pane, backend=args.backend, session=args.herdr_session or "",
        lines=args.lines,
    ), end="")
    return 0


def cmd_focus(args: argparse.Namespace) -> int:
    rec = _select_target(args)
    if rec.backend == "tmux":
        cp = run(["tmux", "select-pane", "-t", rec.pane_id])
    else:
        current = _find_herdr_agent(rec.backend_session, rec.agent_session_id, rec.pane_id)
        if not current:
            print("agent-wakeup: Herdr agent no longer exists", file=sys.stderr)
            return 2
        data = _json_result(_herdr(rec.backend_session, "agent", "get", current.pane_id))
        if isinstance(data.get("agent"), dict):
            data = data["agent"]
        workspace = str(data.get("workspace_id") or "")
        tab = str(data.get("tab_id") or "")
        if not workspace or not tab:
            print("agent-wakeup: Herdr agent has no focus coordinates", file=sys.stderr)
            return 2
        cp = _herdr(rec.backend_session, "workspace", "focus", workspace)
        if cp.returncode == 0:
            cp = _herdr(rec.backend_session, "tab", "focus", tab)
    if cp.returncode != 0:
        print(cp.stderr or cp.stdout, file=sys.stderr, end="")
    return cp.returncode


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="agent-wakeup")
    sub = p.add_subparsers(dest="cmd", required=False)

    s = sub.add_parser("status", help="Show live agent panes and wakeup tasks")
    s.add_argument("--tsv", action="store_true", help="Print TV-friendly TSV")
    s.add_argument("--json", action="store_true", help="Print JSON")
    s.add_argument("--backend", choices=("auto", "tmux", "herdr", "all"), default="auto")
    s.add_argument("--herdr-session", help="Limit Herdr rows to one running session")
    s.set_defaults(func=cmd_status)

    s = sub.add_parser("schedule", help="Schedule a continue for a pane")
    s.add_argument("--pane", help="tmux pane target or pane id")
    s.add_argument("--current", action="store_true", help="Use $HERDR_PANE_ID or $TMUX_PANE")
    s.add_argument("--backend", choices=("auto", "tmux", "herdr"), default="auto")
    s.add_argument("--herdr-session")
    s.add_argument("--agent-session-id", help="Stable Herdr agent session identity")
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
    s.add_argument("--current", action="store_true", help="Use $HERDR_PANE_ID or $TMUX_PANE")
    s.add_argument("--backend", choices=("auto", "tmux", "herdr"), default="auto")
    s.add_argument("--herdr-session")
    s.add_argument("--agent-session-id", help="Stable Herdr agent session identity")
    s.add_argument("--text", default=DEFAULT_TEXT)
    s.add_argument("--enter-only", action="store_true", help="Send only Enter")
    s.add_argument("--auto", action="store_true", help="Choose Enter for rate-limit menus, otherwise continue")
    s.add_argument("--expect-quota", action="store_true")
    s.add_argument("--force", action="store_true")
    s.add_argument("--dry-run", action="store_true")
    s.set_defaults(func=cmd_send_now)

    s = sub.add_parser("cancel", help="Cancel queued wakeups for a pane")
    s.add_argument("--pane", help="tmux pane target or pane id")
    s.add_argument("--current", action="store_true", help="Use $HERDR_PANE_ID or $TMUX_PANE")
    s.add_argument("--backend", choices=("auto", "tmux", "herdr"), default="auto")
    s.add_argument("--herdr-session")
    s.add_argument("--agent-session-id", help="Stable Herdr agent session identity")
    s.set_defaults(func=cmd_cancel)

    s = sub.add_parser("preview", help="Print live pane capture")
    s.add_argument("--pane", required=True)
    s.add_argument("--lines", type=int, default=CAPTURE_LINES)
    s.add_argument("--backend", choices=("tmux", "herdr"), default="tmux")
    s.add_argument("--herdr-session")
    s.set_defaults(func=cmd_preview)

    s = sub.add_parser("focus", help=argparse.SUPPRESS)
    s.add_argument("--pane", required=True)
    s.add_argument("--backend", choices=("tmux", "herdr"), required=True)
    s.add_argument("--herdr-session")
    s.add_argument("--agent-session-id")
    s.set_defaults(func=cmd_focus)

    return p


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not hasattr(args, "func"):
        args = parser.parse_args(["status", *(argv or [])])
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
