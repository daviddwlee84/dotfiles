# Plan: Add `actionlint` (GitHub Actions linter) to the dotfiles toolkit

## Context

`actionlint` (rhysd) is the de-facto static checker for GitHub Actions workflow files — it type-checks `${{ }}` expressions, validates `uses:` action refs / runner labels / cron / globs, and (its killer feature) pipes each `run:` block through **ShellCheck** and Python snippets through pyflakes.

The user wants it in the dotfiles as a **general-purpose toolbox CLI** (same tier as `shellcheck` / `shfmt`), plus a **pre-commit hook** so the repo's own workflow files get linted. Fit is high because the synergy tools are already present: `shellcheck` is installed everywhere (apt on Linux, brew on macOS) so actionlint's ShellCheck integration works out-of-the-box, and pre-commit is already heavily used (15 hooks incl. shellcheck + shfmt).

Decisions locked with the user:
- **Linux install = mirror `shfmt`** — Linuxbrew best-effort only (no diffnav-style release-binary download). Non-Linuxbrew Linux hosts won't get the CLI, but the pre-commit hook still lints there.
- **Add the pre-commit hook** (not CLI-only).

The `find-skills` search surfaced only a thin `rshade/agent-skills@actionlint` wrapper (53 installs) — **not** worth installing; the CLI + hook route matches this repo's philosophy (tools via ansible/brew; agent-facing surface auto-rendered by the templated `chezmoi-dotfiles` skill).

## Changes

### 1. `dot_ansible/roles/devtools/tasks/main.yml` — install the CLI

**macOS (brew):** add `- actionlint` to the `name:` list in the `Install developer CLI tools (macOS)` task (line 53–110), right after `- shfmt` (line 109). It's a Homebrew-core formula. Extend the adjacent shell-linting comment (lines 103–107) to mention actionlint.

**Linux (mirror `shfmt`):** in the `# --- shellcheck + shfmt ---` section (lines 2060–2088), add a `actionlint` install task modeled exactly on the existing `Install shfmt via Linuxbrew when available (Debian/Ubuntu)` task — reuse the existing `shfmt_brew_probe` register (same `command -v brew` probe already runs there; no need for a second probe), gated on `os_family == "Debian"` and `shfmt_brew_probe.stdout | trim != ''`, `community.general.homebrew: name: actionlint`. Update the section's leading comment to note actionlint rides the same Linuxbrew best-effort path.

### 2. `.pre-commit-config.yaml` — add the hook

Append a new block after the shfmt hook (after line 132, keeping all linters grouped at the bottom):

```yaml
  - repo: https://github.com/rhysd/actionlint
    rev: v1.7.7   # PIN to the latest release tag — verify at implementation
    hooks:
      - id: actionlint-system   # reuse the ansible/brew-installed binary + system shellcheck
        files: '^\.github/workflows/.*\.ya?ml$'
```

Notes:
- Pin `rev:` to an exact tag (repo convention — every third-party hook is tag-pinned). Verify the current latest tag and the exact hook id from `rhysd/actionlint`'s `.pre-commit-hooks.yaml` at build time.
- Hook id choice: **`actionlint-system`** reuses the CLI we install (consistent version, no extra toolchain). Fallback if a Go-self-contained hook is preferred: `id: actionlint` (`language: golang`, builds its own binary, needs Go on PATH). actionlint auto-discovers `shellcheck` on PATH under **either** variant, so the ShellCheck integration works regardless.
- `files:` scopes to the workflow dir; the repo has exactly one workflow today (`.github/workflows/docs.yml`).

### 3. `docs/this_repo/tool-managers.md` — A–Z row (CLAUDE.md contract)

Add one row to the § Tool index (A–Z) table (header at line 931, 4 cols `| Tool | macOS | Linux | Role |`), placed alphabetically near the top:

```
| **actionlint** | brew | Linuxbrew (best-effort) | devtools |
```

No § Per-manager catalog change (brew/Linuxbrew are existing mechanisms, not new). No `docs/this_repo/upgrades.md` change — brew covers macOS upgrade via `upgrade-brew` (case 1); Linux is install-only like the other release tools (confirmed by exploration).

