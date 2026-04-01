<!-- 37699258-71dd-4f49-93b3-c2687cb97bda -->
---
todos:
  - id: "completion"
    content: "Add auto-generating ZSH completion for sesh in 22_sesh.zsh"
    status: pending
  - id: "zsh-widget"
    content: "Upgrade sesh-sessions ZSH widget with icons, preview, multi-source keybindings"
    status: pending
  - id: "tmux-keys"
    content: "Add sesh keybindings to dot_tmux.conf (prefix+T popup, prefix+L last, detach-on-destroy)"
    status: pending
  - id: "sesh-toml"
    content: "Create dot_config/sesh/sesh.toml with default_session, sessions, wildcards, blacklist"
    status: pending
  - id: "docs"
    content: "Create docs/sesh.md with setup guide, integrations, and configuration reference"
    status: pending
  - id: "readme"
    content: "Update README.md to reference sesh config"
    status: pending
isProject: false
---
# Sesh Setup Enhancement

## Current State

- **Installation**: sesh 2.24.2 installed via Homebrew (macOS) / GitHub releases (Linux) in the `devtools` ansible role
- **ZSH integration**: `dot_config/zsh/tools/22_sesh.zsh` has a basic `sesh-sessions` function with fzf, bound to `Ctrl+A`
- **No sesh.toml config** exists (`~/.config/sesh/` does not exist)
- **No sesh shell completion** installed (documented in `docs/zsh/zsh-completions.md` as Category A but not actively generated)
- **tmux.conf**: Uses TPM, tmux-resurrect, tmux-continuum, tmux2k theme; no sesh-specific keybindings
- **fzf** is installed and configured in `10_fzf.zsh`
- **Television (tv)** is NOT installed

## Changes

### 1. Add ZSH shell completion for sesh

File: `dot_config/zsh/tools/22_sesh.zsh`

Add completion generation to `~/.zfunc/_sesh` (consistent with the pattern documented in `docs/zsh/zsh-completions.md`):

```zsh
if [[ ! -f ~/.zfunc/_sesh ]] || [[ $(sesh --version 2>/dev/null) != $(head -c 100 ~/.zfunc/_sesh 2>/dev/null | grep -o 'sesh [0-9.]*' || echo '') ]]; then
    mkdir -p ~/.zfunc
    sesh completion zsh > ~/.zfunc/_sesh 2>/dev/null
fi
```

### 2. Upgrade sesh-sessions ZSH widget

File: `dot_config/zsh/tools/22_sesh.zsh`

Upgrade from the basic fzf picker to the full-featured version from the sesh README, with:
- `--icons` flag for Nerd Font icons
- Session preview via `sesh preview`
- Keybindings to filter by type: `Ctrl+A` (all), `Ctrl+T` (tmux), `Ctrl+G` (configs), `Ctrl+X` (zoxide), `Ctrl+F` (find dirs), `Ctrl+D` (kill session)
- Header showing available keybindings
- Proper TTY handling for ZSH widget context (exec `</dev/tty`)

### 3. Add tmux keybindings for sesh

File: `dot_tmux.conf`

Add a sesh section before TPM initialization:
- `prefix + T`: Open sesh picker in a tmux popup via `fzf-tmux` (the canonical integration from sesh README)
- `prefix + L`: `sesh last` to switch to last session
- `prefix + 9`: `sesh connect --root` to jump to project root
- `set -g detach-on-destroy off`: Don't exit tmux when closing a session
- `bind-key x kill-pane`: Skip the kill-pane confirmation prompt

### 4. Create sesh.toml configuration

File: `dot_config/sesh/sesh.toml` (chezmoi-managed)

Best practices derived from joshmedeski and omerxx dotfiles:

```toml
#:schema https://github.com/joshmedeski/sesh/raw/main/sesh.schema.json

[default_session]
startup_command = "nvim +GoToFile"
preview_command = "eza --all --git --icons --color=always {}"

sort_order = ["tmux", "config", "zoxide"]
dir_length = 2

blacklist = ["^scratch$", "^_"]

[[session]]
name = "dotfiles"
path = "~/.local/share/chezmoi"

[[session]]
name = "neovim config"
path = "~/.config/nvim"

[[session]]
name = "home"
path = "~"
disable_startup_command = true

[[wildcard]]
pattern = "~/repos/*"
startup_command = "nvim"
```

### 5. Create documentation

File: `docs/sesh.md`

Contents:
- What sesh is and why we use it
- How it's installed (ansible devtools role)
- ZSH integration (keybindings, completion)
- tmux integration (keybindings, popup picker)
- sesh.toml configuration guide (sessions, wildcards, default_session, preview/startup commands)
- Integration with other tools (fzf, television cable channel, zoxide)
- Customization tips (add your own sessions, wildcard patterns)

### 6. Update README.md

Add sesh to the appropriate sections noting it as a tmux session manager with fzf integration.

## Files Modified

| File | Action |
|------|--------|
| `dot_config/zsh/tools/22_sesh.zsh` | Update: add completion + upgrade fzf picker |
| `dot_tmux.conf` | Update: add sesh keybindings section |
| `dot_config/sesh/sesh.toml` | Create: sesh configuration |
| `docs/sesh.md` | Create: sesh documentation |
| `README.md` | Update: mention sesh config |
