"""yth search — FTS5 search over watch history.

Default matches title / channel / description (ranked title≫channel≫desc via
bm25). ``--subs`` additionally matches indexed caption text and shows a
snippet. ``--json`` emits structured results for piping. DB-only.

The tv channel (`tv yth`) only fuzzy-filters the metadata *display string* —
television's source is single-shot and never sees the live query — so deep
caption search lives here, in the CLI.
"""
from __future__ import annotations

import json
import sys
from dataclasses import dataclass, field
from typing import Annotated

import tyro
from rich.console import Console
from rich.table import Table

from scripts.yth import connect, fts_query, short_date


@dataclass
class Args:
    query: Annotated[
        list[str],
        tyro.conf.Positional,
        tyro.conf.arg(help="Search terms (ANDed). Quote to include spaces."),
    ] = field(default_factory=list)
    subs: Annotated[
        bool, tyro.conf.arg(help="Also search indexed caption text.")
    ] = False
    json_out: Annotated[
        bool, tyro.conf.arg(name="json", help="Emit JSON instead of a table.")
    ] = False
    limit: Annotated[int, tyro.conf.arg(help="Max results.")] = 50
    raw: Annotated[
        bool,
        tyro.conf.arg(help="Pass the query straight to FTS5 (native MATCH syntax)."),
    ] = False


def _meta_hits(con, match: str, limit: int):
    return con.execute(
        """
        SELECT v.video_id, v.title, v.channel, s.watch_count, s.last_watched
        FROM videos_fts f
        JOIN videos v ON v.id = f.rowid
        LEFT JOIN video_stats s ON s.video_id = v.video_id
        WHERE videos_fts MATCH ?
        ORDER BY bm25(videos_fts, 8.0, 4.0, 1.0)
        LIMIT ?
        """,
        (match, limit),
    ).fetchall()


def _subs_hits(con, match: str, limit: int):
    return con.execute(
        """
        SELECT sub.video_id, v.title, v.channel, s.watch_count, s.last_watched,
               snippet(subtitles_fts, 0, '»', '«', '…', 10) AS snip
        FROM subtitles_fts sf
        JOIN subtitles sub ON sub.id = sf.rowid
        JOIN videos v ON v.video_id = sub.video_id
        LEFT JOIN video_stats s ON s.video_id = v.video_id
        WHERE subtitles_fts MATCH ?
        ORDER BY bm25(subtitles_fts)
        LIMIT ?
        """,
        (match, limit),
    ).fetchall()


def cli(args: Args) -> int:
    text = " ".join(args.query).strip()
    if not text:
        print("yth search: empty query. Try: yth search <terms>", file=sys.stderr)
        return 2

    match = text if args.raw else fts_query(text)
    if not match:
        print("yth search: query has no searchable terms.", file=sys.stderr)
        return 2

    con = connect()
    import sqlite3

    try:
        meta = _meta_hits(con, match, args.limit)
        subs = _subs_hits(con, match, args.limit) if args.subs else []
    except sqlite3.OperationalError as e:
        print(
            f"yth search: FTS5 rejected the query ({e}).\n"
            "  Drop --raw, or quote special characters.",
            file=sys.stderr,
        )
        return 2

    # Merge: metadata hits keep their rank; caption-only hits append. A video
    # matched by both is tagged with both sources.
    order: list[str] = []
    by_id: dict[str, dict] = {}
    for r in meta:
        by_id[r["video_id"]] = {
            "video_id": r["video_id"],
            "title": r["title"] or r["video_id"],
            "channel": r["channel"] or "-",
            "watch_count": r["watch_count"] or 0,
            "last_watched": r["last_watched"],
            "matched": ["meta"],
            "snippet": None,
        }
        order.append(r["video_id"])
    for r in subs:
        vid = r["video_id"]
        if vid in by_id:
            by_id[vid]["matched"].append("subs")
            by_id[vid]["snippet"] = r["snip"]
        else:
            by_id[vid] = {
                "video_id": vid,
                "title": r["title"] or vid,
                "channel": r["channel"] or "-",
                "watch_count": r["watch_count"] or 0,
                "last_watched": r["last_watched"],
                "matched": ["subs"],
                "snippet": r["snip"],
            }
            order.append(vid)

    results = [by_id[v] for v in order]

    if args.json_out:
        print(json.dumps(results, indent=2, ensure_ascii=False))
        return 0

    if not results:
        print(f"yth search: no matches for {text!r}", file=sys.stderr)
        return 0

    table = Table(show_lines=False, header_style="bold")
    cols = ["watched", "channel", "title", "match", "id"]
    if args.subs:
        cols.insert(4, "caption")
    for header in cols:
        table.add_column(header)
    for r in results:
        cells = [
            short_date(r["last_watched"]),
            r["channel"][:26],
            r["title"][:60],
            "+".join(r["matched"]),
        ]
        if args.subs:
            cells.append((r["snippet"] or "")[:60])
        cells.append(r["video_id"])
        table.add_row(*cells)
    Console().print(table)
    return 0


def main() -> int:
    return cli(tyro.cli(Args, prog="yth search"))


if __name__ == "__main__":
    sys.exit(main())
