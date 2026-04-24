# tmux scrollback shows duplicated / ghost lines while Claude Code / OpenCode runs

**Symptoms** (grep this section): ghost lines in tmux scrollback, repeated spinner frames in history, scrollback looks "broken" when scrolling up in a coding-agent pane, tmux history contains dozens of half-repainted copies of the same prompt, copy-mode shows flipbook frames of a streaming TUI, `prefix + [` then scroll up and see duplicated UI chrome from a running agent.

**First seen**: 2026-04 (daily Claude Code / OpenCode workflow)
**Affects**: tmux × any main-screen TUI that repaints via ANSI sequences (some coding agents, progress bars, live log viewers without `\e[?1049h` alt-screen toggle)
**Status**: mitigated (`scroll-on-clear off` + `prefix + [` freeze workflow); fundamental limit of ANSI redraw + linear scrollback — cannot be fully eliminated while the TUI runs on the main screen.

## Symptom

Scrolling up through a pane that ran Claude Code / OpenCode / a long `cargo build` with live progress shows frames of the TUI stacked like a flipbook in history. Each repaint cycle left a layer in scrollback:

```
❯ claude
╭───────── Claude Code ─────────╮
│ > analyzing …                  │
╰────────────────────────────────╯
❯ claude
╭───────── Claude Code ─────────╮
│ > analyzing …                  │
│ > reading file                 │
╰────────────────────────────────╯
❯ claude
╭───────── Claude Code ─────────╮
│ > analyzing …                  │
│ > reading file                 │
│ > writing patch                │
╰────────────────────────────────╯
```

Unlike a native terminal (iTerm2, Ghostty direct), where the same repaint cycles just overwrite the visible region and never enter history.

## Root cause

Two-layer issue:

1. **ANSI redraw on the main screen.** TUIs that don't enter alternate-screen (`\e[?1049h`) repaint by erasing + rewriting the same region. A raw terminal emulator only remembers the current grid; tmux, which captures into a scrollback buffer for cursor-up / copy-mode, keeps every frame. This is fundamental to how tmux implements history, not a bug.

2. **`scroll-on-clear on` (tmux 3.3+ default).** When a TUI issues a full-screen clear (ED) before repaint, tmux pushes the pre-clear screen into history instead of dropping it, multiplying the first problem.

Alt-screen apps (vim, htop, less, most modern TUIs including Claude Code's interactive session) are NOT affected — tmux keeps alt-screen's buffer separate and doesn't pollute history with repaints.

## Workaround

Applied in this repo:

- `set -g scroll-on-clear off` in [`dot_config/tmux/common.conf`](../dot_config/tmux/common.conf) next to `history-limit`.

Manual workflow for inspection while an agent is running:

- `prefix + [` enters copy-mode, which **snapshots** the current frame. Scroll freely with wheel / `C-u` / `C-d` without the UI continuing to repaint under you. `q` exits.
- For a clean export of a pane (history + current screen), use `prefix + Y` (full scrollback to clipboard) or `tmux capture-pane -pS - > /tmp/pane.log` on the CLI.
- If exporting for replay, `tmux capture-pane -pe -S -` preserves escape sequences; feed into `asciinema play` or similar.

For command-boundary navigation (jump to previous prompt / copy last command's output cleanly), see [OSC 133 integration](../docs/tools/tmux/README.md#osc-133-command-boundary-navigation-warp-style) — orthogonal feature, solves "I want the output of the last command" rather than "the agent's repaint frames are noise".

## Prevention

Not really preventable while the TUI runs on the main screen. Check whether a new tool supports alt-screen mode (some accept `--alt-screen` / `--tui` flags; otherwise it's an upstream issue). Claude Code's interactive mode does use alt-screen, so normal Claude sessions are unaffected — the symptom typically shows up with tools that stream structured output with live repaint but no alt-screen enter sequence.

## Related

- tmux manpage on `scroll-on-clear`: _"If this option is on, whenever contents are cleared from the terminal they are moved into the history."_
- [`docs/tools/tmux/README.md`](../docs/tools/tmux/README.md#scrollback--coding-agents) → "Scrollback & Coding Agents" — the positive workflow documentation of this pitfall.
- [`docs/tools/tmux/README.md`](../docs/tools/tmux/README.md#osc-133-command-boundary-navigation-warp-style) → "OSC 133 Command-Boundary Navigation" — separate feature, enables clean per-command copy even when the stream around it is messy.
- [`pitfalls/tmux-display-menu-silent-fail.md`](tmux-display-menu-silent-fail.md) — unrelated tmux silent-failure mode (height-based, not scrollback).
