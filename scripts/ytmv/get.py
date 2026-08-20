"""ytmv get — download a music video and make it playable on an old device.

yt-dlp's job here is narrow: fetch the media, convert the container/codec, and
fetch subtitle files. Everything a legacy player actually cares about — ID3v2.3
downgrade, text encoding, sidecar .lrc, cover sizing, FAT-safe names — is done
afterwards by this module and ``scripts.ytmv.tag_mp3``. yt-dlp's own
``--embed-metadata`` / ``--embed-thumbnail`` postprocessors are deliberately NOT
used: they only write ID3v2.4 and would fight with mutagen over the same frames.

Output modes (combinable):
  --audio (default)            mp3 + tags + cover, plus a sidecar .lrc
  --video                      mp4 (h264/aac), soft subs by default
  --video --burn-subs          mp4 with the lyrics burned into the picture

Downloads run sequentially with --sleep between items; YouTube rate-limits
aggressively and this repo's hosts already trip its bot check.
"""
from __future__ import annotations

import shutil
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Annotated
from urllib.parse import parse_qs, urlparse

import tyro

from scripts.yth import CookieSourceError, VIDEO_ID_RE
from scripts.ytmv import (
    UnencodableLyrics,
    cookie_options,
    dedupe_lrc,
    default_out_dir,
    ffmpeg_bin,
    has_libass,
    libass_help,
    load_config,
    lrc_to_plain,
    lrc_to_srt,
    make_cover,
    parse_artist_track,
    resolve_profile,
    run_ffmpeg,
    sanitize_filename,
    tag_mp3,
    write_lrc,
    yt_dlp_runtime_opts,
    ytdl,
)
from scripts.ytmv.lyrics import fetch_lyrics
from scripts.ytmv.tag import overrides_from


@dataclass
class Args:
    urls: Annotated[
        list[str],
        tyro.conf.Positional,
        tyro.conf.arg(help="Video or playlist URLs (or bare 11-char video ids)."),
    ] = field(default_factory=list)
    from_file: Annotated[
        str, tyro.conf.arg(help="Read URLs from a file, one per line ('#' comments).")
    ] = ""
    out: Annotated[str, tyro.conf.arg(help="Output dir (default: ~/Music/ytmv).")] = ""
    profile: Annotated[str, tyro.conf.arg(help="Player profile (default: config/safe).")] = ""
    audio: Annotated[bool, tyro.conf.arg(help="Produce an mp3 (default true).")] = True
    video: Annotated[bool, tyro.conf.arg(help="Also produce an mp4.")] = False
    soft_subs: Annotated[
        bool, tyro.conf.arg(help="Embed subtitles as an mp4 track (most old players ignore).")
    ] = True
    burn_subs: Annotated[
        bool, tyro.conf.arg(help="Burn lyrics into the picture (implies --video; needs libass).")
    ] = False
    lyrics: Annotated[
        str, tyro.conf.arg(help="auto | lrclib | youtube | none.")
    ] = "auto"
    langs: Annotated[
        list[str],
        tyro.conf.arg(help="Caption languages to try (default: yth's configured langs)."),
    ] = field(default_factory=list)
    artist: Annotated[str, tyro.conf.arg(help="Override artist (single URL only).")] = ""
    track: Annotated[str, tyro.conf.arg(help="Override title (single URL only).")] = ""
    album: Annotated[str, tyro.conf.arg(help="Override album (single URL only).")] = ""
    number: Annotated[
        bool, tyro.conf.arg(help="Prefix filenames with '01 - ' (players sort by name).")
    ] = False
    m3u: Annotated[str, tyro.conf.arg(help="Write an .m3u playlist with this name.")] = ""
    max_height: Annotated[int, tyro.conf.arg(help="Cap video height, e.g. 480. 0 = best.")] = 0
    audio_quality: Annotated[
        str, tyro.conf.arg(help="LAME VBR quality for mp3: 0 (best) .. 9.")
    ] = "0"
    cookies: Annotated[
        bool, tyro.conf.arg(help="Use yth's cookie source (restricted/authenticated retry).")
    ] = False
    force: Annotated[bool, tyro.conf.arg(help="Re-download even if the target exists.")] = False
    sleep: Annotated[float, tyro.conf.arg(help="Seconds between items (rate-limit).")] = 1.5
    refresh_lyrics: Annotated[bool, tyro.conf.arg(help="Bypass the LRCLIB response cache.")] = False
    json_out: Annotated[bool, tyro.conf.arg(name="json", help="Emit a JSON report.")] = False
    # --- profile overrides ---
    id3_version: Annotated[int, tyro.conf.arg(help="Force ID3 major version (3 or 4).")] = 0
    id3_encoding: Annotated[
        str, tyro.conf.arg(help="utf16 | utf8 | latin1 | raw-big5 | raw-gbk.")
    ] = ""
    lrc_encoding: Annotated[str, tyro.conf.arg(help="utf-8 | utf-8-sig | cp950 | gbk.")] = ""
    lrc_on_unencodable: Annotated[str, tyro.conf.arg(help="strict | replace.")] = ""
    skip_lrc_sidecar: Annotated[bool, tyro.conf.arg(help="Skip the sidecar .lrc.")] = False
    skip_embed_lyrics: Annotated[bool, tyro.conf.arg(help="Skip the USLT frame.")] = False
    embed_sylt: Annotated[bool, tyro.conf.arg(help="Also write a SYLT frame.")] = False
    cover_max: Annotated[int, tyro.conf.arg(help="Longest cover edge in px.")] = 0
    skip_cover: Annotated[bool, tyro.conf.arg(help="Do not embed cover art.")] = False
    ascii_filenames: Annotated[bool, tyro.conf.arg(help="ASCII-only filenames.")] = False


