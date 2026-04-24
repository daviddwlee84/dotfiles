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

The managed zsh config provides four shell helpers, each with a distinct
weight class so you can pick the right tool for the moment:

| Command | Weight | When to use | Session name |
|---------|--------|-------------|--------------|
| `shere` | Bare shell | Ad-hoc cd: just need a tmux session at `$PWD`, no editor, no layout | `<basename>` |
| `sroot` | Sesh defaults | Want sesh's wildcard / `default_session` behavior at the git root | sesh-determined (`dir_length=2`) |
| `scode` | Heavy | "Open the coding-agent layout for *this* repo" — nvim 75% \| `specstory run` 25% + btop window | `coding-agent/<repo>` |
| `svibe` | Heaviest | "Vibe coding" — N tiled agent panes + lazygit + nvim | `vibe/<repo>` |

The underlying functions are `sesh-here` / `sesh-root` / `sesh-code` /
`sesh-vibe`; you can call them directly if you prefer function names over
aliases.

#### `shere` — bare shell at `$PWD`

Intentionally lightweight: creates a tmux session named after the basename of
the directory, drops you into a shell, **does not** trigger sesh's
`default_session.startup_command` (nvim) or any wildcard layout. Use it when
you've cd'd somewhere ephemeral and just want session persistence.

```bash
shere                          # bare shell session at $PWD
shere npm run dev              # session that runs `npm run dev` instead of a shell
shere -c "specstory run"       # explicit --command flag
shere -p ~/some/dir            # explicit path; -p + bare args also works
```

> **Behavior change (2026-04)**: `shere` used to inherit sesh's default
> startup_command, which opened nvim. It was renamed to "lightweight session"
> because the heavy editor-first workflow is now `scode`. If you want the old
> behavior, use `sroot` (which honors the sesh wildcards/defaults) or
> `sesh connect "$PWD"` directly.

#### `sroot` — git root with sesh defaults

Connects to the current git repo's top-level (or `$PWD` if not in a repo) and
honors all of sesh.toml: wildcard layouts (e.g. `/Volumes/Data/Program/*/*`
auto-applies `project.yaml`), `default_session.startup_command`, etc. This is
the right choice if you've been customizing sesh.toml and want those
customizations to apply.

```bash
sroot                          # connect to git root, sesh.toml decides layout
sroot specstory run codex      # explicit command override
```

#### `scode` — repo-scoped coding-agent layout

`scode` creates a session **named after the current repo**, so different
repos no longer collide on the single `coding-agent` session name. This was
the headline pain point of the old `sesh connect coding-agent` workflow:
the second invocation from a different repo would silently reuse the
existing session pointing at the *wrong* repo.

```bash
scode                          # current repo, default agent (specstory → claude)
scode codex                    # right pane runs `specstory run codex`
scode opencode                 # right pane runs `opencode` raw (not yet a specstory provider)
scode --no-specstory claude    # right pane runs `claude` raw (no markdown auto-save)
scode --on-exit kill claude    # Ctrl+C closes the right pane (vs default: drops to shell)
scode --on-exit restart codex  # codex auto-respawns on crash
scode -p ~/work/foo            # explicit repo path
scode --no-attach              # build the session in the background, don't switch
scode -h                       # help
```

Layout (window 1 "editor"):

```
┌─────────────────────────────┬──────────────┐
│ nvim                        │ specstory    │
│ (75% width)                 │ run [agent]  │
│                             │ (25% width)  │
└─────────────────────────────┴──────────────┘
```

Window 2 "monitor": `btop` (falls back to `htop` / `top`).

**Refuses outside a git repo** — if you're not in a repo, you don't want the
heavy layout. Use `shere` for bare shells or `svibe` if you really want a
vibe layout in a non-repo directory (svibe also requires a repo, but that's
because vibe layouts make even less sense without git context).

##### Agent wrapping (auto, opt out with `--no-specstory`)

| Argument | Right-pane command |
|----------|--------------------|
| (none) | `specstory run` (defaults to claude with auto-save md) |
| `claude` / `codex` / `cursor` / `droid` / `gemini` | `specstory run <name>` (known specstory providers) |
| `opencode` and other unknown CLIs | runs the binary directly |
| any agent + `--no-specstory` | runs the binary directly (raw) |

