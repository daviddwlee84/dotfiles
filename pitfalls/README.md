# Pitfalls

Past traps we've stepped on. Symptoms-first knowledge base — the goal is that
when a problem recurs (on a new machine, after an upgrade, with a new tool
combo), grepping the symptom here lands you on the root cause and workaround
in seconds, instead of re-debugging from scratch.

This folder is `chezmoi`-ignored (see `.chezmoiignore.tmpl` → `pitfalls/**`); it
is repo metadata for maintainers, not user-facing config to deploy.

## Pitfalls vs the rest

This repo has four sibling surfaces with overlapping shapes; pick the right one:

| Surface | Time direction | Question it answers | Access pattern |
|---|---|---|---|
| `docs/tools/<tool>.md` | Present | "How does this tool work / how do I configure it?" | Read top to bottom |
| `docs/this_repo/<topic>.md` | Present | "Why did we architect it this way?" | Read top to bottom |
| `pitfalls/<slug>.md` | **Past** | **"I see error X — has this happened before?"** | **Grep symptoms** |
| `backlog/<slug>.md` | Future | "We thought about doing Y — what was the analysis?" | Index in `TODO.md` |
| `AGENTS.md` Hard invariants | Present | "What rules MUST agents follow?" | Read top to bottom |

A pitfall **graduates** to a Hard invariant in `AGENTS.md` when the trap is
serious enough that you can't rely on memory or grep — typically when (a) it
recurs across machines, (b) it silently corrupts state, or (c) the workaround
is non-obvious and easy to undo by accident. When graduating, leave a
`pitfalls/<slug>.md` as historical record and link to it from the invariant.

## When to add a pitfall doc

Add a `pitfalls/<slug>.md` when you've spent more than ~15 minutes on something
where the answer wasn't googleable, AND any of:

- The symptom is non-obvious from the root cause (`SSH_CONNECTION` cleared
  silently → hostname module disappears, no error)
- The fix is "do nothing different but in a specific order" (sentinel writes
  must come after `wait $pid` for fleet-apply, etc.)
- The same trap could be hit by a new agent / new machine / new contributor
- An upstream bug exists with no ETA — workaround needs to outlive memory
- A specific tool version is required (or forbidden) and the failure mode at
  the wrong version is silent / confusing (e.g. tmux 3.2a popup off-screen)

## When NOT to add a pitfall doc

- Trivially googleable error (the next person will solve in 30 seconds anyway)
- Already covered in `docs/tools/<tool>.md` as part of the tool's normal
  configuration — cross-link from this README's "Cross-referenced pitfalls"
  table below instead of duplicating
- Already a `AGENTS.md` Hard invariant — those have higher priority enforcement
  (cross-link only)
- One-off transient (network glitch, machine-specific config rot) — fix and
  move on

## File template

