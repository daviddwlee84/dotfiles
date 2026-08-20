"""yth — shared helpers for the YouTube watch-history CLI.

The umbrella binary (``dot_dotfiles/bin/executable_yth``) plus subcommand
modules (``scripts/yth/{import_takeout,sync,enrich,fetch_subs,search,list,
show}.py``) all share this namespace. Helpers live here instead of being
duplicated per-module — same rationale as ``scripts/mlf/__init__.py``.

``yt_dlp`` is imported lazily (via :func:`ytdl`) — it's ~0.3-0.5s to import —
so the hot DB-only paths (``search`` / ``list`` / ``show``, and the tv preview
pane) never pay the cost. Only the network subcommands (``sync`` / ``enrich``
/ ``fetch-subs``) touch it.

Storage layout (via ``platformdirs``, so it's correct on macOS *and* Linux):
  data   → history.db          (durable; the watch history + FTS index)
  config → config.toml         (cookie source, subtitle langs, open target)
  cache  → (transient scratch; subtitle downloads use a TemporaryDirectory)
"""
from __future__ import annotations

import contextlib
import functools
import http.cookiejar
import io
import os
import re
import shutil
import stat
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

APP = "yth"

# YouTube video ids are 11 chars of the URL-safe base64 alphabet. Anchored so
# a stray query-string fragment can't masquerade as an id.
VIDEO_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")


# --------------------------------------------------------------------------- #
# Paths
# --------------------------------------------------------------------------- #
def _dirs():
    from platformdirs import user_cache_dir, user_config_dir, user_data_dir

    return (
        Path(user_data_dir(APP)),
        Path(user_config_dir(APP)),
        Path(user_cache_dir(APP)),
    )


def data_dir() -> Path:
    d, _, _ = _dirs()
    d.mkdir(parents=True, exist_ok=True)
    return d


def config_dir() -> Path:
    _, c, _ = _dirs()
    return c


def cache_dir() -> Path:
    _, _, k = _dirs()
    k.mkdir(parents=True, exist_ok=True)
    return k


def db_path() -> Path:
    """Location of the sqlite history DB. Override with $YTH_DB (tests)."""
    override = os.environ.get("YTH_DB")
    if override:
        p = Path(override).expanduser()
        p.parent.mkdir(parents=True, exist_ok=True)
        return p
    return data_dir() / "history.db"


# --------------------------------------------------------------------------- #
# Time
# --------------------------------------------------------------------------- #
def now_iso() -> str:
    """Current UTC time as an ISO8601 string (second precision, no micros)."""
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def short_date(iso: str | None) -> str:
    """ISO timestamp → ``YYYY-MM-DD`` (or ``-``). Cheap: just slices."""
    return iso[:10] if iso else "-"


def fmt_duration(secs: int | None) -> str:
    """Seconds → ``H:MM:SS`` / ``M:SS`` (or ``-``)."""
    if not secs:
        return "-"
    secs = int(secs)
    h, rem = divmod(secs, 3600)
    m, s = divmod(rem, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"


def iso_utc(value: str | None) -> str | None:
    """Normalize a timestamp string to ISO8601 UTC, or None if unparseable.

    Takeout ``time`` fields look like ``2024-01-02T03:04:05.678Z``. We accept
    the trailing ``Z`` (Python <3.11 datetime.fromisoformat can't) and drop
    sub-second precision so ``watch_events`` de-dupes cleanly.
    """
    if not value:
        return None
    v = value.strip().replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(v)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc).replace(microsecond=0).isoformat()


