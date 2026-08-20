"""Shared helpers for the ``ytmv`` CLI (YouTube MV → old MP3 players).

Helpers live here instead of being duplicated per-module — same rationale as
``scripts/yth/__init__.py`` and ``scripts/mlf/__init__.py``. Heavy imports
(``yt_dlp``, ``mutagen``, ``httpx``) are all behind functions so the cheap
subcommands (``ytmv doctor``, ``ytmv tag``) never pay for them.

The point of this tool is everything that happens *after* yt-dlp hands you a
file: old MP3 players want ID3v2.3 rather than v2.4, sometimes want CJK text
as raw Big5/GBK bytes in latin-1-declared frames, often read lyrics only from
a sidecar ``.lrc`` (and sometimes only from an embedded USLT frame), and choke
on long/unicode filenames on FAT32. All of that is expressed as a **profile**
(see ``PROFILES``) so the user can bisect toward whatever their player wants
without re-downloading anything (``ytmv tag``).

Storage (via ``platformdirs``, honours ``XDG_*``):
    config   user_config_dir/ytmv/config.toml
    cache    user_cache_dir/ytmv/lrclib/*.json
    output   ~/Music/ytmv  (override: config ``out``, or ``--out``)

Cookie configuration is deliberately NOT duplicated here — it is read from
``yth``'s config via ``scripts.yth.cookie_opts`` so the Arc/Zen cookie story
is documented and configured in exactly one place (docs/tools/yth.md).
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

APP = "ytmv"

# Bump to invalidate every cached LRCLIB response (appsrc's _CACHE_VERSION idiom).
_CACHE_VERSION = "v1"

LRCLIB_BASE = "https://lrclib.net/api"
USER_AGENT = f"ytmv/{_CACHE_VERSION} (+https://github.com/daviddwlee84/dotfiles)"


# --------------------------------------------------------------------------- #
# Paths
# --------------------------------------------------------------------------- #
def _dirs() -> tuple[Path, Path]:
    """Return ``(config_dir, cache_dir)``; platformdirs imported lazily."""
    import platformdirs

    return (
        Path(platformdirs.user_config_dir(APP)),
        Path(platformdirs.user_cache_dir(APP)),
    )


def config_dir() -> Path:
    """Config dir. Deliberately NOT created — absence is the normal state."""
    return _dirs()[0]


def cache_dir() -> Path:
    cache = _dirs()[1]
    cache.mkdir(parents=True, exist_ok=True)
    return cache


def default_out_dir() -> Path:
    """Default download target. ``$YTMV_OUT`` overrides (tests).

    This is user *media*, not application state, so it goes under the music dir
    (which honours XDG_MUSIC_DIR on Linux) rather than an XDG data dir.
    """
    env = os.environ.get("YTMV_OUT")
    if env:
        return Path(env).expanduser()
    try:
        import platformdirs

        return Path(platformdirs.user_music_dir()) / APP
    except (ImportError, AttributeError):
        return Path.home() / "Music" / APP


# --------------------------------------------------------------------------- #
# Player-compatibility profiles
# --------------------------------------------------------------------------- #
# Every knob an old player might care about. `safe` is the broadest-compatibility
# bet for an UNKNOWN player; the others are the escape hatches you reach for when
# the device shows garbage. `ytmv tag` re-applies any of these to files you have
# already downloaded, so bisecting costs nothing.
#
#   id3_version         3 = ID3v2.3 (what most pre-2010 players parse), 4 = v2.4
#   id3_encoding        utf16 | utf8 | latin1 | raw-big5 | raw-gbk  (see below)
#   lrc_sidecar         write "<basename>.lrc" next to the audio file
#   lrc_encoding        text encoding of that sidecar
#   lrc_on_unencodable  strict = fail loudly; replace = substitute "?"
#   embed_uslt          embed unsynced lyrics in an ID3 USLT frame
#   embed_sylt          embed synced lyrics in an ID3 SYLT frame (rarely read)
#   cover               "jpeg" or "none"
#   cover_max           longest edge, px
#   filename_charset    unicode | ascii  (ascii strips/transliterates non-ASCII)
#   filename_max        max characters in the stem (FAT32 path budgets are tight)
#   number_prefix       "01 - Title.mp3"; many players sort by filename/FAT order
PROFILES: dict[str, dict] = {
    "safe": {
        "id3_version": 3,
        "id3_encoding": "utf16",
        "lrc_sidecar": True,
        "lrc_encoding": "utf-8",
        "lrc_on_unencodable": "strict",
        "embed_uslt": True,
        "embed_sylt": False,
        "cover": "jpeg",
        "cover_max": 300,
        "filename_charset": "unicode",
        "filename_max": 120,
        "number_prefix": False,
    },
    "cjk-big5": {
        "id3_version": 3,
        "id3_encoding": "raw-big5",
        "lrc_sidecar": True,
        # cp950, not bare "big5": cp950 is the Microsoft superset that player
        # firmware and Windows-derived toolchains actually implement. Strict
        # big5 raises on characters real players render fine (verified: 碁, ～, ‧).
        "lrc_encoding": "cp950",
        "lrc_on_unencodable": "strict",
        "embed_uslt": True,
        "embed_sylt": False,
        "cover": "jpeg",
        "cover_max": 300,
        "filename_charset": "unicode",
        "filename_max": 120,
        "number_prefix": False,
    },
    "cjk-gbk": {
        "id3_version": 3,
        "id3_encoding": "raw-gbk",
        "lrc_sidecar": True,
        "lrc_encoding": "gbk",
        "lrc_on_unencodable": "strict",
        "embed_uslt": True,
        "embed_sylt": False,
        "cover": "jpeg",
        "cover_max": 300,
        "filename_charset": "unicode",
        "filename_max": 120,
        "number_prefix": False,
    },
    "ipod": {
        # iPod/Sansa/Walkman-era players read embedded lyrics, not sidecars.
        "id3_version": 3,
        "id3_encoding": "utf16",
        "lrc_sidecar": False,
        "lrc_encoding": "utf-8",
        "lrc_on_unencodable": "strict",
        "embed_uslt": True,
        "embed_sylt": False,
        "cover": "jpeg",
        "cover_max": 300,
        "filename_charset": "unicode",
        "filename_max": 120,
        "number_prefix": False,
    },
    "modern": {
        "id3_version": 4,
        "id3_encoding": "utf8",
        "lrc_sidecar": True,
        "lrc_encoding": "utf-8",
        "lrc_on_unencodable": "strict",
        "embed_uslt": True,
        "embed_sylt": False,
        "cover": "jpeg",
        "cover_max": 600,
        "filename_charset": "unicode",
        "filename_max": 200,
        "number_prefix": False,
    },
}

DEFAULT_PROFILE = "safe"

# id3_encoding -> the codec its raw-bytes variant smuggles. See tag_mp3().
_RAW_ID3_CODECS = {"raw-big5": "cp950", "raw-gbk": "gbk"}


# --------------------------------------------------------------------------- #
# Config
# --------------------------------------------------------------------------- #
def load_config() -> dict:
    """Read ``config.toml`` if present; a malformed file degrades, never fatals.

    Recognised top-level keys: ``profile``, ``out``, ``ffmpeg``, ``langs``,
    ``audio_quality``, ``cookiefile`` / ``from_browser`` (override yth's), plus
    any profile setting as a global default. User profiles live under
    ``[profiles.<name>]``.
    """
    cfg: dict = {}
    path = config_dir() / "config.toml"
    if path.is_file():
        import tomllib

        try:
            cfg = tomllib.loads(path.read_text(encoding="utf-8"))
        except tomllib.TOMLDecodeError as e:
            print(f"ytmv: ignoring malformed {path}: {e}", file=sys.stderr)
            cfg = {}
    return cfg


def resolve_profile(cfg: dict, name: str = "", overrides: dict | None = None) -> dict:
    """Merge, in increasing precedence:

    built-in profile → user ``[profiles.<name>]`` → config top-level defaults →
    explicit CLI overrides. Raises ``KeyError`` for an unknown profile name.
    """
    chosen = name or cfg.get("profile") or DEFAULT_PROFILE
    user_profiles = cfg.get("profiles") or {}
    if chosen not in PROFILES and chosen not in user_profiles:
        known = ", ".join(profile_names(cfg))
        raise KeyError(f"unknown profile '{chosen}' (known: {known})")

    settings = dict(PROFILES.get(chosen, PROFILES[DEFAULT_PROFILE]))
    settings.update(user_profiles.get(chosen) or {})
    # Top-level config keys act as cross-profile defaults.
    for key in PROFILES[DEFAULT_PROFILE]:
        if key in cfg:
            settings[key] = cfg[key]
    for key, value in (overrides or {}).items():
        if value is not None:
            settings[key] = value
    settings["_name"] = chosen
    return settings


def profile_names(cfg: dict | None = None) -> list[str]:
    names = set(PROFILES)
    names.update((cfg or {}).get("profiles") or {})
    return sorted(names)


def resolve_cookie_config(cfg: dict) -> tuple[dict, str]:
    """Return the effective cookie config and its non-secret owner label.

    ``ytmv`` may override the shared ``yth`` source, but both download and
    doctor must follow the same precedence. The returned mapping is never
    printed wholesale because it can contain a sensitive cookie-file path.
    """
    if cfg.get("cookiefile") or cfg.get("from_browser"):
        return cfg, "ytmv"

    from scripts.yth import load_config as yth_config

    shared = yth_config()
    if shared.get("cookiefile") or shared.get("from_browser"):
        return shared, "yth"
    return {}, "none"


def cookie_options(cfg: dict, enabled: bool) -> dict:
    """yt-dlp cookie kwargs. Reuses ``yth``'s config unless ytmv overrides it."""
    if not enabled:
        return {}

    from scripts.yth import cookie_opts

    effective, _owner = resolve_cookie_config(cfg)
    return cookie_opts(effective, required=True)


# --------------------------------------------------------------------------- #
# ffmpeg (+ the libass probe that gates --burn-subs)
# --------------------------------------------------------------------------- #
_LIBASS_CACHE: dict[str, bool] = {}

# Keg-only Homebrew formulae that DO link libass. Being keg-only, installing one
# does not shadow or conflict with the plain `ffmpeg` on PATH — which is exactly
# why this is a safe fix to recommend.
_BREW_FFMPEG_CANDIDATES = ("ffmpeg-full", "ffmpeg@7", "ffmpeg@6")


def ffmpeg_bin(cfg: dict | None = None) -> str | None:
    """Resolve the ffmpeg to use: config ``ffmpeg`` → keg-only brew → PATH."""
    import shutil

    configured = (cfg or {}).get("ffmpeg")
    if configured:
        path = os.path.expanduser(str(configured))
        return path if os.access(path, os.X_OK) else None

    for formula in _BREW_FFMPEG_CANDIDATES:
        candidate = _brew_prefix(formula)
        if candidate:
            exe = Path(candidate) / "bin" / "ffmpeg"
            if os.access(exe, os.X_OK):
                return str(exe)
    return shutil.which("ffmpeg")


def _brew_prefix(formula: str) -> str | None:
    """`brew --prefix <formula>` or None. Probed by OUTPUT, never exit status.

    A stub `brew` returns 0 with empty output for every subcommand — the trap
    documented in CLAUDE.md's Homebrew rule.
    """
    import shutil
    import subprocess

    brew = shutil.which("brew")
    if not brew:
        return None
    try:
        out = subprocess.run(
            [brew, "--prefix", formula],
            capture_output=True, text=True, check=False, timeout=10,
        )
    except (subprocess.TimeoutExpired, OSError):
        return None
    prefix = out.stdout.strip()
    return prefix if out.returncode == 0 and prefix else None


def has_libass(ffmpeg: str) -> bool:
    """True when this ffmpeg exposes the ``subtitles`` filter (i.e. libass).

    Homebrew-core's plain `ffmpeg` 8.x is built WITHOUT libass, so burning
    subtitles into the picture silently has no available filter. Probed by
    parsing `-filters` rather than the configure line, because a build can link
    libass without advertising it in `-version`.
    """
    if ffmpeg in _LIBASS_CACHE:
        return _LIBASS_CACHE[ffmpeg]
    import subprocess

    ok = False
    try:
        out = subprocess.run(
            [ffmpeg, "-hide_banner", "-filters"],
            capture_output=True, text=True, check=False, timeout=20,
        )
        for line in out.stdout.splitlines():
            # Format: " ... subtitles         V->V       Render text subtitles..."
            parts = line.split()
            if len(parts) >= 2 and parts[1] == "subtitles":
                ok = True
                break
    except (subprocess.TimeoutExpired, OSError):
        ok = False
    _LIBASS_CACHE[ffmpeg] = ok
    return ok


def libass_help(ffmpeg: str | None) -> str:
    """The remediation text shown when --burn-subs has no libass to work with."""
    where = ffmpeg or "<none found>"
    return (
        f"ytmv: --burn-subs needs an ffmpeg built with libass; {where} has no\n"
        "  'subtitles' filter (checked via `ffmpeg -hide_banner -filters`).\n"
        "  Fix one of these ways:\n"
        "    macOS   brew install ffmpeg-full   (keg-only: does NOT shadow `ffmpeg`)\n"
        "    Debian  apt install ffmpeg         (Debian builds link libass)\n"
        "    any     set  ffmpeg = \"/path/to/ffmpeg\"  in ~/.config/ytmv/config.toml\n"
        "  Or drop --burn-subs and use --soft-subs (many old players ignore those)."
    )


def run_ffmpeg(ffmpeg: str, args: list[str], timeout: int = 900,
               cwd: str | None = None) -> tuple[int, str]:
    """Run ffmpeg quietly; return ``(returncode, stderr_tail)``."""
    import subprocess

    cmd = [ffmpeg, "-hide_banner", "-loglevel", "error", "-y", *args]
    try:
        out = subprocess.run(
            cmd, capture_output=True, text=True, check=False, timeout=timeout,
            cwd=cwd,
        )
    except subprocess.TimeoutExpired:
        return 1, f"timed out after {timeout}s"
    except OSError as e:
        return 1, str(e)
    return out.returncode, out.stderr.strip()[-2000:]


# --------------------------------------------------------------------------- #
# LRC parsing / writing / conversion
# --------------------------------------------------------------------------- #
# [mm:ss.xx] / [mm:ss.xxx] / [mm:ss:xx] / [mm:ss] — several may prefix one line.
_LRC_TIME = re.compile(r"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]")
_LRC_META = re.compile(r"^\[(ar|ti|al|au|by|re|ve|length|offset):(.*)\]\s*$", re.I)


def parse_lrc(text: str) -> tuple[list[tuple[int, str]], dict[str, str]]:
    """Parse LRC into ``([(start_ms, line)], metadata)``, sorted by time.

    Metadata tags are returned separately, never as lyric lines. ``[offset:]``
    (milliseconds, positive = shift later) is applied to every timestamp.
    """
    cues: list[tuple[int, str]] = []
    meta: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.rstrip()
        if not line:
            continue
        m = _LRC_META.match(line)
        if m:
            meta[m.group(1).lower()] = m.group(2).strip()
            continue
        stamps = list(_LRC_TIME.finditer(line))
        if not stamps:
            continue
        content = _LRC_TIME.sub("", line).strip()
        for s in stamps:
            minutes, seconds, frac = s.group(1), s.group(2), s.group(3) or "0"
            # ".5" is 500ms, ".50" is 500ms, ".500" is 500ms — pad, don't parse raw.
            millis = int(frac.ljust(3, "0")[:3])
            cues.append((int(minutes) * 60_000 + int(seconds) * 1000 + millis, content))

    offset = 0
    if "offset" in meta:
        try:
            offset = int(float(meta["offset"]))
        except ValueError:
            offset = 0
    if offset:
        cues = [(max(0, t + offset), s) for t, s in cues]

    cues.sort(key=lambda c: c[0])
    return cues, meta


def lrc_to_plain(text: str) -> str:
    """Strip timestamps/metadata, keeping line order — for USLT."""
    cues, _ = parse_lrc(text)
    if cues:
        return "\n".join(s for _, s in cues if s)
    # Not an LRC at all (e.g. LRCLIB plainLyrics): pass through unchanged.
    return text.strip()


def dedupe_lrc(text: str) -> str:
    """Collapse YouTube's rolling auto-caption repetition into readable LRC.

    Auto-captions re-emit the previously visible line with every new cue, so a
    straight VTT→LRC conversion produces each lyric two or three times over. We
    drop a cue when it repeats — or is wholly contained in — the cue we last
    kept. yt-dlp's own ``--convert-subs lrc`` does no such deduplication, which
    is why its output is unusable as lyrics for a music video.
    """
    cues, _ = parse_lrc(text)
    if not cues:
        return text
    kept: list[tuple[int, str]] = []
    for start, content in cues:
        stripped = content.strip()
        if not stripped:
            continue
        if kept:
            previous = kept[-1][1]
            if stripped == previous or stripped in previous:
                continue
            # The rolling window case: the new cue starts with what we just kept.
            if stripped.startswith(previous):
                kept[-1] = (kept[-1][0], stripped)
                continue
        kept.append((start, stripped))
    return "\n".join(f"[{ms // 60000:02d}:{(ms % 60000) / 1000:05.2f}]{s}"
                     for ms, s in kept)


def _srt_time(ms: int) -> str:
    ms = max(0, ms)
    hours, rem = divmod(ms, 3_600_000)
    minutes, rem = divmod(rem, 60_000)
    seconds, millis = divmod(rem, 1000)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d},{millis:03d}"


