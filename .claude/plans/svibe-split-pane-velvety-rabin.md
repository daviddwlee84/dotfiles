# svibe: prefer column layout below a pane-count threshold

## Context

`svibe` (alias for the `sesh-vibe` zsh function) always lays out its agent
window with `tmux select-layout … tiled`, regardless of pane count. This means
2 panes already produce a top/bottom split and 3 panes produce an awkward
1.5×2 grid, when what the user actually wants for small counts is **N
side-by-side vertical columns** — each pane keeps a usable width and
agent transcripts stay readable.

The user asked: for small N prefer column layout ("水平切分" → side-by-side
columns via tmux `even-horizontal`), only fall back to a grid once the grid
is genuinely necessary. Their example cutover: 3 panes = 3 columns, 4 panes
= start using the grid.

Outcome: change the layout selection in svibe from unconditional `tiled` to
`even-horizontal` when `N ≤ 3` and `tiled` when `N ≥ 4`. Everything else
about svibe (agent wrapping, windows, bounds, validation, help output,
heterogeneous `--agents` mode) is unchanged.

## Scope & non-goals

- **In scope**: the single layout-selection call that runs after each split
  inside `sesh-vibe`, plus the short doc/help strings that describe the
  layout.
- **Not in scope**: adding a `--layout` CLI flag, adding an `SVIBE_LAYOUT`
  env override, revisiting the `[1, 12]` bound, changing pane ordering.
  A flag override is a plausible future addition but the user asked for a
  default change, not new configuration surface.

## The change

### 1. `dot_config/zsh/tools/22_sesh.zsh` — `sesh-vibe()` layout selection

Currently (lines 578–585):

```zsh
# Add remaining panes
local i
for (( i = 2; i <= ${#agents}; i++ )); do
    tmux split-window -t "${session}:agents" -c "$repo_root" \
        "$(_vibe_agent_cmd "${agents[$i]}")"
    # Re-tile after each split so layout stays balanced
    tmux select-layout -t "${session}:agents" tiled >/dev/null
done
```

Replace with:

```zsh
# Pick window layout based on final pane count:
#   N ≤ 3 → even-horizontal (N side-by-side columns, readable width)
#   N ≥ 4 → tiled (grid — columns would be too narrow)
local svibe_layout
if (( ${#agents} <= 3 )); then
    svibe_layout="even-horizontal"
else
    svibe_layout="tiled"
fi

# Add remaining panes
local i
for (( i = 2; i <= ${#agents}; i++ )); do
    tmux split-window -t "${session}:agents" -c "$repo_root" \
        "$(_vibe_agent_cmd "${agents[$i]}")"
    # Re-balance after each split so layout stays uniform
    tmux select-layout -t "${session}:agents" "$svibe_layout" >/dev/null
done
```

Notes:
- Threshold is computed **once** from `${#agents}` before the loop, so every
  iteration applies the same target layout. That also keeps the N=1 case
  correct: the loop body doesn't run, so no `select-layout` is called and
  the single pane fills the window as before.
- `even-horizontal` vs a chain of `split-window -h`: using `select-layout`
  is the right hammer because it re-balances widths at every step, matching
  how the existing tiled path works. This also means the user can press
  `prefix + Space` / the built-in tmux layout cycler to switch between
  layouts interactively if they want a different view for a given session.

### 2. Help text (same file, inside the `-h|--help` heredoc, lines ~434–437)

Current:

```
Default: svibe 4 claude
  window 1 "agents" — N panes (tiled), each running an agent
  window 2 "git"    — lazygit
  window 3 "edit"   — nvim
```

Replace with:

```
Default: svibe 4 claude
  window 1 "agents" — N agent panes (≤3 = columns, ≥4 = tiled grid)
  window 2 "git"    — lazygit
  window 3 "edit"   — nvim
```

### 3. `docs/tools/sesh.md` — svibe layout description (lines 186–195)

Current:

