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
| `prefix + T` | Open sesh picker via television (tv) in a tmux popup |
| `prefix + O` | Open sesh built-in picker in a tmux popup |
| `prefix + W` | Open sesh window picker (fzf) -- switch or create tmux windows |
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
name = "chezmoi"
path = "~/.local/share/chezmoi"
tmuxinator = "chezmoi"    # delegates to tmuxinator for reliable multi-window setup

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

#### Per-project layout via tmuxp `--append`

For repos that benefit from a structured layout (editor / shell / lazygit
windows), wildcards can chain a `tmuxp load --append` on top of the bare
session sesh creates. Same trick as the `coding-agent` named session — see
[Approach B below](#approach-b-tmuxp-via-startup_command-active) for the
underlying mechanic.

```toml
# All repos under /Volumes/Data/Program/<group>/<repo>
[[wildcard]]
pattern = "/Volumes/Data/Program/*/*"
startup_command = "start_directory={} tmuxp load -a -y ~/.config/tmuxp/project.yaml && tmux kill-window -t :1 2>/dev/null; tmux select-window -t :editor 2>/dev/null"
```

The `{}` placeholder is the matched path. We pass it as a `start_directory`
env var so [`~/.config/tmuxp/project.yaml`](../../dot_config/tmuxp/project.yaml)'s
`start_directory: ${start_directory:-.}` picks it up. After the append, the
empty initial window sesh always creates is killed (`-t :1`), and focus
moves to the `editor` window so nvim is foregrounded immediately.

The pattern targets `/Volumes/Data/Program/*/*` (canonical paths) rather
than `~/Documents/Program/*/*` because zoxide records canonical paths
(see [zoxide.md](zoxide.md) → `_ZO_RESOLVE_SYMLINKS`). One pattern catches
both surface and canonical entries.

### Custom multi-section preview

The default `eza` preview only shows a file listing. The
[`~/bin/sesh-preview`](../../bin/executable_sesh-preview) script renders a
richer view in the fzf preview pane:

1. **Header**: dir name, parent path, git branch + dirty count + ahead/behind, mtime
2. **README**: first 25 lines, syntax-highlighted via `bat` if available
3. **Recent commits**: last 5 oneline commits (git repos only)
4. **File tree**: `eza --tree --level=2` with build dirs ignored

Wired in `sesh.toml`:

```toml
[default_session]
preview_command = "~/bin/sesh-preview {}"
```

Falls back to plain `head`/`ls` if `bat`/`eza` are missing, and gracefully
handles non-directory args (sesh sometimes hands the picker raw session
strings rather than paths). Output is capped under ~50 lines to avoid
fzf preview pane scroll on first paint.

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

`_ZO_RESOLVE_SYMLINKS=1` (set in
[`zsh/tools/20_zoxide.zsh`](../../dot_config/zsh/tools/20_zoxide.zsh)) makes
zoxide canonicalise paths before storing them, so symlink-heavy setups
(e.g. `~/Documents/Program -> /Volumes/Data/Program`) don't fragment a
single physical directory's frecency across two phantom entries. Sesh
wildcards should target the canonical pattern (`/Volumes/Data/Program/*/*`)
rather than the surface symlink.

To bootstrap a fresh DB with the directories you'd like sesh to surface
immediately (without waiting for organic `cd` traffic), the simplest path
is a one-shot Python script that reads the binary `db.zo` (version 3
format: `u32 ver, u64 count, then per-entry: u64 path_len, path bytes,
f64 rank, u64 ts`), inserts new entries with `rank=1.0`, and writes back.
Existing entries with higher scores are preserved. Sample workflow lives
in [pitfalls/zoxide-symlink-fragmentation.md](../../pitfalls/zoxide-symlink-fragmentation.md)
if/when that pitfall doc is created.

### Neovim (in-editor zoxide picker)

For jumping between repos without leaving Neovim, [`nvim/lua/plugins/zoxide-picker.lua`](../../dot_config/nvim/exact_plugins/zoxide-picker.lua)
adds a snacks.picker over `zoxide query --list --score`:

| Keymap | Action |
|--------|--------|
| `<leader>fz` | Pick repo, change tab-local cwd via `:tcd` |
| `<leader>fZ` | Pick repo, change global cwd via `:cd` |

`:tcd` (tab-local) is the default to avoid confusing LazyVim's
project-root detection when you have buffers from multiple projects open.
Use `:cd` (`<leader>fZ`) when you genuinely want the whole nvim session
to follow.

### Three project pickers compared

LazyVim ends up with **three overlapping but distinct** project-jump
entry points. Pick the one that matches your intent:

| Where | Trigger | Source | What it does |
|-------|---------|--------|--------------|
| Inside nvim | `<leader>fp` (or dashboard `p`) | `snacks.picker.projects` — oldfiles git roots + `fd` over `dev` dirs | `:tcd` + `persistence.nvim` restore (last buffers/windows for that cwd) |
| Inside nvim | `<leader>fz` / `<leader>fZ` | Full zoxide DB (frecency, 100+ entries) | Pure `:tcd` / `:cd`, no session restore |
| Inside tmux | `prefix + g` (sesh fzf) | tmux + sesh.toml + zoxide | Switch/create tmux session, spawn nvim + lazygit fresh |

Rough heuristic:

- **Already in nvim, want to peek at another repo's file** → `<leader>fz`
  (cheap, no session ceremony)
- **Already in nvim, want to fully resume work on another repo** →
  `<leader>fp` (restores buffers/windows you had last time)
- **Outside nvim, want a clean per-repo workspace** → `prefix+g` from tmux
  (gets you the layout from `~/.config/tmuxp/project.yaml`)

### Configuring the snacks projects picker

The defaults look at `~/dev` and `~/projects` (which probably don't exist
on your machine), plus oldfiles-derived git roots. To make `<leader>fp`
surface every repo under your project home, add it to `dev` —
[`projects.lua`](../../dot_config/nvim/exact_plugins/projects.lua) does this
for `/Volumes/Data/Program`:

```lua
{
  "folke/snacks.nvim",
  opts = {
    picker = {
      sources = {
        projects = {
          dev = { "/Volumes/Data/Program" },  -- canonical path, not the symlink
          max_depth = 2,                       -- catches <group>/<repo>
        },
      },
    },
  },
}
```

To **manually pin** a project that doesn't have a `.git` (or you want it
permanently surfaced regardless of `fd` discovery), set `projects` to
a list of paths:

