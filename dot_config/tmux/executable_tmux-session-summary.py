#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "rich>=13.9",
# ]
# ///
"""tmux-session-summary — AI-powered overview of every tmux session.

Subcommands:
  list      Human-readable summary, one block per session (default).
  picker    TSV `<session>\\t<one-line>` for fzf. Used by `tsum -i` and the
            tmux popup menu entry.

Flags:
  -d, --deep        Include the visible area (20-100 lines) of each session's
                    active pane in the LLM prompt. More context, more tokens,
                    may include scrollback content. Self-capture is skipped
                    automatically (the pane running tsum is excluded).
  --shallow         Force metadata-only mode (overrides TSUM_DEEP_DEFAULT).
  -r, --refresh     Bypass the 10-min cache; force a fresh LLM call.
  --dry-run         Print the constructed prompt to stdout and exit (no API
                    call). Lets you audit what would be sent.
  --no-cache        Don't read or write the cache (one-off invocation).
  --sort {alpha,closability}
                    alpha (default): tmux's natural order (alphabetical).
                    closability: keep → check → safe, so active work surfaces
                    first.
  --only {safe,check,keep}
                    Filter to one tier only. Combine with picker mode to bulk
                    inspect candidates: `tsum picker --only safe | fzf -m`.

Deep-by-default:
  Set `TSUM_DEEP_DEFAULT=1` (e.g. in ~/.shellrc.adhoc) to make --deep implicit;
  override per-invocation with --shallow. CLI flags always win over the env
  var: --deep beats --shallow beats TSUM_DEEP_DEFAULT beats metadata-only.

Env vars (mirrors dot_config/zsh/tools/04_ai_capture.zsh — set in your
shell rc to override globally):

  AICAP_AGENT             auto | claude | opencode | codex | cursor-agent | http
  AICAP_CLAUDE_MODEL      default: haiku
  AICAP_OPENCODE_MODEL    default: github-copilot/claude-haiku-4.5
  AICAP_CODEX_MODEL       default: gpt-5-mini
  AICAP_CURSOR_MODEL      default: (let cursor-agent pick)
  AICAP_HTTP_URL          default: https://openrouter.ai/api/v1/chat/completions
  AICAP_HTTP_MODEL        default: google/gemini-2.0-flash-exp:free
  AICAP_HTTP_API_KEY      default: $OPENROUTER_API_KEY
  TSUM_CACHE_TTL          seconds, default 600 (10 min)
  TSUM_TIMEOUT            seconds, default 60 (LLM call timeout)
  TSUM_TMUX_BIN           full path to tmux binary, default "tmux" — set this
                          when multiple tmux versions are on PATH and the
                          server you want runs from a specific one (apt vs
                          appimage protocol mismatch). E.g. /bin/tmux.

Cache:
  $XDG_CACHE_HOME/tmux-session-summary/<hostname>.json
  (falls back to ~/.cache/tmux-session-summary/)

Companion docs: docs/shells/aliases.md row, plan in
.claude/plans/ldw-in-eventual-wall.md.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

from rich.console import Console
from rich.text import Text


# ---------------------------------------------------------------------------
# SSOT loader — parse dot_config/shell/04_ai_agents.sh so this script gets
# the same AICAP_* defaults as aifix/aiblock without redeclaring them. Used
# only when env vars aren't already inherited (cron, tmux popup, etc.).
# ---------------------------------------------------------------------------
_SSOT_PATH_CANDIDATES = (
    "~/.config/shell/04_ai_agents.sh",
    # When run from the chezmoi source dir before `chezmoi apply`:
    "~/.local/share/chezmoi/dot_config/shell/04_ai_agents.sh",
)
# Match `: "${VAR:=value}"` lines — value may be empty or contain spaces.
# Captures: (var_name, raw_value)
_SSOT_LINE = re.compile(r'^\s*:\s*"\$\{(AICAP_\w+):=([^}]*)\}"\s*$')


def _load_ssot_defaults() -> dict[str, str]:
    """Return AICAP_* defaults parsed from the first existing SSOT path.

    Empty dict if no candidate exists — callers should fall back to the
    hardcoded safety defaults below. Drift between this script and the
    shell file is impossible because we read the file at process start.
    """
    for raw in _SSOT_PATH_CANDIDATES:
        p = Path(os.path.expanduser(raw))
        if not p.is_file():
            continue
        out: dict[str, str] = {}
        try:
            for line in p.read_text(encoding="utf-8").splitlines():
                m = _SSOT_LINE.match(line)
                if m:
                    out[m.group(1)] = m.group(2)
        except OSError:
            return {}
        return out
    return {}


_SSOT = _load_ssot_defaults()


def _env_or_ssot(key: str, hardcoded_fallback: str = "") -> str:
    """Resolution order: env var (live override) > SSOT file > hardcoded
    safety default. The hardcoded value should only kick in on hosts that
    have neither inherited the env nor deployed the SSOT — a rare edge."""
    val = os.environ.get(key)
    if val is not None:  # explicitly set (even to empty) wins
        return val
    return _SSOT.get(key, hardcoded_fallback)

# ---------------------------------------------------------------------------
# Env defaults — mirror 04_ai_capture.zsh so user overrides carry across.
# ---------------------------------------------------------------------------
AICAP_AGENT = os.environ.get("AICAP_AGENT", "")
# AICAP_* defaults come from dot_config/shell/04_ai_agents.sh (the SSOT).
# Hardcoded values below are safety fallbacks only — they kick in when both
# the env var is unset AND the SSOT file is missing (e.g. an unpacked
# tarball without `chezmoi apply`). The drift risk vs the SSOT is contained
# to that edge case.
AICAP_CLAUDE_MODEL = _env_or_ssot("AICAP_CLAUDE_MODEL", "haiku")
AICAP_OPENCODE_MODEL = _env_or_ssot("AICAP_OPENCODE_MODEL", "github-copilot/claude-haiku-4.5")
AICAP_CODEX_MODEL = _env_or_ssot("AICAP_CODEX_MODEL", "")
AICAP_CURSOR_MODEL = _env_or_ssot("AICAP_CURSOR_MODEL", "")
AICAP_HTTP_URL = _env_or_ssot("AICAP_HTTP_URL", "https://openrouter.ai/api/v1/chat/completions")
AICAP_HTTP_MODEL = _env_or_ssot("AICAP_HTTP_MODEL", "google/gemini-2.0-flash-exp:free")
AICAP_HTTP_API_KEY = os.environ.get("AICAP_HTTP_API_KEY") or os.environ.get("OPENROUTER_API_KEY", "")
AICAP_AGENT_PRIORITY = _env_or_ssot("AICAP_AGENT_PRIORITY", "opencode claude codex cursor-agent").split()
TSUM_CACHE_TTL = int(os.environ.get("TSUM_CACHE_TTL", "600"))
TSUM_TIMEOUT = float(os.environ.get("TSUM_TIMEOUT", "60"))
# Pin a specific tmux binary if multiple are on PATH (e.g. /bin/tmux 3.2a
# from apt vs ~/.local/bin/tmux 3.5+ from the appimage). Different major
# versions can't talk to each other's server — the newer client returns
# "no sessions" against an older server's socket and the error is silent.
# Setting this resolves both the binary AND, transitively, the matching
# server. Default "tmux" → first on PATH.
TSUM_TMUX_BIN = os.environ.get("TSUM_TMUX_BIN", "tmux")


def _with_model(*model_flag_and_value: str) -> list[str]:
    """Return [flag, value] only when value is non-empty, else []. Lets each
    agent fall back to its CLI default when AICAP_<AGENT>_MODEL is unset —
    avoids hard-failing if the provider retires a pinned model ID."""
    flag, value = model_flag_and_value
    return [flag, value] if value else []


AGENT_CONFIG = {
    # Order matters: detect_agent() iterates this dict and picks the first
    # CLI it finds on PATH. opencode-first because benchmarking on 2026-05-12
    # showed it's ~2x faster than cursor-agent and ~3x faster than claude
    # for tsum-style multi-session summarization (one-shot, JSON output).
    "opencode":     {"base": ["opencode", "run", *_with_model("-m", AICAP_OPENCODE_MODEL)]},
    "claude":       {"base": ["claude", "-p", *_with_model("--model", AICAP_CLAUDE_MODEL)]},
    "codex":        {"base": ["codex", "exec", *_with_model("-m", AICAP_CODEX_MODEL)]},
    "cursor-agent": {"base": ["cursor-agent", "-p", *_with_model("--model", AICAP_CURSOR_MODEL)]},
    "http":         {"base": []},
}

# Diagnostic console goes to stderr so `tsum | grep ...` and `tsum picker | fzf`
# stay clean on stdout.
err = Console(stderr=True)


# ---------------------------------------------------------------------------
# Tmux capture
# ---------------------------------------------------------------------------
@dataclass
class Window:
    index: int
    name: str
    active: bool
    cwd: str
    cmd: str
    panes: int


@dataclass
class Session:
    name: str
    created: int        # unix epoch
    attached: bool
    last_attached: int  # unix epoch, 0 if never
    windows: list[Window] = field(default_factory=list)
    active_pane_tail: str = ""  # populated when --deep
    active_pane_skipped: bool = False  # True if we skipped self-capture (this is `tsum`'s own pane)


# Bounds for --deep capture window. Lower bound so tiny SSH panes (e.g. 12-row
# popups) still get useful context; upper bound so a maximised pane doesn't
# dominate the LLM prompt budget.
_DEEP_MIN_LINES = 20
_DEEP_MAX_LINES = 100


# Most recent stderr from a non-zero `tmux` exit. Surfaced by the
# "no sessions found" path so multi-binary / version-mismatch failures
# stop being silent.
_LAST_TMUX_STDERR: str = ""


def _tmux(*args: str, timeout: float = 5.0) -> str:
    """Run `$TSUM_TMUX_BIN ARGS...` and return stdout. Empty string on failure
    (stderr captured in _LAST_TMUX_STDERR for diagnostic surfacing)."""
    global _LAST_TMUX_STDERR
    try:
        result = subprocess.run(
            [TSUM_TMUX_BIN, *args],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except FileNotFoundError:
        _LAST_TMUX_STDERR = f"{TSUM_TMUX_BIN}: command not found"
        return ""
    except subprocess.TimeoutExpired:
        _LAST_TMUX_STDERR = f"{TSUM_TMUX_BIN}: timed out after {timeout}s"
        return ""
    if result.returncode != 0:
        _LAST_TMUX_STDERR = (result.stderr or "").strip()
        return ""
    return result.stdout


def collect_sessions(deep: bool = False) -> list[Session]:
    """Query the tmux server for every session + its windows.

    Returns empty list if the tmux server is unreachable.
    """
    raw = _tmux(
        "list-sessions",
        "-F",
        "#{session_name}\t#{session_created}\t#{session_attached}\t#{session_last_attached}",
    )
    if not raw.strip():
        return []
    my_pane = os.environ.get("TMUX_PANE", "")  # the pane running THIS script, if any
    sessions: list[Session] = []
    for line in raw.strip().splitlines():
        parts = line.split("\t")
        if len(parts) < 4:
            continue
        name, created, attached, last_attached = parts[:4]
        sess = Session(
            name=name,
            created=int(created) if created.isdigit() else 0,
            attached=attached not in ("", "0"),
            last_attached=int(last_attached) if last_attached.isdigit() else 0,
        )
        sess.windows = _collect_windows(name)
        if deep:
            sess.active_pane_tail, sess.active_pane_skipped = _capture_active_pane(
                name, sess.windows, my_pane
            )
        sessions.append(sess)
    return sessions


def _collect_windows(session: str) -> list[Window]:
    raw = _tmux(
        "list-windows",
        "-t",
        session,
        "-F",
        "#{window_index}\t#{window_name}\t#{window_active}\t#{pane_current_path}\t#{pane_current_command}\t#{window_panes}",
    )
    wins: list[Window] = []
    for line in raw.strip().splitlines():
        parts = line.split("\t")
        if len(parts) < 6:
            continue
        idx, wname, active, cwd, cmd, panes = parts[:6]
        wins.append(
            Window(
                index=int(idx) if idx.isdigit() else 0,
                name=wname,
                active=active == "1",
                cwd=cwd,
                cmd=cmd,
                panes=int(panes) if panes.isdigit() else 1,
            )
        )
    return wins


def _capture_active_pane(session: str, wins: list[Window], my_pane: str) -> tuple[str, bool]:
    """Visible-area capture of the session's active window's active pane.

    Returns (text, skipped). `skipped=True` when the target pane is the one
    running this script — capturing it would include `tsum`'s own output
    (the prompt, the previous summary if any), which pollutes the LLM input
    and produces a recursive-looking session description.

    Capture window is sized to the pane's actual height, clamped to
    [_DEEP_MIN_LINES, _DEEP_MAX_LINES]. Smaller than ~20 lines is usually
    useless; larger than ~100 dominates the prompt and risks leaking lots
    of scrollback content.
    """
    active = next((w for w in wins if w.active), wins[0] if wins else None)
    if active is None:
        return "", False
    target = f"{session}:{active.index}"

    # Self-capture guard. `tmux display-message -p '#{pane_id}'` returns
    # the active pane of the target; compare against $TMUX_PANE.
    if my_pane:
        target_pane = _tmux(
            "display-message", "-p", "-t", target, "#{pane_id}"
        ).strip()
        if target_pane and target_pane == my_pane:
            return "", True

    # Size the capture to the pane's actual visible height.
    height_str = _tmux(
        "display-message", "-p", "-t", target, "#{pane_height}"
    ).strip()
    try:
        height = int(height_str)
    except ValueError:
        height = 40  # reasonable fallback
    lines = max(_DEEP_MIN_LINES, min(height, _DEEP_MAX_LINES))

    text = _tmux(
        "capture-pane", "-p", "-S", f"-{lines}", "-t", target
    ).rstrip()
    return text, False


# ---------------------------------------------------------------------------
# Signature + cache
# ---------------------------------------------------------------------------
def session_signature(sessions: list[Session], deep: bool) -> str:
    """Stable hash over the (session_name, window_count, window_indices,
    pane_current_command-of-active-window) tuple — invalidates the cache when
    structure changes but not when the user just navigates around.

    `deep` participates in the sig so a `--deep` run is cached separately
    from a metadata-only run (different prompt → different summaries).
    """
    parts: list[str] = ["deep" if deep else "shallow"]
    for s in sorted(sessions, key=lambda x: x.name):
        win_sig = ",".join(f"{w.index}:{w.cmd}" for w in s.windows)
        parts.append(f"{s.name}|{len(s.windows)}|{win_sig}")
    blob = "\n".join(parts).encode("utf-8")
    return hashlib.sha256(blob).hexdigest()[:16]


def cache_path(deep: bool) -> Path:
    """Per-host, per-mode cache file. Splitting deep / shallow into two slots
    means toggling --deep / --shallow doesn't thrash the other mode's cache —
    each TTL window can serve both depths from cache independently.
    """
    base = os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")
    d = Path(base) / "tmux-session-summary"
    d.mkdir(parents=True, exist_ok=True)
    host = socket.gethostname().split(".")[0] or "host"
    mode = "deep" if deep else "shallow"
    return d / f"{host}-{mode}.json"


# Bump when the per-session schema changes (e.g. v2 added closability fields).
# Cache files with a mismatched version are silently ignored and overwritten on
# next refresh, so old caches degrade gracefully without manual cleanup.
_CACHE_VERSION = "v2"


def load_cache(sig: str, deep: bool) -> list[dict] | None:
    p = cache_path(deep)
    if not p.is_file():
        return None
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None
    if data.get("version") != _CACHE_VERSION:
        return None
    if data.get("sig") != sig:
        return None
    age = time.time() - float(data.get("generated_at_epoch", 0))
    if age > TSUM_CACHE_TTL:
        return None
    summaries = data.get("sessions")
    return summaries if isinstance(summaries, list) else None


def save_cache(sig: str, summaries: list[dict], deep: bool) -> None:
    p = cache_path(deep)
    try:
        p.write_text(
            json.dumps(
                {
                    "version": _CACHE_VERSION,
                    "sig": sig,
                    "generated_at_epoch": time.time(),
                    "ttl_seconds": TSUM_CACHE_TTL,
                    "sessions": summaries,
                },
                indent=2,
            ),
            encoding="utf-8",
        )
    except OSError as e:
        err.print(f"[yellow]tmux-session-summary: cache write failed: {e}[/yellow]")


# ---------------------------------------------------------------------------
# Prompt construction
# ---------------------------------------------------------------------------
PROMPT_PREAMBLE = """\
You are summarizing a developer's tmux sessions so they can quickly remember \
what each one is for, AND decide which sessions are safe to close. The data \
below is from `tmux list-sessions` + `tmux list-windows`. The user has many \
cryptically-named sessions (numbers, dates, project slugs) and wants a \
one-glance refresher + a clear closability rating.

