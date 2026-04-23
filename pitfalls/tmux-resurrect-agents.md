# tmux-resurrect doesn't restore coding-agent / TUI sessions

**Symptoms** (grep this section): after `tmux kill-server` + reattach, the
window layout and cwd come back but `opencode` / `claude` / `codex` /
`aider` / `lazygit` / `btop` / `yazi` panes are just a bare shell prompt;
nvim panes restore fine; `tmux-continuum` ran on schedule; `prefix +
Ctrl-r` doesn't help.
**First seen**: 2026-04, tmux-resurrect master + tmux-continuum master
**Affects**: every TUI not in resurrect's default whitelist (effectively:
every coding agent, every "modern" TUI shipped after ~2018)
**Status**: workaround in place (`@resurrect-processes` extended in
`common.conf`); not a bug — by design.

## Symptom

After kicking the tmux server (manual `tmux kill-server`, OS reboot,
ghostty crash, plugin reload that needed full restart):

```bash
tmux attach
# (window layouts come back; nvim re-opens with the same files)
# but agent panes show:
~/proj/foo $ █
# instead of:
opencode> █
```

`tmux-continuum` saved successfully (check `~/.local/share/tmux/resurrect/`
or `~/.tmux/resurrect/` — last save file is recent and contains the agent
process names). It just chose not to restart them.

## Root cause

`tmux-resurrect`'s restore phase walks each saved pane, reads the recorded
process command, and **only re-execs commands that match the
`@resurrect-processes` whitelist**. Default whitelist is approximately:

```
"~vi vim nvim emacs man less more tail top htop irssi mutt"
```

Notice what's missing: every coding agent, every git/docker TUI, every
modern file manager. `nvim` survives because it's explicitly listed; `vim`
survives because of the leading `~` semantics; `htop` survives.
`opencode` doesn't survive because it's not on the list — resurrect leaves
that pane as a fresh shell at the saved cwd.

This is **deliberate**. From the resurrect docs and design discussion
([tmux-plugins/tmux-resurrect#9][1]):

- Agents typically have **in-memory state** (conversation buffer, MCP
  connections, OAuth tokens) that bare `exec opencode` cannot recreate.
- Re-execing arbitrary commands is a foot-gun: a daemon launched with `&`,
  a `npm run dev` that mutates files, a `psql` connected to prod — none
  of these should auto-restart on tmux reattach.
- The whitelist is opt-in so the user takes explicit responsibility for
  "yes, this command is safe to bare-restart".

[1]: https://github.com/tmux-plugins/tmux-resurrect/blob/master/docs/restoring_programs.md

## Workaround

Extend the whitelist in `dot_config/tmux/common.conf`:

```tmux
set -g @resurrect-processes 'opencode claude codex aider gemini lazygit btop htop yazi k9s lazydocker glow'
```

What this **does** restore:

- pane re-execs the bare command (no args)
- agent picks up at the cwd that was saved
- visible result: panel shows the agent's startup screen instead of `$`

What this does **not** restore:

- conversation history (every coding agent restarts as a brand-new session;
  `opencode --continue` / `claude --continue` would resume the last one but
  resurrect can't pass args)
- in-flight tool calls / pending diffs / sub-agent state
- auth tokens that were typed at runtime (those that come from env / config
  files survive; runtime `/login` does not)
- TUI scroll position / search history

If you want session continuity (not just "agent is running again"), wrap
each agent in a `*-resume` shim that invokes `--continue`:

```bash
#!/usr/bin/env bash
# ~/.local/bin/opencode-resume
exec opencode --continue "$@"
```

then `set -g @resurrect-processes 'opencode-resume claude-resume codex-resume ...'`.
Trade-off: the very first launch in any session also goes through
`--continue` which may resume an unrelated old session if you forgot to
explicitly `opencode` (no `-resume`) for new work. Repo currently uses the
plain whitelist (option a) and leaves the wrapper variant (option c) to
the user.

## Prevention

When adopting a new TUI / coding-agent CLI, decide upfront:

1. **Safe to bare re-exec** (file managers, git TUIs, monitors, agents you
   always want to restart from scratch) → add to `@resurrect-processes`.
2. **Stateful and worth resuming** (agents with conversation continuity
   that matters) → write a `<tool>-resume` wrapper, whitelist that.
3. **Dangerous to auto-restart** (dev servers, prod connections, anything
   with side effects on launch) → leave off the whitelist; restore brings
   you to a shell at the right cwd, you launch by hand.

The line between (1) and (2) is judgement; "I want my agent panes to look
populated after reattach" is a valid reason to pick (1) even for stateful
agents — you accept that the visible session is fresh.

## Verifying after a change

```bash
# After editing common.conf:
chezmoi apply ~/.config/tmux
tmux source-file ~/.config/tmux/tmux.conf
tmux show-options -g | grep resurrect-processes
# expect to see your extended list

# Force a save + restore cycle without losing real sessions:
tmux run-shell ~/.tmux/plugins/tmux-resurrect/scripts/save.sh
# (do NOT run restore.sh from a live session — it spawns NEW panes for
# every saved pane on top of your current state)

# Inspect the latest save file to confirm the agent commands were captured:
ls -t ~/.local/share/tmux/resurrect/last 2>/dev/null \
  || ls -t ~/.tmux/resurrect/last
cat $(readlink ~/.local/share/tmux/resurrect/last 2>/dev/null \
  || readlink ~/.tmux/resurrect/last) | grep -E 'opencode|claude'
```

The real verification is to `tmux kill-server` and reattach — but obviously
only do that when you've finished work you care about.
