"""yth list — dump watch history, newest first.

Default output is a rich.Table for terminal browsing. ``--tsv`` emits the
tab-separated layout the `tv yth` channel consumes as its source (column 0 =
video_id, which tv hands to the preview + action commands).

DB-only: never imports yt_dlp, so it stays instant as a tv source.
"""
from __future__ import annotations

import sys
from dataclasses import dataclass
from typing import Annotated

import tyro
from rich.console import Console
from rich.table import Table

from scripts.yth import connect, fmt_duration, short_date

# tv wants the whole history in one shot; it does the fuzzy filtering itself.
# 20k rows is trivial for television; the cap is a runaway guard only.
_TSV_CAP = 20000
_TABLE_CAP = 200


@dataclass
class Args:
    tsv: Annotated[
        bool,
        tyro.conf.arg(help="Emit TSV for the `tv yth` source instead of a table."),
    ] = False
    limit: Annotated[
        int,
        tyro.conf.arg(help="Max rows (-1 = auto: 20000 for --tsv, 200 for the table)."),
    ] = -1


def _rows(con, limit: int):
    return con.execute(
        """
        SELECT v.video_id, v.title, v.channel, v.duration,
               s.watch_count, s.last_watched
        FROM videos v
        LEFT JOIN video_stats s ON s.video_id = v.video_id
        ORDER BY (s.last_watched IS NULL), s.last_watched DESC, v.id DESC
        LIMIT ?
        """,
        (limit,),
    ).fetchall()


def _clean(value) -> str:
    """Scrub tab/newline so a cell can't break the TSV column framing."""
    return str(value or "").replace("\t", " ").replace("\r", " ").replace("\n", " ").strip()


def _marker(watch_count) -> str:
    n = watch_count or 1
    return "▶" if n <= 1 else f"×{n}"


def cli(args: Args) -> int:
    con = connect()
    if args.limit >= 0:
        limit = args.limit
    else:
        limit = _TSV_CAP if args.tsv else _TABLE_CAP
    rows = _rows(con, limit)

    if args.tsv:
        out = []
        for r in rows:
            out.append(
                "\t".join(
                    (
                        r["video_id"],
                        _marker(r["watch_count"]),
                        _clean(r["channel"]) or "-",
                        _clean(r["title"]) or r["video_id"],
                        short_date(r["last_watched"]),
                        fmt_duration(r["duration"]),
                    )
                )
            )
        sys.stdout.write("\n".join(out))
        if out:
            sys.stdout.write("\n")
        return 0

    if not rows:
        print(
            "yth list: (no history yet)\n"
            "  Import a Takeout export:  yth import-takeout <watch-history.json>\n"
            "  Or sync recent history:   yth sync",
            file=sys.stderr,
        )
        return 0

    table = Table(show_lines=False, header_style="bold")
    for header in ("watched", "channel", "title", "dur", "id"):
        table.add_column(header)
    for r in rows:
        table.add_row(
            short_date(r["last_watched"]),
            (_clean(r["channel"]) or "-")[:30],
            (_clean(r["title"]) or r["video_id"])[:70],
            fmt_duration(r["duration"]),
            r["video_id"],
        )
    Console().print(table)
    return 0


def main() -> int:
    return cli(tyro.cli(Args, prog="yth list"))


if __name__ == "__main__":
    sys.exit(main())
