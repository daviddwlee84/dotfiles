#!/usr/bin/env python3
"""Unified agent-session enumerator for the `agent-sessions` tv channel.

Walks session storage for OpenCode, Claude Code, Codex, and Cursor and emits
a single TSV stream with stable columns:

  0. agent tag        ([oc] / [cc] / [cx] / [cu] / [ci])
  1. when             (YYYY-MM-DD HH:MM, local time)
  2. session id       (full id; passed to <agent> --resume / --session)
  3. directory        (absolute cwd; "?" when unknown)
  4. title/snippet    (first non-system user message, truncated)

Usage (called from cable/agent-sessions.toml):

  agent-sessions.py all       # all four agents merged
  agent-sessions.py opencode  # opencode-only
  agent-sessions.py claude    # claude-only
  agent-sessions.py codex     # codex-only
  agent-sessions.py cursor    # cursor Agent CLI only
  agent-sessions.py cursor-ide  # Cursor IDE composer chats only

Performance notes:
- Title extraction reads only the first ~80 lines of each JSONL.
- Skips obvious system prepends (AGENTS.md, <local-command-caveat>,
  <system-reminder>, etc.) heuristically — see _is_system_prepend().
- All errors are swallowed silently; missing dirs produce no output.
"""

from __future__ import annotations

import json
import os
import re
import sqlite3
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


def _emit(agent: str, when: str, sid: str, cwd: str, title: str) -> None:
    title = _truncate(title or "(no title)")
    cwd = _compress_home(cwd or "?")
    print(f"{agent}\t{when}\t{sid}\t{cwd}\t{title}")


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
            _emit(
                "[oc]",
                _fmt_when(row["time_updated"]),
                row["id"],
                row["directory"] or "?",
                row["title"] or "",
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
    for _mtime, sid, cwd, title, when in rows:
        _emit("[cc]", when, sid, cwd, title)


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
    for _mtime, sid, cwd, title, when in rows:
        _emit("[cx]", when, sid, cwd, title)


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
    for _mtime, sid, cwd, title, when in rows:
        _emit("[cu]", when, sid, cwd, title)


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
    for _ts, sid, cwd, title, when in rows:
        _emit("[ci]", when, sid, cwd, title)


# ---------------------------------------------------------------------------
# Dispatcher
# ---------------------------------------------------------------------------
def main() -> int:
    mode = sys.argv[1] if len(sys.argv) > 1 else "all"
    handlers = {
        "opencode": [_opencode],
        "claude": [_claude],
        "codex": [_codex],
        "cursor": [_cursor],
        "cursor-ide": [_cursor_ide],
        "all": [_opencode, _claude, _codex, _cursor, _cursor_ide],
    }
    if mode not in handlers:
        print(f"unknown mode: {mode}", file=sys.stderr)
        return 2
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
    return 0


if __name__ == "__main__":
    sys.exit(main())
