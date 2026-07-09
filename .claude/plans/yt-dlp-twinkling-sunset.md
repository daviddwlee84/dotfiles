# `yth` — YouTube watch-history search CLI + tv channel

## Context

YouTube's native watch-history search (`/feed/history`) is weak: you can only match
titles, and there's no way to search what was *said* in a video (captions) or query
semantically. The user often remembers having watched *something* but can't find it.
This repo already has a family of in-house `executable_*` CLIs with matching `tv`
(Television) picker channels (`mlf`+`tv mlflow`, `fleet`+`tv fleet-hosts`) — a
gh-select-style workflow. `yth` adds the same shape for personal YouTube history:
fast fuzzy picker over your full history + a CLI that can search **titles, channels,
descriptions, and caption text**.

**Scope decisions (locked with user):**
- MVP = metadata FTS search (title/description/channel) **+ on-demand subtitle fetch**
  and opt-in bulk fetch, with caption text in FTS5.
- Data sources = **both** Google Takeout import (primary, cookie-free, full multi-year
  backfill) **and** yt-dlp `:ythistory` cookie sync (secondary, optional, incremental).
- **Semantic/embedding search → deferred to `backlog/yth-semantic-search.md`.**
- `yt-dlp` gets installed as a first-class tool (user opted in).

**Environment facts (verified on this host):** `ffmpeg` present, `mpv` absent. Browser
for login cookies is **Arc** (Chromium fork, installed) + **Zen** (Firefox fork, not on
this host). yt-dlp has no `arc`/`zen` keyword; Zen works via `firefox:<profile-path>`,
Arc needs a `cookies.txt` export (its Keychain "Arc Safe Storage" key can't be decrypted
by the `chrome` keyword). Cookies only matter for `sync` + restricted videos — public
enrich/subs need none.

---

## Architecture

Clone the `mlf` trio: thin PEP723 launcher + `scripts/yth/` modules + a `tv` channel.

```
dot_dotfiles/bin/executable_yth   # uv PEP723 launcher, dict-dispatch, _source_path()
scripts/yth/__init__.py           # shared: connect()/migrate(), open_id/copy_id/play_id,
                                  #   cookie_opts(), url_for(), vtt_to_text(), lazy ytdl()
scripts/yth/import_takeout.py     # `yth import-takeout` (primary backfill)
scripts/yth/sync.py               # `yth sync`  (:ythistory, lazy yt_dlp, cookies)
scripts/yth/enrich.py             # `yth enrich` (per-video metadata, cookie-free)
scripts/yth/fetch_subs.py         # `yth fetch-subs` (subtitle fetch+parse)
scripts/yth/search.py             # `yth search` (FTS5 metadata / --subs, rich / --json)
scripts/yth/list.py               # `yth list --tsv` (tv source emitter)
scripts/yth/show.py               # `yth show` (DB-ONLY detail; tv preview + CLI)
```

- Launcher mirrors `dot_dotfiles/bin/executable_mlf`: PEP723 shebang
  `#!/usr/bin/env -S uv run --quiet --script`; deps `yt-dlp`, `tyro`, `rich`,
  `platformdirs`; intercept `-h/--help/help` **before** any heavy import; `_source_path()`
  via `chezmoi source-path`; dict-dispatch mapping subcommand `-`→module `_`
  (`import-takeout`→`import_takeout`). Bare `yth` → `os.execvp` `tv yth` (the picker).
- `open`/`copy`/`play` are launcher shims calling helpers in `__init__.py` (like `mlf`'s
  `open_id`/`copy_id`), not separate modules.
- **Lazy `yt_dlp`**: `search`/`list`/`show` use only stdlib `sqlite3` + `rich`. `ytdl()` in
  `__init__.py` imports `yt_dlp` on first use so the hot `yth show` preview path stays
  instant and network-free.
- Deps: `yt-dlp` in the launcher PEP723 block **and** as a `python_uv_tools` entry — the
  exact dual pattern `mlf` uses for `mlflow`.

