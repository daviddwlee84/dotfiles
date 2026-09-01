# `mkdocs build --strict` aborts with ~350 warnings: social plugin dependencies "not found", then cairosvg "crashed"

**Symptoms** (grep this section):

- `uv run mkdocs build --strict` ends with:
  ```
  Aborted with 185 warnings in strict mode!
  ```
  and the warning list is almost entirely one repeated line (347 of 359 on this
  repo — one per page):
  ```
  WARNING -  Required dependencies of "social" plugin not found
  ```
- After installing the imaging extras the message **changes** rather than
  disappearing:
  ```
  WARNING -  "cairosvg" Python module is installed, but it crashed with:
  no library called "cairo-2" was found
  no library called "cairo" was found
  no library called "libcairo-2" was found
  cannot load library 'libcairo.so.2': dlopen(libcairo.so.2, 0x0002): tried: 'libcairo.so.2' (no such file), …
  cannot load library 'libcairo.2.dylib': dlopen(libcairo.2.dylib, 0x0002): tried: 'libcairo.2.dylib' (no such file), '/usr/lib/libcairo.2.dylib' (no such file, not in dyld cache), …
  Additionally, ctypes.util.find_library() did not manage to locate a library called 'libcairo.2.dylib'
  ```
- `python -c "import cairosvg"` fails the same way, **even though**
  `brew list --versions cairo pango` shows both installed and
  `/opt/homebrew/lib/libcairo.2.dylib` exists.
- CI (`.github/workflows/docs.yml`) builds the same commit **green**.
- The noise hides every other warning, so `--strict` is effectively unusable
  locally and unrelated problems accumulate unseen.

**First seen**: 2026-09 (Hanrus-Mac-mini, macOS 26.6.2, Apple Silicon)
**Affects**: macOS + Homebrew; any `mkdocs-material[imaging]` / cairosvg /
cairocffi consumer. Not Linux (apt puts libcairo on the default loader path).
**Status**: fixed in repo — `just docs-build` / `just docs-serve`

## Root cause — two separate gaps, one after the other

**1. `uv run` does not install optional extras.** The docs dependencies live in
`pyproject.toml` under `[project.optional-dependencies].docs`, and `[project]`
has **no base `dependencies`**. `uv run mkdocs …` syncs only the base set, so
`mkdocs-material[imaging]` (→ `cairosvg`, `pillow`) is never installed. CI does
not hit this because `.github/workflows/docs.yml` runs an explicit
`uv sync --extra docs` on the line before `uv run mkdocs build`. There was no
local equivalent, while `AGENTS.md` told agents to run bare
`uv run mkdocs build --strict` — a check that could never pass.

**2. macOS cannot find Homebrew's libcairo through `ctypes`.** `cairocffi`
resolves the native library with `ctypes.util.find_library('cairo')`, which
searches the dynamic loader's default paths. Homebrew's `/opt/homebrew/lib` is
not one of them, and System Integrity Protection **strips `DYLD_*` variables
from the environment inherited by system binaries**, so the usual
`export DYLD_LIBRARY_PATH` in a shell profile does not survive either. Linux
avoids this entirely because apt installs libcairo into `/usr/lib/...`.

## Workaround

```sh
uv sync --extra docs
DYLD_FALLBACK_LIBRARY_PATH="$(brew --prefix)/lib" uv run mkdocs build --strict
```

Prerequisite native libs (macOS): `brew install cairo pango`. Linux: the apt
list in `.github/workflows/docs.yml` (`libcairo2-dev libpango1.0-dev
libfreetype6-dev libffi-dev libjpeg-dev libpng-dev`).

Confirm the native side independently of mkdocs:

```sh
DYLD_FALLBACK_LIBRARY_PATH="$(brew --prefix)/lib" .venv/bin/python -c "import cairosvg; print(cairosvg.__version__)"
```

Use `DYLD_FALLBACK_LIBRARY_PATH`, not `DYLD_LIBRARY_PATH` — the fallback
variable is consulted after the normal search and does not override system
libraries that happen to share a name.

## Prevention

Both steps are baked into the justfile so nobody has to remember them:

```
just docs-build     # uv sync --extra docs + DYLD_FALLBACK_LIBRARY_PATH + --strict
just docs-serve     # same env, live preview
```

`AGENTS.md`'s "New `docs/**/*.md` → run the strict build" rule now names
`just docs-build` instead of the bare `uv run mkdocs build --strict`.

**Generalisable**: a plugin that reports "dependencies not found" may be
reporting a *native* library failure, not a missing Python package — install
the package first and re-read the (different) error before concluding.

## Related

- Backlog surfaced once this noise cleared:
  [`backlog/mkdocs-llmstxt-i18n-page-uri-mismatch.md`](../backlog/mkdocs-llmstxt-i18n-page-uri-mismatch.md)
  — 11 curated pages silently missing from `llms.txt`, invisible while the
  social plugin emitted 347 warnings per build
- [`backlog/mkdocs-anchor-drift.md`](../backlog/mkdocs-anchor-drift.md) — why
  `validation.links.anchors` is still `info`
- `.github/workflows/docs.yml` — the working reference environment