def lrc_to_srt(text: str, tail_ms: int = 5000) -> str:
    """Convert LRC to SRT so ffmpeg can burn it into the picture.

    LRC carries only START times, so each cue ends where the next begins and the
    final cue gets ``tail_ms``. Cues sharing a timestamp (LRC's way of stacking
    e.g. original + translation) are merged into one multi-line cue rather than
    emitted as zero-length overlapping subtitles.
    """
    cues, _ = parse_lrc(text)
    if not cues:
        return ""

    merged: list[tuple[int, list[str]]] = []
    for start, content in cues:
        if merged and merged[-1][0] == start:
            if content:
                merged[-1][1].append(content)
        else:
            merged.append((start, [content] if content else []))

    blocks: list[str] = []
    index = 0
    for i, (start, lines) in enumerate(merged):
        if not lines:
            continue  # blank cue (instrumental gap marker) — no subtitle to show
        end = merged[i + 1][0] if i + 1 < len(merged) else start + tail_ms
        if end <= start:
            end = start + tail_ms
        index += 1
        blocks.append(
            f"{index}\n{_srt_time(start)} --> {_srt_time(end)}\n" + "\n".join(lines)
        )
    return "\n\n".join(blocks) + ("\n" if blocks else "")


class UnencodableLyrics(Exception):
    """Raised when the target .lrc encoding cannot represent the lyrics."""