### 4. Dedicated docs page (user-requested) — `docs/tools/actionlint.md` (+ zh-TW mirror + nav)

Per-tool docs live in `docs/tools/*.md` and the repo enforces a **bilingual convention** — every tools page has a `.zh-TW.md` sibling served via mkdocs-static-i18n. So create **both**:

- **`docs/tools/actionlint.md`** — the English page. Contents:
  - What actionlint is + what it checks (schema, `${{ }}` expression type-checking, `uses:` refs, runner/cron/glob, **ShellCheck on `run:` blocks**, pyflakes on Python).
  - How it's installed *in this repo* — macOS `brew` (devtools role), Linux Linuxbrew best-effort (mirrors `shfmt`); note the non-Linuxbrew Linux gap and that the pre-commit hook still lints there.
  - **ShellCheck integration** — actionlint auto-discovers `shellcheck` on PATH (already installed everywhere here); cross-link to the shellcheck/shfmt row in `tool-managers.md`.
  - **pre-commit usage** — the `rhysd/actionlint` hook (`actionlint-system`, scoped to `.github/workflows/`); cross-link to [`tools/pre-commit.md`](docs/tools/pre-commit.md).
  - Ad-hoc usage: `actionlint`, `actionlint .github/workflows/docs.yml`, optional `.actionlintrc.yaml` config.
- **`docs/tools/actionlint.zh-TW.md`** — zh-TW mirror of the above (mandatory; model structure/tone on an existing pair like `docs/tools/pre-commit.md` ↔ `.zh-TW.md`).

- **`mkdocs.yml` nav** — add one entry under the **`Git & DevOps:`** subsection (line 304), adjacent to `- pre-commit: tools/pre-commit.md` (line 308), e.g. `- actionlint (GitHub Actions linter): tools/actionlint.md`. The i18n plugin resolves the `.zh-TW.md` variant automatically from the same nav entry; if the `nav_translations` block (line 69) enumerates the label, add its zh-TW translation there too. Mirror exactly how `pre-commit.md` is wired so bilingual serving works.

CLAUDE.md contract for "New `docs/**/*.md`": nav entry in `mkdocs.yml` + `uv run mkdocs build --strict` (see Verification). Cross-links from `tool-managers.md` auto-reverse-link back.

### Out of scope / deliberately skipped
- **README.md** — only touch if it enumerates individual dev CLIs (shfmt/shellcheck aren't listed there today); otherwise no user-facing "What You Get" change for a single linter.
- **`.chezmoiexternal.toml.tmpl` / `upgrade_tools.sh` / `justfile`** — no new upgrade category (accepted Linux install-only gap, same as shfmt).
- The `rshade` actionlint skill — not installed.

## Verification

Per the repo's "validate with the app, not just syntax" invariant:

1. **CLI installs / formula name is real:** `brew install actionlint` locally (this is a darwin host), then `actionlint -version`.
2. **actionlint runs green on the repo's workflow:** `actionlint .github/workflows/docs.yml` — expect clean (exploration predicts no errors; main value is ongoing shellcheck coverage of `run:` blocks). Confirms shellcheck integration is active.
3. **pre-commit config valid + hook works:** `uv run pre-commit validate-config` then `uv run pre-commit run actionlint-system --all-files` (installs/pins the hook, lints `docs.yml`).
4. **ansible syntax:** `ansible-playbook <playbook> --syntax-check` for the devtools role (first-pass); if a devtools tag/host is available, a `--check` narrow run of the shellcheck+shfmt section.
5. **docs build strict** (tool-managers.md is in MkDocs nav): `uv run mkdocs build --strict`.

## Critical files
- `dot_ansible/roles/devtools/tasks/main.yml` (macOS list ~line 109; Linux section 2060–2088)
- `.pre-commit-config.yaml` (append after line 132)
- `docs/this_repo/tool-managers.md` (A–Z table, header line 931)
- `docs/tools/actionlint.md` **+** `docs/tools/actionlint.zh-TW.md` (new bilingual page)
- `mkdocs.yml` (nav entry under `Git & DevOps:`, ~line 308)
