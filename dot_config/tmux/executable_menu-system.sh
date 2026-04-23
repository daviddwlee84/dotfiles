#!/usr/bin/env bash
# System / plugin management submenu
set -euo pipefail
exec tmux display-menu -T " System " -x R -y P \
  "Reload config"     R "run-shell 'tmux source-file ~/.tmux.conf && tmux display-message Sourced'" \
  "Install plugins"   I "run-shell '~/.tmux/plugins/tpm/bindings/install_plugins'" \
  "Update plugins"    U "run-shell '~/.tmux/plugins/tpm/bindings/update_plugins'" \
  "" "" "" \
  "Detach"            d "detach-client" \
  "Clock"             k "clock-mode"
