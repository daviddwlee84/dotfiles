#!/usr/bin/env bats
# Smoke tests intended to run inside the Docker `test` service container
# (see docker-compose.yml). They assert the post-`chezmoi apply` + post-ansible
# state of a fresh Ubuntu box.
#
# Do NOT run these on a host machine — they assume the chezmoi source lives at
# /tmp/dotfiles-source (matches Dockerfile COPY target) and that the container
# has just completed a full install.

load "../test_helper.bash"

SOURCE_DIR="${CHEZMOI_SOURCE_DIR:-/tmp/dotfiles-source}"

@test "chezmoi apply is idempotent (diff is empty after re-apply)" {
  # Re-apply should be a no-op. A non-empty diff means templates drift or
  # run_once state tracking is broken.
  run chezmoi apply
  [ "$status" -eq 0 ]
  run chezmoi diff
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "zsh -n parses ~/.zshrc and ~/.zshenv without errors" {
  [ -f "$HOME/.zshrc" ]
  [ -f "$HOME/.zshenv" ]
  zsh -n "$HOME/.zshrc"
  zsh -n "$HOME/.zshenv"
}

@test "~/.config/zsh exists and every *.zsh file parses cleanly" {
  [ -d "$HOME/.config/zsh" ]
  # Parse every deployed zsh module. A regression here means a syntax error
  # slipped through into the interactive shell path.
  local file failures=0
  while IFS= read -r file; do
    if ! zsh -n "$file" 2>/dev/null; then
      echo "zsh -n failed: $file" >&2
      failures=$((failures + 1))
    fi
  done < <(find "$HOME/.config/zsh" -type f -name '*.zsh')
  [ "$failures" -eq 0 ]
}

@test "neovim is installed and can run a headless lua call" {
  command -v nvim
  run nvim --headless "+lua print('ok')" +qa
  [ "$status" -eq 0 ]
}

@test "~/.config/nvim exists and init file is present" {
  [ -d "$HOME/.config/nvim" ]
  [ -f "$HOME/.config/nvim/init.lua" ] || [ -f "$HOME/.config/nvim/init.vim" ]
}

@test "core CLI tools are on PATH" {
  # These are the tools a user would notice missing. Not an exhaustive list.
  for cmd in nvim rg fd fzf zsh just bats; do
    command -v "$cmd" || {
      echo "missing on PATH: $cmd" >&2
      return 1
    }
  done
}

@test "oh-my-zsh plugins are installed" {
  local omz="$HOME/.oh-my-zsh/custom/plugins"
  [ -d "$omz/zsh-autosuggestions" ]
  [ -d "$omz/zsh-syntax-highlighting" ]
  [ -d "$omz/zsh-completions" ]
}

@test "unit tests pass in-container (zsh_proxy.bats under installed zsh)" {
  # Re-run the host unit tests inside the container. Catches regressions where
  # a zsh feature we rely on works on macOS but not on the Ubuntu-shipped zsh.
  [ -f "$SOURCE_DIR/tests/unit/zsh_proxy.bats" ]
  run bats "$SOURCE_DIR/tests/unit/zsh_proxy.bats"
  [ "$status" -eq 0 ]
}
