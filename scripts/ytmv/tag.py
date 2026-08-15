"""ytmv tag — re-apply a player profile to files you already have. Offline.

This is the "my player showed garbage, try another profile" loop. Downloading
again would be wasteful and slow, so every compatibility knob (ID3 version and
text encoding, sidecar ``.lrc`` encoding, cover size, filename charset) can be
re-applied in place. Existing tags and any sidecar ``.lrc`` are read back in and
rewritten under the new profile, so nothing needs re-fetching.

Touches the network never — that is what makes it safe to run in a tight loop
while you figure out what the device actually wants.
"""
from __future__ import annotations

import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Annotated

import tyro

from scripts.ytmv import (
    UnencodableLyrics,
    ffmpeg_bin,
    load_config,
    lrc_to_plain,
    make_cover,
    resolve_profile,
    sanitize_filename,
    tag_mp3,
    write_lrc,
)


@dataclass
class Args:
    paths: Annotated[
        list[str],
        tyro.conf.Positional,
        tyro.conf.arg(help="MP3 files (or directories, scanned non-recursively)."),
    ] = field(default_factory=list)
    profile: Annotated[
        str, tyro.conf.arg(help="Player profile to apply (default: config, else safe).")
    ] = ""
    artist: Annotated[str, tyro.conf.arg(help="Override artist (single file only).")] = ""
    track: Annotated[str, tyro.conf.arg(help="Override title (single file only).")] = ""
    album: Annotated[str, tyro.conf.arg(help="Override album.")] = ""
    year: Annotated[str, tyro.conf.arg(help="Override year.")] = ""
    rename: Annotated[
        bool, tyro.conf.arg(help="Also rewrite filenames through the profile's sanitiser.")
    ] = False
    # --- profile overrides (each shadows the selected profile) ---
    id3_version: Annotated[
        int, tyro.conf.arg(help="Force ID3 major version: 3 (old players) or 4.")
    ] = 0
    id3_encoding: Annotated[
        str,
        tyro.conf.arg(help="utf16 | utf8 | latin1 | raw-big5 | raw-gbk."),
    ] = ""
    lrc_encoding: Annotated[
        str, tyro.conf.arg(help="Sidecar .lrc encoding: utf-8 | utf-8-sig | cp950 | gbk.")
    ] = ""
    lrc_on_unencodable: Annotated[
        str, tyro.conf.arg(help="strict (fail) | replace (substitute '?').")
    ] = ""
    skip_lrc_sidecar: Annotated[
        bool, tyro.conf.arg(help="Do not write/rewrite the sidecar .lrc.")
    ] = False
    skip_embed_lyrics: Annotated[
        bool, tyro.conf.arg(help="Do not embed lyrics in a USLT frame.")
    ] = False
    embed_sylt: Annotated[
        bool, tyro.conf.arg(help="Also embed synced lyrics as SYLT (rarely supported).")
    ] = False
    cover_max: Annotated[int, tyro.conf.arg(help="Longest cover edge in px.")] = 0
    skip_cover: Annotated[bool, tyro.conf.arg(help="Strip / skip cover art.")] = False
    ascii_filenames: Annotated[
        bool, tyro.conf.arg(help="Transliterate filenames to ASCII (implies --rename).")
    ] = False
    dry_run: Annotated[bool, tyro.conf.arg(help="Report what would change, write nothing.")] = False


def overrides_from(args: Args) -> dict:
    """Build the per-setting override dict from CLI flags (None = leave alone)."""
    out: dict = {}
    if args.id3_version:
        out["id3_version"] = args.id3_version
    if args.id3_encoding:
        out["id3_encoding"] = args.id3_encoding
    if args.lrc_encoding:
        out["lrc_encoding"] = args.lrc_encoding
    if args.lrc_on_unencodable:
        out["lrc_on_unencodable"] = args.lrc_on_unencodable
    if args.skip_lrc_sidecar:
        out["lrc_sidecar"] = False
    if args.skip_embed_lyrics:
        out["embed_uslt"] = False
    if args.embed_sylt:
        out["embed_sylt"] = True
    if args.cover_max:
        out["cover_max"] = args.cover_max
    if args.skip_cover:
        out["cover"] = "none"
    if args.ascii_filenames:
        out["filename_charset"] = "ascii"
    return out


def collect_mp3s(paths: list[str]) -> list[Path]:
    found: list[Path] = []
    for raw in paths:
        path = Path(raw).expanduser()
        if path.is_dir():
            found.extend(sorted(p for p in path.glob("*.mp3") if p.is_file()))
        elif path.is_file():
            found.append(path)
        else:
            print(f"ytmv tag: no such path: {path}", file=sys.stderr)
    return found