For EACH session, infer:
  - A concise one-line summary (<= 70 chars) describing what the user is \
doing there. Be specific: name the project, the running task, the file being \
edited. Avoid generic phrases like "a session" or "various work".
  - 1-3 "important_windows": the editor window, the long-running process, \
the primary terminal — whichever stand out as load-bearing. Skip if nothing \
really stands out.
  - A "closability" rating — how safe it is to close this session RIGHT NOW \
without losing work:
      "safe"   → nothing important; close freely. Only idle shells \
(zsh/bash/fish), lazygit browsers, monitoring (tail -f, htop, watch), or \
detached sessions with last_attached >7 days ago and no running process.
      "check"  → might lose work; review before closing. Editor open with a \
filename (might have unsaved buffer), attached but currently idle, recent \
activity, unclear state.
      "keep"   → active in-progress work; do NOT close. Coding-agent CLI \
running (claude/opencode/codex/aider/gemini), long-running process \
(python/node/npm run dev/cargo run/docker compose up/pytest), \
attached + currently editing, --deep output showing a build/test running.
  - A one-line "closability_reason" (<= 50 chars) explaining the rating.

When in doubt, pick "check" rather than "safe" — false safe is worse than \
false check.

Summary heuristics:
  - `nvim`, `vim`, `code` → likely an editor; the filename in cmd matters.
  - `python`, `node`, `npm`, `cargo`, `make`, `pytest`, `docker` → likely a \