```lua
projects = {
  vim.fn.expand("~/.local/share/chezmoi"),
  vim.fn.expand("~/.config/nvim"),
  "/Volumes/Data/Program/Personal/some-repo",
},
```

Both `dev` (auto-discovered via `fd`) and `projects` (manual list) are
merged with oldfiles entries before fzf renders. Snacks dedupes by path.

The `confirm = "load_session"` default delegates to `persistence.nvim`
(also wired in `projects.lua`); it restores the last buffer/window
layout for that cwd. If `persistence.nvim` isn't installed, `load_session`
silently falls back to opening the file picker after `:tcd`.

### Television (tv)

[Television](https://github.com/alexpasmantier/television) has a built-in [sesh channel](https://alexpasmantier.github.io/television/community/channels-unix/#sesh). Television is installed by the `devtools` ansible role (`brew install television` on macOS; Linuxbrew on Linux when available, otherwise skipped with a warning because upstream currently ships only `unknown-linux-gnu` binaries that require glibc ≥ 2.39 — incompatible with Ubuntu 22.04 LTS. See [docs/linux-package-sources.md](../linux-package-sources.md)).

**tmux keybinding:** `prefix + T` opens television's sesh channel in a tmux popup.

```
bind-key "T" display-popup -E -w 80% -h 70% -d '#{pane_current_path}' -T ' Sesh (tv) ' "tv sesh"
```

Use `Ctrl-s` to cycle through sources (all, tmux, config, zoxide, fd), and `Ctrl-d` to kill the highlighted session.

A custom cable channel config at `~/.config/television/cable/sesh.toml` overrides the built-in channel with richer source cycling and actions matching our fzf picker setup.

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
