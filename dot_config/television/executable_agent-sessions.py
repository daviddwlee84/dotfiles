#!/usr/bin/env python3
"""Unified agent-session enumerator for the `agent-sessions` tv channel.

Walks session storage for OpenCode, Claude Code, Codex, and Cursor and emits
a single TSV stream with stable columns:

  0. agent tag        ([oc] / [cc] / [cx] / [cu] / [ci])
  1. when             (YYYY-MM-DD HH:MM, local time)
  2. session id       (full id; passed to <agent> --resume / --session)
  3. directory        (absolute cwd; "?" when unknown)
  4. title/snippet    (first non-system user message, truncated)
  5. specstory_path   (matching .specstory/history/*.md file, or empty)

In `all` mode rows from every agent are collected into one buffer, sorted
globally by raw mtime DESC, and then printed — otherwise TV sees each
agent's block sorted internally but concatenated, which looks random.

Usage (called from cable/agent-sessions.toml):

  agent-sessions.py all       # all five agents merged, globally sorted
  agent-sessions.py opencode  # opencode-only
  agent-sessions.py claude    # claude-only
  agent-sessions.py codex     # codex-only
  agent-sessions.py cursor    # cursor Agent CLI only
  agent-sessions.py cursor-ide                # Cursor IDE composer chats only
  agent-sessions.py transcript <cc|cx|oc> <sid>  # render full back-and-forth
                                                 # as markdown on stdout.

Column 5 (specstory_path) is produced by grep'ing each file under
$SPECSTORY_HISTORY_DIRS (default: ~/.local/share/chezmoi/.specstory/history)
for `<!-- <Provider> Session <uuid> ... -->` on the first ~10 lines — the
comment SpecStory embeds in every transcript it writes. See
docs/tools/specstory-internals.md for why that line is the reverse-lookup
key.

Performance notes:
- Title extraction reads only the first ~80 lines of each JSONL.
- SpecStory map reads the first ~10 lines per .md file, once per invocation.
- Skips obvious system prepends (AGENTS.md, <local-command-caveat>,
  <system-reminder>, etc.) heuristically — see _is_system_prepend().
- All errors are swallowed silently; missing dirs produce no output.
"""

from __future__ import annotations

import json
import os
import re
import sqlite3
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from typing import Iterator, Optional

HOME = Path.home()
SNIPPET_LEN = 140
MAX_LINES_SCAN = 80  # per JSONL file when hunting first user message

_SYSTEM_PREFIXES = (
    "<local-command-caveat>",
    "<local-command-stdout>",
    "<local-command-stderr>",
    "<system-reminder>",
    "<command-name>",
    "<command-message>",
    "<command-args>",
    "<environment_context>",
    "<user_instructions>",
    "<INSTRUCTIONS>",
    "# AGENTS.md",
    "# AGENTS instructions",
    "Caveat:",
)


def _fmt_when(epoch_ms_or_s: float) -> str:
    """Format epoch (ms or s) as local YYYY-MM-DD HH:MM."""
    if epoch_ms_or_s > 1e12:  # ms
        epoch_ms_or_s /= 1000.0
    try:
        return datetime.fromtimestamp(epoch_ms_or_s).strftime("%Y-%m-%d %H:%M")
    except (OSError, ValueError):
        return "?"


def _fmt_iso(s: str) -> str:
    """Format ISO-8601 string as local YYYY-MM-DD HH:MM."""
    try:
        # Handle trailing Z
        s = s.replace("Z", "+00:00")
        dt = datetime.fromisoformat(s)
        return dt.astimezone().strftime("%Y-%m-%d %H:%M")
    except ValueError:
        return s[:16] if s else "?"


def _truncate(text: str, n: int = SNIPPET_LEN) -> str:
    """Collapse whitespace and truncate."""
    text = re.sub(r"\s+", " ", text).strip()
    if len(text) <= n:
        return text
    return text[: n - 1] + "…"


def _is_system_prepend(text: str) -> bool:
    """Heuristic: skip system-prepended messages so we get the real user prompt."""
    t = text.lstrip()
    return any(t.startswith(p) for p in _SYSTEM_PREFIXES)


_HOME_STR = str(HOME)


def _compress_home(p: str) -> str:
    """Replace leading $HOME with ~ so the display column stays narrow."""
    if not p or p == "?":
        return p or "?"
    if p == _HOME_STR:
        return "~"
    if p.startswith(_HOME_STR + "/"):
        return "~" + p[len(_HOME_STR):]
    return p


# ---------------------------------------------------------------------------
# SpecStory reverse-lookup: session id -> .specstory/history/*.md path.
#
# Every file written by SpecStory embeds a line of the form
#   <!-- <Provider-display-name> Session <uuid> (YYYY-MM-DD HH:MM:SSZ) -->
# on line 5. The UUID matches the agent's own session id, so we can grep
# the first handful of lines of every .md and build a {sid -> path} cache.
# Details: docs/tools/specstory-internals.md.
# ---------------------------------------------------------------------------
_SS_COMMENT_RE = re.compile(
    r"Session ([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})",
    re.IGNORECASE,
)
_SPECSTORY_DEFAULT = HOME / ".local/share/chezmoi/.specstory/history"
_SPECSTORY_MAP: Optional[dict[str, str]] = None


def _specstory_history_dirs() -> list[Path]:
    """Directories to scan for `.specstory/history/*.md` files.

    Override via `SPECSTORY_HISTORY_DIRS` (colon-separated). Default is
    just this repo's checkout, which is where the user's SpecStory is
    currently configured to write.
    """
    raw = os.environ.get("SPECSTORY_HISTORY_DIRS", "")
    if raw:
        out: list[Path] = []
        for p in raw.split(":"):
            p = p.strip()
            if not p:
                continue
            out.append(Path(os.path.expanduser(p)))
        return out
    if _SPECSTORY_DEFAULT.is_dir():
        return [_SPECSTORY_DEFAULT]
    return []


