# tmux's next-prompt finds zero A markers even though the zsh precmd hook emits OSC 133 A

**Symptoms** (grep this section): `tmux send-keys -X next-prompt` doesn't move the cursor, `tmux send-keys -X previous-prompt` cursor stuck at bottom, `previous-prompt -o` works (C markers detected) but `previous-prompt` does nothing (A markers missing), shell-function cpout/cpcmd/cpblock returns 1 byte or empty selection, OSC 133 A marker "emits" from precmd but tmux's line-attr tracking has no A lines, `tmux capture-pane -pe -S -` does not re-emit OSC 133 bytes (tmux consumes them), prefix + M-y and prefix + M-i bindings work but their shell-function equivalents don't.

**First seen**: 2026-04 (building shell-level cpout/cpcmd/cpblock helpers on top of OSC 133 shell integration)
**Affects**: zsh + starship + tmux combo, all tmux versions tested (3.5 / 3.6a). Likely affects any prompt that uses ZLE cursor management after precmd.
**Status**: workaround documented — embed A in `$PROMPT` via `%{...%}` instead of printf'ing from precmd.

## Symptom

Shell integration hook looks correct:

```zsh
_osc133_precmd() {
  local ec=$?
  printf '\e]133;D;%s\a\e]133;A\a' "$ec"   # ← A is sent here
}
_osc133_preexec() {
  printf '\e]133;C\a'                        # ← C is sent here
}
add-zsh-hook precmd _osc133_precmd
add-zsh-hook preexec _osc133_preexec
```

Hook verified loaded: `echo $precmd_functions | grep osc133` → `_osc133_precmd`. Commands run fine, prompt renders. But:

```sh
# Enter copy-mode, go to bottom, then navigate backward:
tmux copy-mode
tmux send-keys -X history-bottom                    # cursor at (0,19)
tmux send-keys -X previous-prompt                   # A marker search
tmux display-message -p '#{copy_cursor_x},#{copy_cursor_y}'
# (0,19) — DIDN'T MOVE. No A markers found in scrollback.

# Same pane, same moment, C markers DO work:
tmux send-keys -X previous-prompt -o                # C marker search
tmux display-message -p '#{copy_cursor_x},#{copy_cursor_y}'
# (0,14) — jumped backward to a C marker. Next: (0,10), (0,5), stop.
```

The C markers from preexec work; the A markers from precmd are invisible to tmux.

## Root cause

Between precmd returning and the prompt painting, zsh's line editor (ZLE) performs cursor-positioning operations (cursor-save, cursor-move, redraw) that desynchronise tmux's OSC 133 line-attr tracking from the final rendered position of the prompt. The A marker is parsed by tmux, but the line attribute gets attached to a transient cursor position (during ZLE's internal redraw) rather than the line where the prompt ends up. When ZLE later moves the cursor to render the prompt, the line that visually contains the prompt has no A attribute.

C markers don't hit this because preexec runs AFTER the user pressed Enter — cursor is already at col 0 of a new line, ZLE isn't about to move it, the C attribute sticks where expected.

Note: `tmux capture-pane -pe -S -` does NOT re-emit OSC 133 bytes either (tmux consumes them as internal state, only propagates the line attributes), so grepping scrollback for `\e]133` always returns zero — doesn't mean the markers were never emitted, doesn't help diagnose this.

## Workaround

Embed the A marker in `$PROMPT` via zsh's `%{...%}` non-printing escape, so it renders at the exact spatial location where the prompt starts — bypassing ZLE's cursor-management timing entirely.

```zsh
_osc133_precmd() {
  local ec=$?
  # Wrap the (already-rendered-by-starship) PROMPT with D + A markers via
  # %{...%} (zero-width). Runs AFTER starship because add-zsh-hook chains
  # in registration order and this file loads after 01_starship.zsh.
  PROMPT=$'%{\e]133;D;'"${ec}"$';\a\e]133;A\a%}'"${PROMPT}"
}

_osc133_preexec() {
  printf '\e]133;C\a'   # C via printf still works
}

add-zsh-hook precmd _osc133_precmd
add-zsh-hook preexec _osc133_preexec
```

The `$'...'` form is required so `\e` and `\a` become real ESC/BEL bytes at zsh parse time. The `%{...%}` wrapping tells zsh the contents take zero display cells, so prompt width math (cursor positioning, redraw) stays correct.

This also works cleanly with starship because starship OVERWRITES `$PROMPT` each precmd — our subsequent wrap doesn't accumulate across iterations.

## Prevention

When adding OSC 133-style shell-integration markers that are supposed to be tmux-navigation targets:

- Markers that need to land on the **prompt line** (A, B): embed in `$PROMPT` via `%{...%}`, not printf from precmd.
- Markers that need to land on the **output line** (C): printf from preexec works (cursor is already at the output's starting row when preexec runs).
- Markers that are **purely informational** (D with exit code): printf from precmd is fine IF nothing navigates to them. tmux's `next-prompt`/`previous-prompt` ignore D.

Test by running 2–3 commands, entering copy-mode, and calling `tmux send-keys -X previous-prompt` from the bottom. If the cursor doesn't move, the A markers aren't being stored even if the raw bytes were emitted.

## Related

- [`docs/tools/tmux/README.md`](../docs/tools/tmux/README.md#osc-133-command-boundary-navigation-warp-style) — user-facing explanation of the A/C navigation
- [`dot_config/zsh/tools/02_shell_integration.zsh`](../dot_config/zsh/tools/02_shell_integration.zsh) — current hook implementation (post-workaround)
- [`dot_config/zsh/tools/03_tmux_capture.zsh`](../dot_config/zsh/tools/03_tmux_capture.zsh) — cpout/cpcmd/cpblock helpers that depend on the markers working
- [FreeDesktop OSC 133 spec](https://gitlab.freedesktop.org/Per_Bothner/specifications/blob/master/proposals/semantic-prompts.md) — official protocol
- Similar workaround upstream: [iTerm2's shell integration](https://iterm2.com/documentation-shell-integration.html) embeds OSC 133 in PS1, not via precmd printf — for the same reason.
