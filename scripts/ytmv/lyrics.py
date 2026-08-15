"""ytmv lyrics — (re)attach lyrics to MP3s that already exist.

Split out from ``get`` because the two failure modes are different: a download
either works or doesn't, but lyrics matching is fuzzy and often needs a second
pass with a corrected artist/title. This subcommand re-runs only the lyrics
half — no re-downloading — and offers ``--pick`` for the cases where LRCLIB has
several plausible entries and guessing would be worse than asking.

Lookup chain (``--source auto``):
  1. LRCLIB exact   /api/get with artist + track + duration
  2. LRCLIB fuzzy   /api/search, ranked by duration proximity + name similarity
  3. plainLyrics    unsynced text -> USLT only, never a fake-timestamp .lrc

YouTube captions are rung 3 of ``ytmv get``'s chain; they need the video URL, so
they are not available here where we only have local files.
"""
from __future__ import annotations

import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Annotated

import tyro

from scripts.ytmv import (
    UnencodableLyrics,
    load_config,
    lrc_to_plain,
    lrclib_get,
    lrclib_search,
    pick_hit,
    rank_hits,
    resolve_profile,
    tag_mp3,
    write_lrc,
)
from scripts.ytmv.tag import collect_mp3s, overrides_from, read_existing


@dataclass
class Args:
    paths: Annotated[
        list[str],
        tyro.conf.Positional,
        tyro.conf.arg(help="MP3 files (or directories, scanned non-recursively)."),
    ] = field(default_factory=list)
    profile: Annotated[str, tyro.conf.arg(help="Player profile (default: config/safe).")] = ""
    artist: Annotated[str, tyro.conf.arg(help="Force the artist used for lookup.")] = ""
    track: Annotated[str, tyro.conf.arg(help="Force the title used for lookup.")] = ""
    album: Annotated[str, tyro.conf.arg(help="Album, sharpens the exact lookup.")] = ""
    pick: Annotated[
        bool, tyro.conf.arg(help="Show LRCLIB candidates and choose interactively.")
    ] = False
    force: Annotated[
        bool, tyro.conf.arg(help="Refetch even when a sidecar .lrc already exists.")
    ] = False
    refresh_lyrics: Annotated[bool, tyro.conf.arg(help="Bypass the 30-day LRCLIB cache.")] = False
    sleep: Annotated[float, tyro.conf.arg(help="Seconds between files (be polite).")] = 1.0
    json_out: Annotated[bool, tyro.conf.arg(name="json", help="Emit a JSON report.")] = False
    # Profile overrides worth having here too (the .lrc encoding is the usual one).
    lrc_encoding: Annotated[str, tyro.conf.arg(help="utf-8 | utf-8-sig | cp950 | gbk.")] = ""
    lrc_on_unencodable: Annotated[str, tyro.conf.arg(help="strict | replace.")] = ""
    skip_lrc_sidecar: Annotated[bool, tyro.conf.arg(help="Embed only, no sidecar file.")] = False
    skip_embed_lyrics: Annotated[bool, tyro.conf.arg(help="Sidecar only, no USLT frame.")] = False
    embed_sylt: Annotated[bool, tyro.conf.arg(help="Also write a SYLT frame.")] = False
    # Unused-but-accepted so overrides_from() can be shared with `ytmv tag`.
    id3_version: int = 0
    id3_encoding: str = ""
    cover_max: int = 0
    skip_cover: bool = False
    ascii_filenames: bool = False


def audio_duration(path: Path) -> float | None:
    from mutagen.mp3 import MP3

    try:
        return float(MP3(path).info.length)
    except Exception:  # noqa: BLE001 - a duration we can't read just weakens matching
        return None


def _prompt_choice(hits: list[dict]) -> dict | None:
    """Numbered table of candidates; empty input skips the file."""
    from rich.console import Console
    from rich.table import Table

    console = Console(stderr=True)
    table = Table(title="LRCLIB candidates")
    table.add_column("#", justify="right")
    table.add_column("track")
    table.add_column("artist")
    table.add_column("album")
    table.add_column("dur", justify="right")
    table.add_column("synced", justify="center")
    for i, hit in enumerate(hits[:10], 1):
        table.add_row(
            str(i), hit.get("trackName") or "", hit.get("artistName") or "",
            hit.get("albumName") or "", str(int(hit.get("duration") or 0)),
            "yes" if hit.get("syncedLyrics") else "-",
        )
    console.print(table)
    try:
        answer = input("pick # (Enter to skip): ").strip()
    except (EOFError, KeyboardInterrupt):
        return None
    if not answer.isdigit():
        return None
    index = int(answer)
    return hits[index - 1] if 1 <= index <= min(10, len(hits)) else None


