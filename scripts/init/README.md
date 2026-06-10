# dotfiles-init

Interactive wrapper around `chezmoi init` inspired by
[vercel-labs/skills](https://github.com/vercel-labs/skills).

`.chezmoi.toml.tmpl` in this repo defines ~19 prompts (`profile`, `email`,
`name`, plus 16 `installX` / preference flags). Running `chezmoi init`
walks you through them one-by-one. This wrapper groups them into a
single multi-select UI, adds pre-set bundles (`personal-mac`,
`work-mac`, `server-linux`, `minimal`), checks SSH-key prerequisites,
and then calls real `chezmoi init` with `--promptString` /
`--promptBool` / `--promptChoice` flags so chezmoi stays the source of
truth.

## Usage

### Fresh machine (via bootstrap.sh)

```bash
curl -fsSL https://raw.githubusercontent.com/daviddwlee84/dotfiles/main/bootstrap.sh | bash
```

`bootstrap.sh` installs `uv` if missing, re-execs against `/dev/tty`
(so interactive prompts work even though stdin is the curl pipe), then
runs `uv run --script <raw URL>` on this script.

### Re-apply on an already-initialized machine

```bash
uv run --script ~/.local/share/chezmoi/scripts/init/dotfiles_init.py
```

Detects that `~/.local/share/chezmoi/.git` exists and calls
`chezmoi init --apply` **without** a repo arg, which re-renders
`.chezmoi.toml.tmpl` with your new `--promptBool` / `--promptString`
overrides. Answers written by `promptStringOnce` / `promptBoolOnce`
are overridden by the CLI flags.

### Regenerate / drift check

```bash
# Regenerate .chezmoi.toml.tmpl + Dockerfile from PROMPTS:
uv run --script ~/.local/share/chezmoi/scripts/init/dotfiles_init.py gen --source .
# Or via just:
just gen-prompts

# Verify on-disk matches PROMPTS (no writes; non-zero exit = drift):
uv run --script ~/.local/share/chezmoi/scripts/init/dotfiles_init.py gen --check --source .
# `doctor` is a back-compat alias for `gen --check`.
```

`PROMPTS` is the single source of truth. `gen` renders the marker-delimited
prompt block in `.chezmoi.toml.tmpl` and the `ARG` + flag blocks in
`Dockerfile` from it, and coverage-checks the README option table. The
`dotfiles-init-gen-check` pre-commit hook runs `gen --check` so the surfaces
can never drift.

### List bundles

```bash
uv run --script ~/.local/share/chezmoi/scripts/init/dotfiles_init.py list-bundles
```

## Adding a new chezmoi prompt

`PROMPTS` in `dotfiles_init.py` is the single source of truth; the template
and Dockerfile are generated from it. So adding a prompt is now two steps:

1. **Edit `PROMPTS`** in `scripts/init/dotfiles_init.py` — add a `Prompt(...)`
   entry (key, kind, group, label, desc, default, `prompt_text`, and a
   `comment` doc block). For host-specific prompts set `condition=When(...)`
   and an `else_value` (baked in the template + hidden in the TUI on
   non-matching hosts). If it should be on-by-default for a bundle, also
   update `BUNDLES`.
2. **Run `just gen-prompts`** (or `dotfiles_init.py gen --source .`) to
   regenerate the marker regions in `.chezmoi.toml.tmpl` and `Dockerfile`,
   then add the new key to the README option table (coverage-checked).

Commit the regenerated files together. `just gen-prompts -- --check` (and the
`dotfiles-init-gen-check` pre-commit hook) fail if anything drifts — you never
hand-edit the generated regions.

## Bundles

A bundle is a named set of overrides on top of the individual prompt
defaults. Anything not listed in a bundle keeps its prompt default.

Current bundles (edit `BUNDLES` in `dotfiles_init.py` to tune):

| Bundle | Rough intent |
|---|---|
| `personal-mac` | Full personal setup — AI desktop apps, LLM tools, Brewfile, Bitwarden. |
| `work-mac` | Safer — coding agents + dev tooling, no personal AI/LLM apps. |
| `server-linux` | Headless — coding agents, networking, dev tooling; noRoot stays off. |
| `minimal` | Dotfiles only — no `installX` flags on. |
| `custom` | No overrides applied — tick every feature yourself. |

## Re-init semantics

`.chezmoi.toml.tmpl` uses `promptBoolOnce` / `promptStringOnce` (the
`-Once` variants). On first init they prompt; on subsequent runs they
read the existing value from `~/.config/chezmoi/chezmoi.toml` — **unless**
you pass `--prompt` to force re-prompting, or pass explicit
`--promptBool k=v` / `--promptString k=v` flags, which take precedence.

This wrapper always passes explicit flags, so re-running it always
updates answers to whatever you select in the UI.

## Behind GFW

The interactive bootstrap path needs to reach
`raw.githubusercontent.com` twice (once to fetch `bootstrap.sh`, once
to fetch `dotfiles_init.py`). If you're behind GFW without a
fan-qiang path, either:

- Set `DOTFILES_RAW_URL` / `DOTFILES_REF` environment variables to a
  mirror (e.g. Gitee) before running `bootstrap.sh`.
- Or use the non-interactive path from the top-level [README](../../README.md)
  and answer each prompt yourself — this goes straight through
  `get.chezmoi.io` (which has its own mirror routing).

## Design notes

- **Why single-file PEP 723 and not a proper package?** Matches the
  `scripts/fleet/apply.py` pattern in this repo — easier to maintain,
  no `pyproject.toml` to version, fetchable via
  `uv run --script <url>` without any package build step.
- **Why `uv run --script` and not `uvx`?** `uvx --from git+https://…`
  requires an installable package; single-file scripts use
  `uv run --script` instead. Same end-user experience (one command,
  no global install).
- **Why CLI flags to chezmoi, not a pre-written `~/.config/chezmoi/chezmoi.toml`?**
  `promptBoolOnce` reads from `[data]` in the config file, so
  pre-writing it would short-circuit chezmoi's own type validation
  and make re-init semantics confusing. CLI flags are the documented
  override path and the existing `Dockerfile` already uses them.

## Out of scope

- **Windows support** — chezmoi works on Windows, but questionary
  (prompt_toolkit) under Git Bash / MSYS is flaky. macOS + Linux only.
- **Adding new chezmoi prompts** — the 19 existing prompts are the
  right scope; this wrapper is a UI layer, not an expansion of the
  configuration surface.
- **Publishing to PyPI / Homebrew** — the `uv run --script <url>`
  path works without either. No package to maintain.
