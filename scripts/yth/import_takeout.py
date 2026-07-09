"""yth import-takeout — backfill watch history from a Google Takeout export.

Google Takeout → YouTube and YouTube Music → history → **JSON** produces
``watch-history.json``: a flat array of activity entries. This is the primary,
cookie-free, full-multi-year backfill (yt-dlp `:ythistory` sync only reaches
the recent, page-loadable window).

Idempotent: videos are upserted filling only NULL metadata (never clobbering a
title an `enrich` pass already canonicalised), and each watch is an
``INSERT OR IGNORE`` into ``watch_events`` keyed on (video_id, watched_at), so
re-importing the same export — or an export that overlaps a previous one — adds
nothing. Non-video rows (searches, ads, removed-video placeholders with no
resolvable id) are skipped.

The ``.html`` Takeout variant is intentionally unsupported (brittle,
locale-dependent markup) — see backlog/yth-semantic-search.md.
"""
from __future__ import annotations

import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Annotated
from urllib.parse import urlparse

import tyro

from scripts.yth import connect, extract_video_id, iso_utc

# Localized Takeout prefixes on the `title` field ("Watched <real title>").
# The provisional title is only a fallback — `enrich` overwrites it — so we
# strip the common English prefix and otherwise keep whatever's there.
_TITLE_PREFIXES = ("Watched ",)


@dataclass
class Args:
    file: Annotated[
        str,
        tyro.conf.Positional,
        tyro.conf.arg(help="Path to a Takeout watch-history.json."),
    ]


def _channel_id(url: str | None) -> str | None:
    if not url:
        return None
    path = urlparse(url).path
    if "/channel/" in path:
        return path.split("/channel/", 1)[1].split("/")[0] or None
    return None


def _clean_title(title: str | None) -> str | None:
    if not title:
        return None
    for prefix in _TITLE_PREFIXES:
        if title.startswith(prefix):
            title = title[len(prefix):]
            break
    return title.strip() or None


def cli(args: Args) -> int:
    path = Path(args.file).expanduser()
    if not path.is_file():
        print(f"yth import-takeout: no such file: {path}", file=sys.stderr)
        return 2

    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError) as e:
        print(f"yth import-takeout: {path} is not valid JSON ({e}).", file=sys.stderr)
        return 2
    if not isinstance(data, list):
        print(
            "yth import-takeout: expected a JSON array (the Takeout 'JSON' export,\n"
            "  not the HTML one). Got a "
            f"{type(data).__name__}.",
            file=sys.stderr,
        )
        return 2

    con = connect()
    videos_touched: set[str] = set()
    new_events = 0
    skipped = 0

    for entry in data:
        if not isinstance(entry, dict):
            skipped += 1
            continue
        vid = extract_video_id(entry.get("titleUrl"))
        if vid is None:
            skipped += 1
            continue

        title = _clean_title(entry.get("title"))
        subs = entry.get("subtitles") or []
        channel = subs[0].get("name") if subs else None
        channel_id = _channel_id(subs[0].get("url")) if subs else None

        con.execute(
            """
            INSERT INTO videos(video_id, title, channel, channel_id, url)
            VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(video_id) DO UPDATE SET
              title      = COALESCE(videos.title, excluded.title),
              channel    = COALESCE(videos.channel, excluded.channel),
              channel_id = COALESCE(videos.channel_id, excluded.channel_id),
              url        = COALESCE(videos.url, excluded.url)
            """,
            (vid, title, channel, channel_id, f"https://www.youtube.com/watch?v={vid}"),
        )
        videos_touched.add(vid)

        watched = iso_utc(entry.get("time"))
        if watched:
            cur = con.execute(
                "INSERT OR IGNORE INTO watch_events(video_id, watched_at, source) "
                "VALUES(?, ?, 'takeout')",
                (vid, watched),
            )
            new_events += cur.rowcount

    con.commit()
    total = con.execute("SELECT COUNT(*) FROM videos").fetchone()[0]
    print(
        f"yth import-takeout: {len(videos_touched)} videos in file, "
        f"{new_events} new watch events, {skipped} non-video rows skipped. "
        f"DB now holds {total} videos.",
        file=sys.stderr,
    )
    return 0


def main() -> int:
    return cli(tyro.cli(Args, prog="yth import-takeout"))


if __name__ == "__main__":
    sys.exit(main())