running build/server/test. Note it.
  - `zsh`, `bash`, `fish` alone → idle shell; usually NOT important.
  - `claude`, `codex`, `opencode`, `aider` → coding agent session.
  - Same cwd across many windows → that cwd is the project root.
  - `wt` / `worktree` / `tries/` / `coding-agent/` in session name → git \
worktree experiment, often short-lived.

Respond with STRICT JSON only, no prose, no code fences:
[
  {
    "session": "<name>",
    "summary": "<<=70 chars>",
    "closability": "safe" | "check" | "keep",
    "closability_reason": "<<=50 chars>",
    "important_windows": [
      {"index": <int>, "name": "<window_name>", "why": "<<=40 chars>"}
    ]
  }
]
"""


def build_prompt(sessions: list[Session], deep: bool) -> str:
    parts = [PROMPT_PREAMBLE, "", "--- SESSIONS ---", ""]
    for s in sessions:
        attached_marker = "(attached)" if s.attached else ""
        parts.append(f"session: {s.name} [{len(s.windows)} windows] {attached_marker}".rstrip())
        for w in s.windows:
            active = " ACTIVE" if w.active else ""
            pane_note = f" ({w.panes} panes)" if w.panes > 1 else ""
            parts.append(f"  {w.index}: {w.name:<14} {w.cwd}    {w.cmd}{pane_note}{active}")
        if deep:
            if s.active_pane_skipped:
                parts.append(
                    "  (skipped active-pane capture: this is the pane running tsum)"
                )
            elif s.active_pane_tail:
                tail_lines = s.active_pane_tail.splitlines()
                parts.append(
                    f"  recent output (visible area, {len(tail_lines)} lines, active pane):"
                )
                for line in tail_lines:
                    # Per-line clip so a pathological line doesn't blow tokens.
                    parts.append(f"    {line[:200]}")
        parts.append("")
    parts.append("Return JSON now.")
    return "\n".join(parts)


# ---------------------------------------------------------------------------
# Agent invocation
# ---------------------------------------------------------------------------
def detect_agent() -> str | None:
    """Pick an agent: explicit override > priority list from SSOT.

    Priority list is `$AICAP_AGENT_PRIORITY` from
    dot_config/shell/04_ai_agents.sh. Override globally by exporting that
    var; override per-call by setting AICAP_AGENT.
    """
    if AICAP_AGENT:
        if AICAP_AGENT == "http" or shutil.which(AICAP_AGENT):
            return AICAP_AGENT
        err.print(
            f"[red]AICAP_AGENT={AICAP_AGENT!r} but that CLI isn't on PATH.[/red]"
        )
        return None
    for cand in AICAP_AGENT_PRIORITY:
        if shutil.which(cand):
            return cand
    return None


def model_for(agent: str) -> str:
    return {
        "claude": AICAP_CLAUDE_MODEL or "(default)",
        "opencode": AICAP_OPENCODE_MODEL or "(default)",
        "codex": AICAP_CODEX_MODEL or "(default)",
        "cursor-agent": AICAP_CURSOR_MODEL or "(default)",
        "http": AICAP_HTTP_MODEL,
    }.get(agent, "?")


def invoke_agent(agent: str, prompt: str, timeout: float) -> str:
    """Run the agent in one-shot mode and return raw reply text.

    Returns empty string on failure (caller falls back to metadata-only
    rendering).
    """
    if agent == "http":
        return _invoke_http(prompt, timeout)
    base = AGENT_CONFIG[agent]["base"]
    try:
        result = subprocess.run(
            [*base, prompt],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        err.print(f"[red]{agent} timed out after {timeout:.0f}s[/red]")
        return ""
    except FileNotFoundError:
        err.print(f"[red]{agent} not on PATH (race vs detect_agent)[/red]")
        return ""
    if result.returncode != 0:
        err.print(f"[red]{agent} exited {result.returncode}[/red]")
        if result.stderr.strip():
            err.print(f"[dim]{result.stderr.strip()[:500]}[/dim]")
        return ""
    return result.stdout


def _invoke_http(prompt: str, timeout: float) -> str:
    payload = json.dumps({
        "model": AICAP_HTTP_MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "stream": False,
    }).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    if AICAP_HTTP_API_KEY:
        headers["Authorization"] = f"Bearer {AICAP_HTTP_API_KEY}"
    req = urllib.request.Request(AICAP_HTTP_URL, data=payload, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8", errors="replace")
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as e:
        err.print(f"[red]http: {e}[/red]")
        return ""
    try:
        parsed = json.loads(body)
        return parsed["choices"][0]["message"]["content"]
    except (json.JSONDecodeError, KeyError, IndexError, TypeError):
        err.print(f"[red]http: unexpected response shape[/red] [dim]{body[:300]}[/dim]")
        return ""


# ---------------------------------------------------------------------------
# Response parsing
# ---------------------------------------------------------------------------
_CLOSABILITY_TIERS = ("safe", "check", "keep")


def parse_reply(reply: str) -> list[dict] | None:
    """Extract the JSON array of session summaries from the agent's reply.

    Agents sometimes wrap JSON in ``` fences or add a preamble despite
    instructions. We tolerate that by finding the first `[` and last `]`.
    """
    if not reply.strip():
        return None
    # Strip code fences if present.
    stripped = reply.strip()
    if stripped.startswith("```"):
        stripped = stripped.split("\n", 1)[1] if "\n" in stripped else stripped
        if stripped.endswith("```"):
            stripped = stripped.rsplit("```", 1)[0]
        stripped = stripped.strip()
    # Find outer JSON array.
    start = stripped.find("[")
    end = stripped.rfind("]")
    if start == -1 or end == -1 or end < start:
        return None
    try:
        parsed = json.loads(stripped[start : end + 1])
    except json.JSONDecodeError:
        return None
    if not isinstance(parsed, list):
        return None
    # Coerce minimal shape.
    out: list[dict] = []
    for item in parsed:
        if not isinstance(item, dict):
            continue
        sess = str(item.get("session", "")).strip()
        if not sess:
            continue
        raw_closability = str(item.get("closability", "")).strip().lower()
        # Unknown / missing → "check" (conservative middle): per the prompt
        # rule "when in doubt, pick check rather than safe."
        closability = raw_closability if raw_closability in _CLOSABILITY_TIERS else "check"
        out.append({
            "session": sess,
            "summary": str(item.get("summary", "")).strip()[:140],
            "closability": closability,
            "closability_reason": str(item.get("closability_reason", "")).strip()[:80],
            "important_windows": [
                {
                    "index": int(w.get("index", 0)) if str(w.get("index", "")).lstrip("-").isdigit() else 0,
                    "name": str(w.get("name", "")).strip()[:30],
                    "why": str(w.get("why", "")).strip()[:80],
                }
                for w in (item.get("important_windows") or [])
                if isinstance(w, dict)
            ][:3],
        })
    return out


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------
def _summary_by_session(summaries: list[dict]) -> dict[str, dict]:
    return {s["session"]: s for s in summaries}


