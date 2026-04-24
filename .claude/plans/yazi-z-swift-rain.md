# Unified "Where am I going next" picker + workflow docs

## Context

**The pain**: User can't remember `shere` / `sroot` / `scode` / `svibe` / `wt switch` /
`wt cc` / `wtcd`. They want a Yazi-Z-style flow: press one key → type a project
or directory → land in the right tmux session with the right layout, regardless
of whether they're currently inside tmux. The workflow should feel "直覺 只哪
打哪" and compose cleanly with worktrunk worktrees.

**The state today** (confirmed via exploration):

- `Alt+S` (outside tmux, ZLE widget in `dot_config/zsh/tools/22_sesh.zsh:17`) and
  `prefix + g` (inside tmux, `dot_config/tmux/executable_sesh-picker.sh`) both
  already open the same fzf popup. Both scripts handle in-tmux vs outside-tmux
  transparently via `_sesh_attach_or_switch` / sesh's own detection.
- The picker already supports `Ctrl+X` to flip the source to zoxide frecency
  directories (`sesh list -z --icons`).
- Wildcard sessions in `dot_config/sesh/sesh.toml:137-155` (`/Volumes/Data/Program/*/*`,
  `~/repos/*`, `~/src/tries/*`) auto-apply tmuxp layouts when you pick a matching
  zoxide dir — so "pick zoxide dir → get multi-window layout" already works for
  those paths.
- `wt list --format=json | jq -r '.worktrees[].path'` is already used by the `wtcd`
  fzf helper in `dot_config/zsh/tools/37_worktrunk.zsh:129-136`.

**The two real gaps**:

1. Zoxide dirs outside the configured wildcards get a *default* sesh session
   (bare nvim) — never the `scode` coding-agent layout (nvim 75% + agent 25% +
   btop window). Today the only way to get the `scode` layout is to `cd <repo>`
   and type `scode`. The picker doesn't know the user wants that layout.
2. Worktrees don't appear anywhere in the picker. `wt list` is a separate flow.
   The user has to remember whether they're switching project (sesh) or branch
   (wt).

**The goal**: upgrade the *existing* picker (same keys, no new memorization) so
it surfaces worktrees and auto-applies `scode` layout for git repos. Then write
a single workflow doc that makes the flow teachable in one page.

## Scope decisions (chosen by user)

- **Docs + one keybinding integrator** — both ship together.
- **Worktrees in the same picker** — one picker sees sessions, zoxide dirs, and
  worktrees.
- **Smart preset detection** — no second menu. Git repo → `scode`; non-git dir →
  `shere`; existing tmux session → plain `sesh connect`.

## Design

### A. Unified picker script

**New file**: `dot_config/tmux/executable_smart-picker.sh` (chmod +x via chezmoi
`executable_` prefix).

Composes four data sources into one fzf-tmux popup, uses filter mode hotkeys
matching the existing picker's muscle memory:

```
 ^a all ^t tmux ^g configs ^x zoxide ^w worktrees ^f find ^d kill
```

Behavior on Enter (smart dispatcher):

```bash
selected="$(...fzf...)"
payload="${selected#* }"   # strip leading icon column (matches sesh format)

# Case 1: selection is an existing tmux session name
if tmux has-session -t "=$payload" 2>/dev/null; then
    exec sesh connect "$payload"         # sesh handles switch-client vs attach
fi

# Case 2: selection is a path (starts with / or ~)
if [[ "$payload" == /* || "$payload" == "~"* ]]; then
    target="${payload/#\~/$HOME}"
    # Smart preset: git repo → scode layout; else plain sesh (honors wildcards)
    if git -C "$target" rev-parse --show-toplevel &>/dev/null; then
        exec zsh -i -c "scode '$target'"  # reuse existing scode helper
    else
        exec sesh connect "$target"      # plain session, nvim via startup_command
    fi
fi

# Case 3: configured sesh session name
exec sesh connect "$payload"
```

**Worktree source** (`Ctrl+W`): iterate known project roots (read from a small
config list) and cat their `wt list --format=json` outputs. MVP: list worktrees
of the **current directory's repo only** (simpler, covers the 90% case —
user is usually already *in* a project when they want to jump to its sibling
branch). Later enhancement: scan `~/Documents/Program/*`, `/Volumes/Data/Program/*`,
`~/repos/*` for worktrunk-tracked repos.

### B. Wire the new script in place of the existing two

Minimal-churn upgrade — keep the same keys users already have:

1. `dot_config/tmux/executable_sesh-picker.sh` — replace body with
   `exec "$(dirname "$0")/smart-picker.sh" "$@"` (keeps `prefix + g` working; all
   existing menu references still resolve).
2. `dot_config/zsh/tools/22_sesh.zsh:17` `sesh-sessions` function — same
   treatment; either call `~/.config/tmux/smart-picker.sh` or inline the
   equivalent logic. Keep `Alt+S` binding (line 616-618) untouched.

No new keys to memorize. Existing entry points now do more.

### C. Docs deliverable

**New file**: `docs/this_repo/workflow.md` — single-page playbook.

Structure (concise, scannable):