# --------------------------------------------------------------------------- #
# Database
# --------------------------------------------------------------------------- #
_SCHEMA = """
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS videos (
  id            INTEGER PRIMARY KEY,
  video_id      TEXT UNIQUE NOT NULL,
  title         TEXT,
  channel       TEXT,
  channel_id    TEXT,
  url           TEXT,
  description   TEXT,
  duration      INTEGER,
  upload_date   TEXT,
  enriched_at   TEXT,
  subs_fetched_at TEXT
);

CREATE TABLE IF NOT EXISTS watch_events (
  video_id   TEXT NOT NULL,
  watched_at TEXT NOT NULL,
  source     TEXT NOT NULL DEFAULT 'takeout',
  PRIMARY KEY (video_id, watched_at)
);
CREATE INDEX IF NOT EXISTS watch_events_vid ON watch_events(video_id);

CREATE TABLE IF NOT EXISTS subtitles (
  id         INTEGER PRIMARY KEY,
  video_id   TEXT NOT NULL,
  lang       TEXT NOT NULL,
  text       TEXT NOT NULL,
  fetched_at TEXT,
  UNIQUE (video_id, lang)
);

CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);

CREATE VIEW IF NOT EXISTS video_stats AS
  SELECT video_id,
         COUNT(*)        AS watch_count,
         MIN(watched_at) AS first_watched,
         MAX(watched_at) AS last_watched
  FROM watch_events GROUP BY video_id;

CREATE VIRTUAL TABLE IF NOT EXISTS videos_fts USING fts5(
  title, channel, description,
  content='videos', content_rowid='id',
  tokenize='unicode61 remove_diacritics 2'
);
CREATE TRIGGER IF NOT EXISTS videos_ai AFTER INSERT ON videos BEGIN
  INSERT INTO videos_fts(rowid, title, channel, description)
  VALUES (new.id, new.title, new.channel, new.description);
END;
CREATE TRIGGER IF NOT EXISTS videos_ad AFTER DELETE ON videos BEGIN
  INSERT INTO videos_fts(videos_fts, rowid, title, channel, description)
  VALUES ('delete', old.id, old.title, old.channel, old.description);
END;
CREATE TRIGGER IF NOT EXISTS videos_au AFTER UPDATE ON videos BEGIN
  INSERT INTO videos_fts(videos_fts, rowid, title, channel, description)
  VALUES ('delete', old.id, old.title, old.channel, old.description);
  INSERT INTO videos_fts(rowid, title, channel, description)
  VALUES (new.id, new.title, new.channel, new.description);
END;

CREATE VIRTUAL TABLE IF NOT EXISTS subtitles_fts USING fts5(
  text, content='subtitles', content_rowid='id',
  tokenize='unicode61 remove_diacritics 2'
);
CREATE TRIGGER IF NOT EXISTS subtitles_ai AFTER INSERT ON subtitles BEGIN
  INSERT INTO subtitles_fts(rowid, text) VALUES (new.id, new.text);
END;
CREATE TRIGGER IF NOT EXISTS subtitles_ad AFTER DELETE ON subtitles BEGIN
  INSERT INTO subtitles_fts(subtitles_fts, rowid, text)
  VALUES ('delete', old.id, old.text);
END;
CREATE TRIGGER IF NOT EXISTS subtitles_au AFTER UPDATE ON subtitles BEGIN
  INSERT INTO subtitles_fts(subtitles_fts, rowid, text)
  VALUES ('delete', old.id, old.text);
  INSERT INTO subtitles_fts(rowid, text) VALUES (new.id, new.text);
END;
"""


def connect():
    """Open (creating + migrating if needed) the history DB.

    Returns a ``sqlite3.Connection`` with ``row_factory = sqlite3.Row``.
    Raises a friendly error if the bundled sqlite lacks FTS5.
    """
    import sqlite3

    con = sqlite3.connect(db_path())
    con.row_factory = sqlite3.Row
    try:
        con.executescript(_SCHEMA)
    except sqlite3.OperationalError as e:
        if "fts5" in str(e).lower():
            print(
                "yth: this Python's bundled sqlite3 lacks the FTS5 extension.\n"
                "  yth's search index requires FTS5. The uv-managed CPython\n"
                "  (python-build-standalone) ships it — ensure `uv` resolves\n"
                "  the script's interpreter rather than a stripped system one.",
                file=sys.stderr,
            )
            raise SystemExit(3) from e
        raise
    con.commit()
    return con


def meta_get(con, key: str, default: str | None = None) -> str | None:
    row = con.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
    return row["value"] if row else default


def meta_set(con, key: str, value: str) -> None:
    con.execute(
        "INSERT INTO meta(key, value) VALUES(?, ?) "
        "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        (key, value),
    )


