# Migrate run_onchange scripts into `.chezmoiscripts/` with global/repo namespaces

**Status**: P2 ready
**Effort**: M
**Related**: `TODO.md` · `run_onchange_after_*.sh.tmpl` (6 files at repo root) · `docs/tools/agent-skills.md` · chezmoi reference: `.chezmoiscripts/`

## Context

2026-04, surfaced while shipping `run_onchange_after_45_repo_bootstrap_skills.sh.tmpl`
(the project-skills auto-bootstrap, sibling of the global-skills installer). Two
problems became visible at once:

1. The repo root is starting to accumulate `run_onchange_after_*.sh.tmpl` files
   (now 6: ansible_roles, bat_theme, brew_bundle, raycast_config,
   install_global_skills, repo_bootstrap_skills). Visually noisy in `ls`.
2. There's no naming distinction between "global / runs on every machine"
   scripts and "repo-scope / only meaningful when this machine edits the repo"
   scripts. The latter currently has just one entry (the new one), but the
   pattern will repeat — every future "if you're editing the repo, also
   bootstrap X" hook lands at repo root next to genuinely-global ones.

Step 1 (already shipped): added `repo_` infix to the new script as a
provisional marker (`run_onchange_after_45_repo_bootstrap_skills.sh.tmpl`). All
existing scripts are implicitly "global" by absence of any infix.

Step 2 (this entry): move everything into `.chezmoiscripts/<scope>/...` to make
the scope explicit and tidy up the source root.

## Investigation

### `.chezmoiscripts/` nested folder support — undocumented but stable

Official docs only describe `.chezmoiscripts/` as a flat directory. Verified
via upstream issues that **nested subdirectories work and are stable**:

