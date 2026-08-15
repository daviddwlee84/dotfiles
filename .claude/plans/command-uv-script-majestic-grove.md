# `ytmv` — YouTube MV → old-MP3-player CLI (uv script + tyro)

## Context

The user wants to download YouTube music videos, put them on **old MP3 players**, and see
lyrics on the device. Today the repo has neither half of that:

- **`yth`** (`dot_dotfiles/bin/executable_yth` + `scripts/yth/`) is a watch-history *search*
  tool. It sets `"skip_download": True` (`scripts/yth/fetch_subs.py:84`) and never touches
  media; its captions are flattened to plain text into sqlite and the VTT files are thrown
  away with the `TemporaryDirectory` (`fetch_subs.py:82-104`). `docs/tools/yth.md:21`
  states the boundary outright: ffmpeg is "only for muxing, which `yth` doesn't do".
- **`yt-dlp`** is installed and on PATH (`dot_ansible/roles/python_uv_tools/defaults/main.yml:99-105`),
  but there is no wrapper — no alias, no shell function, no `~/.config/yt-dlp/config`.

Raw `yt-dlp` gets you a file; it does **not** get you a file an old player can actually
use. That gap is the whole point of this tool: ID3v2.3 downgrade, sidecar `.lrc`, CJK text
encoding, FAT32-safe filenames, cover-art sizing, and real synced lyrics (official MVs
usually have no YouTube captions at all).

**Locked with the user:** all four outputs (mp3+`.lrc`, mp3 with embedded lyrics, mp4 with
soft subs, mp4 with burned-in subs); lyrics from LRCLIB with YouTube captions as fallback;
player specifics unknown → everything switchable with a conservative default; standalone
CLI as a uv PEP-723 script with tyro, following the `yth`/`mlf` umbrella pattern.

## Verified environment facts

These were checked on this host — do not re-derive them:

| Fact | Evidence |
|---|---|
| `yt-dlp` 2026.07.04, `--convert-subs` supports **`lrc`** natively (also ass/srt/vtt) | `yt-dlp --help` |
| Preset aliases `-t mp3` / `-t mp4` / `-t aac` / `-t mkv` exist | `yt-dlp --help` |
| **`ffmpeg` 8.1.1 (homebrew/core) has NO libass** → no `subtitles`/`ass` filter → hardsub is impossible with it | `ffmpeg -filters`; formula deps have no `libass` |
| **`ffmpeg-full` (homebrew/core) depends on libass AND is keg-only** (`:versioned_formula`, no `conflicts_with`) → installs to `$(brew --prefix ffmpeg-full)/bin/ffmpeg` **without shadowing** the plain `ffmpeg`. `ffmpeg@7`/`ffmpeg@6` likewise. | `brew info --json=v2` |
| LRCLIB is auth-free. `GET /api/get?artist_name=&track_name=&duration=` (album optional) → 200 + `syncedLyrics` in `[mm:ss.xx]` LRC. `GET /api/search?q=` → array. Fields: `id,name,trackName,artistName,albumName,duration,instrumental,plainLyrics,syncedLyrics` | live probe |
| Big5/GBK are **lossy**: Big5 can't encode kana (`涙`) or `é`; GBK can't encode `♪`; neither handles non-BMP (`𠮷`). `errors="replace"` silently yields `?` | `python3` round-trip |
| `mutagen` is installed nowhere in the repo | repo-wide grep |
| YouTube returns `Sign in to confirm you're not a bot` from this host even for public videos | live `yt-dlp` probe |
| `ffmpeg` is gated behind the `installMediaTools` prompt (default **false**), and `CLAUDE.md` forbids promoting it to `devtools` | `.chezmoi.toml.tmpl:101`, CLAUDE.md |
| `ytmv` collides with nothing on PATH and nothing in the repo | `command -v` |

## Name