# Visual mapping for the three closability tiers. The glyph is plain Unicode
# so it survives no-color terminals; the colour is rich-styled in TTYs.
_TIER_GLYPHS = {"safe": "🟢", "check": "🟡", "keep": "🔴"}
_TIER_COLORS = {"safe": "green", "check": "yellow", "keep": "red"}
_TIER_FALLBACK_GLYPH = "⚪"  # used when LLM output is missing (fallback renderers)


def render_list(sessions: list[Session], summaries: list[dict], use_color: bool) -> None:
    """Human-readable: one block per session to stdout."""
    out = Console(force_terminal=use_color, no_color=not use_color, soft_wrap=True)
    by_name = _summary_by_session(summaries)
    name_width = max((len(s.name) for s in sessions), default=4)
    for s in sessions:
        info = by_name.get(s.name, {})
        summary = info.get("summary") or "(no summary)"
        tier = info.get("closability", "check")
        glyph = _TIER_GLYPHS.get(tier, _TIER_FALLBACK_GLYPH)
        color = _TIER_COLORS.get(tier, "cyan")
        attached = " *" if s.attached else "  "
        line = Text()
        line.append(f"{glyph} ", style="bold")
        # Underline the name when "keep" so the row pops even on glyph-blind terminals.
        name_style = f"bold {color}"
        if tier == "keep":
            name_style += " underline"
        line.append(f"{s.name:<{name_width}}{attached} ", style=name_style)
        line.append(f"[{len(s.windows):>2}w] ", style="dim")
        line.append(summary, style="white")
        reason = info.get("closability_reason", "")
        if reason:
            line.append(f"  ({reason})", style="dim italic")
        out.print(line)
        for w_info in info.get("important_windows", []):
            why = f"  — {w_info['why']}" if w_info.get("why") else ""
            idx = w_info.get("index", 0)
            wname = w_info.get("name", "")
            sub = Text()
            sub.append("    └ ", style="dim")
            sub.append(f"w{idx}: {wname}", style="green")
            sub.append(why, style="dim")
            out.print(sub)