# --------------------------------------------------------------------------- #
# URL collection
# --------------------------------------------------------------------------- #
def _normalize(url: str) -> str:
    """Accept a bare 11-char video id as well as a full URL."""
    url = url.strip()
    if VIDEO_ID_RE.fullmatch(url):
        return f"https://www.youtube.com/watch?v={url}"
    return url


def _youtube_url_allowed(url: str) -> bool:
    """Accept only canonical HTTPS media/playlist URL shapes.

    Merely checking a `*.youtube.com` hostname is unsafe with cookies because
    `/redirect` can bounce to a plaintext YouTube URL. Channel, search, consent,
    redirect, and arbitrary generic-extractor paths are not ytmv inputs.
    """
    try:
        parsed = urlparse(url)
        host = (parsed.hostname or "").lower().rstrip(".")
        query = parse_qs(parsed.query)
    except ValueError:
        return False
    if parsed.scheme != "https":
        return False

    path_parts = [part for part in parsed.path.split("/") if part]
    if host == "youtu.be":
        return bool(path_parts and VIDEO_ID_RE.fullmatch(path_parts[0]))

    youtube_hosts = {"youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"}
    if host in youtube_hosts:
        if parsed.path == "/watch":
            return bool(query.get("v") and VIDEO_ID_RE.fullmatch(query["v"][0]))
        if parsed.path == "/playlist":
            return bool(query.get("list") and query["list"][0])
        if len(path_parts) == 2 and path_parts[0] in {"shorts", "embed", "live"}:
            return bool(VIDEO_ID_RE.fullmatch(path_parts[1]))
        return False

    if host in {"youtube-nocookie.com", "www.youtube-nocookie.com"}:
        return bool(
            len(path_parts) == 2
            and path_parts[0] == "embed"
            and VIDEO_ID_RE.fullmatch(path_parts[1])
        )
    return False


def _input_label(url: str) -> str:
    try:
        parsed = urlparse(url)
        return f"{parsed.hostname or '<missing>'}{parsed.path or '/'}"
    except ValueError:
        return "<invalid>"


def collect_urls(args: Args) -> list[str]:
    urls = [_normalize(u) for u in args.urls if u.strip()]
    if args.from_file:
        path = Path(args.from_file).expanduser()
        if not path.is_file():
            print(f"ytmv get: no such file: {path}", file=sys.stderr)
            return []
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                urls.append(_normalize(line))
    return urls