def _load_specstory_map() -> dict[str, str]:
    global _SPECSTORY_MAP
    if _SPECSTORY_MAP is not None:
        return _SPECSTORY_MAP
    m: dict[str, str] = dict()
    for d in _specstory_history_dirs():
        try:
            md_files = list(d.glob("*.md"))
        except OSError:
            continue
        for md in md_files:
            try:
                with md.open("r", encoding="utf-8", errors="replace") as f:
                    for i, line in enumerate(f):
                        if i >= 10:
                            break
                        match = _SS_COMMENT_RE.search(line)
                        if match:
                            # First win is fine — duplicates (same sid, two
                            # .md files) are undocumented edge cases.
                            m.setdefault(match.group(1).lower(), str(md))
                            break
            except OSError:
                continue
    _SPECSTORY_MAP = m
    return m


def _specstory_path(sid: str) -> str:
    if not sid:
        return ""
    return _load_specstory_map().get(sid.lower(), "")


# ---------------------------------------------------------------------------
# Emission buffer. `all` mode collects into _COLLECT so we can sort globally
# by mtime DESC across agents — each handler still sorts locally but the
# block ordering between agents was previously source-order (random-feel).
# ---------------------------------------------------------------------------
_COLLECT: Optional[list] = None


def _emit(agent: str, when: str, sid: str, cwd: str, title: str, ts: float = 0.0) -> None:
    title = _truncate(title or "(no title)")
    cwd = _compress_home(cwd or "?")
    ss = _specstory_path(sid)
    if _COLLECT is not None:
        _COLLECT.append((ts, agent, when, sid, cwd, title, ss))
        return
    print(f"{agent}\t{when}\t{sid}\t{cwd}\t{title}\t{ss}")


# ---------------------------------------------------------------------------
# OpenCode (SQLite)
# ---------------------------------------------------------------------------
def _opencode() -> Iterator[None]:
    db = HOME / ".local/share/opencode/opencode.db"
    if not db.exists():
        return
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        con.row_factory = sqlite3.Row
        cur = con.execute(
            """
            SELECT id, directory, title, time_updated
            FROM session
            WHERE time_archived IS NULL
            ORDER BY time_updated DESC
            """
        )
        for row in cur:
            tu = row["time_updated"] or 0
            ts_s = (tu / 1000.0) if tu > 1e12 else float(tu)
            _emit(
                "[oc]",
                _fmt_when(tu),
                row["id"],
                row["directory"] or "?",
                row["title"] or "",
                ts=ts_s,
            )
        con.close()
    except sqlite3.Error:
        pass
    yield  # generator marker


# ---------------------------------------------------------------------------
# Claude Code (JSONL per session under ~/.claude/projects/<flat-cwd>/)
# ---------------------------------------------------------------------------
def _claude_first_user_msg(path: Path) -> tuple[str, str]:
    """Return (cwd, first-non-system-user-message)."""
    cwd = ""
    title = ""
    try:
        with path.open("r", encoding="utf-8", errors="replace") as f:
            for i, line in enumerate(f):
                if i >= MAX_LINES_SCAN:
                    break
                try:
                    d = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not cwd and d.get("cwd"):
                    cwd = d["cwd"]
                if title:
                    continue
                if d.get("type") != "user":
                    continue
                msg = d.get("message")
                if not isinstance(msg, dict):
                    continue
                content = msg.get("content")
                text = ""
                if isinstance(content, str):
                    text = content
                elif isinstance(content, list):
                    for part in content:
                        if isinstance(part, dict) and part.get("type") == "text":
                            text = part.get("text", "")
                            break
                if text and not _is_system_prepend(text):
                    title = text
    except OSError:
        pass
    return cwd, title


def _claude() -> None:
    root = HOME / ".claude/projects"
    if not root.is_dir():
        return
    rows: list[tuple[float, str, str, str, str]] = []
    for jsonl in root.rglob("*.jsonl"):
        # Skip subagent traces — they aren't resumable as standalone sessions.
        if "/subagents/" in str(jsonl):
            continue
        try:
            mtime = jsonl.stat().st_mtime
        except OSError:
            continue
        sid = jsonl.stem  # filename is the sessionId UUID
        cwd, title = _claude_first_user_msg(jsonl)
        rows.append((mtime, sid, cwd, title, _fmt_when(mtime)))
    rows.sort(key=lambda r: r[0], reverse=True)
    for mtime, sid, cwd, title, when in rows:
        _emit("[cc]", when, sid, cwd, title, ts=mtime)


# ---------------------------------------------------------------------------
# Codex (~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl)
# ---------------------------------------------------------------------------
def _codex_meta(path: Path) -> tuple[str, str, str]:
    """Return (sid, cwd, title-or-first-user-msg)."""
    sid = ""
    cwd = ""
    thread_name = ""
    title = ""
    try:
        with path.open("r", encoding="utf-8", errors="replace") as f:
            for i, line in enumerate(f):
                if i >= MAX_LINES_SCAN:
                    break
                try:
                    d = json.loads(line)
                except json.JSONDecodeError:
                    continue
                t = d.get("type")
                payload = d.get("payload") or {}
                if t == "session_meta":
                    if not sid:
                        sid = payload.get("id", "")
                    if not cwd:
                        cwd = payload.get("cwd", "")
                    if not thread_name:
                        thread_name = payload.get("thread_name", "") or ""
                elif t == "response_item" and not title:
                    if payload.get("type") == "message" and payload.get("role") == "user":
                        for c in payload.get("content", []):
                            if isinstance(c, dict) and c.get("type") in ("input_text", "text"):
                                txt = c.get("text", "")
                                if txt and not _is_system_prepend(txt):
                                    title = txt
                                    break
    except OSError:
        pass
    return sid, cwd, thread_name or title


