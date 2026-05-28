# Fix: `chezmoi update` blocked by dirty ble.sh clone

## Context

`chezmoi update` fails when it tries to refresh the ble.sh git-repo external:

```
error: Your local changes to the following files would be overwritten by merge:
    lib/core-complete.sh  lib/core-syntax.sh  lib/init-term.sh ...
chezmoi: .local/share/blesh: ... exit status 1
```

### Root cause — NOT our config, NOT agent-generated

It is **ble.sh's own `make install` mutating its git checkout.**

- `.chezmoiexternal.toml.tmpl` clones the source to `~/.local/share/blesh` (`type = "git-repo"`, weekly `pull --ff-only --recurse-submodules`).
- `.chezmoiscripts/global/run_onchange_after_26_install_blesh.sh.tmpl` runs `make -C ~/.local/share/blesh install PREFIX=$HOME/.local`.
- In ble.sh's `GNUmakefile`, `PREFIX=$HOME/.local` → `DATADIR=$HOME/.local/share` → **`INSDIR=$HOME/.local/share/blesh`** — i.e. the install destination is the **same directory as the git clone**.
- `make install` copies the *processed* build output (`out/lib/*.sh`: license header added, comments + blank lines stripped) **over the tracked source `lib/*.sh`**, plus writes untracked `licenses/`. This dirties the working tree (`git diff --stat`: 26 files, ~11k deletions).
- Next weekly refresh, chezmoi's `git pull --ff-only` refuses to overwrite the locally-modified tracked files → the error.

So the "local changes" are build artifacts, not anything we or an agent wrote. The structural bug is the **clone-path == install-PREFIX-target collision** (ble.sh expects these to differ).

## Permanent fix — Option 2: decouple source clone from install target (chosen)

ble.sh's intended layout: clone the source somewhere, then `make install PREFIX=~/.local` installs into `~/.local/share/blesh`. We currently put the clone *at* the install target, so `make install` writes over its own checkout. Fix = move the clone out of the install dir.

**New layout:**

```
~/.local/src/blesh     # git clone — source only; chezmoi pulls/updates here
~/.local/share/blesh   # make-install output (runtime) — NOT a git repo
```

The runtime artefact stays at `~/.local/share/blesh/ble.sh`, so **`dot_bashrc.tmpl` (lines 50/52) and all docs that reference that path need no changes** — only the source-clone location moves.

### Edits

**1. `.chezmoiexternal.toml.tmpl` (~lines 91-112)** — move the external from the install dir to a source dir:
- Rename the table key `[".local/share/blesh"]` → `[".local/src/blesh"]` (and its `.clone` / `.pull` subtables). Keep `type`, `url`, `refreshPeriod`, and the `--recurse-submodules` args identical.
- Fix the comment block: the runtime artefact still lives at `~/.local/share/blesh/ble.sh` (clarify the clone is now source-only at `~/.local/src/blesh`); correct the stale script name `run_onchange_after_25_install_blesh` → **`26`**.

**2. `.chezmoiscripts/global/run_onchange_after_26_install_blesh.sh.tmpl`** — point the build at the new source dir:
- `BLESH_SRC="$HOME/.local/src/blesh"` (was `.../share/blesh`).
- HEAD-hash trigger path (line 12): `joinPath .chezmoi.homeDir ".local/src/blesh/.git/HEAD"`.
- `make -C "$BLESH_SRC" install PREFIX="$HOME/.local"` is unchanged — but now `BLESH_SRC` (src) ≠ `INSDIR` (`~/.local/share/blesh`), so the install no longer dirties the checkout.
- Update the path comments in the header (lines 2, 16-17) to reflect src-vs-runtime split.

**3. New migration script `.chezmoiscripts/global/run_once_before_NN_migrate_blesh_path.sh.tmpl`** (pick an unused low `NN` among the `run_*_before_*` scripts) — remove the old git-repo-at-install-dir so `make install` can repopulate a clean runtime dir. **Guarded exactly as the user specified** (only delete when it is still a git clone, so the post-migration plain install dir is never re-deleted):

```bash
old="$HOME/.local/share/blesh"
if [ -d "$old/.git" ]; then
    rm -rf "$old"
fi
```

A `*_before_*` script runs before the `run_after_26` install, so the dir is cleared before `make install` recreates it. Independent of the new `~/.local/src/blesh` clone (different path).

**4. `pitfalls/` entry** (project-knowledge-harness convention — title by *symptom*, verbatim error): e.g. `pitfalls/chezmoi-update-blesh-local-changes-overwritten.md`. Record the exact `Your local changes to the following files would be overwritten by merge` error, the clone==install-PREFIX collision root cause, and the decouple fix. Add its index row per `pitfalls/README.md`.

### Optional doc touch-ups (low priority)
- `docs/shells/bash.md:14` — one-line clarification that the source clone now lives at `~/.local/src/blesh` (runtime still `~/.local/share/blesh`).
- `docs/zsh/oh-my-zsh-plugins.md:78` references `.chezmoiexternal.toml.tmpl:105-112` by line number — refresh if it drifts.

## Apply / migration order on this (broken) machine

No separate `git reset --hard` unblock is needed — once the config change lands, chezmoi no longer pulls the old path:

1. Make the four edits above in `~/.local/share/chezmoi`.
2. `chezmoi apply` (local working tree, no git pull): old external is gone → migration `rm -rf`s the dirty `~/.local/share/blesh` git repo → new external clones `~/.local/src/blesh` → install builds a clean runtime into `~/.local/share/blesh`.

(If you want to verify the *old* path could pull before switching, `git -C ~/.local/share/blesh reset --hard` first — but it's unnecessary given the migration deletes that dir.)

## Verification

- `chezmoi apply` (then `chezmoi update`) completes with **no** `.local/.../blesh` error.
- `~/.local/src/blesh/.git` exists (source clone); `~/.local/share/blesh/.git` does **not** (plain runtime dir).
- `~/.local/share/blesh/ble.sh` exists; a fresh `bash -ilc 'echo "$BLE_VERSION"'` prints a version (ble.sh attached).
- Simulate the weekly refresh: `chezmoi apply --refresh-externals` twice in a row → both succeed, `git -C ~/.local/src/blesh status` stays clean (no dirtying of the source checkout). This is the regression that originally broke.
- `uv run mkdocs build --strict` if any `docs/**` lines were touched.