### SQLite schema (`user_data_dir("yth")/history.db` — macOS: `~/Library/Application Support/yth/`)

Idempotency is the crux (re-imports + Takeout∩sync overlap must not double-count), so
watches are a normalized event table and stats are a view — **not** stored counters.

```sql
PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;

CREATE TABLE videos (
  id INTEGER PRIMARY KEY,              -- rowid alias == FTS content_rowid (video_id is TEXT)
  video_id TEXT UNIQUE NOT NULL,
  title TEXT, channel TEXT, channel_id TEXT, url TEXT,
  description TEXT, duration INTEGER, upload_date TEXT,   -- YYYYMMDD (yt-dlp native)
  enriched_at TEXT, subs_fetched_at TEXT                 -- NULL => needs work
);
CREATE TABLE watch_events (                                -- one row per watch; idempotent
  video_id TEXT NOT NULL, watched_at TEXT NOT NULL,
  source TEXT NOT NULL DEFAULT 'takeout',                 -- 'takeout' | 'sync'
  PRIMARY KEY (video_id, watched_at)
);
CREATE INDEX watch_events_vid ON watch_events(video_id);
CREATE TABLE subtitles (
  id INTEGER PRIMARY KEY, video_id TEXT NOT NULL, lang TEXT NOT NULL,
  text TEXT NOT NULL, fetched_at TEXT, UNIQUE(video_id, lang)
);
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);      -- sync cursor, last-import ts
CREATE VIEW video_stats AS
  SELECT video_id, COUNT(*) watch_count, MIN(watched_at) first_watched,
         MAX(watched_at) last_watched FROM watch_events GROUP BY video_id;

CREATE VIRTUAL TABLE videos_fts USING fts5(
  title, channel, description, content='videos', content_rowid='id',
  tokenize='unicode61 remove_diacritics 2');
-- AFTER INSERT/DELETE/UPDATE triggers on `videos` keep videos_fts in sync
-- (DELETE/UPDATE must emit the fts5 'delete' command-row on old.id, else the index desyncs).
CREATE VIRTUAL TABLE subtitles_fts USING fts5(
  text, content='subtitles', content_rowid='id',
  tokenize='unicode61 remove_diacritics 2');   -- analogous triggers on `subtitles`
```

- `enrich`'s `UPDATE videos SET description=…` auto-reindexes via the `videos_au` trigger —
  the reason external-content FTS beats a hand-synced table.
- **Search MATCH safety**: never pass raw user text to `MATCH` (`-`,`:`,`"`,`*`,`(` throw
  `fts5: syntax error`). Build AND-of-quoted-terms: `" ".join('"'+t.replace('"','""')+'"'
  for t in query.split())`; rank `ORDER BY bm25(videos_fts, 8.0, 4.0, 1.0)` (title≫chan≫desc).
  `--subs` runs a second query on `subtitles_fts` and UNIONs video_ids. `--raw` escape hatch
  for native FTS5 syntax.
- `import-takeout`: parse `titleUrl` → 11-char id (skip rows w/o it: removed videos, search/ad
  rows); strip localized `"Watched "` title prefix; `channel`=`subtitles[0].name`. Upsert
  `videos` filling **only NULL** title/channel (never clobber an enriched title); then
  `INSERT OR IGNORE INTO watch_events`. **Require JSON export** (Takeout → History → JSON);
  `.html` parser deferred to backlog (brittle, locale-dependent).
- `sync` (`:ythistory`) has no per-watch timestamps → walk newest→oldest, stop at
  `meta['sync_cursor']`, `INSERT OR IGNORE watch_events(watched_at=now(), source='sync')`,
  update cursor. Takeout stays source-of-truth for accurate times.

### yt-dlp library recipes (in the network modules only)