def render_picker(sessions: list[Session], summaries: list[dict]) -> None:
    """TSV `<session>\\t<one-line>` for fzf consumption.

    Always plain text (no ANSI), always stdout. fzf will display the second
    column via --with-nth=2.
    """
    by_name = _summary_by_session(summaries)
    for s in sessions:
        info = by_name.get(s.name, {})
        summary = info.get("summary") or "(no summary)"
        tier = info.get("closability", "check")
        glyph = _TIER_GLYPHS.get(tier, _TIER_FALLBACK_GLYPH)
        attached = "*" if s.attached else " "
        win_count = f"[{len(s.windows):>2}w]"
        print(f"{s.name}\t{glyph} {attached} {win_count} {summary}")


def render_fallback_list(sessions: list[Session], use_color: bool) -> None:
    """Used when the LLM failed: print bare metadata so the user still sees something."""
    out = Console(force_terminal=use_color, no_color=not use_color, soft_wrap=True)
    name_width = max((len(s.name) for s in sessions), default=4)
    for s in sessions:
        attached = " *" if s.attached else "  "
        line = Text()
        line.append(f"{_TIER_FALLBACK_GLYPH} ", style="bold")
        line.append(f"{s.name:<{name_width}}{attached} ", style="bold cyan")
        line.append(f"[{len(s.windows):>2}w] ", style="dim")
        # Best-effort tag: most-common cwd basename + active window's cmd
        cwds = [w.cwd for w in s.windows]
        common = max(set(cwds), key=cwds.count) if cwds else ""
        basename = os.path.basename(common.rstrip("/")) or common
        active = next((w for w in s.windows if w.active), None)
        active_str = f" — {active.cmd}" if active else ""
        line.append(f"{basename}{active_str}", style="white")
        out.print(line)


