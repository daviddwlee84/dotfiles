#!/usr/bin/env bash
# Coding-agent submenu — discovery + management of live agent sessions.
#
# Reached from the top popup menu (prefix + Space → → Agents). The two `tv`
# entries are the primary surfaces; recon is offered only when installed.
#
# See: docs/tools/agent-panes-discovery.md
set -euo pipefail

declare -a rows=(
  "Live agent panes (tv)"     a "display-popup -E -w 80% -h 70% -d '#{pane_current_path}' -T ' Live agent panes ' 'tv agent-panes'"
  "Quota wakeup (tv)"         w "display-popup -E -w 88% -h 75% -d '#{pane_current_path}' -T ' Agent wakeup ' 'tv agent-wakeup'"
  "Stored sessions (tv)"      s "display-popup -E -w 80% -h 70% -d '#{pane_current_path}' -T ' Agent sessions ' 'tv agent-sessions'"
)

# recon is Claude-only and optional (cargo install). Probe before adding the
# row so the menu doesn't show a dead entry on hosts that haven't installed it.
if command -v recon >/dev/null 2>&1; then
  rows+=(
    ""                        ""  ""
    "Claude dashboard (recon)" r  "display-popup -E -w 80% -h 60% -T ' recon (Claude) ' 'recon'"
  )
fi

exec tmux display-menu -T " Agents " -x R -y P "${rows[@]}"