```
Layout (3 windows):

\`\`\`
window 1 "agents"    — N tiled panes, each running its agent (mixed allowed)
window 2 "git"       — lazygit (or \`git status\` fallback)
window 3 "edit"      — nvim
\`\`\`

Pane count is bounded \`[1, 12]\`. Above ~6 the tiled layout becomes too
cramped on most displays — the cap is conservative, not technical.
```

Replace with:

```
Layout (3 windows):

\`\`\`
window 1 "agents"    — N agent panes: ≤3 = even-horizontal columns,
                       ≥4 = tiled grid (mixed agents allowed)
window 2 "git"       — lazygit (or \`git status\` fallback)
window 3 "edit"      — nvim
\`\`\`

The agents window prefers **side-by-side vertical columns** up to 3 panes
so each transcript keeps a readable width, and falls back to a tiled grid
at 4+ panes where columns would be too narrow. Press \`prefix + Space\`
to cycle through tmux's built-in layouts if you want a different view.

Pane count is bounded \`[1, 12]\`. Above ~6 the tiled grid becomes too
cramped on most displays — the cap is conservative, not technical.
```

## Files to modify

| File | Change |
|------|--------|
| `dot_config/zsh/tools/22_sesh.zsh` | layout-selection logic (lines 578–585); `--help` text (lines 434–437) |
| `docs/tools/sesh.md` | layout description (lines 186–195) |

No other CLAUDE.md invariants apply (this doesn't touch chezmoi templates,
the sudo session, fleet-apply, upgrade paths, or the tmux popup menu size).
`mkdocs.yml` nav is unchanged (no new doc pages).

## Verification

Run from the repo root. Assumes `claude` is installed; substitute any
agent you have locally if not.

1. **Source the updated function** in a fresh shell so the change takes
   effect:

   ```bash
   source ~/.config/zsh/tools/22_sesh.zsh
   ```

2. **N = 2** — expect two side-by-side columns:

   ```bash
   svibe --no-attach 2 claude
   tmux display-message -t 'vibe/chezmoi:agents' -p '#{window_layout}'
   # → layout string should start with "even-horizontal" or show two
   #   panes at roughly (cols/2, full-height) each.
   tmux list-panes -t 'vibe/chezmoi:agents' -F '#{pane_index} #{pane_width}x#{pane_height}'
   # → two panes, equal widths, equal (full) heights.
   tmux kill-session -t 'vibe/chezmoi'
   ```

3. **N = 3** — expect three side-by-side columns (the user's motivating
   example):

   ```bash
   svibe --no-attach 3 claude
   tmux list-panes -t 'vibe/chezmoi:agents' -F '#{pane_index} #{pane_width}x#{pane_height}'
   # → three panes, equal widths, equal full heights. NOT a 2-over-1 grid.
   tmux kill-session -t 'vibe/chezmoi'
   ```

4. **N = 4** — expect tiled grid (regression check — behavior unchanged):

   ```bash
   svibe --no-attach 4 claude
   tmux list-panes -t 'vibe/chezmoi:agents' -F '#{pane_index} #{pane_width}x#{pane_height}'
   # → 2×2 grid (two rows of two panes).
   tmux kill-session -t 'vibe/chezmoi'
   ```

5. **N = 1** — expect a single full-window pane (no `select-layout`
   called):

   ```bash
   svibe --no-attach 1 claude
   tmux list-panes -t 'vibe/chezmoi:agents' | wc -l
   # → 1
   tmux kill-session -t 'vibe/chezmoi'
   ```

6. **`--help` text** mentions the new layout rule:

   ```bash
   svibe -h | grep -E 'columns|tiled'
   ```

7. **Docs strict build** still passes:

   ```bash
   uv run mkdocs build --strict
   ```

## Risks

- Minor: users with muscle memory for the previous tiled layout at N=2 or
  N=3 will see a change. This is the requested behavior. They can cycle
  layouts with `prefix + Space` in-session, and the help text + docs now
  call out the new rule.
- None of the changes touch `modify_` / `create_` chezmoi files, ansible,
  or the sudo session, so no cross-file invariants are at risk.
