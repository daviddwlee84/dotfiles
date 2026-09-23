# Plan: `tv inventory` — a searchable catalog of tools this repo installs

## Context

The user keeps losing track of what the repo installs. Today that information is split across three places, and none of them answers "what is this, which role/recipe installs it, and is it on this host?":

- `docs/this_repo/tool-managers.md` § Tool index (A–Z): about 234 hand-written rows with columns `Tool | macOS | Linux | Role`. It has no category or description. The format is loose (several tools per row, `— notes` after the role), and nothing parses it or checks it for coverage.
- `dot_config/docs/tools/cli-tools.md`: 55 curated rows that drive `tv tools` and the Alt+T launcher. It is a launcher list, not an inventory.
- `tv appsrc`: a live scan of the OS (cask, apt, uv, …). It shows how something got onto the machine, but not whether this repo declared it or which role owns it.

The existing `tv aliases` channel, the precedent the user remembers, builds its list at runtime from `alias` / `typeset -f`. That works for aliases but not for tools: an install inventory needs data that has been *declared*.

**Outcome:** one structured catalog file becomes the single source of truth for tool metadata. A new `tv inventory` channel reads it and checks each tool's live status on this host, and the Tool index in tool-managers.md is generated from the catalog instead of being written by hand.

### How the user's two concerns are handled

1. **Duplication.** The catalog *replaces* the hand-written Tool index table, which becomes a generated marker region, so there is one fewer copy. It does **not** copy the role defaults lists: `python_uv_tools/defaults/main.yml` and the others remain the install source of truth. The catalog only adds what they lack (category, description, docs link), and a test fails if a role list has a binary the catalog is missing. `cli-tools.md` stays as the curated launcher. Generating it from a `launcher = true` field is left to the backlog.
2. **Hosts that install only part of the set because of different init prompts.** Each role in the catalog records the prompt that gates it, e.g. `media_tools → installMediaTools`, mirroring the `{{ if $installMediaTools }}` gates in `.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl`. When the channel builds its list it reads `chezmoi data --format json` once and gives every row one of four statuses:
   - ✅ installed (`command -v` hits)
   - ❌ expected but missing (gate on, right OS, binary absent). This means the install is broken.
   - ⚪ not enabled on this host (prompt off). The detail view names the prompt key, so the user knows how to turn it on.
   - `–` not for this OS

   Fuzzy-typing `❌` or `⚪` then filters by status.

## Design

### 1. Catalog: `dot_config/docs/tools/tool-catalog.toml` (new, deployed next to `cli-tools.md`)

```toml
[roles.media_tools]
gate = "installMediaTools"        # prompt key; omit = always installed
[roles.devtools]                  # no gate

[[tool]]
name = "bat"
bin = ["bat"]                     # binaries to probe; default [name]
category = "File & Search"        # reuse cli-tools.md's category names
desc = "cat with syntax highlighting"
role = "devtools"                 # ansible role | "Brewfile.darwin" | "bootstrap" | "mise" | "chezmoi-external"
mac = "brew"
linux = "apt"                     # "n/a" means not for this OS
gate = ""                         # optional per-tool override (e.g. installPlaywrightCli inside a role)
docs = "docs/tools/bat.md"        # optional, repo-relative
```

The install and upgrade commands are *derived*, not stored:
- install: `just ansible-tags <role>`, or a Brewfile / mise note
- upgrade: `just upgrade-<manager>`, using a manager → category map that mirrors `scripts/upgrade_tools.sh` `cat_*`

**Seeding:** write a one-off script to parse the existing 234-row Tool index into the TOML (names, mac/linux, role). Take descriptions and categories from `cli-tools.md` for its 55 overlapping tools, then have an agent draft the remaining roughly 180 `category`/`desc` values, with user review of the diff.

### 2. Helper: `dot_config/television/executable_tool-catalog.py`

- Uses a `uv run --script` PEP 723 header, the same pattern as `executable_mlflow-source.py`.
- Needs only the standard library (`tomllib`, requires-python >= 3.11).
- Subcommands:
  - `source`: TSV `name⇥status⇥category⇥role⇥method⇥desc`. The method is the current OS's `mac` or `linux` value. It calls `chezmoi data` once and probes with `shutil.which`; the whole list must stay under about 300 ms.
  - `preview NAME`: the full catalog entry, status with reason (including the gate key when ⚪), resolved path, a best-effort `--version` line with a short timeout, and the derived install/upgrade commands.
  - `index-md`: renders the Tool index markdown table. Used by `just gen-tool-index [--check]`, the same pattern as `just gen-prompts`, running the same file from the source tree.

