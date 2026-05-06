# Development Workflow — "Only type where you're going"

The end-to-end flow for picking up a project, jumping between worktrees, and
running parallel AI coding agents — without memorising helper function names.

This doc is the **index**. For deep dives see
[`docs/tools/sesh.md`](../tools/sesh.md) (picker, layouts, sesh config),
[`docs/tools/worktrunk.md`](../tools/worktrunk.md) (worktrees, parallel agents,
hooks), and [`docs/tools/tmux/`](../tools/tmux/) (panes, popup menu, theme).

---

## TL;DR — one key per intent

| Intent | Key | Where the key lives |
|---|---|---|
| Switch project / open a new one | `Alt+S` (outside tmux) or `prefix+g` (inside) | `smart-picker.sh` |
| Switch branch within current project | inside the picker → `Ctrl+W` worktrees | `smart-picker.sh` |
| Spin up a new parallel branch + agent | `wt cc <branch> -- '<prompt>'` | [`worktrunk.md`](../tools/worktrunk.md#per-worktree-claude--opencode) |
| Peek at sibling worktree (no session swap) | `wtcd` (fzf-tmux picker) | [`worktrunk.md`](../tools/worktrunk.md#the-wtcd-rationale) |
| Refresh coding-agent layout on current repo | `scode` (manual override) | [`sesh.md`](../tools/sesh.md) |

Everything else is explained by these five rows.

---

## The one keystroke

- **Outside tmux** (plain zsh prompt): `Alt+S`
- **Inside tmux**: `prefix + g`

Both open the same fzf popup. Same hotkeys, same behaviour, same dispatch
logic. The only difference is that outside-tmux spawns a fresh tmux client,
inside-tmux uses `switch-client` — handled by `sesh connect` and
`_sesh_attach_or_switch` transparently.

### Filter modes inside the picker

```
 ^a all         sesh list --icons
 ^t tmux        active tmux sessions only
 ^g configs     configured sesh sessions (from sesh.toml)
 ^x zoxide      zoxide frecency dirs  ← "type where I've been before"
 ^w worktrees   worktrees of the current repo  ← the worktrunk combo
 ^f find        fd walk from $HOME (depth 2)  ← when zoxide doesn't know yet
 ^d kill        kill the session under cursor, reload list
```

Hit the hotkey → the list reloads with that source. Type to fuzzy-filter.
Enter to dispatch.

### What happens on Enter — smart dispatch

The picker doesn't ask "which layout?" — it decides based on what you picked.

| Selection shape | Dispatch |
|---|---|
| Existing tmux session name | `sesh connect <name>` → switch/attach |
| Path inside a git repo (`.git` dir exists) | `scode -p <path>` → **coding-agent layout** (nvim 75% + agent 25% + btop window) |
| Path *not* inside a git repo | `sesh connect <path>` → plain session (wildcard patterns in `sesh.toml` still win if the path matches one) |
| Configured sesh session name | `sesh connect <name>` → honours `startup_command` |

The rule in one sentence: **git repo = scode layout; everything else =
sesh's default**. No second menu, no remembering which helper to type.

### When to override the smart rule

The picker is opinionated. If you want something else, skip the picker and
call the helper directly — all four remain available:

- `shere` — plain shell at `$PWD`, no editor, no git requirement
- `sroot` — honours `sesh.toml` wildcards and `default_session.startup_command`
- `scode` — coding-agent layout (requires git repo)
- `svibe` — parametric multi-agent layout (requires git repo)

See [`docs/tools/sesh.md`](../tools/sesh.md) for the full helper spec.

---

## Sesh + worktrunk — three orthogonal axes

Stolen from [`docs/tools/worktrunk.md`](../tools/worktrunk.md#mental-model)
because it's the mental model that makes the whole flow click:

| Axis | Tool | Granularity | What the picker shows |
|---|---|---|---|
| **Project** | `sesh` | One per repo | `^t` + `^g` + `^x` filters |
| **Branch** | `wt` (worktrunk) | One per parallel task in a project | `^w` filter |
| **Pane** | `tmux` | Editor / agent / logs / git | — (the layout inside the session) |

Picker = axes 1 and 2 in one popup. Worktrunk's own `wt switch` / `wtcd` /
`wt cc` still exist — reach for them when you want to *create* a worktree
or *run hooks*. The picker is for *jumping* to one that exists.

---

## Decision tree — which tool for which moment

```
Am I starting from scratch (no session for this project yet)?
├── Project I use often           → Alt+S / prefix+g, type name, hit Enter
├── Project I haven't used before → Alt+S / prefix+g → ^f (find) → pick → Enter
└── Brand new empty dir           → cd there → shere (skips git check)

Am I already in a session for this project?
├── Want to jump to a sibling worktree  → Alt+S / prefix+g → ^w → pick
├── Want to just peek at one (no swap)  → wtcd
├── Want to spin up a fresh branch + Claude agent → wt cc <branch> -- '<prompt>'
└── Want to see all worktrees' agent progress     → wt list

Am I wrapping up?
├── Branch ready to merge       → wt merge main
├── Branch rejected / scratch   → wt remove
└── Session no longer needed    → Alt+S / prefix+g → ^t → ^d to kill
```

---

## Why this reduces memorisation burden

Before: four helper functions (`shere` / `sroot` / `scode` / `svibe`), three
worktrunk commands (`wt switch` / `wt cc` / `wtcd`), and a sesh picker that
created *wrong* layouts for zoxide-picked repos. Seven names to remember,
plus the wrong default.

After: two keys (`Alt+S` and `prefix+g` — same behaviour either way) cover
every "I want to go somewhere" case. The picker auto-picks the coding-agent
layout for git repos so you never have to type `scode` for the common case.
`wt cc` / `wtcd` / `wt merge` are still the right tools for *creating* and
*cleaning up* — but for *navigating*, one key is enough.

---

## Gotchas

- **The picker's `^w` only lists worktrees of the current directory's repo.**
  Outside any repo it returns an empty list. This is deliberate for the MVP;
  cross-project worktree enumeration would need a known-projects list and
  doesn't earn its complexity yet.
- **Smart dispatch uses `.git` directory existence.** A non-git dir that
  happens to match a sesh wildcard (e.g. `/Volumes/Data/Program/foo/bar`
  which has no `.git`) will get the wildcard's layout, *not* scode. If you
  want scode, call `scode -p <path>` directly.
- **`scode` is called via `zsh -ic` from the bash picker script.** Means a
  fresh zsh sources your zshrc once per picker-enter. Fast enough
  (~50–150ms) but not instant. If you see lag, it's the zshrc, not sesh.
- **Outside tmux**, picking anything replaces your current shell with
  `tmux attach-session`. Ctrl-B d to get back. No way around this — tmux's
  own design.

---

## Cross-references

- [`docs/tools/sesh.md`](../tools/sesh.md) — sesh config, helpers, sesh.toml
  wildcards, tmuxp + tmuxinator layouts
- [`docs/tools/worktrunk.md`](../tools/worktrunk.md) — worktree workflow,
  `wt cc` parallel agents, hooks, `hash_port` per-worktree dev servers
- [`docs/tools/tmux/`](../tools/tmux/) — tmux config, popup menu, OSC 52
  clipboard, theme switching
- [`docs/shells/aliases.md`](../shells/aliases.md) — every alias and function
  catalogued
- [`dot_config/tmux/executable_smart-picker.sh`](../../dot_config/tmux/executable_smart-picker.sh)
  — the picker script itself (short, well-commented)
- [`dot_config/sesh/sesh.toml`](../../dot_config/sesh/sesh.toml) — named
  sessions and wildcards

---

## Future iterations (not yet enabled)

The user will revise this doc as the flow evolves. Candidates tracked in
[`TODO.md`](../../TODO.md) and [`backlog/`](../../backlog/README.md):

- Cross-project worktree enumeration in `^w` (scan known project roots)
- A `projects` television channel as an alternative entry point
- Yazi `Z` keymap → pipe selected dir into the smart picker
- `wt cc`-from-picker: pick a worktree that doesn't exist yet, get prompted
  for a branch name + agent prompt in one flow
- `specstory run` integration for `wt cc` (currently only `scode` / `svibe`
  auto-wrap the agent — see the caveat in [`worktrunk.md`](../tools/worktrunk.md#caveats))
