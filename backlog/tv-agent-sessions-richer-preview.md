# `tv agent-sessions`: richer preview + `.specstory/history/*.md` linkage

**Status**: P1 in-progress (2026-04; landing this round) — Cursor transcripts deferred
**Effort**: M for the first batch; Cursor transcripts each another M
**Related**: `dot_config/television/cable/agent-sessions.toml`, `dot_config/television/executable_agent-sessions.py`, [docs/tools/specstory-internals.md](../docs/tools/specstory-internals.md)

## Context

The `tv agent-sessions` channel aggregates OpenCode / Claude Code / Codex / Cursor-CLI / Cursor-IDE sessions into one `tv` picker with fuzzy search, resume-in-terminal, clipboard copy-by-ID/path. Three gaps the user flagged 2026-04-24:

1. **Preview shows only "first 5 user messages"** — good for finding a session by text, useless for reading it back. Want the full back-and-forth transcript.
2. **No link to the corresponding `.specstory/history/*.md`** — user often wants to reference a prior session to another coding agent, currently has to eyeball-match by timestamp + title.
3. **`all` mode ordering looks random** — confirmed: each per-agent handler sorts internally by mtime DESC, but the `all` mode concatenates the five blocks without a global merge. So TV sees OpenCode-block → Claude-block → …, each internally sorted, overall not. The emitted TSV column 1 (`when`) has the right data for a global sort — we just weren't doing the merge.

## Investigation