def fetch_lyrics(artist: str, track: str, duration: float | None, album: str,
                 interactive: bool, use_cache: bool) -> tuple[str, str, str]:
    """Return ``(synced_lrc, plain_text, source)``; empty strings when nothing fits."""
    if not track:
        return "", "", "no-track-name"

    hit = lrclib_get(artist, track, duration, album, use_cache=use_cache)
    source = "lrclib-exact"

    if not hit:
        query = f"{artist} {track}".strip()
        hits = lrclib_search(query, use_cache=use_cache)
        if hits:
            hit = _prompt_choice(rank_hits(hits, artist, track, duration)) if interactive \
                else pick_hit(hits, artist, track, duration)
            source = "lrclib-search"

    if not hit:
        return "", "", "no-match"
    if hit.get("instrumental"):
        return "", "", "instrumental"

    synced = hit.get("syncedLyrics") or ""
    plain = hit.get("plainLyrics") or ""
    if synced:
        return synced, lrc_to_plain(synced), source
    if plain:
        # Unsynced text is useful embedded, but writing it as a .lrc with
        # invented timestamps would make the player scroll nonsense.
        return "", plain, source + "-unsynced"
    return "", "", "empty"


def apply_lyrics(path: Path, settings: dict, synced: str, plain: str) -> None:
    existing = read_existing(path)
    meta = {
        "artist": existing["artist"],
        "track": existing["track"] or path.stem,
        "album": existing["album"],
        "year": existing["year"],
    }
    tag_mp3(path, meta, settings, lyrics_text=plain, synced_lrc=synced,
            cover=existing["cover"])
    if synced and settings.get("lrc_sidecar"):
        write_lrc(path.with_suffix(".lrc"), synced, settings["lrc_encoding"],
                  settings["lrc_on_unencodable"])


def cli(args: Args) -> int:
    if not args.paths:
        print("ytmv lyrics: no files given. Try: ytmv lyrics ~/Music/ytmv",
              file=sys.stderr)
        return 2

    cfg = load_config()
    try:
        settings = resolve_profile(cfg, args.profile, overrides_from(args))
    except KeyError as e:
        print(f"ytmv lyrics: {e}", file=sys.stderr)
        return 2

    files = collect_mp3s(args.paths)
    if not files:
        print("ytmv lyrics: no .mp3 files found.", file=sys.stderr)
        return 0
    if (args.artist or args.track) and len(files) > 1:
        print(f"ytmv lyrics: --artist/--track apply to a single file; got {len(files)}.",
              file=sys.stderr)
        return 2

    report = []
    found = skipped = failed = 0
    total = len(files)

    for i, path in enumerate(files, 1):
        sidecar = path.with_suffix(".lrc")
        if sidecar.is_file() and not args.force:
            print(f"  [{i}/{total}] {path.name} — has .lrc (use --force)", file=sys.stderr)
            skipped += 1
            report.append({"file": str(path), "status": "skipped"})
            continue

        existing = read_existing(path)
        artist = args.artist or existing["artist"]
        track = args.track or existing["track"] or path.stem
        album = args.album or existing["album"]

        try:
            synced, plain, source = fetch_lyrics(
                artist, track, audio_duration(path), album,
                interactive=args.pick, use_cache=not args.refresh_lyrics,
            )
        except Exception as e:  # noqa: BLE001
            print(f"  [{i}/{total}] {path.name} x {type(e).__name__}: {e}",
                  file=sys.stderr)
            failed += 1
            report.append({"file": str(path), "status": "error", "detail": str(e)})
            continue

        if not synced and not plain:
            print(f"  [{i}/{total}] {path.name} — no lyrics ({source})", file=sys.stderr)
            report.append({"file": str(path), "status": "none", "source": source})
        else:
            try:
                apply_lyrics(path, settings, synced, plain)
            except UnencodableLyrics as e:
                print(f"  [{i}/{total}] {path.name} x {e}", file=sys.stderr)
                failed += 1
                report.append({"file": str(path), "status": "error", "detail": str(e)})
                continue
            kind = "synced" if synced else "unsynced"
            print(f"  [{i}/{total}] {path.name} ok ({kind}, {source})", file=sys.stderr)
            found += 1
            report.append({"file": str(path), "status": "ok", "kind": kind,
                           "source": source})

        if args.sleep and i < total:
            time.sleep(args.sleep)

    if args.json_out:
        import json

        print(json.dumps(report, indent=2, ensure_ascii=False))

    print(f"ytmv lyrics: {found} with lyrics, {skipped} skipped, {failed} failed.",
          file=sys.stderr)
    # Songs without lyrics on LRCLIB are a fact about the world, not a failure.
    return 1 if failed else 0


def main() -> int:
    return cli(tyro.cli(Args, prog="ytmv lyrics"))


if __name__ == "__main__":
    sys.exit(main())
