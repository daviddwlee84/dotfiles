"""yth show — one-video detail. DB-only (no network), used two ways:

  - `yth show <id>`            markdown to stdout (human / piping)
  - tv preview pane           `yth show '<id>' | bat -l markdown`  (must be instant)

`--json` emits a structured object (used by the channel's Alt+J action).
"""
from __future__ import annotations

import json
import sys
from dataclasses import dataclass
from typing import Annotated

import tyro

from scripts.yth import connect, fmt_duration, video_url

_DESC_CAP = 4000
_SUBS_CAP = 1600


@dataclass
class Args:
    video_id: Annotated[str, tyro.conf.Positional, tyro.conf.arg(help="YouTube video id.")]
    json_out: Annotated[
        bool, tyro.conf.arg(name="json", help="Emit a JSON object instead of markdown.")
    ] = False


def _load(con, vid: str):
    video = con.execute("SELECT * FROM videos WHERE video_id=?", (vid,)).fetchone()
    stats = con.execute(
        "SELECT watch_count, first_watched, last_watched FROM video_stats WHERE video_id=?",
        (vid,),
    ).fetchone()
    subs = con.execute(
        "SELECT lang, text, fetched_at FROM subtitles WHERE video_id=? ORDER BY lang",
        (vid,),
    ).fetchall()
    return video, stats, subs


def _markdown(video, stats, subs, vid: str) -> str:
    title = (video["title"] if video and video["title"] else vid)
    channel = (video["channel"] if video and video["channel"] else "unknown channel")
    dur = fmt_duration(video["duration"]) if video else "-"
    wc = stats["watch_count"] if stats else 0
    first = stats["first_watched"][:10] if stats and stats["first_watched"] else "-"
    last = stats["last_watched"][:10] if stats and stats["last_watched"] else "-"
    when = f"watched ×{wc}" + (f" · {first}→{last}" if first != last else f" · {last}")

    lines = [
        f"# {title}",
        "",
        f"**{channel}** · {when} · {dur}",
        "",
        video_url(vid),
        "",
    ]
    if video and video["description"]:
        desc = video["description"]
        lines.append(desc[:_DESC_CAP] + ("…" if len(desc) > _DESC_CAP else ""))
    else:
        lines.append("_(not enriched yet — run `yth enrich`)_")

    if subs:
        langs = ", ".join(s["lang"] for s in subs)
        lines += ["", f"## Captions ({langs})", ""]
        text = subs[0]["text"]
        lines.append(text[:_SUBS_CAP] + ("…" if len(text) > _SUBS_CAP else ""))
    else:
        lines += ["", "_(no captions fetched — `yth fetch-subs " + vid + "`)_"]
    return "\n".join(lines) + "\n"


def cli(args: Args) -> int:
    vid = args.video_id.strip()
    con = connect()
    video, stats, subs = _load(con, vid)

    if video is None and stats is None:
        print(f"yth show: no such video in history: {vid}", file=sys.stderr)
        return 1

    if args.json_out:
        obj = {
            "video_id": vid,
            "title": video["title"] if video else None,
            "channel": video["channel"] if video else None,
            "channel_id": video["channel_id"] if video else None,
            "url": video_url(vid),
            "duration": video["duration"] if video else None,
            "upload_date": video["upload_date"] if video else None,
            "description": video["description"] if video else None,
            "enriched_at": video["enriched_at"] if video else None,
            "subs_fetched_at": video["subs_fetched_at"] if video else None,
            "watch_count": stats["watch_count"] if stats else 0,
            "first_watched": stats["first_watched"] if stats else None,
            "last_watched": stats["last_watched"] if stats else None,
            "subtitles": [{"lang": s["lang"], "chars": len(s["text"])} for s in subs],
        }
        print(json.dumps(obj, indent=2, ensure_ascii=False))
        return 0

    sys.stdout.write(_markdown(video, stats, subs, vid))
    return 0


def main() -> int:
    return cli(tyro.cli(Args, prog="yth show"))


if __name__ == "__main__":
    sys.exit(main())
