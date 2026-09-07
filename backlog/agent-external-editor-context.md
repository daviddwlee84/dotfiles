# Agent external-editor context and prompt composer

**Status**: P? — research captured 2026-09-07; not enabled or implemented
**Effort**: M for the Claude/Neovim spike; L if a multi-agent transcript viewer is needed
**Related**: `TODO.md` · `docs/tools/editor.md` · `docs/tools/pi-agents.md` · `backlog/tv-agent-sessions-richer-preview.md`

## Context

Writing a long reply in fullscreen Neovim hides the agent conversation being
referenced. The user proposed Claude Code's last-response context toggle, then
folding/dimming that context, with a tmux/Herdr transcript pane as a larger option.
Evaluate side effects and comparable Codex CLI, OpenCode and Pi practices before
changing the managed editor workflow.

This is the single implementation research note. Windows has a TODO pointer only.
The cross-platform decision is in `daviddwlee84/dotfiles-all`,
`docs/agent-external-editor-context.md`. These names remain useful in standalone
clones; the superproject checks out this repository as `dotfiles-unix/`.

## Investigation

### Claude: verified feature, but the supplied explanation needs updating

- [Interactive-mode documentation](https://code.claude.com/docs/en/interactive-mode#general-controls)
  documents **Ctrl+G** / **Ctrl+X Ctrl+E**, and `/config` → **Show last response in
  external editor**. It prepends the previous reply as commented reference and
  removes that block on return from the editor.
- [v2.1.110](https://github.com/anthropics/claude-code/releases/tag/v2.1.110)
  introduced the option; GitHub reports publication at **2026-04-15 22:07 UTC**
  (April 16 in UTC+8). The supplied release/version claim is supported.
- Crucial correction: [v2.1.129](https://github.com/anthropics/claude-code/releases/tag/v2.1.129),
  published **2026-05-06 UTC**, records a fix for external-editor handoff blanking
  conversation history above the prompt. Do not assume every current GUI-editor
  workflow still blanks the conversation. Retest the installed version, terminal
  and rendering mode. Retained pixels do not prove that the paused TUI can scroll.
- [#20045](https://github.com/anthropics/claude-code/issues/20045) was **open** when
  checked; [#36516](https://github.com/anthropics/claude-code/issues/36516) was
  **closed as duplicate**, not resolved by its own fix. Issue status alone does
  not establish current behavior.
- [Settings documentation](https://code.claude.com/docs/en/settings) distinguishes
  `settings.json` from Claude-owned `~/.claude.json`, which stores global `/config`
  preferences alongside other runtime state. Do not blindly add
  `externalEditorContext` to `dot_claude/modify_settings.json.tmpl`, and never
  version or replace the whole runtime file. First adoption should use `/config`.

### Version-specific local evidence: Claude 2.1.261

Read-only inspection of the installed executable's bundled editor helper found:

- `externalEditorContext` defaults to false. Targeted reads found the key unset
  in this host's default `~/.claude.json` and `~/.claude/settings.json`; no settings
  were changed. Alternate config roots/running-session overrides were not tested.
- Reference text is capped to the **last 50 lines**, with a truncation notice.
  The first part of a long answer can therefore be missing even before folding.
- A literal generated separator containing **Write your reply below this line**
  marks the boundary. The helper finds its first occurrence and returns the text
  after it. It does **not** remove all lines matching `^#`.
- Consequently, a `# Heading` or shell comment **below** the separator survives;
  anything typed **above** it is discarded. If the separator is missing/altered,
  the helper returns the editor content without removing the reference block.
  If reference content itself contains the exact separator, the first-match rule
  deserves a synthetic regression case.
- These are implementation observations for **2.1.261**, not a stable public
  serialization contract. No real conversation was sent and no interactive
  editor handoff was exercised in this research session.

### Comparable practices

| Agent | Native prompt editing | Reference workflow and limits |
|---|---|---|
| Claude Code | Ctrl+G / Ctrl+X Ctrl+E; optional last-response context | Closest native match. Context removal is Claude-specific; local 2.1.261 limits it to 50 lines. |
| Codex CLI | Ctrl+G; `VISUAL`, falling back to `EDITOR`; save/exit returns text to the composer before sending | Official docs establish prompt editing and `/copy` for the latest completed output. They do not establish a Claude-equivalent context toggle or comment stripping. Use a separate reference buffer/file unless a version-specific adapter is verified. This comparison is about CLI, not the Codex desktop composer. |
| OpenCode TUI | `/editor`, default Ctrl+X then **E** (`<leader>e`); current source prefers `VISUAL` over `EDITOR` | `/export`, default Ctrl+X then **X**, opens a Markdown conversation export in the editor. Export is a reference/document workflow, not an editable prompt with ignored history. Current prompt source passes the draft, expands text paste placeholders and retains non-text parts separately. |
| Pi coding agent | Ctrl+G; current `externalEditor` setting overrides `VISUAL` → `EDITOR`; Notepad/nano fallback | Current helper edits only the expanded draft. `/copy` copies the last assistant message; `/export` writes HTML or JSONL. Extensions can read the current branch and provide custom UI, making a local reference/composer extension feasible. That is a proposed extension, not an existing native last-response toggle. |

Sources checked 2026-09-07:

- Codex: [prompt editor](https://learn.chatgpt.com/docs/cli-customization#prompt-editor)
  and [commands](https://developers.openai.com/codex/cli/slash-commands).
  Local installation resolves to Codex **0.153.4**; no local Rust source was
  available in the managed dotfiles, so behavior claims use official docs.
- OpenCode: [TUI documentation source](https://github.com/anomalyco/opencode/blob/57ef3828431790c53f8f333c7ffbfe88770a1812/packages/web/src/content/docs/tui.mdx),
  [editor helper](https://github.com/anomalyco/opencode/blob/57ef3828431790c53f8f333c7ffbfe88770a1812/packages/tui/src/editor.ts),
  [prompt integration](https://github.com/anomalyco/opencode/blob/57ef3828431790c53f8f333c7ffbfe88770a1812/packages/tui/src/component/prompt/index.tsx),
  [export integration](https://github.com/anomalyco/opencode/blob/57ef3828431790c53f8f333c7ffbfe88770a1812/packages/tui/src/routes/session/index.tsx).
  The documentation mentions `EDITOR`; the inspected source additionally prefers
  `VISUAL`. Its helper suspends the renderer; GUI-editor visibility/scrolling is
  not guaranteed. These are upstream dev-branch observations, not a local TUI test.
- Pi: [README](https://github.com/earendil-works/pi/blob/aa23e784c647d713e775a8adcaf3c219e84f5068/packages/coding-agent/README.md),
  [settings](https://github.com/earendil-works/pi/blob/aa23e784c647d713e775a8adcaf3c219e84f5068/packages/coding-agent/docs/settings.md),
  [editor helper](https://github.com/earendil-works/pi/blob/aa23e784c647d713e775a8adcaf3c219e84f5068/packages/coding-agent/src/modes/interactive/external-editor.ts),
  [interactive integration](https://github.com/earendil-works/pi/blob/aa23e784c647d713e775a8adcaf3c219e84f5068/packages/coding-agent/src/modes/interactive/interactive-mode.ts),
  [extensions](https://github.com/earendil-works/pi/blob/aa23e784c647d713e775a8adcaf3c219e84f5068/packages/coding-agent/docs/extensions.md).
  Local package: `@earendil-works/pi-coding-agent` **0.84.4**. The upstream helper
  stops/restarts the TUI around the editor. `ctx.sessionManager.getBranch()` plus
  `ctx.ui.custom()` / `ctx.ui.setEditorText()` is a plausible extension route;
  use branch identity rather than concatenating every session entry.

### Existing repo surfaces to reuse

- `dot_config/nvim/lua/config/autocmds.lua` already detects quick-edit buffers,
  disables diagnostics and format-on-save, and supports `NVIM_QUICK_EDIT`.
  It deliberately leaves LSP/plugins running. It does not implement reference
  folding, context-boundary protection or comprehensive scratch-data cleanup.
- `dot_dotfiles/bin/executable_dotfiles-editor` and `editorcfg` already resolve
  editor choice per invocation, preserve arguments/cwd, wait for completion and
  return exit status. Both `EDITOR` and `VISUAL` point to the same launcher.
- `dot_config/television/executable_agent-sessions.py` already renders Claude,
  Codex and OpenCode transcripts, preferring SpecStory then native stores.
  Reuse that knowledge after checking format freshness; it is not proof that
  the exact session belonging to a Ctrl+G invocation can be identified.
- `backlog/specstory-detached-transcript-capture.md` records resident-wrapper
  memory costs. Do not introduce another continuous transcript watcher casually.
- Pi combo/extension ownership is in the separate `daviddwlee84/pi-agents` repo
  (`docs/tools/pi-agents.md`); its deployed checkout is not an authoring workspace.
  This backlog compares Pi, but does not authorize editing that external repo or
  assume Oh My Pi has identical APIs.

## Side effects and mitigations

| Risk | Evaluation / mitigation |
|---|---|
| Lost reply or reference accidentally submitted | Preserve the exact Claude separator and keep the prompt below it. Folding/dimming must be display-only. Do not implement a generic `^#` deletion rule. Other agents can submit copied comments as ordinary prompt text. |
| False sense of read-only protection | A fold or dim highlight is still editable. Prefer a separate nonmodifiable reference buffer for a stronger boundary; preserve the actual prompt file. Initial cursor movement must target the verified prompt start, not simply the first non-comment line. |
| Local copies of conversation data | Adding context puts more conversation text into temporary files. Swap, persistent undo, backups, ShaDa/register history, clipboard managers, editor plugins or GUI recovery can retain it after the agent deletes its temp file. Assess buffer-local suppression/cleanup and existing plugin behavior; avoid blanket global editor changes. No new model tokens should result from an intact stripped reference block, but local retention is a separate issue. |
| Autoformat or plugin interference | Existing quick-edit disables autoformat, which helps preserve the separator. Do not enable format-on-save for this filetype. LSP and other plugins remain active; language highlighting does not establish a confidentiality boundary. |
| Incomplete/misleading history | Last-response context is not full history; local Claude truncates it. Snapshot time, agent and session/branch ID must be visible. Never select another pane's session using only newest-file mtime, and never label terminal scrollback as a complete transcript. |
| GUI/multiplexer handoff | Preserve wait/exit behavior, including cancellation and nonzero exit. GUI editors need their wait option. A split alone does not keep a paused TUI interactive. Test resizing, SSH, nested multiplexers and Windows ConPTY; Ctrl+G also collides with this repo's Zellij unlock key. |
| Wider editor regressions | The shared launcher also serves Git, crontab and other editors. Do not add agent-specific context to every invocation or identify Claude solely by `/tmp` or `.md`. An explicit caller marker or verified format is needed. |
| Maintenance and performance | Structured session formats, paste/image placeholders, forks and compaction vary by agent/version. Prefer on-demand bounded exports; avoid re-reading an unbounded JSONL on every keypress. `Pi /share` uploads a gist and is unnecessary for local reference. |

## Options considered

| Option | Benefit | Cost / limitation |
|---|---|---|
| A. Claude native toggle only | Smallest experiment; no custom parser | Last response only; local 50-line limit and editable boundary |
| B. A + buffer-local Neovim display improvements | Dim/fold reference, move cursor to prompt; keeps existing editor choice | M: needs reliable identification, boundary fixtures and version-change fallback |
| C. Separate reference export/buffer + existing editor | Can handle full history and agents without native context | Must bind the exact session and keep exported history outside submitted prompt |
| D. tmux/Herdr transcript pane + blocking editor wrapper | Full side-by-side workflow | L: pane lifecycle, session identity, refresh, cancellation and OS capability gaps |
| E. Pi extension composer | Native access to active branch and custom UI | Separate ownership/API lifecycle; does not automatically transfer to other agents |

## Decision and resume plan

**2026-09-07: capture only.** Start with A, then B if desired. Retest current
Claude GUI handoff before committing to D. Use C for occasional full-history
reference; reserve D/E for a demonstrated recurring need. No settings, keymaps,
dependencies, live sessions or external repositories were changed in this task.

Acceptance checks for a later spike:

1. Capture synthetic input/output for the installed agent version: ordinary
   reply, empty draft, long response, CRLF, CJK, `#` headings, shell comments,
   separator text occurring in reference, damaged/missing separator, paste and
   image placeholders. Verify both context removal and exact intended prompt.
2. Display-only folding/dimming changes no file bytes. Test cursor placement,
   `zo`/`zc`, cancel/nonzero editor exit and no-save exit. Unknown formats fall
   back to the ordinary editor rather than guessing where to delete text.
3. Audit temp/recovery artifacts with synthetic text and inspect whether any
   buffer-local persistence restrictions actually prevent additional copies.
4. Compare terminal Neovim and a GUI wait editor on the real host: conversation
   pixels retained versus interactive scrolling, inline/fullscreen rendering,
   tmux/Herdr/SSH, and a real Windows ConPTY host for parity.
5. If transcript integration is still needed, require exact session/branch
   selection, clear truncation/staleness labels and no automatic submission or
   cloud upload. Reuse the existing renderer where compatible.
6. Before shipping, update the affected platform user docs bilingually and
   native tests. Keep the cross-platform decision current, promote the TODO via
   the harness, and mark this research shipped only for the scope actually done.

## Open questions

- Whether the current native toggle alone is enough for this user's typical
  replies; whether the 50-line cap is significant in practice.
- Whether a future supported settings surface can manage this preference without
  taking ownership of Claude's runtime state.
- Which reliable caller/session signal a shared editor invocation can receive.
- Whether current GUI handoff preserves the desired scroll interaction on the
  user's exact terminal and Claude rendering mode; upstream release notes do
  not substitute for that test.