**`ytmv`** — "YouTube MV". Free on PATH, reads as a sibling of `yth` without overloading it,
and stays honest about scope (music videos, not a general downloader).

## Architecture — umbrella, cloning `yth`

`yth` is the template; copy its shapes rather than inventing new ones.

```
dot_dotfiles/bin/executable_ytmv   # PEP723 launcher: USAGE short-circuit, _source_path(),
                                   #   sys.path inject, dict dispatch, os.execvp for `tv`
scripts/ytmv/__init__.py           # profiles, config, cookie reuse, ffmpeg probe,
                                   #   LRC<->SRT, encoding writer, filename sanitiser, tagging
scripts/ytmv/get.py                # `ytmv get`     — download + convert + tag + lyrics
scripts/ytmv/lyrics.py             # `ytmv lyrics`  — (re)attach lyrics to existing files
scripts/ytmv/tag.py                # `ytmv tag`     — re-apply a profile, offline
scripts/ytmv/doctor.py             # `ytmv doctor`  — environment probe
```

Non-negotiable shapes to copy from `dot_dotfiles/bin/executable_yth`:

- Shebang `#!/usr/bin/env -S uv run --quiet --script`; PEP 723 block with
  `requires-python = ">=3.11"` and `>=`-floored deps.
- `_source_path()` verbatim in shape (`executable_yth:71-97`): `chezmoi source-path` with a
  5s timeout and `check=False`, catching `(TimeoutExpired, OSError)`; fall back to
  `~/.local/share/chezmoi` validated by the sentinel `scripts/ytmv/__init__.py`; otherwise
  a two-space-indented multi-line stderr message and `exit(2)`.
- `-h/--help/help` prints a module-level `USAGE` constant and returns 0 **before**
  `_source_path()` or any heavy import (`executable_yth:147-152`).
- `_leaf()`: `sys.argv = [prog, *args]` then `__import__(f"scripts.ytmv.{module}", fromlist=["main"])`
  (`executable_yth:113-117`), so `yt_dlp`/`mutagen`/`httpx` are never imported on the
  `doctor`/`tag` paths.
- Exit codes: `0` ok, `1` operational failure, `2` bad usage, `3` broken environment.
  Diagnostics to stderr as `ytmv <sub>: msg`; progress as `[ytmv] …`; **stdout stays clean**.

**PEP 723 deps:** `yt-dlp>=2025.1`, `tyro>=0.9`, `rich>=13.9`, `platformdirs>=4`,
`mutagen>=1.47`, `httpx>=0.27`. `httpx` matches the repo's HTTP precedent
(`executable_mi-router`, `executable_tsnet`, `executable_reyee`). **`mutagen` gets NO
`python_uv_tools` entry** — that role is for packages that ship a binary, and mutagen
ships none.

**Cookie reuse — do not build a second cookie system.** `scripts/ytmv/__init__.py` imports
`from scripts.yth import cookie_opts, load_config as _yth_config` (both are on `sys.path`
already, `scripts/yth/__init__.py:291-352`). `~/.config/yth/config.toml` stays the single
place the Arc/Zen cookie story is configured and documented (`docs/tools/yth.md:61-78`).
`ytmv`'s own config may override with its own `cookiefile`/`from_browser` keys, but the
default is "whatever `yth` uses". **This creates a new cross-file coupling** — record it in
the CLAUDE.md `yth` row and in both docs pages.

## A. Player-compatibility profiles (the core UX)

Hardcoded dict `PROFILES` in `scripts/ytmv/__init__.py`, user-extensible via a
`[profiles.<name>]` table in `~/.config/ytmv/config.toml`. Resolution order:
**built-in profile → user profile override → config top-level defaults → explicit CLI flag**.
`--profile` selects; every individual setting also has its own flag so the user can bisect
toward whatever their player actually wants.

