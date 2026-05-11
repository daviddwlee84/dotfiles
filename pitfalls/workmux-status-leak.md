# Workmux 🤖 status icon stuck on tmux window after agent exits

## Symptoms

- Tmux window list shows `1 zsh 🤖` after the OpenCode/Claude session
  in that window has been closed (Ctrl+C, kill pane, terminal crash).
- `tmux list-windows` shows `pane_current_command` is back to `zsh` /
  `bash`, but the 🤖 emoji persists in the window-status.
- Other windows that currently run an agent show no marker at all,
  while old "ghost" windows do.
- `tmux show -gv window-status-format` does NOT contain any emoji literal
  — searching `~/.tmux/`, `~/.config/tmux/`, all loaded plugins for
  `🤖|💬|✅` returns zero matches.
- `grep -rln '🤖' ~/.config ~/.local` finds nothing tmux-related.
- The marker only appears on SOME machines — fresh boxes never have it;
  only machines where you previously ran `workmux setup` (or `wm setup`).

## Root cause

The 🤖/💬/✅ icons come from [workmux](https://github.com/raine/workmux)
(`workmux` / `wm`), a tmux + git-worktree orchestrator. The mechanism is
**per-window tmux user options**:

```
tmux set-option -w -t <session>:<window> @workmux_status '🤖'
```

This was invisible to a normal grep-the-config search because:

1. `@workmux_status` is a **per-window** option, not global. `tmux show -gv`
   only inspects global options. To see it: `tmux show-options -wA -t <window>`.
2. The `window-status-format` mod that `wm setup` does is **per-tmux-session**,
   set the first time `wm` runs in that session. It's not in any config
   file — only in tmux's runtime state.
3. The literal emoji never appears in any config file because the
   user-var value is set imperatively by `workmux set-window-status` from
   agent hooks at runtime.

## Why the marker leaks

Two distinct leak modes, both upstream design choices:

### 1. `working` (🤖) is sticky by design

From `workmux set-window-status --help`:

| state | auto-clear |
|---|---|
| `working` | NEVER auto-clears |
| `waiting` | Auto-clears on window focus |
| `done` | Auto-clears on window focus |

`working` only goes away when something explicitly calls
`workmux set-window-status done` (or `clear`). If the agent process dies
ungracefully (Ctrl+C, terminal crash, OOM, SSH disconnect), no `done`
event fires and the 🤖 sticks forever.

### 2. Claude integration is set-only by upstream design

Upstream `wm setup` writes `~/.claude/settings.json` hooks that only
**set** `working` on `PostToolUse` / `UserPromptSubmit`. There is **no
`Stop` hook calling `set-window-status done`** in the upstream install.
Every Claude turn ends with 🤖 still showing — even on graceful exit.

OpenCode is better: its plugin listens for `session.idle` and calls
`done`. That fixes the graceful-shutdown case but not the crash case.

## Fix

This repo ships three layers of mitigation, all chezmoi-managed so they
auto-deploy on every box. See [docs/tools/workmux.md](../docs/tools/workmux.md)
for the full integration story; in pitfall-form:

1. **Claude `Stop` + `SubagentStop` hooks** —
   [`dot_claude/modify_settings.json`](../dot_claude/modify_settings.json)
   adds explicit `workmux set-window-status done` calls on every turn end.
   Fixes the by-design Claude leak. The hook-aware merger preserves any
   parallel entries from CodeIsland or `wm setup`.

2. **OpenCode `session.idle` plugin** —
   [`dot_config/opencode/plugins/workmux-status.ts`](../dot_config/opencode/plugins/workmux-status.ts)
   vendored from upstream. Handles graceful-shutdown leak.

3. **Self-managed window-status-format** —
   [`dot_config/tmux/theme.catppuccin.conf`](../dot_config/tmux/theme.catppuccin.conf)
   appends `#{?@workmux_status, #{@workmux_status},}` to catppuccin's
   window text overrides. Plus `status_format: false` in
   [`dot_config/workmux/config.yaml`](../dot_config/workmux/config.yaml)
   tells `wm` not to also do its own per-session rewrite. Result: icons
   render in every tmux session consistently, survive `chezmoi diff`,
   don't fight catppuccin.

For the residual crash-leak case (any agent killed without firing its
hook): use `wmclear` from
[`dot_config/zsh/tools/38_workmux.zsh`](../dot_config/zsh/tools/38_workmux.zsh),
or run `wm sidebar` (auto-detects 10s pane silence and downgrades stuck
`working`).

## Debugging recipe (next time the marker behaves weirdly)

```bash
# 1. Is workmux even installed on this machine?
command -v workmux && workmux --version

# 2. What's the per-window state?
tmux list-windows -aF '#{session_name}:#{window_index} name=#{window_name} marker=#{@workmux_status}'

# 3. What's the per-session window-status-format?
#    (workmux self-manages this if status_format:true; we set it to false)
tmux show -gv window-status-format
tmux show -gv @catppuccin_window_text  # our self-managed path

# 4. Where are the agent hooks actually pointing?
jq '.hooks' ~/.claude/settings.json
ls ~/.config/opencode/plugins/

# 5. Manual escape hatch when stuck
wmclear           # current window
wmclear --all     # entire current session
```

## Related

- [docs/tools/workmux.md](../docs/tools/workmux.md) — integration overview.
- [docs/tools/agent-overlays.md](../docs/tools/agent-overlays.md) — the
  hook-aware merger pattern in `modify_settings.json`.
- [backlog/tmux-window-status-indicators.md](../backlog/tmux-window-status-indicators.md)
  — original design exploration that predicted exactly this lifecycle bug
  before workmux was discovered as the upstream solution. Closed by this
  pitfall.
