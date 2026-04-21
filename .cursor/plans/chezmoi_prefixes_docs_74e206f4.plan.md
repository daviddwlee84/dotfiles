---
name: chezmoi prefixes docs
overview: Create a canonical reference+playbook for chezmoi source-state prefixes at docs/tools/chezmoi-prefixes.md, and slim the existing Selective File Management section in CLAUDE.md to point at it while keeping the two repo-specific case studies.
todos:
  - id: write-docs
    content: Draft docs/tools/chezmoi-prefixes.md (canonical links, safety table, per-prefix reference, prefix-ordering matrix, repo playbook, refresh recipes)
    status: completed
  - id: slim-claude-md
    content: "Edit CLAUDE.md: rename Selective File Management section, add pointer + agent guideline, keep the two case studies"
    status: completed
  - id: link-readme
    content: Append docs/tools/chezmoi-prefixes.md to README.md's final Customization paragraph
    status: completed
isProject: false
---

## Scope

- **New**: `docs/tools/chezmoi-prefixes.md` — reference + playbook (~250 lines).
- **Edit**: [CLAUDE.md](CLAUDE.md) — slim the `Selective File Management` section, add agent guideline pointer.
- **Edit**: [README.md](README.md) — append the new doc to the "Customization" paragraph at the bottom (keeps the single-line doc index pattern already there).
- **Not doing**: SKILL.md. Over-engineered for a single personal dotfiles repo; revisit only if we want to publish a reusable community artifact.

## 1. `docs/tools/chezmoi-prefixes.md` outline

Header plus these sections (use inline links to official chezmoi docs throughout):

- **Canonical references** — two links:
  - `https://www.chezmoi.io/reference/source-state-attributes/` (full prefix matrix + allowed combinations per target type)
  - `https://www.chezmoi.io/user-guide/manage-different-types-of-file/` (practical recipes, including the `#manage-part-but-not-all-of-a-file` anchor)

- **`chezmoi add` safety decision table** (3 buckets, the core cheat sheet):
  - Green-light: `dot_`, `private_`, `executable_`, `readonly_`
  - Add-safe but re-check semantics after: `create_`, `exact_`, `literal_`
  - Do NOT treat as ordinary tracked file: `remove_`, `encrypted_`, `modify_`

- **Per-prefix reference** — one subsection each for the 9 prefixes from the user's cheat sheet (`dot_`, `private_`, `executable_`, `readonly_`, `create_`, `exact_`, `literal_`, `remove_`, `encrypted_`) plus a brief note on `modify_`, `symlink_`, `empty_`, `external_`, and the script family (`run_`/`once_`/`onchange_`/`before_`/`after_`) since this repo uses `run_once_before_*` and `run_onchange_after_*` scripts in the root. Each subsection covers: effect, `chezmoi add` behavior, risk notes, typical use.

- **Allowed prefix ordering** — condensed matrix lifted from the official Source state attributes page (regular / create / modify / directory / script), so readers don't have to memorize stacking order like `encrypted_private_readonly_executable_dot_foo`.

- **Playbook — what goes where in this repo** (the "+實戰" part the user chose):
  - `dot_zshrc`, `dot_gitconfig`, `dot_config/...` normal configs → `dot_` (common track+add)
  - SSH configs (`dot_ssh/config`, `dot_ssh/config.d/*`) → `private_` + `create_` template (mirrors the current `README.md` SSH notes)
  - Executables under `~/bin/`, `~/.local/bin/x` → `executable_`
  - Neovim / LazyVim: config body is tracked normally; `lazy-lock.json` → `create_` (seeded, not resynced). Cross-link back to the CLAUDE.md case study.
  - Claude Code `settings.json` → `modify_` via `jq` overlay. Cross-link back to CLAUDE.md case study.
  - runtime / cache / machine-local (plugin artifacts, swap files, logs) → `.chezmoiignore`, not a prefix.
  - Secrets — brief guidance: prefer password-manager templates (`onepassword`, `bitwarden`, `keyring`) or `encrypted_` with age/gpg; never commit a plain `private_` file with a real token.

- **Refresh recipes** (the non-obvious ops):
  - `create_` baseline refresh: `cp ~/path "$(chezmoi source-path ~/path)"` (already documented in CLAUDE.md — repeat here so this doc is self-contained).
  - `chezmoi re-add` vs `chezmoi add`: one-liner on when each is safe vs dangerous per prefix (re-add silently skips `create_` / `modify_`; add strips attributes).
  - `chezmoi chattr` for toggling prefixes without manually renaming.

## 2. CLAUDE.md changes

Target the existing `## Selective File Management (modify_ and create_)` section at `CLAUDE.md` L140–175.

- Replace the section heading with `## Selective File Management (case studies)` and move the generic intro sentence into a one-line pointer: "For the full prefix reference and `chezmoi add` safety table, see [docs/tools/chezmoi-prefixes.md](docs/tools/chezmoi-prefixes.md)."
- Keep the two subsections intact (they are repo-specific and useful as agent context):
  - `dot_claude/modify_settings.json` — partial JSON management via jq (L144–154)
  - `dot_config/nvim/create_lazy-lock.json` — seed-once, never overwrite (L156–171)
  - `Failure modes of the modify_ script` (L173–175)
- Add a new short bullet list right under the pointer, as an agent guideline:
  - "Before running `chezmoi add`, decide which prefix bucket the file belongs to (see the safety table). In particular, never `chezmoi add` a `create_` or `modify_` target — it strips the attribute. Use `cp $(chezmoi source-path …)` or edit in place instead."

## 3. README.md change

Append one doc link to the existing "Customization" paragraph at the bottom of [README.md](README.md) (L248), matching the comma-separated link style already used there:

- Add: `[docs/tools/chezmoi-prefixes.md](docs/tools/chezmoi-prefixes.md) for chezmoi source-state prefix semantics and when each is safe to `chezmoi add`.`

## Non-goals (called out explicitly)

- Not writing a `SKILL.md` or touching `~/.claude/skills/` / `~/.cursor/skills-cursor/`.
- Not changing `docs/cheatsheet.md` (it's command-focused; prefix semantics belong in a dedicated reference).
- Not touching `scripts/redact_*.py`, pre-commit, or any other moving pieces visible in `git status`.
