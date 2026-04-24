# OSC 133 shell integration — emits prompt/command markers so tmux can
# navigate command boundaries (next-prompt / previous-prompt in copy-mode)
# and the prefix + M-y binding in dot_config/tmux/keybindings.conf can
# copy the last command's output (Warp-style).
#
# Protocol: https://gitlab.freedesktop.org/Per_Bothner/specifications/blob/master/proposals/semantic-prompts.md
#
#   OSC 133 ; A ST             before prompt (start of prompt)
#   OSC 133 ; B ST             between prompt and command input (end of prompt)
#   OSC 133 ; C ST             after Enter, before command output (start of output)
#   OSC 133 ; D ; exit_code ST after command finishes (end of output)
#
# Uses add-zsh-hook so it chains cleanly after starship / zsh-vi-mode / oh-my-zsh
# (they all also use add-zsh-hook — no clobbering).
#
# Opt-out: export DISABLE_OSC133=1 before starting zsh.

[[ -n "$DISABLE_OSC133" ]] && return
[[ "$TERM" == "dumb" ]] && return

autoload -Uz add-zsh-hook

_osc133_precmd() {
  local ec=$?
  # Wrap the (already-rendered-by-starship) PROMPT with D + A markers using
  # %{...%} so zsh treats them as zero-width. This runs AFTER starship's
  # own precmd (add-zsh-hook chains in registration order; 01_starship.zsh
  # loads before 02_shell_integration.zsh).
  #
  # Why in PROMPT, not printf? An earlier version printf'd A from precmd
  # directly. tmux's OSC 133 line-attr tracking was unreliable — ZLE's
  # cursor management between precmd and prompt-paint caused the A flag
  # to land on the wrong grid line (next-prompt navigation found zero A
  # markers even though the bytes were sent). Embedding via PROMPT
  # guarantees the markers render at the exact spatial location tmux
  # expects (start of the prompt line).
  #
  # D marker carries the previous command's exit code; A marks start of
  # new prompt. Neither is strictly required for next-prompt/previous-prompt
  # navigation (A is, D isn't), but both are cheap.
  PROMPT=$'%{\e]133;D;'"${ec}"$';\a\e]133;A\a%}'"${PROMPT}"
}

_osc133_preexec() {
  # Skip C for our own tmux capture helpers — otherwise their copy-mode
  # `previous-prompt -o` chain lands on their own (empty) output start
  # instead of the previous command's real output. Coupling is documented
  # in 03_tmux_capture.zsh.
  case "${1%% *}" in
    cpout|cpcmd|cpblock) return ;;
  esac
  # C: start of command output (Enter was just pressed, before exec).
  printf '\e]133;C\a'
}

add-zsh-hook precmd _osc133_precmd
add-zsh-hook preexec _osc133_preexec

# B (end-of-prompt marker) would naturally append to PROMPT tail. tmux's
# next-prompt / previous-prompt only needs A and C, so we skip B. Revisit if
# a future consumer (Ghostty semantic shell integration, Warp) requires it.
