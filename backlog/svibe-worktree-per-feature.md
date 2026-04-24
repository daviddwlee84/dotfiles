# `svibe` + worktree: per-feature editor/agent pair, on a hotkey

**Status**: P? — idea only, not spiked yet
**Effort**: M (option B) / L (option A — bigger, probably not worth it)
**Related**: `dot_config/zsh/tools/22_sesh.zsh` (`sesh-vibe`/`sesh-code`), `dot_config/zsh/tools/37_worktrunk.zsh` (`wtcd`), `dot_config/tmux/menu.sh` (popup menu), [docs/tools/worktrunk.md](../docs/tools/worktrunk.md), [docs/tools/sesh.md](../docs/tools/sesh.md) → `scode`/`svibe`

## Context

Current svibe + scode run every agent in the **same working directory**
(the current repo, no worktree). That works great for "multiple agents
on the same problem" but fights the "pick up a parallel feature" flow
that `worktrunk` already optimizes for. worktrunk's docs
([docs/tools/worktrunk.md → "The three-layer navigation"](../docs/tools/worktrunk.md#the-three-layer-navigation-sesh--wt--wtcd))
show the intended shape: `wt add fix-tmux-menu && wtcd fix-tmux-menu &&
claude` — one task = one worktree = one agent.

What's missing: a single hotkey that stitches "new worktree + agent +
editor" into one tmux motion, analogous to what
[Sidecar](https://sidecar.haplab.com/) does for desktop apps. Two
shapes were considered when the user raised this:

- **A.** Standby pool — `svibe-wt N` creates N worktrees up front, one
  agent per worktree, all on scratch branches. Rename/rebase later when
  the user decides what each agent will work on.
- **B.** Per-feature hotkey — a tmux binding (`prefix + W`? new menu
  row?) that opens **one** new tmux window: new worktree + split pane
  (left: nvim, right: agent).

Recommendation captured at decision time: build **B** when there's
demand; skip **A** unless a pattern actually emerges. Details below.

## Why B over A

1. **Matches existing workflow**. worktrunk is already one-worktree-
   per-task. B automates the last manual step (tmux split + launch
   editor + launch agent). A introduces a second mental model (agent
   pool) that doesn't fit what's there.
2. **No idle-agent cost**. A starts N agents on standby — if the user
   doesn't assign tasks immediately, that's N processes consuming
   context window / tokens / session-store disk on nothing. B starts
   agents on demand.
3. **A degenerates back to `svibe`**. If the user ends up having all N
   agents work the same repo state (no real parallel branches), the
   worktree isolation is pure overhead — and regular `svibe` does that
   better because the panes share one working dir.
4. **Disk cost**. Each worktree is a full checkout. N≥4 standby
   worktrees on larger repos = real disk. Per-feature creation only
   pays when the feature exists.

## B — design sketch

### Shape

```
prefix + W (or menu-row "Worktree → New feature window")
 └─ prompt: new branch name  (fzf over existing branches too — pick
                              or type a new one)
    └─ `wt add <branch>`                     (reuses worktrunk)
       └─ `tmux new-window -c <new-worktree-path> -n <short-name>`
          └─ pane L (75%): `nvim`            (scode-style width split)
          └─ pane R (25%): `specstory run <agent>`  (default = claude)
```

Exit behavior: the window's panes inherit `--on-exit shell` semantics
already used by `scode` / `svibe` (drop to `$SHELL` with a re-run hint,
don't close the window on Ctrl+C).

### Open design questions

1. **Key binding**. `prefix + c` is tmux's new-window — shadowing it
   would break muscle memory. Options, least-disruptive first:
   - Add a **menu row** in `~/.config/tmux/menu.sh` (Worktree → New
     feature). Zero new keys. User invokes via `prefix + Space` →
     Worktree → New. Cheapest.
   - Bind `prefix + W` (uppercase W, free today per the existing
     keybindings.conf) to the same script. Two-key muscle memory.
   - Bind `prefix + C-w` (ctrl-w inside prefix) — closer to "worktree"
     mnemonic but conflicts with vim's window nav for anyone doing
     `:<C-w>` in a nested neovim; probably avoid.
2. **Branch-name source**. Three candidates:
   - `fzf` popup over `git branch --all` results, with a "type to
     create new" fallback. Highest affordance, most interactive.
   - Plain `read -p "branch: "` prompt inside a tmux `display-popup`.
     Smallest surface.
   - Auto-name `wip/YYYY-MM-DD-hhmm-RAND`; user renames with
     `git branch -m` when the feature firms up. Fastest path-of-least-
     resistance for "I just want to start coding".
   Leaning fzf + auto-name fallback when user hits enter on empty.
3. **Layout shape inside the new window**. Copy `scode` (nvim 75% |
   agent 25%) exactly, or something else? scode is battle-tested —
   copy it.
4. **Agent choice**. Default `claude` (matches scode). Optional
   positional arg (`svibe-wt codex` / `svibe-wt opencode`) for picking
   another. Honor the same `--no-specstory` / `--on-exit` flags
   `scode`/`svibe` already parse (share `_sesh_wrap_agent` +
   `_sesh_on_exit_wrap`).
5. **Window naming**. worktrunk's `wt` already picks good tmux-safe
   branch names; the new window name can just echo the branch slug
   (`fix-tmux-menu` or similar).
6. **Cleanup**. `wt remove <branch>` already exists in worktrunk for
   the worktree. The tmux side: user closes the window manually (same
   as every other tmux window). No lifecycle coupling needed — if the
   user removes the worktree via `wt remove`, the nvim pane's CWD
   becomes stale but tmux doesn't care.
7. **Interplay with `scode`/`svibe` session names**. `scode` uses
   `coding-agent/<repo>`, `svibe` uses `vibe/<repo>`. A per-feature
   worktree window could live inside the **current** session (adds a
   window, not a session) to stay ergonomic — or spawn its own session
   named `feature/<branch>`. Current-session is less surprising;
   defer the "own session" variant until someone wants it.
8. **First-run behavior when not inside a session**. Fall back to
   `wt add <branch>; cd <worktree>; nvim` inline, no tmux layout,
   and print a hint? Or hard-require tmux? Probably: hard-require
   tmux (the binding implies it anyway).

### Naming & entry points

- **Command**: `svibe-wt` (or `svibe-worktree` / `scode-wt`) zsh
  function alongside `sesh-vibe`. The scode-shaped name would honor
  the 1-agent layout, so `scode-wt` is probably the more honest name
  — `svibe-wt` implies parametric pane count, which this doesn't
  have.
- **Tmux entry**: menu row (Worktree → New feature window) + an
  optional top-level `prefix + W` binding.
- **Alias**: `swt` (short; `scode-wt` as the full name). Matches the
  `shere` / `sroot` / `scode` / `svibe` family.

### Reuse from existing code

Everything below already exists in `dot_config/zsh/tools/22_sesh.zsh`
and should be shared, not copy-pasted:

- `_sesh_git_root` — resolve the source repo root (to branch off).
- `_sesh_sanitize` — session/window name sanitizer (forbids `.` `:`).
- `_sesh_wrap_agent` — specstory wrapping (known-provider detection).
- `_sesh_on_exit_wrap` — the shell/kill/restart wrapper with the
  yellow re-run hint.

`wtcd` is defined at `dot_config/zsh/tools/37_worktrunk.zsh:57`; call
it rather than re-implementing the cd-to-worktree logic.

## A — why deferred (kept for context)

Standby pool. Rejected for the reasons listed in "Why B over A", plus:

- Requires a lifecycle model (when do standby agents get assigned? by
  the user picking a pane? by a menu? what happens if all N are
  already busy when a new task arrives?) that B sidesteps entirely.
- Rebalancing (move an agent from worktree X to worktree Y after it
  turned out Y is the branch that matters) is error-prone; rebuilding
  state (chat history, context) across a move is not free.
- A proponent's strongest argument — "I want to context-switch fast" —
  is already handled by `wtcd` + multiple tmux windows. The latency
  saving from pre-warmed agent processes is seconds at most.

If A becomes interesting later, the simplest revival is: call B in a
loop from a parent script, feeding it N pre-picked branch names. No
new primitives needed.

## Verification plan (when we pick B up)

1. `swt` (no arg, not inside a session) → refuses with a hint to
   `tmux new-session` first.
2. `swt` (inside a session, in a git repo) → popup prompts for branch
   name; accepting a new name creates worktree + window + split.
3. `swt codex` → same, right pane runs `specstory run codex`.
4. `swt --on-exit restart feature-x codex` → right pane auto-respawns.
5. After `wt remove feature-x`, the stale tmux window's nvim pane
   still behaves (CWD just doesn't exist anymore); user closes it
   manually.
6. `prefix + Space` → Worktree → New feature window reaches the same
   flow.
7. `swt -h` help text lists all the flags.

## Out of scope (explicit non-goals)

- **Agent pool / standby mode** (option A above). Revisit only if a
  user pattern demands it.
- **Cross-worktree agent handoff**. "Move this agent from worktree X
  to Y" is not a feature. Close and re-open.
- **Automated branch naming from agent output** ("agent infers a good
  branch name from its first task"). Cute but fragile; prompt-based
  naming is more predictable.
- **Integration with GitHub PR creation**. `worktrunk` has its own
  story for this; no need to duplicate in `swt`.
