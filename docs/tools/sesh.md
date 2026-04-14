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
| `shere` | Connect to a sesh session for the current directory |
| `sroot` | Connect to the current git root if present, otherwise `$PWD` |

The underlying functions are `sesh-here` and `sesh-root`, so you can call them directly if you prefer function names over aliases.

Both helpers accept a **command** as bare arguments (no quotes needed), which overrides the default `startup_command` from `sesh.toml`:

```bash
# No args → default startup_command (nvim)
shere
sroot

# Bare args → treated as the command to run in the new session
shere specstory run codex
shere npm run dev
sroot specstory run codex

# Explicit flags (also supported)
shere -c "specstory run codex"       # --command flag
shere -p ~/repos/my-project          # --path flag (overrides $PWD)
shere -p ~/repos/my-project npm dev  # path + command
```

**Note:** `--command` only takes effect when creating a new session. If the session already exists, sesh switches to it and ignores the command.

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

## Pane Layouts (Advanced)

### Sesh Limitations

Sesh **cannot** create pane splits natively. Each `[[window]]` gets exactly one pane with one `startup_script`. There is no `panes`, `layout`, `size`, or `ratio` configuration.

If you need predefined pane layouts (e.g., "left pane = nvim 75%, right pane = specstory run 25%"), you must use an external tool.

### The `tmuxp` Field is Dead Code (as of sesh v2.24)

**Important**: The `tmuxp` field in `sesh.toml` (on `[[session]]` and `[default_session]`) is defined in the Go struct and JSON schema, but **never read or used** by sesh's source code. Only `tmuxinator` has a working integration.

Evidence from source code:
- `startup/config.go` checks `Tmuxinator` and `StartupCommand` but **not** `Tmuxp`
- `connector/connect.go` has a `tmuxinatorStrategy` but **no** `tmuxpStrategy`
- Setting `tmuxp = "..."` in sesh.toml does nothing -- the session falls through to `default_session.startup_command`

### Approach B: tmuxp via `startup_command` (Active)

Use sesh's `startup_command` to call `tmuxp load --append`, which appends windows from a tmuxp YAML into the sesh-created session, then kill the initial empty window.

Config in `sesh.toml`:
```toml
[[session]]
name = "coding-agent"
path = "~"
startup_command = "tmuxp load -a -y ~/.config/tmuxp/coding-agent.yaml && tmux kill-window -t coding-agent:1"
```

Layout defined in `~/.config/tmuxp/coding-agent.yaml`:
```yaml
session_name: coding-agent
windows:
  - window_name: editor
    layout: main-vertical
    options:
      main-pane-width: 75%    # 3:1 ratio
    panes:
      - shell_command: nvim
      - shell_command: specstory run
  - window_name: monitor
    panes:
      - shell_command: btop
```

**How it works:**
1. `sesh connect coding-agent` → sesh creates a tmux session named `coding-agent` at `~`
2. `startup_command` runs inside the first pane via `tmux send-keys`
3. `tmuxp load -a -y` appends the "editor" and "monitor" windows to the current session
4. `tmux kill-window -t coding-agent:1` removes the initial empty window sesh created

**Pros:** tmuxp already installed, declarative YAML, `--append` avoids session conflict.
**Cons:** brief flash of empty window being killed; `startup_command` is `send-keys` so timing-sensitive.

**Requires:** `tmuxp` (`pip install tmuxp` or `uv tool install tmuxp`)

### Approach C: tmuxinator Native Integration (Alternative)

Sesh has full native support for tmuxinator. When `tmuxinator` field is set, sesh **bypasses** its own `NewSession` + `startup.Exec` and delegates entirely to `tmuxinator start`.

Config in `sesh.toml`:
```toml
[[session]]
name = "coding-agent"
path = "~"
tmuxinator = "coding-agent"
```