**SpecStory reverse-lookup is grep-able.** Every `.specstory/history/*.md` file embeds `<!-- <Provider> Session <uuid> ... -->` on line 5, and the UUID is the same session id the agent uses for its `--resume` flag. Full derivation, caveats, CLI surface in [docs/tools/specstory-internals.md](../docs/tools/specstory-internals.md) — confirmed against DeepWiki (<https://deepwiki.com/specstoryai/getspecstory>) for the architecture and against the actual files in this repo's `.specstory/history/` for the format.

**Per-agent transcript-render feasibility** (from probing real session stores):

| Agent | Source | Difficulty | Notes |
|---|---|---|---|
| Claude Code (`[cc]`) | `~/.claude/projects/<flat>/<sid>.jsonl`, one JSON object per line | Easy | Filter `type ∈ {user, assistant}`; content is `str` or `list[{type:text, text}]`. Existing `first 5` path already walks this. |
| Codex (`[cx]`) | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | Easy | Filter `type == response_item` + `payload.type == message`; nested but regular. |
| OpenCode (`[oc]`) | `~/.local/share/opencode/opencode.db` (SQLite) | Medium | SQL join on `message` + `part`; existing preview block already has the SQL skeleton, just needs `LIMIT 5` dropped. |
| Cursor Agent CLI (`[cu]`) | `~/.cursor/chats/<wsHash>/<chatId>/store.db` (blobs) | **Painful** | Blobs are binary JSON with no role index; current `first 5` code iterates every blob and guesses role. Full transcript would need the same, with higher error rate over longer sessions. |
| Cursor IDE composer (`[ci]`) | `globalStorage/state.vscdb` `cursorDiskKV` table (`composerData:<id>` + `bubbleId:<id>:<bid>`) | Medium | Structured, but two-table lookup and a verbose schema. |

**TV preview supports scrolling** (`pageup` / `pagedown` for half-page), preview panel sized at 60 rows via the channel's `[ui.preview_panel]`. A multi-hundred-turn transcript fits fine — no need for a self-built TUI yet.

**Pitfall avoided** — [pitfalls/tv-channel-bare-braces-break-substitution.md](../pitfalls/tv-channel-bare-braces-break-substitution.md) warns that any bare `{...}` in the channel TOML's `command` strings silently breaks ALL `{split:\t:N}` placeholders. Mitigation: keep the rendering code in the Python helper; the TOML just shells out to it.

## Shipping this round (2026-04)

| # | Change | File(s) |
|---|---|---|
| A | **Helper: global mtime DESC sort in `all` mode.** Handlers emit into a shared buffer instead of printing directly; main() sorts + prints once. Single-mode behaviour unchanged (each already sorts locally). | `dot_config/television/executable_agent-sessions.py` |
| B | **Helper: new TSV column 5 = `specstory_path`.** Single scan of `~/.local/share/chezmoi/.specstory/history/*.md` on startup, reads the first ~10 lines per file to extract the `<!-- ... Session <uuid> ... -->` UUID, builds `{sid → path}` cache. Column is empty string when no match. | `dot_config/television/executable_agent-sessions.py` |
| C | **Helper: `transcript <cc\|cx\|oc> <sid>` subcommand.** Writes markdown to stdout. Prefers the pre-rendered `.specstory/history/*.md` when available (zero-parsing, matches what user sees on disk); falls back to raw-source rendering for live / un-synced sessions. | `dot_config/television/executable_agent-sessions.py` |
| D | **TOML: 3-stage preview cycle.** Preview 1 (new, default on open) = metadata header + specstory path + full transcript via `glow --style auto -` (falls back to `bat -l md` if glow is missing). Preview 2 = legacy first-5 user messages (unchanged). Preview 3 = raw dump (unchanged). | `dot_config/television/cable/agent-sessions.toml` |
| E | **TOML: `Alt+S` → copy SpecStory MD path to clipboard.** New `[actions.copy_specstory]` mirroring `[actions.copy_dir]` (pbcopy / wl-copy / xclip / OSC52). Quietly no-ops on empty column. | `dot_config/television/cable/agent-sessions.toml` |
| F | **Docs split.** Moved filename-algorithm + reverse-lookup + markdown-structure deep dive from `docs/tools/specstory.md` (which is user-facing install/config) into new `docs/tools/specstory-internals.md`. Nav entry added to `mkdocs.yml`. | `docs/tools/specstory-internals.md`, `docs/tools/specstory.md`, `mkdocs.yml` |

## Deferred (tracked here, not in this batch)

| # | Change | Why deferred |
|---|---|---|
| G | **Cursor Agent CLI (`[cu]`) full transcript** | Painful — blob decode + role guessing. Current `first 5` implementation already best-effort; full transcript amplifies the fragility. Defer until user actually browses Cursor Agent sessions often. |
| H | **Cursor IDE composer (`[ci]`) full transcript** | Two-table join across `composerData` + `bubbleId:*` is straightforward but verbose (~50 lines). Low current demand (user works mostly in Cursor CLI / Claude). |
| I | **Custom TUI fallback** | TV's preview scroll + 60-row panel covers the need. Re-open only if we hit a real TV constraint. |
| J | **Add `glow` to the `devtools` ansible role** | Currently installed on the user's macOS box via homebrew directly; `bat` fallback in the preview command means glow absence doesn't break anything. Add to ansible when a fleet host complains. |
| K | **Tool-use blocks in the transcript** | Current Claude-side renderer inlines a one-line summary (`> *tool_use: <name>*`). Full collapsible rendering (à la SpecStory's `<tool-use>` / `<details>`) would bring the live transcript to parity with SpecStory's output — but the SpecStory-first path already handles this when the session has been synced, so the deferred renderer is only a last-resort. Trade-off: polish vs complexity in the helper. |

## Options considered

### Rendering strategy for preview 1

| Option | Pros | Cons |
|---|---|---|
| A. Always re-render from raw source | Works for live / un-synced sessions | Duplicates SpecStory's rendering logic; diverges from what the user sees on disk |
| B. Always cat the `.specstory/history/*.md` | Zero parsing; pixel-perfect match with disk artefact; supports all providers uniformly (including ones we can't render well, like Cursor Agent) | Only works after SpecStory flushes — live / in-progress sessions have no file yet |
| C. **Prefer B, fall back to A** (chosen) | Best of both; "is this the session I want" works for finished sessions, "what's happening right now" works for live ones | Helper has two code paths to maintain |

### Sort strategy for `all` mode

| Option | Pros | Cons |
|---|---|---|
| A. Sort in TV | Helper stays simple | TV's config has no `sort_by` knob; would need string-pipeline ordering tricks. Fragile. |
| B. **Helper buffer + single global sort** (chosen) | One-liner refactor; uses the raw mtime floats each handler already computes; deterministic | Handlers no longer "stream" output for the merged case (acceptable — total row count is ~hundreds) |
| C. Per-agent sub-channels only, drop `all` | Simplest | Defeats the aggregation value |

### Reverse-lookup map

| Option | Pros | Cons |
|---|---|---|
| A. Replicate SpecStory's slug algorithm, derive filename from (ts, first-user-msg) | No grep; fast | Drifts with SpecStory versions; breaks on historical files with old formats |
| B. **Grep `<!-- ... Session <uuid> ... -->` on helper startup** (chosen) | Version-agnostic; works across all providers with one regex | O(num\_md\_files) startup cost — bounded (~300 files × ~10 lines each = negligible) |
| C. Shell out to a future SpecStory subcommand | Zero logic on our end | Subcommand doesn't exist; `specstory list` / `sync` / `watch` don't expose path |

## Open questions

- **Should the transcript include tool-use blocks?** Claude JSONL has them, SpecStory renders them collapsed. Our Python fallback currently emits a one-line summary (`> *tool_use: Bash*`). Expand later if the fallback path becomes the dominant one.
- **Does the `.specstory/history/` lookup dir need to be configurable?** Hard-coded to `~/.local/share/chezmoi/.specstory/history` today. If the user starts using SpecStory in other repos often, promote to `SPECSTORY_HISTORY_DIRS` env var (colon-separated, multi-dir scan).

## Decision

`2026-04-24 chose option C (SpecStory-first → raw-source fallback) + option B (helper buffer sort) + option B (grep-based reverse lookup)`. Cursor transcripts deferred pending demand.

## References

- [docs/tools/specstory-internals.md](../docs/tools/specstory-internals.md)
- [pitfalls/tv-channel-bare-braces-break-substitution.md](../pitfalls/tv-channel-bare-braces-break-substitution.md)
- <https://deepwiki.com/specstoryai/getspecstory>
- User ask that triggered this: .specstory history file `2026-04-24_09-09-09Z-commit-commit-backup-e.md` + the session-resume flow in `dot_config/television/cable/agent-sessions.toml`