| Setting | `safe` (default) | `cjk-big5` | `cjk-gbk` | `ipod` | `modern` |
|---|---|---|---|---|---|
| `id3_version` | 3 | 3 | 3 | 3 | 4 |
| `id3_encoding` | `utf16` | `raw-big5` | `raw-gbk` | `utf16` | `utf8` |
| `lrc_sidecar` | yes | yes | yes | **no** | yes |
| `lrc_encoding` | `utf-8` | `big5` | `gbk` | — | `utf-8` |
| `lrc_on_unencodable` | `strict` | `strict` | `strict` | — | `strict` |
| `embed_uslt` | yes | yes | yes | yes | yes |
| `embed_sylt` | no | no | no | no | no |
| `cover` / `cover_max` | jpeg / 300 | jpeg / 300 | jpeg / 300 | jpeg / 300 | jpeg / 600 |
| `filename_charset` | `unicode` | `unicode` | `unicode` | `unicode` | `unicode` |
| `filename_max` | 120 | 120 | 120 | 120 | 200 |
| `number_prefix` | no | no | no | no | no |

Notes that must survive into the code comments and docs:

- **`raw-big5`/`raw-gbk` are a deliberate spec violation.** Many old Chinese-market players
  read ID3v2.3 text frames declared as ISO-8859-1 but containing Big5/GBK bytes. Implement
  as: encode text with the target codec, then hand the bytes to mutagen as a latin-1 frame.
  Comment it as intentional so a future reader doesn't "fix" it.
- **`lrc_on_unencodable = "strict"` is the default on purpose.** `errors="replace"` turns a
  Japanese line into `?そうそう` silently. Strict mode must fail with the offending
  character and line number and suggest `--lrc-encoding utf-8` or `--lrc-on-unencodable replace`.
- `ipod` disables the sidecar because that family reads embedded USLT only.
- `filename_charset = "ascii"` (transliterate/strip) exists as a flag but is off everywhere
  by default — turn it on only if the player shows blank/garbage filenames.
- `number_prefix` writes `01 - Title.mp3`; many old players sort by filename or raw FAT
  order, so it is the fix for "playlist plays in the wrong order".

## B. Subcommands

| Command | Purpose |
|---|---|
| `ytmv get <URL>…` | Download → convert → tag → lyrics. The workhorse. |
| `ytmv lyrics <PATH>…` | (Re)attach lyrics to files that already exist. `--pick` for interactive LRCLIB disambiguation, `--artist/--track` to force the query. Network. |
| `ytmv tag <PATH>…` | Re-apply a profile to existing files — ID3 version/encoding, `.lrc` transcode, cover resize, filename rewrite. **Offline.** This is the "my player showed garbage, try another profile" loop. |
| `ytmv doctor` | Environment probe; see § J. |

`Args` sketch for `get` (every field `Annotated[T, tyro.conf.arg(help=…)]` with a default,
per `scripts/yth/search.py:30-45`):

```python
urls: Annotated[list[str], tyro.conf.Positional, ...] = field(default_factory=list)
from_file: str = ""              # a file of URLs, one per line
audio: bool = True               # produce mp3
video: bool = False              # produce mp4
burn_subs: bool = False          # hardsub (implies --video); needs libass
soft_subs: bool = True           # applies when --video
profile: str = ""                # "" -> config default -> "safe"
out: str = ""                    # "" -> config default -> ~/Music/ytmv
lyrics: Literal["auto","lrclib","youtube","none"] = "auto"
langs: list[str] = field(default_factory=list)     # "" -> yth config langs
artist / track / album: str = ""                   # manual override, single-URL only
number: bool = False             # 01 - prefix
m3u: bool = False                # emit a .m3u next to the files
max_height: int = 0              # 0 = best; e.g. 480 for tiny screens
cookies: bool = False            # reuse yth's cookie source
force: bool = False              # re-download / re-tag existing
sleep: float = 1.5               # between items, matches yth's rate-limiting
json_out: Annotated[bool, tyro.conf.arg(name="json")] = False
```