def encode_text(text: str, encoding: str, on_unencodable: str = "strict") -> bytes:
    """Encode ``text``, reporting the exact offending character on failure.

    Big5 cannot represent kana or accented Latin; GBK cannot represent some
    symbols; neither covers non-BMP. ``errors="replace"`` would silently turn a
    line into '?' — hence ``strict`` is the default and this raises instead.
    """
    try:
        return text.encode(encoding)
    except UnicodeEncodeError as e:
        if on_unencodable == "replace":
            return text.encode(encoding, errors="replace")
        bad = text[e.start:e.end]
        line_no = text.count("\n", 0, e.start) + 1
        raise UnencodableLyrics(
            f"{encoding} cannot encode {bad!r} (U+{ord(bad[0]):04X}) on line {line_no}. "
            f"Use --lrc-encoding utf-8, or --lrc-on-unencodable replace to accept '?'."
        ) from e


def write_lrc(path: Path, text: str, encoding: str, on_unencodable: str = "strict") -> None:
    """Write a sidecar .lrc in the player's expected encoding."""
    path.write_bytes(encode_text(text, encoding, on_unencodable))


# --------------------------------------------------------------------------- #
# Filenames (FAT32 / old-player safe)
# --------------------------------------------------------------------------- #
_FAT_ILLEGAL = re.compile(r'[<>:"/\\|?*\x00-\x1f]')
_WINDOWS_RESERVED = {
    "CON", "PRN", "AUX", "NUL",
    *(f"COM{i}" for i in range(1, 10)),
    *(f"LPT{i}" for i in range(1, 10)),
}