# --------------------------------------------------------------------------- #
# URLs / ids
# --------------------------------------------------------------------------- #
def extract_video_id(url: str | None) -> str | None:
    """Pull an 11-char YouTube id out of a watch/short/embed/youtu.be URL.

    Returns None for non-video rows (Google search entries, removed-video
    placeholders, anything without a recognisable id) so callers can skip
    them. Also accepts a bare id.
    """
    if not url:
        return None
    url = url.strip()
    if VIDEO_ID_RE.match(url):
        return url

    from urllib.parse import parse_qs, urlparse

    try:
        u = urlparse(url)
    except ValueError:
        return None
    host = (u.hostname or "").lower().removeprefix("www.")

    if host == "youtu.be":
        cand = u.path.lstrip("/").split("/")[0]
        return cand if VIDEO_ID_RE.match(cand) else None

    if host in ("youtube.com", "m.youtube.com", "music.youtube.com"):
        if u.path == "/watch":
            vals = parse_qs(u.query).get("v", [])
            cand = vals[0] if vals else ""
            return cand if VIDEO_ID_RE.match(cand) else None
        for prefix in ("/shorts/", "/embed/", "/live/", "/v/"):
            if u.path.startswith(prefix):
                cand = u.path[len(prefix):].split("/")[0]
                return cand if VIDEO_ID_RE.match(cand) else None
    return None


def video_url(video_id: str) -> str:
    """Canonical watch URL (works for shorts too; opens in the app/site)."""
    return f"https://www.youtube.com/watch?v={video_id}"


# --------------------------------------------------------------------------- #
# Config + cookies
# --------------------------------------------------------------------------- #
def load_config() -> dict:
    """Read config.toml (if present); fill defaults; auto-detect Zen cookies.

    Keys: ``cookiefile`` (Arc → exported cookies.txt) XOR ``from_browser``
    (e.g. ``firefox:/path/to/zen/profile``); ``langs`` (subtitle langs);
    ``open_target`` (``browser`` | ``mpv``).
    """
    cfg: dict = {}
    path = config_dir() / "config.toml"
    if path.is_file():
        import tomllib

        try:
            cfg = tomllib.loads(path.read_text(encoding="utf-8"))
        except tomllib.TOMLDecodeError as e:
            print(f"yth: ignoring malformed {path}: {e}", file=sys.stderr)
            cfg = {}

    if not cfg.get("cookiefile") and not cfg.get("from_browser"):
        zen = _detect_zen_profile()
        if zen:
            cfg["from_browser"] = f"firefox:{zen}"

    cfg.setdefault("langs", ["en", "en-US"])
    cfg.setdefault("open_target", "browser")
    return cfg


def _detect_zen_profile() -> str | None:
    """Best-effort path to a Zen (Firefox fork) profile dir with cookies.

    macOS: ``~/Library/Application Support/zen/Profiles/*/cookies.sqlite``.
    Linux: ``~/.zen/*/cookies.sqlite``. Returns the profile dir (not the
    sqlite file) since that's what yt-dlp's ``firefox:<path>`` wants. None
    when Zen isn't installed (the common case on this host).
    """
    roots = [
        Path.home() / "Library" / "Application Support" / "zen" / "Profiles",
        Path.home() / ".zen",
    ]
    for root in roots:
        if not root.is_dir():
            continue
        hits = sorted(root.glob("*/cookies.sqlite"))
        if hits:
            return str(hits[0].parent)
    return None


class CookieSourceError(ValueError):
    """A configured cookie source is unsafe or unusable (message is value-free)."""


