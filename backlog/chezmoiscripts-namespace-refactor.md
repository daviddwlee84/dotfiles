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

Eight namespace schemes brainstormed 2026-04. Listed by orthogonal axis they
exploit (scope / OS / trigger-source / semantic / phase / hybrids).

| Option | Layout sketch | Pros | Cons |
|---|---|---|---|
| **A. Pure scope (2 dirs)** | `.chezmoiscripts/{global,repo}/` | Minimal taxonomy, matches current 5+1 distribution, zero judgement burden | `global/` still mixes ansible/brew/skills internally; not future-proof past ~10 scripts |
| **B. Scope × OS** | `global/{darwin,linux,cross}/` + `repo/` | Maintainer-blessed pattern (`twpayne/dotfiles` uses it); OS-only logic exits templates | Premature: only `raycast_config` is truly darwin-only today; `cross/` is awkward naming |
| **C. Scope × trigger source** | `global/{ansible,brew,config-cache,skills}/` + `repo/skills/` | One glance reveals what each script watches; new scripts auto-find a home | Most buckets would hold 1 script — directory-per-file overhead |
| **D. Scope × semantic** | `global/{install,sync,bootstrap}/` + `repo/bootstrap/` | Encodes the [Install vs upgrade is split](../AGENTS.md#install-vs-upgrade-is-split-on-purpose) Hard invariant in directory names; `install/` literally declares "never upgrades" | install vs bootstrap line is fuzzy (skills install belongs where?); 6 scripts ÷ 3 buckets = density too low |
| **E. Pure trigger source (no scope)** | `.chezmoiscripts/{ansible,brew,config-imports,skills-global,skills-repo}/` | Trigger-source as primary axis | Loses scope visibility — and scope is a hard contract (repo-only must NOT run on consumer machines); burying it in filenames is dangerous. `skills-global` vs `skills-repo` reintroduces scope, contradicting the premise |
| **F. Scope × Phase (`before_`/`after_`)** | `global/{before,after}/` + `repo/{before,after}/` | Visually reinforces ordering | Currently 100% are `after_`, so the split would convey zero information; phase already lives in the filename — redundant |
| **G. Hybrid: scope flat + OS sub-dir on demand** | `global/<NN>_*.sh.tmpl` + `global/darwin/<NN>_*.sh.tmpl` (only when truly OS-bound) + `repo/...` | A's simplicity + B's extensibility, but only pays the OS-dir cost when needed; raycast sinks one level, others stay flat | "When to open a sub-dir" is a soft judgement → future maintainers may answer inconsistently |
| **H. Scope dirs + verb prefix in filename** | `global/20_install_ansible_roles.sh.tmpl`, `global/25_sync_bat_theme.sh.tmpl`, etc. | Verb visible without entering directory; greppable | Long filenames; squashes D's and B's axes into the name → readability loss |

## Decision (2026-04)

**Chose Option A (pure scope, 2 dirs)**.

Inputs to the decision:

- **Future OS-only scripts**: ≤ 1-2 expected (raycast is current outlier;
  most "OS-specific" logic is internal `{{ if eq .chezmoi.os "darwin" }}`
  template branching that doesn't justify directory-level split). → Option G
  is over-engineered.
- **1-year growth**: < 10 scripts total expected. → Option D's 3-bucket
  semantic split would average 2-3 scripts per bucket — taxonomy denser than
  data. Reconsider D when total exceeds ~12.
- **Scope contract is hard, OS is soft**: repo-only scripts MUST NOT run on
  consumer machines (script self-gates via `joinPath .chezmoi.sourceDir
  "skills-lock.json" | stat`). OS-specific scripts merely should-not-run on
  the wrong OS but failing safely is fine via template `exit 0`. So scope
  deserves directory-level visibility; OS doesn't.

Revisit triggers (when to upgrade A → something else):
- Scripts ≥ 12 → consider D (semantic) or C (trigger-source)
- OS-only scripts ≥ 3 → consider G (add `darwin/` sub-dir under `global/`)
- New host class emerges (e.g., ML-only, server-only) → consider new
  top-level scope dir alongside `global/` and `repo/` (e.g., `ml/`)

## Recommendation

Option A:

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
