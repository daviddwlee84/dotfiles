# Add modern GNU `rsync` to the `base` ansible role

## Context

On this Mac, `rsync` resolves to `/usr/bin/rsync`, which is Apple's **openrsync** (`rsync 2.6.9 compatible`, protocol 29) — not GNU rsync. It rejects GNU rsync 3.x flags like `--info`, which is what caused "The rsync failed because macOS ships old rsync (no --info flag)". There is **no** Homebrew rsync installed (`/opt/homebrew/bin`, `/usr/local/bin` both empty), and `rsync` is not declared anywhere in this repo's install set.

Fix: have the dotfiles install a modern GNU `rsync` so new machines don't inherit the openrsync footgun. On macOS the brew formula (`rsync` 3.4.x, protocol 32) lands in `/opt/homebrew/bin`, which precedes `/usr/bin` on PATH, so `rsync` auto-resolves to the modern binary. On Linux `rsync` is a clean apt/yum package (and usually preinstalled and already modern) — we declare it for cross-platform symmetry and minimal-container safety.

`rsync` is a clean package on **every** platform (brew-core + apt + yum), exactly like `ripgrep`/`fd`/`curl`/`wget`/`git` — which all live in the **`base`** role. So it belongs in `base`'s existing per-OS package lists, following the `ripgrep` dual-list model, **not** in `devtools` next to `rclone` (rclone only lives there because it needs a bespoke `downloads.rclone.org` Linux block; rsync has no such need). Confirmed with the user: **base role**.

## Changes

### 1. Install — `dot_ansible/roles/base/tasks/main.yml` (3 one-line edits)

All three edits just add `rsync` to existing package lists — no new tasks, no new sudo surface (brew needs no sudo; the Debian/RedHat tasks already carry `become: true` + `tags: [sudo]`).

- **macOS brew list** (`Install base packages (macOS)`, ~line 4–17): add `- rsync` (place after `- fd`, before `- jq`, matching the approved preview).
- **Debian/Ubuntu apt list** (`Install base packages (Debian/Ubuntu)`, ~line 66–90): add `- rsync` (after `- fd-find`, before `- jq`). Package name is plain `rsync` on apt.
- **RedHat/CentOS shell loop** (`Install base packages (RedHat/CentOS)`, ~line 123–133): append `rsync` to the `for p in git git-lfs curl wget jq tree gcc gcc-c++ make; do` list → `... make rsync; do`. The loop is `rpm -q`-guarded, so this is idempotent and skips when already present.

### 2. Docs (mandatory) — `docs/this_repo/tool-managers.md`

Per the CLAUDE.md cross-file rule, a new tool via an **existing** mechanism (brew-formula-via-ansible) requires exactly **one** new row in **§ Tool index (A–Z)**. Insert alphabetically between `ripgrep` (line 1125) and `ruby` (line 1126):

```
| **rsync** | brew | apt / yum (usually preinstalled) | base — replaces macOS's built-in openrsync 2.6.9 (no `--info` etc.); brew rsync 3.x lands in `/opt/homebrew/bin` ahead of `/usr/bin` on PATH |
```

(Format = the file's 4-column `| Tool | macOS | Linux | Role |`; the trailing note mirrors the style of the `ripgrep`/`rclone` rows.)

## Surfaces intentionally NOT touched (verified, with rationale)

- **`docs/this_repo/upgrades.md`** — nothing. Brew formulae are auto-covered by the generic `brew` upgrade category (its § Extending explicitly says "Nothing to do" for a tool already under an existing category).
- **Shell completions** (`scripts/generate_completions.sh`, `docs/zsh/zsh-completions.md` Section A/F) — nothing. `rsync` ships no `--completion <shell>` generator; its completion is pre-bundled with zsh core (`_rsync`), so it's a Section B "no action needed" tool. The CLAUDE.md completion rule only fires for upstream CLIs that ship a generator.
- **`README.md`** — skip. The cross-file rule's README targets (What You Get / Supported Platforms / Quick Setup) are for platforms/prompts/setup steps; a single ubiquitous baseline CLI added to `base` isn't a headline feature (peers `git-lfs`/`tree`/`just` aren't individually surfaced there either). Can add a bullet later if desired.
- **`docs/this_repo/tool-managers.zh-TW.md`** — skip. The cross-file rule does not name the zh-TW mirror as a same-commit target for the A–Z row, and it already lags the English file (missing `resvg`/`resilio-sync`). Best-effort only.

## Verification

1. **Ansible validity** (per the "validate with the app" invariant): syntax-check plus a narrow run of the `base` role, e.g.
   `ansible-playbook dot_ansible/site.yml --tags base --check` (or the repo's `just` ansible entrypoint) — confirm no parse/template errors and the base-packages task is green.
2. **Actual install** on this Mac: `chezmoi apply` (the base role file changing re-triggers `run_onchange_after_20_ansible_roles.sh.tmpl`), or run the base role directly.
3. **Confirm the modern binary wins**:
   - `which -a rsync` → `/opt/homebrew/bin/rsync` listed first.
   - `rsync --version` → `rsync  version 3.4.x  protocol version 32` (not `2.6.9 compatible` / not `openrsync`).
   - `rsync --info=progress2 --version` (or any `--info` invocation) no longer errors — the original failure is resolved.
4. **Docs**: `uv run mkdocs build --strict` still passes (note: known baseline warnings are pre-existing and unrelated — a clean build vs. the documented baseline is the check, not zero warnings).