def expand_playlists(urls: list[str], cookies: dict) -> list[str]:
    """Flatten playlist URLs into their entries; leave single videos alone."""
    yt_dlp = ytdl()
    out: list[str] = []
    for url in urls:
        if "list=" not in url:
            out.append(url)
            continue
        opts = {
            **_base_opts(None, cookies),
            "extract_flat": "in_playlist",
            "skip_download": True,
        }
        try:
            with yt_dlp.YoutubeDL(opts) as ydl:
                info = ydl.extract_info(url, download=False)
        except Exception as e:  # noqa: BLE001
            print(f"ytmv get: cannot expand playlist {url}: {e}", file=sys.stderr)
            continue
        for entry in (info or {}).get("entries") or []:
            if entry and entry.get("id"):
                out.append(f"https://www.youtube.com/watch?v={entry['id']}")
    return out


# --------------------------------------------------------------------------- #
# yt-dlp calls
# --------------------------------------------------------------------------- #
def _base_opts(ffmpeg: str | None, cookies: dict) -> dict:
    opts = {
        "quiet": True,
        "noprogress": True,
        **yt_dlp_runtime_opts(),
        **cookies,
    }
    if ffmpeg:
        opts["ffmpeg_location"] = ffmpeg
    return opts


def probe(url: str, ffmpeg: str | None, cookies: dict) -> dict | None:
    yt_dlp = ytdl()
    opts = {**_base_opts(ffmpeg, cookies), "skip_download": True}
    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            return ydl.extract_info(url, download=False)
    except Exception as e:  # noqa: BLE001
        print(f"  x metadata: {str(e).splitlines()[0][:160]}", file=sys.stderr)
        return None


def download_audio(url: str, workdir: Path, quality: str, ffmpeg: str | None,
                   cookies: dict) -> Path | None:
    yt_dlp = ytdl()
    opts = {
        **_base_opts(ffmpeg, cookies),
        "format": "bestaudio/best",
        "outtmpl": {"default": str(workdir / "audio.%(ext)s")},
        "writethumbnail": True,
        "postprocessors": [
            {"key": "FFmpegExtractAudio", "preferredcodec": "mp3",
             "preferredquality": quality},
        ],
    }
    with yt_dlp.YoutubeDL(opts) as ydl:
        ydl.download([url])
    hits = sorted(workdir.glob("audio.mp3"))
    return hits[0] if hits else None


def download_video(url: str, workdir: Path, max_height: int, soft_subs: bool,
                   langs: list[str], ffmpeg: str | None, cookies: dict) -> Path | None:
    yt_dlp = ytdl()
    height = f"[height<={max_height}]" if max_height else ""
    postprocessors: list[dict] = []
    if soft_subs:
        postprocessors.append({"key": "FFmpegEmbedSubtitle"})
    opts = {
        **_base_opts(ffmpeg, cookies),
        # h264 + aac: the only combination old hardware decoders reliably handle.
        "format": f"bv*{height}+ba/b{height}",
        "format_sort": ["vcodec:h264", "acodec:aac", "res", "fps"],
        "merge_output_format": "mp4",
        "outtmpl": {"default": str(workdir / "video.%(ext)s")},
        "writesubtitles": soft_subs,
        "writeautomaticsub": soft_subs,
        "subtitleslangs": langs or ["en"],
        "postprocessors": postprocessors,
    }
    with yt_dlp.YoutubeDL(opts) as ydl:
        ydl.download([url])
    for candidate in ("video.mp4", "video.mkv", "video.webm"):
        path = workdir / candidate
        if path.is_file():
            return path
    return None


