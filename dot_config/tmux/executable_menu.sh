#!/usr/bin/env bash
# Top-level tmux popup menu — invoked by `prefix + Space`.
#
# Why a script (not inline `display-menu` in keybindings.conf):
#   1. tmux's command parser stops at literal `;`, `{`, `}` even inside
#      nested quotes. With ~50 menu rows full of fzf binds and shell
#      one-liners, escaping became fragile and broke silently.
#   2. tmux `display-menu` does not paginate. If the menu is taller than
#      the terminal, the entire popup is suppressed with no error. By
#      generating the menu here we can read $TMUX client_height and
#      auto-trim low-frequency rows when small.
#   3. Submenus are normal `tmux display-menu` invocations from rows;
#      they don't share quoting context with the parent menu.
#
# Submenus live in sibling scripts:
#   menu-layouts.sh, menu-session.sh, menu-sesh.sh,
#   menu-popups.sh, menu-theme.sh, menu-system.sh, menu-agents.sh
#
# See: pitfalls/tmux-display-menu-silent-parse-failure.md

set -euo pipefail

H=$(tmux display-message -p '#{client_height}')
DIR=~/.config/tmux

# Tier 0: ALWAYS shown (highest frequency, ~7 rows + 2 separators)
declare -a tier0=(
  "Last window"  Tab "last-window"
  "Last pane"    P   "last-pane"
  ""             ""  ""
  "Choose win"   w   "choose-tree -Zw"
  "Choose sess"  s   "choose-tree -Zs"
  "Pane #s"      q   "display-panes -d 0"
  ""             ""  ""
  "Sesh picker"  g   "run-shell '$DIR/sesh-picker.sh'"
  "Lazygit"      G   "display-popup -E -w 90% -h 90% -d '#{pane_current_path}' -T ' lazygit ' 'lazygit'"
)

# Tier 1: shown when height >= 22 (adds new-window/split/zoom)
declare -a tier1=(
  ""             ""  ""
  "New window"   c   "new-window -c '#{pane_current_path}'"
  "Split |"      "|" "split-window -h -c '#{pane_current_path}'"
  "Split -"      "-" "split-window -v -c '#{pane_current_path}'"
  "Zoom"         z   "resize-pane -Z"
)

# Tier 2: submenus + cheatsheet (always shown if Tier 1 is shown)
declare -a tier2=(
  ""             ""  ""
  "→ Layouts"    L   "run-shell '$DIR/menu-layouts.sh'"
  "→ Session"    S   "run-shell '$DIR/menu-session.sh'"
  "→ Sesh+"      E   "run-shell '$DIR/menu-sesh.sh'"
  "→ Agents"     A   "run-shell '$DIR/menu-agents.sh'"
  "→ Popups"     o   "run-shell '$DIR/menu-popups.sh'"
  "→ Theme"      T   "run-shell '$DIR/menu-theme.sh'"
  "→ System"     Y   "run-shell '$DIR/menu-system.sh'"
  ""             ""  ""
  "Cheatsheet"   "?" "display-popup -E -w 80% -h 80% -T ' tmux cheatsheet ' 'glow -p $DIR/cheatsheet.md 2>/dev/null || less $DIR/cheatsheet.md'"
  "Search keys"  "/" "run-shell -b ~/.tmux/plugins/tmux-fzf/scripts/keybinding.sh"
)

rows=("${tier0[@]}")
if [ "$H" -ge 22 ]; then
  rows+=("${tier1[@]}" "${tier2[@]}")
elif [ "$H" -ge 14 ]; then
  rows+=("${tier2[@]}")
fi

exec tmux display-menu -T "#[align=centre,bold]tmux (h=$H)" -x R -y P "${rows[@]}"