def _validated_cookiefile(raw_path: str) -> str:
    """Validate a Netscape jar silently before yt-dlp can echo malformed rows.

    yt-dlp's loader warns with ``line!r`` for a malformed entry, which includes
    the bearer value. All file-backed sinks therefore pass through here first.
    Error messages describe only the class of failure — never a row or value.
    """
    path = Path(os.path.expanduser(raw_path))
    if not path.is_file():
        raise CookieSourceError("cookie file is missing")
    try:
        metadata = path.stat()
    except OSError as e:
        raise CookieSourceError(f"cookie file cannot be inspected ({type(e).__name__})") from None
    if metadata.st_size <= 0:
        raise CookieSourceError("cookie file is empty")
    mode = stat.S_IMODE(metadata.st_mode)
    if os.name != "nt" and mode != 0o600:
        raise CookieSourceError(f"cookie file mode is {mode:04o}; expected 0600")

    # Validate with yt-dlp's exact parser. It normally warns with `line!r` for
    # a skipped row (including the bearer value), so capture and discard every
    # diagnostic and turn any warning/error into a value-free rejection.
    from yt_dlp.cookies import YoutubeDLCookieJar

    jar = YoutubeDLCookieJar(str(path))
    diagnostics = io.StringIO()
    try:
        with contextlib.redirect_stderr(diagnostics):
            jar.load(ignore_discard=True, ignore_expires=True)
    except (http.cookiejar.LoadError, OSError, ValueError):
        raise CookieSourceError("cookie file is not valid Netscape format") from None
    if diagnostics.getvalue():
        raise CookieSourceError("cookie file contains an entry yt-dlp cannot parse")

    all_cookies = list(jar)

    def is_youtube_cookie(cookie) -> bool:
        domain = cookie.domain.lstrip(".").lower()
        return domain == "youtube.com" or domain.endswith(".youtube.com")

    if any(not is_youtube_cookie(cookie) for cookie in all_cookies):
        raise CookieSourceError(
            "cookie file contains non-YouTube domains; export an isolated YouTube-only jar"
        )
    # Netscape exports use expires=0 for session cookies. stdlib treats 0 as
    # expired, while yt-dlp correctly normalizes it to a live session cookie.
    usable = [
        cookie
        for cookie in all_cookies
        if cookie.expires in (None, 0) or not cookie.is_expired()
    ]
    if not usable:
        raise CookieSourceError("cookie file has no unexpired YouTube-domain entries")
    return str(path)


def cookie_opts(cfg: dict, *, required: bool = False) -> dict:
    """Translate a safe configured source into yt-dlp cookie options.

    Returns ``{}`` when an optional source is absent. Explicit authenticated
    paths pass ``required=True`` so a missing source cannot silently fall back
    to anonymous access. File-backed sources are rejected before yt-dlp sees
    them if missing, non-0600, malformed, empty/expired, or multi-domain.
    """
    if cfg.get("cookiefile"):
        return {"cookiefile": _validated_cookiefile(str(cfg["cookiefile"]))}
    if cfg.get("from_browser"):
        browser, _, profile = str(cfg["from_browser"]).partition(":")
        browser = browser.strip().lower()
        supported = {
            "brave", "chrome", "chromium", "edge", "firefox", "opera",
            "safari", "vivaldi", "whale",
        }
        if browser not in supported:
            raise CookieSourceError(
                f"unsupported yt-dlp browser name: {browser or '<empty>'}"
            )
        return {"cookiesfrombrowser": (browser, profile or None, None, None)}
    if required:
        raise CookieSourceError("no cookie source configured")
    return {}


# --------------------------------------------------------------------------- #
# yt-dlp (lazy)
# --------------------------------------------------------------------------- #
@functools.lru_cache(maxsize=1)
def _node_supports_yt_dlp_ejs() -> bool:
    """Return true only for the Node 22+ runtime required by current yt-dlp."""
    node = shutil.which("node")
    if not node:
        return False
    try:
        result = subprocess.run(
            [node, "--version"], capture_output=True, text=True, timeout=5, check=False
        )
        major = int((result.stdout or result.stderr).strip().lstrip("v").split(".", 1)[0])
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return False
    return result.returncode == 0 and major >= 22


def yt_dlp_runtime_opts() -> dict:
    """Return a supported managed JS runtime for embedded yt-dlp calls.

    yt-dlp's Python API does not read standalone CLI config. This repo manages
    Node through mise, but legacy armv7/EL7 hosts may expose only Node 20/16;
    never select those as though they could run EJS. Doctor reports the hard
    requirement, while simple extraction may still degrade without a runtime.
    """
    runtimes = {"node": {}} if _node_supports_yt_dlp_ejs() else {}
    return {"js_runtimes": runtimes}


def ytdl():
    """Lazily import and return the ``yt_dlp`` module.

    Kept behind a function so DB-only subcommands never import it (it's the
    heaviest dependency and the tv preview path must stay instant).
    """
    import yt_dlp

    return yt_dlp


# --------------------------------------------------------------------------- #
# Subtitles
# --------------------------------------------------------------------------- #
_VTT_TAG = re.compile(r"<[^>]+>")  # <00:00:01.234>, <c>…</c>, alignment tags