def youtube_lrc(url: str, workdir: Path, langs: list[str], ffmpeg: str | None,
                cookies: dict) -> str:
    """Fetch YouTube captions already converted to LRC by yt-dlp itself."""
    yt_dlp = ytdl()
    subdir = workdir / "subs"
    subdir.mkdir(exist_ok=True)
    opts = {
        **_base_opts(ffmpeg, cookies),
        "skip_download": True,
        "writesubtitles": True,
        "writeautomaticsub": True,
        "subtitleslangs": langs or ["en"],
        "subtitlesformat": "vtt",
        "outtmpl": {"default": str(subdir / "%(id)s.%(ext)s")},
        "postprocessors": [{"key": "FFmpegSubtitlesConvertor", "format": "lrc",
                            "when": "before_dl"}],
        "sleep_interval_subtitles": 1,
    }
    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            ydl.download([url])
    except Exception as e:  # noqa: BLE001
        print(f"  - captions: {str(e).splitlines()[0][:120]}", file=sys.stderr)
        return ""
    for path in sorted(subdir.glob("*.lrc")):
        text = path.read_text(encoding="utf-8", errors="replace")
        if text.strip():
            return dedupe_lrc(text)
    return ""


def burn_subs(ffmpeg: str, video: Path, lrc_text: str, dest: Path,
              workdir: Path) -> tuple[bool, str]:
    """Burn LRC lyrics into the picture via an intermediate SRT."""
    srt_text = lrc_to_srt(lrc_text)
    if not srt_text:
        return False, "no timed lyrics to burn"
    srt = workdir / "burn.srt"
    srt.write_text(srt_text, encoding="utf-8")
    # ffmpeg's filtergraph parser treats ':' '\' ''' '[' ']' ',' as syntax, so an
    # absolute path (temp dirs, "Artist - 稻香.srt") is a minefield to escape.
    # Sidestep it entirely: run with cwd=workdir and pass the bare ASCII name.
    code, err = run_ffmpeg(
        ffmpeg,
        [
            "-i", str(video),
            "-vf", "subtitles=burn.srt:force_style='FontSize=22,Outline=1,MarginV=24'",
            "-c:v", "libx264", "-profile:v", "baseline", "-level", "3.0",
            "-pix_fmt", "yuv420p", "-preset", "medium", "-crf", "23",
            "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart",
            str(dest),
        ],
        cwd=str(workdir),
    )
    return code == 0, err


# --------------------------------------------------------------------------- #
# Main flow
# --------------------------------------------------------------------------- #
def build_stem(meta: dict, settings: dict, index: int | None) -> str:
    parts = [p for p in (meta.get("artist"), meta.get("track")) if p]
    raw = " - ".join(parts) if len(parts) == 2 else (parts[0] if parts else "untitled")
    if index is not None:
        raw = f"{index:02d} - {raw}"
    return sanitize_filename(raw, settings["filename_charset"], settings["filename_max"])


