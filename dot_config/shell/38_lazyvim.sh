# 38_lazyvim.sh - LazyVim / Neovim plugin management aliases (shared bash + zsh).
# Moved from dot_config/zsh/tools/38_lazyvim.zsh; file already used only
# POSIX-portable constructs.
#
# All commands run nvim in headless mode and exit, so they can be chained
# in scripts or used in CI. Output is piped through `tail` to keep the
# terminal clean (nvim headless mode produces a lot of redraw noise).
#
# Usage examples:
#   lazy-update                  # update all plugins
#   lazy-update snacks.nvim      # update a single plugin
#   mason-install lua-language-server stylua
#   nvim-rollback                # restore plugins from lazy-lock.json

command -v nvim &>/dev/null || return 0

# --- Internal helper -------------------------------------------------------
# Run a sequence of nvim ex-commands headlessly and trim noisy output.
# Usage: _nvim_headless "<cmd1>" "<cmd2>" ...
_nvim_headless() {
  local args=()
  local cmd
  for cmd in "$@"; do
    args+=("+${cmd}")
  done
  args+=("+qa")
  nvim --headless "${args[@]}" 2>&1 | tail -40
}

# --- Lazy.nvim (plugin manager) -------------------------------------------

# Update plugins. With no args: update all. With args: update specific plugins.
#   lazy-update
#   lazy-update snacks.nvim telescope.nvim
lazy-update() {
  if [[ $# -eq 0 ]]; then
    _nvim_headless "Lazy! sync"
  else
    _nvim_headless "Lazy! update $*"
  fi
}

# Check which plugins have updates available (no install).
alias lazy-check='_nvim_headless "Lazy! check"'

# Install missing plugins (e.g., after editing config to add a new one).
alias lazy-install='_nvim_headless "Lazy! install"'

# Remove plugins that are no longer in your config.
alias lazy-clean='_nvim_headless "Lazy! clean"'

# Restore all plugins to the versions pinned in lazy-lock.json.
# Useful for rolling back after a bad update.
alias lazy-restore='_nvim_headless "Lazy! restore"'

# Build plugins that have a build step (e.g., telescope-fzf-native).
alias lazy-build='_nvim_headless "Lazy! build"'

# Show plugin load times. Opens interactively (not headless).
alias lazy-profile='nvim "+Lazy profile"'

# Open the Lazy UI interactively.
alias lazy='nvim "+Lazy"'

# --- Mason (LSP / formatter / linter manager) ------------------------------

# Update all Mason packages.
alias mason-update='_nvim_headless "MasonUpdate"'

# Install one or more Mason packages.
#   mason-install lua-language-server stylua
mason-install() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: mason-install <package> [<package> ...]" >&2
    echo "Example: mason-install lua-language-server stylua" >&2
    return 1
  fi
  _nvim_headless "MasonInstall $*"
}

# Uninstall Mason packages.
mason-uninstall() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: mason-uninstall <package> [<package> ...]" >&2
    return 1
  fi
  _nvim_headless "MasonUninstall $*"
}

# Open Mason UI interactively.
alias mason='nvim "+Mason"'

# Open Mason log (useful when an install fails).
alias mason-log='nvim "+MasonLog"'

# --- Treesitter ------------------------------------------------------------

# Update all installed Treesitter parsers.
alias treesitter-update='_nvim_headless "TSUpdateSync"'

# Install Treesitter parsers for specific languages.
#   treesitter-install python rust go
treesitter-install() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: treesitter-install <language> [<language> ...]" >&2
    return 1
  fi
  local lang
  for lang in "$@"; do
    _nvim_headless "TSInstallSync! $lang"
  done
}

# --- Health & diagnostics --------------------------------------------------

# Run :checkhealth (interactive — output is too rich for headless).
alias nvim-health='nvim "+checkhealth"'

# Print Neovim version + build info.
alias nvim-version='nvim --version | head -10'

# Run a fresh nvim with NO plugins / NO config (debugging baseline).
alias nvim-clean-startup='nvim --clean'

# Tail the LSP log file.
alias nvim-lsp-log='tail -f "${XDG_STATE_HOME:-$HOME/.local/state}/nvim/lsp.log"'

# --- Cache / state management ---------------------------------------------

# Show how much disk Neovim's plugin & state dirs are using.
nvim-disk-usage() {
  local share="${XDG_DATA_HOME:-$HOME/.local/share}/nvim"
  local state="${XDG_STATE_HOME:-$HOME/.local/state}/nvim"
  local cache="${XDG_CACHE_HOME:-$HOME/.cache}/nvim"
  echo "Neovim disk usage:"
  local dir
  for dir in "$share" "$state" "$cache"; do
    if [[ -d "$dir" ]]; then
      printf "  %-60s %s\n" "$dir" "$(du -sh "$dir" 2>/dev/null | awk '{print $1}')"
    fi
  done
}

# Nuclear option: remove plugin install dir + state. Config is untouched.
# Will prompt for confirmation. After running, next `nvim` will reinstall everything.
nvim-reset-plugins() {
  local share="${XDG_DATA_HOME:-$HOME/.local/share}/nvim"
  local state="${XDG_STATE_HOME:-$HOME/.local/state}/nvim"
  echo "This will delete:"
  echo "  $share"
  echo "  $state"
  echo "Your config (~/.config/nvim) will NOT be touched."
  printf "Continue? [y/N] "
  local confirm
  read -r confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborted."
    return 1
  fi
  rm -rf "$share" "$state"
  echo "Done. Run \`nvim\` to reinstall plugins."
}

# --- Quick access ----------------------------------------------------------

# Jump to nvim config dir (chezmoi-aware: edits source if config is managed).
nvim-config-cd() {
  cd "${XDG_CONFIG_HOME:-$HOME/.config}/nvim"
}
