# tv vs fzf — Comparison & Best Practices

Two fuzzy finders, two philosophies. This dotfiles repo uses **both**.

| | **fzf** | **television (tv)** |
|---|---------|---------------------|
| Philosophy | Low-level fuzzy primitive; you compose workflows with shell glue | Structured picker framework; workflows declared as TOML channels |
| Analogy | Unix pipe building block | Terminal-native Telescope.nvim |
| Matcher | Custom mature engine (multi-year, battle-tested) | [nucleo](https://github.com/helix-editor/nucleo) (shared with Helix) |
| Query syntax | fuzzy, exact (`'`), prefix (`^`), suffix (`$`), inverse (`!`), **OR** (`\|`) | fuzzy, exact, prefix, suffix, substring, negate — no OR |
| Extensibility | Shell scripts, env vars, `--bind`, `--preview`, `--reload` | TOML channel files in `cable/` directory |
| Shell integration | `Ctrl+R` / `Ctrl+T` / `Alt+C` + `**<TAB>` completion | `Ctrl+R` / `Ctrl+T` with context-aware channel triggers |
| Sorting control | `--tiebreak`, `--sort`, `--no-sort` | `no_sort`, `frecency` per channel |
| Multi-select | `--multi` + Tab/Shift-Tab | Built-in |
| Preview | `--preview` flag (any command) | `[preview]` section in channel TOML |
| Actions on select | `--bind 'enter:execute(...)'` | `[actions]` section; fork/execute modes |
| Ecosystem maturity | Huge: vim, tmux, zsh, bash, fish, git, kubectl, etc. | Growing; fewer third-party integrations |
| Config in this repo | `dot_config/zsh/tools/10_fzf.zsh` | `dot_config/television/cable/*.toml` |

## When to use which (in this dotfiles repo)

| Use case | Tool | Why |
|----------|------|-----|
| Shell history (`Ctrl+R`) | fzf | More sorting modes, `FZF_CTRL_R_OPTS` customization |
| File picker (`Ctrl+T`) | fzf | Deep completion integration, `**<TAB>` |
| Directory cd (`Alt+C`) | fzf | Built-in, simple |
| Tab completion preview | fzf | `_fzf_comprun` per-command previews |
| Sesh session picker | tv | Channel with source cycling (tmux/zoxide/config/fd), preview, kill action |
| CLI tools picker | tv | Channel parsing `cli-tools.md`, preview with tldr |
| Aliases picker | tv | Channel listing all runtime aliases/functions |
| Git branch switching | tv | Channel with preview + checkout action |
| Custom domain pickers | tv | Declarative TOML channels are faster to author than shell wrappers |

## "Telescope-like workflow" explained

The pattern (popularized by [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)):

```
Source → Filter/Sort → Preview → Action
```

You use the **same picker UI** with **different data sources**. Each picker (channel) defines what to search, how to preview, and what actions are available. You don't switch mental models — just switch channels.

tv implements this natively: each `.toml` file in `cable/` is a channel recipe.

## Channel / Cable Best Practices

### 1. One channel = one job

Don't build a mega-channel. Keep each channel focused:

- `files` — find files
- `text` — grep content
- `git-branches` — switch branches
- `dirs` — cd via zoxide/fd
- `history` — shell history
- `tools` — CLI tool reference

### 2. Source should be clean and stable

The `[source]` runs a shell command. Keep it:

- **Machine-friendly output** — one entry per line, predictable format
- **Lightweight** — no heavy formatting; let `display` / `output` / `preview` handle presentation
- **Use source cycling** for variants of the same thing (e.g. `fd -t f` vs `fd -t f -H` for hidden files)

Rule: only cycle sources that share the same mental model. "Files vs hidden files" = good. "Files vs docker containers" = bad.

### 3. Preview is the workflow's soul

Good preview transforms the experience from "pick blindly" to "browse with context":

| Channel | Preview command |
|---------|----------------|
| files | `bat --color=always {}` |
| text/grep | `bat --color=always --highlight-line {line} {file}` |
| git branches | `git log --oneline --graph {}` |
| git log | `git show {}` |
| docker images | `docker inspect {} \| jq` |
| tools | `tldr {}` or `{} --help` |

### 4. Keep actions minimal and consistent

Per channel, define:

| Key | Role | Example |
|-----|------|---------|
| `Enter` | Primary action | Open, connect, execute |
| `Ctrl+E` | Edit | `$EDITOR {}` |
| `Ctrl+Y` | Yank/copy | Copy to clipboard |
| `Ctrl+X` | Destructive | Kill session, delete |
| `Ctrl+/` | Toggle preview | Built-in |

### 5. Respect original ordering for temporal data

For shell history, git log, and similar temporal sources:

- Set `no_sort = true` to preserve source order
- Set `frecency = false` to disable frequency-based ranking

You want "most recent commands" not "highest fuzzy score from 6 months ago".

### 6. Use shell integration triggers

tv's shell integration can detect the current command prefix and auto-select a channel:

```toml
# In shell_integration config
[channel_triggers]
"git checkout" = "git-branches"
"git switch"   = "git-branches"
"cd"           = "dirs"
"ls"           = "dirs"
"vim"          = "files"
"nvim"         = "files"
"cat"          = "files"
"bat"          = "files"
"export"       = "env"
"unset"        = "env"
```

This turns the shell prompt into a **context-aware picker entry point**.

## Cable organization

### By data type (recommended for most people)

```
cable/
├── files.toml
├── text.toml
├── dirs.toml
├── git-branches.toml
├── git-log.toml
├── env.toml
├── history.toml
├── sesh.toml
└── tools.toml
```

### By work context (for project-heavy workflows)

```
cable/
├── code-files.toml
├── code-grep.toml
├── code-symbols.toml
├── repo-switch.toml
├── notes.toml
├── infra-docker.toml
└── infra-k8s.toml
```

## Practical comparison table

| Scenario | fzf approach | tv approach |
|----------|-------------|-------------|
| Find project files | `fd -t f \| fzf --preview 'bat {}'` | `tv files` (built-in channel) |
| Grep repo content | `rg --line-number foo \| fzf --preview 'bat ...'` | `tv text` (built-in channel) |
| Switch git branch | `git branch \| fzf \| xargs git checkout` | `tv git-branches` → Enter checks out |
| Shell history | `Ctrl+R` (fzf built-in, toggle sort with `Ctrl+R`) | `Ctrl+R` (tv shell integration) |
| Tab completion | `ssh **<TAB>`, `kill **<TAB>`, custom `_fzf_complete_*` | Not available — fzf only |
| Session management | `sesh list \| fzf-tmux` (Alt+S in this repo) | `tv sesh` with source cycling (prefix+T) |
| URL picker in tmux | `prefix + u` (tmux-fzf-url) | N/A — fzf plugin |
| Custom tool lookup | Alt+T (fzf ZLE widget) | `tv tools` / `tv aliases` |

## Summary

> **fzf** = mature infrastructure primitive. Unmatched shell integration depth, query syntax, and ecosystem.
>
> **tv** = modern workflow framework. Better out-of-box channel/preview/action packaging, less shell glue needed.
>
> Fuzzy matching quality: comparable. Query syntax: fzf has more operators (notably OR). Shell completion: fzf only.

Use both. Let fzf own shell-native integration (`Ctrl+R`, `Ctrl+T`, `Alt+C`, `**<TAB>`). Let tv own structured pickers where channels shine (sesh, tools, aliases, domain-specific workflows).

## Community channels vs our custom channels

tv ships a large set of [community-maintained channels](https://alexpasmantier.github.io/television/community/channels-unix) covering files, dirs, env, git (branch/log/diff/stash/tags/worktrees/remotes/submodules), docker (containers/images/volumes/networks/compose), k8s, brew, cargo, GitHub PRs/issues, systemd journal, and more.

Install/update community channels with:

```bash
tv update-channels
```

This downloads channels into `~/.config/television/cable/`, skipping channels whose requirements aren't met on your system and skipping channels that already exist (won't overwrite your custom ones).

### Do we reinvent the wheel?

| Our channel | Community equivalent | Verdict |
|---|---|---|
| `sesh.toml` | `sesh.toml` (community) | **Retired** — community caught up with identical logic. Our version is kept as `sesh.toml.reference` for reference; `tv update-channels` provides the active one. |
| `tools.toml` | None | **Unique** — parses our `cli-tools.md`, no equivalent |
| `aliases.toml` | `alias.toml` | **Superset** — community version is minimal (`$SHELL -ic 'alias'`, no functions, no actions). Ours adds functions via `typeset -f`, formatted columns, execute action, copy-to-clipboard |

**Conclusion: minimal duplication.** `sesh.toml` was retired in favor of the community version. The other two custom channels have no equivalent or significantly extend the community version.

### Community channels worth adopting

After running `tv update-channels`, these are already available (no manual setup needed). Particularly useful ones:

| Channel | What it does |
|---------|-------------|
| `git-branch` | Branch picker with checkout/delete/merge/rebase actions |
| `git-log` | Commit log with cherry-pick/revert/checkout |
| `git-stash` | Stash browser with apply/pop/drop |
| `git-diff` | Changed files with stage/restore/edit |
| `brew-packages` | Homebrew formula/cask list with upgrade/uninstall |
| `docker-containers` | Container management with start/stop/logs/exec/remove |
| `docker-images` | Image picker with run/shell/remove |
| `dirs` | Directory picker via fd (with hidden toggle via source cycling) |
| `files` | File picker via fd + bat preview (with hidden toggle) |
| `env` | Environment variable browser |
| `dotfiles` | Browse `~/.config` files with bat preview + edit action |
| `gh-issues` / `gh-prs` | GitHub issue/PR picker with rich preview |
| `just-recipes` | Justfile recipe picker with preview + execute |

To write a custom channel, create a `.toml` file in `dot_config/television/cable/` (deployed via chezmoi). Custom channels won't be overwritten by `tv update-channels`. See the [channel spec](https://alexpasmantier.github.io/television/reference/channel-spec) for TOML format.

## See also

- [fzf quick reference](fzf.md)
- [tv quick reference](tv.md)
- [keyboard shortcuts](../keyboard-shortcuts.md)