def process_one(url: str, index: int | None, args: Args, cfg: dict, settings: dict,
                out_dir: Path, ffmpeg: str | None, cookies: dict, langs: list[str]) -> dict:
    result: dict = {"url": url, "status": "error", "files": []}

    info = probe(url, ffmpeg, cookies)
    if not info:
        result["detail"] = "metadata lookup failed"
        return result

    meta = parse_artist_track(info, args.artist, args.track, args.album)
    result["metadata"] = meta
    duration = info.get("duration")
    stem = build_stem(meta, settings, index if args.number else None)
    result["stem"] = stem

    mp3_dest = out_dir / f"{stem}.mp3"
    mp4_dest = out_dir / f"{stem}.mp4"
    want_audio = args.audio
    want_video = args.video or args.burn_subs
    if not args.force:
        if want_audio and mp3_dest.is_file() and mp3_dest.stat().st_size:
            want_audio = False
        if want_video and mp4_dest.is_file() and mp4_dest.stat().st_size:
            want_video = False
    if not want_audio and not want_video:
        result["status"] = "skipped"
        result["files"] = [str(p) for p in (mp3_dest, mp4_dest) if p.is_file()]
        return result

    # ---- lyrics (needed by both the mp3 tags and the hardsub) ----
    synced = plain = ""
    lyrics_source = "disabled"
    with tempfile.TemporaryDirectory(prefix="ytmv-") as td:
        workdir = Path(td)

        if args.lyrics in ("auto", "lrclib"):
            synced, plain, lyrics_source = fetch_lyrics(
                meta["artist"], meta["track"], duration, meta["album"],
                interactive=False, use_cache=not args.refresh_lyrics,
            )
        if not synced and args.lyrics in ("auto", "youtube"):
            captions = youtube_lrc(url, workdir, langs, ffmpeg, cookies)
            if captions.strip():
                synced = captions
                plain = lrc_to_plain(captions)
                lyrics_source = "youtube-captions"
        result["lyrics_source"] = lyrics_source
        result["lyrics"] = "synced" if synced else ("unsynced" if plain else "none")

        # ---- audio ----
        if want_audio:
            try:
                produced = download_audio(url, workdir, args.audio_quality, ffmpeg, cookies)
            except Exception as e:  # noqa: BLE001
                result["detail"] = f"audio download failed: {str(e).splitlines()[0][:160]}"
                return result
            if not produced:
                result["detail"] = "audio download produced no mp3"
                return result

            cover = None
            if settings.get("cover") != "none" and ffmpeg:
                thumbs = [p for p in workdir.iterdir()
                          if p.suffix.lower() in (".webp", ".jpg", ".jpeg", ".png")]
                if thumbs:
                    jpeg = workdir / "cover.jpg"
                    if make_cover(ffmpeg, thumbs[0], jpeg, settings["cover_max"]):
                        cover = jpeg.read_bytes()

            tag_meta = dict(meta)
            if index is not None and args.number:
                tag_meta["track_number"] = index
            try:
                tag_mp3(produced, tag_meta, settings, lyrics_text=plain,
                        synced_lrc=synced, cover=cover)
            except Exception as e:  # noqa: BLE001
                result["detail"] = f"tagging failed: {type(e).__name__}: {e}"
                return result

            out_dir.mkdir(parents=True, exist_ok=True)
            shutil.move(str(produced), str(mp3_dest))
            result["files"].append(str(mp3_dest))

            if synced and settings.get("lrc_sidecar"):
                try:
                    write_lrc(mp3_dest.with_suffix(".lrc"), synced,
                              settings["lrc_encoding"], settings["lrc_on_unencodable"])
                    result["files"].append(str(mp3_dest.with_suffix(".lrc")))
                except UnencodableLyrics as e:
                    # The mp3 is already good; only the sidecar failed. Say so
                    # precisely instead of failing the whole item.
                    print(f"  - sidecar .lrc: {e}", file=sys.stderr)
                    result["lrc_warning"] = str(e)

        # ---- video ----
        if want_video:
            try:
                produced = download_video(url, workdir, args.max_height,
                                          args.soft_subs and not args.burn_subs,
                                          langs, ffmpeg, cookies)
            except Exception as e:  # noqa: BLE001
                result["detail"] = f"video download failed: {str(e).splitlines()[0][:160]}"
                return result
            if not produced:
                result["detail"] = "video download produced no file"
                return result

            out_dir.mkdir(parents=True, exist_ok=True)
            if args.burn_subs:
                ok, err = burn_subs(ffmpeg, produced, synced, mp4_dest, workdir)
                if not ok:
                    result["detail"] = f"burn-in failed: {err}"
                    return result
            else:
                shutil.move(str(produced), str(mp4_dest))
            result["files"].append(str(mp4_dest))

    result["status"] = "ok"
    return result


