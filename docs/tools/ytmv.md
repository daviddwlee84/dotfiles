# ytmv — YouTube music videos for old MP3 players

`ytmv` downloads YouTube music videos and prepares them for playback on **old MP3 players**,
with lyrics visible on the device.

`yt-dlp` alone gets you a file; it does not get you a file a 2008 player can use. That gap
is what `ytmv` fills: ID3v2.3 instead of v2.4, optional raw Big5/GBK text frames, a sidecar
`.lrc` in the encoding the device expects, FAT32-safe filenames, small JPEG cover art, and
real synced lyrics from [LRCLIB](https://lrclib.net) — official music videos usually carry
no YouTube captions at all.

Binary: `dot_dotfiles/bin/executable_ytmv` (→ `~/.dotfiles/bin/ytmv`). Modules: `scripts/ytmv/`.
Sibling of [`yth`](yth.md), which searches your watch history but deliberately never downloads.

## Install

Deployed automatically by chezmoi:

- `ytmv` self-bootstraps its Python deps via a `uv run --script` shebang (PEP 723 inline
  metadata declaring `yt-dlp[default]`, `tyro`, `rich`, `platformdirs`, `mutagen`, `httpx`).
  The `default` extra supplies the yt-dlp-matched **`yt-dlp-ejs`** challenge solver; remote
  component downloads are deliberately disabled.
- Embedded yt-dlp calls enable the repo-managed **Node** runtime only when it is Node 22+
  (installed through mise). Standalone `~/.config/yt-dlp/config` is not read by the Python API,
  so this is code, not a user config knob. `ytmv doctor` checks both EJS and Node. Legacy
  armv7/armv6 (managed Node 20) and EL7 (normally Node 16) cannot solve current EJS challenges;
  doctor fails instead of claiming the old runtime works. EL7 x86_64 can use the documented
  micromamba Node 22 escape hatch; armv7 has no managed supported runtime.
- **`ffmpeg` is required** for `ytmv get` (audio extraction and every video path). It comes
  from the `media_tools` ansible role, which is gated behind the `installMediaTools` chezmoi
  prompt — answer **yes**, or set `ffmpeg = "…"` in the config.
- **`--burn-subs` additionally needs libass.** homebrew-core's plain `ffmpeg` 8.x is built
  without it, so the same role also installs **`ffmpeg-full`**, which is keg-only and
  therefore does not shadow or conflict with `ffmpeg` on PATH. `ytmv` finds it by explicit
  path. Debian's `ffmpeg` already links libass, so Linux needs nothing extra.
- `mutagen` is intentionally **not** a `python_uv_tools` entry — it ships no binary, so it
  lives only in the PEP 723 block.

Run `ytmv doctor` first; it tells you exactly what is missing and how to fix it.
The full deployed guide is also available offline as `ytmv help`.

## Public-first setup and diagnosis

A public YouTube video normally needs **no account cookie**. Start with:

```bash
dotcfg --set installMediaTools=true --yes
command -v node && node --version
ytmv doctor
ytmv get 'https://www.youtube.com/watch?v=...'
```

If YouTube says `Sign in to confirm you're not a bot`, diagnose in order:

1. `ytmv doctor`: fix required `yt-dlp-ejs`, Node, ffmpeg, or public metadata failures.
2. Try a clean residential network. VPN/proxy/cloud/datacenter exits are commonly challenged.
3. Stop repeated retries, wait, and raise batch pacing (`--sleep 10`).
4. Use an account cookie only for genuinely private/restricted content, or as a deliberate
   last-resort bot-check retry. An advanced PO-token provider comes after these steps.

`ytmv doctor --offline --json` keeps network checks as `skip` and validates the local stack.
`ytmv doctor --cookies` explicitly tests loading/decrypting the configured source; it does
**not** prove that the account may access every URL.

## The four outputs

| Want | Command | Notes |
|---|---|---|
| mp3 + sidecar `.lrc` | `ytmv get <URL>` | The default. What most old players read. |
| mp3 with lyrics inside the file | `ytmv get <URL>` | USLT frame, written by default alongside the sidecar. `--embed-sylt` adds SYLT. |
| mp4 with soft subtitles | `ytmv get <URL> --video` | A real subtitle track. **Most old players ignore it.** |
| mp4 with lyrics burned in | `ytmv get <URL> --video --burn-subs` | Always visible, because it is part of the picture. Needs libass. |

## Quick start

```bash
ytmv help                                            # complete setup / cookie-safety guide
ytmv doctor                                          # check local + public-download stack
ytmv get 'https://www.youtube.com/watch?v=...'       # mp3 + .lrc + tags + cover
ytmv get '<playlist-url>' --number --m3u roadtrip    # numbered files + a playlist
ytmv get '<url>' --video --burn-subs --max-height 480
ytmv tag ~/Music/ytmv --profile cjk-big5             # player showed mojibake → re-encode
ytmv lyrics ~/Music/ytmv --pick                      # fix a wrong lyrics match by hand
```

## Subcommands

| Command | What it does |
|---|---|
| `get <URL>…` | Download → convert → tag → attach lyrics. Accepts video URLs, playlist URLs, bare 11-char ids, and `--from-file`. |
| `lyrics <PATH>…` | Find and attach lyrics to mp3s that already exist. `--pick` resolves ambiguous LRCLIB matches interactively; `--artist`/`--track` force the query. |
| `tag <PATH>…` | Re-apply a profile in place — ID3 version/encoding, `.lrc` encoding, cover size, filenames. **Never touches the network.** |
| `doctor` | Probe yt-dlp/EJS/Node, public YouTube metadata, ffmpeg/libass, mutagen, LRCLIB, cookies, output dir, and print the fully resolved profile. `--offline` skips network; `--cookies` opts into source loading/decryption; `--list-profiles` feeds completions. |
| `help [SUBCOMMAND]` | Full import-free setup/security guide, or delegate to one leaf command's Tyro help. `-h`/`--help` intentionally stay concise. |

## Compatibility profiles — the important part

You usually do not know what your player wants. So every compatibility knob is a setting,
profiles bundle sensible combinations, and **`ytmv tag` re-applies any profile to files you
already downloaded** — bisecting costs no bandwidth.

| Setting | `safe` (default) | `cjk-big5` | `cjk-gbk` | `ipod` | `modern` |
|---|---|---|---|---|---|
| `id3_version` | 3 | 3 | 3 | 3 | 4 |
| `id3_encoding` | `utf16` | `raw-big5` | `raw-gbk` | `utf16` | `utf8` |
| `lrc_sidecar` | yes | yes | yes | **no** | yes |
| `lrc_encoding` | `utf-8` | `cp950` | `gbk` | — | `utf-8` |
| `lrc_on_unencodable` | `strict` | `strict` | `strict` | — | `strict` |
| `embed_uslt` / `embed_sylt` | yes / no | yes / no | yes / no | yes / no | yes / no |
| `cover` / `cover_max` | jpeg / 300 | jpeg / 300 | jpeg / 300 | jpeg / 300 | jpeg / 600 |
| `filename_charset` | `unicode` | `unicode` | `unicode` | `unicode` | `unicode` |
| `filename_max` | 120 | 120 | 120 | 120 | 200 |
| `number_prefix` | no | no | no | no | no |

Select with `--profile NAME`; override any individual setting with its own flag
(`--id3-version`, `--lrc-encoding`, `--skip-lrc-sidecar`, `--cover-max`, …). Resolution
order: **built-in profile → user `[profiles.<name>]` → config top-level defaults → CLI flag**.

### Suggested bisect when the player misbehaves

| Symptom on the device | Try |
|---|---|
| Title/artist blank or `????` | `ytmv tag <dir> --profile cjk-big5` (or `cjk-gbk`) |
| Lyrics never appear | `ytmv tag <dir> --profile ipod` (embeds only, drops the sidecar) |
| Filenames blank/garbled | `ytmv tag <dir> --ascii-filenames` |
| Tracks play in the wrong order | re-fetch with `ytmv get … --number` |
| Cover art missing or file rejected | `ytmv tag <dir> --cover-max 200`, or `--skip-cover` |

### Two deliberate oddities

- **`raw-big5` / `raw-gbk` violate the ID3 spec on purpose.** Many old Chinese-market
  players ignore a frame's declared encoding byte and assume the local codepage, so those
  modes encode text to Big5/GBK and then declare the frame as latin-1. The file ends up
  holding exactly the bytes such a player expects. Do not "fix" this.
- **`cp950`, not bare `big5`.** cp950 is the Microsoft superset that player firmware
  actually implements; strict `big5` rejects characters real players render fine (`碁`, `～`,
  `‧`). Same reasoning applies to `gbk` over `gb2312`.

## Lyrics sources

`--lyrics auto` (the default) walks this chain and stops at the first hit:

1. **LRCLIB exact** — `/api/get` with artist + track + duration. Accepted within ±3 s.
2. **LRCLIB fuzzy** — `/api/search`, ranked by duration proximity then name similarity.
   Auto-picked only when unambiguous; otherwise skipped (use `ytmv lyrics --pick` to choose).
3. **YouTube captions** — fetched via yt-dlp and converted to LRC.
4. **Unsynced text** — goes into the USLT frame only, never into a `.lrc` with invented
   timestamps.
5. Give up: a note on stderr, exit 0. A song with no lyrics on LRCLIB is a fact, not an error.

`--lyrics lrclib` / `youtube` / `none` restrict the chain. Responses are cached for 30 days
under the cache dir; `--refresh-lyrics` bypasses it.

!!! note "Why YouTube captions are the fallback, not the primary"
    Official music videos frequently have no captions at all, and auto-generated ones are
    ASR transcripts of singing — often wrong. yt-dlp's own `--convert-subs lrc` also does no
    deduplication of YouTube's rolling caption repetition, so `ytmv` dedupes the result
    itself before writing it.

## Cookies

`ytmv` is cookie-free by default and deliberately reuses `yth`'s source only when
`--cookies` is passed; an explicit flag fails rather than silently falling back when no safe source exists. Configure it in `~/.config/yth/config.toml`; a ytmv-local
`cookiefile` / `from_browser` remains an explicit override.

!!! danger "A cookie file is a login credential"
    yt-dlp use with a logged-in account can cause temporary or permanent account suspension.
    Never print, paste, screenshot, commit, `chezmoi add`, or cloud-backup cookie contents.
    Prefer a dedicated YouTube-only profile/account, not a daily primary account. The target
    `~/.config/{yth,ytmv}/cookies.txt` are explicitly excluded from chezmoi management.
    Every file-backed sink rejects non-0600, malformed, expired/empty, or multi-domain
    jars before yt-dlp sees them, and `ytmv get` accepts only YouTube URL hosts.

### Preferred repeat-use source: dedicated Firefox/Zen profile

```toml
# ~/.config/yth/config.toml
from_browser = "firefox:/absolute/path/to/profile"
```

The profile directory must contain `cookies.sqlite`. Zen is Firefox-compatible and is
auto-detected when installed; use the `firefox:` prefix, not `zen:`.

### Arc / Chromium: isolated YouTube-only export

Arc is not a supported yt-dlp browser name. Do **not** export a daily browser profile with
`--cookies-from-browser … --cookies FILE`: that can write cookies for every site.

1. Open a private/incognito session and sign in to YouTube.
2. Keep exactly one tab: <https://www.youtube.com/robots.txt>.
3. Export only `youtube.com` cookies with the exact extension
   **Get cookies.txt LOCALLY**. The similarly named former extension without “LOCALLY” was
   reported as malware.
4. Save as `~/.config/yth/cookies.txt`; run `chmod 600 ~/.config/yth/cookies.txt`.
5. Close the private session. Replace/delete the file after expiry or invalidation.

```toml
# ~/.config/yth/config.toml
cookiefile = "~/.config/yth/cookies.txt"
```

Validate with `ytmv doctor --cookies`, then opt into the actual URL with
`ytmv get '<url>' --cookies`.

### macOS Chrome: `find-generic-password failed`, no popup

Chrome's handler queries Keychain account `Chrome`, service `Chrome Safe Storage`. Diagnose
without printing its secret:

```bash
security find-generic-password -a Chrome -s 'Chrome Safe Storage' >/dev/null
echo $?
security error -25300
```

Exit 44 / OSStatus `-25300` means the item is not addressable. Authorization is never
reached, so no popup is expected. `cannot decrypt v10 cookies: no key found` means yt-dlp
found the DB but cannot derive its key (`v10` is an encryption marker, not Chrome version
10). A newly-created same-named item cannot decrypt values written with the missing original.
Use a new dedicated supported-browser profile or the isolated export above. Never add the
Keychain option that prints the Safe Storage value.

## Manual web-converter fallback

A web converter runs the same broad fetch → audio-extract → transcode pipeline on its own
servers, often behind different IP pools/proxies/cache. It may bypass a challenge attached
to the local IP, but it does not provide ytmv's ID3/LRC/player-compatibility layer. Never
send a converter Google credentials or cookies; it sees the requested URL/IP and may cache
the converted file. A “320 kbps” MP3 cannot restore quality absent from YouTube's lossy
source.

For normal personal-use fallback, download manually and then process the local file:

```bash
ffprobe -v error ~/Downloads/song.mp3
ytmv tag ~/Downloads/song.mp3 --profile safe --artist 'Artist' --track 'Song'
ytmv lyrics ~/Downloads/song.mp3 --artist 'Artist' --track 'Song'
```

Do not hard-code a site's private web endpoint: interfaces drift, and a service may prohibit
scraping/automation. An automated backend belongs in ytmv only when it has a documented API
permitting CLI use or is an audited self-hosted service. Until then the existing `tag` +
`lyrics` path is the backend-neutral fallback.

## Config — `~/.config/ytmv/config.toml`

```toml
# profile = "safe"                     # default profile for every subcommand
# out     = "~/Music/ytmv"             # default output directory
# ffmpeg  = "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg"   # force a specific ffmpeg
# langs   = ["en", "zh-Hant"]          # caption languages (falls back to yth's)
# cookiefile / from_browser belong in ~/.config/yth/config.toml by default

# Any profile setting may be given here as a cross-profile default:
# cover_max = 200

# Your own profile:
# [profiles.my-player]
# id3_version = 3
# id3_encoding = "raw-big5"
# lrc_encoding = "cp950"
```

## Storage and output layout

Resolved via `platformdirs` (honours `XDG_*`): config at `~/.config/ytmv/config.toml`, cache
at `~/.cache/ytmv/lrclib/`. Downloads default to `~/Music/ytmv` (`user_music_dir()`, so
`XDG_MUSIC_DIR` is respected on Linux); `$YTMV_OUT` overrides it for tests.

Output is **flat** — `Artist - Track.mp3` plus a matching `Artist - Track.lrc`. Old players
navigate folders badly, and a flat directory is what you drag onto a card. Write straight to
the device with `--out /Volumes/MP3`. Filenames are sanitised for FAT32: illegal characters
and control codes stripped, trailing dots/spaces removed, reserved DOS names avoided, length
capped, and the sidecar stem always identical to the audio stem (a player finds the `.lrc`
no other way).

## Cross-file invariants

Touching `ytmv` means keeping these in sync (see the `CLAUDE.md` cross-file table row):

1. `dot_dotfiles/bin/executable_ytmv` — launcher (PEP 723 deps + dict dispatch). Shared
   helpers in `scripts/ytmv/__init__.py`; leaf subcommands in `scripts/ytmv/*.py`.
2. **`ytmv` imports `scripts.yth.cookie_opts` / `load_config`** for its cookie source —
   changing `yth`'s config schema changes `ytmv`'s behaviour.
3. **Public YouTube needs packaged EJS + managed Node** — keep `yt-dlp[default]` in both
   launchers and `python_uv_tools`, keep the `yt-dlp-ejs` distribution guard, merge
   `scripts.yth.yt_dlp_runtime_opts()` into every embedded call, and never suppress warnings.
4. **`--burn-subs` depends on `ffmpeg-full`** being in `dot_ansible/roles/media_tools/tasks/main.yml`
   (macOS). Dropping it silently makes burned-in subtitles impossible; `ytmv doctor` is the
   diagnosis.
5. `dot_config/zsh/tools/60_ytmv_completion.zsh` + `dot_config/bash/60_ytmv_completion.bash`
   — keep the two in sync (Strategy B); `tests/unit/ytmv.bats` enforces it.
6. Docs: this page, `docs/shells/aliases.md`, `docs/zsh/zsh-completions.md` § F,
   `docs/this_repo/tool-managers.md` A–Z, `mkdocs.yml` nav,
   `dot_agents/skills/chezmoi-dotfiles/SKILL.md.tmpl`.

**No `tv ytmv` channel, deliberately.** Every Television channel in this repo wraps a fast
local single-shot source; `ytmv` has no local index to fuzzy-pick over. The one place a
picker fits is LRCLIB disambiguation, which `ytmv lyrics --pick` handles inline. Revisit
only if a local library view is ever added.

## Troubleshooting

- **`--burn-subs needs an ffmpeg built with libass`** — the plain homebrew `ffmpeg` cannot
  burn subtitles. `brew install ffmpeg-full` (keg-only, safe), or point `ffmpeg = "…"` at a
  build that has it. `ytmv doctor` shows the probe result.
- **`ffmpeg not found`** — re-run chezmoi init with `installMediaTools=true`, or set
  `ffmpeg` in the config.
- **`cp950 cannot encode '涙' (U+6D99) on line 1`** — the lyrics contain characters the
  target encoding has no room for (Japanese kana in a Big5 file is the usual case). Use
  `--lrc-encoding utf-8`, or `--lrc-on-unencodable replace` to accept `?`. Strict is the
  default so this never happens silently.
- **`Sign in to confirm you're not a bot`** — run `ytmv doctor` and fix EJS/Node first;
  then leave VPN/proxy/cloud egress, wait before retrying, and raise `--sleep`. Cookies are
  an explicit, account-risking last resort (`ytmv doctor --cookies`), not the first fix.
- **Wrong lyrics attached** — the artist/track guess was off. `ytmv get --json` reports
  which metadata rung fired (`yt-dlp-music-metadata`, `title-split`, `channel-fallback`);
  fix it with `ytmv lyrics <file> --artist … --track … --force`, or `--pick` to choose.
- **No lyrics found** — the song may not be on LRCLIB, or it is marked instrumental. Try
  `ytmv lyrics <file> --pick` with a corrected title.