def _codex() -> None:
    root = HOME / ".codex/sessions"
    if not root.is_dir():
        return
    # Build thread_name lookup from session_index.jsonl (newer Codex writes this).
    index_titles: dict[str, str] = {}
    idx = HOME / ".codex/session_index.jsonl"
    if idx.is_file():
        try:
            with idx.open("r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    try:
                        d = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if d.get("id") and d.get("thread_name"):
                        index_titles[d["id"]] = d["thread_name"]
        except OSError:
            pass

    rows: list[tuple[float, str, str, str, str]] = []
    for jsonl in root.rglob("rollout-*.jsonl"):
        try:
            mtime = jsonl.stat().st_mtime
        except OSError:
            continue
        sid, cwd, title = _codex_meta(jsonl)
        if not sid:
            # Fallback: extract UUID from filename.
            m = re.search(r"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})", jsonl.name)
            sid = m.group(1) if m else jsonl.stem
        if sid in index_titles:
            title = index_titles[sid]
        rows.append((mtime, sid, cwd, title, _fmt_when(mtime)))
    rows.sort(key=lambda r: r[0], reverse=True)
    for mtime, sid, cwd, title, when in rows:
        _emit("[cx]", when, sid, cwd, title, ts=mtime)


# ---------------------------------------------------------------------------
# Cursor (~/.cursor/chats/<wsHash>/<chatId>/store.db)
#
# store.db schema is { blobs(id, data BLOB), meta(key, value) } — chat content
# lives in opaque binary blobs, so we cannot extract titles. We surface
# wsHash/chatId + mtime; resume via `cursor-agent --resume <chatId>`.
# ---------------------------------------------------------------------------
def _cursor_workspace_path(ws_hash: str) -> Optional[str]:
    """Try to map a Cursor wsHash -> workspace folder via VSCode-style state."""
    # Cursor's workspaceStorage is at ~/Library/Application Support/Cursor/User/...
    candidates = [
        HOME / "Library/Application Support/Cursor/User/workspaceStorage" / ws_hash / "workspace.json",
        HOME / ".config/Cursor/User/workspaceStorage" / ws_hash / "workspace.json",
    ]
    for c in candidates:
        if c.is_file():
            try:
                d = json.loads(c.read_text(encoding="utf-8", errors="replace"))
                folder = d.get("folder") or d.get("workspace") or ""
                if folder.startswith("file://"):
                    folder = folder[7:]
                return folder or None
            except (OSError, json.JSONDecodeError):
                continue
    return None


def _cursor_chat_meta(db_path: Path) -> tuple[str, str]:
    """Return (chat_name, latest_root_blob_id) by reading meta table."""
    name = ""
    root_blob = ""
    try:
        con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        cur = con.execute("SELECT value FROM meta LIMIT 1")
        row = cur.fetchone()
        con.close()
        if row and row[0]:
            raw = row[0]
            # Value is a hex-encoded JSON string (per Cursor's storage format).
            if isinstance(raw, (bytes, bytearray)):
                try:
                    text = bytes(raw).decode("utf-8", errors="replace")
                except Exception:
                    text = ""
            else:
                text = str(raw)
            # Try hex decode first (the common case).
            try:
                text = bytes.fromhex(text).decode("utf-8", errors="replace")
            except ValueError:
                pass  # already plain text
            try:
                d = json.loads(text)
                name = d.get("name", "") or ""
                root_blob = d.get("latestRootBlobId", "") or ""
            except (json.JSONDecodeError, AttributeError):
                pass
    except sqlite3.Error:
        pass
    return name, root_blob


def _cursor() -> None:
    root = HOME / ".cursor/chats"
    if not root.is_dir():
        return
    # Cache wsHash -> path lookups.
    ws_cache: dict[str, Optional[str]] = {}
    rows: list[tuple[float, str, str, str, str]] = []
    for db in root.glob("*/*/store.db"):
        try:
            mtime = db.stat().st_mtime
        except OSError:
            continue
        chat_id = db.parent.name
        ws_hash = db.parent.parent.name
        if ws_hash not in ws_cache:
            ws_cache[ws_hash] = _cursor_workspace_path(ws_hash)
        cwd = ws_cache[ws_hash] or f"<ws:{ws_hash[:8]}>"
        title, _ = _cursor_chat_meta(db)
        if not title:
            title = "(cursor chat)"
        rows.append((mtime, chat_id, cwd, title, _fmt_when(mtime)))
    rows.sort(key=lambda r: r[0], reverse=True)
    for mtime, sid, cwd, title, when in rows:
        _emit("[cu]", when, sid, cwd, title, ts=mtime)


# ---------------------------------------------------------------------------
# Cursor IDE composer chats
#
# Storage model (reverse-engineered):
#   ~/Library/Application Support/Cursor/User/
#     globalStorage/state.vscdb              (one giant cursorDiskKV table)
#       composerData:<composerId>            -> {name, createdAt, lastUpdatedAt,
#                                                subtitle, unifiedMode,
#                                                fullConversationHeadersOnly: [...]}
#       bubbleId:<composerId>:<bubbleId>     -> {type:1=user|2=assistant, text, ...}
#     workspaceStorage/<wsHash>/
#       workspace.json                       -> {folder: "file:///..." or "vscode-remote://..."}
#       state.vscdb                          (per-workspace ItemTable)
#         composer.composerData              -> {allComposers: [{composerId, name, ...}]}
#
# We iterate every workspace's allComposers list to get composerId -> wsHash mapping
# (so we can show the project folder), then emit one row per composer. The IDE
# offers no CLI resume flag, so the action is "open the workspace folder in
# Cursor" + "copy composerId to clipboard".
# ---------------------------------------------------------------------------
def _cursor_ide_workspaces() -> dict[str, tuple[str, str, dict]]:
    """Map composerId -> (wsHash, folder_uri, allComposers_entry)."""
    ws_root = HOME / "Library/Application Support/Cursor/User/workspaceStorage"
    if not ws_root.is_dir():
        ws_root = HOME / ".config/Cursor/User/workspaceStorage"
    if not ws_root.is_dir():
        return dict()
    out: dict[str, tuple[str, str, dict]] = dict()
    for d in ws_root.iterdir():
        if not d.is_dir():
            continue
        ws_hash = d.name
        # Get folder URI.
        folder = ""
        wj = d / "workspace.json"
        if wj.is_file():
            try:
                folder = json.loads(wj.read_text(encoding="utf-8", errors="replace")).get("folder", "") or ""
            except (OSError, json.JSONDecodeError):
                pass
        # Get composer list.
        db = d / "state.vscdb"
        if not db.is_file():
            continue
        try:
            con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
            row = con.execute(
                "SELECT value FROM ItemTable WHERE key = 'composer.composerData'"
            ).fetchone()
            con.close()
            if not row or not row[0]:
                continue
            data = json.loads(row[0])
            for entry in data.get("allComposers", []):
                cid = entry.get("composerId")
                if cid:
                    out[cid] = (ws_hash, folder, entry)
        except (sqlite3.Error, json.JSONDecodeError):
            continue
    return out


def _cursor_ide_first_user_msg(global_db: sqlite3.Connection, composer_id: str) -> str:
    """Read composerData entry for first non-system user bubble text."""
    try:
        row = global_db.execute(
            "SELECT value FROM cursorDiskKV WHERE key = ?",
            (f"composerData:{composer_id}",),
        ).fetchone()
        if not row or not row[0]:
            return ""
        d = json.loads(row[0])
        heads = d.get("fullConversationHeadersOnly") or []
        for h in heads:
            if h.get("type") != 1:  # 1 = user
                continue
            bid = h.get("bubbleId")
            if not bid:
                continue
            brow = global_db.execute(
                "SELECT value FROM cursorDiskKV WHERE key = ?",
                (f"bubbleId:{composer_id}:{bid}",),
            ).fetchone()
            if not brow or not brow[0]:
                continue
            try:
                bd = json.loads(brow[0])
            except json.JSONDecodeError:
                continue
            txt = bd.get("text") or ""
            if txt and not _is_system_prepend(txt):
                return txt
    except sqlite3.Error:
        pass
    return ""


def _cursor_ide_folder_to_path(folder_uri: str) -> str:
    """Convert a workspace folder URI to a display path."""
    if not folder_uri:
        return "?"
    if folder_uri.startswith("file://"):
        return folder_uri[7:]
    if folder_uri.startswith("vscode-remote://"):
        # e.g. vscode-remote://ssh-remote%2Bhost/path
        return folder_uri  # keep as-is so user can see it's a remote
    return folder_uri


def _cursor_ide() -> None:
    global_db_path = HOME / "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    if not global_db_path.is_file():
        global_db_path = HOME / ".config/Cursor/User/globalStorage/state.vscdb"
    if not global_db_path.is_file():
        return
    composers = _cursor_ide_workspaces()
    if not composers:
        return
    try:
        gdb = sqlite3.connect(f"file:{global_db_path}?mode=ro", uri=True)
    except sqlite3.Error:
        return
    rows: list[tuple[float, str, str, str, str]] = []
    for cid, (_ws_hash, folder, entry) in composers.items():
        ts = entry.get("lastUpdatedAt") or entry.get("createdAt") or 0
        when = _fmt_when(ts) if ts else "?"
        cwd = _cursor_ide_folder_to_path(folder)
        title = entry.get("name") or ""
        if not title:
            # Fall back to first user bubble.
            title = _cursor_ide_first_user_msg(gdb, cid)
        if not title:
            # Skip empty/abandoned composers (no name, no bubbles).
            continue
        rows.append((float(ts) / 1000.0 if ts > 1e12 else float(ts), cid, cwd, title, when))
    gdb.close()
    rows.sort(key=lambda r: r[0], reverse=True)
    for ts, sid, cwd, title, when in rows:
        _emit("[ci]", when, sid, cwd, title, ts=ts)


# ---------------------------------------------------------------------------
# Transcript rendering — full back-and-forth as markdown on stdout.
#
# Prefer SpecStory's pre-rendered `.specstory/history/*.md` when the session
# has been synced (matches what the user sees on disk, zero-parsing). Fall
# back to a raw-source walk for live / un-synced sessions.
# ---------------------------------------------------------------------------
def _render_turn(role: str, text: str, ts: str = "", model: str = "") -> None:
    header = f"## {role}"
    if model:
        header += f" — `{model}`"
    if ts:
        header += f"  *({ts})*"
    print(header)
    print()
    print(text.rstrip())
    print()
    print("---")
    print()


def _transcript_claude(sid: str) -> None:
    root = HOME / ".claude/projects"
    if not root.is_dir():
        print("(~/.claude/projects not found)")
        return
    path: Optional[Path] = None
    for p in root.rglob(f"{sid}.jsonl"):
        if "/subagents/" in str(p):
            continue
        path = p
        break
    if path is None:
        print(f"(Claude session `{sid}` not found)")
        return
    print(f"# Claude Code session  `{sid}`")
    print()
    print(f"*file*: `{path}`")
    print()
    print("---")
    print()
    try:
        with path.open("r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    d = json.loads(line)
                except json.JSONDecodeError:
                    continue
                t = d.get("type")
                if t not in ("user", "assistant"):
                    continue
                msg = d.get("message") or dict()
                content = msg.get("content")
                parts: list[str] = []
                if isinstance(content, str):
                    parts.append(content)
                elif isinstance(content, list):
                    for part in content:
                        if not isinstance(part, dict):
                            continue
                        pt = part.get("type")
                        if pt == "text":
                            parts.append(part.get("text", "") or "")
                        elif pt == "tool_use":
                            name = part.get("name", "?")
                            parts.append(f"\n> *tool_use: `{name}`*")
                        elif pt == "tool_result":
                            tr = part.get("content", "")
                            if isinstance(tr, list):
                                tr = " ".join(
                                    (c.get("text", "") or "")
                                    for c in tr
                                    if isinstance(c, dict) and c.get("type") == "text"
                                )
                            tr = str(tr or "")
                            tr = re.sub(r"\s+", " ", tr)[:500]
                            parts.append(f"\n> *tool_result*: {tr}")
                text = "\n".join(p for p in parts if p).strip()
                if not text:
                    continue
                if t == "user" and _is_system_prepend(text):
                    continue
                role = "User" if t == "user" else "Agent"
                model = msg.get("model", "") if t == "assistant" else ""
                _render_turn(role, text, ts=d.get("timestamp", "") or "", model=model)
    except OSError as e:
        print(f"(error reading session file: {e})")


def _transcript_codex(sid: str) -> None:
    root = HOME / ".codex/sessions"
    if not root.is_dir():
        print("(~/.codex/sessions not found)")
        return
    path: Optional[Path] = None
    for p in root.rglob(f"rollout-*{sid}*.jsonl"):
        path = p
        break
    if path is None:
        print(f"(Codex session `{sid}` not found under ~/.codex/sessions)")
        return
    print(f"# Codex session  `{sid}`")
    print()
    print(f"*file*: `{path}`")
    print()
    print("---")
    print()
    try:
        with path.open("r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    d = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if d.get("type") != "response_item":
                    continue
                payload = d.get("payload") or dict()
                if payload.get("type") != "message":
                    continue
                role = payload.get("role")
                if role not in ("user", "assistant"):
                    continue
                texts: list[str] = []
                for c in payload.get("content", []) or []:
                    if not isinstance(c, dict):
                        continue
                    if c.get("type") in ("input_text", "text", "output_text"):
                        texts.append(c.get("text", "") or "")
                text = "\n".join(t for t in texts if t).strip()
                if not text:
                    continue
                if role == "user" and _is_system_prepend(text):
                    continue
                ts = d.get("timestamp", "") or payload.get("timestamp", "") or ""
                _render_turn("User" if role == "user" else "Agent", text, ts=ts)
    except OSError as e:
        print(f"(error reading session file: {e})")


def _transcript_opencode(sid: str) -> None:
    db = HOME / ".local/share/opencode/opencode.db"
    if not db.exists():
        print("(~/.local/share/opencode/opencode.db not found)")
        return
    print(f"# OpenCode session  `{sid}`")
    print()
    print(f"*db*: `{db}`")
    print()
    print("---")
    print()
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        cur = con.execute(
            """
            SELECT m.data, p.data, p.time_created
            FROM part p JOIN message m ON p.message_id = m.id
            WHERE p.session_id = ?
              AND json_extract(p.data, '$.type') = 'text'
            ORDER BY p.time_created ASC
            """,
            (sid,),
        )
        had_row = False
        for m_data, p_data, tc in cur:
            had_row = True
            try:
                m = json.loads(m_data)
            except (json.JSONDecodeError, TypeError):
                m = dict()
            try:
                p = json.loads(p_data)
            except (json.JSONDecodeError, TypeError):
                p = dict()
            role = m.get("role")
            if role not in ("user", "assistant"):
                continue
            text = p.get("text") or ""
            if not text:
                continue
            if role == "user" and _is_system_prepend(text):
                continue
            ts = _fmt_when(tc) if tc else ""
            _render_turn("User" if role == "user" else "Agent", text, ts=ts)
        con.close()
        if not had_row:
            print(f"(no parts found for session `{sid}`)")
    except sqlite3.Error as e:
        print(f"(opencode SQL error: {e})")


def _transcript(tag: str, sid: str) -> None:
    # Prefer SpecStory's pre-rendered markdown when available — matches what
    # the user sees on disk and handles providers we can't re-render locally.
    ss = _specstory_path(sid)
    if ss:
        try:
            sys.stdout.write(Path(ss).read_text(encoding="utf-8", errors="replace"))
            return
        except OSError:
            # Fall through to raw-source rendering.
            pass
    if tag in ("cc", "[cc]"):
        _transcript_claude(sid)
    elif tag in ("cx", "[cx]"):
        _transcript_codex(sid)
    elif tag in ("oc", "[oc]"):
        _transcript_opencode(sid)
    else:
        print(f"# session `{sid}`")
        print()
        print(
            f"_Transcript rendering is not yet supported for agent tag `{tag}`_"
            " — see the legacy preview cycle (`Ctrl+F`) for first-5 user"
            " messages, or `Alt+E` to open the raw source."
        )


# ---------------------------------------------------------------------------
# Live tmux pane discovery (`panes` mode)
#
# Cross-references `tmux list-panes -aF` with running agent processes:
#
#   1. Claude — read `~/.claude/sessions/{claude_pid}.json` for each file
#      Claude writes per process. The JSON has `sessionId`, `cwd`, `status`
#      ("busy"/"idle"), and an optional `name` — authoritative. Walk parent
#      chain from claude_pid to find the owning tmux pane (claude usually
#      runs as a grandchild of the pane shell, e.g. via specstory wrapper).
#
#   2. Codex/OpenCode/Cursor-Agent — `pgrep -x <bin>` to find running
#      processes; walk parent chain to map to a pane. Cross-reference cwd
#      against storage (opencode.db / .codex/sessions / .cursor/chats)
#      for the most recent matching session — best-effort, may be wrong if
#      multiple sessions share a cwd, but the row is still useful for
#      jump-to-pane.
#
# Output: 9-col TSV (extends the 6-col schema with pane_target / pane_pid /
# status). Consumed by `cable/agent-panes.toml`.
# ---------------------------------------------------------------------------

# Per-agent detection.
# - "binary":      `pgrep -x <name>` — process is a standalone executable.
# - "node-wrapped": some agents ship as Node/Bun scripts; `comm` shows as
#                  `node`/`bun`/`deno`. We scan argv for `/<package-name>`
#                  to anchor it as a path component (avoids matching
#                  `vim cursor-agent.md`-style false positives).
# Aider / goose intentionally omitted for v1 — easy to add later.
_AGENT_DETECTORS = (
    # (mode, needle, tag)
    ("binary", "claude", "[cc]"),  # informational — Claude is fully resolved
                                   # earlier via ~/.claude/sessions/*.json
    ("binary", "codex", "[cx]"),
    ("binary", "opencode", "[oc]"),
    ("binary", "cursor-agent", "[cu]"),
    ("node-wrapped", "cursor-agent", "[cu]"),  # Cursor Agent CLI is shipped
                                               # as a Node script in practice.
    ("node-wrapped", "opencode", "[oc]"),      # belt-and-braces; OpenCode
                                               # ships native today but the
                                               # extra cost is one ps call.
)

_PANE_FORMAT = "\t".join(
    [
        "#{session_name}",
        "#{window_index}",
        "#{window_name}",
        "#{pane_index}",
        "#{pane_id}",
        "#{pane_pid}",
        "#{pane_current_command}",
        "#{pane_current_path}",
        "#{pane_active}",
    ]
)


def _list_tmux_panes() -> list[dict]:
    """Snapshot all tmux panes across all sessions. Empty list if no server."""
    try:
        out = subprocess.check_output(
            ["tmux", "list-panes", "-aF", _PANE_FORMAT],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return []
    panes: list[dict] = []
    for line in out.splitlines():
        cols = line.split("\t")
        if len(cols) != 9:
            continue
        try:
            pid = int(cols[5])
        except ValueError:
            continue
        panes.append(
            {
                "session": cols[0],
                "window_index": cols[1],
                "window_name": cols[2],
                "pane_index": cols[3],
                "pane_id": cols[4],
                "pane_pid": pid,
                "pane_cmd": cols[6],
                "pane_cwd": cols[7],
                "pane_active": cols[8] == "1",
                "target": f"{cols[0]}:{cols[1]}.{cols[3]}",
            }
        )
    return panes


def _get_ppid(pid: int) -> Optional[int]:
    """Return parent PID of `pid`, or None if process gone / lookup failed."""
    try:
        out = subprocess.check_output(
            ["ps", "-o", "ppid=", "-p", str(pid)],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        return int(out) if out else None
    except (subprocess.CalledProcessError, ValueError):
        return None


def _find_pane_for_pid(pid: int, pane_pids: dict[int, dict]) -> Optional[dict]:
    """Walk parent chain from `pid` until we hit a tmux pane_pid. None if root."""
    cur = pid
    for _ in range(20):  # cap chain depth to avoid pathological loops
        if cur in pane_pids:
            return pane_pids[cur]
        ppid = _get_ppid(cur)
        if ppid is None or ppid <= 1 or ppid == cur:
            return None
        cur = ppid
    return None


def _pgrep_x(name: str) -> list[int]:
    """Return PIDs whose process name (comm) exactly matches `name`."""
    try:
        out = subprocess.check_output(
            ["pgrep", "-x", name],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return []
    return [int(p) for p in out.split() if p.isdigit()]


def _proc_start_ts(pid: int) -> float:
    """Return process start time as local epoch seconds, or 0.0 if unknown.

    Used to filter cwd-based session lookups to "rollouts that exist after
    this agent process began" — without this, a brand-new Codex/OpenCode/
    Cursor session in a cwd that has older session history would show the
    OLD session's title (the resolver picks the most-recent storage entry
    in cwd, which is unrelated to the just-started process).
    """
    try:
        out = subprocess.check_output(
            ["ps", "-o", "lstart=", "-p", str(pid)],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return 0.0
    if not out:
        return 0.0
    # `ps -o lstart=` format on macOS/BSD: "Mon Apr 27 10:05:56 2026".
    # Linux outputs the same format under coreutils/procps when locale is C.
    for fmt in ("%a %b %d %H:%M:%S %Y", "%a %b  %d %H:%M:%S %Y"):
        try:
            return datetime.strptime(out, fmt).timestamp()
        except ValueError:
            continue
    return 0.0


def _find_node_wrapped_pids(needle: str) -> list[int]:
    """Find PIDs of Node/Bun/Deno-wrapped CLIs by path-anchored argv match.

    `needle` should be the CLI's package name (e.g. "cursor-agent"); we
    search for `/<needle>` in argv to anchor it as a path component, so
    `vim cursor-agent.md` doesn't false-positive.
    """
    try:
        out = subprocess.check_output(
            ["ps", "-axo", "pid=,comm=,args="],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return []
    pids: list[int] = []
    anchor = "/" + needle
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) < 3:
            continue
        try:
            pid = int(parts[0])
        except ValueError:
            continue
        comm = parts[1]
        args = parts[2]
        if comm in ("node", "bun", "deno") and anchor in args:
            pids.append(pid)
    return pids


# --- Storage cross-reference: best-effort cwd-based session lookup ---
# Used for codex / opencode / cursor — Claude already gives us authoritative
# session_id from its per-PID JSON, so it doesn't need this.


def _opencode_session_for_cwd(cwd: str, since_ts: float = 0.0) -> tuple[str, float, str]:
    """Most-recent OpenCode session matching cwd AND newer than `since_ts`.

    Returns (sid, mtime_s, title). When `since_ts > 0` (agent process start
    time), older sessions are skipped — prevents a brand-new agent in a cwd
    with prior session history from showing the OLD session's title.
    """
    db = HOME / ".local/share/opencode/opencode.db"
    if not db.exists() or not cwd:
        return ("", 0.0, "")
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        cur = con.execute(
            """
            SELECT id, title, time_updated
            FROM session
            WHERE directory = ? AND time_archived IS NULL
            ORDER BY time_updated DESC
            LIMIT 1
            """,
            (cwd,),
        )
        row = cur.fetchone()
        con.close()
        if row:
            sid, title, tu = row
            ts = (tu / 1000.0) if tu and tu > 1e12 else float(tu or 0)
            if since_ts and ts < since_ts:
                # Most recent stored session pre-dates this process — must
                # be a fresh session that hasn't been written yet.
                return ("", 0.0, "")
            return (sid or "", ts, title or "")
    except sqlite3.Error:
        pass
    return ("", 0.0, "")


def _codex_session_for_cwd(cwd: str, since_ts: float = 0.0) -> tuple[str, float, str]:
    """Most-recent Codex rollout in cwd AND newer than `since_ts`.

    See _opencode_session_for_cwd for the `since_ts` rationale.
    """
    root = HOME / ".codex/sessions"
    if not root.is_dir() or not cwd:
        return ("", 0.0, "")
    best: tuple[float, str, str] = (0.0, "", "")
    # Don't scan all of history — limit to last 7 days (one dir per day).
    cutoff = datetime.now().timestamp() - 7 * 86400
    floor = max(cutoff, since_ts)
    for jsonl in root.rglob("rollout-*.jsonl"):
        try:
            mtime = jsonl.stat().st_mtime
        except OSError:
            continue
        if mtime < floor or mtime <= best[0]:
            continue
        sid, scwd, title = _codex_meta(jsonl)
        if scwd != cwd:
            continue
        if not sid:
            m = re.search(
                r"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})",
                jsonl.name,
            )
            sid = m.group(1) if m else jsonl.stem
        best = (mtime, sid, title)
    return (best[1], best[0], best[2])


def _cursor_session_for_cwd(cwd: str, since_ts: float = 0.0) -> tuple[str, float, str]:
    """Most-recent Cursor Agent CLI chat in cwd AND newer than `since_ts`."""
    root = HOME / ".cursor/chats"
    if not root.is_dir() or not cwd:
        return ("", 0.0, "")
    best: tuple[float, str] = (0.0, "")
    for db in root.glob("*/*/store.db"):
        try:
            mtime = db.stat().st_mtime
        except OSError:
            continue
        if mtime <= best[0] or (since_ts and mtime < since_ts):
            continue
        ws_hash = db.parent.parent.name
        folder = _cursor_workspace_path(ws_hash)
        if folder and folder == cwd:
            best = (mtime, db.parent.name)  # chat_id = parent dir name
    return (best[1], best[0], "")


_STATUS_GLYPH = {"busy": "●", "idle": "○"}

# Group rows by agent type in the picker (Claude → Codex → OpenCode → Cursor).
# Within each group rows are sorted most-recent-first. The visual grouping
# helps the eye when there are many panes; the prefix glyph is also
# meaningful only inside the [cc] block (Claude exposes status; others don't).
_AGENT_SORT_PRIORITY = {"[cc]": 0, "[cx]": 1, "[oc]": 2, "[cu]": 3}


def _build_pane_row(
    agent: str,
    sid: str,
    pane: dict,
    when_ts: float,
    title: str,
    status: str,
) -> tuple[int, float, str]:
    """Return (agent_priority, neg_when_ts, tsv_line) for the 9-col schema.

    Column 8 is the pre-rendered status glyph (●/○/empty) — TV's display
    template can't do per-column substitution, and any unrecognised syntax
    silently breaks all `{split:}` placeholders in the same string. So we
    map status here.

    The sort key bundles agent priority + negative timestamp so a plain
    `rows.sort()` gives "Claude block (newest first), then Codex, then
    OpenCode, then Cursor".
    """
    cwd = _compress_home(pane["pane_cwd"] or "?")
    title = _truncate(title or "")
    ss = _specstory_path(sid) if sid else ""
    when = _fmt_when(when_ts) if when_ts else ""
    label = f"{pane['session']}:{pane['window_index']}.{pane['pane_index']}"
    glyph = _STATUS_GLYPH.get(status, "")
    line = (
        f"{agent}\t{when}\t{sid}\t{cwd}\t{title}\t{ss}"
        f"\t{label}\t{pane['pane_pid']}\t{glyph}"
    )
    priority = _AGENT_SORT_PRIORITY.get(agent, 99)
    return (priority, -when_ts, line)


def _panes() -> None:
    """Enumerate live tmux panes that have a coding-agent process inside."""
    panes = _list_tmux_panes()
    if not panes:
        return
    pane_pids: dict[int, dict] = {p["pane_pid"]: p for p in panes}

    rows: list[tuple[float, str]] = []
    # Dedupe: one pane_id should not emit twice even if multiple agent
    # processes (e.g. worker children) live inside it.
    seen: set[str] = set()

    # ---- Claude: authoritative per-PID JSON files ----
    cc_dir = HOME / ".claude/sessions"
    if cc_dir.is_dir():
        for f in cc_dir.glob("*.json"):
            try:
                claude_pid = int(f.stem)
            except ValueError:
                continue
            try:
                data = json.loads(f.read_text(encoding="utf-8", errors="replace"))
            except (OSError, json.JSONDecodeError):
                continue
            if not isinstance(data, dict):
                continue
            pane = _find_pane_for_pid(claude_pid, pane_pids)
            if pane is None:
                # Stale PID file (process gone) or claude running outside tmux.
                continue
            sid = str(data.get("sessionId") or "")
            key = f"{pane['pane_id']}|cc|{sid}"
            if key in seen:
                continue
            seen.add(key)
            name = str(data.get("name") or "")
            status = str(data.get("status") or "")
            updated = data.get("updatedAt") or data.get("startedAt") or 0
            try:
                when_ts = (
                    float(updated) / 1000.0
                    if updated and updated > 1e12
                    else float(updated or 0)
                )
            except (TypeError, ValueError):
                when_ts = 0.0
            # Prefer Claude's own session name; fall back to first user message.
            title = name
            if not title and sid:
                jsonl = next(
                    (HOME / ".claude/projects").rglob(f"{sid}.jsonl"), None
                )
                if jsonl:
                    _, title = _claude_first_user_msg(jsonl)
            rows.append(_build_pane_row("[cc]", sid, pane, when_ts, title, status))

    # ---- Other agents: pgrep / argv scan + storage cross-reference ----
    # Claude is already resolved above via authoritative ~/.claude/sessions
    # files; the [cc] entry in _AGENT_DETECTORS is informational only and
    # gets short-circuited here so we don't double-count.
    for mode, needle, tag in _AGENT_DETECTORS:
        if tag == "[cc]":
            continue
        if mode == "binary":
            agent_pids = _pgrep_x(needle)
        elif mode == "node-wrapped":
            agent_pids = _find_node_wrapped_pids(needle)
        else:
            agent_pids = []
        for agent_pid in agent_pids:
            pane = _find_pane_for_pid(agent_pid, pane_pids)
            if pane is None:
                continue
            cwd = pane["pane_cwd"]
            # Floor cwd-based reverse-lookups at the agent process's start
            # time. Without this, a brand-new session in a cwd that has
            # older session history would inherit the OLD session's title.
            since_ts = _proc_start_ts(agent_pid)
            if tag == "[oc]":
                sid, ts, title = _opencode_session_for_cwd(cwd, since_ts)
            elif tag == "[cx]":
                sid, ts, title = _codex_session_for_cwd(cwd, since_ts)
            elif tag == "[cu]":
                sid, ts, title = _cursor_session_for_cwd(cwd, since_ts)
            else:
                sid, ts, title = ("", 0.0, "")
            # Dedupe by pane — a single pane may match multiple detectors
            # (e.g. cursor-agent matches both binary and node-wrapped probes
            # on hosts that have a thin native shim wrapping the Node app).
            key = f"{pane['pane_id']}|{tag[1:3]}"
            if key in seen:
                continue
            seen.add(key)
            rows.append(_build_pane_row(tag, sid, pane, ts, title, ""))

    # Group by agent (cc → cx → oc → cu), most-recent-first within each group.
    rows.sort()
    for _priority, _neg_ts, line in rows:
        print(line)


# ---------------------------------------------------------------------------
# Dispatcher
# ---------------------------------------------------------------------------
def main() -> int:
    mode = sys.argv[1] if len(sys.argv) > 1 else "all"

    if mode == "transcript":
        if len(sys.argv) < 4:
            print(
                "usage: agent-sessions.py transcript <cc|cx|oc> <sid>",
                file=sys.stderr,
            )
            return 2
        _transcript(sys.argv[2], sys.argv[3])
        return 0

    handlers = {
        "opencode": [_opencode],
        "claude": [_claude],
        "codex": [_codex],
        "cursor": [_cursor],
        "cursor-ide": [_cursor_ide],
        "all": [_opencode, _claude, _codex, _cursor, _cursor_ide],
        "panes": [_panes],
    }
    if mode not in handlers:
        print(f"unknown mode: {mode}", file=sys.stderr)
        return 2

    global _COLLECT
    collect = mode == "all"
    if collect:
        _COLLECT = []

    for fn in handlers[mode]:
        try:
            result = fn()
            # _opencode is a generator; consume it.
            if result is not None:
                for _ in result:
                    pass
        except Exception as e:
            # Never crash the channel.
            print(f"(error in {fn.__name__}: {e})", file=sys.stderr)

    if collect and _COLLECT is not None:
        buffer = _COLLECT
        _COLLECT = None  # restore normal emit path for any stragglers
        buffer.sort(key=lambda r: r[0], reverse=True)
        for _ts, agent, when, sid, cwd, title, ss in buffer:
            print(f"{agent}\t{when}\t{sid}\t{cwd}\t{title}\t{ss}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
