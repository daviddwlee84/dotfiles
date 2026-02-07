# TODO

Future enhancements for the dotfiles repository.

## LazyVim v8 Incremental Restore (2026-02-07)

Gradual restore from backup at `backups/nvim-20260206-223408` to reduce behavior churn.

### Restored

- [x] `dot_config/nvim/lua/plugins/dashboard.lua`
- [x] `dot_config/nvim/lua/plugins/gitsigns.lua`
- [x] `dot_config/nvim/lua/plugins/mini-surround.lua`
- [x] `dot_config/nvim/lua/plugins/vim-visual-multi.lua`
- [x] `dot_config/nvim/lua/plugins/wakatime.lua`

### Deferred (review before restore)

- [ ] `dot_config/nvim/lua/plugins/avante.lua` (avoid conflict with `lazyvim.plugins.extras.ai.avante`)
- [ ] `dot_config/nvim/lua/plugins/diffview.lua` (`command` key typo and undefined `is_git_root`)
- [ ] `dot_config/nvim/lua/plugins/nvim-cmp.lua` (changes `<Tab>` completion behavior globally)
- [ ] `dot_config/nvim/lua/plugins/noice-fix.lua` (UI behavior override)
- [ ] `dot_config/nvim/lua/plugins/sqlit-float.lua` + `lua/sqlit_float/*` (local plugin path, higher maintenance)
- [ ] `dot_config/nvim/lua/plugins/colorscheme.lua` (currently disabled/commented block)

### Notes

- Current explorer is Snacks, not Neo-tree. `x` cut is not a default mapping in Snacks explorer.

## Zsh Configuration

| Item | Notes |
|------|-------|
| conda/mamba init | Needs ansible role for miniforge/conda |
| NVM setup | Needs ansible role for nvm |
| Yazi y() function | Needs ansible role for yazi |
| BUN, pnpm, cargo PATH | Needs ansible roles for these tools |
| Go PATH | Needs ansible role for Go |
| TA-Lib paths | Machine-specific, keep in secrets.zsh |
| Try/Toolkami | Custom tools, keep in secrets.zsh |
| alias cc, readelf, ccusage | These depend on specstory/binutils |
| secrets.zsh encryption | Future: encrypt with age |

## Ansible Roles to Add

- [ ] miniforge/conda
- [ ] nvm (Node Version Manager)
- [ ] yazi (terminal file manager)
- [ ] bun (JavaScript runtime)
- [ ] pnpm (package manager)
- [ ] rust/cargo
- [ ] go

---

Fix Claude Code hook on Ubuntu `Stop hook error: Failed with non-blocking status code: GDBus.Error:org.freedesktop.DBus.Error.ServiceUnknown: The name org.freedesktop.Notifications was not provided by any .service files`

Use mise to manage most of the runtime version?!

Optimize zsh & tmux startup time

~Do we want to use Brewfile to manage macOS packages installation instead of writing one by one through Ansible?~ **Done**: XDG-compliant Brewfiles at `~/.config/homebrew/` with chezmoi run_onchange script (opt-in via `installBrewApps`).