def render_fallback_picker(sessions: list[Session]) -> None:
    """Picker fallback when LLM failed."""
    for s in sessions:
        attached = "*" if s.attached else " "
        cwds = [w.cwd for w in s.windows]
        common = max(set(cwds), key=cwds.count) if cwds else ""
        basename = os.path.basename(common.rstrip("/")) or common
        active = next((w for w in s.windows if w.active), None)
        active_str = f" — {active.cmd}" if active else ""
        print(f"{s.name}\t{_TIER_FALLBACK_GLYPH} {attached} [{len(s.windows):>2}w] {basename}{active_str}")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def _env_truthy(val: str) -> bool:
    return val.strip().lower() not in ("", "0", "false", "no", "off")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="tmux-session-summary",
        description="AI-powered overview of every tmux session.",
    )
    p.add_argument("mode", nargs="?", default="list", choices=["list", "picker"])
    # --deep and --shallow are mutually-resolved later (--deep wins). default
    # is None so we can tell "user did not pass either flag" apart from
    # "user explicitly chose shallow" and consult TSUM_DEEP_DEFAULT only in
    # the former case.
    p.add_argument(
        "-d", "--deep",
        dest="deep", action="store_true", default=None,
        help="Include visible area of each session's active pane (overrides TSUM_DEEP_DEFAULT=0).",
    )
    p.add_argument(
        "--shallow",
        dest="deep", action="store_false",
        help="Force metadata-only (overrides TSUM_DEEP_DEFAULT=1).",
    )
    p.add_argument("-r", "--refresh", action="store_true", help="Bypass cache.")
    p.add_argument("--dry-run", action="store_true", help="Print the prompt that would be sent; no API call.")
    p.add_argument("--no-cache", action="store_true", help="Don't read or write the cache.")
    p.add_argument(
        "--sort", choices=["alpha", "closability"], default="alpha",
        help="Order sessions: alpha (tmux's natural order) or closability (keep→check→safe).",
    )
    p.add_argument(
        "--only", choices=_CLOSABILITY_TIERS, default=None,
        help="Filter to one closability tier.",
    )
    args = p.parse_args()
    # Three-state resolution: flag explicit > env var > False.
    if args.deep is None:
        args.deep = _env_truthy(os.environ.get("TSUM_DEEP_DEFAULT", ""))
    return args