def sanitize_filename(stem: str, charset: str = "unicode", max_len: int = 120) -> str:
    """Make ``stem`` safe for a FAT32 card in an old player.

    Strips FAT-illegal characters and control codes, collapses whitespace, drops
    trailing dots/spaces (Windows/FAT cannot represent them), avoids reserved
    device names, and caps length in characters. ``charset="ascii"`` additionally
    transliterates/strips non-ASCII, for players that render CJK filenames blank.
    """
    import unicodedata

    out = _FAT_ILLEGAL.sub("_", stem)
    if charset == "ascii":
        decomposed = unicodedata.normalize("NFKD", out)
        out = decomposed.encode("ascii", errors="ignore").decode("ascii")
    out = re.sub(r"\s+", " ", out).strip()
    out = out.rstrip(". ")
    if not out:
        out = "untitled"
    if out.split(".")[0].upper() in _WINDOWS_RESERVED:
        out = f"_{out}"
    if len(out) > max_len:
        out = out[:max_len].rstrip(". ")
    return out or "untitled"


# --------------------------------------------------------------------------- #
# Artist / track extraction
# --------------------------------------------------------------------------- #
# Noise that channel uploads bolt onto music-video titles.
_TITLE_NOISE = re.compile(
    r"""\s*(?:
          \((?:[^()]*\b(?:official|music|lyric|lyrics|video|mv|audio|hd|4k|
                          live|visualizer|performance|ver\.?|version)\b[^()]*)\)
        | \[(?:[^\[\]]*\b(?:official|music|lyric|lyrics|video|mv|audio|hd|4k|
                          live|visualizer|performance)\b[^\[\]]*)\]
        | 【[^】]*】
        | \|\s*(?:official|music|lyric|lyrics)\b.*$
        )""",
    re.I | re.X,
)
# Common "Artist - Title" separators, including CJK full-width dashes.
_ARTIST_SEP = re.compile(r"\s+[-–—－]\s+|\s*[|｜]\s*")


