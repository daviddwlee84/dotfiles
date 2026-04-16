# Custom Aliases & Shell Functions

Quick reference for custom aliases and shell functions defined in this dotfiles repo.

> **Maintenance rule** (mirrored in `CLAUDE.md`): whenever you add or modify a custom alias or shell function, update this table — include the type, source file (relative to repo root), and a brief description.

## Reference Table

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `v` | alias | `dot_config/zsh/10_aliases.zsh` | Open Neovim (`nvim`) |
| `zsh-profile` | alias | `dot_config/zsh/10_aliases.zsh` | Profile zsh startup time |
| `load-nvm` | alias | `dot_config/zsh/10_aliases.zsh` | Lazy-load NVM for the current session |
| `bw-update-completion` | alias | `dot_config/zsh/10_aliases.zsh` | Regenerate cached Bitwarden zsh completion |
| `ghostty-ssh-terminfo` | function | `dot_config/zsh/10_aliases.zsh` | Install xterm-ghostty terminfo on a remote host over SSH |
| `gcam` | function | `dot_config/zsh/10_aliases.zsh` | `git add -A && git commit -m "<msg>"` |
| `gca` | alias | `dot_config/zsh/10_aliases.zsh` | `git commit --amend --no-edit` (keep existing message) |
| `gcam-amend` | function | `dot_config/zsh/10_aliases.zsh` | `git commit --amend -m "<msg>"` (replace message) |
| `gundo` | function | `dot_config/zsh/10_aliases.zsh` | Undo last commit → back to staged; prints undone commit message |
| `lg` | alias | `dot_config/zsh/tools/37_lazygit.zsh` | Open lazygit TUI |
| `ghget` | function | `dot_config/zsh/tools/41_github.zsh` | Download a subdirectory from a GitHub tree URL |
