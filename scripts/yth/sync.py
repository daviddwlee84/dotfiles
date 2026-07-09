"""yth sync — incremental watch-history sync via yt-dlp ``:ythistory``.

Your watch history is account-private, so this **requires login cookies** (see
``cookie_opts`` / config.toml). It reaches only the recent, page-loadable
window — Takeout import is the source of truth for full backfill and accurate
timestamps. ``:ythistory`` carries no per-watch timestamps, so synced watches
are stamped with the sync time (approximate) and tagged ``source='sync'``.

Incremental: entries come newest-first; we walk until we hit ``meta.sync_cursor``
(the newest id from the previous run), inserting ``INSERT OR IGNORE`` watch
events along the way, then advance the cursor. Re-running right away is a no-op.
"""
from __future__ import annotations

import sys
from dataclasses import dataclass
from typing import Annotated

import tyro

from scripts.yth import (
    VIDEO_ID_RE,
    config_dir,
    connect,
    cookie_opts,
    load_config,
    meta_get,
    meta_set,
    now_iso,
    ytdl,
)

_HISTORY_URL = "https://www.youtube.com/feed/history"  # == the :ythistory alias


@dataclass
class Args:
    limit: Annotated[
        int,
        tyro.conf.arg(help="Max history entries to walk from the top (0 = no cap)."),
    ] = 300
    full: Annotated[
        bool,
        tyro.conf.arg(help="Ignore the saved cursor and re-scan up to --limit."),
    ] = False


def _no_cookies_msg() -> str:
    cfg_path = config_dir() / "config.toml"
    return (
        "yth sync: no cookie source configured — watch history is account-private.\n"
        f"  Set one in {cfg_path}:\n"
        '    • Zen (Firefox fork): auto-detected if installed, else\n'
        '        from_browser = "firefox:/path/to/zen/profile"\n'
        '    • Arc / other Chromium: export cookies.txt (e.g. the "Get cookies.txt\n'
        '        LOCALLY" extension), then  cookiefile = "~/.config/yth/cookies.txt"\n'
        "  No cookies needed for full backfill: yth import-takeout <watch-history.json>"
    )


def cli(args: Args) -> int:
    cfg = load_config()
    cookies = cookie_opts(cfg)
    if not cookies:
        print(_no_cookies_msg(), file=sys.stderr)
        return 2

    opts = {
        "extract_flat": True,
        "skip_download": True,
        "quiet": True,
        "no_warnings": True,
        **cookies,
    }
    if args.limit and args.limit > 0:
        opts["playlistend"] = args.limit

    yt_dlp = ytdl()
    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(_HISTORY_URL, download=False)
    except Exception as e:  # noqa: BLE001
        msg = str(e).splitlines()[0][:200] if str(e) else type(e).__name__
        print(
            f"yth sync: could not read history ({msg}).\n"
            "  Cookies may be missing/expired, or YouTube asked to confirm you're\n"
            "  not a bot. Re-export cookies, or use `yth import-takeout` instead.",
            file=sys.stderr,
        )
        return 1

    entries = info.get("entries") or []
    con = connect()
    cursor = None if args.full else meta_get(con, "sync_cursor")
    newest = None
    added = 0
    scanned = 0

    for e in entries:
        vid = (e.get("id") or "").strip()
        if not VIDEO_ID_RE.match(vid):
            continue
        scanned += 1
        if newest is None:
            newest = vid
        if cursor and vid == cursor:
            break
        con.execute(
            """
            INSERT INTO videos(video_id, title, channel, channel_id, url)
            VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(video_id) DO UPDATE SET
              title   = COALESCE(videos.title, excluded.title),
              channel = COALESCE(videos.channel, excluded.channel)
            """,
            (
                vid,
                e.get("title"),
                e.get("uploader") or e.get("channel"),
                e.get("channel_id"),
                f"https://www.youtube.com/watch?v={vid}",
            ),
        )
        cur = con.execute(
            "INSERT OR IGNORE INTO watch_events(video_id, watched_at, source) "
            "VALUES(?, ?, 'sync')",
            (vid, now_iso()),
        )
        added += cur.rowcount

    if newest:
        meta_set(con, "sync_cursor", newest)
    con.commit()
    print(
        f"yth sync: scanned {scanned} history entries, {added} new watch events.",
        file=sys.stderr,
    )
    if scanned and not cursor:
        print(
            "  (first sync — cursor set; future syncs stop here. For full history "
            "use `yth import-takeout`.)",
            file=sys.stderr,
        )
    return 0


def main() -> int:
    return cli(tyro.cli(Args, prog="yth sync"))


if __name__ == "__main__":
    sys.exit(main())
