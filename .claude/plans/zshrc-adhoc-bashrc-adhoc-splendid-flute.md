# Unified shared adhoc/secrets layer for both shells

## Context

This repo currently has two parallel "user-local override" surfaces:

| File | Sourced by | Auto-created stub | Purpose |
|---|---|---|---|
| `~/.zshrc.adhoc` | zsh only | yes (in `dot_zshrc.tmpl`) | Quick zsh experiments, machine-local overrides |
| `~/.bashrc.adhoc` | bash only | yes (in `dot_bashrc.tmpl`) | Same but bash-only |
| `~/.config/zsh/secrets.zsh` | zsh only | no | API keys / tokens for zsh |
| `~/.config/bash/secrets.sh` | bash only | no | Same but bash-only |

Two friction points:

1. **No shared override layer.** Anything POSIX-portable (an `export FOO=bar`,
   a vendor-installer `eval "$(...)"` line, a `PATH=` prepend) has to be pasted
   into BOTH `~/.zshrc.adhoc` AND `~/.bashrc.adhoc` — easy to drift, easy to
   forget the other shell.
2. **Inconsistent locations.** Adhoc lives in `$HOME` while secrets live deep
   in `~/.config/{zsh,bash}/`. New users hunting "where do I put my OPENAI_API_KEY"
   have to check two places per shell, four total.

The fix: add two new POSIX-shared user-local files at the top level, mirroring
the existing `.adhoc` naming, and document the whole tier system in one place.

## Design

### File tier table (final shape)

| Tier | File | Scope | Lifecycle | Purpose |
|---|---|---|---|---|
| 1 | `~/.config/shell/*.sh` | both shells | chezmoi-managed | Shared POSIX modules (env, PATH, tool init, aliases) |
| 1 | `~/.config/zsh/*.zsh` | zsh only | chezmoi-managed | zsh-only modules (ZLE widgets, compdef) |
| 1 | `~/.config/bash/*.bash` | bash only | chezmoi-managed | bash-only modules (ble-bind, OMB) |
| **2** | **`~/.shellrc.secrets`** ← NEW | **both shells (POSIX)** | user-local, gitignored | Shared API keys / tokens. Source-of-truth for anything both shells need. |
| 2 | `~/.config/zsh/secrets.zsh` | zsh only | user-local | Shell-specific secrets (e.g. zsh-only completion tokens) |
| 2 | `~/.config/bash/secrets.sh` | bash only | user-local | Shell-specific secrets |
| **3** | **`~/.shellrc.adhoc`** ← NEW | **both shells (POSIX)** | user-local, auto-stubbed | Shared experiments / machine overrides |
| 3 | `~/.zshrc.adhoc` | zsh only | user-local, auto-stubbed | zsh-only experiments (ZLE widgets, `bindkey`, `setopt`) |
| 3 | `~/.bashrc.adhoc` | bash only | user-local, auto-stubbed | bash-only experiments (`bind -x`, `ble-bind`) |

**Rule of thumb for users**: write everything in `~/.shellrc.{adhoc,secrets}`
*by default*. Drop down to per-shell only when you need a zsh-only construct
(ZLE widget, `read -q`, `${m:t}`, `setopt`, `compdef`) or a bash-only one
(`bind -x`, `ble-bind`, `shopt`).

### Load order

**zsh** (`dot_zshrc.tmpl`):

```
1. Shared POSIX modules            ~/.config/shell/*.sh
2. zsh modules                     ~/.config/zsh/*.zsh + tools/*.zsh
3. Shared secrets (NEW)            ~/.shellrc.secrets
4. zsh secrets                     ~/.config/zsh/secrets.zsh
5. Shared adhoc (NEW)              ~/.shellrc.adhoc
6. zsh adhoc                       ~/.zshrc.adhoc
```

**bash** (`dot_bashrc.tmpl`, mapped to existing 12-step order):