def main() -> int:
    args = parse_args()

    sessions = collect_sessions(deep=args.deep)
    if not sessions:
        resolved = shutil.which(TSUM_TMUX_BIN) or TSUM_TMUX_BIN
        err.print(
            f"[red]tmux-session-summary: no tmux sessions found via "
            f"{TSUM_TMUX_BIN!r} ({resolved}).[/red]"
        )
        if _LAST_TMUX_STDERR:
            err.print(f"[dim]tmux stderr: {_LAST_TMUX_STDERR}[/dim]")
        err.print(
            "[yellow]Possible causes:[/yellow]\n"
            "  - server not running → start a session first.\n"
            "  - multiple tmux binaries on PATH (apt vs appimage vs brew) and the\n"
            "    one we resolved talks a different protocol than the running server.\n"
            "    Fix: [cyan]export TSUM_TMUX_BIN=/path/to/correct-tmux[/cyan]\n"
            "    (e.g. [cyan]/bin/tmux[/cyan] if your sessions live there)."
        )
        return 1

    if args.dry_run:
        print(build_prompt(sessions, deep=args.deep))
        return 0

    sig = session_signature(sessions, deep=args.deep)
    cached: list[dict] | None = None
    if not args.refresh and not args.no_cache:
        cached = load_cache(sig, args.deep)

    if cached is not None:
        summaries = cached
    else:
        agent = detect_agent()
        if agent is None:
            tried = ", ".join(AICAP_AGENT_PRIORITY)
            err.print(
                f"[red]No coding-agent CLI on PATH (tried: {tried}).[/red]\n"
                "[dim]Install one, or set AICAP_AGENT=http with AICAP_HTTP_API_KEY.[/dim]\n"
                "[yellow]Falling back to metadata-only output (no AI summaries).[/yellow]"
            )
            return _render_fallback(sessions, args)

        prompt = build_prompt(sessions, deep=args.deep)
        with err.status(f"[dim]{agent} ({model_for(agent)}) thinking…[/dim]", spinner="dots"):
            reply = invoke_agent(agent, prompt, TSUM_TIMEOUT)
        summaries = parse_reply(reply) or []
        if not summaries:
            err.print("[yellow]LLM returned no parseable JSON; falling back to metadata-only.[/yellow]")
            return _render_fallback(sessions, args)
        if not args.no_cache:
            save_cache(sig, summaries, args.deep)

    # Apply --sort / --only between summary fetch and rendering. Cache is
    # untouched (we always save unsorted + unfiltered) so different views
    # of the same summary set don't thrash the cache.
    sessions = _apply_view(sessions, summaries, sort=args.sort, only=args.only)
    if not sessions:
        err.print(f"[yellow]No sessions match --only={args.only}.[/yellow]")
        return 0

    if args.mode == "picker":
        render_picker(sessions, summaries)
    else:
        render_list(sessions, summaries, use_color=sys.stdout.isatty())
    return 0


