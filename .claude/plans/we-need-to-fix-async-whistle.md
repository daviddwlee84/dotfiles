# Fix project-scope agent skill installation source

## Context

`just bootstrap-skills` (and the matching `chezmoi apply` run-script) fail to restore the three project-scope agent skills: `agent-history-hygiene`, `mkdocs-site-bootstrap`, `project-knowledge-harness`. The upstream clone succeeds but the installer reports:

```
No matching skills found for: agent-history-hygiene, mkdocs-site-bootstrap, project-knowledge-harness
Available skills:
  - find-skills
  - skill-creator
```

Root cause: the `source` field in our two lock files is `daviddwlee84/agent-skills` without the `/skills` suffix. Per [`docs/tools/agent-skills.md:179-182`](../../docs/tools/agent-skills.md):

> `npx skills add owner/repo` looks at `.agents/skills/` in that repo; `npx skills add owner/repo/skills` looks at `skills/`.

Upstream [`daviddwlee84/agent-skills`](https://github.com/daviddwlee84/agent-skills) keeps our three skills under `skills/local/` and `skills/vendor/`, while its `.agents/skills/` only contains `find-skills` + `skill-creator` — which is exactly what the installer is listing as "available". The correct source to pass is `daviddwlee84/agent-skills/skills`.

Intended outcome: `chezmoi apply` on a fresh machine restores all 3 project-scope skills silently, and `just bootstrap-skills` succeeds.

## Files to change

### 1. `/home/ldw/.local/share/chezmoi/skills-lock.json`

Hand-maintained project lock consumed by `npx skills experimental_install`. Update three `source` fields:

- Line 5 (`agent-history-hygiene`): `"daviddwlee84/agent-skills"` → `"daviddwlee84/agent-skills/skills"`
- Line 10 (`mkdocs-site-bootstrap`): same
- Line 15 (`project-knowledge-harness`): same

Leave `computedHash` values untouched — the hash is over skill folder contents, not the source URL, so if the upstream commit is unchanged it will still verify. If `npx skills experimental_install` later complains about hash mismatch, regenerate by re-running `npx skills add daviddwlee84/agent-skills/skills -s <name> -y` for each skill (that rewrites `skills-lock.json` with fresh hashes).

### 2. `/home/ldw/.local/share/chezmoi/dot_agents/modify_dot_skill-lock.json.tmpl`

chezmoi `modify_` merger that maintains `~/.agents/.skill-lock.json` (the global skills-cli lock). The `$managed` JSON literal (line 26-45) hard-codes one entry from `daviddwlee84/agent-skills`:

- Line 31 (`project-knowledge-harness`): `"source": "daviddwlee84/agent-skills"` → `"source": "daviddwlee84/agent-skills/skills"`

Do NOT touch the `find-skills` entry on line 37 (`"source": "vercel-labs/skills"`). It's a different upstream repo, currently installs successfully, and the user did not report it broken — leave it as-is to avoid scope creep.

The downstream script `.chezmoiscripts/global/run_onchange_after_40_install_global_skills.sh.tmpl` reads `.source` verbatim and passes it to `npx skills@latest add "$source" -s "$name" -g -y` at line 63, so fixing the merger is sufficient — no code change needed in the install script.

## Files NOT to change

- `justfile` (`bootstrap-skills` recipe line 341-344): the recipe just runs `npx -y skills@latest experimental_install` with no arguments; it reads `skills-lock.json` directly. Fixing that file is sufficient.
- `.chezmoiscripts/repo/run_onchange_after_45_bootstrap_skills.sh.tmpl`: same — just invokes `npx skills experimental_install`, no source string baked in.
- `docs/tools/agent-skills.md`: already documents the invariant at line 179. No doc update needed (the fix makes our config match the already-documented rule).

## Verification

1. **Lint the JSON** — `jq . /home/ldw/.local/share/chezmoi/skills-lock.json` and `chezmoi execute-template < dot_agents/modify_dot_skill-lock.json.tmpl | jq .` both exit 0.

2. **Clear any stale live state** (safe since the merger will re-seed it):
   ```sh
   rm -rf ./.agents/skills/agent-history-hygiene ./.agents/skills/mkdocs-site-bootstrap ./.agents/skills/project-knowledge-harness
   rm -rf "$HOME/.agents/skills/project-knowledge-harness"
   ```

3. **Re-run the project restore** — `just bootstrap-skills` should now print 3 successful installs, no "No matching skills found" error, and populate `./.agents/skills/{agent-history-hygiene,mkdocs-site-bootstrap,project-knowledge-harness}/SKILL.md`.

4. **Re-run the global restore** — `chezmoi apply` (or re-run just the global script) should report `→ project-knowledge-harness (from daviddwlee84/agent-skills/skills)` and `[SUCCESS] installed project-knowledge-harness`, ending with `Global agent skills sync complete.`

5. **Idempotency check** — a second `chezmoi apply` should short-circuit to `All project-scope agent skills present at ./.agents/skills/; nothing to install.` and `All globally-managed agent skills present; nothing to install.`

6. **Confirm SKILL.md files exist** for all three project skills and for `~/.agents/skills/project-knowledge-harness/SKILL.md`.
