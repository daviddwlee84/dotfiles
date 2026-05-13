# Should `fleet` / `mlf` / `sms` / `mi-router` live in standalone GitHub repos?

> **Status**: deferred research / `P?` × `L`. Captured 2026-05-13 after the `mlf` umbrella + TUI shipped (commits `65018ac`, `1f5cce6`). Triggered by the question: *"are we sure these belong in the dotfiles repo, or should each become a `uv tool install`-able PyPI/git package?"*

## What "these" are

| Binary | Source layout |
|---|---|
| `fleet` | `dot_dotfiles/bin/executable_fleet` (dispatcher) + `scripts/fleet/**` (modules) + `scripts/fleet/apply.py` |
| `mlf` | `dot_dotfiles/bin/executable_mlf` (dispatcher) + `scripts/mlf/**` (`__init__.py`, `tui.py`, `plot.py`, `list.py`, `download.py`) |
| `sms` | `dot_dotfiles/bin/executable_sms` (single-file CLI, tyro) |
| `mi-router` | `dot_dotfiles/bin/executable_mi-router` (single-file CLI, tyro) |

All four use **PEP 723 inline-deps `uv run --script` shebangs** today. No separate `pyproject.toml`. No setuptools entry point. No PyPI presence. `chezmoi apply` copies the binary into `~/.dotfiles/bin/`; the user's shell sources that into `$PATH` via the bin-migration commit (`3e86f3d`).

## The question

Three plausible homes:

1. **Status quo**: everything in this dotfiles repo. (current)
2. **One repo each**: `daviddwlee84/fleet`, `daviddwlee84/mlf`, etc. on GitHub. Each becomes a proper Python package, installable via `uv tool install git+https://github.com/daviddwlee84/mlf` (or PyPI). Dotfiles only ships `uv tool install …` into the `python_uv_tools` ansible role.
3. **One umbrella repo**: `daviddwlee84/dawei-cli-tools` (or similar) containing all four as subcommands or sibling entry points.

## Pros / cons

### (1) Status quo — keep in dotfiles

**Pros**
- **Single source of truth**: one git push deploys binary + ansible roles + tv channels + zsh aliases + tmux popup entries together. No version-skew between "the tool" and "the dotfiles that integrate it" (the tv channel keybindings and the TUI keybindings, see [CLAUDE.md](../CLAUDE.md) cross-file row — share mnemonics that have to stay in sync).
- **Zero-friction iteration**: `chezmoi apply` re-deploys after every edit. No version bump, no GitHub release, no `uv tool upgrade`.
- **PEP 723 is light**: no `pyproject.toml`, no `src/` layout, no `tests/` directory, no CI matrix. The dispatcher is 250 LOC, the modules are 100-500 LOC each.
- **Shared helpers are trivial**: `scripts/mlf/__init__.py` exports `make_client/open_id/copy_id/fetch_histories` to all four mlf modules with a simple `from scripts.mlf import …`. No need to publish them as a separate `mlf-core` package.
- **Discovery**: someone cloning this repo to set up a new machine gets the CLIs for free, fully wired into tmux/television/aliases.

