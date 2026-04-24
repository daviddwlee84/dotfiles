# Agent skills (`vercel-labs/skills`)

This repo manages [`vercel-labs/skills`](https://github.com/vercel-labs/skills)
agent skills two ways, with sharply different scopes.

## TL;DR

| Scope | Lock file | Where the skill lives | Restored by |
|---|---|---|---|
| **Global** (every project, every shell) | `~/.agents/.skill-lock.json` (chezmoi-managed) | `~/.agents/skills/<name>/` | `run_onchange_after_40_install_global_skills.sh.tmpl` on every `chezmoi apply` |
| **Project** (only inside this repo's working tree, for editing skills) | `./skills-lock.json` (git-tracked) | `./.agents/skills/<name>/` | `run_onchange_after_45_repo_bootstrap_skills.sh.tmpl` on every `chezmoi apply` (when source dir == repo); manual fallback: `just bootstrap-skills` |

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

Restore is automatic on `chezmoi apply` via
`run_onchange_after_45_repo_bootstrap_skills.sh.tmpl`. The script:

1. Checks whether `.chezmoi.sourceDir` contains a `skills-lock.json` (i.e.
   this machine's chezmoi source dir IS the repo). If not, exits silently —
   project skills only matter when you're editing the repo with an agent.
2. Fast-path: if every skill named in the lock already has a
   `./.agents/skills/<name>/SKILL.md`, exits without invoking npx.
3. Otherwise runs `npx skills@latest experimental_install` from the source
   dir to rebuild `./.agents/skills/...` and `./.claude/skills/...` symlinks.

Trigger hash: SHA256 of `skills-lock.json` content, so the script only
re-runs when the lock actually changes.

Manual fallback (if you want to force a re-bootstrap, or you cloned the repo
to a path that isn't your chezmoi source dir):

```sh
just bootstrap-skills
# → npx skills@latest experimental_install
```

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

## How `npx skills` actually wires agents (mechanism reference)

Verified by reading [`vercel-labs/skills/src/agents.ts`](https://github.com/vercel-labs/skills/blob/main/src/agents.ts)
and [`installer.ts`](https://github.com/vercel-labs/skills/blob/main/src/installer.ts).
Important because the CLI's "I installed your skill for agent X" message does
**not** mean agent X actually reads from `~/.agents/skills/` at runtime — that
is a per-agent convention, not a guarantee.

### Two install strategies

| Strategy | What the CLI writes | Agents that use it |
|---|---|---|
| **Universal** (`skillsDir: '.agents/skills'`) | Nothing in agent-specific dir; agent reads `~/.agents/skills/` (global) or `./.agents/skills/` (project) directly | `cursor`, `opencode`, `codex`, `gemini-cli`, `copilot`, `antigravity`, `warp`, `replit`, `cline`, `kimi-cli`, `firebender`, `deep-agents` |
| **Per-agent symlink** | Symlink `~/.<agent>/skills/<name>` → `~/.agents/skills/<name>` (copy on Windows) | `claude-code`, `augment`, `bob`, `cortex`, `crush`, `goose`, `junie`, `kilo`, `kiro`, `kode`, `roo`, `trae`, `windsurf`, etc. |

The skip happens at `installer.ts`:

```ts
if (isGlobal && isUniversalAgent(agentType)) {
  return { /* skipped: no symlink, no copy */ };
}
```

So `npx skills add foo -g -a cursor -a opencode` produces **zero** files in
`~/.cursor/skills/` or `~/.opencode/skills/`. Whether Cursor and OpenCode
actually pick up `~/.agents/skills/foo/SKILL.md` at runtime is up to those
agents (Anthropic's Skills spec is Claude Code's; others adopt by convention,
not contract).

### Lock filename collision (easy to confuse)

| Path | Scope | Owner |
|---|---|---|
| `~/.agents/.skill-lock.json` | Global, **singular** `skill-` | Skills CLI |
| `./skills-lock.json` | Project, **plural** `skills-` | Skills CLI |

Schema differs (global is v3 with `dismissed`/`lastSelectedAgents`; project is
flatter). Don't symlink one to the other.

### Restore commands and their quirks

| Command | What it does |
|---|---|
| `npx skills experimental_install` | Restores **project** lock (`./skills-lock.json`) only |
| `npx skills experimental_install -g` | `-g` is **silently ignored**, still project-only ([#283](https://github.com/vercel-labs/skills/issues/283), [#549](https://github.com/vercel-labs/skills/issues/549)) |
| `npx skills update -g` | Updates already-installed global skills; does **not** backfill missing entries from the lock |
| `npx skills add <source> -s <name> -g -y` | The only working "restore one missing global skill" idiom — what `run_onchange_after_40_install_global_skills.sh.tmpl` loops over |

### CLI flag gotchas

- **Repo shorthand requires `/skills` suffix when skills live under `skills/`**.
  `npx skills add owner/repo` looks at `.agents/skills/` in that repo;
  `npx skills add owner/repo/skills` looks at `skills/`. Most third-party skill
  repos use the latter layout.
- **`-a` does NOT take comma-separated values**. Repeat the flag:
  `-a claude-code -a opencode -a cursor`.
- **Agent names are normalised** (`claude-code` not `claude`,
  `gemini-cli` not `gemini`, `copilot` not `github-copilot`). Run
  `npx skills add --list` (or trigger the validation error) to see the
  canonical list.

### Per-agent env var overrides

Agents that respect a custom config dir change where the symlink/skill is
read from:

| Env var | Default | Effect |
|---|---|---|
| `CLAUDE_CONFIG_DIR` | `~/.claude` | Skills CLI writes symlinks here instead |
| `CODEX_HOME` | `~/.codex` | Codex picks up skills from here (Codex is universal, so the global install relies on `~/.agents/skills/` regardless) |
| `XDG_CONFIG_HOME` | `~/.config` | Affects Cursor/OpenCode/Gemini-CLI lookup paths |

If you set any of these and re-run `npx skills add -g`, the CLI writes to the
new location; chezmoi's lock-file management still uses
`~/.agents/.skill-lock.json` (the lock is location-independent).

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