```
... steps 1-7 unchanged ...
 8. atuin init
 9a. Shared secrets (NEW)          ~/.shellrc.secrets    ← before ble-attach
 9b. bash secrets                  ~/.config/bash/secrets.sh
10. ble-attach
11. ~/.bash_aliases + ~/.bashrc.d/*
12a. Shared adhoc (NEW)            ~/.shellrc.adhoc      ← after ble-attach
12b. bash adhoc                    ~/.bashrc.adhoc
```

**Precedence**: shared sourced FIRST, per-shell SECOND. Per-shell wins on
conflict — same rule as the existing `~/.bash_aliases`-vs-`.bashrc.adhoc`
ordering. Secrets sourced before adhoc so `~/.shellrc.adhoc` can reference
secret values.

### Why these names

`~/.shellrc.{adhoc,secrets}` is a syntactic mirror of the existing
`~/.{zsh,bash}rc.{adhoc}`. The "shellrc" prefix makes it obvious the file is
sourced by every interactive shell, with a POSIX-only constraint.

Alternative names (`.profile.adhoc` → confuses with login shells; `.shrc.adhoc`
→ BSD-style but unfamiliar to most Linux/macOS users) were considered and
rejected.

### POSIX-only constraint (documented + enforced socially)

The auto-stub for `~/.shellrc.adhoc` (and the doc page) explicitly say:
**no zsh-isms, no bash-isms.** If shell detection is needed, dispatch via
`$ZSH_VERSION` / `$BASH_VERSION` — the same convention `dot_config/shell/*.sh`
already uses. (Cannot enforce mechanically; this is policy, not validation.)

## Files to change

### 1. `dot_zshrc.tmpl` (lines ~128–157)

Add two new source blocks:

- **Before** the existing `[[ -r "$ZSH_CONFIG_DIR/secrets.zsh" ]] && source ...`
  on line 129, add: `[[ -r "$HOME/.shellrc.secrets" ]] && source "$HOME/.shellrc.secrets" || true`
- **Before** the auto-create-stub block at lines 136–154, add an analogous
  auto-create-stub block for `~/.shellrc.adhoc` (with POSIX-only warning in
  the heredoc) followed by `[[ -r "$HOME/.shellrc.adhoc" ]] && source "$HOME/.shellrc.adhoc"`.
  Keep existing `~/.zshrc.adhoc` block + source line AFTER it (per-shell wins).

### 2. `dot_bashrc.tmpl` (lines ~128–193)

Two analogous insertions:

- **Step 9a (new)**: insert before line 130 — `[ -r "$HOME/.shellrc.secrets" ] && . "$HOME/.shellrc.secrets"`. Renumber step 9 → step 9b in the comment header.
- **Step 12a (new)**: before the `~/.bashrc.adhoc` auto-create-stub at line 167,
  add an analogous auto-create-stub for `~/.shellrc.adhoc` (POSIX-only heredoc),
  then `[ -r "$HOME/.shellrc.adhoc" ] && . "$HOME/.shellrc.adhoc"`. Existing
  step 12 renumbers to 12b.

### 3. `.chezmoiignore.tmpl` (after line 95)

Add two entries:

```
# Personal shared adhoc/secrets layer (POSIX-only, both shells).
# Auto-created on first shell launch; never tracked.
.shellrc.adhoc
.shellrc.secrets
```

### 4. `docs/shells/adhoc-and-secrets.md` (NEW)

New canonical doc page covering:

- The 3-tier × 3-scope file matrix above
- Decision flowchart: "I want to add an env var / alias / binding — which file?"
- Precedence rules (shared-then-per-shell, secrets-then-adhoc)
- POSIX-only constraint for shared files + how to dispatch on shell
  (`$ZSH_VERSION` / `$BASH_VERSION`) when needed
- Examples for each tier (an OPENAI_API_KEY in `~/.shellrc.secrets`,
  a `setopt` in `~/.zshrc.adhoc`, a `bind -x` in `~/.bashrc.adhoc`)
- Cross-link to `docs/shells/architecture.md` and `docs/this_repo/config-conventions.md`

### 5. `mkdocs.yml`

Add nav entry under the "Zsh" or "Shells" section (whichever matches
existing `aliases.md` / `history.md` / `bash.md` placement) — alphabetical:
`adhoc-and-secrets.md`.