1. **TL;DR table** — one row per intent ("switch project", "switch branch within
   project", "new parallel agent", "peek sibling worktree") → the one key to
   press. Teaches the decision tree in one glance.
2. **The one keystroke** — `Alt+S` (outside tmux) or `prefix + g` (inside).
   Same behavior either way. Explains `Ctrl+A/T/G/X/W/F/D` filter modes.
3. **Smart preset detection** — explain the `.git`-directory rule so it's not
   magic. Tell the reader how to opt into or out of it explicitly (still type
   `scode` / `shere` by hand when you want to override).
4. **Sesh + worktrunk combo** — half-page section ripping the 3-axis table from
   `docs/tools/worktrunk.md:38-42` and showing the picker's role in each axis.
5. **When to reach for which tool** — decision tree:
   - Just want to open a project → picker (`Alt+S` / `prefix+g`)
   - Already in a project, need parallel agent on different branch → `wt cc`
   - Already in a project, quick peek at sibling worktree → `wtcd`
   - Refresh session layout without closing panes → `scode` by hand
6. **Cross-refs** to `docs/tools/sesh.md`, `docs/tools/worktrunk.md`,
   `docs/tools/tmux/README.md` for the deep dives. No duplication — this doc
   is the *index*, not the manual.

**CLAUDE.md cross-file maintenance rule update**: the section at
`CLAUDE.md:22-25` ("Custom aliases & shell functions → `docs/zsh/aliases.md`")
— verify whether `smart-picker.sh` is a zsh function (no — it's a bash script
under `dot_config/tmux/`, so `docs/zsh/aliases.md` doesn't need an entry).
`docs/tools/sesh.md:240-250` (the keybindings table) already lists `prefix + g`
as "sesh picker"; after this change the behavior changes but the *key* stays
the same — update the description cell to read "smart picker: tmux sessions +
configs + zoxide dirs + worktrees, smart layout detection. See
`docs/this_repo/workflow.md`." Do the same for the `Alt+S` row.

## Files to change

| File | Change |
|---|---|
| `dot_config/tmux/executable_smart-picker.sh` | **new**; the unified picker |
| `dot_config/tmux/executable_sesh-picker.sh` | one-liner that execs smart-picker |
| `dot_config/zsh/tools/22_sesh.zsh` | `sesh-sessions` body → call smart-picker (keep the ZLE widget wrapper) |
| `docs/this_repo/workflow.md` | **new**; single-page end-to-end playbook |
| `docs/tools/sesh.md` | update picker description in keybindings table (2 rows) |
| `README.md` | section "What You Get > Tools" — one line mentioning the unified picker + pointer to workflow.md (required by CLAUDE.md:11-20) |
| `docs/zsh/aliases.md` | **no change** (script is bash, not a zsh function) |

## Critical code to reuse, not reinvent

- `_sesh_attach_or_switch` (`dot_config/zsh/tools/22_sesh.zsh:60-67`) — in-tmux vs
  outside-tmux switching. Don't reinvent.
- `scode` function (`dot_config/zsh/tools/22_sesh.zsh:254-410`) — already handles
  per-repo session creation + layout. Smart-picker must call this, not re-create
  the layout.
- Existing fzf-tmux bind pattern (`executable_sesh-picker.sh:23-29`) — copy the
  prompt-change + reload pattern verbatim, just add `ctrl-w`.
- `wt list --format=json | jq -r '.worktrees[].path'` pattern from `wtcd`
  (`dot_config/zsh/tools/37_worktrunk.zsh:131-135`).
- `sesh preview {}` (`executable_sesh-picker.sh:31`) already handles previews
  for sessions, configs, and paths — works for worktree entries too.

## Verification plan

End-to-end tests (manual, from a fresh shell):

1. **Outside tmux**: `Alt+S` → pick a zoxide dir that IS a git repo → verify a
   `coding-agent/<repo>` session was created with the 75/25 nvim/agent split +
   btop window. Reopen `Alt+S` → verify the session now appears in `Ctrl+T`
   (tmux-only) filter and picking it `tmux attach`es cleanly.
2. **Outside tmux**: `Alt+S` → pick a zoxide dir that is NOT a git repo (e.g.,
   `~/Downloads`) → verify plain sesh session with just nvim.
3. **Inside tmux**: `prefix + g` → `Ctrl+W` → pick a worktree from current
   repo → verify session switches (not attaches) and cwd is the worktree path.
4. **Inside tmux**: `prefix + g` → `Ctrl+X` → pick a dir → verify the picker
   treats it as a zoxide entry (not a tmux session) and dispatches correctly.
5. **Chezmoi apply**: `chezmoi diff dot_config/tmux/`,
   `chezmoi diff dot_config/zsh/tools/22_sesh.zsh` — confirm the
   `executable_smart-picker.sh` is marked `+rwxr-xr-x` (executable_ prefix
   working). `chezmoi apply`, then `tmux kill-server` to force reload.
6. **Pitfall regression check**: reopen `prefix + Space` (popup menu). Verify
   the "Sesh picker" entry still opens cleanly at terminal heights 14, 22, 60
   (per the tmux display-menu height-fit invariant in `CLAUDE.md`). The menu
   itself isn't touched but running it exercises the new dispatcher.
7. **Docs sanity**: grep that `docs/this_repo/workflow.md` resolves all relative
   links it names (`docs/tools/sesh.md`, `docs/tools/worktrunk.md`,
   `docs/tools/tmux/README.md`). `just lint-docs` if that recipe exists;
   otherwise visual inspection.

## Out of scope (for this iteration)

- Cross-project worktree enumeration (scanning `~/Documents/Program/*` etc.).
  MVP only lists worktrees of the current repo. Add later if it becomes
  friction.
- TV (`television`) channel variant. The user picked "upgrade the picker", not
  "add a second picker". A `projects` tv channel could come later but doesn't
  need to block this.
- Yazi `Z` keymap. The user has no keymap customizations in
  `dot_config/yazi/keymap.toml` today; adding one is out-of-scope and would
  fragment the mental model ("Yazi Z" vs "Alt+S").
- LLM commit messages in `worktrunk`, database-per-worktree, Caddy subdomain
  routing — all deferred in `docs/tools/worktrunk.md:482-493`; nothing changed.