Layout defined in `~/.config/tmuxinator/coding-agent.yml`:
```yaml
name: coding-agent
root: <%= @settings["root"] || "~" %>
on_project_start: tmux set-window-option main-pane-width 75%
windows:
  - editor:
      layout: main-vertical
      panes:
        - nvim
        - specstory run
  - monitor:
      panes:
        - btop
```

**How it works:**
1. `sesh connect coding-agent` → sesh detects `tmuxinator` field
2. `connector/tmuxinator.go` calls `tmuxinator start coding-agent` directly
3. tmuxinator creates the entire session with all windows and panes
4. sesh then switches/attaches to the session

**Pros:** cleanest integration, no empty window hack, sesh natively manages the lifecycle.
**Cons:** requires tmuxinator (`gem install tmuxinator`), Ruby dependency.

**Requires:** `tmuxinator` (installed by `ruby_gem_tools` ansible role)

### Approach A: Pure Shell Script (Fallback)

For environments without tmuxp or tmuxinator, use raw tmux commands:

```toml
[[session]]
name = "coding-agent"
path = "~"
startup_command = "tmux split-window -h -p 25 'specstory run' && tmux select-pane -L && tmux new-window -n monitor 'btop' && tmux select-window -t 1 && nvim"
```

**Pros:** zero extra dependencies.
**Cons:** fragile, hard to read, hard to maintain.

### Comparing Approaches

Both `coding-agent` (tmuxp) and `coding-agent-mux` (tmuxinator) are configured in `sesh.toml` for A/B comparison:

```bash
sesh connect coding-agent       # Approach B: tmuxp --append
sesh connect coding-agent-mux   # Approach C: tmuxinator native
```

After testing, keep the one you prefer and remove/comment the other.

## try + sesh Integration

[try-cli](https://github.com/tobi/try) creates ephemeral project workspaces under `~/src/tries/`. A sesh wildcard automatically applies `startup_command = "nvim"` to any try project.

### Usage

```bash
# One-step: open project and start coding session
try-sesh some-project
try-sesh https://github.com/user/repo

# Two-step: try first, then sesh
try some-project
shere                    # sesh connect "$PWD"
```

The `try-sesh` function (alias: `tsesh`) runs `try` then immediately `sesh connect "$PWD"`. Session names follow `dir_length=2` convention: `tries/2026-04-14-some-project`.

Source: `~/.config/zsh/tools/32_try.zsh`

## Upstream Issues (tmuxp)

Sesh's `tmuxp` config field is documented in the schema and README, but **not implemented** in the source code. Relevant upstream issues:

- [#87 - Add tmuxp support](https://github.com/joshmedeski/sesh/issues/87) -- Feature request to add tmuxp support. Status: Closed (marked "Done" on project board), but the implementation only added the field to the config struct/schema without wiring it into the connect/startup logic.
- [#198 - Built-in Window and Pane management](https://github.com/joshmedeski/sesh/issues/198) -- Request for native pane/window layout support (avoiding tmuxp/tmuxinator dependency). Status: Closed. Sesh v2.25 added basic window support but still no pane splits.
- [#188 - startup_command sent too early](https://github.com/joshmedeski/sesh/issues/188) -- Bug where startup_command is sent before the shell is ready. Status: Open. This can affect Approach B (`tmuxp load -a`) if there's a timing issue.

## References

- [sesh GitHub](https://github.com/joshmedeski/sesh)
- [Smart tmux sessions with sesh](https://www.youtube.com/watch?v=-yX3GjZfb5Y) (Josh Medeski)
- [DevOps Toolbox sesh review](https://www.youtube.com/watch?v=ejdzk_L6nIk) (Omer Hamerman)
- [joshmedeski/dotfiles sesh.toml](https://github.com/joshmedeski/dotfiles/blob/main/.config/sesh/sesh.toml)
- [omerxx/dotfiles television cable](https://github.com/omerxx/dotfiles/blob/master/television/cable/sesh.toml)