def read_existing(path: Path) -> dict:
    """Pull artist/track/album/year and cover back out of the file's own tags.

    Re-tagging must not lose information the file already carries — the user may
    only be switching encodings, not re-identifying the song.
    """
    from mutagen.id3 import ID3, ID3NoHeaderError

    meta = {"artist": "", "track": "", "album": "", "year": "", "cover": None,
            "lyrics": ""}
    try:
        tags = ID3(path)
    except (ID3NoHeaderError, OSError):
        return meta

    def first(key: str) -> str:
        frames = tags.getall(key)
        return str(frames[0].text[0]) if frames and frames[0].text else ""

    meta["track"] = first("TIT2")
    meta["artist"] = first("TPE1")
    meta["album"] = first("TALB")
    meta["year"] = first("TDRC") or first("TYER")
    uslt = tags.getall("USLT")
    if uslt:
        meta["lyrics"] = str(uslt[0].text)
    apic = tags.getall("APIC")
    if apic:
        meta["cover"] = apic[0].data
    return meta


def cli(args: Args) -> int:
    if not args.paths:
        print("ytmv tag: no files given. Try: ytmv tag ~/Music/ytmv --profile cjk-big5",
              file=sys.stderr)
        return 2

    cfg = load_config()
    try:
        settings = resolve_profile(cfg, args.profile, overrides_from(args))
    except KeyError as e:
        print(f"ytmv tag: {e}", file=sys.stderr)
        return 2

    files = collect_mp3s(args.paths)
    if not files:
        print("ytmv tag: no .mp3 files found.", file=sys.stderr)
        return 0

    if (args.artist or args.track) and len(files) > 1:
        print("ytmv tag: --artist/--track apply to a single file; got "
              f"{len(files)}.", file=sys.stderr)
        return 2

    ffmpeg = ffmpeg_bin(cfg)
    ok = failed = 0

    for path in files:
        existing = read_existing(path)
        meta = {
            "artist": args.artist or existing["artist"],
            "track": args.track or existing["track"] or path.stem,
            "album": args.album or existing["album"],
            "year": args.year or existing["year"],
        }

        # A sidecar .lrc is the richer source (it has timestamps); fall back to
        # whatever USLT already holds.
        sidecar = path.with_suffix(".lrc")
        synced = ""
        if sidecar.is_file():
            synced = _read_lrc(sidecar)
        lyrics_plain = lrc_to_plain(synced) if synced else existing["lyrics"]

        cover = None if settings.get("cover") == "none" else existing["cover"]
        if cover and args.cover_max and ffmpeg:
            cover = _resize_cover(ffmpeg, cover, settings["cover_max"]) or cover

        if args.dry_run:
            print(f"[ytmv] would tag {path.name}: id3v2.{settings['id3_version']} "
                  f"{settings['id3_encoding']}, lrc={settings['lrc_encoding']}"
                  f"{' (no sidecar)' if not settings['lrc_sidecar'] else ''}",
                  file=sys.stderr)
            ok += 1
            continue

        try:
            tag_mp3(path, meta, settings, lyrics_text=lyrics_plain, synced_lrc=synced,
                    cover=cover)
            if synced and settings.get("lrc_sidecar"):
                write_lrc(sidecar, synced, settings["lrc_encoding"],
                          settings["lrc_on_unencodable"])
            elif not settings.get("lrc_sidecar") and sidecar.is_file():
                sidecar.unlink()
        except UnencodableLyrics as e:
            print(f"  {path.name} x {e}", file=sys.stderr)
            failed += 1
            continue
        except Exception as e:  # noqa: BLE001 - one bad file must not stop the batch
            print(f"  {path.name} x {type(e).__name__}: {e}", file=sys.stderr)
            failed += 1
            continue

        final = path
        if args.rename or args.ascii_filenames:
            stem = sanitize_filename(
                path.stem, settings["filename_charset"], settings["filename_max"]
            )
            if stem != path.stem:
                final = path.with_name(stem + path.suffix)
                path.rename(final)
                if sidecar.is_file():
                    sidecar.rename(final.with_suffix(".lrc"))

        print(f"  {final.name} ok", file=sys.stderr)
        ok += 1

    print(f"ytmv tag: {ok} tagged, {failed} failed "
          f"(profile '{settings['_name']}').", file=sys.stderr)
    return 1 if failed else 0


def _read_lrc(path: Path) -> str:
    """Read a sidecar whose encoding we do not know a priori.

    Files written under a cjk-* profile are Big5/GBK, not UTF-8, so a plain
    read_text() would raise on exactly the files this subcommand exists to fix.
    """
    data = path.read_bytes()
    for encoding in ("utf-8-sig", "utf-8", "big5", "gbk", "cp932"):
        try:
            return data.decode(encoding)
        except UnicodeDecodeError:
            continue
    return data.decode("utf-8", errors="replace")


def _resize_cover(ffmpeg: str, data: bytes, max_edge: int) -> bytes | None:
    import tempfile

    with tempfile.TemporaryDirectory() as td:
        src = Path(td) / "in.jpg"
        dst = Path(td) / "out.jpg"
        src.write_bytes(data)
        if make_cover(ffmpeg, src, dst, max_edge):
            return dst.read_bytes()
    return None


def main() -> int:
    return cli(tyro.cli(Args, prog="ytmv tag"))


if __name__ == "__main__":
    sys.exit(main())
