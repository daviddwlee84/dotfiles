# Plan: chezmoi-templated `chezmoi-dotfiles` agent skill (cross-agent, lean, self-syncing)

## Context

When an agent (Claude Code / opencode / codex / cursor) is opened in an **arbitrary
directory**, it has no idea this machine's `$HOME` is driven by a chezmoi+ansible
dotfiles repo — nor that the repo ships ~10 custom in-house CLIs (`fleet`, `mlf`,
`pqsum`, `x`, `mi-router`, …), ~40 custom Television (`tv`) channels, a tmux
`prefix+Space` menu, and an extensive `docs/` tree. `docs/**` is **chezmoi-ignored**
(`.chezmoiignore.tmpl:41`), so it never lands in `$HOME`; an agent can only reach it
via `chezmoi source-path`. Result: the user (and the agent) can't discover or
operate any of this from outside the repo.

**Goal:** a single, chezmoi-**templated** personal skill that (a) only lists the
tools the user actually selected at `chezmoi init` (rendered via the 26 prompt
keys), (b) teaches the agent how to drive chezmoi/ansible/just, and (c) stays
*lean* — it points to the repo's existing `docs/` via `chezmoi source-path` instead
of duplicating content, to keep agent context small.

## Decisions (all confirmed with user)

- **Name = `chezmoi-dotfiles`** — namespaced → zero collision risk in the flat
  skill namespace (a bare `dotfiles` could clash with a third-party / future
  `npx skills add` skill of the same name, causing a chezmoi↔npx overwrite ping-pong).
- **Cross-agent / universal** — real templated `SKILL.md` lives in
  `~/.agents/skills/chezmoi-dotfiles/` (the universal dir this repo already uses),
  plus a chezmoi-managed symlink `~/.claude/skills/chezmoi-dotfiles →
  ../../.agents/skills/chezmoi-dotfiles` so Claude Code discovers it. (Mirrors npx's
  per-agent-symlink strategy — `docs/tools/agent-skills.md`.)
- **Plain managed `.tmpl` (NOT `create_`)** — the skill iterates heavily with the
  project, so it must re-render on **every `chezmoi apply`** and propagate across the
  fleet. `create_` was rejected: it seeds once then freezes (stale after `dotcfg`
  reconfigure, and skill-body improvements never reach existing hosts without
  `rm` + re-apply on each). A plain managed templated file syncs normally.
- **Lean + reference + self-discovering** — body references `docs/` and uses live
  discovery commands instead of hardcoded enumerations, to minimize maintenance churn.

## Why not the existing skill mechanism

Existing skills are pulled by `npx skills` from an external repo and live in
chezmoi-**ignored** `.agents/skills/**` / `.claude/skills/**`
(`.chezmoiignore.tmpl:62-66`) — static clones that **cannot** be chezmoi-templated.
This is the first **first-party, chezmoi-managed, templated** skill, so it needs its
own re-inclusion path (below). It coexists with the npx skills (distinct name, not in
the npx lock → no conflict).

## Approach

### 1. New templated skill file (the heart)

Create `dot_agents/skills/chezmoi-dotfiles/SKILL.md.tmpl` → renders to
`~/.agents/skills/chezmoi-dotfiles/SKILL.md`. Format mirrors
`.agents/skills/project-knowledge-harness/SKILL.md` (YAML frontmatter `name` +
`description`, then markdown body).

- **First line of body**: an HTML-comment ownership marker
  `<!-- managed-by: chezmoi-dotfiles (chezmoi source: dot_agents/skills/chezmoi-dotfiles/SKILL.md.tmpl) -->`
  (cheap provenance; also the hook a future foreign-skill guard could grep).
- **Frontmatter `description`** = the trigger. Cover: "operate/apply/edit these
  dotfiles", "where does config/tool X live", "how does keymap/keybinding work
  (tmux/shell/fzf)", "what custom CLIs / tv channels exist", "what's installed on
  this machine", "how to use chezmoi/ansible/just here".
