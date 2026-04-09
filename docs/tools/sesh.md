# Sesh - Smart Tmux Session Manager

[Sesh](https://github.com/joshmedeski/sesh) is a CLI that manages tmux sessions using zoxide, giving you instant access to your most-used projects with smart session naming, startup commands, and preview.

## Installation

Sesh is installed automatically by the `devtools` ansible role:

- **macOS**: `brew install sesh`
- **Linux**: GitHub release binary → `~/.local/bin/sesh`

No manual installation needed after `chezmoi apply`.

## Keybindings

### ZSH (`Alt+S`)

Press `Alt+S` anywhere in the shell to open the sesh picker. This uses `fzf-tmux` as a popup with full filtering support.

Source: `~/.config/zsh/tools/22_sesh.zsh`

### ZSH Helpers

The managed zsh config also provides two shell helpers:

| Command | Action |
|---------|--------|
| `shere` | Connect to a sesh session for the current directory (`sesh connect "$PWD"`) |
| `sroot` | Connect to the current git root if present, otherwise `"$PWD"` |

The underlying functions are `sesh-here` and `sesh-root`, so you can call them directly if you prefer function names over aliases.

### tmux

All keybindings use the tmux prefix (default `Ctrl+B`).

| Keybinding | Action |
|------------|--------|
| `prefix + g` | Open sesh picker popup (fzf with preview, icons, filtering) |
| `prefix + S` | Switch to last session (via `sesh last`) |
| `prefix + 9` | Jump to root of current git repo/worktree |

Source: `~/.tmux.conf`

`prefix + g` avoids relying on `Shift`, so it does not fall through to tmux's built-in `prefix + t` clock shortcut on terminals that do not report uppercase prefix bindings reliably.

### Picker Keybindings (inside fzf popup)

| Key | Action |
|-----|--------|
| `Ctrl+A` | Show all sessions |
| `Ctrl+T` | Filter: tmux sessions only |
| `Ctrl+G` | Filter: configured sessions only |
| `Ctrl+X` | Filter: zoxide directories only |
| `Ctrl+F` | Filter: find directories (`fd`) |
| `Ctrl+D` | Kill selected tmux session |
| `Tab` / `Shift+Tab` | Navigate down/up |

## Shell Completion

ZSH tab completion for `sesh` subcommands and flags is auto-generated into `~/.zfunc/_sesh` on first load (and regenerated when sesh version changes). This follows the project's [completion pattern](zsh/zsh-completions.md).

Manual regeneration:

```bash
sesh completion zsh > ~/.zfunc/_sesh
rm -f ~/.zcompdump && compinit
```

## Configuration

Config file: `~/.config/sesh/sesh.toml` (managed by chezmoi)

### Schema Autocomplete

The config includes a JSON Schema directive for editor autocomplete via [taplo](https://taplo.tamasfe.dev/):

```toml
#:schema https://github.com/joshmedeski/sesh/raw/main/sesh.schema.json
```

### Key Options

| Option | Description |
|--------|-------------|
| `sort_order` | Session type display order: `tmux`, `config`, `tmuxinator`, `zoxide` |
| `dir_length` | Directory components in session names (default: 1) |
| `blacklist` | Regex patterns to hide from the picker |
| `cache` | Enable stale-while-revalidate caching (experimental) |

### Default Session

Applied to all sessions unless overridden:

```toml
[default_session]
startup_command = "nvim"
preview_command = "eza --all --git --icons --color=always {}"
```

- `startup_command`: runs when a new session is created
- `preview_command`: shown in the fzf preview pane (`{}` = session path)

### Named Sessions

Pin frequently used directories with custom names and commands:

```toml
[[session]]
name = "dotfiles"
path = "~/.local/share/chezmoi"

[[session]]
name = "home"
path = "~"
disable_startup_command = true
```

Available fields: `name`, `path`, `startup_command`, `preview_command`, `disable_startup_command`, `windows`.

### Wildcard Sessions

Apply settings to directories matching a glob pattern:

```toml
[[wildcard]]
pattern = "~/repos/*"
startup_command = "nvim"
```

- `*` matches one level, `**` matches recursively
- Explicit `[[session]]` entries take priority over wildcards

### Windows

Define reusable window layouts:

```toml
[[session]]
name = "my-project"
path = "~/repos/my-project"
windows = ["git"]

[[window]]
name = "git"
startup_script = "lazygit"
```

## Recommended tmux Settings

These are already set in `~/.tmux.conf`:

```
set -g detach-on-destroy off   # stay in tmux when closing a session
bind-key x kill-pane           # skip kill-pane confirmation
```

## Integration with Other Tools

### fzf

Sesh's primary picker integration. The `fzf-tmux` wrapper renders fzf inside a tmux popup. Our setup uses `--icons` for Nerd Font glyphs and `sesh preview` for the preview pane.

### zoxide

Sesh uses zoxide's frecency database to suggest directories. Any directory you `cd` into is automatically tracked and appears in `sesh list -z`.

### Television (tv)

[Television](https://github.com/alexpasmantier/television) has a built-in [sesh channel](https://alexpasmantier.github.io/television/community/channels-unix/#sesh). If tv is installed, you can use it as an alternative picker:

```
# tmux keybinding (alternative to fzf)
bind-key "T" display-popup -E -w 80% -h 70% -d '#{pane_current_path}' -T 'Sesh' tv sesh
```

Television cable channel config (`~/.config/television/cable/sesh.toml`):

```toml
[metadata]
name = "sesh"
description = "Session manager integrating tmux sessions, zoxide directories, and config paths"
requirements = ["sesh", "fd"]

[source]
command = ["sesh list --icons", "sesh list -t --icons", "sesh list -c --icons", "sesh list -z --icons", "fd -H -d 2 -t d -E .Trash . ~"]
ansi = true
output = "{strip_ansi|split: :1..|join: }"

[preview]
command = "sesh preview '{strip_ansi|split: :1..|join: }'"

[keybindings]
enter = "actions:connect"
ctrl-d = ["actions:kill_session", "reload_source"]

[actions.connect]
description = "Connect to selected session"
command = "sesh connect '{strip_ansi|split: :1..|join: }'"
mode = "execute"

[actions.kill_session]
description = "Kill selected tmux session"
command = "tmux kill-session -t '{strip_ansi|split: :1..|join: }'"
mode = "fork"
```

### Raycast (macOS)

The [sesh Raycast extension](https://www.raycast.com/joshmedeski/sesh) provides GUI-based session switching outside the terminal.

## Customization Tips

1. **Add project sessions**: Edit `~/.config/sesh/sesh.toml` (via `chezmoi edit ~/.config/sesh/sesh.toml`) to pin your most-used projects.

2. **Wildcard for monorepos**: Use `pattern = "~/work/monorepo/packages/*"` to auto-configure all sub-projects.

3. **Per-project startup**: Set `startup_command` to launch dev servers, editors, or TUI tools automatically.

4. **Preview with bat**: Use `preview_command = "bat --color=always {}/README.md"` to show project READMEs in the picker.

5. **Multiple windows**: Define `[[window]]` entries and reference them in sessions for multi-pane layouts (e.g., editor + lazygit).

## References

- [sesh GitHub](https://github.com/joshmedeski/sesh)
- [Smart tmux sessions with sesh](https://www.youtube.com/watch?v=-yX3GjZfb5Y) (Josh Medeski)
- [DevOps Toolbox sesh review](https://www.youtube.com/watch?v=ejdzk_L6nIk) (Omer Hamerman)
- [joshmedeski/dotfiles sesh.toml](https://github.com/joshmedeski/dotfiles/blob/main/.config/sesh/sesh.toml)
- [omerxx/dotfiles television cable](https://github.com/omerxx/dotfiles/blob/master/television/cable/sesh.toml)