def vtt_to_text(vtt: str) -> str:
    """Flatten a WebVTT subtitle blob to deduplicated plain text.

    Strips the WEBVTT header, cue-timing lines, cue numbers, NOTE/STYLE
    blocks and inline ``<…>`` tags, then collapses the rolling-caption
    duplication typical of YouTube auto-subs (each cue repeats the previous
    visible line) with a simple ``line != last`` guard.
    """
    out: list[str] = []
    last: str | None = None
    for raw in vtt.splitlines():
        line = raw.strip()
        if (
            not line
            or line == "WEBVTT"
            or "-->" in line
            or line.isdigit()
            or line.startswith(("Kind:", "Language:", "NOTE", "STYLE"))
        ):
            continue
        line = _VTT_TAG.sub("", line).strip()
        if line and line != last:
            out.append(line)
            last = line
    return " ".join(out)


# --------------------------------------------------------------------------- #
# FTS query building
# --------------------------------------------------------------------------- #
def fts_query(text: str) -> str:
    """Build a safe FTS5 MATCH string: AND of double-quoted terms.

    Raw user input can contain ``-``, ``:``, ``"``, ``*``, ``(`` which are
    FTS5 operators and raise ``fts5: syntax error``. Quoting each whitespace
    term (doubling embedded quotes) turns everything into literal phrase
    tokens. Empty input yields ``""`` which the caller must special-case.
    """
    terms = [t for t in text.split() if t]
    return " ".join('"' + t.replace('"', '""') + '"' for t in terms)


# --------------------------------------------------------------------------- #
# Actions: open / copy / play  (used by launcher shims + tv channel parity)
# --------------------------------------------------------------------------- #
def open_id(video_id: str) -> int:
    """Open the video's watch page in the default browser. Returns exit code."""
    ident = video_id.strip()
    if not VIDEO_ID_RE.match(ident):
        print(f"yth open: not a valid video id: {ident!r}", file=sys.stderr)
        return 2
    import webbrowser

    url = video_url(ident)
    print(f"[yth] open: {url}", file=sys.stderr)
    if not webbrowser.open(url):
        print(
            "yth open: no usable browser opener (open/xdg-open/wslview missing).\n"
            f"  URL: {url}",
            file=sys.stderr,
        )
        return 1
    return 0


def copy_id(video_id: str) -> int:
    """Copy the video URL to the clipboard. Returns exit code.

    Provider chain pbcopy → wl-copy → xclip → OSC 52, matching
    ``scripts/mlf.copy_id`` and the ``yth.toml [actions.copy-url]`` snippet.
    """
    ident = video_id.strip()
    payload = video_url(ident) if VIDEO_ID_RE.match(ident) else ident
    providers = [["pbcopy"], ["wl-copy"], ["xclip", "-selection", "clipboard"]]
    for cmd in providers:
        if shutil.which(cmd[0]):
            try:
                subprocess.run(cmd, input=payload, text=True, check=True)
            except subprocess.CalledProcessError as e:
                print(f"yth copy: {cmd[0]} failed ({e.returncode})", file=sys.stderr)
                continue
            print(f"[yth] copied via {cmd[0]}: {payload}", file=sys.stderr)
            return 0
    try:
        import base64

        b64 = base64.b64encode(payload.encode()).decode()
        with open("/dev/tty", "w") as tty:
            tty.write(f"\033]52;c;{b64}\007")
        print(f"[yth] copied via OSC52: {payload}", file=sys.stderr)
        return 0
    except OSError as e:
        print(f"yth copy: no clipboard provider and OSC52 failed ({e}).", file=sys.stderr)
        return 1


def play_id(video_id: str, cfg: dict | None = None) -> int:
    """Play in mpv when configured + installed, else open in browser."""
    ident = video_id.strip()
    if not VIDEO_ID_RE.match(ident):
        print(f"yth play: not a valid video id: {ident!r}", file=sys.stderr)
        return 2
    cfg = cfg if cfg is not None else load_config()
    url = video_url(ident)
    if cfg.get("open_target") == "mpv" and shutil.which("mpv"):
        print(f"[yth] mpv: {url}", file=sys.stderr)
        return subprocess.run(["mpv", url]).returncode
    return open_id(ident)