def clean_title(title: str) -> str:
    previous = None
    out = title
    while out != previous:
        previous = out
        out = _TITLE_NOISE.sub("", out).strip()
    return out.strip(" -–—|·").strip()


def parse_artist_track(info: dict, artist: str = "", track: str = "", album: str = "") -> dict:
    """Resolve artist/track/album, recording WHICH rung of the chain fired.

    Chain: explicit flags → yt-dlp's music metadata (populated for YouTube
    Music-category videos) → "Artist - Title" split of the cleaned video title →
    channel name as artist. The ``source`` field is surfaced by ``--json`` so a
    wrong LRCLIB match is diagnosable rather than mysterious.
    """
    result = {
        "artist": artist.strip(),
        "track": track.strip(),
        "album": album.strip(),
        "year": None,
        "source": "flags",
    }

    if not result["artist"] or not result["track"]:
        meta_artist = (info.get("artist") or info.get("creator") or "").strip()
        meta_track = (info.get("track") or "").strip()
        if meta_artist and meta_track:
            result["artist"] = result["artist"] or meta_artist
            result["track"] = result["track"] or meta_track
            result["source"] = "yt-dlp-music-metadata"

    if not result["artist"] or not result["track"]:
        cleaned = clean_title(info.get("title") or "")
        parts = _ARTIST_SEP.split(cleaned, maxsplit=1)
        if len(parts) == 2 and all(p.strip() for p in parts):
            result["artist"] = result["artist"] or parts[0].strip()
            result["track"] = result["track"] or parts[1].strip()
            result["source"] = "title-split"
        else:
            result["track"] = result["track"] or cleaned
            channel = (info.get("channel") or info.get("uploader") or "").strip()
            # "Foo - Topic" is YouTube's auto-generated artist channel naming.
            channel = re.sub(r"\s*-\s*Topic$", "", channel)
            result["artist"] = result["artist"] or channel
            result["source"] = "channel-fallback"

    if not result["album"]:
        result["album"] = (info.get("album") or "").strip()
    year = info.get("release_year")
    if not year and info.get("upload_date"):
        year = str(info["upload_date"])[:4]
    result["year"] = str(year) if year else None
    return result


