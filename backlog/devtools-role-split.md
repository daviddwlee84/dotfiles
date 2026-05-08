# Split `devtools` mega-role into focused per-tool roles

**Status**: P3 / deferred
**Effort**: L
**Related**: `TODO.md` (P3 lane), `dot_ansible/roles/devtools/tasks/main.yml`, `dot_ansible/playbooks/{linux,macos}.yml`

## Context

Surfaced 2026-05 while adding the standalone `atuin` role. User asked
whether atuin should be its own role or merged into `devtools`. The answer
was "standalone" — but the discussion exposed that `devtools` is already
a 166-task mega-role bundling ~50 unrelated tools, and most of its
siblings (`atuin`, `starship`, `neovim`, `docker`, `bitwarden`,
`coding_agents`, `homebrew`, `iac_tools`, `js_cli_tools`,
`lazyvim_deps`, `media_tools`, …) are appropriately scoped standalone
roles. `devtools` is the outlier.

## Investigation

```
$ grep -c "^- name:" dot_ansible/roles/devtools/tasks/main.yml
166

$ grep -E "^- name: (Install|Tap)" dot_ansible/roles/devtools/tasks/main.yml \
    | grep -oE "(Install|Tap) [a-z][a-zA-Z0-9_-]*" | sort -u
Install banner / bat / bats / btop / dasel / diffnav / direnv / eza /
fastfetch / freeze / gh / gh-dash / git-delta / git-graph / glab / glow /
gum / htop / jnv / lnav / pandoc / rclone / sesh / superfile / tailspin /
taplo / television / tldr / tmux / vhs / witr / worktrunk / yazi / yq /
zellij / zoxide … (~40 distinct tools)
```

Existing breakage signals already in `TODO.md`:

- P2 line 52: "devtools: gate `Install tmux plugins via TPM` on tmux being on PATH" (centos/rocky9 noroot fatality).
- P2 line 53: "devtools role: broaden remaining user-level fallbacks to RedHat" (~30 tasks gated `Debian`-only).
- P3 line 69: "CentOS / RedHat: broaden user-level fallback gates in remaining roles" calls out devtools as the largest offender (~20 hits).

Each of those is a per-tool change living in a pile of unrelated tasks.
A split would let each tool's RedHat/CentOS broadening be a self-contained
PR scoped to one role.

## Options considered

| Option | Pros | Cons |
|---|---|---|
| A. Leave it | Zero churn. `state: present` + `creates:` already make idempotent re-runs cheap. | Every future per-tool tweak edits the same monster file; conflict-prone. Hard to skip individual tools per-host. |
| B. Split into ~6 cohesive roles + meta-role | Each tool group owns its own RedHat/Debian/macOS branches. Per-host opt-out is one playbook line. Easier code review. | ~6 new roles to maintain; need to wire them into both playbooks; risk of churn on first cut. |
| C. One role per tool (~40 roles) | Maximum granularity. Mirrors atuin/starship/zoxide pattern exactly. | Playbook becomes ~50 lines of `- role:` entries; role discovery noise; cross-tool task ordering harder to reason about. |

### Proposed grouping for option B

| New role | Covers | Rough task count |
|---|---|---|
| `shell_addons` | zoxide, eza, bat, sesh, tldr, direnv | ~25 |
| `tui_apps` | yazi, superfile, btop, htop, lazygit, fastfetch, banner | ~30 |
| `git_tools` | gh, glab, git-delta, git-graph, diffnav, gh-dash, gum (used by git scripts) | ~30 |
| `format_tools` | yq, jnv, dasel, taplo, pandoc, glow, freeze, vhs, lnav, tailspin | ~35 |
| `tmux_stack` | tmux upgrade (Linuxbrew / appimage logic) + zellij + TPM install + plugin sync | ~20 |
| `misc_devtools` | rclone, witr, worktrunk, anything that doesn't fit | ~25 |

Plus a `devtools_all` meta-role that just does `dependencies: [shell_addons, tui_apps, git_tools, format_tools, tmux_stack, misc_devtools]` so existing playbook entries (`- role: devtools`) keep working with one rename (`devtools` → `devtools_all`).

## Current blocker / open questions

1. **Migration order**: do we land all 6 roles at once, or extract one at a time (e.g. `tmux_stack` first because it has the most cross-cutting concerns)? Incremental is safer but means `devtools/tasks/main.yml` shrinks across many PRs.
2. **Variable namespacing**: the current role uses module-level facts (e.g. `is_linuxbrew`, `is_arm64`) registered in early tasks. Splits need to either (a) duplicate the detection in each role, (b) hoist into a `pre_tasks:` block in each playbook, or (c) move into the existing `base` role's facts.
3. **`os_family == "Debian"` gate cleanup**: the split is the natural moment to do the P2/P3 RedHat-broadening work. Bundling them increases scope but avoids touching each task twice.
4. **CI**: existing `just docker-test-*` smoke tests target the playbook entry, so they should pass through unchanged with the meta-role. Verify with rocky9 + ubuntu jammy + centos7-noroot images.

## Next steps when picked up

1. Audit the 166 tasks; produce the canonical mapping table (extension of the table above) listing every `- name:` line and its target role.
2. Land role 1 (recommend `shell_addons` — small, self-contained, frequently touched).
3. Once the playbook is happy with `- role: shell_addons` AND `- role: devtools` (with the migrated tasks deleted), proceed to role 2.
4. After all six lands, introduce `devtools_all` meta-role and delete the now-empty `devtools` role (or rename `devtools` → `devtools_all` directly).
5. Update `docs/playbooks/workflow.md` and `mkdocs.yml` if a new docs page per role is desired.

## Why "deferred"

No active pain — `chezmoi apply` works, `state: present` keeps re-runs cheap, the in-flight P2/P3 RedHat-broadening work can land against the existing structure. Pick this up the next time a refactor of `devtools/tasks/main.yml` is on the table for another reason (e.g. needing per-host opt-out granularity, or hitting ansible task-count performance).
