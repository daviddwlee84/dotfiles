# tmux Scrollback × Coding-Agent TUI + Warp-like Copy-Last-Output

## Context

Two UX papercuts surface when running coding agents (Claude Code, OpenCode, Codex, Aider) inside tmux on this repo:

1. **Scrollback looks "broken" while a TUI is running.** Streaming agents repaint the same region with ANSI sequences. On the **main screen** (not alt-screen), tmux captures each frame into history, producing ghost/duplicated lines that are jarring compared to running the same agent in a native terminal. Partly fundamental to ANSI redraw + scrollback, but one tmux option (`scroll-on-clear off`) + a known workflow (`prefix + [` freeze + wheel) takes most of the sting out.

2. **No Warp-like "copy last command output".** The repo already has `prefix + y/Y/C-y` for capture-pane helpers, but nothing that bounds a copy to the last shell command. Requires OSC 133 prompt markers that zsh+starship doesn't currently emit. Once markers exist, tmux 3.4+ gets `next-prompt`/`previous-prompt` navigation for free, plus a one-keybind "yank last output" becomes a 5-line copy-mode macro.

**Intended outcome**: smoother tmux scrolling around agent panes, plus Warp-style command-boundary navigation and a `prefix + M-y` for "copy last output". All additive — existing bindings and agent behaviour unchanged.

---

## Design decisions

Confirmed with user:

- **OSC 133 source**: manual zsh precmd/preexec hook in a new `dot_config/zsh/tools/02_shell_integration.zsh`. Framework-agnostic; works in Ghostty / cmux / SSH-to-any-remote; opt-out via `DISABLE_OSC133=1`.
- **Pitfall doc**: yes — new `pitfalls/tmux-scrollback-tui-repaint-ghosting.md` (symptom-titled, per `project-knowledge-harness` convention).
- **Copy-last-output key**: `prefix + M-y`, extending the `prefix + y/Y/C-y` capture family. M-namespace is free (only fine-resize `M-h/j/k/l` use it).

Skipped (considered, not doing):

- **Bumping `history-limit`** — already 50000 at `dot_config/tmux/common.conf:71`, plenty.
- **Changing `alternate-screen`** — default on; correct for curses apps. Claude Code uses alt-screen so its paint cycles don't pollute scrollback at all.
- **New menu submenu entry** for these bindings — copy-mode navigation is power-user territory, documenting in `docs/tools/tmux/keybindings.md` is enough.
- **Wait for Starship native OSC 133** — feature request still open upstream; hook is 15 lines and we can delete it if/when Starship ships native.

---

## Files to modify

### 1. `dot_config/tmux/common.conf` (~line 71 area)

Add one option after `history-limit`:

```tmux
# Don't push the pre-clear screen contents into scrollback when a TUI issues a
# full-screen clear (ED). Streaming coding agents (Claude Code, OpenCode, etc.)
# that run on the main screen (not alternate-screen) otherwise leave ghost
# frames in history every repaint. Alt-screen apps (vim, htop) are unaffected.
# Default in tmux 3.3+ is `on`; we explicitly turn it off for cleaner scrollback.
# See pitfalls/tmux-scrollback-tui-repaint-ghosting.md.
set -g scroll-on-clear off
```

### 2. `dot_config/tmux/keybindings.conf`

**Add below the existing `bind -T copy-mode-vi DoubleClick1Pane ...` block (around line 103), before the "Capture Pane Helpers" section:**

```tmux
# -----------------------------------------------------------------------------
# Command-boundary navigation in copy-mode (requires OSC 133 markers from shell
# — emitted by dot_config/zsh/tools/02_shell_integration.zsh). In a plain shell
# (no markers, e.g. `sh`, `bash` without our hook, or `DISABLE_OSC133=1`),
# these keys become no-ops. tmux 3.4+ required for next-prompt/previous-prompt;
# `-o` variant (jump to output start, not prompt start) is tmux 3.5+.
#
#   {  / }    previous/next prompt (prompt line)
#   M-[ / M-] previous/next output (the line AFTER the prompt — usually what
#             you want for "skip to the output of the previous command")
# -----------------------------------------------------------------------------
bind -T copy-mode-vi '{' send-keys -X previous-prompt
bind -T copy-mode-vi '}' send-keys -X next-prompt
bind -T copy-mode-vi M-[ send-keys -X previous-prompt -o
bind -T copy-mode-vi M-] send-keys -X next-prompt -o
```

**Add to the "Capture Pane Helpers" section (after the existing `bind C-y ...` at line 122):**

```tmux
# prefix + M-y: copy the LAST command's output to clipboard (Warp-style).
# Uses OSC 133 markers — if the shell doesn't emit them, selection ends up
# empty and tmux displays "Empty selection" harmlessly. Implementation:
# enter copy-mode, jump to start of previous command's output, start selection,
# jump forward to the next prompt, copy, exit copy-mode.
bind M-y copy-mode \; \
  send-keys -X previous-prompt -o \; \
  send-keys -X begin-selection \; \
  send-keys -X next-prompt \; \
  send-keys -X copy-pipe-and-cancel "tmux load-buffer -w -" \; \
  display-message "Last command output copied to clipboard"
```

