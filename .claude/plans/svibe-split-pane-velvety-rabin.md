# svibe: width-aware layout + auto-default N (round 2)

## Context

**Round 1 (already shipped, commit `3b2c63e`)**: svibe's agent window no
longer always uses `tiled`. Hardcoded threshold: `N ≤ 3 → even-horizontal`,
`N ≥ 4 → tiled`. That matched the user's initial ask ("3 panes = 3 columns,
4 = grid") but is insensitive to terminal width — on a narrow terminal,
3 columns may already be unreadable; on a very wide terminal, 5 columns
would still be fine.

**Round 2 (code changes in place, this plan covers the commit step)**:
two enhancements asked for in the follow-up:

1. **Width-aware cutover**: replace the `N ≤ 3` constant with
   `N ≤ term_width / min_width`. A new `--min-width COLS` flag (env
   `SVIBE_MIN_WIDTH`, default 80) gates the behavior.
2. **Auto-default N**: when the user doesn't pass a pane count (neither
   positional `N` nor `--agents`), derive it from the current terminal:
   `N = clamp(term_width / min_width, 1, 12)`. Users who pass `svibe 4`
   or `svibe --agents a,b,c` keep explicit control.

A separate `L`-sized follow-up — **multi-window spillover** when agents
would fall below `min_width` even after falling back to tiled — was
captured in `backlog/svibe-multi-window-spillover.md` plus a TODO entry,
rather than built now.

## State of the working tree

Another agent's commits landed in parallel while this was in progress:

- `3e2fcbb` (tv/agent-sessions) incidentally picked up my TODO.md entry
  for the svibe-spillover backlog, so the TODO index is already up-to-date
  on main.
- `5b5e89e` (tmux prefix + M-x) is unrelated; no overlap.

Remaining uncommitted work for this round:

| File | Status | Change |
|------|--------|--------|
| `dot_config/zsh/tools/22_sesh.zsh` | modified, unstaged | adds `min_width` local, `--min-width` flag parsing + validation, `term_width` computation, auto-N in the positional branch, width-based layout cutover in the split loop, new --help paragraph + example |
| `docs/tools/sesh.md` | modified, unstaged | "Width-aware defaults" subsection with the knob table, updated layout description, updated examples (incl. `svibe --min-width 120`) |
| `backlog/svibe-multi-window-spillover.md` | untracked | long-form design notes for the deferred L-sized feature |
| `.specstory/history/2026-04-24_10-12-53Z-svibe-split-pane-grid.md` | modified, unstaged | this session's transcript (per `agent-history-hygiene` skill, commit alongside feature) |

Unrelated unstaged files (do **not** include in this commit): the older
`.specstory/history/2026-04-24_02-36-54Z-*.md` and
`.specstory/history/2026-04-24_09-41-49Z-*.md` transcripts,
`.specstory/statistics.json`, `docs/assets/copy-to-llm/copy-to-llm-custom.css`.

The index currently has unrelated staged content (tv-agent-sessions WIP
ancillaries that 3e2fcbb did not consume). The commit must use a
`-- <pathspec>` filter so only the four svibe files land in this commit.

## Commit step

1. **Drop the obsolete stash**: `git stash drop stash@{0}`. Its content
   (TODO.md deltas) was absorbed by 3e2fcbb; keeping it would mislead
   future stash-list scans.
2. **Stage the new backlog file**:
   `git add backlog/svibe-multi-window-spillover.md`.
3. **Commit with a pathspec filter** so the user's other staged WIP stays
   out. Message follows the existing `svibe: …` prefix style:

   ```
   svibe: width-aware layout + auto-default N (--min-width, SVIBE_MIN_WIDTH)

   Replace the N≤3 columns cutover that shipped last round with a
   width-aware rule: columns when all N panes fit at ≥min_width cols
   side-by-side, tiled grid otherwise. Min-width defaults to 80, tunable
   via `SVIBE_MIN_WIDTH` env or `--min-width COLS` flag.

   When neither positional N nor --agents is given, also auto-pick the
   count from the current terminal: N = clamp(term_width / min_width,
   1, 12). So `svibe` on a 240-col terminal with min-width 80 builds
   3 agent panes; at min-width 120, 2 panes.

   Multi-window spillover (>max_columns agents into agents-2/agents-3
   windows) is scoped but deferred — see
   backlog/svibe-multi-window-spillover.md + P?/L TODO entry.
   ```

   Pathspec: `dot_config/zsh/tools/22_sesh.zsh`, `docs/tools/sesh.md`,
   `backlog/svibe-multi-window-spillover.md`,
   `.specstory/history/2026-04-24_10-12-53Z-svibe-split-pane-grid.md`.

4. **Post-commit sanity**: `git status` to confirm the svibe files are
   gone from the unstaged set and the user's other WIP is untouched.

## Verification

Already run before re-entering plan mode (to re-confirm, rerun after
commit lands):

- `zsh -n dot_config/zsh/tools/22_sesh.zsh` → syntax OK
- `uv run mkdocs build --strict` → built in ~2s, only the tolerated
  anchor-drift INFO lines (tracked in
  `backlog/mkdocs-anchor-drift.md`), no new warnings

Behavior checks — to be run manually in a zsh shell after sourcing the
updated file (not part of the commit):

1. `source ~/.config/zsh/tools/22_sesh.zsh` to reload `sesh-vibe`.
2. `svibe --no-attach` on a 240-col terminal → expect 3 even-horizontal
   panes; `tmux list-panes -t 'vibe/chezmoi:agents' -F '#{pane_width}'`
   should show roughly 80-wide panes.
3. `svibe --no-attach --min-width 120` → expect 2 panes at ~120 each.
4. `svibe --no-attach 5` on the same 240-col terminal → explicit count >
   `max_columns=3` forces tiled grid (2+2+1 or similar).
5. `svibe --no-attach 1` → single pane, no `select-layout` call (loop
   body doesn't run).
6. `svibe -h | grep -E 'min-width|auto'` → help text mentions the flag +
   auto-N behavior.
7. `SVIBE_MIN_WIDTH=1 svibe --no-attach` → every terminal width produces
   `max_columns = term_width`, so auto-N hits the [1,12] clamp and layout
   stays even-horizontal.
8. `SVIBE_MIN_WIDTH=abc svibe --no-attach` → validation rejects with the
   expected error message.

Tear down after each test: `tmux kill-session -t 'vibe/chezmoi'`.

## Out of scope (for later rounds)

- Multi-window spillover (the L-sized follow-up captured in the backlog
  doc and P? TODO entry).
- A `--layout auto|columns|tiled` override flag. Interactive tmux layout
  cycling via `prefix + Space` covers the one-off "I want a different
  view" case; a CLI override is noise until someone actually asks for it.
- Dynamic re-layout on terminal resize. tmux handles proportional resize
  of existing panes; a full layout recompute on SIGWINCH is a different
  shape of feature.
