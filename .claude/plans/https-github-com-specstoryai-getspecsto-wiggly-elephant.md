# Plan: Richer `tv agent-sessions` + SpecStory mapping docs

## Context

The `tv agent-sessions` Television channel (`dot_config/television/cable/agent-sessions.toml` + helper `dot_config/television/executable_agent-sessions.py`) already aggregates OpenCode / Claude Code / Codex / Cursor-CLI / Cursor-IDE sessions into one searchable TUI. Three user-reported gaps:

1. **Preview shows only "first 5 user messages"** — useful for search, but not for reading back a session. The user wants a full back-and-forth transcript (with markdown rendering where available).
2. **No link to `.specstory/history/*.md`** — when the user wants to reference a past session to another agent, they currently have to eyeball-match by timestamp + title. We have an unambiguous handle (session id) but it's not exposed.
3. **`all` mode results look randomly ordered** — confirmed: each per-agent handler sorts internally by mtime DESC, but the `all` mode concatenates the five blocks without a global merge-sort. So TV sees OpenCode-block → Claude-block → … each internally sorted, overall not.

Research finding (Explore agent on SpecStory CLI at `specstoryai/getspecstory`, Go): the `.specstory/history/*.md` file emitted per session embeds an HTML comment on line 5 of the form `<!-- Claude Code Session <uuid> (YYYY-MM-DD HH:MM:SSZ) -->` (or `<!-- cursoride Session <uuid> ... -->`, `<!-- Codex Session <uuid> ... -->`, etc.). The session UUID here is exactly the same id we already put in TSV column 2. So session → SpecStory markdown mapping is a one-liner grep — no need to replicate SpecStory's slug algorithm. (We'll still document the algorithm for future reference, since no CLI subcommand exposes the mapping either.)

## Deliverables (committed this round)

### 1. New doc: `docs/tools/specstory.md`

What SpecStory is, how the filename is derived (so the doc survives CLI bitrot), and — crucially — the grep-based reverse-lookup recipe we rely on. Sections:

- **What it is** — Go CLI from `specstoryai/getspecstory`, watches coding-agent session stores and materializes transcripts to `.specstory/history/*.md`.
- **Filename algorithm** — `YYYY-MM-DD_HH-MM-SS[Z|±HHMM]-<slug>.md`; timestamp = first JSONL record's `CreatedAt` (UTC default, `--local-time-zone` for `+0800`); slug = first 4 words of first real (non-synthetic) user message, lowercased, XML-tag-stripped, punctuation-stripped, hyphen-joined. No session id in filename. Point to `pkg/session/session.go` (FormatFilenameTimestamp, BuildSessionFilePath) and `pkg/spi/path_utils.go` (GenerateFilenameFromUserMessage).
- **Reverse-lookup recipe** — session id → `.specstory/history/*.md`: `grep -l "Session ${sid}" .specstory/history/*.md`. Works for all providers because the HTML comment is uniform.
- **Markdown structure** — H1 timestamp, provider comment, `_**User (ts)**_` / `_**Agent (model ts)**_` blocks separated by `---`, thinking in `<think><details>`, tool use in `<tool-use ...><details>`. Useful if we ever want to re-render.
- **CLI surface** — only `sync` / `list`; no `resolve <sid>` / `path <sid>` subcommand. That's why we grep.
- **Caveats** — historical files keep old format (e.g. `+0800` vs `Z`; with/without seconds). Format collisions (same second + same first-4-words) are undocumented — last write wins.

Add nav entry to `mkdocs.yml` under the existing **Tools** section (alphabetical). Run `uv run mkdocs build --strict` to verify.

### 2. New backlog entry: `backlog/tv-agent-sessions-richer-preview.md`

Full improvement landscape with status per item — so items that DON'T ship this round (Cursor transcript rendering, custom TUI fallback) are tracked. Follow `backlog/README.md` template (Status/Effort → Context → Investigation → Options → Open questions). Sections:

