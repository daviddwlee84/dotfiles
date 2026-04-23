# Agent skills (`vercel-labs/skills`)

This repo manages [`vercel-labs/skills`](https://github.com/vercel-labs/skills)
agent skills two ways, with sharply different scopes.

## TL;DR

| Scope | Lock file | Where the skill lives | Restored by |
|---|---|---|---|
| **Global** (every project, every shell) | `~/.agents/.skill-lock.json` (chezmoi-managed) | `~/.agents/skills/<name>/` | `run_onchange_after_40_install_global_skills.sh.tmpl` on every `chezmoi apply` |
| **Project** (only inside this repo's working tree, for editing skills) | `./skills-lock.json` (git-tracked) | `./.agents/skills/<name>/` | `just bootstrap-skills` after a fresh clone |

The two scopes happen to overlap today (both install
`project-knowledge-harness`), but they serve different purposes — see "Why two
scopes?" below.

## Global scope: must-have skills, on every machine

The skills CLI does **not** yet support `npx skills install -g` from a lock
file ([upstream issue #283](https://github.com/vercel-labs/skills/issues/283),
[#549](https://github.com/vercel-labs/skills/issues/549)). So we hand-roll
restore in two pieces:

### `dot_agents/modify_dot_skill-lock.json.tmpl` — the merger

A `modify_` script that owns `~/.agents/.skill-lock.json`. Every `chezmoi
apply`:

1. Reads the live lock file via stdin.
2. Merges the **managed-set** declared in `$managed` (top of the script) into
   `.skills`, preserving any `installedAt`/`updatedAt`/`skillFolderHash` from
   the live entry.
3. Preserves any `.skills.<name>` entries **not** in the managed-set (so
   ad-hoc `npx skills add … -g` installs survive).
4. Preserves `.dismissed` and `.lastSelectedAgents` per-machine state
   verbatim.

To declare a new must-have global skill, edit the inline `$managed` JSON in
that script:

```json
{
  "skills": {
    "your-new-skill": {
      "source": "owner/repo",
      "sourceType": "github",
      "sourceUrl": "https://github.com/owner/repo.git",
      "skillPath": "skills/your-new-skill/SKILL.md"
    }
  }
}
```

Then run `chezmoi apply`. The merger writes the new entry into the lock; the
restore script (next section) sees the missing on-disk skill and installs it.

### `run_onchange_after_40_install_global_skills.sh.tmpl` — the restorer

`onchange` hash trigger is the merger script's own SHA256 — so this script
re-runs whenever the **managed-set** is edited (not whenever the live lock
mutates from random `npx skills update -g` activity).

For each entry in `~/.agents/.skill-lock.json`:

- If `~/.agents/skills/<name>/SKILL.md` exists → skip (already installed).
- Otherwise → `npx skills add <source> -s <name> -g -y`.

This is idempotent: a re-run on a fully-installed machine prints
"All globally-managed agent skills present; nothing to install" and exits.

### After installing a new skill manually

If you `npx skills add foo/bar -g` interactively on a machine and want it to
become managed across the fleet:

1. `cat ~/.agents/.skill-lock.json` — find the entry the CLI just wrote.
2. Copy `source` / `sourceType` / `sourceUrl` / `skillPath` into the
   `$managed.skills` block of `dot_agents/modify_dot_skill-lock.json.tmpl`.
3. Commit. Other hosts pick it up at next `chezmoi apply`.

If you only want it on one machine, do nothing — the merger preserves the
live entry on the source machine, and other hosts simply never see it.

## Project scope: editing-this-repo convenience

`./skills-lock.json` + `./.agents/skills/` exist purely so that **when you're
editing the chezmoi repo itself**, agents launched from the repo root can use
`project-knowledge-harness` against the repo it documents. They are **not**
deployed (chezmoi-ignored: see `.chezmoiignore.tmpl` → `.agents/skills`,
`.claude/skills`, `skills-lock.json`) and **not** git-tracked except for
`skills-lock.json` (`.gitignore` covers `.agents/`, `.claude/skills/`).

Restore on a fresh clone:

```sh
just bootstrap-skills
# → npx skills@latest experimental_install
```

This rebuilds `./.agents/skills/...` and `./.claude/skills/...` symlinks from
the lock. If you've never used a project-scope skill in this repo, the recipe
is a no-op.

## Why two scopes?

| Use case | Where to install |
|---|---|
| Skill you want available in every project, on every machine | Global (edit `$managed` in the merger script) |
| Skill that only makes sense inside this specific repo | Project (`npx skills add ... -y` from repo root, commit `skills-lock.json`) |
| Skill you're prototyping locally before deciding | Project, then promote to global once stable |

`project-knowledge-harness` is in **both** scopes today because (a) the harness
itself targets *any* project so it belongs globally, and (b) we want to use it
on the chezmoi repo immediately, which the global install covers but
project-scope makes the lock-file dependency explicit for anyone reading
`skills-lock.json` here.

## Anti-patterns

- **Don't put skill source files (`.agents/skills/<name>/SKILL.md`,
  templates, etc.) in chezmoi source.** They're owned by the npx skills CLI;
  chezmoi managing them creates a constant fight with the CLI's
  `skillFolderHash`. Only the **lock file** is chezmoi-managed.
- **Don't run `chezmoi re-add ~/.agents/.skill-lock.json`** to capture local
  changes. Edit the merger's `$managed` block instead — that's the
  source-of-truth list. `re-add` would freeze a snapshot of one machine's
  state into the source, defeating the merger's per-machine preservation.
- **Don't commit `./.agents/skills/`**. They're skill source clones that the
  npx CLI rewrites on every `update`; tracking them creates noisy diffs and
  accidental conflicts with upstream skill updates.
- **Don't add `-g` to `bootstrap-skills`**. That recipe is project-scope by
  design; global is owned by `chezmoi apply`.

## References

- Live `dot_agents/modify_dot_skill-lock.json.tmpl` — merger source of truth
- Live `run_onchange_after_40_install_global_skills.sh.tmpl` — restore loop
- [`vercel-labs/skills` README](https://github.com/vercel-labs/skills) — CLI docs
- [Issue #283 — `skills install -g`](https://github.com/vercel-labs/skills/issues/283)
- [Issue #549 — global lock restore](https://github.com/vercel-labs/skills/issues/549)
- [`docs/tools/agent-overlays.md`](agent-overlays.md) — sibling pattern for
  Claude/Cursor/OpenCode `settings.json` overlays (also `modify_` based)
