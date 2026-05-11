# Workmux — tmux + git-worktree orchestration with agent status icons

[Workmux](https://workmux.raine.dev) (`workmux` / `wm`) is a CLI from
[raine/workmux](https://github.com/raine/workmux) that ties tmux windows,
git worktrees, and AI coding agents into one workflow. It coexists with
[`worktrunk`](worktrunk.md) (`wt`) in this repo — the two solve overlapping
problems but each has a unique killer feature, so we keep both managed.

> **TL;DR**
> - `wt` = worktree CLI / aliases / `wt cc fix-x -- 'prompt'` per-branch
>   Claude launcher. See [worktrunk playbook](worktrunk.md).
> - `wm` = same worktree-launcher concept BUT also: 🤖/💬/✅ icons in tmux
>   window list, `wm dashboard` TUI, `wm sidebar` always-on status pane,
>   per-window status user-var (`@workmux_status`).
> - This repo auto-installs both, manages `wm`'s status hooks for Claude
>   Code + OpenCode so the icons work on every fresh box, and patches the
>   upstream by-design `working` (🤖) leak so it doesn't get stuck.

## Table of Contents

- [Why both wt and wm?](#why-both-wt-and-wm)
- [What this repo manages for you](#what-this-repo-manages-for-you)
- [Status icon mechanics](#status-icon-mechanics)
- [The 🤖-leak problem and how we fix it](#the--leak-problem-and-how-we-fix-it)
- [Self-managed status format](#self-managed-status-format)
- [Daily commands](#daily-commands)
- [Manual cleanup: `wmclear`](#manual-cleanup-wmclear)
- [Sidebar daemon (optional)](#sidebar-daemon-optional)
- [Adding a new agent](#adding-a-new-agent)
- [Reusing the per-window status mechanism (without workmux)](#reusing-the-per-window-status-mechanism-without-workmux)
- [Cross-references](#cross-references)

---

## Why both wt and wm?

| Capability | `wt` (worktrunk) | `wm` (workmux) |
|---|---|---|
| Create worktree + branch + tmux pane | ✅ `wt switch -c -x claude feat` | ✅ `wm add feat` |
| Per-branch alias system | ✅ `[aliases]` in toml | ⚠️ named layouts only |
| Cleanup `merge`/`remove` lifecycle | ✅ | ✅ |
| Hooks (pre/post-start/merge/remove) | ✅ ten hook types | ✅ four hook types |
| Tmux window-status agent icon | ❌ no integration | ✅ `@workmux_status` |
| Always-visible status sidebar | ❌ | ✅ `wm sidebar` |
| Dashboard TUI (`d` for diff, `c` for commit) | ⚠️ interactive picker only | ✅ `wm dashboard` |
| Sandbox (Docker / Lima / Apple Container) | ❌ | ✅ |
| LLM commit messages | ✅ `wt merge` invokes LLM | ❌ |
| Auto-detected backend (kitty / wezterm / zellij) | ⚠️ tmux-only | ✅ multi-backend |
| Already in this repo | since 2026-04 | since 2026-05-11 |

You don't have to use both. The split is:

- **`wt cc <branch> -- 'prompt'`** stays the muscle-memory entry for
  parallel Claude/OpenCode in a worktree (worktrunk's alias engine is more
  expressive).
- **`wm` is what gives you the 🤖/💬/✅ icons** in the tmux window list, no
  matter which tool you used to spawn the agent. The icons come from
  workmux hooks installed in Claude/OpenCode that run regardless of which
  CLI you used to launch them.
- **`wm dashboard` / `wm sidebar`** for monitoring N parallel agents.

If you only want one, drop `wt`'s aliases from
[`dot_config/worktrunk/config.toml`](../../dot_config/worktrunk/config.toml)
and use `wm add -x claude` in its place.

## What this repo manages for you

| File / setting | Path | Purpose |
|---|---|---|
| Binary install (macOS) | `dot_ansible/roles/devtools/tasks/main.yml` (`workmux` in `homebrew:` list, `raine/workmux` tap) | `brew install workmux` on every macOS apply |
| Binary install (Linux) | `dot_ansible/roles/devtools/tasks/main.yml` (workmux block) | Downloads `workmux-linux-{amd64,arm64}.tar.gz` from GitHub releases to `~/.local/bin/`; symlinks `wm -> workmux` |
| Global config | [`dot_config/workmux/config.yaml`](../../dot_config/workmux/config.yaml) | `nerdfont: false` + `status_format: false` (we manage the tmux format ourselves) |
| Tmux window format | [`dot_config/tmux/theme.catppuccin.conf`](../../dot_config/tmux/theme.catppuccin.conf) | Appends `#{?@workmux_status, #{@workmux_status},}` to `@catppuccin_window_text` / `@catppuccin_window_current_text` |
| Claude hooks | [`dot_claude/modify_settings.json`](../../dot_claude/modify_settings.json) | Adds `Stop` / `SubagentStop` / `UserPromptSubmit` / `Notification` hooks calling `workmux set-window-status` |
| OpenCode plugin | [`dot_config/opencode/plugins/workmux-status.ts`](../../dot_config/opencode/plugins/workmux-status.ts) | Vendored copy of upstream plugin — listens to OpenCode events, calls `workmux set-window-status` |
| OpenCode plugin deps | [`dot_config/opencode/modify_package.json`](../../dot_config/opencode/modify_package.json) | jq-merges `@opencode-ai/plugin: 1.4.3` into existing `package.json` |
| Shell helpers | [`dot_config/zsh/tools/38_workmux.zsh`](../../dot_config/zsh/tools/38_workmux.zsh) | `wmclear` (manual marker reset), `wmsb` alias, `wm='workmux'` fallback alias |

What is **NOT** managed (by design):

- `wm setup` is not auto-run. It would write the same Claude/OpenCode hooks
  we already manage above, leading to duplicate entries (the hook-aware
  merger in `modify_settings.json` would deduplicate them but the cleaner
  path is to skip `wm setup` entirely on managed machines). On a fresh box
  the chezmoi layer installs everything `wm setup` would have done.
- `~/.config/workmux/state/` (per-machine runtime state — XDG state dir).
- `wm dashboard` color theme overrides — defaults are fine.
- Per-project `.workmux.yaml` — that lives in each project repo, not here.

## Status icon mechanics

Three states, three glyphs (defaults):

| State | Glyph | Set by | Auto-clear behaviour |
|---|---|---|---|
| `working` | 🤖 | Agent processing a turn | ❌ **Sticky** — never auto-clears |
| `waiting` | 💬 | Permission prompt / question | ✅ Clears when window receives focus |
| `done` | ✅ | Turn finished gracefully | ✅ Clears when window receives focus |
| `clear` | (none) | Explicit unset | — |

The mechanism: `workmux set-window-status <state>` writes to the tmux
**per-window user option** `@workmux_status` for the current window. Our
catppuccin format string appends `#{?@workmux_status, #{@workmux_status},}`,
so any window with the option set renders the glyph after `#W`.

Verify on a live tmux:

```bash
# See which windows have the marker set
tmux list-windows -aF '#{session_name}:#{window_index} #{@workmux_status}'

# Look at the format string our theme installed
tmux show -gv @catppuccin_window_text
# Expected: ' #W#{?@workmux_status, #{@workmux_status},}'
```

## The 🤖-leak problem and how we fix it

`working` is **sticky by design** — it only transitions away when the agent
explicitly calls `set-window-status done` (or `clear`). When the agent dies
ungracefully (Ctrl+C, terminal crash, OOM, SSH disconnect), no `done` ever
fires and the 🤖 sticks forever.

Worse for Claude specifically: upstream's default `wm setup` only installs
hooks that **set** `working` (`PostToolUse`, `UserPromptSubmit`) — there is
no `Stop` hook calling `set-window-status done`. Every Claude turn ends with
🤖 still showing. This is **by design** in upstream and was the root cause
of the [original investigation](../../pitfalls/workmux-status-leak.md).

This repo fixes both leak modes:

1. **Claude `Stop` + `SubagentStop` hooks** — managed in
   [`dot_claude/modify_settings.json`](../../dot_claude/modify_settings.json).
   Every Claude turn end calls `workmux set-window-status done`, which
   immediately makes ✅ appear and then auto-clears on focus. Fixes the
   by-design leak.

2. **OpenCode `session.idle` event handler** — vendored from upstream into
   [`dot_config/opencode/plugins/workmux-status.ts`](../../dot_config/opencode/plugins/workmux-status.ts).
   This works for graceful shutdowns. Crash/Ctrl+C still leaks.

3. **Crash leak (any agent)** — three escape hatches:
   - `workmux sidebar` running anywhere → 10s pane-silence detection
     auto-downgrades stuck `working` to interrupted (released v0.1.99 +
     v0.1.163). See [Sidebar daemon (optional)](#sidebar-daemon-optional).
   - `wmclear` (this repo's helper) — manual reset. See
     [Manual cleanup](#manual-cleanup-wmclear).
   - `command -v workmux >/dev/null && workmux set-window-status clear` —
     raw command if you forget the alias.

The `command -v workmux` guard in our Claude hooks means the hook silently
no-ops on a fresh machine where ansible hasn't run yet (or on a server
without workmux installed) — you'll see no errors in Claude's hook log.

## Self-managed status format

Workmux's default install (`wm setup`) modifies `window-status-format`
**per-tmux-session** the first time `wm` runs in that session. Three
problems with the default:

1. **Per-session drift** — older tmux sessions that predate your last `wm`
   invocation never get the format. Reattach to one and the icons silently
   don't render.
2. **Invisible to chezmoi** — the format string lives in tmux's runtime,
   not in a config file we can diff.
3. **Conflicts with catppuccin's `@catppuccin_window_text` override** in
   this repo (catppuccin re-derives the format on every plugin run).

Solution: set `status_format: false` in
[`dot_config/workmux/config.yaml`](../../dot_config/workmux/config.yaml) and
manage the format ourselves in
[`dot_config/tmux/theme.catppuccin.conf`](../../dot_config/tmux/theme.catppuccin.conf).
Both `@catppuccin_window_text` and `@catppuccin_window_current_text` get
the `#{?@workmux_status, #{@workmux_status},}` suffix appended. The
conditional renders nothing when the user-var is unset, so windows without
agents look identical to before this change.

## Daily commands

The full upstream reference is at
[workmux.raine.dev](https://workmux.raine.dev). Quick crib for this repo:

```bash
# Create a worktree + tmux window + Claude pane
wm add fix-login --prompt 'Login times out after 5min, fix to 24h'

# Same but reuse if it exists
wm add fix-login -o

# Three parallel agents, one per branch
wm add login-a --prompt 'Approach A' --background
wm add login-b --prompt 'Approach B' --background
wm add login-c --prompt 'Approach C' --background

# Check status of every running agent
wm dashboard
# or compact CLI:
wm list

# Always-on status sidebar (also enables 10s leak auto-clear)
wm sidebar

# Jump to most recently finished/waiting agent
wm last-done

# Merge into main and clean up worktree + branch + tmux window
wm merge

# Just remove without merging
wm remove fix-login
```

Aliases ([`dot_config/zsh/tools/38_workmux.zsh`](../../dot_config/zsh/tools/38_workmux.zsh)):

| Alias | Expands to | Notes |
|---|---|---|
| `wm` | `workmux` | Defined as alias on macOS; symlink in `~/.local/bin` on Linux |
| `wmsb` | `workmux sidebar` | Toggle the sidebar |
| `wmclear` | (function — see below) | Manual marker reset |

## Manual cleanup: `wmclear`

```bash
# Clear the marker on the current window (calls workmux set-window-status clear)
wmclear

# Clear marker on a specific window in current session
wmclear 5

# Nuke every workmux marker in the current tmux session
wmclear --all
```

Implementation lives in `dot_config/zsh/tools/38_workmux.zsh`. The single-
window form prefers `workmux set-window-status clear` so workmux's internal
agent-state is also reset; the bulk forms fall back to `tmux set-option -w
-u @workmux_status` which only clears the user-var.

## Sidebar daemon (optional)

Run `wm sidebar` (or `wmsb`) once per tmux session to spawn the sidebar
pane. Two side benefits beyond the visible status panel:

1. **Interrupted-agent detection** — works only while sidebar is running.
   Watches each agent pane for output; after 10s of silence on a `working`
   agent, marks it interrupted and (per upstream v0.1.163+) downgrades the
   icon. Fixes the crash-leak with no manual cleanup.
2. **Cross-window status at a glance** — see all running agents and their
   git diff stats without `prefix + w`-ing through windows.

Cost: one tmux pane (configurable width, default ~30 cols). Auto-resizes
on terminal resize. Toggle off with `wm sidebar` again.

This repo deliberately does **NOT** auto-spawn the sidebar — too intrusive
for users who just want the icons. Add it manually to your tmux startup if
you want it everywhere:

```bash
# Add to your ~/.tmux.conf.local or similar (NOT chezmoi-managed by default)
set-hook -g session-created 'run-shell "workmux sidebar 2>/dev/null || true"'
```

## Adding a new agent

Workmux supports Claude, OpenCode, Codex, Copilot CLI, Pi, and Gemini for
status tracking ([upstream support
matrix](https://workmux.raine.dev/guide/status-tracking#agent-support)).
Codex/Copilot/Pi don't have a `waiting` state due to upstream API limits.

To add tracking for a new agent **on every machine** (not just one box):

1. Read upstream's per-agent setup at
   [workmux.raine.dev/guide/status-tracking](https://workmux.raine.dev/guide/status-tracking)
   — typically a hook config in the agent's settings file.
2. Don't run `wm setup`. Instead vendor the hook config into this repo:
   - For agents that already have an overlay file (`dot_codex/modify_config.toml.tmpl`,
     etc.), add the hook entries to that overlay's template so the
     hook-aware merger preserves user/runtime additions.
   - For agents without an overlay yet, model after
     [`dot_claude/modify_settings.json`](../../dot_claude/modify_settings.json)
     or [`dot_config/opencode/plugins/workmux-status.ts`](../../dot_config/opencode/plugins/workmux-status.ts).
3. Wrap the actual `workmux set-window-status` call with
   `command -v workmux >/dev/null 2>&1 && ... || true` so the hook no-ops
   on machines where workmux isn't installed yet.
 4. Update the table under [What this repo
    manages](#what-this-repo-manages-for-you) with the new file.

## Reusing the per-window status mechanism (without workmux)

The `@workmux_status` glyph is a thin wrapper over a generic tmux primitive:
**per-window user options + a conditional in `window-status-format`**. You
can use the same trick for ANY long-running thing whose state you want
glanceable in the tab bar — build watchers, test runners, deploy progress,
queue depth, alert badges, on-call rotation, anything. Workmux is one
producer; you can add more.

### The primitive (3 moving parts)

1. **Set** a per-window user option (any name starting with `@`):
   ```bash
   # Current window
   tmux set-option -w '@my_status' '🔨'
   # Specific window
   tmux set-option -w -t 'mysession:3' '@my_status' '⚠️'
   # Unset (clear)
   tmux set-option -w -u '@my_status'
   ```

2. **Render** it conditionally in `window-status-format` so windows
   without the option set don't render anything extra. This repo's
   catppuccin theme already appends one such conditional in
   [`dot_config/tmux/theme.catppuccin.conf`](../../dot_config/tmux/theme.catppuccin.conf):
   ```tmux
   set -g @catppuccin_window_text ' #W#{?@workmux_status, #{@workmux_status},}'
   ```
   To add YOUR badge, append another conditional:
   ```tmux
   set -g @catppuccin_window_text ' #W#{?@workmux_status, #{@workmux_status},}#{?@my_status, #{@my_status},}'
   ```
   Both will coexist (workmux's 🤖 + your 🔨 next to each other when both
   are set on the same window).

3. **Read** it back to verify or to gate logic:
   ```bash
   tmux show-options -wv -t 'mysession:3' '@my_status'
   tmux list-windows -aF '#{session_name}:#{window_index} marker=#{@my_status}'
   ```

### When to invent your own user-var vs reuse `@workmux_status`

Reuse `@workmux_status` if your status is conceptually "agent-like"
(working / waiting / done) — that way `wm sidebar` / `wm dashboard` /
`wm last-done` see your producer too, and `wmclear` resets it. Just call
`workmux set-window-status working` (or `waiting` / `done` / `clear`)
from your hook instead of writing the user-var directly.

Invent a new `@<something>_status` user-var when:
- The state space differs (e.g. a build watcher with `building` /
  `passing` / `failing` is not workmux's working/waiting/done).
- You don't want it to appear in `wm dashboard` (workmux only knows
  about `@workmux_status`).
- Multiple producers should be visible simultaneously (workmux's icon
  and your build icon side by side).

### Worked example: build watcher

Spawn a script that watches `npm run dev` output and tags the window:

```bash
# ~/.local/bin/dev-watch.sh
npm run dev 2>&1 | while IFS= read -r line; do
  printf '%s\n' "$line"
  case "$line" in
    *"compiled successfully"*)
      tmux set-option -w '@build_status' '✅' ;;
    *"failed to compile"*|*"error"*)
      tmux set-option -w '@build_status' '❌' ;;
    *"compiling"*)
      tmux set-option -w '@build_status' '🔨' ;;
  esac
done
trap 'tmux set-option -w -u "@build_status" 2>/dev/null' EXIT INT TERM
```

Append the conditional to the catppuccin format (in
`dot_config/tmux/theme.catppuccin.conf`, alongside the workmux one):
```tmux
set -g @catppuccin_window_text ' #W#{?@workmux_status, #{@workmux_status},}#{?@build_status, #{@build_status},}'
```

`tmux source-file ~/.tmux.conf` (or new tmux session) and your window
shows `dev 🔨` while building, `dev ✅` when green, `dev ❌` on failure,
nothing when the script isn't running.

### Lifecycle hard rules (learned the hard way)

These mirror the workmux-leak debugging in
[`pitfalls/workmux-status-leak.md`](../../pitfalls/workmux-status-leak.md):

- **Always have an unset path.** Set without unset = stuck marker
  forever. Use a `trap … EXIT INT TERM` if your producer is a script;
  use a `Stop` / `idle` event handler if your producer is an agent.
- **Sticky states need an explicit clearer.** `working`-style states
  (no auto-clear) need a counterpart event that calls unset. Workmux's
  bug was Anthropic shipping `set working` hooks without `set done` on
  Claude Stop — same trap awaits any custom integration.
- **Guard the producer with a `command -v` check** if it might run on a
  machine that doesn't have tmux loaded (cron, CI, SSH headless), so
  `tmux set-option` doesn't error and trash your hook log.
- **Pick a unique `@` prefix.** `@workmux_status` is taken; collisions
  silently wreck both producers. Convention: `@<tool>_status` or
  `@<your-username>_<purpose>`.
- **Per-window scope, not per-pane.** `tmux set-option -w` is window-
  level, so all panes in a window share the marker. If you need
  per-pane, use `set-option -p` and switch the format to use
  `#{?#{p:@my_status}, …}` — but the icon shows on the WINDOW tab, so
  per-window is almost always what you want.

For the "see all markers across all sessions" debugging recipe, see
[`pitfalls/workmux-status-leak.md`](../../pitfalls/workmux-status-leak.md)
→ "Debugging recipe".

## Cross-references

- [Worktrunk playbook](worktrunk.md) — the parallel `wt` workflow.
- [Agent overlays deep-dive](agent-overlays.md) — how `dot_*/modify_*`
  scripts merge with runtime-rewritten configs.
- [`pitfalls/workmux-status-leak.md`](../../pitfalls/workmux-status-leak.md) —
  the original investigation that uncovered the by-design leak and the
  per-tmux-session format-drift issue.
- [`backlog/tmux-window-status-indicators.md`](../../backlog/tmux-window-status-indicators.md) —
  closed in this commit; design notes preserved for history.
- [Upstream docs](https://workmux.raine.dev) — full CLI reference.
- [CHANGELOG](https://github.com/raine/workmux/blob/main/CHANGELOG.md) —
  release-by-release feature list. Worth checking when bumping the install.
