# `.chezmoiscripts/` layout

This repo organises auto-run scripts into a two-bucket layout under
`.chezmoiscripts/` that encodes **scope** (which machines should re-run
when the script changes) in the directory name:

```
.chezmoiscripts/
├── global/   # Runs on every machine that consumes this repo
│   ├── run_onchange_after_20_ansible_roles.sh.tmpl
│   ├── run_onchange_after_25_bat_theme.sh.tmpl
│   ├── run_onchange_after_30_brew_bundle.sh.tmpl
│   ├── run_onchange_after_32_raycast_config.sh.tmpl
│   └── run_onchange_after_40_install_global_skills.sh.tmpl
└── repo/     # Runs only when the chezmoi source dir IS this repo working tree
    └── run_onchange_after_45_bootstrap_skills.sh.tmpl
```

Plus four `run_*before_*` scripts that intentionally stayed at the
repo root — see [What's still at the repo root](#whats-still-at-the-repo-root-and-why)
below.

## What's still at the repo root (and why)

Four `run_*before_*` scripts deliberately stayed at the repo root:

| Script | Phase | Why not moved |
|---|---|---|
| `run_once_before_00_bootstrap.sh.tmpl` | once, before | sudo session init + locale fix; `run_once_*` is path-keyed in chezmoi state, so moving forces a re-run on every machine |
| `run_before_01_backup_dotfiles.sh.tmpl` | every, before | Backs up dotfiles before chezmoi overwrites. Three modes via `backupMode`: `smart` (default; uses `chezmoi status` to back up only files apply would modify/delete — clean host produces no backup), `full` (hardcoded allowlist, onboarding mode), `off`. Inspect via `just list-backups` / `just diff-backup <TS>`. |
| `run_once_before_02_fix_intel_homebrew.sh.tmpl` | once, before | Intel Mac brew prefix migration; same `run_once_*` state-tracking concern as `00` |
| `run_once_before_50_opencode_migrate.sh.tmpl` | once, before | One-shot opencode CLI config migration; would re-run if path changes |

The `run_once_*` scripts are state-tracked **by path** in
`chezmoi state` (the `scriptState` bucket is keyed on a hash that
includes the script's source path). Moving them would either re-run the
once-only logic on every existing machine, or require coordinated
`chezmoi state delete-bucket --bucket=scriptState` surgery on each host.
The `run_onchange_after_*` scripts moved earlier had the same property
but their re-run cost was acceptable (idempotent ansible / brew bundle);
for `run_once_before_*` the cost is higher and less predictable
(`00_bootstrap` reinstalls base packages, `50_opencode_migrate` re-applies
a one-shot migration).

Plus there's no scope ambiguity to resolve: all four are global. The
`global/` vs `repo/` split that motivated the move for `_after_` scripts
doesn't exist on the `_before_` side, so the directory wouldn't carry
information.

If a future `run_*before_*` script genuinely needs `repo/` scope
(e.g. a project-skills bootstrap that must run before chezmoi applies),
revisit this decision — at that point the bucket starts to encode
scope and the move is worth the re-run cost.

## Why nested?

Two reasons:

1. **Scope is a hard contract** — `repo/` scripts must NOT fire on machines
   that only consume the repo (e.g. a remote server `chezmoi init`'d from
   the GitHub URL). Encoding the scope in the path makes the contract
   visible at a glance and harder to violate by accident; the script
   itself still has to gate on `eq .chezmoi.sourceDir <repo-root>`.
2. **Repo-root tidiness** — six `run_onchange_after_*.sh.tmpl` files at
   the top level pushed past the noise threshold. The 2-bucket split keeps
   `ls` of the repo root scannable without losing the numeric phase
   ordering that controls run order within each bucket.

## Why this works (chezmoi behaviour)

`.chezmoiscripts/` accepts subdirectories. They are not part of any public
"feature" but the behaviour has been confirmed in chezmoi issues:

- [twpayne/chezmoi#2013 — `.chezmoiscripts` sub directories](https://github.com/twpayne/chezmoi/issues/2013)
- [twpayne/chezmoi#3246 — ASCII ordering in subdirectories](https://github.com/twpayne/chezmoi/issues/3246)

The maintainer's own dotfiles use the same pattern:
[twpayne/dotfiles](https://github.com/twpayne/dotfiles).

### Application order

Within each `before_` / `after_` phase, chezmoi sorts scripts by their
**full path** in ASCII order (case-sensitive). For our layout:

```
.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl
.chezmoiscripts/global/run_onchange_after_25_bat_theme.sh.tmpl
.chezmoiscripts/global/run_onchange_after_30_brew_bundle.sh.tmpl
.chezmoiscripts/global/run_onchange_after_32_raycast_config.sh.tmpl
.chezmoiscripts/global/run_onchange_after_40_install_global_skills.sh.tmpl
.chezmoiscripts/repo/run_onchange_after_45_bootstrap_skills.sh.tmpl
```

`g` < `r` in ASCII, so `global/` always sorts before `repo/`. Within
each bucket the numeric prefix takes over (`20 < 25 < 30 < …`). The
overall order matches what the flat layout produced — by design — so
this refactor was a pure structural change with no behaviour delta.

If we later add `darwin/` / `linux/` subdirs underneath `global/`, those
nested scripts still sort by their full path; mixing
`global/run_onchange_after_20_*` with `global/darwin/run_onchange_after_30_*`
will alphabetise as:

```
global/darwin/run_onchange_after_30_…    # `d` < `r`, so subdir wins!
global/run_onchange_after_20_…
```

This is a footgun: **adding a subdir under `global/` will reorder existing
scripts** because directory names sort against file names alphabetically.
If/when we add OS subdirs, plan the rename so the order is intentional
(e.g. prefix the OS dirs with `_darwin/` `_linux/` to push them past
top-level files alphabetically).

## What goes where

- **`global/`** — anything that must converge state on every machine
  consuming this repo. Examples:
  - Ansible roles (system packages, dotfile-adjacent tools)
  - Brewfile sync
  - bat theme rebuild
  - Raycast config import (gated on `syncRaycast` opt-in)
  - Global skills restore (`~/.agents/.skill-lock.json` → `~/.agents/skills/`)

- **`repo/`** — anything that ONLY makes sense when the local source dir
  IS this repo's working tree (not a deploy-from-GitHub consumer). Today
  this is just project-scope skills bootstrap (`./skills-lock.json` →
  `./.agents/skills/`); the script's first action is to check
  `[[ "$(cd ~/.local/share/chezmoi && pwd)" == "$source_dir" ]]` and
  exit 0 otherwise.

If you add a script that should run **only on Apple Silicon** or
**only with sudo** — that's still scope, but a different axis (OS / capability),
and the current 2-bucket layout doesn't carve a place for it. Three options:

1. Put it in the appropriate scope bucket and gate inside the script with
   a chezmoi template guard (`{{ if eq .chezmoi.os "darwin" }}exit 0{{ end }}`).
   This is what we do today; works for ≤ 2 OS-only scripts.
2. Add `global/darwin/` and `global/linux/` subdirs once OS-only scripts
   reach ~3+. Re-evaluate the alphabetical-ordering footgun above first.
3. Document an alternative layout in `backlog/chezmoiscripts-namespace-refactor.md`
   and revisit the structural decision wholesale.

## Cross-references

- Decision log: [`backlog/chezmoiscripts-namespace-refactor.md`](../../backlog/chezmoiscripts-namespace-refactor.md)
- Auto-run scripts table: [`docs/this_repo/architecture.md`](architecture.md)
- chezmoi docs: [`.chezmoiscripts/`](https://www.chezmoi.io/reference/special-directories/chezmoiscripts/),
  [Application order](https://www.chezmoi.io/reference/application-order/)