Plus per-setting overrides that shadow the profile: `--id3-version`, `--id3-encoding`,
`--lrc-encoding`, `--lrc-on-unencodable`, `--no-lrc-sidecar`, `--no-embed-lyrics`,
`--cover-max`, `--no-cover`, `--ascii-filenames`.

## C. Pipeline

**Use the yt-dlp Python API** (`yt_dlp.YoutubeDL`), not the binary — `scripts/yth/fetch_subs.py:80-104`
already establishes that pattern, it gives structured `info` dicts for free (no `--print`
parsing), and it keeps the version pinned by PEP 723 rather than by whatever is on PATH.
Go through the lazy `ytdl()` shim so `tag`/`doctor` never import it.

**Tagging is owned by mutagen, not yt-dlp.** Disable `--embed-metadata`/`--embed-thumbnail`
entirely: yt-dlp's postprocessors write ID3v2.4 and cannot do v2.3 downgrade, `raw-big5`
frames, USLT, or SYLT. Letting both write causes double-writes and conflicting frames.
yt-dlp's only job is: fetch media, convert the container/codec, fetch subtitle files.

Per output mode:

1. **mp3** — `format: "bestaudio/best"`, `FFmpegExtractAudio` postprocessor to `mp3`
   (preferredquality from config, default `0`/V0). Then mutagen writes TIT2/TPE1/TALB/TDRC/
   TRCK, APIC (cover), USLT (+SYLT if enabled), and saves with `v2_version=<profile>`.
2. **mp3 + sidecar `.lrc`** — same, plus the LRC text written next to the mp3 with the same
   basename in `lrc_encoding`, honouring `lrc_on_unencodable`.
3. **mp4 soft-sub** — `-t mp4` equivalent (`merge_output_format: mp4`, format sort
   `vcodec:h264,acodec:aac`), `--max-height` via a format filter, `writesubtitles` +
   `embedsubtitles` postprocessor. Note in docs that most old players **ignore** soft subs.
4. **mp4 hardsub** — see § E.

**Metadata chain for artist/track/album** (needed for both tagging and the LRCLIB query):
`--artist/--track/--album` flags → yt-dlp `info["artist"]/["track"]/["album"]/["release_year"]`
(populated for Music-category videos) → parse `"Artist - Title"` from `info["title"]`,
stripping the usual noise (`(Official Music Video)`, `[MV]`, `【…】`, `feat.` handling) →
fall back to `info["channel"]` as artist and the cleaned title as track. `ytmv get --json`
must report which rung of the chain was used, so a bad LRCLIB match is diagnosable.

**Cover art without ImageMagick**: yt-dlp downloads the thumbnail (often `.webp`); resize
and convert to JPEG with `ffmpeg -i thumb.webp -vf scale=<max>:-1 cover.jpg`. ffmpeg is
already the hard dependency for audio extraction, so this adds nothing new.

## D. Lyrics chain

`auto` = try each rung until one yields text:

1. **LRCLIB exact** — `GET /api/get` with `artist_name`, `track_name`, `duration`
   (and `album_name` when known). Accept if `abs(hit.duration - actual) <= 3s`.
2. **LRCLIB fuzzy** — `GET /api/search?q="<artist> <track>"`. Rank by duration delta, then
   `artistName` similarity. Auto-pick the best hit when the delta is ≤3s **and** it is
   unambiguously ahead of the runner-up; otherwise skip (in `get`) or prompt (in
   `lyrics --pick`, a numbered `rich` table). `instrumental: true` → record "instrumental",
   do not write an empty `.lrc`.
3. **YouTube captions** — yt-dlp with `skip_download: True`, `writesubtitles`,
   `writeautomaticsub`, `subtitleslangs`, `subtitlesformat: "lrc"`, `convertsubtitles`.
   Mark the result as `source=youtube` (auto-captions of songs are frequently wrong).
