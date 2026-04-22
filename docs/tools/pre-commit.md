# pre-commit

> A **generic** reference for [pre-commit](https://pre-commit.com/) — the hook framework itself, how its Python environment model works, and how to make `pre-commit` robust when system Python breaks (the [`uv`](https://docs.astral.sh/uv/) trick). For *this* repo's hook list + scope rules, see [`this_repo/testing.md` § shellcheck + shfmt](../this_repo/testing.md#shellcheck--shfmt).

## What pre-commit is

[pre-commit](https://pre-commit.com/) is a language-agnostic framework for running short checks at git commit time. A `.pre-commit-config.yaml` file declares a list of "hook repos" (each a GitHub repo with one or more hooks), versioned by `rev:`. On first use, pre-commit clones each repo into `~/.cache/pre-commit/`, creates an **isolated virtualenv / gem / go-module / npm env** per repo, and caches it keyed on `rev:`.

Rough lifecycle:

```text
commit triggered
  → pre-commit run (via .git/hooks/pre-commit shim)
  → for each staged file, match against each hook's `files:` pattern
  → for each matching hook:
      - ensure the hook's env exists in ~/.cache/pre-commit/repo<hash>/
      - if missing, clone repo@rev, build env, cache it
      - invoke the hook's entrypoint with the matched file paths
  → non-zero exit → commit aborted
```

The key mental model: **pre-commit uses the Python it was installed with to bootstrap every hook's environment.** Hooks themselves may run on any language (Node, Go, Ruby, Rust, Python), but the `virtualenv`/`installer` call is initiated by that bootstrap Python. So if *that* Python is broken, nothing works.

## Common commands

```bash
pre-commit install            # install the git hook (.git/hooks/pre-commit)
pre-commit install --install-hooks   # plus pre-build every hook env now

pre-commit run                # run against currently staged files
pre-commit run --all-files    # run against EVERY tracked file
pre-commit run <hook-id>      # run just one hook (e.g. shellcheck)
pre-commit run <hook-id> --files path/to/file

pre-commit autoupdate         # bump every `rev:` to the repo's latest tag
pre-commit autoupdate --repo <url>   # bump only one
pre-commit clean              # wipe ~/.cache/pre-commit/
pre-commit gc                 # GC cached envs that no longer match any config

# Bypass temporarily (do NOT make it a habit):
git commit --no-verify        # skip all hooks for this commit
SKIP=hook-id-1,hook-id-2 git commit   # skip specific hooks
```

`autoupdate` does not *run* the hooks — it just rewrites `rev:` pins and says "remember to actually run them once". This repo wires it into `just upgrade-plugins`.

## Using `uv` to pin pre-commit's Python

[Astral's uv guide for pre-commit](https://docs.astral.sh/uv/guides/integration/pre-commit/) covers a different angle — providing `uv-*` hooks *inside* `.pre-commit-config.yaml` (e.g. `uv-lock`, `uv-export`, `pip-compile`). That is orthogonal to the question "which Python runs `pre-commit` itself?"

The trick relevant here: install `pre-commit` as a `uv tool`, pinned to a Python that works.

```bash
uv tool install --force pre-commit --python 3.13
```

This does three things:

1. Downloads a clean CPython 3.13 into `~/.local/share/uv/python/` (isolated from whatever Homebrew or the system is doing).
2. Creates a dedicated venv under `~/.local/share/uv/tools/pre-commit/`.
3. Symlinks `~/.local/bin/pre-commit` → that venv's script.

After that, `pre-commit` runs under a Python **you control**, independent of Homebrew/system upgrades. New hook environments will be bootstrapped by that 3.13, which means they'll use 3.13 too (unless a hook declares `language_version:` overrides).

### Make sure the uv-managed pre-commit wins on PATH

If you also have `/opt/homebrew/bin/pre-commit` (Homebrew), or `/usr/bin/pre-commit`, put `~/.local/bin` **earlier** in PATH, or uninstall the others:

```bash
# Option A: fix PATH
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc

# Option B: uninstall the brew copy
brew uninstall pre-commit

# Verify
which pre-commit     # → ~/.local/bin/pre-commit (symlink into uv tools)
pre-commit --version
```

### When to use this trick

- A brew Python upgrade just broke `pre-commit` and you don't want to wait for an upstream fix.
- You work across machines with different system Python versions and want the dev experience to be identical.
- You want the hook cache key (`pre-commit` computes it from the bootstrap Python version) to be stable across the team — pin everyone to `--python 3.13` and the cache path matches.

### Caveat

If the team shares `.pre-commit-config.yaml` but half the team uses Homebrew-installed pre-commit and half uses uv-pinned, each group will build and maintain a separate cache under `~/.cache/pre-commit/`. Harmless, just slightly wasteful. Cache keys are per-user anyway, so there is no cross-user invalidation risk.

## Debugging broken hook environments

Pre-commit errors usually fall into a few buckets:

### 1. "An unexpected error has occurred: CalledProcessError … virtualenv"

The bootstrap Python failed to build a virtualenv for one of the hook repos. Typical causes:

- **Broken `pyexpat` / standard-library shared object after a Python point-release upgrade.** Symptom: `ImportError: dlopen(...pyexpat...Symbol not found: _XML_SetAllocTrackerActivationThreshold`. That is a mismatch between the Python's bundled `libexpat` ABI and the system `/usr/lib/libexpat.1.dylib`. Fix: upgrade Python (`brew reinstall python@3.14` if brew has a patch release out) or side-step with the `uv tool install --python 3.13` trick above.
- **System `libssl` / `libcrypto` version mismatch** — similar class of issue.
- **Disk full / permissions** on `~/.cache/pre-commit/`.

### 2. A hook fails but you don't know why

```bash
pre-commit run <hook-id> --all-files --verbose
```

Verbose mode prints the full command line the hook invoked plus stdout/stderr. For formatters in `-d` (diff) mode (`shfmt`, `black --check`), the stderr often *is* the useful diff.

### 3. Hook runs too slowly on commit

```bash
# Install the env up-front so first-commit is fast:
pre-commit install --install-hooks

# Or skip a specific slow hook for this commit:
SKIP=ansible-lint git commit
```

### 4. "files were modified by this hook"

Auto-formatter hooks (trailing-whitespace, end-of-file-fixer, shfmt in `-w` mode, black) **rewrite** files then exit non-zero, forcing you to `git add` the rewritten version and re-commit. This is intentional: hooks can't modify the commit being created, only the working tree. Pattern:

```bash
git commit -m "..."
# hook rewrites files, commit aborts
git add -A
git commit -m "..."
# passes this time
```

If you want the formatter to check-only (so CI can fail without rewriting), most support `-d` / `--check` / `--diff`. This repo runs `shfmt -d` for that reason.

### 5. Reset when all else fails

```bash
pre-commit clean              # wipe cached envs, force re-bootstrap next commit
pre-commit uninstall          # remove the git hook
pre-commit install --install-hooks    # reinstall + pre-build
```

## Integration points worth knowing

- **`.pre-commit-config.yaml` at repo root** — the hook list + `rev:` pins.
- **`.pre-commit-hooks.yaml` in a hook provider repo** — how a repo exposes hooks. (Useful when writing a local `repo: local` hook or a custom shared repo.)
- **`language: system`** — opt out of the virtualenv sandbox and just run a shell command from PATH. This repo uses it for `./scripts/redact_secrets.py --fix` so the hook doesn't try to provision its own Python.
- **`language: python` + `additional_dependencies:`** — install extra pip deps into the hook's venv. The hook cache is keyed on this list, so adding a dep invalidates and rebuilds.
- **`files:` / `exclude:` regex** — the only performance knob you usually need. Narrow `files:` aggressively; hooks that run on every file get slow fast.
- **`stages:`** — hooks can target `pre-commit`, `pre-push`, `commit-msg`, `post-checkout`, etc. Default is just `commit`.

## See also

- [pre-commit.com](https://pre-commit.com/) — upstream docs.
- [Using uv with pre-commit](https://docs.astral.sh/uv/guides/integration/pre-commit/) — `uv`-managed hooks.
- [`docs/this_repo/testing.md` § shellcheck + shfmt](../this_repo/testing.md#shellcheck--shfmt) — how *this* repo uses pre-commit (hook list, scope, zsh carve-out).
- [`docs/this_repo/cheatsheet.md` § Pre-commit & Gitleaks](../this_repo/cheatsheet.md#pre-commit--gitleaks) — command quick-reference.
