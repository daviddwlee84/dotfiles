# TODO

Future enhancements for the dotfiles repository.

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
