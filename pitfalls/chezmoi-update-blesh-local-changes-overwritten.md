# `chezmoi update` aborts on ble.sh: "local changes would be overwritten by merge"

**Symptoms** (grep this section): `chezmoi update` / `chezmoi apply --refresh-externals` fails while refreshing the ble.sh git-repo external with:

```
error: Your local changes to the following files would be overwritten by merge:
    lib/core-complete.sh
    lib/core-syntax.sh
    lib/init-term.sh
    lib/keymap.vi_digraph.sh
    lib/test-main.sh
    lib/test-util.sh
Please commit your changes or stash them before you merge.
Aborting
chezmoi: .local/share/blesh: /Users/<user>/.local/share/blesh: exit status 1
```

`git -C ~/.local/share/blesh status` shows ~26 tracked `lib/*.sh` modified (a `git diff` reveals an added BSD-3-Clause license header + stripped comments/blank lines), plus untracked `licenses/`.

**First seen**: 2026-05
**Affects**: any host where the ble.sh source was cloned into `~/.local/share/blesh` AND `make install PREFIX=~/.local` ran there (the old chezmoi external layout). All OSes.
**Status**: fixed (source clone relocated to `~/.local/src/blesh`)

## Symptom

The weekly external refresh (`refreshPeriod = "168h"`, `pull --ff-only --recurse-submodules`) aborts because the working tree of `~/.local/share/blesh` is dirty. The "local changes" look mysterious — nobody edited ble.sh's source, and the diff is a wholesale rewrite (license header on, comments off) of files like `lib/core-syntax.sh`.

## Root cause

NOT user config, NOT agent-generated. It is **ble.sh's own `make install` overwriting its git checkout**, because the clone path and the install target were the same directory:

- chezmoi external cloned the source to `~/.local/share/blesh`.
- `run_onchange_after_26_install_blesh.sh.tmpl` ran `make -C ~/.local/share/blesh install PREFIX=$HOME/.local`.
- In ble.sh's `GNUmakefile`, `PREFIX=$HOME/.local` → `DATADIR=$HOME/.local/share` → **`INSDIR=$HOME/.local/share/blesh`** — identical to the clone.
- `make install` copies the *processed* build output (`out/lib/*.sh`, with license header + stripped comments) over the tracked source `lib/*.sh`, and writes untracked `licenses/`. The checkout is now dirty.
- Next `git pull --ff-only` refuses to clobber the locally-modified tracked files → the abort above.

ble.sh's documented usage clones the source somewhere and installs into a *separate* `PREFIX`; co-locating them is the trap.

## Workaround

Immediate unblock on a still-broken host (discards the build-mutated tracked files; untracked `licenses/` and submodule content don't block a fast-forward):

```bash
git -C ~/.local/share/blesh reset --hard
chezmoi apply --refresh-externals   # or re-run `chezmoi update`
```

This only re-arms the trap — the next install dirties the tree again. The permanent fix below removes the collision.

## Prevention

Decouple the source clone from the install target (the fix now in-repo):

- `.chezmoiexternal.toml.tmpl` clones to `[".local/src/blesh"]` (source only).
- `run_onchange_after_26_install_blesh.sh.tmpl` sets `BLESH_SRC="$HOME/.local/src/blesh"` and the HEAD-hash trigger reads `~/.local/src/blesh/.git/HEAD`; `make install PREFIX=$HOME/.local` still builds the runtime into `~/.local/share/blesh`, which is now a plain dir (no `.git`).
- `run_once_before_10_migrate_blesh_path.sh.tmpl` removes the old `~/.local/share/blesh` **only if it is still a git clone** (`[ -d "$old/.git" ]`), so `make install` repopulates a clean runtime dir.

The runtime artefact stays at `~/.local/share/blesh/ble.sh`, so `dot_bashrc.tmpl` and docs that source it are unchanged.

General rule: never point a build/install step's output dir at a chezmoi git-repo external's clone path — installers that rewrite tracked files in place will dirty the tree and break `pull --ff-only`.

## Related

- `.chezmoiexternal.toml.tmpl` (ble.sh block) — the decoupled layout + WHY comment.
- `.chezmoiscripts/global/run_onchange_after_26_install_blesh.sh.tmpl` — build-from-src.
- `.chezmoiscripts/global/run_once_before_10_migrate_blesh_path.sh.tmpl` — migration.
- [`pitfalls/blesh-set-v-leaks-gexec-wrapper.md`](blesh-set-v-leaks-gexec-wrapper.md) — other ble.sh trap.
- `docs/shells/bash.md` — ble.sh init order (12-step).
- Upstream: <https://github.com/akinomyoga/ble.sh> (install docs use a separate clone vs PREFIX).