def _render_fallback(sessions: list[Session], args: argparse.Namespace) -> int:
    """Fallback render path — used when the LLM is unavailable or unparseable.

    --sort=closability and --only depend on LLM-derived tiers, so they're
    no-ops here; warn the user instead of silently ignoring.
    """
    if args.only or args.sort == "closability":
        err.print(
            "[yellow]--sort=closability and --only need an LLM-rated tier;"
            " ignoring in fallback mode.[/yellow]"
        )
    if args.mode == "picker":
        render_fallback_picker(sessions)
    else:
        render_fallback_list(sessions, use_color=sys.stdout.isatty())
    return 0


# Sort order for --sort=closability: high-urgency first so the user sees
# active work at the top and can scroll past safe-to-close sessions.
_TIER_RANK = {"keep": 0, "check": 1, "safe": 2}


def _apply_view(
    sessions: list[Session],
    summaries: list[dict],
    *,
    sort: str,
    only: str | None,
) -> list[Session]:
    by_name = _summary_by_session(summaries)

    def tier_of(s: Session) -> str:
        return by_name.get(s.name, {}).get("closability", "check")

    if only:
        sessions = [s for s in sessions if tier_of(s) == only]

    if sort == "closability":
        # Stable secondary sort by name preserves alphabetical order within
        # each tier so the listing is deterministic.
        sessions = sorted(sessions, key=lambda s: (_TIER_RANK.get(tier_of(s), 1), s.name))

    return sessions


if __name__ == "__main__":
    sys.exit(main())