### 3. Channel: `dot_config/television/cable/inventory.toml`

- Its header comment follows the convention in `appsrc.toml`.
- Source: `~/.config/television/tool-catalog.py source`.
- Display: `{split:\t:1} {split:\t:0}  [{split:\t:2}]  {split:\t:5}  ({split:\t:3})`.
- Preview: `tool-catalog.py preview '{split:\t:0}'`.

Key bindings follow the Alt+ convention and reuse appsrc's letters where the meaning matches:

| Key | Action |
|---|---|
| Enter | Detail view (same as the preview, paged) |
| Alt+T | tldr |
| Alt+M | man |
| Alt+D | open the linked doc (glow, falling back to bat) |
| Alt+I | copy the install command (`just ansible-tags <role>`) |
| Alt+U | copy the upgrade command |
| Alt+W | `appsrc which <bin>` as a live cross-check |

### 4. Generated Tool index

In `docs/this_repo/tool-managers.md`, replace the § Tool index table body with a `<!-- BEGIN/END generated: tool-catalog -->` marker region. Keep the prose and the chezmoi-externals exclusion note outside the markers.

### 5. Guardrails

- **`tests/unit/test_tool_catalog.py`:**
  - schema check: required keys; `role` exists under `dot_ansible/roles/` or is one of the allowed pseudo-roles; `gate` is a real key in the `PROMPTS` tuple of `scripts/init/dotfiles_init.py`; no duplicate names
  - coverage check: every `binary`/`extra_binaries` in the `python_uv_tools`, `llm_tools_uv`, `js_cli_tools`, `ruby_gem_tools`, `dotnet_tools` and `go_tools` defaults, plus the macOS brew `name:` list in `devtools/tasks/main.yml`, appears in some tool's `bin`
  - drift check: the Tool index region equals `index-md` output
- **Pre-commit hook:** add `tool-catalog-gen-check` next to `dotfiles-init-gen-check`.

### 6. Cross-file updates (same commit)

- `CLAUDE.md`: change the "New tool installed…" row to say "add or edit the entry in `dot_config/docs/tools/tool-catalog.toml`, then run `just gen-tool-index`", and note the gate field.
- `docs/tools/tv.md` § Custom Channels: add a `### inventory` section. Also add a missing `### aliases` stub while there.
- `docs/this_repo/tool-managers.md`: a short note that the index is generated.
- `dot_agents/skills/chezmoi-dotfiles/SKILL.md.tmpl`: mention `tv inventory` and the catalog as the answer to "what's installed here".
- Optional: a tmux popup binding. Not in scope unless the user asks.

## Critical files

- New:
  - `dot_config/docs/tools/tool-catalog.toml`
  - `dot_config/television/executable_tool-catalog.py`
  - `dot_config/television/cable/inventory.toml`
  - `tests/unit/test_tool_catalog.py`
- Edited:
  - `docs/this_repo/tool-managers.md`
  - `justfile` (`gen-tool-index`)
  - `.pre-commit-config.yaml`
  - `CLAUDE.md`
  - `docs/tools/tv.md`
  - `dot_agents/skills/chezmoi-dotfiles/SKILL.md.tmpl`
- Reference, read-only:
  - role `defaults/main.yml` files
  - `.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl` (role → gate mapping)
  - `scripts/upgrade_tools.sh` (manager → upgrade category)
  - `cable/appsrc.toml` (conventions)

## Verification

1. `uv run --script dot_config/television/executable_tool-catalog.py source | head`: TSV shape is correct and it runs in under about 300 ms (`time`).
2. `… preview bat`, plus one gated-off tool such as `ffmpeg` if media tools are off: the ⚪ reason names `installMediaTools`.
3. `just gen-tool-index --check` passes. Hand-edit the region and confirm it fails.
4. `uv run pytest tests/unit/test_tool_catalog.py`. Temporarily remove one uv tool from the catalog and confirm the coverage check fails.
5. `chezmoi apply` the three deployed files, then `tv inventory`. Check that filtering by category and by `❌` works and that each Alt action fires.
6. Run `tv channels` to confirm the channel is listed. Run `just docs-build` because tool-managers.md changed.
