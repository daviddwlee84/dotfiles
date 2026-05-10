# Add marimo + jupyterlab (with marimo-jupyter-extension) to `python_uv_tools`

## Context

Marimo's shell completion is already wired up in [`dot_config/shell/29_marimo.sh`](../../dot_config/shell/29_marimo.sh) and a marimo config template exists at [`dot_config/marimo/create_marimo.toml.tmpl`](../../dot_config/marimo/create_marimo.toml.tmpl), but **marimo itself is not actually installed by ansible** — completion silently no-ops on hosts that don't already have marimo. This plan installs it via uv tool with the user's chosen extras and adds a sibling JupyterLab env that hosts `marimo-jupyter-extension`.

**Key research findings** (from PyPI metadata + the extension's README):

- `marimo[recommended]` bundles SQL/sandbox/Altair/AI (`pydantic-ai-slim`)/Ruff/jupyter-convert. `marimo[mcp]` separately adds MCP server support (`mcp` + `pydantic`). The two combine cleanly as `marimo[recommended,mcp]` — user-selected.
- `marimo-jupyter-extension` is a **JupyterLab extension** — its README states it must live in **Jupyter's environment, not marimo's**. Putting it as `--with` on the `marimo` uv tool entry would install but not function (no JupyterLab in that env). Solution: a second `uv tool install jupyterlab` env carrying `marimo[sandbox]` (per the extension's documented requirement) plus `marimo-jupyter-extension`.
- Each `uv tool install` produces an isolated venv. `--with` deps don't expose entry points to `~/.local/bin`, so the duplicate marimo install in the JupyterLab env will not shadow the primary `marimo` binary from the first entry.

## Changes

### 1. `dot_ansible/roles/python_uv_tools/defaults/main.yml`

Append two entries to the `python_uv_tools` list (after `trafilatura` at line 47-48):

```yaml
  - name: marimo[recommended,mcp]
    binary: marimo
    with:
      - httpx[socks]  # SOCKS proxy support for AI/MCP clients
  - name: jupyterlab
    binary: jupyter-lab
    with:
      - marimo[sandbox]            # required by marimo-jupyter-extension's PEP 723 launcher
      - marimo-jupyter-extension   # JupyterLab extension; lives in the JL env, not marimo's
```

No `needs_modern_gcc: true` flag — none of the transitive deps (polars, duckdb, sqlglot, altair, ruff, pydantic-ai-slim, mcp, pydantic, jupyter-server, jupyterlab-server) force a numpy 2.x source build on CentOS 7. If that ever surfaces, add the flag in a follow-up.

The role's `tasks/main.yml` already handles `--with` deps via the existing loop body (line 31-49) — no task changes needed.

### 2. `README.md` line 276

Update the python tools list to include the new entries:

```diff
-- **Python tools (via uv)**: thefuck, apprise, sqlit-tui, dotenv, git-filter-repo, mlflow, tmuxp, trafilatura
+- **Python tools (via uv)**: thefuck, apprise, sqlit-tui, dotenv, git-filter-repo, mlflow, tmuxp, trafilatura, marimo, jupyterlab (with marimo-jupyter-extension)
```

(per the CLAUDE.md cross-file maintenance rule for README's "Tools" section).

## Files modified

- `dot_ansible/roles/python_uv_tools/defaults/main.yml` — append two entries
- `README.md` — extend the python tools bullet on line 276

## Verification

1. **Render check**: `ansible-playbook --syntax-check dot_ansible/site.yml` (no template, just YAML).
2. **Targeted install** on the local host:
   ```sh
   ansible-playbook dot_ansible/site.yml --tags python_uv_tools --check  # dry-run first
   ansible-playbook dot_ansible/site.yml --tags python_uv_tools          # real install
   ```
   Or via the normal flow: `chezmoi apply` → `run_onchange_after_20_ansible_roles.sh` → role runs.
3. **Functional smoke**:
   - `marimo --version` (prints version; confirms primary binary in `~/.local/bin`)
   - `marimo tutorial intro` → check the new tab opens (sanity-check `[recommended]` extras render fine)
   - `uv tool run --from "marimo[recommended,mcp]" marimo --help` is **not** the path here; we want `~/.local/bin/marimo` directly
   - `jupyter-lab --version` (confirms JupyterLab env + binary)
   - Inside JupyterLab, verify the marimo launcher tile appears (per the extension's README) — this proves `marimo-jupyter-extension` actually activated in the JL env.
   - `uv tool list` should show **two** separate tools: `marimo` and `jupyterlab`, each with their own version pin.
4. **Idempotency**: re-run the role; `creates: ~/.local/bin/marimo` and `creates: ~/.local/bin/jupyter-lab` should make the install tasks `ok` (not `changed`) on the second pass.
5. **Shell completion**: open a new shell; `marimo <TAB>` should complete (the existing `dot_config/shell/29_marimo.sh` early-returns if `marimo` is missing, so this is the first time it actually fires).

## Out of scope / explicit non-goals

- **No `docs/` page added.** The role's existing usage pattern is documented inline in `defaults/main.yml`'s header comment; new entries follow it. Per CLAUDE.md's "no docs unless asked" guidance.
- **No mkdocs nav update** (no new `docs/**/*.md` file).
- **No upgrade hook**. `scripts/upgrade_tools.sh`'s generic uv path already picks up any `uv tool install`-managed tool; no per-tool wiring needed.
- **`needs_modern_gcc` not set**. If CentOS 7 install fails on numpy/pandas source build, add the flag in a follow-up rather than preemptively skipping a working install everywhere else.