**Cons**
- **Discoverability for non-users-of-this-repo**: someone who likes `mlf` can't `pipx install mlf` from a fresh shell — they have to either clone the whole dotfiles repo or copy the script + helper modules manually.
- **No version pins**: every git pull rolls everyone (well, every one of *me*'s machines) to head. If a TUI keybinding changes mid-day, the change lands on the next `chezmoi apply` without warning.
- **No issue tracker / PRs scoped to the tool**: `mlf`-specific bugs go into this repo's [TODO.md](../TODO.md) alongside ansible-role tweaks and zsh init bugs.
- **Hard to share**: showing a colleague `mlf` requires "first, clone my dotfiles" — high friction.

### (2) One repo each — `uv tool install`-able

**Pros**
- **Real packaging**: `pyproject.toml`, semver tags, GitHub releases, optional PyPI. Friends can `uv tool install mlf` and get the binary in 5 seconds.
- **Issue/PR isolation**: a `fleet` bug filed by a teammate doesn't drown in dotfiles repo noise.
- **CI per-tool**: matrix testing (Python 3.11/3.12/3.13 × macOS/Linux) makes more sense for a packaged tool than for an inline-deps script.
- **Independent versioning**: pin `mlf==0.4.2` in the dotfiles ansible role; upgrading is explicit (`just upgrade-uv-tools`) rather than implicit (`chezmoi apply`).

**Cons**
- **N repos to maintain**: README × N, release process × N, dependency PRs × N. Realistically, given the maintainer count (1), most will go stale.
- **Integration coupling**: `mlf`'s TUI mnemonics (`b/y/p/d/j`) mirror the `tv mlflow` channel's `Ctrl+<letter>` actions (per CLAUDE.md cross-file rule). With separate repos, this contract becomes "edit one, remember to PR the other" — exactly the kind of cross-repo drift the cross-file table exists to prevent.
- **Shared helpers need to be a package**: `make_client/open_id/copy_id/fetch_histories` would need to be either (a) duplicated per-repo, (b) extracted into a `mlf-common` PyPI package, or (c) inlined into each script. None are appealing.
- **The `uv run --script` ergonomics are *better* than `uv tool install`** for the dotfiles use case: PEP 723 deps live next to the code; first invocation resolves, subsequent invocations are instant from cache. No `pyproject.toml` ↔ code drift, no need to run `uv tool upgrade mlf` after every change.

### (3) One umbrella repo — `dawei-cli-tools` (or similar)

**Pros**
- **One PyPI publish for all four** — `uv tool install dawei-cli-tools` exposes `fleet`, `mlf`, `sms`, `mi-router` simultaneously.
- **Shared helpers become a proper module** (`dawei_cli_tools.mlf.client.make_client` etc.) — clean Python, no `scripts.mlf` sys-path hack.
- **Single release cadence** — sane for a solo maintainer.

**Cons**
- **All-or-nothing version**: bumping `mlf` forces a re-release of the entire umbrella. With PEP 723 today, `mlf` and `fleet` can evolve completely independently within the same commit.
- **Doesn't solve the dotfiles-coupling problem**: TUI keybindings still need to stay in sync with the tv channel, which is *necessarily* in the dotfiles repo (it's a `dot_config/television/cable/*.toml` file). Cross-repo dependency persists.
- **Heavier than current**: needs a `pyproject.toml`, `__init__.py` modules instead of `executable_*` shebang scripts, console-scripts entry points, etc. ~2 hours of refactor for unclear payoff.

## Tentative recommendation (revisit if any trigger fires)

**Keep in dotfiles (option 1) for now.** The PEP 723 inline-deps pattern is genuinely lighter than packaging, the integration with tv/tmux/ansible is real, and there's a single maintainer. Premature extraction would multiply the surface area.

**Triggers that would force a re-evaluation**:

1. **External user demand**: someone files an issue saying "I want to use `mlf` without your whole dotfiles repo" — at that point, do option 2 *for `mlf` only* (not the whole set).
2. **Cross-machine version skew matters**: if I find myself wanting to pin `mlf==0.3` on one host while running `mlf` head on another, that's the moment for option 2.
3. **CI for `mlf`/`fleet` is needed**: if the codebases grow enough that "I tested it locally" stops being sufficient — say > 1000 LOC or > 3 modules — extract to its own repo with proper CI.
4. **Shared `mlf-common` helpers grow > 200 LOC**: at that point, `scripts/mlf/__init__.py` is no longer a utility file — it's a library. Library deserves a package.

Until any of those fire, the gain from extraction doesn't justify the maintenance multiplier.

## Halfway alternative (worth trying first)

Add a one-line **manifest** to each CLI's `executable_*` header that records the *intent* of the future extraction:

```python
# Future extraction: `uv tool install git+https://github.com/daviddwlee84/mlf` once
# any of the triggers in backlog/python-cli-tui-extraction.md fires. Until then
# the canonical home is dot_dotfiles/bin/executable_mlf in the dotfiles repo.
```

That sets expectations for any future reader without forcing the refactor today.

## Open questions

- Does PEP 723 actually scale to a script that imports many modules? `mlf` already does — `executable_mlf` is 270 lines, `scripts/mlf/tui.py` is 500 lines. So far the only friction is `sys.path` hacking via `_source_path()`. That hack would disappear with packaging.
- Should the tv channel helpers (`mlflow-source.py` / `mlflow-preview.py`) move INTO `mlf` if it gets extracted? Probably yes — they'd become subcommands of `mlf` (e.g. `mlf channel-source` / `mlf channel-preview`) and the tv `.toml` would call those instead.
- For `uv tool install`, does `entry_points` work across Python versions cleanly? Should be fine on 3.11+ but verify.

## Related

- Phase 1 commit: `65018ac` (umbrella + subcommands)
- Phase 2 commit: `1f5cce6` (Textual TUI)
- Related cross-file rule: see CLAUDE.md row `executable_mlf` / `scripts/mlf/{tui,plot,list,download}.py` / mlflow.toml keybindings.
- See also: [bin-migration.md](bin-migration.md) — context for why `~/bin/` moved to `~/.dotfiles/bin/`, which is a *precondition* for option 2 (a system-installed `uv tool` binary lives in `~/.local/bin/` and shouldn't shadow the dotfiles one).
