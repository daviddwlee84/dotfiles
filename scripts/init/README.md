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

### Schema parity check

```bash
uv run --script ~/.local/share/chezmoi/scripts/init/dotfiles_init.py doctor
```

Greps `.chezmoi.toml.tmpl` + `Dockerfile` and compares to the
embedded `PROMPTS` tuple. Non-zero exit = drift. Run this in CI /
pre-commit so the three surfaces never go out of sync.

### List bundles

```bash
uv run --script ~/.local/share/chezmoi/scripts/init/dotfiles_init.py list-bundles
```

## Adding a new chezmoi prompt

Per the "Dockerfile + dotfiles_init wrapper" cross-file rule in
[../../CLAUDE.md](../../CLAUDE.md), a new prompt requires changes in
three places, in the same commit:

1. **`.chezmoi.toml.tmpl`** — add the
   `promptBoolOnce` / `promptStringOnce` / `promptChoiceOnce` call.
2. **`Dockerfile`** — add a matching `ARG CHEZMOI_*` build argument
   and a `--promptBool` / `--promptString` flag on the `chezmoi init`
   command.
3. **`scripts/init/dotfiles_init.py`** — add a matching entry to the
   `PROMPTS` tuple (key, kind, group, label, desc, default). If the
   prompt should be on-by-default for any bundle, also update
   `BUNDLES`.

Verify with `dotfiles_init.py doctor` before committing.

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