# --------------------------------------------------------------------------- #
# LRCLIB
# --------------------------------------------------------------------------- #
_CACHE_TTL_SECONDS = 30 * 24 * 3600


def _cache_path(kind: str, key: str) -> Path:
    import hashlib

    digest = hashlib.sha256(f"{_CACHE_VERSION}:{kind}:{key}".encode()).hexdigest()[:32]
    root = cache_dir() / "lrclib"
    root.mkdir(parents=True, exist_ok=True)
    return root / f"{kind}-{digest}.json"


def _cache_read(path: Path):
    import json
    import time

    if not path.is_file():
        return None
    if time.time() - path.stat().st_mtime > _CACHE_TTL_SECONDS:
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def _cache_write(path: Path, payload) -> None:
    import json

    try:
        path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    except OSError:
        pass  # a cache we cannot write is not an error worth failing the run for


def _http_get(url: str, params: dict, timeout: float = 10.0):
    """GET JSON from LRCLIB. Returns None on 404 / any network failure.

    Network trouble must never be fatal — the caller falls through to the next
    rung of the lyrics chain.
    """
    import httpx

    try:
        response = httpx.get(
            url, params=params, timeout=timeout, headers={"User-Agent": USER_AGENT}
        )
    except httpx.HTTPError as e:
        print(f"ytmv: lrclib unreachable ({type(e).__name__}) — skipping", file=sys.stderr)
        return None
    if response.status_code == 404:
        return None
    if response.status_code != 200:
        print(f"ytmv: lrclib returned HTTP {response.status_code}", file=sys.stderr)
        return None
    try:
        return response.json()
    except ValueError:
        return None