See [`assets/pitfall-doc.md.template`](#) in the
[`project-knowledge-harness` skill](https://github.com/daviddwlee84/agent-skills/tree/main/skills/local/project-knowledge-harness),
or copy the structure of an existing entry below.

Key sections (different from `backlog/` template — symptom-first, not
context-first):

```markdown
# <Title describing the SYMPTOM, not the root cause>

**Symptoms** (grep this section): <verbatim error messages, observable behaviour>
**First seen**: YYYY-MM
**Affects**: <tool/version/OS combo>
**Status**: workaround documented / fixed upstream in vX.Y / WONTFIX

## Symptom

Full error messages (verbatim, not paraphrased — preserves grep-ability).
Reproduction steps if applicable.

## Root cause

Why this happens. Reference source, docs, or upstream issue.

## Workaround

Immediate workaround (commands, config diff). Should be copy-pasteable.

## Prevention

How to avoid stepping on this again. If serious enough, link to the
corresponding `AGENTS.md` Hard invariant.

## Related

Links to `docs/`, sibling pitfalls, `TODO.md` entries (if a real fix is
queued), upstream issues/PRs.
```

## Index

Pitfalls owned by this folder. Keep alphabetical.

| Slug | Symptom keywords | Status |
|---|---|---|
| [`brew-cask-slow-github-release-assets`](brew-cask-slow-github-release-assets.md) | `brew upgrade --cask <x>` download creeps at ~25 KB/s from `release-assets.githubusercontent.com`; TUNA/ghproxy/Clash don't help | no workaround (network-path issue) |
| [`npm-postinstall-github-releases-hang`](npm-postinstall-github-releases-hang.md) | `npm install -g` hangs after "Downloading https://github.com/.../releases/..." | workaround documented |
| [`nvim-fs-find-enoent-stale-cwd`](nvim-fs-find-enoent-stale-cwd.md) | nvim 0.12 startup `vim/fs.lua:0: ENOENT` from avante / lualine / lazy checker; `[C]: in function 'assert'` | workaround documented (`cd` to a real dir before launching) |
| [`tmux-display-menu-silent-fail`](tmux-display-menu-silent-fail.md) | `prefix + Space` / `prefix + e` doesn't open the popup menu, no error | workaround documented (script + height tiers) |
| [`tmux-submenu-flash-and-bottom-right`](tmux-submenu-flash-and-bottom-right.md) | nested `display-menu` via `run-shell` from right-click parent: flash, bottom-right placement, or selection silently does nothing on 2nd open | workaround documented (inline submenu items into parent) |
| [`tmux-pane-vanishes-on-ctrl-c-despite-shell-wrapper`](tmux-pane-vanishes-on-ctrl-c-despite-shell-wrapper.md) | tmux pane built with `cmd; exec $SHELL` wrapper closes on Ctrl+C inside btop/htop/less even though clean quit (`q`/`:q`) lands in shell as designed | fixed in `dot_config/zsh/tools/22_sesh.zsh` (`trap '' INT;` prefix in `_sesh_on_exit_wrap`) |
| [`tmux-resurrect-agents`](tmux-resurrect-agents.md) | tmux-resurrect doesn't restore coding-agent / TUI sessions after `kill-server` | known limitation |
| [`tmux2k-bandwidth-uint64-underflow`](tmux2k-bandwidth-uint64-underflow.md) | `18446744073709551615K` in tmux status bar | workaround documented |
| [`tv-channel-bare-braces-break-substitution`](tv-channel-bare-braces-break-substitution.md) | TV channel preview shows literal `{split:\t:N}` instead of substituted values, no error | workaround documented (avoid bare `{...}` in heredocs; prefer external `executable_*.sh/py` helpers) |
| [`yazi-tmux-popup-crash`](yazi-tmux-popup-crash.md) | Yazi inside `display-popup` crashes tmux server, "Terminal response timeout" | workaround documented |
| [`zsh-tied-array-path-shadowing`](zsh-tied-array-path-shadowing.md) | `command not found` only inside one zsh function, works at prompt; `hash -r` / `rehash` doesn't help | fixed in `dot_config/zsh/tools/22_sesh.zsh` (rename local `path` → `target`) |
| [`tmux-resurrect-agents`](tmux-resurrect-agents.md) | reattach restores layout but agent/TUI panes come back as bare shell | workaround documented (`@resurrect-processes` whitelist) |
| [`yazi-tmux-popup-crash`](yazi-tmux-popup-crash.md) | `Terminal response timeout` from yazi → tmux server dies | workaround documented (use `new-window`, not `display-popup`) |

## Cross-referenced pitfalls (still in their original homes)

These traps are documented elsewhere and aren't duplicated here — the table
exists so grepping `pitfalls/` still finds them. Move into this folder only
if their original location stops being a natural reading flow.

| Trap | Lives in | Why not here |
|---|---|---|
| chezmoi `modify_` files clobbered by `chezmoi add` | `docs/tools/chezmoi-prefixes.md` → "Case studies in this repo" | Already part of the prefix-semantics narrative |
| chezmoi `create_` files silently skipped by `chezmoi re-add` | `docs/tools/chezmoi-prefixes.md` | Same as above |
| CodeIsland hook ping-pong with our overlay | `docs/tools/agent-overlays.md` → "CodeIsland integration" | Documented as part of overlay design |
| tmux 3.2a `display-menu` popup off-screen / silently suppressed | `AGENTS.md` Hard invariant + `dot_ansible/roles/devtools/` upgrade logic | Graduated to invariant + ansible mitigation |
| fleet-apply process substitution + sentinel ordering | `AGENTS.md` Hard invariant → "fleet-apply semantics" | Graduated to invariant |
| Sudo session `sudo -k` invalidates shared cache | `AGENTS.md` Hard invariant → "Sudo session" | Graduated to invariant |
| chezmoi `modify_settings.json` overlay vs Claude live edits | `docs/tools/agent-overlays.md` | Part of overlay design rationale |
