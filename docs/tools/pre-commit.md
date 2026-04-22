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

## How this repo installs pre-commit (single source of truth)

This repo installs `pre-commit` **the same way on every OS**: as a uv-managed tool pinned to CPython 3.13.

```bash
uv tool install --force pre-commit --python 3.13
```

That exact command is the single source of truth. It runs in three places and all three converge on `~/.local/bin/pre-commit`:

| Entry point | File | When it runs |
|---|---|---|
| Ansible role | [`dot_ansible/roles/security_tools/tasks/main.yml`](../../dot_ansible/roles/security_tools/tasks/main.yml) | `chezmoi apply` → `ansible-playbook macos.yml/linux.yml`, and `just ansible-security` |
| Justfile recipe | [`justfile`](../../justfile) `pre-commit-install-tool` (depended on by `pre-commit-setup` and `setup-dev`) | `just pre-commit-setup`, `just setup-dev` |
| Doctor recipe | [`scripts/pre-commit-doctor.sh`](../../scripts/pre-commit-doctor.sh) via `just pre-commit-doctor` | On demand, when hooks break |

`uv` itself is installed by [`run_once_before_00_bootstrap.sh.tmpl`](../../run_once_before_00_bootstrap.sh.tmpl) before any ansible role runs, so the install command above always has `uv` available.

What `uv tool install --force pre-commit --python 3.13` actually does:

1. Downloads a clean CPython 3.13 into `~/.local/share/uv/python/` (isolated from whatever Homebrew or the system is doing).
2. Creates a dedicated venv under `~/.local/share/uv/tools/pre-commit/`.
3. Symlinks `~/.local/bin/pre-commit` → that venv's script.

After that, `pre-commit` runs under a Python **you control**, independent of Homebrew/system upgrades. New hook environments will be bootstrapped by that 3.13, which means they'll use 3.13 too (unless a hook declares `language_version:` overrides).

### Why pinned 3.13 (not Homebrew Python)

Homebrew's `python@3.14` has historically shipped with a bundled `libexpat` whose ABI disagreed with the system `/usr/lib/libexpat.1.dylib` on macOS, breaking every `virtualenv` call that `pre-commit` issues to build hook repos (symptom: `Symbol not found: _XML_SetAllocTrackerActivationThreshold` on import of `pyexpat`). Pinning to CPython 3.13 side-steps that whole class of brew-python-upgrade breakage — and it makes the hook cache key (which pre-commit derives from the bootstrap Python version) stable across machines and teammates.

### PATH precedence: how `~/.local/bin/pre-commit` wins

The uv install only helps if `~/.local/bin` beats brew's `/opt/homebrew/bin` and conda's `~/miniforge3/bin` on PATH. This repo's zsh export ([`dot_config/zsh/00_exports.zsh.tmpl:21`](../../dot_config/zsh/00_exports.zsh.tmpl)) handles that:

```sh
export PATH="$HOME/bin:$HOME/.local/bin:$PATH"
```

Because this export runs before conda's lazy init ([`dot_config/zsh/tools/04_conda_mamba.zsh`](../../dot_config/zsh/tools/04_conda_mamba.zsh)), the uv-managed binary wins. Verify:

```bash
which pre-commit        # → ~/.local/bin/pre-commit
which -a pre-commit     # lists all copies, in PATH order
```

### The conda-shadow failure mode

If you see `which pre-commit` return `~/miniforge3/bin/pre-commit` (or similar), conda installed `pre-commit` transitively into its `base` env and something in your PATH ordering put conda ahead of `~/.local/bin`. Fix options:

```bash
# Option A: just ask the doctor
just pre-commit-doctor

# Option B: drop conda's copy
conda remove -n base pre-commit     # if it was installed into base
conda deactivate                    # or just leave base

# Option C: uninstall brew's copy (if that's the shadow instead)
brew uninstall pre-commit
```

The PATH-shadow case is the usual reason "I ran `just setup-dev` but `pre-commit --version` shows a different version than the ansible role installed."

### Team / multi-machine caveat

If the team shares `.pre-commit-config.yaml` but some teammates use Homebrew-installed pre-commit and others use uv-pinned, each group will build and maintain a separate cache under `~/.cache/pre-commit/`. Harmless, just slightly wasteful. Cache keys are per-user anyway, so there is no cross-user invalidation risk — but for a fully reproducible cache key, have everyone run the ansible role / `just pre-commit-setup` so they all end up on the same uv-pinned 3.13.

### Not to be confused with `uv-*` hooks

[Astral's uv guide for pre-commit](https://docs.astral.sh/uv/guides/integration/pre-commit/) covers a different angle — providing `uv-*` hooks *inside* `.pre-commit-config.yaml` (e.g. `uv-lock`, `uv-export`, `pip-compile`). That is orthogonal to the question "which Python runs `pre-commit` itself?" (which is what this section is about). This repo doesn't currently use any `uv-*` hooks in `.pre-commit-config.yaml`.

## Debugging broken hook environments

Before diving into the buckets below, **try the doctor first** — it covers 90% of cases:

```bash
just pre-commit-doctor                 # diagnose + auto-repair via uv
just pre-commit-doctor --run-hooks     # same, plus smoke-test hook envs
./scripts/pre-commit-doctor.sh --check # diagnose-only (no reinstall)
```

The doctor checks `uv` is present, confirms `pre-commit` resolves to `~/.local/bin/pre-commit` (not a conda/brew shadow), scans for the known-bad `pyexpat` / `virtualenv` error signatures, and re-runs `uv tool install --force pre-commit --python 3.13` + `pre-commit clean` if anything is wrong.

Pre-commit errors usually fall into a few buckets:

### 1. "An unexpected error has occurred: CalledProcessError … virtualenv"

The bootstrap Python failed to build a virtualenv for one of the hook repos. Typical causes:

- **Broken `pyexpat` / standard-library shared object after a Python point-release upgrade.** Symptom: `ImportError: dlopen(...pyexpat...Symbol not found: _XML_SetAllocTrackerActivationThreshold`. That is a mismatch between the Python's bundled `libexpat` ABI and the system `/usr/lib/libexpat.1.dylib`. **Fix:** `just pre-commit-doctor` — it re-installs pre-commit under a uv-pinned CPython 3.13 that isn't affected. (Manual equivalent: `uv tool install --force pre-commit --python 3.13 && pre-commit clean`.)
- **System `libssl` / `libcrypto` version mismatch** — similar class of issue. Same fix: re-pin via the doctor.
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