4. **`plainLyrics`** from the LRCLIB hit → unsynced. Goes into USLT only; **never** written
   as a `.lrc` with fake timestamps.
5. Give up: stderr note, **exit 0** (not an error — matches `scripts/yth/search.py:140-142`).

Client: `httpx`, explicit `User-Agent: ytmv/<version> (+https://github.com/…)` per LRCLIB's
request, 10s timeout, sequential with the same `--sleep` throttle as the downloads. Cache
responses at `~/.cache/ytmv/lrclib/<sha256(query)>.json` with a 30-day TTL and a
`_CACHE_VERSION` constant to bump for invalidation (the `executable_appsrc:73` convention).
Network failure is non-fatal: warn, fall through to the next rung.

## E. Hardsub — the one thing the host can't do today

`--burn-subs` needs libass, which the installed ffmpeg lacks. Design:

- **Probe** (in `__init__.py`, used by both `get` and `doctor`): run
  `<ffmpeg> -hide_banner -filters`, look for a line whose filter name is exactly
  `subtitles`. Cache the result per-binary-path in memory for the process.
- **Binary selection**: config key `ffmpeg = "<path>"`; when unset, auto-detect in order
  `$(brew --prefix ffmpeg-full)/bin/ffmpeg` → `$(brew --prefix ffmpeg@7)/bin/ffmpeg` →
  `ffmpeg` on PATH. Because those formulae are **keg-only**, installing one does not
  shadow or conflict with the plain `ffmpeg` — this is why it is a clean fix.
- **Behaviour**: `--burn-subs` **hard-fails** with exit 3 when no libass-capable ffmpeg is
  found. Silently degrading to soft subs would hand the user a file their player shows
  nothing on — the exact failure this tool exists to prevent. Message names the probe that
  failed, the binaries tried, and the fix: `brew install ffmpeg-full` (macOS) /
  `apt install ffmpeg` (Debian builds ship libass) / set `ffmpeg = "…"` in
  `~/.config/ytmv/config.toml`.
- **Ansible**: add `ffmpeg-full` to the macOS Homebrew list in
  `dot_ansible/roles/media_tools/tasks/main.yml:17-27`. That role is already behind
  `installMediaTools`, so this respects the CLAUDE.md rule (adding a libass-capable variant
  *inside* the gated role is fine; promoting ffmpeg to `devtools` is not). Debian's `ffmpeg`
  already links libass — no Linux change needed.
- **LRC → SRT conversion** (hardsub needs timed subtitle input; LRC has only start times):
  each line's end = the next line's start; the last line gets `+5s`; drop LRC metadata tags
  (`[ar:]`, `[ti:]`, `[al:]`, `[by:]`, `[offset:]`) and apply `[offset:]` if present;
  collapse duplicate timestamps (multi-line-per-timestamp LRC) into one cue. Then
  `ffmpeg -i in.mp4 -vf "subtitles=out.srt:force_style='…'" -c:a copy out.mp4`.
  Pure-function, fully unit-testable offline.

## F. Output layout and batch handling

- Default `--out`: `~/Music/ytmv/` (the dir exists), overridable in config and per-invocation.
  **Flat by default** — old players and FAT32 cope badly with deep trees, and a flat folder
  is what you drag onto a card. `--tree` opts into `Artist/Album/`.
- Filename sanitiser: strip FAT32-illegal `<>:"/\|?*`, control chars, and trailing dots/
  spaces; collapse whitespace; cap at `filename_max` **graphemes** (not bytes) preserving the
  extension; never emit a Windows reserved name (`CON`, `NUL`, `COM1`…).
- Playlists: a playlist URL expands via `extract_flat`; `--from-file` reads one URL per line
  (`#` comments). **Sequential with `--sleep`**, mirroring `scripts/yth/fetch_subs.py:151-152`
  — YouTube rate-limits aggressively and this host already trips the bot check.