### 3. `dot_config/zsh/tools/02_shell_integration.zsh` (NEW file)

Numbered `02_` so it loads after `01_starship.zsh` (starship needs to finish `eval "$(starship init zsh)"` first — starship installs its own precmd that we chain after via `add-zsh-hook`).

```zsh
# OSC 133 shell integration — emits prompt/command markers so tmux can
# navigate command boundaries (next-prompt / previous-prompt in copy-mode)
# and our prefix + M-y binding can copy the last command's output.
#
# Protocol reference: https://gitlab.freedesktop.org/Per_Bothner/specifications/blob/master/proposals/semantic-prompts.md
#
#   OSC 133 ; A ST   before prompt (start of prompt)
#   OSC 133 ; B ST   between prompt and command input (end of prompt)
#   OSC 133 ; C ST   after Enter, before command output (start of output)
#   OSC 133 ; D ; exit_code ST   after command finishes (end of output)
#
# Uses add-zsh-hook to chain after starship / zsh-vi-mode / oh-my-zsh hooks
# (they all also use add-zsh-hook — no conflict).
#
# Opt-out: export DISABLE_OSC133=1 before shell start.

[[ -n "$DISABLE_OSC133" ]] && return
[[ "$TERM" == "dumb" ]] && return

autoload -Uz add-zsh-hook

_osc133_precmd() {
  local ec=$?
  # D: end of previous command's output (with exit code); A: start of new prompt
  printf '\e]133;D;%s\a\e]133;A\a' "$ec"
}

_osc133_preexec() {
  # C: start of command output (Enter was just pressed)
  printf '\e]133;C\a'
}

add-zsh-hook precmd _osc133_precmd
add-zsh-hook preexec _osc133_preexec

# B (end-of-prompt marker) is conventionally printed at the tail of PS1.
# Starship renders the whole prompt via its own mechanism, so we prepend
# the B marker to RPROMPT's LHS via PROMPT_EOL_MARK? No — the cleanest
# place is `precmd_functions` right before starship's hook emits its
# prompt. But because starship uses `precmd` too, and add-zsh-hook runs
# them in registration order, starship's hook fires after ours -> our
# "A" lands before starship paints and our "B" would need to land after.
# Workaround: append B to PS1 via a widget. Since tmux's next-prompt /
# previous-prompt only needs A and C markers (B is optional per the
# protocol), we skip B for now. If a future consumer (e.g. Ghostty
# semantic shell integration) requires B, revisit with a zle-line-init
# approach.
```

### 4. `docs/tools/tmux/README.md`

Add a new section after "OSC 52 Clipboard" (the current OSC section):

