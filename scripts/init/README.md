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
`chezmoi init --apply --prompt` **without** a repo arg, which re-renders
`.chezmoi.toml.tmpl`. On re-init the TUI is seeded from your **current**
`~/.config/chezmoi/chezmoi.toml` values so untouched options aren't reset.

The `--prompt` flag is load-bearing: see "Re-init semantics" below.

### Reconfigure (change settings after init)

Prefer this over hand-editing `~/.config/chezmoi/chezmoi.toml`:

```bash
# Interactive — grouped TUI pre-filled with your current values:
just reconfigure
# or the shell wrapper (locates the script via `chezmoi source-path`):
czcfg
# or the deployed PATH twin (on ~/.dotfiles/bin, with tab completion):
dotcfg

# Non-interactive single-key changes (space-separated key=value), e.g. fleet:
just reconfigure -- --set installLlmTools=true motdStyle=figlet --yes
czcfg --set noRoot=true --yes
dotcfg --set noRoot=true --yes

# Preview the chezmoi command without running it:
just reconfigure -- --dry-run
```

`reconfigure` reads the live `[data]` table, layers any `--set` overrides on
top, and runs `chezmoi init --apply --prompt` so the new answers actually take
effect. `--set` keys/values are validated against `PROMPTS` (unknown key, bad
bool token, or out-of-range choice fail fast). A stale/removed `profile` value
(e.g. the retired `macos_intel`) is dropped and re-detected.

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

`.chezmoi.toml.tmpl` uses `promptBoolOnce` / `promptStringOnce` /
`promptChoiceOnce` (the `-Once` variants). On first init they prompt; on
subsequent runs they read the existing value from
`~/.config/chezmoi/chezmoi.toml`'s `[data]` and **return it directly**.

Crucially, `--promptBool k=v` / `--promptString k=v` / `--promptChoice k=v`
flags do **NOT** override an already-stored value on their own — the `-Once`
function short-circuits before the `promptBool` lookup ever happens. Verified
empirically (chezmoi v2.69.x):

```console
$ printf '{{ promptBoolOnce . "installLlmTools" "P" false }}' \
    | chezmoi execute-template --init --promptBool "P=false"
true        # stored value wins; the flag is ignored

$ chezmoi init --prompt --promptBool "P=false" …
            # --prompt forces the Once call to re-fire → flag now wins
```

So to actually change answers you must pass `--prompt` (force re-prompting)
**together with** the full set of `--promptX` flags (which then satisfy the
re-fired prompts non-interactively). Both `init` (on re-init) and the
`reconfigure` subcommand pass `--prompt` plus a complete flag set for every
applicable prompt, so re-running them updates answers to your selections.
(Without `--prompt`, the stale `[data]` values silently persist —
`pitfalls/chezmoi-reinit-promptonce-keeps-stale-value.md`.)

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
