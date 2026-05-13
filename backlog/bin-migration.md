# Relocate `~/bin/` to a chezmoi-distinct path

**Status**: P? / deferred
**Effort**: M
**Related**: `bin/`, `dot_config/shell/00_exports.sh.tmpl:23`, `docs/this_repo/fleet-apply.md`

## Context

Surfaced 2026-05-13 while adding `bin/executable_fleet` (the umbrella `fleet`
CLI). Currently `bin/executable_*` files in chezmoi deploy to `~/bin/`:

```
bin/executable_sms           → ~/bin/sms
bin/executable_mi-router     → ~/bin/mi-router
bin/executable_x             → ~/bin/x   (also documented at ~/.local/bin/x)
bin/executable_sesh-preview  → ~/bin/sesh-preview
bin/executable_fleet         → ~/bin/fleet  (post 2026-05)
```

`~/bin` is a collision-prone target — third-party installers (Anaconda, asdf,
mise, custom build scripts) sometimes drop binaries there or expect it as
user-writable scratch space. With 5 chezmoi-managed entries and growing, "where
did this binary come from" is harder to answer than it should be.

User question (paraphrased): "can we rename `~/bin` to a more hidden path that
doesn't mix with `~/.local/bin` (which is for auto-installed `uv tool` / `cargo
install` / `mise` output), so it's obvious these are chezmoi-managed?"

## Options

| Option | Pros | Cons |
|---|---|---|
| **Stay at `~/bin/`** (current) | Zero migration cost; widely understood convention | Collision risk persists; mixes with non-chezmoi binaries |
| **`~/.dotfiles-bin/`** | Prefix telegraphs origin; clean isolation from `.local/bin` | Non-standard XDG; needs PATH update + every doc update |
| **`~/.local/share/chezmoi-bin/`** | XDG-aligned ("data" under chezmoi); explicit ownership | `share/` is conventionally for non-executable data; long path |

Recommended (if/when migrated): `~/.dotfiles-bin/` — the prefix is the whole
point, and `.local/share/` for executables is unusual enough to surprise
future contributors.

## Files affected by any migration

- `bin/executable_sms` / `mi-router` / `x` / `sesh-preview` / `fleet` — rename
  the source dir (`bin/` → e.g. `dot_dotfiles-bin/`)
- `dot_config/shell/00_exports.sh.tmpl:23` — PATH export (`$HOME/bin:$HOME/.local/bin`)
- `justfile` — audit for `~/bin` hardcodes (none today, but the new `fleet`
  recipe calls the source path, not the deployed binary, so no change required
  if the source dir is renamed too)
- `docs/this_repo/fleet-apply.md` — references to `~/bin/fleet`
- `docs/tools/chezmoi-prefixes.md:199` — the `~/.local/bin/x` aspirational note
- `pitfalls/*.md` — audit before migrating (none reference `~/bin` today)
- `bootstrap.sh` / `Dockerfile` if they mention PATH

## Migration ordering (when revisited)

1. Add new path to PATH alongside the old one (so `~/bin/sms` keeps working
   while the new `~/.dotfiles-bin/sms` is being adopted).
2. `chezmoi apply` deploys to the new path on every host (fleet-apply handles
   the rollout).
3. Flip every doc reference to the new path.
4. Wait one release / one personal sync cycle so all machines are up.
5. Remove the old `~/bin/` entries by hand on each host (or via a one-shot
   `run_onchange_after_*.sh.tmpl` that `rm`s the known set of legacy
   filenames — careful not to remove user-created `~/bin/*`).

## Decision

Deferred until either:
- A real collision happens (e.g. asdf-installed `sms` overrides chezmoi's), or
- `bin/` exceeds ~10 entries (currently 5).

The bin-migration risk (5 binaries × PATH × every doc reference) is
uncorrelated with the value of any single new binary; bundling them
into a feature commit expands the blast radius for no upside.

## Reference

- Original discussion: 2026-05-13, fleet-CLI session — user raised the
  question while approving the umbrella `fleet` binary plan.
- Plan file at the time: `.claude/plans/fleet-scripts-fleet-apply-py-cli-bin-jazzy-glacier.md`