- Skip-existing by default (target file present and non-empty), `--force` to redo.
  Per-item failures are counted and reported at the end; the run continues.
- `--m3u` writes a UTF-8 `.m3u` in `--out`; note in docs that some players need `.m3u8` or
  CRLF, and expose `--m3u-encoding`/`--m3u-crlf` if that turns out to matter.

## G. Files to create / modify

**New:**

1. `dot_dotfiles/bin/executable_ytmv` — launcher (§ Architecture).
2. `scripts/ytmv/__init__.py` — `PROFILES`, `load_config()`, `resolve_profile()`,
   `ffmpeg_bin()`, `has_libass()`, `lrc_to_srt()`, `write_lrc()`, `sanitize_filename()`,
   `tag_mp3()`, `lrclib_get()`/`lrclib_search()`, `parse_artist_track()`.
   Section-banner comments; lazy imports inside functions (`scripts/yth/__init__.py` style).
3. `scripts/ytmv/{get,lyrics,tag,doctor}.py` — tyro leaves, `prog=` matching the launcher's
   `leaves` dict.
4. `dot_config/zsh/tools/60_ytmv_completion.zsh` + `dot_config/bash/60_ytmv_completion.bash`
   — Strategy B hand-written pair mirroring `53_yth_completion.{zsh,bash}`. **60 is the next
   free prefix** in the 45–59 completion band. Complete `--profile` from the `PROFILES` keys
   via a hidden `ytmv doctor --list-profiles` flag (the `appsrc scan --list-names` pattern,
   `dot_config/zsh/tools/57_appsrc_completion.zsh:9-14`).
5. `docs/tools/ytmv.md` — mirror `docs/tools/yth.md`'s section order. A `.zh-TW.md` twin is
   optional; the newer pages (`appsrc`, `data-viewers`, `office-viewers`) skip it.
6. `tests/unit/ytmv.bats` — offline black-box, PATH-stub style, **including** the
   `"help and both completion files advertise every public option"` test from
   `tests/unit/herdr_grep.bats:610`.

**Modified:**

7. `dot_ansible/roles/media_tools/tasks/main.yml` — add `ffmpeg-full` to the macOS brew list.
8. `docs/this_repo/tool-managers.md` — § Tool index (A–Z) row for `ffmpeg-full`
   (`| **ffmpeg-full** | brew (keg-only) | — | media_tools |`) near the `ffmpeg` row.
   No uv-table change (`mutagen` is PEP-723-only, ships no binary).
9. `docs/zsh/zsh-completions.md` § F — table row for `ytmv` (`:143-162`).
10. `docs/shells/aliases.md` — row in § Media / AV (`:698`), type `CLI (bin)`, plus the
    § Table of Contents at `:13`. (`aliases.zh-TW.md` already lacks `yth`/`appsrc`; skip.)
11. `mkdocs.yml` — en nav entry in the in-house-CLI cluster (`:355-365`) and the zh-TW
    **title-translation map** line (`~:160`) if a zh-TW page is written.
12. `dot_agents/skills/chezmoi-dotfiles/SKILL.md.tmpl` — one bullet under
    `## Custom in-house CLIs` (`:123-145`). Prose there does **not** re-render on apply, so
    without this the tool is invisible to every agent.
13. `CLAUDE.md` — extend the existing paired-TUI/`yth` cross-file row to record the
    `ytmv → scripts.yth.cookie_opts` coupling and the `--burn-subs` ⇄ `media_tools`
    `ffmpeg-full` dependency.
14. `README.md` — a line only if `installMediaTools` guidance changes; likely just the
    "What You Get" media row.

**Deliberately skipped:** a `dot_config/television/cable/ytmv.toml` channel. `tv` channels
are pickers over an existing inventory; `ytmv` is a one-shot downloader with no list to
fuzzy-pick. The one place a picker fits is LRCLIB disambiguation, and that is better served
by `ytmv lyrics --pick`'s inline `rich` table than by a channel. Revisit if a
`ytmv list`/library view ever exists.