```markdown
## Scrollback & Coding Agents

Streaming TUIs (Claude Code, OpenCode, Codex) repaint the same screen region via
ANSI sequences. On the **alternate screen** (vim, htop) tmux's scrollback is
unaffected. On the **main screen** (some coding agents), every frame gets
pushed into history by default, producing ghost/duplicated lines.

Two settings and one workflow keep this clean:

- `set -g scroll-on-clear off` (in `common.conf`) — discards pre-clear contents
  instead of pushing them into history on full-screen clear.
- `history-limit 50000` — already set; 50k lines is plenty even for a full day
  of agent sessions.
- **Freeze before scrolling**: `prefix + [` enters copy-mode, which snapshots
  the current frame. Scroll the wheel or use `C-u`/`C-d` without the UI
  continuing to repaint under you. `q` exits.

For a pitfall-level description of why this can't be "fixed" further (ANSI
redraw + linear scrollback is fundamentally lossy), see
[pitfalls/tmux-scrollback-tui-repaint-ghosting.md](../../../pitfalls/tmux-scrollback-tui-repaint-ghosting.md).

## OSC 133 Command-Boundary Navigation (Warp-style)

`dot_config/zsh/tools/02_shell_integration.zsh` emits OSC 133 prompt markers
via precmd/preexec. tmux 3.4+ parses them, enabling:

| Key (in copy-mode) | Action |
|---|---|
| `{` | Jump to previous prompt |
| `}` | Jump to next prompt |
| `Alt+[` | Jump to previous command **output** start |
| `Alt+]` | Jump to next command **output** start |

And a top-level shortcut that wraps the above into a one-press copy:

| Key | Action |
|---|---|
| `prefix + M-y` | Copy the **last command's output** to clipboard |

Opt out per shell: `export DISABLE_OSC133=1` before starting zsh. Has no effect
if the remote shell isn't zsh or doesn't source our tools dir (e.g. a bare
`bash` on a production server) — the bindings just become no-ops.
```

### 5. `docs/tools/tmux/keybindings.md`

Add the new bindings to the Copy Mode section (existing table). Match the file's current style — read it first to confirm column headers.

### 6. `pitfalls/tmux-scrollback-tui-repaint-ghosting.md` (NEW)

Following the symptom-first convention from `pitfalls/README.md`:

```markdown
# tmux scrollback shows duplicated / ghost lines while Claude Code / OpenCode runs

**Symptoms** (grep this section): ghost lines in tmux scrollback, repeated
spinner frames in history, scrollback looks "broken" when scrolling up in a
coding-agent pane, tmux history contains dozens of half-repainted copies of
the same prompt

**First seen**: 2026-04 (observed on daily Claude Code / OpenCode workflow)
**Affects**: tmux × any main-screen TUI that repaints via ANSI (some coding
agents, progress bars, live log viewers without `\e[?1049h` alt-screen toggle)
**Status**: mitigated (`scroll-on-clear off` + `prefix + [` workflow);
fundamental limit of ANSI redraw + linear scrollback.

## Symptom

Scrolling up through a pane that ran Claude Code / OpenCode / a long
`cargo build` with live progress shows frames of the TUI stacked like a flipbook
in history. Unlike a native terminal, where the same repaint cycles just
overwrite the visible region and never enter history.

## Root cause

Two-layer issue:

1. **ANSI redraw writes to the main screen.** TUIs that don't enter
   alternate-screen (`\e[?1049h`) repaint by erasing + rewriting the same
   region. Native terminals don't remember erased content; tmux, which
   captures into a scrollback buffer for cursor-up / copy-mode, does.

2. **`scroll-on-clear on` (tmux default).** When a TUI issues a full-screen
   clear before repaint, tmux pushes the pre-clear screen into history
   instead of dropping it, multiplying the problem.

Alt-screen apps (vim, htop, less, most modern TUIs including Claude Code's
interactive sessions) are NOT affected — tmux keeps alt-screen's buffer
separate and doesn't pollute history with repaints.

## Workaround

Applied in this repo:

- `set -g scroll-on-clear off` in `dot_config/tmux/common.conf`.

Manual workflow for inspection:

- `prefix + [` enters copy-mode, which snapshots the current frame. Scroll
  freely with wheel / `C-u` / `C-d` without the UI continuing to repaint
  under you.
- For a clean export of a pane (history + screen), use `prefix + Y` (full
  scrollback to clipboard) or `tmux capture-pane -pS -` on the CLI.

## Prevention

Not really preventable while the TUI runs on the main screen. If you find a
new agent that looks unusually bad, check whether it supports alt-screen
mode (some accept `--alt-screen` / `--tui` flags; otherwise upstream issue).

## Related

- tmux manpage `scroll-on-clear`: "If this option is on, whenever contents are
  cleared from the terminal they are moved into the history."
- `pitfalls/tmux-display-menu-silent-fail.md` — separate tmux redraw gotcha.
- `docs/tools/tmux/README.md` → "Scrollback & Coding Agents" (the positive
  workflow version of this pitfall).
```

---

## Verification

End-to-end sanity checks after `chezmoi apply` and `tmux kill-server && tmux`:

1. **OSC 133 markers emitting**: run `cat -v` after typing a command, then
   look for `^[]133;A^G` / `^[]133;C^G` / `^[]133;D;0^G` escape bytes in the
   output of `tmux capture-pane -pe -S -`. (The `-e` flag preserves escape
   sequences.) If markers are absent, the hook isn't wired.
   ```sh
   echo test; tmux capture-pane -pe -S - | grep -c '\x1b]133'
   # expect: at least 3 matches (A, C, D)
   ```
2. **Copy-mode navigation**: `prefix + [`, then press `{` — cursor should jump
   to the previous prompt line. `M-[` should jump to the OUTPUT start of the
   previous command (one line lower). No-op / unchanged cursor = markers not
   reaching tmux.
3. **Copy-last-output**: run `echo hello && ls` somewhere, then press
   `prefix + M-y`. Paste (⌘V / middle-click / `tmux paste-buffer`) — should
   contain `hello\n<ls output>`. Status line should show "Last command output
   copied to clipboard".
4. **Scrollback sanity**: open a Claude Code / OpenCode session; let it
   stream a long response; `prefix + [` and scroll up — no ghost frames
   from the clear cycles. Compare to the same workflow with
   `tmux set -g scroll-on-clear on` (reverts to the problematic behaviour)
   for a side-by-side.
5. **Opt-out works**: `DISABLE_OSC133=1 zsh` → no markers emitted,
   step 1 returns 0 matches. `prefix + M-y` in such a pane becomes a
   harmless "Empty selection" message.
6. **Coexistence with starship / zsh-vi-mode**: `echo $precmd_functions` —
   should list `_osc133_precmd` alongside starship's and zsh-vi-mode's hooks
   (no clobbering). `tmux new` into a fresh pane, run a few commands, vi-mode
   cursor still changes on ESC, starship prompt still renders.

## Critical files

- `dot_config/tmux/common.conf:71` (history-limit, where `scroll-on-clear` inserts)
- `dot_config/tmux/keybindings.conf:98-103` (copy-mode-vi block, where `{}` bindings go)
- `dot_config/tmux/keybindings.conf:107-122` (capture helpers, where `M-y` goes)
- `dot_config/zsh/tools/01_starship.zsh` (reference — the new `02_` file loads after)
- `docs/tools/tmux/README.md` (existing OSC 52 section to slot in after)
- `docs/tools/tmux/keybindings.md` (copy-mode table)
- `pitfalls/README.md` (format template, already confirmed)