- [#2013 — `.chezmoiscripts` sub directories](https://github.com/twpayne/chezmoi/issues/2013):
  closed as completed; user observed `twpayne`'s own dotfiles
  ([`twpayne/dotfiles`](https://github.com/twpayne/dotfiles)) organize scripts
  into `.chezmoiscripts/<os>/` subdirs since chezmoi v2.8. Maintainer-blessed
  pattern by example.
- [#3246 — Script execution not following ASCII order in subdirectories](https://github.com/twpayne/chezmoi/issues/3246):
  closed as expected behaviour. Confirms: **the entire script tree is sorted
  by path (directory names included)**, not flattened-then-sorted. Implication
  for our case: `global/run_onchange_after_20_*` sorts before
  `repo/run_onchange_after_45_*` because `g` < `r` lexicographically — happens
  to align with the existing 20→45 numeric sequence. Lucky.

### Re-run blast radius

Moving any `run_onchange_` script changes its source path → chezmoi treats it
as a brand-new script and re-runs once. Per-script analysis:

| Script | Re-run cost | Side-effect risk | Mitigation |
|---|---|---|---|
| `ansible_roles` | High — entire ansible playbook (25+ roles) | **Low**: all roles are `state: present` / `creates:` install-only by [Hard invariant](../AGENTS.md#install-vs-upgrade-is-split-on-purpose). Re-run is idempotent, ~5-10 min. | Acceptable; one-time per machine |
| `bat_theme` | Low — `bat cache --build`, seconds | None | None needed |
| `brew_bundle` | Medium — `brew bundle check && bundle` | Low: `brew bundle` only installs missing, doesn't upgrade existing | None needed |
| `raycast_config` | Low — opt-in (`syncRaycast=false` on most machines) early-exits | Re-imports Raycast config on enabled machines; idempotent | None needed |
| `install_global_skills` | Low — fast-path (all SKILL.md present → exit) | None | None needed |
| `repo_bootstrap_skills` | Low — same fast-path | None | None needed |

**Bottom line**: every machine pays one ~5-10 min ansible idempotent re-run on
the apply that follows the refactor. Everything else is seconds or no-op.

### `before_/after_` ordering across `.chezmoiscripts/` tree

Confirmed: `.chezmoiscripts/global/run_before_*` still runs before any file
update; `.chezmoiscripts/repo/run_after_*` still runs after. The `before_/
after_` modifier survives the directory move. Only the **alphabetical ordering
within a phase** changes (path-aware now).

## Options considered

| Option | Pros | Cons |
|---|---|---|
| **A. `.chezmoiscripts/{global,repo}/`** (2-level, scope-only) | Minimal taxonomy, matches current actual diversity (5 global + 1 repo). Easy to extend per-scope without re-organising. | Doesn't pre-empt finer slices (per-OS, per-tool). May split again later. |
| **B. `.chezmoiscripts/global/{install,sync}/` + `repo/...`** (3-level by intent) | Models the install-only invariant explicitly: `install/ansible_roles` declares "never upgrades"; `sync/raycast_config` declares "re-imports state on every change". | 6 scripts is too few for a 3-level taxonomy; risk of over-engineering. Sync vs install line is fuzzy for `bat_theme` (cache rebuild — neither?). |
| **C. `.chezmoiscripts/{darwin,linux,global,repo}/`** (twpayne's pattern) | Mirrors the project's sole maintainer-blessed example. Useful when a script becomes OS-specific (currently `bat_theme` and `brew_bundle` already template-branch internally — could split). | Premature: only `raycast_config` is truly macOS-only; rest run cross-platform. Splitting now duplicates the OS-detection logic that already lives inside the templates. |
| **D. Stay flat at repo root** (current) | Zero migration cost. | Doesn't solve the visual noise or the global/repo confusion. |

## Recommendation: Option A, leave room to grow

```
.chezmoiscripts/
  global/
    run_onchange_after_20_ansible_roles.sh.tmpl
    run_onchange_after_25_bat_theme.sh.tmpl
    run_onchange_after_30_brew_bundle.sh.tmpl
    run_onchange_after_32_raycast_config.sh.tmpl
    run_onchange_after_40_install_skills.sh.tmpl
  repo/
    run_onchange_after_45_bootstrap_skills.sh.tmpl
```

Rationale: 6 scripts don't justify Option B's 3-level taxonomy yet; OS-split
(Option C) is premature when only one script is truly OS-gated. Option A
gives the immediate win (scope clarity + tidier root) and leaves the tree
shallow enough to reorganise later without disturbing the sort order
(if we add a `darwin/` subdir under `global/` later, scripts there still
sort by their full path — predictable).

### Implementation checklist

1. `mkdir -p .chezmoiscripts/{global,repo}/`
2. `git mv` 5 scripts to `.chezmoiscripts/global/`, 1 to `.chezmoiscripts/repo/`.
   Drop the now-redundant `repo_` infix from the moved file:
   `run_onchange_after_45_bootstrap_skills.sh.tmpl` (scope is encoded in the
   directory).
3. Update cross-references:
   - `AGENTS.md` — search `run_onchange_after_` and update paths
   - `docs/tools/agent-skills.md` — both restorer script paths
   - `.chezmoiignore.tmpl` and `.gitignore` comments
   - The `# merger:` hash trigger inside `run_onchange_after_40_install_skills.sh.tmpl`
     uses `{{ include "dot_agents/modify_dot_skill-lock.json.tmpl" | sha256sum }}`
     — that's a chezmoi template path, **unaffected** by the script's own move.
4. Verify with `chezmoi apply --dry-run` (should be silent — no template render
   errors).
5. Document the de facto nested-folder behaviour in
   `docs/this_repo/chezmoiscripts-layout.md` (new file): cite issues #2013 /
   #3246, link `twpayne/dotfiles` as precedent, explain the global/repo split.
6. **Test on one machine first** before pushing. The ansible re-run is the
   only real risk surface; if it fails non-idempotently on any role, surface
   it (likely a `creates:` missing somewhere) and pin that in
   `pitfalls/ansible-not-actually-idempotent-<role>.md` before continuing.

## Current blocker / open questions

- None — ready to ship after Step 1 lands (the `repo_` infix that this entry
  will retire).
- Open: should `.chezmoitemplates/` get the same treatment if it grows? Not
  this entry — re-evaluate when there are >5 root-level templates.

## References

- chezmoi docs: [`.chezmoiscripts/`](https://www.chezmoi.io/reference/special-directories/chezmoiscripts/)
- chezmoi docs: [Application order](https://www.chezmoi.io/reference/application-order/) (re: alphabetical within `before_`/`after_` phases)
- [Issue #2013 — `.chezmoiscripts` sub directories](https://github.com/twpayne/chezmoi/issues/2013) (closed, behaviour confirmed)
- [Issue #3246 — ASCII ordering in subdirectories](https://github.com/twpayne/chezmoi/issues/3246) (closed, ordering rule confirmed)
- [`twpayne/dotfiles`](https://github.com/twpayne/dotfiles) — maintainer's own use of nested `.chezmoiscripts/`
- AGENTS.md → "Install vs upgrade is split on purpose" — guarantees ansible re-run safety
