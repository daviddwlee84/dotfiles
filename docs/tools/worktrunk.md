# Worktrunk — Git Worktree Workflow Playbook

[Worktrunk](https://worktrunk.dev) (`wt`) is a CLI for git worktree management
designed around running AI coding agents in parallel. This doc is a
**workflow playbook**: how I actually use it in this dotfiles environment,
combined with `sesh` + `tmux`. For full reference docs see
[worktrunk.dev](https://worktrunk.dev).

> **TL;DR**
> - One repo → many worktrees, each on its own branch, each with its own
>   agent / dev server / database.
> - `sesh` picks the **repo** (per-project tmux session). `wt` picks the
>   **worktree** within that repo. `wtcd` peeks at sibling worktrees without
>   moving sesh/tmux.
> - Cold-start elimination via `wt step copy-ignored`. Per-worktree dev
>   server via `hash_port`. Cleanup via `wt remove` / `wt merge` hooks.

## Table of Contents

- [Mental model](#mental-model)
- [Install & shell integration in this repo](#install--shell-integration-in-this-repo)
- [The three-layer navigation: sesh + wt + wtcd](#the-three-layer-navigation-sesh--wt--wtcd)
- [Per-worktree Claude / OpenCode](#per-worktree-claude--opencode)
- [Per-worktree dev server (`hash_port`)](#per-worktree-dev-server-hash_port)
- [tmux session per worktree (and how it interacts with `scode`/`svibe`)](#tmux-session-per-worktree-and-how-it-interacts-with-scodesvibe)
- [Cold-start elimination](#cold-start-elimination)
- [Merge & cleanup flow](#merge--cleanup-flow)
- [LLM commit messages — when to bother](#llm-commit-messages--when-to-bother)
- [Recipes I haven't enabled yet](#recipes-i-havent-enabled-yet)
- [Cross-references](#cross-references)

---

## Mental model

Three orthogonal axes of "what am I working on":

| Axis | Tool | Granularity | Example |
|------|------|-------------|---------|
| **Project** | `sesh` (`shere`/`sroot`/`scode`/`svibe`) | One per repo / dir | `coding-agent/dotfiles` |
| **Branch** | `wt` (worktrunk) | One per parallel task within a project | `dotfiles.feat-x`, `dotfiles.fix-y` |
| **Pane** | `tmux` | Editor / agent / logs / git | nvim ▏ claude ▏ btop |

Without worktrunk, parallel agents inside one repo step on each other
(checkout conflicts, stale `node_modules`, dev server port clashes). With
worktrunk, each agent gets its own checkout dir + branch + (optional) port +
(optional) DB, addressed by **branch name**.

The **chezmoi-managed [`~/.config/worktrunk/config.toml`](../../dot_config/worktrunk/config.toml)**
in this repo is intentionally minimal — only aliases (`sw`/`ls`/`rm`/`cc`/`oc`)
are active. Hooks and LLM commits are commented as opt-in templates. Enable
them per-project as the need actually surfaces, not preemptively.

---

## Install & shell integration in this repo

Auto-installed by the `devtools` ansible role:

- **macOS**: `brew install worktrunk` (Homebrew formula).
- **Linux**: GitHub release musl tar.xz → `~/.local/bin/wt`. Ansible task
  ensures `xz-utils` is present and downloads
  `worktrunk-{x86_64,aarch64}-unknown-linux-musl.tar.xz` from
  `max-sixty/worktrunk`. Same fallback pattern as `sesh`.

Shell integration lives in
[`dot_config/zsh/tools/37_worktrunk.zsh`](../../dot_config/zsh/tools/37_worktrunk.zsh):

1. `eval "$(wt config shell init zsh)"` — wraps `wt` as a zsh function so
   `wt switch` actually `cd`s the parent shell. Same approach as
   starship/zoxide/direnv; **does not** call `wt config shell install`
   (which would edit `~/.zshrc` and fight chezmoi).
2. Auto-generates `~/.zfunc/_wt` on Linux only via `COMPLETE=zsh wt`
   (clap dynamic completion). On macOS the brew formula already ships
   `_wt` to `/opt/homebrew/share/zsh/site-functions/`, so the generator
   is skipped.
3. Defines `wtcd` — a small fzf-tmux helper for cross-worktree navigation
   that **doesn't** change tmux/sesh session (see next section).

> **Why not just `wt config shell install`?** It writes a block to
> `~/.zshrc`, which chezmoi manages from `dot_zshrc.tmpl`. Every
> `chezmoi apply` would either undo it or perpetually report drift. The
> `eval "$(wt config shell init zsh)"` form gives the same wrapper without
> touching the rc file.

---

## The three-layer navigation: sesh + wt + wtcd

The single biggest mental shift moving to worktrees is realising **moving
between worktrees is NOT the same as moving between projects**. Three
distinct keystrokes for three distinct intents:

| I want to... | Use | What it does | Side effects |
|--------------|-----|--------------|--------------|
| Switch **project** | `Alt+S` (sesh picker), `sroot`, `scode` | Detaches from current tmux session, attaches to project's session | Full session swap |
| Switch **worktree** in current project | `wt switch <branch>` (or `wt sw`, or `wt switch` with no arg → picker) | `cd`s parent shell, runs hooks (`pre/post-start`) | New dir; if hook spawns tmux session for the worktree, you can attach to that |
| **Peek** at sibling worktree | `wtcd` (fzf picker) | `cd`s parent shell only | Stays in same tmux/sesh session; useful for diffing, copying files |

### Concrete example

```bash
# Morning: open the dotfiles project
$ sroot                              # → tmux session "dotfiles" (or whatever sesh names it)

# Pick up where I left off on the worktrunk-docs branch
$ wt switch worktrunk-docs           # → cd to ../dotfiles.worktrunk-docs, post-start hooks run

# Quick look at what main looks like right now (don't lose my place)
$ wtcd                               # → fzf shows all worktrees → pick "main" → cd, no session change
$ git log --oneline -5
$ cd -                               # back to worktrunk-docs

# New parallel task: spin up a worktree + Claude in one go
$ wt cc fix-tmux-menu -- 'Investigate the popup menu height issue documented in pitfalls/tmux-display-menu-silent-fail.md'
# Now there's a 2nd Claude running in ../dotfiles.fix-tmux-menu while I keep editing here.
```

### The `wtcd` rationale

`wt switch` is the right tool 95% of the time. But `wt switch` runs
`pre-start` / `post-start` hooks — start dev servers, copy ignored files,
spawn agents. That's heavy. When you only want to **look** at a sibling
worktree (find a file, copy a snippet, run `git log`), you don't want
hook side effects. `wtcd` skips hooks entirely; it's a pure `cd`.

```zsh
# Defined in dot_config/zsh/tools/37_worktrunk.zsh
function wtcd() {
    local target
    target=$(wt list --format=json 2>/dev/null \
        | jq -r '.worktrees[].path' \
        | fzf-tmux -p 60%,40% --prompt='wt cd ❯ ') || return
    [[ -n "$target" ]] && cd -- "$target"
}
```

Add a per-project keybinding to your tmux config if you use it a lot:
`bind-key W run-shell 'tmux send-keys "wtcd" Enter'`.

---

## Per-worktree Claude / OpenCode

The single most useful pattern for parallel coding agents. Each worktree
runs its own agent in its own checkout dir; they can't collide on file
edits, branches, or git state.

The aliases live in `~/.config/worktrunk/config.toml` (NOT in zsh — putting
them there means they also work from `wt switch`'s interactive picker, and
from any shell):

```toml
[aliases]
cc = "wt switch --create --execute=claude"
oc = "wt switch --create --execute='opencode run'"
```

Usage:

```bash
# Three Claude agents working in parallel, one prompt each
wt cc add-auth        -- 'Add JWT auth middleware. See docs/auth.md for the schema.'
wt cc fix-pagination  -- 'Fix the off-by-one in /api/list. Repro in tests/pagination.test.ts:42.'
wt cc write-tests     -- 'Write integration tests for /api/checkout.'

# Or with OpenCode
wt oc refactor-store  -- 'Migrate redux → zustand. Start with src/state/user.ts.'

# Check on progress (markers come from the Claude/OpenCode plugins; 🤖 = working, 💬 = waiting)
wt list
#   Branch          Status   ...  Marker  ...
# @ main                            ^
# + add-auth        +   ↕↑    ↑3   🤖
# + fix-pagination  +   ↕↑    ↑1   💬     ← needs my input
# + write-tests     +   ↕     ↑2   🤖

# Jump to the one waiting for input
wt switch fix-pagination
```

### Caveats

- `--execute` (`-x`) launches the agent **in the foreground** of the new
  shell. If you want the agent to run in a separate tmux session/window
  rather than blocking your prompt, use the [tmux session per worktree](#tmux-session-per-worktree-and-how-it-interacts-with-scodesvibe)
  pattern below — `wt switch -x 'tmux new-session -d ...'`.
- The `cc` / `oc` aliases assume you've already authenticated each agent
  CLI globally (`claude`/`opencode`). They inherit your shell environment.
- For SpecStory transcript capture (this repo's coding-agent overlay), the
  `scode`/`svibe` sesh helpers wrap the agent in `specstory run`; `wt cc`
  does NOT. If you want both, write your own alias:
  `wsc = "wt switch --create --execute='specstory run claude'"`.

---

## Per-worktree dev server (`hash_port`)

Three parallel agents editing a Next.js app all want to run `npm run dev`.
With one repo: port collision, last one wins, the others crash. With
worktrunk + `hash_port`: each branch deterministically gets its own port
in the 10000-19999 range, derived from the branch name.

Add to a project's local `.config/wt.toml` (per-project, not your global
config — different projects need different commands):

```toml
[post-start]
server = "npm run dev -- --port {{ branch | hash_port }}"

[list]
url = "http://localhost:{{ branch | hash_port }}"

[pre-remove]
server = "lsof -ti :{{ branch | hash_port }} -sTCP:LISTEN | xargs kill 2>/dev/null || true"
```

Now:

```bash
wt cc fix-checkout-ui -- 'Make the checkout button green'
# post-start runs `npm run dev -- --port 14823` in the background
# Hook output goes to a log file; tail it with:
tail -f "$(wt config state logs get --hook=user:post-start:server)"

wt list
# URL column shows http://localhost:14823 (clickable in iTerm/Ghostty)
# Port is deterministic — fix-checkout-ui ALWAYS gets 14823, on any machine

# When done, wt remove cleans up:
wt remove fix-checkout-ui
# pre-remove kills the dev server before unlinking the worktree
```

### Why this matters more than it sounds

- **No port juggling**: you don't think about ports at all.
- **Bookmarkable**: the URL for `fix-checkout-ui` is stable across reboots
  and across machines (laptop and desktop both compute port 14823).
- **CORS / cookies**: each worktree is on its own port, so cookies don't
  leak between branches. Combine with the [Caddy subdomain
  pattern](https://worktrunk.dev/tips-patterns/#subdomain-routing-with-caddy)
  if you need clean URLs without ports.
- **Database isolation**: same `hash_port` trick works for spawning a
  per-worktree Postgres container — see
  [worktrunk.dev/tips-patterns#database-per-worktree](https://worktrunk.dev/tips-patterns/#database-per-worktree).

> Project-local `.config/wt.toml` should usually be **committed** to the
> repo so all collaborators (and all your machines) share the same hooks.
> The chezmoi-managed `~/.config/worktrunk/config.toml` is for personal
>   defaults that apply across all repos.

---

## tmux session per worktree (and how it interacts with `scode`/`svibe`)

Two competing models for "where does my coding-agent layout live":

### Model A — `scode` / `svibe` per **project** (current default)

[`sesh-code`/`sesh-vibe`](sesh.md) (aliases `scode`/`svibe`) create one
tmux session **per repo**, named `coding-agent/<repo>` or `vibe/<repo>`,
with a fixed nvim + agent + lazygit layout. All worktrees of that repo
share the same session — you `wt switch` inside it to move between them.

✅ **Best for**: solo coding, sequential work on different branches, low
parallel agent count.
❌ **Limitation**: only one Claude/OpenCode pane visible at a time. If
you have 5 parallel agents, you can't watch them all simultaneously.

### Model B — tmux session per **worktree**

Spin up a dedicated tmux session for each worktree, with its own multi-pane
layout. Worktrunk's official recipe:

```toml
# project's .config/wt.toml
[pre-start]
tmux = """
S={{ branch | sanitize }}
W={{ worktree_path }}
tmux new-session -d -s "$S" -c "$W" -n dev
tmux split-window -h -t "$S:dev" -c "$W"
tmux split-window -v -t "$S:dev.0" -c "$W"
tmux split-window -v -t "$S:dev.2" -c "$W"
tmux send-keys -t "$S:dev.1" 'npm run backend' Enter
tmux send-keys -t "$S:dev.2" 'claude' Enter
tmux send-keys -t "$S:dev.3" 'npm run frontend' Enter
tmux select-pane -t "$S:dev.0"
"""

[pre-remove]
tmux = "tmux kill-session -t {{ branch | sanitize }} 2>/dev/null || true"
```

Then `wt switch --create feature -x 'tmux attach -t {{ branch | sanitize }}'`
creates the worktree, runs the layout, and attaches you to the new session.

✅ **Best for**: 3+ parallel agents, dashboard-style overview,
worktree-specific services (backend/frontend/db each in their own pane).
❌ **Limitation**: tmux session list grows fast — pair with `sesh` to
filter (sesh picks up tmux sessions automatically). Also: heavier
cold-start.

### How they interact

The two models are **not mutually exclusive**:

- Use `scode` to enter the project (one persistent session for the editor
  + git overview).
- Use Model B's `pre-start` hook to spawn a **separate** session per
  worktree containing only the agent + dev servers.
- Switch between them via `Alt+S` (sesh picker shows both
  `coding-agent/dotfiles` AND `dotfiles.feat-x`, `dotfiles.feat-y`...).
- Detach the agent session, leave it running. Re-attach later with sesh.

### Sesh + wt session naming convention

If you adopt Model B, recommend prefixing tmux session names so sesh's
picker groups them sensibly:

```toml
[pre-start]
tmux = "tmux new-session -d -s 'wt/{{ repo }}/{{ branch | sanitize }}' ..."
```

Now `Alt+S` shows:

```
coding-agent/dotfiles      ← scode session (editor)
wt/dotfiles/feat-x         ← wt session (agent A)
wt/dotfiles/feat-y         ← wt session (agent B)
wt/dotfiles/fix-z          ← wt session (agent C)
```

…all greppable by typing `wt/dotfiles/` in fzf.

---

## Cold-start elimination

A new worktree is a fresh checkout — no `node_modules/`, no `target/`,
no `.env`, no build cache. For a Rust or pnpm project, that's a 60-180s
penalty per `wt switch --create`. Two complementary mitigations:

### `wt step copy-ignored`

Copies all gitignored files from the source worktree into the new one.
Add to project's `.config/wt.toml`:

```toml
[post-start]
copy = "wt step copy-ignored"
```

For projects with huge ignored directories you don't want to copy (e.g.
`coverage/`, `dist/`, OS junk), create `.worktreeinclude` listing what
**should** be copied — files must be both gitignored AND listed.

### Sequenced pipelines

When `pnpm install` needs to see the copied `node_modules/` first,
sequence with the `[[hook]]` array form (`[[…]]` = ordered pipeline,
`[…]` = parallel):

```toml
[[post-start]]
copy = "wt step copy-ignored"

[[post-start]]
install = "pnpm install"   # reuses cached packages from copied node_modules
```

### When the agent needs files immediately

If `--execute claude` needs `.env` to exist before launch, use `pre-start`
instead of `post-start`:

```toml
[pre-start]
copy = "wt step copy-ignored"
```

---

## Merge & cleanup flow

Worktrunk replaces the multi-step "commit → push → merge → switch back →
remove worktree → delete branch" dance with one command:

```bash
wt merge main
# 1. (optional) generates LLM commit message from staged diff
# 2. commits, rebases onto main, fast-forwards merge
# 3. switches you back to main worktree
# 4. background-removes the feature worktree + branch
```

What this means in practice with parallel agents:

```bash
# Three agents finished. Review their diffs in the picker first:
wt switch              # interactive picker shows live diff/log preview, tab between worktrees

# Pick winner #1, merge it
wt merge main

# Pick winner #2, but want manual commit message for this one (override):
wt mc                  # if you set up the editor-override alias from `Manual commit messages`
                       # in https://worktrunk.dev/tips-patterns/

# Reject #3 — close without merging
wt switch reject-this-one
wt remove              # discards branch + worktree (will warn if unmerged commits)
```

### Per-merge cleanup hooks

Add per-project `pre-merge` (run validation before letting bad code in)
and `post-merge` (deploy, notify):

```toml
[[pre-merge]]
test = "npm test"
build = "npm run build"

[post-merge]
deploy = """
if [ {{ target }} = main ]; then npm run deploy:production; fi
"""
```

`pre-merge` runs **once per merge** (after rebase). `pre-commit` runs
**per squashed commit** during the merge — put fast checks (lint,
typecheck) there and slow ones (full test suite) in `pre-merge`.

---

## LLM commit messages — when to bother

`wt merge` can pipe the staged diff to a command that returns a commit
message on stdout. Three configurations, pick at most one in
`~/.config/worktrunk/config.toml`:

| Strategy | When | Config |
|----------|------|--------|
| **Manual editor** | Solo work, you're the one with context | `command = '''f=$(mktemp); printf '\n\n' > "$f"; sed 's/^/# /' >> "$f"; ${EDITOR:-vi} "$f" < /dev/tty > /dev/tty; grep -v '^#' "$f"'''` |
| **Claude headless** | Agent-driven workflow, want the agent to also write the message | `command = "claude -p"` |
| **OpenCode** | Same as Claude but with OpenCode | `command = "opencode run"` |

All three currently sit **commented out** in this repo's
[`dot_config/worktrunk/config.toml`](../../dot_config/worktrunk/config.toml).
Reasoning: I haven't decided yet whether the LLM-generated messages are
better than what a coding agent already produced before staging. Plan is
to enable `claude -p` once I've used `wt merge` enough to feel the friction.

### Editor override per-merge

Keep LLM as default but use editor for one specific merge:

```toml
[aliases]
mc = '''WORKTRUNK_COMMIT__GENERATION__COMMAND='f=$(mktemp); printf "\n\n" > "$f"; sed "s/^/# /" >> "$f"; ${EDITOR:-vi} "$f" < /dev/tty > /dev/tty; grep -v "^#" "$f"' wt merge'''
```

Then `wt merge` uses Claude, `wt mc` opens `$EDITOR`.

### Branch summaries

With LLM commits enabled, also turn on `summary = true` to get one-line
LLM-generated branch summaries in `wt list --full` and the picker (tab 5):

```toml
[list]
summary = true
```

---

## Recipes I haven't enabled yet

Documented for "future me" — copy-paste targets when the need arises.
All from [worktrunk.dev/tips-patterns](https://worktrunk.dev/tips-patterns/).

| Recipe | Trigger to enable |
|--------|-------------------|
| **Database per worktree** (Postgres container, `hash_port` for the DB port, `vars` to coordinate names) | First time I want to test schema migrations on a feature branch without trashing the main DB |
| **Caddy subdomain routing** (`feat-x.dotfiles.localhost` instead of `:14823`) | First time cookies / CORS bites me on a port-based dev URL |
| **Bare repo layout** (`<project>/.git` + `<project>/<branch>/`) | New project where I want symmetric branch dirs from day one |
| **Stacked branches** (`wt switch --create part2 --base=@`) | First time I want to break a big PR into a stack |
| **Agent handoff** (one agent spawns another in a detached tmux session) | First time I'm running an agent long enough to want it to delegate |
| **CI status in `wt list`** (`wt list --full --branches`) | First time I'm juggling enough open PRs to lose track of which CI is green |

---

## Cross-references

- [`docs/tools/sesh.md`](sesh.md) — sesh helpers (`shere` / `sroot` /
  `scode` / `svibe`); the project layer above worktrunk.
- [`docs/tools/tmux/`](tmux/) — tmux config, popup menu, theme switching;
  the pane layer below sesh.
- [`docs/tools/agent-overlays.md`](agent-overlays.md) — Claude Code,
  OpenCode, Codex CLI overlay configs (`modify_*`); how the agent CLIs
  themselves are managed.
- [`docs/tools/specstory.md`](specstory.md) — agent transcript capture;
  paired with `scode`/`svibe` (NOT with `wt cc` by default).
- [`dot_config/worktrunk/config.toml`](../../dot_config/worktrunk/config.toml)
  — managed user config (aliases active; hooks/LLM commits commented).
- [`dot_config/zsh/tools/37_worktrunk.zsh`](../../dot_config/zsh/tools/37_worktrunk.zsh)
  — shell integration + `wtcd` helper.
- [worktrunk.dev](https://worktrunk.dev) — full upstream docs.