- **Body sections (lean, mostly pointers + self-discovery):**
  1. *Orientation* — `$HOME` is chezmoi-managed; repo root = `chezmoi source-path`
     (no args); **`docs/**` is NOT in `$HOME`** → read via
     `"$(chezmoi source-path)/docs/..."`. Read `CLAUDE.md` Hard invariants before editing.
  2. *chezmoi essentials* — `apply` / `diff` / `status` / `edit` / `add` / `re-add` /
     `managed` / `cat` / `data` / `source-path`; `cas`/`cau` wrappers; `dotcfg` to
     reconfigure prompts; **never `chezmoi add` a `modify_`/`create_` target**.
     Reference `docs/this_repo/cheatsheet.md`.
  3. *What's installed on THIS machine* — **the templated section**: `{{ if .installX }}`
     blocks over the prompt keys (`installCodingAgents`, `installPythonUvTools`,
     `installExtraRuntimes`, `installNiri`, `installBitwarden`, `installBrewApps`,
     `installInputMethod`, `installNetworkingTools`, `installTunnelTools`,
     `installIacTools`, `installMediaTools`, `installLlmTools`, `installDotnetTools`,
     `installHomelabTools`, `installAuditd`, `enableVimMode`, `primaryShell`,
     `profile`). End with a ground-truth pointer: `chezmoi data | jq` / `dotcfg`.
  4. *Custom in-house CLIs* — one line each (`fleet`, `mlf`, `pqsum`, `x`,
     `mi-router`, `reyee`, `sms`, `ping-monitor`, `dotcfg`, `sesh-preview`); gate
     `mlf` on `.installPythonUvTools`; **+ self-discovery line**:
     `ls "$(chezmoi source-path)/dot_dotfiles/bin/"`. Point to `docs/tools/<cli>.md`.
  5. *Television (`tv`) channels* — explain `tv <channel>`; **do not enumerate all
     ~40** — say "run `tv` to browse; channels live in
     `$(chezmoi source-path)/dot_config/television/cable/`"; point to `docs/tools/tv.md`.
     (This is the user's flagship "I didn't know it existed" example.)
  6. *Keybindings* — tmux `prefix+Space` menu, shell ZLE widgets (`Alt+S` sesh,
     `Alt+T` tools), the `bindings()` helper; point to `docs/shells/keybindings.md`
     + `docs/tools/tmux/keybindings.md`.
  7. *Aliases/functions* — `docs/shells/aliases.md` + `tv aliases`.
  8. *just recipes* — `just --list` from the source dir; `upgrade-*`, `fleet-*`,
     `gen-prompts`. Note the install-vs-upgrade split (apply = install-only).

Keep it short: the rendered installed-tools list is the only "generated" value;
everything else is a pointer or a self-discovery command.

### 2. Cross-agent symlink

Create `dot_claude/skills/symlink_chezmoi-dotfiles` (chezmoi `symlink_` attribute)
with content `../../.agents/skills/chezmoi-dotfiles` → produces
`~/.claude/skills/chezmoi-dotfiles → ~/.agents/skills/chezmoi-dotfiles`. Plain file
(no `.tmpl`); relative path is OS-agnostic.

### 3. Re-include both paths in `.chezmoiignore.tmpl`

Append negations **after** the existing block (`.chezmoiignore.tmpl:62-66`),
last-match-wins so the broad npx ignore still holds for everything else:

```
# First-party chezmoi-managed templated skill (NOT npx-owned) — re-include it.
!.agents/skills/chezmoi-dotfiles
!.agents/skills/chezmoi-dotfiles/**
!.claude/skills/chezmoi-dotfiles
```

**Verify this works first** (chezmoi re-inclusion under an ignored dir) — see
Verification step 1. **Fallback if it doesn't:** render via a
`run_onchange_after_42_render_chezmoi_dotfiles_skill.sh.tmpl` (a `.tmpl` script that
writes the rendered body + symlink), mirroring the existing
`.chezmoiscripts/global/run_onchange_after_40_install_global_skills.sh.tmpl`. (This
fallback still re-renders on change — freshness is preserved either way; only
`create_` would have broken sync.)

### 4. Keep-in-sync rule in CLAUDE.md (the user's "record in AGENTS.md" ask)

Add **one row** to the "Cross-file maintenance rules" table in `CLAUDE.md` (edit one
of `CLAUDE.md`/`AGENTS.md`/`GEMINI.md` — they're symlinks):

| Surface you change | Also update | Reference |
|---|---|---|
| Selected-tool inventory / in-house CLIs / `tv` channels / keymaps surfaced to agents (new prompt key, new `executable_*` CLI, etc.) | `dot_agents/skills/chezmoi-dotfiles/SKILL.md.tmpl` (the agent-facing index of this repo) | Keep it **lean & self-discovering** — prefer pointers (`tv`, `just --list`, `ls $(chezmoi source-path)/dot_dotfiles/bin/`, `docs/`) over hardcoded lists so most changes need **no** skill edit. Only edit when adding a section that must be gated on a new prompt key, or a stable new CLI worth naming. |

This keeps facts consistent without turning the skill into a high-churn mirror.

### 5. Doc mirror

Update `docs/tools/agent-skills.md` — short subsection: this is the first
**first-party, chezmoi-templated** skill (vs npx-pulled ones), where its source lives,
and the `.chezmoiignore` re-inclusion. Existing nav page → re-run
`uv run mkdocs build --strict`. No new nav entry (we reference existing docs).

## Critical files

- **New:** `dot_agents/skills/chezmoi-dotfiles/SKILL.md.tmpl` (the templated skill)
- **New:** `dot_claude/skills/symlink_chezmoi-dotfiles` (cross-agent symlink)
- **Edit:** `.chezmoiignore.tmpl` (append 3 negation lines after line 66)
- **Edit:** `CLAUDE.md` (one new maintenance-table row — §4)
- **Edit:** `docs/tools/agent-skills.md` (mirror subsection — §5)

## Reuse / references (don't duplicate)

- SKILL.md format model: `.agents/skills/project-knowledge-harness/SKILL.md`
- Prompt keys available as `.<key>`: `scripts/init/dotfiles_init.py` `PROMPTS` →
  baked into `.chezmoi.toml.tmpl`
- Detail docs to point at (not copy): `docs/this_repo/cheatsheet.md`,
  `docs/shells/{keybindings,aliases}.md`, `docs/tools/tv.md`,
  `docs/tools/tmux/keybindings.md`,
  `docs/tools/{fleet-exec,fleet-hosts,pueue,mi-router,reyee,sms,ping-monitor}.md`
- Existing skill-install pattern (fallback model):
  `.chezmoiscripts/global/run_onchange_after_40_install_global_skills.sh.tmpl`

## Verification

1. **Re-inclusion works**: `chezmoi managed | grep chezmoi-dotfiles` lists both
   `.agents/skills/chezmoi-dotfiles/SKILL.md` and `.claude/skills/chezmoi-dotfiles`.
   If empty → negation failed → switch to the run-script fallback (§3).
2. **Renders correctly / only selected tools**:
   `chezmoi cat ~/.agents/skills/chezmoi-dotfiles/SKILL.md` — confirm the
   installed-tools section reflects this host's `.chezmoi.toml` (a section is absent
   when its `installX` is false). Optionally cross-render another profile with
   `chezmoi execute-template` to confirm gating flips.
3. **Sync proof (answers the create_ concern)**: edit the template, `chezmoi apply`,
   confirm the deployed `SKILL.md` reflects the edit (managed `.tmpl` re-renders;
   `create_` would not).
4. **Frontmatter parses**: valid YAML frontmatter (name + description) so agents index it.
5. **Apply + symlink resolves**: `chezmoi apply`, then `~/.agents/skills/chezmoi-dotfiles/SKILL.md`
   exists and `readlink ~/.claude/skills/chezmoi-dotfiles` →
   `../../.agents/skills/chezmoi-dotfiles`; `cat` through the link resolves.
6. **No npx conflict**: `~/.agents/.skill-lock.json` still valid; `chezmoi-dotfiles`
   absent from it (chezmoi-owned, as intended).
7. **Docs build**: `uv run mkdocs build --strict` passes.
8. **End-to-end trigger**: in a fresh agent session in an unrelated cwd, ask "how do
   I apply my dotfile changes / what tv channels do I have" and confirm the skill is
   selected and answers from the rendered list + source-path docs.
