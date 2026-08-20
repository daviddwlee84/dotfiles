"""yth enrich — fill missing per-video metadata via yt-dlp.

Takeout/sync give us only id + a provisional title + channel. `enrich` fetches
the canonical title, description, duration and upload_date so search covers
descriptions and `show` is useful. **Cookie-free by default** — public videos
need no auth (pass ``--cookies`` to also reach members-only / age-restricted
items using the configured cookie source).

Picks up where it left off: only videos with ``enriched_at IS NULL`` are
fetched. A *permanent* failure (removed / private / unavailable) stamps
``enriched_at`` (sentinel) so a ``--limit`` batch never retries a dead id; a
*transient* failure (bot-check, HTTP 429, network) is left unstamped so a later
run — e.g. with ``--cookies`` or from a cleaner IP — retries it. Re-run to
continue; use ``--force`` to re-enrich everything.
"""
from __future__ import annotations

import re
import sys
import time
from dataclasses import dataclass
from typing import Annotated

import tyro

from scripts.yth import (
    CookieSourceError,
    connect,
    cookie_opts,
    load_config,
    now_iso,
    video_url,
    yt_dlp_runtime_opts,
    ytdl,
)

# Errors that mean the video is gone for good → safe to sentinel-stamp so we
# never retry. Anything NOT matching (bot-check, 429, timeouts, unknown) is
# treated as transient and left unstamped for a future retry.
_PERMANENT_RE = re.compile(
    r"video unavailable|private video|been removed|no longer available|"
    r"does not exist|account.*terminated|removed by the uploader|"
    r"members-only|join this channel|blocked it|not available in your country|"
    r"copyright|age.restricted|inappropriate",
    re.IGNORECASE,
)


@dataclass
class Args:
    limit: Annotated[int, tyro.conf.arg(help="Max videos to enrich this run.")] = 50
    all: Annotated[
        bool, tyro.conf.arg(help="Enrich every pending video (ignores --limit).")
    ] = False
    force: Annotated[
        bool, tyro.conf.arg(help="Re-enrich videos already enriched.")
    ] = False
    cookies: Annotated[
        bool,
        tyro.conf.arg(help="Use the configured cookie source (for restricted videos)."),
    ] = False
    sleep: Annotated[
        float, tyro.conf.arg(help="Seconds to pause between videos (rate-limit).")
    ] = 1.0


def _targets(con, args: Args):
    where = "" if args.force else "WHERE enriched_at IS NULL"
    limit = "" if args.all else f"LIMIT {int(args.limit)}"
    return con.execute(
        f"""
        SELECT v.video_id FROM videos v
        LEFT JOIN video_stats s ON s.video_id = v.video_id
        {where}
        ORDER BY (s.last_watched IS NULL), s.last_watched DESC
        {limit}
        """
    ).fetchall()


def cli(args: Args) -> int:
    con = connect()
    rows = _targets(con, args)
    if not rows:
        print("yth enrich: nothing to do (all videos enriched).", file=sys.stderr)
        return 0

    cfg = load_config()
    opts = {
        "skip_download": True,
        "quiet": True,
        "extract_flat": False,
        "sleep_interval": 1,
        "max_sleep_interval": 3,
        **yt_dlp_runtime_opts(),
    }
    if args.cookies:
        try:
            opts.update(cookie_opts(cfg, required=True))
        except CookieSourceError as e:
            print(f"yth enrich: cookie source rejected — {e}", file=sys.stderr)
            return 2

    yt_dlp = ytdl()
    ok = permanent = transient = 0
    total = len(rows)
    with yt_dlp.YoutubeDL(opts) as ydl:
        for i, row in enumerate(rows, 1):
            vid = row["video_id"]
            try:
                info = ydl.extract_info(video_url(vid), download=False)
            except Exception as e:  # noqa: BLE001
                msg = str(e).splitlines()[0][:120] if str(e) else type(e).__name__
                if _PERMANENT_RE.search(str(e)):
                    # Gone for good — stamp so we don't retry.
                    con.execute(
                        "UPDATE videos SET enriched_at=? WHERE video_id=?",
                        (now_iso(), vid),
                    )
                    con.commit()
                    permanent += 1
                    print(f"  [{i}/{total}] {vid} ✗ unavailable: {msg}", file=sys.stderr)
                else:
                    # Transient (bot-check / 429 / network) — leave unstamped.
                    transient += 1
                    print(f"  [{i}/{total}] {vid} ⟳ transient: {msg}", file=sys.stderr)
            else:
                con.execute(
                    """
                    UPDATE videos SET
                      title       = COALESCE(?, title),
                      description = ?,
                      duration    = ?,
                      upload_date = ?,
                      channel     = COALESCE(?, channel),
                      channel_id  = COALESCE(?, channel_id),
                      enriched_at = ?
                    WHERE video_id = ?
                    """,
                    (
                        info.get("title"),
                        info.get("description"),
                        info.get("duration"),
                        info.get("upload_date"),
                        info.get("channel") or info.get("uploader"),
                        info.get("channel_id"),
                        now_iso(),
                        vid,
                    ),
                )
                con.commit()
                ok += 1
                print(
                    f"  [{i}/{total}] {vid} ✓ {(info.get('title') or '')[:70]}",
                    file=sys.stderr,
                )
            if args.sleep and i < total:
                time.sleep(args.sleep)

    print(
        f"yth enrich: {ok} enriched, {permanent} unavailable (marked done), "
        f"{transient} transient (will retry).",
        file=sys.stderr,
    )
    return 0


def main() -> int:
    return cli(tyro.cli(Args, prog="yth enrich"))


if __name__ == "__main__":
    sys.exit(main())
