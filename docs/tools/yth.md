# yth — search your YouTube watch history

`yth` is a local-first CLI + Television (`tv`) picker for your own YouTube watch history.
YouTube's native `/feed/history` search only matches titles; `yth` indexes **titles,
channels, descriptions, and caption text** in a local sqlite database and searches them with
FTS5 — so "I know I watched something about X" becomes a one-line query. It's the
gh-select-style twin pattern used by `mlf` + `tv mlflow` and [`fleet hosts`](fleet-hosts.md).

Binary: `dot_dotfiles/bin/executable_yth` (→ `~/.dotfiles/bin/yth`). Modules: `scripts/yth/`.
Picker twin: `tv yth` (`dot_config/television/cable/yth.toml`).

## Install

Deployed automatically by chezmoi:

- `yth` self-bootstraps its Python deps via a `uv run --script` shebang (PEP 723 inline
  metadata declaring `yt-dlp`, `tyro`, `rich`, `platformdirs`) — no separate install step.
- `yt-dlp` is **also** installed as a standalone binary by the `python_uv_tools` ansible
  role (same dual pattern as `mlflow` ↔ `mlf`), so `yt-dlp` is on PATH independently.
- Needs `uv` on PATH; `bat` for the `tv yth` preview pane; `ffmpeg` (already via the
  `media_tools` role) is optional (only for muxing, which `yth` doesn't do).

## Two data sources (and why)

Your watch history is **not** in the YouTube Data API (removed ~2016). `yth` gets it two ways:

| Source | Command | Cookies? | Coverage | Timestamps |
|---|---|---|---|---|
| **Google Takeout** (primary) | `yth import-takeout <file>` | no | full multi-year history | exact (from the export) |
| **yt-dlp `:ythistory`** (secondary) | `yth sync` | **yes** | recent page-loadable window only | approximate (sync time) |

Export from [Google Takeout](https://takeout.google.com/) → *YouTube and YouTube Music* →
history → **JSON** format → `watch-history.json`. Import is idempotent: re-importing the
same (or an overlapping) export adds nothing. Use `sync` for quick incremental top-ups
between exports; Takeout stays the source of truth.

## Quick start

```bash
yth import-takeout ~/Downloads/watch-history.json   # backfill (cookie-free)
yth enrich --limit 500                              # fill descriptions/durations (public)
yth fetch-subs --recent 100                         # index captions for recent videos
yth search "rust async"                             # search title/channel/description
yth search "borrow checker" --subs                  # also search caption text
tv yth                                              # fuzzy-pick the whole history
```

## Subcommands

| Command | What it does |
|---|---|
| `import-takeout <file>` | Backfill from a Takeout `watch-history.json` (JSON only). Idempotent. |
| `sync [--limit N] [--full]` | Incremental `:ythistory` sync (needs cookies). Walks newest→cursor. |
| `enrich [--limit N \| --all] [--cookies] [--force]` | Fetch title/description/duration/upload_date. Cookie-free for public videos. Permanent failures (removed/private) are stamped; transient (bot-check/429) retry next run. |
| `fetch-subs <id>… \| --recent N \| --all [--cookies] [--langs …]` | Download manual+auto captions, flatten VTT→text, index. |
| `search <query> [--subs] [--json] [--limit N] [--raw]` | FTS5 search. `--subs` also matches captions; `--raw` uses native FTS5 syntax. |
| `list [--tsv] [--limit N]` | List history newest-first. `--tsv` is the `tv yth` source. |
| `show <id> [--json]` | One-video detail (DB-only, no network). Powers the tv preview. |
| `open <id>` / `copy <id>` / `play <id>` | Open in browser / copy URL / play (mpv if configured, else browser). |

## Cookies (only `sync` + restricted videos)

**Public videos need no cookies** — `enrich` and `fetch-subs` of public content work
unauthenticated. Cookies are required only for `yth sync` (your account-private history)
and for members-only / age-restricted / private videos.

yt-dlp's `--cookies-from-browser` knows `brave, chrome, chromium, edge, firefox, opera,
safari, vivaldi, whale` — **not** `arc` or `zen` (both are forks). Handle them like this:

| Browser | Mechanism | Config |
|---|---|---|
| **Zen** (Firefox fork) | yt-dlp reads Firefox-format `cookies.sqlite` from an explicit profile path. Auto-detected if Zen is installed. | `from_browser = "firefox:/path/to/zen/Profiles/<profile>"` |
| **Arc** (Chromium fork) | The `chrome` keyword derives the Keychain service name *"Chrome Safe Storage"*; Arc's is *"Arc Safe Storage"* and there's no flag to override it, so keyword extraction can't decrypt Arc cookies on macOS. Export a `cookies.txt` instead. | `cookiefile = "~/.config/yth/cookies.txt"` |
| Standard Chrome/Firefox/… | Use the keyword directly. | `from_browser = "firefox"` (or `chrome`, …) |

To export Arc cookies: install the **"Get cookies.txt LOCALLY"** extension (Arc is Chromium,
so Chrome Web Store extensions install), visit `youtube.com` logged in, Export → save as
`~/.config/yth/cookies.txt`. These expire; re-export periodically.

## The `tv yth` channel

`tv yth` (or bare `yth`) opens a fuzzy picker over `yth list --tsv`. Television's source is
single-shot and never sees the live query, so the channel fuzzy-filters the **title/channel
display string** only — **caption/description search stays in `yth search --subs`**.

| Key | Action |
|---|---|
| `Enter` / `Ctrl+O` / `Alt+B` | Open the video in the browser |
| `Ctrl+Y` | Copy the video URL |
| `Alt+P` | Play (mpv if configured, else browser) |
| `Alt+S` | Fetch captions for this video, then show detail |
| `Alt+J` | Dump the video's JSON detail |

`Alt+` (not `Ctrl+`) is used for new actions because this repo's tmux prefix is `Ctrl+b` —
a `ctrl-b` binding would be swallowed before tv saw it. The `o/b/y/p/s/j` mnemonics are the
SSOT for a future `yth tui`.

## Config — `~/.config/yth/config.toml`

```toml
# cookiefile   = "~/.config/yth/cookies.txt"                    # Arc / any browser (export)
# from_browser = "firefox:/…/zen/Profiles/xxxx.Default"        # Zen (auto-detected if unset)
langs        = ["en", "en-US"]                                 # subtitle languages to fetch
open_target  = "browser"                                       # browser | mpv
```

## Storage

Resolved via `platformdirs` (honours `XDG_*`): DB at `~/.local/share/yth/history.db`, config
at `~/.config/yth/config.toml`, cache at `~/.cache/yth/`. Set `$YTH_DB` to override the DB
path (used by tests). Schema: `videos` (+ `videos_fts`), `watch_events` (one row per watch;
stats via the `video_stats` view), `subtitles` (+ `subtitles_fts`), `meta`. FTS is
external-content with triggers, so `enrich`/`fetch-subs` UPDATEs re-index automatically.

## Cross-file invariants

Touching `yth` means keeping these in sync (see the `CLAUDE.md` cross-file table row):

1. `dot_dotfiles/bin/executable_yth` — launcher (PEP723 deps + dict-dispatch). Shared helpers
   live in `scripts/yth/__init__.py`; leaf subcommands in `scripts/yth/*.py`.
2. `dot_config/television/cable/yth.toml` — the `o/b/y/p/s/j` mnemonics mirror any future
   `yth tui`; new actions use `Alt+`.
3. `dot_config/zsh/tools/53_yth_completion.zsh` + `dot_config/bash/53_yth_completion.bash` —
   keep the two in sync (Strategy B).
4. `dot_ansible/roles/python_uv_tools/defaults/main.yml` — the `yt-dlp` entry (dual with the
   launcher PEP723 block).
5. Docs: this page (+ `yth.zh-TW.md`), `docs/shells/aliases.md`, `docs/zsh/zsh-completions.md`
   §F, `docs/this_repo/tool-managers.md` A–Z + uv inventory, `mkdocs.yml` nav,
   `dot_agents/skills/chezmoi-dotfiles/SKILL.md.tmpl`.

## Troubleshooting

- **`Sign in to confirm you're not a bot`** on `enrich`/`fetch-subs`/`sync` — YouTube
  bot-check, common from datacenter IPs. It's treated as transient (not stamped), so it
  retries next run. Configure cookies (`--cookies` for enrich/fetch-subs) or run from a
  residential IP.
- **`no captions`** — the video genuinely has no subtitles in the configured `langs`. Add
  langs (`--langs en,en-orig,zh-Hant`) or accept it (the video is stamped so it won't retry;
  `--force` to retry).
- **`yth sync: no cookie source configured`** — expected until you set `cookiefile` or
  `from_browser`. Prefer `yth import-takeout` for full history (no cookies needed).
- **Empty `tv yth`** — no history imported yet. Run `yth import-takeout` or `yth sync`.