> `opencode` is currently raw because specstory upstream doesn't support it
> as a provider yet. Tracked in
> [`backlog/specstory-opencode-support.md`](../../backlog/specstory-opencode-support.md)
> — when `specstoryai/getspecstory#156` lands, the case statement in
> `_sesh_wrap_agent` gets a one-line update and opencode joins the auto-wrap
> list.

##### `--on-exit` modes

What happens when **any** pane command exits (agent, nvim, btop in `scode`;
agent, lazygit, nvim in `svibe`) — clean quit, Ctrl+C, or crash:

| Mode | Behavior |
|------|----------|
| `shell` (default) | Pane prints a yellow hint and drops into `$SHELL`. You can re-launch the command (the hint shows the exact invocation), switch windows, or close the pane manually. Costs one background `$SHELL` process per pane while the command isn't running. |
| `kill` | Pane/window closes when the command exits. The historical / tmux-default behavior. |
| `restart` | Wraps the command in `while true; do CMD \|\| true; sleep 1; done`. Use Ctrl+C twice quickly to break the loop and land in shell. Useful when iterating on a crash-prone tool. |

> The `shell` default trades one background process per pane for far better
> recoverability — the most common reported pain point with the old
> `coding-agent` workflow was "I hit Ctrl+C in the agent and lost the pane
> plus the 75/25 layout"; the same applies to accidentally `:q`-ing nvim or
> quitting btop/lazygit.

> The flag applies uniformly to every command-running pane in the layout —
> there is no per-surface override. If you want e.g. lazygit to die on quit
> but agents to drop to shell, file a feature request.

##### Single-agent only

`scode` is single-agent by design. If you want multiple agents in parallel,
use `svibe --agents …`. Passing `--agents` to `scode` errors with a hint to
switch to `svibe`.

> The legacy `coding-agent` named session in `sesh.toml` is **kept for
> back-compat** (still appears in the sesh picker, still works as
> `sesh connect coding-agent`) but `scode` is the preferred entry point.
> See the "DEPRECATED" comment block in sesh.toml.

#### `svibe` — parametric multi-agent vibe layout

Built directly with tmux scripting (not tmuxp) because pane counts are
parametric and tmuxp YAML can't express that.

Two ways to specify which agents run:

```bash
# Homogeneous (positional): all panes run the same agent
svibe                                            # N auto-picked × claude (see below)
svibe 2                                          # 2× claude
svibe 4 codex                                    # 4× codex
svibe 6 opencode                                 # 6× opencode (heavy — large monitor recommended)

# Heterogeneous (--agents): one entry per pane, list length = pane count
svibe --agents claude,codex,codex,opencode       # 4 panes, mixed
svibe --agents claude,opencode                   # 2 panes, mixed
svibe --agents 'claude, codex, opencode'         # whitespace around commas tolerated

# Other flags (work with both modes)
svibe --on-exit kill 4 claude                    # Ctrl+C closes panes
svibe --on-exit restart --agents codex,opencode  # auto-respawn loop
svibe --no-specstory 4 claude                    # 4× raw claude (no markdown auto-save)
svibe --min-width 120                            # wider panes → fewer auto columns
svibe -p ~/repo --agents claude,codex            # explicit path
svibe -h                                         # help
```

Mixing positional `[N] [CLI]` with `--agents` is **rejected** to keep
semantics unambiguous — pick one mode.

##### Width-aware defaults

Both **how many panes** (when `N` is omitted) and **how they're laid out**
are derived from the current terminal width ÷ a min-width threshold.

| Knob | Default | Override |
|------|---------|----------|
| `min_width` (cols) | `80` | env `SVIBE_MIN_WIDTH` or flag `--min-width COLS` |
| `term_width` (cols) | `$COLUMNS` with `tput cols` fallback | (read at invocation time) |

- **Auto N** (when neither positional `N` nor `--agents` was given):
  `N = clamp(term_width / min_width, 1, 12)`. So on a 240-col terminal:
  `min-width 80` → `N=3`; `min-width 120` → `N=2`; `min-width 60` → `N=4`.
- **Agents-window layout**: if all `N` panes fit side-by-side at
  `≥ min_width` each, use `even-horizontal` (N columns). Otherwise fall
  back to `tiled` (grid). Press `prefix + Space` to cycle through tmux's
  built-in layouts interactively if you want a different view.

Layout (3 windows):