Cookie helper in `__init__.py` (tuple is `(BROWSER, PROFILE, KEYRING, CONTAINER)`):
```python
def cookie_opts(cfg):
    if cfg.get("cookiefile"):                       # Arc → exported cookies.txt
        return {"cookiefile": os.path.expanduser(cfg["cookiefile"])}
    if cfg.get("from_browser"):                     # "firefox:/path/to/zen/profile"
        b, _, prof = cfg["from_browser"].partition(":")
        return {"cookiesfrombrowser": (b, prof or None, None, None)}
    return {}                                        # public videos need nothing
```
- **`:ythistory`** (cookies): `{"extract_flat": True, "skip_download": True, "quiet": True,
  **cookie_opts}`, `extract_info("https://www.youtube.com/feed/history", download=False)`;
  entries carry `id/title/uploader`.
- **enrich** (cookie-free public): `{"skip_download": True, "extract_flat": False,
  "sleep_interval": 1, "max_sleep_interval": 3}`; map `title/description/duration/
  upload_date/channel/channel_id`; set `enriched_at=now()` even on private/removed (sentinel
  so `--limit` batches don't retry dead ids forever).
- **fetch-subs** (cookie-free public): download into a `TemporaryDirectory` with
  `{"skip_download": True, "writesubtitles": True, "writeautomaticsub": True,
  "subtitleslangs": langs, "subtitlesformat": "vtt", "outtmpl": ".../%(id)s.%(ext)s",
  "sleep_interval_subtitles": 1, **cookie_opts}`, glob the `*.vtt`, `vtt_to_text()` each.
  `vtt_to_text` strips WEBVTT/`-->`/cue-numbers/`<tags>` and collapses the rolling
  auto-caption dup with `line != last`. Bulk `--all`: sequential, `time.sleep(1–2)`,
  catch `DownloadError`/HTTP 429 with backoff, skip rows with `subs_fetched_at` set.

### tv channel `dot_config/television/cable/yth.toml`

Television's source is **single-shot** (no live-query interpolation — confirmed against
`mlflow.toml`), so tv only fuzzy-filters the metadata **display string**. Deep subtitle
search therefore stays in `yth search --subs` (CLI); the channel is the fast history picker.
`yth list --tsv` over thousands of rows is fine (tv is built for big candidate sets).

TSV columns: `0`=video_id `1`=marker(`▶`/`×N`) `2`=channel `3`=title `4`=last_watched(YYYY-MM-DD)
`5`=duration(H:MM:SS); cells scrubbed of `\t`/`\n`. Mirror `mlflow.toml` `{split:\t:N}`:
```toml
[source]
command = "yth list --tsv"
display = "{split:\\t:3}  ·  {split:\\t:2}  ({split:\\t:4}, {split:\\t:5}) {split:\\t:1}"
output  = "{split:\\t:0}"
no_sort = true
[preview]                                  # DB-only → instant, no network
command = "yth show '{split:\\t:0}' | bat --color=always --plain --paging=never --language=markdown"
[keybindings]
enter="actions:open"; ctrl-y="actions:copy-url"; ctrl-o="actions:open-browser"
alt-b="actions:open-browser"   # b-mnemonic; NOT ctrl-b (this repo's tmux prefix is C-b!)
alt-p="actions:play"; alt-s="actions:subs"; alt-j="actions:json"
```
Action bodies copy `mlflow.toml`: `mode="fork"` for open/copy (reuse its
`pbcopy→wl-copy→xclip→OSC52` clip chain, emit `https://youtu.be/<id>`), `mode="execute"`
for `subs`/`json` (`… | less -R; read -r _`). **Mnemonic set o/b/y/p/s/j** is the SSOT to
mirror into any future `yth tui` (bare letters), tracked in a new CLAUDE.md row like `mlf`'s.

### Config `user_config_dir("yth")/config.toml`
```toml
# cookiefile = "~/.config/yth/cookies.txt"                       # Arc (export via "Get cookies.txt LOCALLY")
# from_browser = "firefox:/…/zen/Profiles/xxxx.Default"          # Zen (auto-detected if unset)
langs = ["en", "en-US"]
open_target = "browser"                                          # browser | mpv
```
Zen auto-detect: glob `~/Library/Application Support/zen/Profiles/*/cookies.sqlite`, degrade
gracefully to "no cookie source" when absent (this host).