### 6. `CLAUDE.md` — Hard repo invariants section

Add a one-paragraph entry under "Hard repo invariants" near the existing
"`primaryShell` choice gates `chsh` only" rule:

> ### Three-tier override layer (shared / per-shell × adhoc / secrets)
>
> User-local overrides live in six files: shared POSIX (`~/.shellrc.adhoc`,
> `~/.shellrc.secrets`) and per-shell (`~/.{zsh,bash}rc.adhoc`,
> `~/.config/{zsh,bash}/secrets.{zsh,sh}`). Shared sourced first, per-shell
> wins on conflict. Secrets sourced before adhoc. All six are
> chezmoi-ignored. **Do not** add the shared files to chezmoi management or
> auto-create them with shell-specific syntax. Full matrix:
> [docs/shells/adhoc-and-secrets.md](docs/shells/adhoc-and-secrets.md).

### 7. `docs/shells/architecture.md` (small update)

The existing mention of `~/.bashrc.adhoc` / `~/.zshrc.adhoc` (around lines
114–115, 241 per exploration) gets a one-line cross-reference to the new doc:
"For shared `~/.shellrc.{adhoc,secrets}` see [adhoc-and-secrets.md](adhoc-and-secrets.md)."

### 8. `docs/shells/aliases.md` (CLAUDE.md mandates this)

If we introduce ANY new alias/function in the chezmoi-managed surfaces as part
of this change, the table must be updated. **In this design we add zero new
managed aliases**, so this file is untouched. (Noted here so the reviewer
doesn't flag it as a missed update.)

## Reused existing patterns

- **Auto-create stub heredoc**: the new `~/.shellrc.adhoc` block reuses the
  exact pattern from `dot_zshrc.tmpl:136-154` and `dot_bashrc.tmpl:167-190`.
- **Source guard**: `[[ -r ... ]] && source ...` (zsh) / `[ -r ... ] && . ...`
  (bash) — same as existing secrets/adhoc lines.
- **Chezmoi-ignored personal files**: `.chezmoiignore.tmpl` already has 4
  ignore lines for the existing per-shell variants; the 2 new entries follow
  the same comment style.

## Verification

1. **Dry-run apply**:
   `chezmoi diff` — should show only the 8 file edits above + the new doc.
   `chezmoi apply --dry-run -v`.
2. **Apply on the local machine** (`self` host): `just apply`.
3. **Confirm auto-creation**: open a fresh shell of each kind. Verify
   `~/.shellrc.adhoc` is created (with POSIX-only warning in the stub) and
   `~/.shellrc.secrets` is NOT auto-created (secrets files should be
   user-explicit; only adhoc gets a stub — matches existing behavior).
4. **Functional test**:
   - `echo 'export __SHELLRC_ADHOC_TEST=shared' >> ~/.shellrc.adhoc`
   - `zsh -ic 'echo $__SHELLRC_ADHOC_TEST'` → `shared`
   - `bash -ic 'echo $__SHELLRC_ADHOC_TEST'` → `shared`
   - Same for `~/.shellrc.secrets`.
5. **Precedence test**: set the same variable in both `~/.shellrc.adhoc`
   (value `shared`) and `~/.zshrc.adhoc` (value `zshlocal`). Confirm zsh
   sees `zshlocal` (per-shell wins).
6. **MkDocs strict build**: `uv run mkdocs build --strict` — no broken links
   on the new page or its cross-references.
7. **Cleanup test variable** from both adhoc files when done.

## Out of scope (intentionally not doing)

- Migrating existing `~/.config/{zsh,bash}/secrets.*` content into
  `~/.shellrc.secrets`. Users do that on their own machines if they want; the
  per-shell files stay as a fallback.
- Changing the `dot_config/shell/` modular loader or its `*.sh` glob — the
  new files live in `$HOME`, not `$XDG_CONFIG_HOME`, so the loader is
  untouched.
- Renaming any existing files. All four legacy paths
  (`~/.{zsh,bash}rc.adhoc`, `~/.config/{zsh,bash}/secrets.*`) keep working
  unchanged.
