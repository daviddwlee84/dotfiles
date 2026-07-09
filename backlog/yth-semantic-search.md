# yth — semantic / embedding subtitle search

**Status**: P? deferred
**Effort**: L
**Related**: `TODO.md` · `dot_dotfiles/bin/executable_yth` · `scripts/yth/*.py` · `docs/tools/yth.md`

## Context

`yth` (shipped 2026-07) does keyword FTS5 search over title / channel /
description + fetched captions. The original ask also wanted **semantic** search
("好像看過某 video … 或 semantic 的查") — find a video by describing its content in
your own words, not by matching literal caption tokens. Deferred at plan time to
keep the MVP shippable; keyword + caption FTS already beats YouTube's native
history search.

## Investigation

Not started beyond a design sketch. The pieces:

- Transcripts are already stored (`subtitles.text`), so the corpus exists once
  `yth fetch-subs` has run over the history — no new fetching needed.
- Need: chunk transcripts → embed → store vectors → ANN query at search time,
  merged with / ranked against the existing FTS results.

## Options considered

| Axis | Option A | Option B | Option C |
|---|---|---|---|
| Embedding provider | Voyage AI (Anthropic's recommended; API key) | OpenAI `text-embedding-3` (API key) | local `fastembed` / sentence-transformers (no key, heavier install) |
| Vector store | `sqlite-vec` (same DB file, minimal dep) | `lancedb` (richer, separate store) | numpy brute-force (fine < ~50k chunks) |

Leaning: local `fastembed` + `sqlite-vec` to stay key-free and self-contained
(consistent with `yth` being a local-first tool), but that adds a chunky dep to
the PEP723 block. Cloud embeddings install lighter but need a key + network and
send transcripts off-box (privacy note). **Provider decision is open** — the user
deferred it.

## Current blocker / open questions

- Embedding provider not chosen (Voyage / OpenAI / local). Trade-off: privacy +
  no-key (local) vs install weight + quality.
- Chunking strategy (per-cue window vs fixed-token) and how to merge semantic
  ranks with FTS bm25 (hybrid score vs a separate `--semantic` mode).
- New `yth embed` subcommand + vector table + triggers, or a sidecar index?

## Decision (if any)

`2026-07 deferred` — ship keyword + caption FTS first; revisit once there's real
usage and a provider preference.

## Also deferred here (smaller)

- **Takeout `.html` parser** — `yth import-takeout` requires the JSON export; the
  HTML MyActivity variant is brittle + locale-dependent. Add only if someone has
  only the HTML export.
- **Materialized watch-stats** — `video_stats` is a VIEW; if it gets slow past
  ~100k watch_events, materialize via an `AFTER INSERT ON watch_events` trigger.
- **`yth tui`** — a Textual dashboard twin (like `mlf`'s). The `tv yth` channel
  covers the picker use-case; a multi-pane TUI is a nice-to-have. When built, its
  bare-letter keybindings must mirror the `tv yth` `o/b/y/p/s/j` mnemonics.

## References

- yt-dlp cookies (Arc/Zen caveats): `docs/tools/yth.md`
- Sibling local-first tool: `mlf` (`scripts/mlf/`), `tv mlflow`