## H. Verification

**Offline / no network (the bulk of it, runnable as bats + `python3 -c`):**

```bash
# pure functions
ytmv doctor --list-profiles                     # profile resolution + override precedence
python3 -c "..."                                # lrc_to_srt(): end=next start, last +5s,
                                                #   [offset:] applied, metadata tags dropped,
                                                #   duplicate timestamps collapsed
python3 -c "..."                                # write_lrc() strict mode raises on 涙/é/♪/𠮷
python3 -c "..."                                # sanitize_filename(): FAT32 chars, trailing
                                                #   dot, CON/NUL, grapheme cap keeps ext

# ID3 round-trip against a generated silent file (no download)
ffmpeg -f lavfi -i anullsrc -t 1 -q:a 9 /tmp/t.mp3
ytmv tag /tmp/t.mp3 --profile safe --artist A --track T
python3 -c "from mutagen.id3 import ID3; f=ID3('/tmp/t.mp3'); print(f.version, f.getall('USLT'))"
# expect (2,3,0) and a USLT frame; repeat with --profile modern -> (2,4,0)
#         and --profile cjk-big5 -> latin-1-declared frame containing big5 bytes

just bats                                       # baseline is 7 pre-existing failures — diff by
                                                #   test NAME against a clean worktree, not by count
uv run mkdocs build --strict                    # baseline ~12 warnings, same rule
```

**`ytmv doctor` must assert**, each with pass/fail and a fix hint: `uv` present; `yt-dlp`
importable + version; `ffmpeg` resolved path + version; **libass/`subtitles` filter
present**; `mutagen` importable; cookie source configured (and which — reused from `yth` or
overridden); `--out` writable; active profile with every resolved setting printed; LRCLIB
reachable (`--offline` to skip).

**Network (needs a cookie source, since this host trips the bot check):**

```bash
ytmv get "<a music video URL>" --profile safe --out /tmp/ytmv-test --cookies --json
# assert: mp3 + .lrc written; --json reports which metadata rung and which lyrics rung fired
ytmv get "<same URL>" --video --burn-subs --out /tmp/ytmv-test --cookies
# on this host today: expect exit 3 with the libass message. After `brew install ffmpeg-full`,
# expect a burned-in mp4.
```

**Real-device check** — the only test that actually settles the profile question: copy one
file per profile onto the player and see which shows title and lyrics correctly. `ytmv tag`
exists so this loop needs no re-downloading.

## I. Risks and open questions

1. **The default profile is a guess.** Player unknown, so `safe` (v2.3 + UTF-16 + UTF-8
   `.lrc` + USLT + sidecar) is the broadest-compatibility bet, and `ytmv tag` makes
   re-trying cheap. Expect one round of trial and error on the real device.
2. **Hardsub needs a second ffmpeg install.** `brew install ffmpeg-full` is keg-only so it
   is non-invasive, but it is ~47 dependencies and only pays off if `--burn-subs` is
   actually used. Worth confirming the user wants that before wiring the ansible change.
3. **LRCLIB coverage for Mandarin/Cantonese pop is thinner than for Western tracks.** The
   user chose LRCLIB + YouTube captions and declined the NetEase fallback; if coverage
   disappoints, `lyrics.py`'s rung structure makes NetEase a contained addition.
4. **Bot checks.** Cookies will be needed more often than for `yth`, because downloading is
   more aggressively gated than metadata. Reusing `yth`'s cookie config means the Arc
   `cookies.txt` export expires and must be refreshed (`docs/tools/yth.md:76-78`).
5. **SYLT is off everywhere by default.** Support is rare and mutagen's SYLT handling is
   fiddly; the sidecar `.lrc` plus USLT covers far more devices. Flag exists, off by default.
6. **Copyright** is the user's call — the tool is general-purpose and fetches lyrics from a
   public API for personal device use.
