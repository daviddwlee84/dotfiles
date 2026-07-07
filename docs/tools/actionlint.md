# actionlint

> [actionlint](https://github.com/rhysd/actionlint) — a static checker for **GitHub Actions workflow files** (`.github/workflows/*.yml`). It goes far beyond YAML syntax: it type-checks `${{ }}` expressions, validates `uses:` action refs, runner labels, `cron` and glob patterns, and (its killer feature) pipes each `run:` block through [ShellCheck](https://www.shellcheck.net/) and Python snippets through [pyflakes](https://pypi.org/project/pyflakes/). In this repo it ships both as an on-PATH CLI and as a pre-commit hook.

## What it checks

| Category | Examples |
|---|---|
| **Workflow schema** | unknown keys, wrong types, missing required fields |
| **`${{ }}` expressions** | undefined context (`github.evnt`), type mismatches, bad function calls |
| **`uses:` refs** | malformed action refs, local action input/output mismatches |
| **Runners / cron / globs** | invalid `runs-on` labels, bad `schedule.cron`, `paths`/`branches` globs |
| **`run:` shell scripts** | delegates to **ShellCheck** — quoting, unset vars, `SC2086`, etc. |
| **Embedded Python** | `run:` steps with `shell: python` → **pyflakes** |
| **Security** | script-injection patterns (untrusted `${{ }}` interpolated into a shell body) |

## How this repo installs it

| OS | Mechanism | Owner |
|---|---|---|
| macOS | `brew install actionlint` (Homebrew-core formula) | [`devtools`](../../dot_ansible/roles/devtools/tasks/main.yml) role, alongside `shellcheck` / `shfmt` |
| Linux (Debian/Ubuntu) | **Linuxbrew best-effort** — installed only when `brew` is present, mirroring how `shfmt` is handled (actionlint is not in apt) | same `devtools` role, `# --- shellcheck + shfmt ---` section |

**Linux gap by design:** on a Linux host *without* Linuxbrew, the CLI is not installed — but the pre-commit hook (below) still lints workflows there, since the `actionlint` hook variant can build its own binary via Go. See the A–Z row in [`this_repo/tool-managers.md`](../this_repo/tool-managers.md#tool-index-az).

## ShellCheck integration (no config needed)

actionlint **auto-discovers `shellcheck` on `PATH`** and runs it against every `run:` block automatically — there is nothing to wire up. This repo already installs `shellcheck` everywhere (apt on Linux, brew on macOS; see the shellcheck / shfmt row in [`tool-managers.md`](../this_repo/tool-managers.md#tool-index-az)), so the integration is active out of the box. If `shellcheck` were missing, actionlint would simply skip that check rather than error.

## pre-commit hook

Wired in [`.pre-commit-config.yaml`](../../.pre-commit-config.yaml), grouped with the other linters after `shfmt`:

```yaml
  - repo: https://github.com/rhysd/actionlint
    rev: v1.7.12
    hooks:
      - id: actionlint-system
        files: '^\.github/workflows/.*\.ya?ml$'
```

- **`actionlint-system`** reuses the on-PATH binary the `devtools` role installs, so the hook and ad-hoc `actionlint` runs stay on the same version (no second copy, no Go build).
- `files:` scopes the hook to the workflow directory — it never fires on unrelated YAML.
- The `rhysd/actionlint` repo also offers `id: actionlint` (`language: golang`, builds its own binary — use this on hosts without the CLI) and `id: actionlint-docker` (runs in a container). Both auto-discover `shellcheck` the same way.

Run it manually:

```bash
pre-commit run actionlint-system --all-files
```

## Ad-hoc usage

```bash
actionlint                                 # lint every .github/workflows/*.yml
actionlint .github/workflows/docs.yml      # lint one file
actionlint -color                          # force colored output
actionlint -shellcheck=                    # disable the shellcheck integration
actionlint -version
```

### Optional config: `.actionlintrc.yaml`

Drop a `.actionlintrc.yaml` at the repo root to tune behavior — e.g. self-hosted runner labels, per-path ignores, or passing extra flags to shellcheck/pyflakes:

```yaml
self-hosted-runner:
  labels:
    - my-custom-runner
config-variables: null   # allow any configuration variable name
```

This repo does not ship one today (defaults are fine for its single `docs.yml` workflow).

## Related

- [pre-commit](pre-commit.md) — the hook framework this rides on.
- [`tool-managers.md` § Tool index](../this_repo/tool-managers.md#tool-index-az) — install mechanism per OS (shared with `shellcheck` / `shfmt`).
- Upstream: [rhysd/actionlint](https://github.com/rhysd/actionlint) · [checks documentation](https://github.com/rhysd/actionlint/blob/main/docs/checks.md).