def cli(args: Args) -> int:
    urls = collect_urls(args)
    if not urls:
        print("ytmv get: no URLs. Try: ytmv get 'https://www.youtube.com/watch?v=...'",
              file=sys.stderr)
        return 2

    invalid_inputs = sorted(
        {_input_label(url) for url in urls if not _youtube_url_allowed(url)}
    )
    if invalid_inputs:
        print(
            "ytmv get: only canonical HTTPS YouTube watch/playlist/media URLs "
            "or bare video ids are accepted; "
            f"rejected input(s): {', '.join(invalid_inputs)}",
            file=sys.stderr,
        )
        return 2

    if args.lyrics not in ("auto", "lrclib", "youtube", "none"):
        print(f"ytmv get: --lyrics must be auto|lrclib|youtube|none, got "
              f"'{args.lyrics}'", file=sys.stderr)
        return 2

    cfg = load_config()
    try:
        settings = resolve_profile(cfg, args.profile, overrides_from(args))
    except KeyError as e:
        print(f"ytmv get: {e}", file=sys.stderr)
        return 2

    ffmpeg = ffmpeg_bin(cfg)
    if not ffmpeg:
        print("ytmv get: ffmpeg not found — it is required to produce mp3/mp4.\n"
              "  Re-run chezmoi init with installMediaTools=true, or set\n"
              "  ffmpeg = \"/path/to/ffmpeg\" in ~/.config/ytmv/config.toml.",
              file=sys.stderr)
        return 3

    if args.burn_subs and not has_libass(ffmpeg):
        # Falling back to soft subs here would hand back a file the player shows
        # nothing on — the exact failure this tool exists to prevent.
        print(libass_help(ffmpeg), file=sys.stderr)
        return 3

    out_dir = Path(args.out).expanduser() if args.out else (
        Path(str(cfg["out"])).expanduser() if cfg.get("out") else default_out_dir()
    )
    # Must be absolute: burn_subs() runs ffmpeg with cwd=<tempdir> (to avoid
    # escaping the subtitles= filter path), so a relative --out would resolve
    # against the temp dir and the encode would fail with "No such file".
    out_dir = out_dir.resolve()
    try:
        cookies = cookie_options(cfg, args.cookies)
    except CookieSourceError as e:
        print(f"ytmv get: cookie source rejected — {e}", file=sys.stderr)
        return 2
    langs = args.langs or cfg.get("langs") or []
    if not langs:
        try:
            from scripts.yth import load_config as yth_config

            langs = yth_config().get("langs") or ["en"]
        except ImportError:
            langs = ["en"]

    urls = expand_playlists(urls, cookies)
    if (args.artist or args.track or args.album) and len(urls) > 1:
        print(f"ytmv get: --artist/--track/--album apply to a single video; got "
              f"{len(urls)}.", file=sys.stderr)
        return 2

    results = []
    ok = failed = skipped = 0
    total = len(urls)
    for i, url in enumerate(urls, 1):
        print(f"[{i}/{total}] {url}", file=sys.stderr)
        result = process_one(url, i, args, cfg, settings, out_dir, ffmpeg, cookies, langs)
        results.append(result)
        if result["status"] == "ok":
            ok += 1
            print(f"  ok {result.get('stem')}  "
                  f"[lyrics: {result.get('lyrics')} via {result.get('lyrics_source')}]"
                  f"  [meta: {result.get('metadata', {}).get('source')}]", file=sys.stderr)
        elif result["status"] == "skipped":
            skipped += 1
            print("  - already present (--force to redo)", file=sys.stderr)
        else:
            failed += 1
            print(f"  x {result.get('detail')}", file=sys.stderr)
        if args.sleep and i < total:
            time.sleep(args.sleep)

    if args.m3u:
        _write_m3u(out_dir, args.m3u, results)

    if args.json_out:
        import json

        print(json.dumps(results, indent=2, ensure_ascii=False))

    print(f"ytmv get: {ok} downloaded, {skipped} skipped, {failed} failed → {out_dir}",
          file=sys.stderr)
    return 1 if failed else 0


def _write_m3u(out_dir: Path, name: str, results: list[dict]) -> None:
    """Emit a plain .m3u of the audio files, in the order they were requested."""
    lines = ["#EXTM3U"]
    for result in results:
        for path in result.get("files", []):
            if path.endswith(".mp3"):
                lines.append(Path(path).name)
    target = out_dir / (name if name.endswith(".m3u") else f"{name}.m3u")
    try:
        out_dir.mkdir(parents=True, exist_ok=True)
        target.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"[ytmv] playlist: {target}", file=sys.stderr)
    except OSError as e:
        print(f"ytmv get: could not write {target}: {e}", file=sys.stderr)


def main() -> int:
    return cli(tyro.cli(Args, prog="ytmv get"))


if __name__ == "__main__":
    sys.exit(main())
