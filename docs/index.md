# daviddwlee84/dotfiles

Cross-platform development environment setup using [chezmoi](https://www.chezmoi.io/) (config files) + [ansible](https://docs.ansible.com/) (system dependencies), tuned for coding-agent workflows on macOS and Ubuntu.

For the quick-install path, supported platforms table, and the "what do I get" bullet list, read [README.md on GitHub](https://github.com/daviddwlee84/dotfiles/blob/main/README.md) — it's the canonical first stop and deliberately left as the single source of truth (not duplicated into this site).

## Where to read next

### For users adopting a slice

| I want to… | Start here |
|---|---|
| Pipe my shell scrollback through Claude / OpenCode / Codex | [**aicapture**](tools/aicapture.md) |
| Understand the tmux config (popup menu, OSC 133, copy-mode) | [tmux](tools/tmux/README.md) |
| Get tmux keybindings at a glance | [tmux keybindings](tools/tmux/keybindings.md) |
| See every custom zsh alias / function | [zsh aliases](zsh/aliases.md) |
| Sesh session workflow (shere / sroot / scode / svibe) | [sesh](tools/sesh.md) · [workflow playbook](playbooks/workflow.md) |
| Set up the agent CLIs (claude / opencode / codex / cursor) | [agent overlays](tools/agent-overlays.md) |
| Clipboard over SSH (OSC 52, `x copy`, Neovim integration) | [clipboard](tools/clipboard.md) |

### For maintainers

| I want to… | Start here |
|---|---|
| Understand the architecture | [architecture](this_repo/architecture.md) |
| Multi-host apply / `fleet-apply` | [fleet-apply](this_repo/fleet-apply.md) |
| The testing / linting / pre-commit story | [testing](this_repo/testing.md) · [pre-commit](tools/pre-commit.md) |
| Upgrades split from installs | [upgrades](this_repo/upgrades.md) |
| chezmoi conventions (prefixes, templating, scripts layout) | [chezmoi prefixes](tools/chezmoi-prefixes.md) · [chezmoi templating](tools/chezmoi-templating.md) · [chezmoiscripts layout](this_repo/chezmoiscripts-layout.md) |
| The repo's design-space research (why we built what we built) | [instant-LLM-fix prior art](this_repo/instant-llm-fix-prior-art.md) |

### Repo-maintainer surfaces

`TODO.md`, `backlog/`, `pitfalls/`, `CLAUDE.md` — these are agent-facing maintenance surfaces, not user documentation. They're **linked** from the site for discoverability but live at the repo root; see [For Maintainers](for-maintainers.md).

## Trying it without adopting the whole repo

Each tool page that's self-contained (e.g., [aicapture](tools/aicapture.md)) has a "Standalone setup" section with `curl` commands + `~/.zshrc` snippet you can paste into any zsh environment without cloning the whole dotfiles repo.

## Site conventions

- All source-of-truth content lives under [`docs/`](https://github.com/daviddwlee84/dotfiles/tree/main/docs) in the repo. The GitHub blob URL for any page is a valid alternative to this site.
- The `Copy to LLM` button on the top right of each page dumps the current page into a paste-ready format (works with Claude Code `claude -p` / OpenCode `opencode run` / pbcopy).
- [llms.txt](llms.txt) / [llms-full.txt](llms-full.txt) are auto-generated site-wide manifests for agents.
