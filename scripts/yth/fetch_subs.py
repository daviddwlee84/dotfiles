"""yth fetch-subs — download + index subtitle text for videos.

Fetches manual subs (falling back to auto-captions) via yt-dlp, flattens the
VTT to deduplicated plain text (see ``vtt_to_text``), and stores it so
``yth search --subs`` can match what was *said* in a video. **Cookie-free by
default** for public videos.

Selection (one required):
  <id>...        explicit video ids
  --recent N     the N most-recently-watched pending videos
  --all          every pending video

"Pending" = ``subs_fetched_at IS NULL``; a video with no available captions is
still stamped so it isn't retried (override with ``--force``). Bulk fetching is
sequential + throttled to avoid YouTube rate-limiting.
"""
from __future__ import annotations

import glob
import os
import sys
import tempfile
import time
from dataclasses import dataclass, field
from typing import Annotated

import tyro

from scripts.yth import connect, cookie_opts, load_config, now_iso, video_url, vtt_to_text, ytdl


@dataclass
class Args:
    video_ids: Annotated[
        list[str],
        tyro.conf.Positional,
        tyro.conf.arg(help="Explicit video ids (omit to use --recent/--all)."),
    ] = field(default_factory=list)
    recent: Annotated[
        int, tyro.conf.arg(help="Fetch the N most-recently-watched pending videos.")
    ] = 0
    all: Annotated[bool, tyro.conf.arg(help="Fetch every pending video.")] = False
    force: Annotated[
        bool, tyro.conf.arg(help="Refetch even if subs were already fetched.")
    ] = False
    cookies: Annotated[
        bool, tyro.conf.arg(help="Use the configured cookie source (restricted videos).")
    ] = False
    langs: Annotated[
        list[str],
        tyro.conf.arg(help="Subtitle langs (default: from config, else en/en-US)."),
    ] = field(default_factory=list)
    sleep: Annotated[
        float, tyro.conf.arg(help="Seconds to pause between videos (rate-limit).")
    ] = 1.5


def _select(con, args: Args) -> list[str]:
    if args.video_ids:
        return [v.strip() for v in args.video_ids if v.strip()]
    where = "" if args.force else "WHERE v.subs_fetched_at IS NULL"
    if args.all:
        rows = con.execute(
            f"SELECT v.video_id FROM videos v "
            f"LEFT JOIN video_stats s ON s.video_id=v.video_id {where} "
            f"ORDER BY (s.last_watched IS NULL), s.last_watched DESC"
        ).fetchall()
        return [r["video_id"] for r in rows]
    if args.recent > 0:
        rows = con.execute(
            f"SELECT v.video_id FROM videos v "
            f"LEFT JOIN video_stats s ON s.video_id=v.video_id {where} "
            f"ORDER BY (s.last_watched IS NULL), s.last_watched DESC LIMIT ?",
            (args.recent,),
        ).fetchall()
        return [r["video_id"] for r in rows]
    return []


def fetch_subs_for(yt_dlp, vid: str, langs: list[str], cookies: dict) -> dict[str, str]:
    """Return {lang: plaintext} for one video. Empty dict if no captions."""
    with tempfile.TemporaryDirectory() as td:
        opts = {
            "skip_download": True,
            "writesubtitles": True,
            "writeautomaticsub": True,
            "subtitleslangs": langs,
            "subtitlesformat": "vtt",
            "outtmpl": os.path.join(td, "%(id)s.%(ext)s"),
            "quiet": True,
            "no_warnings": True,
            "sleep_interval_subtitles": 1,
            **cookies,
        }
        with yt_dlp.YoutubeDL(opts) as ydl:
            ydl.download([video_url(vid)])
        out: dict[str, str] = {}
        for path in sorted(glob.glob(os.path.join(td, "*.vtt"))):
            parts = os.path.basename(path).split(".")
            lang = parts[-2] if len(parts) >= 3 else "und"
            text = vtt_to_text(open(path, encoding="utf-8").read())
            if text:
                out[lang] = text
        return out


def cli(args: Args) -> int:
    con = connect()
    targets = _select(con, args)
    if not targets:
        print(
            "yth fetch-subs: no target videos. Pass ids, or --recent N / --all.",
            file=sys.stderr,
        )
        return 2

    cfg = load_config()
    langs = args.langs or cfg.get("langs") or ["en", "en-US"]
    cookies = cookie_opts(cfg) if args.cookies else {}
    yt_dlp = ytdl()

    with_subs = no_subs = failed = 0
    total = len(targets)
    for i, vid in enumerate(targets, 1):
        try:
            subs = fetch_subs_for(yt_dlp, vid, langs, cookies)
        except Exception as e:  # noqa: BLE001
            failed += 1
            msg = str(e).splitlines()[0][:120] if str(e) else type(e).__name__
            print(f"  [{i}/{total}] {vid} ✗ {msg}", file=sys.stderr)
        else:
            for lang, text in subs.items():
                con.execute(
                    "INSERT INTO subtitles(video_id, lang, text, fetched_at) "
                    "VALUES(?, ?, ?, ?) "
                    "ON CONFLICT(video_id, lang) DO UPDATE SET "
                    "  text=excluded.text, fetched_at=excluded.fetched_at",
                    (vid, lang, text, now_iso()),
                )
            con.execute(
                "UPDATE videos SET subs_fetched_at=? WHERE video_id=?", (now_iso(), vid)
            )
            con.commit()
            if subs:
                with_subs += 1
                langs_got = ", ".join(subs)
                print(f"  [{i}/{total}] {vid} ✓ {langs_got}", file=sys.stderr)
            else:
                no_subs += 1
                print(f"  [{i}/{total}] {vid} — no captions", file=sys.stderr)
        if args.sleep and i < total:
            time.sleep(args.sleep)

    print(
        f"yth fetch-subs: {with_subs} with captions, {no_subs} without, {failed} failed.",
        file=sys.stderr,
    )
    return 0


def main() -> int:
    return cli(tyro.cli(Args, prog="yth fetch-subs"))


if __name__ == "__main__":
    sys.exit(main())
