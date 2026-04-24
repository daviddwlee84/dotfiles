# tmux + OSC 133 capture helpers — shell-level counterparts of the
# prefix + M-y / M-i tmux bindings.
#
#   cpcmd    last command's INPUT  (zsh history; works inside OR outside tmux)
#   cpout    last command's OUTPUT (tmux copy-mode chain; tmux-only)
#   cpblock  last command's FULL BLOCK, Warp-style (tmux-only)
#
# Each prints captured text to stdout (pipe-friendly: `cpout | grep ERROR`)
# AND copies to system clipboard. Diagnostic + byte count go to stderr so
# stdout stays clean for pipes.
#
# WHY cpout/cpblock need tmux:
# tmux consumes OSC 133 marker bytes and only stores them as per-line
# attributes in its grid — `tmux capture-pane -pe` does NOT re-emit them.
# Outside tmux there's no portable way to recover boundaries of a past
# command's output (terminals like iTerm2/Ghostty have proprietary APIs,
# but nothing cross-terminal). cpcmd uses zsh shell history instead, so it
# works universally.
#
# Requires: zsh; plus tmux for cpout/cpblock.

# Pipe stdin to system clipboard, preferring tmux's OSC 52 bridge (SSH-safe)
# and falling back to platform-native clipboard tools.
_cpx_to_clipboard() {
  if [[ -n "$TMUX" ]]; then
    tmux load-buffer -w -
  elif command -v pbcopy &>/dev/null; then
    pbcopy
  elif command -v wl-copy &>/dev/null; then
    wl-copy
  elif command -v xclip &>/dev/null; then
    xclip -selection clipboard -in
  elif command -v xsel &>/dev/null; then
    xsel --clipboard --input
  else
    cat >/dev/null
    return 1
  fi
}

# Run a tmux copy-mode selection chain on the current pane. Prints selection
# to stdout, diagnostic (name + byte count) to stderr. Returns 1 on empty.
#
#   _cpx_tmux_select <display-name> <start-cmd> [start-args...]
#
# Chain: copy-mode → <start-cmd> → begin-selection → next-prompt →
#        copy-pipe-and-cancel "tee <tmp> | tmux load-buffer -w -" → wait-for
#
# Depends on 02_shell_integration.zsh skipping the OSC 133 C marker for
# these helpers' own invocation (see the case statement there). Without
# that skip, `previous-prompt -o` would land on this command's own output
# start and the selection would be empty.
_cpx_tmux_select() {
  local name=$1; shift
  local tmp sentinel
  tmp="${TMPDIR:-/tmp}/cpx-$$-$RANDOM"
  sentinel="cpx-$$-$RANDOM"
  : > "$tmp"
  tmux copy-mode -t "$TMUX_PANE" 2>/dev/null || return 1
  tmux send-keys -t "$TMUX_PANE" -X "$@" 2>/dev/null
  tmux send-keys -t "$TMUX_PANE" -X begin-selection 2>/dev/null
  tmux send-keys -t "$TMUX_PANE" -X next-prompt 2>/dev/null
  tmux send-keys -t "$TMUX_PANE" -X copy-pipe-and-cancel \
    "tee $tmp | tmux load-buffer -w - ; tmux wait-for -S $sentinel" 2>/dev/null
  tmux wait-for "$sentinel" 2>/dev/null
  if [[ -s "$tmp" ]]; then
    cat "$tmp"
    local bytes
    bytes=$(wc -c <"$tmp" | tr -d ' ')
    rm -f "$tmp"
    print -u2 "$name: $bytes bytes copied to clipboard"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# cpcmd — last command's INPUT. Universal: reads zsh shell history. Clean
# output (no prompt chrome, no terminal-echo artefacts).
cpcmd() {
  emulate -L zsh
  local cmd
  cmd=$(fc -ln -1 2>/dev/null)
  cmd="${cmd#	}"   # strip fc's leading tab
  cmd="${cmd# }"
  if [[ -z "$cmd" ]]; then
    print -u2 "cpcmd: no previous command in shell history"
    return 1
  fi
  printf '%s\n' "$cmd" | _cpx_to_clipboard || {
    print -u2 "cpcmd: no clipboard tool available (install pbcopy / xclip / xsel / wl-copy, or run inside tmux)"
    return 1
  }
  printf '%s\n' "$cmd"
  print -u2 "cpcmd: ${#cmd} bytes (zsh history) copied to clipboard"
}

# cpout — last command's OUTPUT via tmux's OSC 133 line attrs.
cpout() {
  emulate -L zsh
  if [[ -z "$TMUX" ]]; then
    print -u2 "cpout: requires tmux (OSC 133 boundaries are stored per-pane by tmux). Use cpcmd for input, or your terminal's native 'copy output' if available."
    return 1
  fi
  _cpx_tmux_select cpout previous-prompt -o || {
    print -u2 "cpout: empty — possible causes: (a) shell pre-dates chezmoi apply, run 'exec zsh' (verify: echo \$precmd_functions | grep osc133); (b) no command has been run yet in this pane; (c) previous command is an alt-screen TUI (vim, htop) with no OSC 133 output."
    return 1
  }
}

# cpblock — last command's FULL BLOCK (prompt + input + output), Warp-style.
# The OSC 133 A marker is embedded in PROMPT itself (02_shell_integration.zsh),
# so cpblock's OWN current prompt line has an A marker too — unlike the C
# marker which we can skip in preexec. So we call previous-prompt TWICE to
# skip the current prompt and land on the previous command's prompt.
cpblock() {
  emulate -L zsh
  if [[ -z "$TMUX" ]]; then
    print -u2 "cpblock: requires tmux (see cpout for why)."
    return 1
  fi
  local tmp sentinel
  tmp="${TMPDIR:-/tmp}/cpx-$$-$RANDOM"
  sentinel="cpx-$$-$RANDOM"
  : > "$tmp"
  tmux copy-mode -t "$TMUX_PANE" 2>/dev/null || {
    print -u2 "cpblock: failed to enter copy-mode"
    return 1
  }
  tmux send-keys -t "$TMUX_PANE" -X previous-prompt 2>/dev/null   # lands on cpblock's own A
  tmux send-keys -t "$TMUX_PANE" -X previous-prompt 2>/dev/null   # previous command's A
  tmux send-keys -t "$TMUX_PANE" -X begin-selection 2>/dev/null
  tmux send-keys -t "$TMUX_PANE" -X next-prompt 2>/dev/null       # forward to cpblock's A
  tmux send-keys -t "$TMUX_PANE" -X copy-pipe-and-cancel \
    "tee $tmp | tmux load-buffer -w - ; tmux wait-for -S $sentinel" 2>/dev/null
  tmux wait-for "$sentinel" 2>/dev/null
  if [[ -s "$tmp" ]]; then
    cat "$tmp"
    local bytes
    bytes=$(wc -c <"$tmp" | tr -d ' ')
    rm -f "$tmp"
    print -u2 "cpblock: $bytes bytes copied to clipboard"
    return 0
  fi
  rm -f "$tmp"
  print -u2 "cpblock: empty — run 'exec zsh' if the shell pre-dates chezmoi apply."
  return 1
}