---

## Files to change (repo-convention mirrors — required for a new in-house CLI)

**New code/config:** `dot_dotfiles/bin/executable_yth`; `scripts/yth/*.py` (8 files);
`dot_config/television/cable/yth.toml`; completions pair
`dot_config/zsh/tools/53_yth_completion.zsh` + `dot_config/bash/53_yth_completion.bash`
(Strategy B, mirror `_mlf`; `53` is the next free prefix).

**Install:** add `- name: yt-dlp` / `binary: yt-dlp` to
`dot_ansible/roles/python_uv_tools/defaults/main.yml`.

**Docs (per CLAUDE.md cross-file table):**
- `docs/this_repo/tool-managers.md` (+ `.zh-TW`): A–Z rows for `yt-dlp` and `yth`; uv-tool
  inventory table row for `yt-dlp`.
- `docs/zsh/zsh-completions.md` §F: table row for `yth`.
- `docs/shells/aliases.md`: `yth` `CLI (bin)` row.
- `dot_agents/skills/chezmoi-dotfiles/SKILL.md.tmpl`: one lean CLI bullet naming `yth` + `tv yth`.
- `CLAUDE.md`: new cross-file row (mnemonic mirror: launcher / `scripts/yth/*` /
  `cable/yth.toml` / future TUI) modeled on the `mlf` row.
- `docs/tools/yth.md` (+ `.zh-TW`) + `mkdocs.yml` nav: **nice-to-have** (note `mlf` ships no
  standalone page). If added, document the Arc/Zen cookie caveats (new territory for the repo)
  and run `uv run mkdocs build --strict` (mind known baseline warnings).

**Backlog/TODO:** `backlog/yth-semantic-search.md` (+ index row in `backlog/README.md`);
`TODO.md` `P?` row → `→ [research](backlog/yth-semantic-search.md)`. Backlog captures:
embedding provider TBD (Voyage / OpenAI / local fastembed), sqlite-vec vs lancedb, chunking,
plus Takeout `.html` parser and a possible `yth tui`.

---

## Phased implementation + verification (validate with the app, not just syntax)

1. **Skeleton + DB** — launcher, `__init__.py`, `search.py`, `list.py`, `show.py`.
   *Verify:* `yth -h` imports no `yt_dlp`; hand-seed 2–3 rows, `yth search foo` / `list --tsv`
   / `show <id>` work; confirm FTS trigger reindexes an UPDATEd title.
2. **Takeout import** — `import_takeout.py`.
   *Verify:* synthetic `watch-history.json` (one video watched twice, one removed-video row) →
   import → `video_stats.watch_count=2`, removed skipped → **re-import → counts unchanged**
   (idempotency).
3. **enrich + fetch-subs** (network, public) — `enrich.py`, `fetch_subs.py`, lazy `ytdl()`.
   *Verify:* `yth enrich --limit 1` on a public id fills description/duration and makes
   `search` match a description word; `yth fetch-subs <id>` → `yth search --subs <caption-word>`
   hits; eyeball `vtt_to_text` dedup.
4. **sync** (cookies) — `sync.py` + Zen auto-detect.
   *Verify:* with a logged-in Firefox/Zen profile or exported cookies.txt, `yth sync` adds ids,
   re-run dedupes via cursor. No cookie source on this host → state that explicitly in report.
5. **tv channel + open/copy/play** — `cable/yth.toml`, helpers.
   *Verify:* `tv list-channels | grep yth`; run the exact `[source]` + `[preview]` commands
   **standalone** (do NOT headless-launch the TUI — it crashes without a TTY); `yth open/copy/play`.
6. **Convention mirrors** — completions, ansible entry, docs, SKILL, CLAUDE.md row, backlog, TODO.
   *Verify:* `chezmoi apply` then `yth <TAB>` in both shells; `mkdocs build --strict` if docs page added.

**Deferred to backlog:** semantic/embedding subtitle search; Takeout `.html` parser;
materialized watch-stats trigger if `video_stats` view gets slow at 100k+ rows.