```
window 1 "agents"    — N agent panes (columns if all fit at ≥min-width,
                       else tiled grid; mixed agents allowed)
window 2 "git"       — lazygit (or `git status` fallback)
window 3 "edit"      — nvim
```

Pane count is bounded `[1, 12]`. Above ~6 the tiled grid becomes too
cramped on most displays — the cap is conservative, not technical.

##### Validation (fail-fast)

`svibe` validates before building anything:

1. `--agents` and positional `[N] [CLI]` cannot both be set
2. `--on-exit` must be `shell` / `kill` / `restart`
3. Pane count in `[1, 12]`
4. Must be inside a git repo
5. **Every** agent CLI in the list must exist in `$PATH`

This avoids the "4-pane window where one pane is silently dead" failure mode
you'd get if validation were per-pane.

##### `--no-specstory` and `--on-exit`

Same semantics as `scode`. The wrapping is **per-pane**, so you can mix
opencode (raw) with claude (specstory-wrapped) freely:

```bash
# 3 panes — opencode raw, claude wrapped, codex wrapped, all share --on-exit shell
svibe --agents opencode,claude,codex
```

Like `scode`, `svibe` refuses outside a git repo. Use `shere` for plain
shells in arbitrary directories.

### Picking between the four

Decision tree:

```
Are you in a git repo?
├── No  → shere (bare shell) or sroot (if you want sesh defaults)
└── Yes → Do you want a layout?
          ├── No                       → shere or sroot
          ├── Single editor + side    → scode
          └── Multiple parallel agents → svibe
```

All four are idempotent: re-invoking with the same target attaches to the
existing session instead of creating a duplicate.

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
startup_command = "cd {} && tmuxp load -a -y ~/.config/tmuxp/project.yaml && tmux kill-window -t :1 2>/dev/null; tmux select-window -t :editor 2>/dev/null"
```

The `{}` placeholder is the matched path. The leading `cd {}` is
load-bearing, and pairs with an equally load-bearing **omission** in the
yaml: neither `project.yaml` nor `coding-agent.yaml` sets session-level
`start_directory`. Every "obvious" value silently breaks in one of three
ways — tmuxp resolves yaml strings via Python's `os.path.expandvars` (no
bash `${VAR:-default}` fallback); tmuxp resolves `.` / `./foo` against
the yaml **file's** directory (not the process cwd); and when libtmux
passes any of those results to `tmux new-window -c`, an invalid path
silently falls back to `$HOME`. By omitting `start_directory` entirely,
libtmux calls `tmux new-window` without `-c`, so tmux inherits the cwd
from the caller — and sesh's `send-keys` runs tmuxp from inside a pane
that `cd {}` has already moved to the matched path. Full write-up in
[pitfalls/tmuxp-append-ignores-session-start-directory.md](../../pitfalls/tmuxp-append-ignores-session-start-directory.md).

After the append, the empty initial window sesh always creates is killed
(`-t :1`), and focus moves to the `editor` window so nvim is foregrounded
immediately.

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
startup_command = "cd ~ && tmuxp load -a -y ~/.config/tmuxp/coding-agent.yaml && tmux kill-window -t coding-agent:1"
```

(The leading `cd ~` is load-bearing for the same tmuxp-append reason
described under the wildcard section above.)

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

## See also

- [`docs/tools/worktrunk.md`](worktrunk.md) — git-worktree manager (`wt`)
  for the **branch** layer below sesh's project layer. The recommended
  three-tier mental model is **sesh = repo, wt = worktree within repo,
  tmux = pane within worktree**. See the
  [three-layer navigation](worktrunk.md#the-three-layer-navigation-sesh--wt--wtcd)
  and [tmux session per worktree](worktrunk.md#tmux-session-per-worktree-and-how-it-interacts-with-scodesvibe)
  sections for how `scode`/`svibe` and `wt` compose.

## References

- [sesh GitHub](https://github.com/joshmedeski/sesh)
- [Smart tmux sessions with sesh](https://www.youtube.com/watch?v=-yX3GjZfb5Y) (Josh Medeski)
- [DevOps Toolbox sesh review](https://www.youtube.com/watch?v=ejdzk_L6nIk) (Omer Hamerman)
- [joshmedeski/dotfiles sesh.toml](https://github.com/joshmedeski/dotfiles/blob/main/.config/sesh/sesh.toml)
- [omerxx/dotfiles television cable](https://github.com/omerxx/dotfiles/blob/master/television/cable/sesh.toml)
