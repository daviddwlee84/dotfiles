# `svibe`: multi-window spillover when panes would fall below min-width

**Status**: P? — design-only, no implementation yet
**Effort**: L (multi-window topology + on-exit routing + focus rules)
**Related**: `dot_config/zsh/tools/22_sesh.zsh` (`sesh-vibe`), [docs/tools/sesh.md](../docs/tools/sesh.md) → `svibe`

## Context

Width-aware single-window layout landed 2026-04: svibe now auto-picks `N`
and chooses `even-horizontal` vs `tiled` based on `term_width / min_width`.
That covers the common case (3–4 agents on a normal-size terminal), but
caps out at the `[1, 12]` bound and falls back to `tiled` once too many
panes would be narrower than `min_width`.

The deferred feature: **when the user explicitly asks for more agents
than fit as columns at `min_width`, spill the overflow into additional
`agents-N` windows instead of cramming them into a tiled grid**. Each
spillover window keeps the wide-column readability that the first window
has, at the cost of the user having to switch windows to see the rest.

Motivating pattern: `svibe 8 codex` on a 240-col terminal (`max_columns =
3` at `min_width=80`) currently produces an 8-pane tiled grid where each
pane is ~90 cols × ~15 rows — legible but crowded. Spillover would
produce three windows (`agents-1` with 3 panes, `agents-2` with 3, `agents-3`
with 2), each a wide `even-horizontal` layout. Same total agent count,
noticeably more usable individually.

## Why this is deferred (not in the single-window change)

1. **Window indices shift**: today the layout is `agents` / `git` / `edit`
   at indices 1/2/3. Spillover means `agents-1` / `agents-2` / ... /
   `git` / `edit`, so any code or muscle-memory referencing window 2
   = lazygit breaks. Need to decide: renumber, or put git/edit at fixed
   high indices, or name-reference everywhere.
2. **`--on-exit restart` per-pane routing**: the current `shell` / `kill`
   / `restart` wrapping is per-pane inside one window. Multi-window has
   the same per-pane semantics but the `[agent exited — back in shell]`
   hint references the pane-relative coords; worth sanity-checking that
   the hint text still reads correctly when the pane is in window 3/5
   instead of window 1/3.
3. **Focus-on-attach**: currently `tmux select-window -t agents;
   select-pane -t .1`. Spillover needs a rule — land in `agents-1.1`
   always, or the last-used agent window, or the first non-full one?
4. **Interaction with existing `[1, 12]` bound**: cap agents per window at
   `max_columns` (= `term_width / min_width`), cap total at 12 (current
   invariant), cap number of spillover windows at some N (8? 10?).
   Product of caps matters — a very wide terminal with tiny `min_width`
   could still produce pathological configs without a ceiling.
5. **CLI surface**: a flag to enable/disable spillover. Options:
    - `--spill` (boolean) — enable spillover, default off.
    - `--max-per-window N` — explicit cap, implies spillover when
      `${#agents} > N`.
    - `SVIBE_SPILL=1` env var — match the `SVIBE_MIN_WIDTH` pattern.
   Probably the flag *and* the env, matching `--min-width` /
   `SVIBE_MIN_WIDTH`. User explicitly asked for a gate flag.

## Sketch

```zsh
# After computing max_columns and knowing ${#agents}:
if (( spill_enabled && ${#agents} > max_columns )); then
    local per_window=$max_columns
    local -a window_names
    local idx=1 remaining=${#agents}
    while (( remaining > 0 )); do
        local take=$(( remaining > per_window ? per_window : remaining ))
        local wname="agents-$idx"
        window_names+=( "$wname" )
        # new-window with first pane, split-window for the rest, apply
        # even-horizontal at end
        remaining=$(( remaining - take ))
        idx=$(( idx + 1 ))
    done
    # git, edit windows follow with fixed names (referenced by name not index)
else
    # existing single-window path
fi
```

Untidy details:
- First window must be created via `new-session -d`, subsequent ones via
  `new-window -t "$session"`. Easier if the first-pane creation is
  factored out of the single-window path.
- Naming: `agents-1` / `agents-2` vs `agents` / `agents-2`. Former is
  more consistent once you have >1; latter is less noisy when you only
  ever use 1. Leaning consistent-`-N`.
- The existing picker (`prefix + e` → menu, `prefix + number`) works
  fine against named windows, no tmux-side changes needed.

## Open questions

1. Is the motivating use case real, or hypothetical? If the user never
   runs `svibe > 6`, this is dead weight. Worth waiting for the first
   "I wish svibe had …" signal before building.
2. Should spillover also fire on `min_width` shrinking the current
   terminal *after* session creation? Probably no — the layout is set at
   creation time, tmux handles resize by proportional shrink, and the
   user can always kill and re-svibe.
3. Multi-monitor / split-screen case: user attaches from a 400-col
   monitor, later from a phone SSH'd at 80 cols. Spillover baked in at
   creation doesn't help here — only session-level layout cycling does.

## Verification plan (when we pick this up)

- `svibe --spill 8 codex` on 240×60 → 3 windows named `agents-1`
  (3 panes), `agents-2` (3 panes), `agents-3` (2 panes), plus `git`
  and `edit`.
- Baseline regression: `svibe 4 codex` still single-window `agents`.
- `--on-exit restart` works per-pane in spillover windows.
- Focus lands in `agents-1.1` on attach.
- `--no-attach` + `tmux has-session` confirms window list matches
  expectation.

## Not in scope (explicit non-goals)

- Dynamic repartition after the session is built. Once panes are laid
  out, they stay laid out; resize is tmux's job.
- Per-pane width overrides (e.g. "make agent 1 wider than the others").
  If someone wants this, tmux's interactive resize (`prefix + M-h/l`)
  is the right surface.
- Automatic lazygit / nvim duplication across spillover windows. They
  stay as single windows — spillover is only for agent panes.