def lrclib_get(artist: str, track: str, duration: float | None, album: str = "",
               use_cache: bool = True):
    """Exact LRCLIB lookup. ``album`` and ``duration`` are optional but sharpen it."""
    params = {"artist_name": artist, "track_name": track}
    if album:
        params["album_name"] = album
    if duration:
        params["duration"] = int(round(duration))
    key = repr(sorted(params.items()))
    path = _cache_path("get", key)
    if use_cache:
        cached = _cache_read(path)
        if cached is not None:
            return cached or None
    payload = _http_get(f"{LRCLIB_BASE}/get", params)
    if use_cache:
        _cache_write(path, payload or {})
    return payload


def lrclib_search(query: str, use_cache: bool = True) -> list[dict]:
    path = _cache_path("search", query)
    if use_cache:
        cached = _cache_read(path)
        if cached is not None:
            return cached
    payload = _http_get(f"{LRCLIB_BASE}/search", {"q": query}) or []
    if not isinstance(payload, list):
        payload = []
    if use_cache:
        _cache_write(path, payload)
    return payload


def rank_hits(hits: list[dict], artist: str, track: str,
              duration: float | None) -> list[dict]:
    """Sort search hits best-first: duration proximity, then name similarity."""
    from difflib import SequenceMatcher

    def score(hit: dict) -> tuple:
        delta = abs((hit.get("duration") or 0) - duration) if duration else 999.0
        artist_sim = SequenceMatcher(
            None, (hit.get("artistName") or "").lower(), artist.lower()
        ).ratio()
        track_sim = SequenceMatcher(
            None, (hit.get("trackName") or "").lower(), track.lower()
        ).ratio()
        has_synced = 1 if hit.get("syncedLyrics") else 0
        return (-has_synced, delta, -(artist_sim + track_sim))

    return sorted(hits, key=score)


def pick_hit(hits: list[dict], artist: str, track: str, duration: float | None,
             tolerance: float = 3.0) -> dict | None:
    """Auto-pick a search hit only when it is unambiguous.

    Requires a synced-lyrics hit inside the duration tolerance. A near-tie with
    the runner-up means we decline rather than guess — `ytmv lyrics --pick` is
    the place to resolve those by hand.
    """
    ranked = rank_hits(hits, artist, track, duration)
    if not ranked:
        return None
    best = ranked[0]
    if not best.get("syncedLyrics"):
        return None
    if duration and abs((best.get("duration") or 0) - duration) > tolerance:
        return None
    return best


# --------------------------------------------------------------------------- #
# yt-dlp (lazy)
# --------------------------------------------------------------------------- #
def yt_dlp_runtime_opts() -> dict:
    """Use the same managed Node runtime as the sibling ``yth`` CLI."""
    from scripts.yth import yt_dlp_runtime_opts as shared_runtime_opts

    return shared_runtime_opts()


def ytdl():
    """Lazily import and return the ``yt_dlp`` module.

    Behind a function so `ytmv doctor` / `ytmv tag` — which never touch the
    network — do not pay its import cost.
    """
    import yt_dlp

    return yt_dlp


# --------------------------------------------------------------------------- #
# ID3 tagging (mutagen owns this, not yt-dlp)
# --------------------------------------------------------------------------- #
# yt-dlp's --embed-metadata/--embed-thumbnail postprocessors always write
# ID3v2.4 and cannot do a v2.3 downgrade, raw-Big5 frames, USLT or SYLT. They
# are therefore disabled in get.py and everything below is mutagen's job —
# letting both write produces duplicate/conflicting frames.
def _id3_encoding_id(name: str) -> int:
    """mutagen Encoding id for a profile's ``id3_encoding``."""
    return {
        "latin1": 0,
        "raw-big5": 0,   # bytes are Big5; the frame claims latin-1 (see tag_mp3)
        "raw-gbk": 0,    # ditto for GBK
        "utf16": 1,
        "utf8": 3,
    }.get(name, 1)