- **Shipping this round** (below, item 3–7) — status `[in-progress]`.
- **Deferred**:
  - Full transcript for Cursor Agent CLI (`[cu]`) — requires iterating all BLOBs, best-effort JSON decode, role-guessing. Fragile; defer until user actually browses Cursor Agent sessions often.
  - Full transcript for Cursor IDE composers (`[ci]`) — two-table join via `composerData:<sid>` + `bubbleId:<sid>:<bid>`; structurally clean but verbose. Medium effort, low current demand.
  - Self-built TUI — only if TV hits a wall (e.g. needs custom layout TV can't express). Current finding: TV preview scrolls and has generous size; no wall yet.

Also add one-line entry to `TODO.md` pointing at the backlog file (per `project-knowledge-harness` convention).

### 3. Helper fix: global sort in `all` mode

File: `dot_config/television/executable_agent-sessions.py`.

Today each per-agent handler sorts rows internally, then prints. `all` mode calls each handler in sequence, so rows are per-agent-sorted, not globally sorted. Fix by having `all` collect rows from all five handlers into one list, sort once by column `when` (or the raw epoch used before formatting — whichever is cheaper), then print.

Scope: ~5–10 lines. Preserve per-agent single-mode behaviour (they still sort locally; no change).

### 4. Helper: new TSV column `specstory_path`

Add a 6th column (index 5) to the TSV emitted by the helper: absolute path to the matched `.specstory/history/*.md`, or empty string if no match.

Implementation: once per helper invocation, shell `grep -lR "Session " ~/.local/share/chezmoi/.specstory/history/*.md` (or Python walk — benchmark, prefer whichever is faster for ~300 files) and build a `{sid: path}` dict. Cheap — O(number_of_md_files × avg_file_size); we only need to read the first ~10 lines of each to find the HTML comment, so use a bounded read. Fallback to empty string on miss.

Resolve the history directory path robustly: prefer `$CHEZMOI_SOURCE_DIR/.specstory/history` if set, else `~/.local/share/chezmoi/.specstory/history`, else skip column (don't crash for users who don't have chezmoi / SpecStory).

TOML `[source].display` / `output` stay the same (they reference columns 0–4 by index; column 5 is new, used by preview + actions only).

### 5. Helper: full transcript renderer

Add a `--transcript <agent> <sid>` mode to the helper (or a second script; prefer same file to keep deployment simple — single `modify_` target). Emits a markdown transcript mimicking SpecStory's format (H2 role headers, `---` separators, code fences for tool IO).

Per-agent implementation — all three easy sources ship this round:

- **Claude Code** (`[cc]`) — walk `~/.claude/projects/**/<sid>.jsonl` line by line, filter `type in {user, assistant}`, extract `message.content` (string or list of `{type:text,text}`). Skip tool-use lines by default (config knob later).
- **Codex** (`[cx]`) — walk `~/.codex/sessions/**/rollout-*<sid>*.jsonl`, filter `type==response_item` + `payload.type==message`, extract by role.
- **OpenCode** (`[oc]`) — SQL: `SELECT m.role, json_extract(p.data,'$.text') FROM part p JOIN message m ON p.message_id=m.id WHERE p.session_id=? ORDER BY p.time_created ASC` (extend the existing "first 5" query in the TOML preview block — same SQL, drop the `LIMIT 5` + role-text filter).

**Deferred** (document in backlog): Cursor Agent (`[cu]`) and Cursor IDE (`[ci]`) full-transcript rendering. Current preview's "first 5" logic for these stays in the legacy preview cycle (see item 6) so the Cursor channels don't regress.

### 6. TOML: preview cycle reordered (3 stages, new transcript first)

File: `dot_config/television/cable/agent-sessions.toml`, `[preview].command`.

New order (Ctrl+F cycles through these):

1. **Metadata + full transcript** (NEW; position 1, default on open):
   - Top: session id, when, cwd, **SpecStory path** (column 5, if present — clickable/copyable via keybinding), agent-specific metadata (model, version, title).
   - Then: a `---` separator.
   - Then: full transcript via `helper --transcript <agent> <sid>` piped through `glow --style auto -` **if `glow` is available**, else `bat -l md --color=always --plain --paging=never` (already in `requirements`). Probe with `command -v glow`.
   - Cursor `[cu]` / `[ci]` in position 1 keep the current "first 5 messages" rendering (transcript renderer not implemented for them yet) — labelled "(transcript rendering deferred; showing first 5)" so the user knows it's not a bug.

2. **Legacy: metadata + first 5 user messages** (position 2; what used to be preview 1). Unchanged. Kept for fast session-finding by content search.

3. **Raw dump** (position 3; what used to be preview 2). Unchanged.

Add `glow` to `[metadata].requirements` as optional (or leave it — TV doesn't enforce, bat fallback handles absence). If glow isn't in the Ansible devtools role, add a follow-up backlog line (don't block this round).

### 7. TOML: new keybinding `Alt+S` — copy SpecStory MD path to clipboard

New `[actions.copy_specstory]` mirroring the existing `copy_dir` pattern (`pbcopy` / `wl-copy` / `xclip` / OSC52 fallback). Source column 5 (`{split:\t:5}`). If empty, print "(no .specstory match for this session)" and beep (or just no-op).

Add `alt-s = "actions:copy_specstory"` under `[keybindings]`. Update the header-block comment in the TOML to mention the new key.

`Alt+E` (edit_jsonl) action: extend to open the matched `.specstory/history/*.md` in `$EDITOR` for `[cc]`/`[cx]`/`[oc]` when the raw JSONL lookup fails AND a specstory match exists — low-cost UX polish. Skip if it complicates logic.

## Deferred (backlog only, not this round)

- Cursor Agent CLI full transcript rendering (BLOB decode, flaky).
- Cursor IDE composer full transcript rendering (two-table join, medium effort).
- Self-built TUI — evaluate only if TV hits an actual constraint.
- Add `glow` to ansible `devtools` role (noted in backlog; not blocking — fallback to `bat` works).

## Critical files

| Action | Path |
|---|---|
| NEW | `docs/tools/specstory.md` |
| NEW | `backlog/tv-agent-sessions-richer-preview.md` |
| EDIT | `mkdocs.yml` (nav Tools section) |
| EDIT | `TODO.md` (one-line backlog pointer) |
| EDIT | `dot_config/television/executable_agent-sessions.py` (global sort + specstory column + `--transcript` mode) |
| EDIT | `dot_config/television/cable/agent-sessions.toml` (3-stage preview cycle + `copy_specstory` action + `alt-s` keybinding + header comment) |

## Existing utilities to reuse

- **Per-agent dispatch pattern** in `agent-sessions.py` — keep shape, add `transcript_<agent>()` parallel to existing `rows_<agent>()` / `preview_<agent>()`.
- **HTML-comment reverse-lookup** — one-line grep against `.specstory/history/*.md`; no new deps.
- **SQL in current TOML preview block** (lines 73–82 of `agent-sessions.toml`) — reuse for OpenCode transcript, drop `LIMIT 5`.
- **Clipboard fallback chain** (pbcopy / wl-copy / xclip / OSC52) — `[actions.copy_dir]` / `[actions.copy_id]` are correct reference implementations (`dot_config/television/cable/agent-sessions.toml:357–381`).
- **`bat` as markdown renderer** — already in `requirements`. Add `glow` as probed-optional.

## Verification

1. `uv run mkdocs build --strict` — docs site builds without new broken links.
2. Re-run `tv agent-sessions` after `chezmoi apply` (helper lives at a `modify_`-prefixed path? No — it's `executable_agent-sessions.py`, plain deploy; `chezmoi apply` will refresh `~/.config/television/agent-sessions.py`).
3. Default view: rows from all 5 agents interleaved by mtime DESC (sanity-check: top 10 rows should be mixed agent tags, not all `[oc]` first then all `[cc]`).
4. Pick a recent Claude session (`ls -t ~/.claude/projects/*/*.jsonl | head -1`, strip `.jsonl`), search for it in TV, confirm preview 1 shows the `.specstory/history/*.md` path in the header block.
5. `Ctrl+F` cycles: new-transcript → legacy-first-5 → raw-dump. Glow renders if present; `bat` fallback otherwise.
6. Full transcript: scroll PageDown through a ~100-turn session; content should scroll cleanly inside the preview pane (TV's `[ui.preview_panel].size = 60` gives plenty of room).
7. `Alt+S` — copies the absolute `.specstory/history/*.md` path; paste elsewhere to confirm.
8. Cursor sessions (`[cu]`/`[ci]`) — preview 1 shows first-5 messages with the "(transcript rendering deferred)" label. No regression.
9. `chezmoi diff` — only the intended files changed.

## Open questions (documented, no blocker)

- Whether to include tool-use blocks in the transcript render (probably yes for Claude, collapsed `<details>` — but deferred as a follow-up config knob; ship text-only first).
- Whether to also render SpecStory's own `.md` file directly when present, instead of re-rendering from raw source. Pros: zero parsing work, matches what the user already sees on disk. Cons: only available for sessions SpecStory has flushed; live in-progress sessions aren't in `.specstory/` yet. Current plan: render from raw source so live sessions work too, and show the SpecStory path as a reference. Revisit if rendering quality diverges.