def _encode_frame_text(text: str, id3_encoding: str) -> str:
    """Prepare a string for an ID3 frame under the profile's encoding.

    For ``raw-big5`` / ``raw-gbk`` this performs a DELIBERATE spec violation:
    many old Chinese-market players ignore the frame's declared encoding byte
    and assume the local codepage, so we encode the text to Big5/GBK and then
    reinterpret those bytes as latin-1. mutagen re-encodes latin-1 losslessly,
    so the file ends up holding the raw Big5/GBK bytes the player expects.
    Do NOT "fix" this to a proper encoding — it is what makes those units work.
    """
    codec = _RAW_ID3_CODECS.get(id3_encoding)
    if not codec:
        return text
    return text.encode(codec, errors="replace").decode("latin-1")


def tag_mp3(path: Path, meta: dict, settings: dict, lyrics_text: str = "",
            synced_lrc: str = "", cover: bytes | None = None) -> None:
    """Write ID3 tags onto ``path`` according to the resolved profile.

    ``meta`` keys: artist, track, album, year, track_number (optional).
    ``lyrics_text`` is plain (unsynced) text for USLT; ``synced_lrc`` is raw LRC
    used for SYLT when the profile enables it.
    """
    from mutagen.id3 import (
        APIC, ID3, ID3NoHeaderError, SYLT, TALB, TDRC, TIT2, TPE1, TRCK, USLT,
    )

    try:
        tags = ID3(path)
    except ID3NoHeaderError:
        tags = ID3()

    enc = _id3_encoding_id(settings["id3_encoding"])
    raw = settings["id3_encoding"]

    def frame_text(value: str) -> str:
        return _encode_frame_text(value, raw)

    # Replace rather than append: re-tagging must be idempotent.
    for key in ("TIT2", "TPE1", "TALB", "TDRC", "TRCK"):
        tags.delall(key)
    tags.delall("USLT")
    tags.delall("SYLT")

    if meta.get("track"):
        tags.add(TIT2(encoding=enc, text=frame_text(meta["track"])))
    if meta.get("artist"):
        tags.add(TPE1(encoding=enc, text=frame_text(meta["artist"])))
    if meta.get("album"):
        tags.add(TALB(encoding=enc, text=frame_text(meta["album"])))
    if meta.get("year"):
        tags.add(TDRC(encoding=enc, text=str(meta["year"])))
    if meta.get("track_number"):
        tags.add(TRCK(encoding=enc, text=str(meta["track_number"])))

    if lyrics_text and settings.get("embed_uslt"):
        tags.add(USLT(encoding=enc, lang="und", desc="", text=frame_text(lyrics_text)))

    if synced_lrc and settings.get("embed_sylt"):
        cues, _ = parse_lrc(synced_lrc)
        if cues:
            tags.add(
                SYLT(
                    encoding=enc, lang="und",
                    format=2,  # 2 = timestamps are milliseconds
                    type=1,    # 1 = lyrics
                    desc="",
                    text=[(frame_text(line), ms) for ms, line in cues if line],
                )
            )

    if cover and settings.get("cover") != "none":
        tags.delall("APIC")
        tags.add(APIC(encoding=0, mime="image/jpeg", type=3, desc="", data=cover))

    if int(settings["id3_version"]) == 3:
        # v2.3 has no TDRC; mutagen rewrites it to TYER/TDAT for us.
        tags.update_to_v23()
        tags.save(path, v2_version=3)
    else:
        tags.save(path, v2_version=4)


def make_cover(ffmpeg: str, source: Path, dest: Path, max_edge: int) -> bool:
    """Downscale/convert a thumbnail to a small JPEG with ffmpeg (no ImageMagick).

    Old players choke on large or non-JPEG cover art; ffmpeg is already a hard
    dependency for audio extraction, so this adds nothing new to install.
    """
    code, _ = run_ffmpeg(
        ffmpeg,
        [
            "-i", str(source),
            "-vf", f"scale='min({max_edge},iw)':-1",
            "-frames:v", "1",
            "-f", "mjpeg", str(dest),
        ],
        timeout=120,
    )
    return code == 0 and dest.is_file() and dest.stat().st_size > 0
