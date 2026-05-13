# Plan: Relocate `~/bin/` → `~/.dotfiles/bin/` (namespace anchor)

## Context

Surfaced 2026-05-13, second half of the fleet umbrella CLI session. With `bin/executable_fleet` shipped (commit `26173a2`), chezmoi now deploys 5 binaries to `~/bin/` (sms, mi-router, x, sesh-preview, fleet). The current layout has three problems:

1. `~/bin/` is **visible** in `ls ~/` — adds clutter at the home root.
2. `~/bin/` is a **collision-prone target** — third-party installers (Anaconda, asdf, mise, manual drops) may write there. Today's collision risk is theoretical, not observed, but the count is growing.
3. The PATH comment at `dot_config/shell/00_exports.sh.tmpl:22` already telegraphs the intent ("`~/bin` for custom scripts, `~/.local/bin` for auto-installed tools") — the layout doesn't reflect that distinction (both look like generic `bin/` dirs to a user browsing their home).

The deferred `backlog/bin-migration.md` proposed `~/.dotfiles-bin/` (flat hidden dir). User's clarifying note signals a **namespace approach** instead: "這種設計 可能也可以把一些通用的 scripts/ 放過去" — they want one anchor that could later host `scripts/`, `lib/`, etc. as siblings to `bin/`.

**Decision**: target `~/.dotfiles/bin/` (option C of the question), with `~/.dotfiles/` reserved as the chezmoi-managed namespace anchor. Future `~/.dotfiles/scripts/`, `~/.dotfiles/lib/`, etc. can grow as siblings without proliferating top-level hidden dirs. `dotfiles` is tool-agnostic (no chezmoi-coupling in the name).

## Target layout

```
~/
├── .dotfiles/              ← chezmoi-managed namespace (hidden, NEW)
│   └── bin/
│       ├── fleet
│       ├── mi-router
│       ├── sms
│       ├── sesh-preview
│       └── x
├── .local/
│   └── bin/                ← uv tool / cargo / mise (unchanged)
├── .config/, .ssh/, .claude/, .codex/, .cursor/, ...
└── (no visible bin/ in `ls ~/`)
```

**Source dir**: rename `bin/` → `dot_dotfiles/bin/`. Inside `dot_dotfiles/`, the `bin/` subdir is a plain dir (NOT chezmoi's root-level special `bin/`), so the standard `executable_*` prefix handling applies to each file inside.

**PATH** (this round, transitional): `$HOME/.dotfiles/bin:$HOME/bin:$HOME/.local/bin:$PATH`
- `$HOME/.dotfiles/bin` first so new managed binaries take precedence
- `$HOME/bin` kept temporarily so user's hand-placed `~/bin/<x>` files (and the soon-to-be-orphaned chezmoi-managed copies) keep resolving until the user runs cleanup
- A follow-up commit drops `$HOME/bin` from PATH after fleet rollout completes (one personal sync cycle)

## Files to change

| File | Change | Notes |
|---|---|---|
| `bin/` (source dir) | Rename → `dot_dotfiles/bin/` | `mkdir -p dot_dotfiles && git mv bin dot_dotfiles/bin` preserves history for all 5 executables |
| `dot_config/shell/00_exports.sh.tmpl:21-23` | PATH prepend + comment update | New comment: `# ~/.dotfiles/bin: chezmoi-managed scripts (this repo)` / `# ~/bin: legacy (transitional, removed in follow-up)` / `# ~/.local/bin: auto-installed tools` |
| `README.md:189` | `~/bin/sms` → `~/.dotfiles/bin/sms` | User-facing intro |
| `README.md:192` | `~/bin/mi-router` → `~/.dotfiles/bin/mi-router` | User-facing intro |
| `docs/tools/sms.md:18` | `~/bin/sms` → `~/.dotfiles/bin/sms` | Tool doc |
| `docs/tools/mi-router.md:21` | `~/bin/mi-router` → `~/.dotfiles/bin/mi-router` | Tool doc |
| `docs/tools/sesh.md:405,417` | `~/bin/sesh-preview` → `~/.dotfiles/bin/sesh-preview` (both prose + `preview_command = "..."` example) | Tool doc + config example |
| `docs/tools/chezmoi-prefixes.md:48` | "personal scripts under `~/bin/` or `~/.local/bin/`" → "personal scripts under `~/.dotfiles/bin/` or `~/.local/bin/`" | Usage example |
| `docs/tools/chezmoi-prefixes.md:198` | `~/bin/sms` → `executable_sms` example → update both sides (`~/.dotfiles/bin/sms` → `dot_dotfiles/bin/executable_sms`) | Naming convention example |
| `docs/tools/chezmoi-prefixes.md:199` | The `~/.local/bin/x` aspirational note → either remove (now superseded) or rewrite to point at `~/.dotfiles/bin/x` | Aspirational note from before this migration |
| `docs/this_repo/fleet-apply.md:66,90` | `~/bin/fleet` → `~/.dotfiles/bin/fleet` | Umbrella CLI doc |
| `docs/this_repo/config-conventions.md:255` | "we have a few in `dot_bin/`" — fix typo AND update to `dot_dotfiles/bin/` | Was already a typo (`dot_bin/` doesn't exist) |
| `justfile:463` and `justfile:469` | L463 comment "Umbrella `fleet` CLI — same binary chezmoi deploys to `~/bin/fleet`" → `~/.dotfiles/bin/fleet`. L469 recipe `@uv run --script ./bin/executable_fleet` → `./dot_dotfiles/bin/executable_fleet`. | Justfile recipe needs BOTH the comment AND the source path updated |
| `backlog/bin-migration.md` | Status: `P? / deferred` → `Done 2026-05-13`. Add a "Resolution" section explaining: option C chosen for namespace extensibility per user signal; transitional PATH; follow-up to drop `$HOME/bin`. Keep the option comparison for future reference. | Per project-knowledge-harness convention |
| `CLAUDE.md` | Update the cross-file maintenance row that lists `bin/executable_fleet` to read `dot_dotfiles/bin/executable_fleet`. | Single cross-file row touched |
| **Sesh-preview consumers** | Audit `dot_config/sesh/**`, `dot_config/yazi/**`, and any other config that hardcodes `~/bin/sesh-preview`. Update to `~/.dotfiles/bin/sesh-preview`. | Implementation step: `grep -r 'bin/sesh-preview' dot_config/` before committing |
| **fleet remote payload** | `bin/executable_fleet` source uses `chezmoi source-path` discovery — no hardcoded `~/bin/fleet`. Confirm zero regression with `grep -E '(\~|\$HOME)/bin' bin/executable_fleet` (after rename: `dot_dotfiles/bin/executable_fleet`). | Sanity check |
| **Existing `~/bin/fleet` callers** | `scripts/fleet/info.py`, `scripts/fleet/tmux.py` and `scripts/fleet_apply.py` — grep for any `~/bin/fleet` or `$HOME/bin/fleet` SSH payload references. Expect zero. | Sanity check |

**Out of scope this round**:
- Removing `$HOME/bin` from PATH entirely (deferred to follow-up after one fleet sync cycle so every host has the new layout, AND the user has confirmed no hand-placed `~/bin/<x>` is in use)
- Deploying any portion of `scripts/` to `~/.dotfiles/scripts/` (separate task; this round only establishes the namespace)
- Adding an automatic cleanup `run_*.sh.tmpl` that `rm`s old `~/bin/{sms,mi-router,x,sesh-preview,fleet}` (safer to let the user clean up manually — chezmoi doesn't own non-chezmoi `~/bin/<x>` entries, and an auto-rm could surprise a user with a same-named binary they placed)
- A symlink shim at `~/bin/fleet` → `~/.dotfiles/bin/fleet` for backward compat (PATH precedence + transitional `$HOME/bin` retention covers this already without adding moving parts)

## Migration approach (hard cutover, transitional PATH)

1. **Local**: rename source dir, update PATH + docs, `chezmoi diff`, then `chezmoi apply`. Old `~/bin/<x>` linger on disk (chezmoi doesn't auto-remove unmanaged files). New `~/.dotfiles/bin/<x>` resolves first via PATH precedence.
2. **Verify locally** (see § Verification).
3. **Fleet rollout**: `fleet apply` from the local host pushes the new layout to every host. Each host: same hard cutover (new path deployed, old `~/bin/<x>` orphaned, PATH precedence makes new win).
4. **Manual cleanup** (per-host, user-driven, this commit just documents it):
   ```
   rm ~/bin/{sms,mi-router,x,sesh-preview,fleet}
   rmdir ~/bin 2>/dev/null  # only succeeds if empty
   ```
5. **Follow-up commit (separate)**: drop `$HOME/bin` from PATH in `00_exports.sh.tmpl`. Sequenced AFTER all hosts have applied the cutover (verified via `fleet status` showing `up-to-date` everywhere) AND after the user is comfortable that no hand-placed `~/bin/<x>` is in use.

**Why transitional PATH (not hard PATH cutover)**: a hard cutover would break any user-placed `~/bin/<x>` until the user `mv`s it. The cost of an extra PATH entry for one sync cycle is zero; the cost of bricking a user's personal binary is non-zero. Aligns with the repo's install-vs-upgrade conservatism: don't break things in place.

## Verification

End-to-end (after edits, before commit):

1. `chezmoi diff` — shows source-dir rename: `bin/executable_*` removed (5 entries), `dot_dotfiles/bin/executable_*` added (5 entries). Confirm count matches.
2. `chezmoi apply` — local apply succeeds; `~/.dotfiles/bin/{fleet,sms,mi-router,sesh-preview,x}` exist with `+x` bit. Verify: `ls -l ~/.dotfiles/bin/` shows all 5 with executable mode.
3. `ls -la ~/bin/` — old binaries still present (expected; will be cleaned up manually).
4. **Fresh shell** after `chezmoi apply`: `echo $PATH | tr ':' '\n' | head -5` — confirm `$HOME/.dotfiles/bin` is first, `$HOME/bin` second, `$HOME/.local/bin` third.
5. `which fleet sms mi-router sesh-preview x` — all resolve to `~/.dotfiles/bin/<name>` (NOT `~/bin/<name>`).
6. `fleet apply --hosts self --dry-run` — full smoke of the umbrella CLI from the new path.
7. `fleet status` — readiness probe still works.
8. `just fleet apply --hosts self --dry-run` — justfile recipe at L469 must dispatch to the new source path `./dot_dotfiles/bin/executable_fleet`.
9. Sesh preview: trigger sesh (via tmux `prefix + Space` menu or `sesh` command) — preview pane renders correctly (confirms `sesh-preview` resolved via new path).
10. `mkdocs build --strict` — all updated docs render with no broken anchors (known anchor-drift noted in `backlog/mkdocs-anchor-drift.md` — pre-existing, not from this change).
11. `git log --follow --oneline dot_dotfiles/bin/executable_fleet` — confirms history preserved across rename.
12. Per pitfalls: confirm no hidden `~/bin` ref in `bin/executable_fleet` (now `dot_dotfiles/bin/executable_fleet`) — `grep -nE '~/bin|\$HOME/bin' dot_dotfiles/bin/executable_fleet` returns nothing.

**Edge cases to specifically exercise**:
- A second shell open from BEFORE `chezmoi apply` — should keep working (`~/bin` still in PATH, old binaries still there).
- A new shell opened AFTER `chezmoi apply` — should pick new path (`$HOME/.dotfiles/bin` first in PATH).
- Fresh box bootstrap (e.g. fleet-managed remote that's never had `~/bin/`): `chezmoi apply` creates `~/.dotfiles/bin/`, never creates `~/bin/`. PATH still has `$HOME/bin` (no-op since dir doesn't exist; benign).
- `fleet-apply` from local to remote: the new `~/.dotfiles/bin/fleet` is deployed via chezmoi apply on the remote. Remote's existing `~/bin/fleet` becomes orphaned. PATH precedence on remote means `fleet` invocations there now resolve to the new path.

## Critical files

- `/Users/daviddwlee84/.local/share/chezmoi/bin/executable_{fleet,sms,mi-router,sesh-preview,x}` (5 files to `git mv`)
- `/Users/daviddwlee84/.local/share/chezmoi/dot_config/shell/00_exports.sh.tmpl` (L21-23 PATH + comment)
- `/Users/daviddwlee84/.local/share/chezmoi/justfile` (L463 comment + L469 source path in the `fleet` recipe)
- `/Users/daviddwlee84/.local/share/chezmoi/README.md` (L189, L192)
- `/Users/daviddwlee84/.local/share/chezmoi/docs/tools/sms.md` (L18)
- `/Users/daviddwlee84/.local/share/chezmoi/docs/tools/mi-router.md` (L21)
- `/Users/daviddwlee84/.local/share/chezmoi/docs/tools/sesh.md` (L405, L417)
- `/Users/daviddwlee84/.local/share/chezmoi/docs/tools/chezmoi-prefixes.md` (L48, L198, L199)
- `/Users/daviddwlee84/.local/share/chezmoi/docs/this_repo/fleet-apply.md` (L66, L90)
- `/Users/daviddwlee84/.local/share/chezmoi/docs/this_repo/config-conventions.md` (L255)
- `/Users/daviddwlee84/.local/share/chezmoi/backlog/bin-migration.md` (status → Done; add Resolution section)
- `/Users/daviddwlee84/.local/share/chezmoi/CLAUDE.md` (the fleet cross-file row — update `bin/executable_fleet` → `dot_dotfiles/bin/executable_fleet`)
- **TBD during implementation**: any `dot_config/sesh/**` or other consumer hardcoding `~/bin/sesh-preview`. Grep `dot_config/**/*` for `bin/sesh-preview` before committing.

## Rationale recap

| Option considered | Outcome |
|---|---|
| **Stay at `~/bin/`** | Rejected — user asked for cleaner `~/`, this doesn't help |
| **`~/.dotfiles-bin/`** (flat, backlog's pick) | Rejected — user's clarifying note signals namespace extensibility for future `scripts/` |
| **`~/.dotfiles/bin/`** (namespace, this plan) | **Chosen** — hides bin/, reusable anchor, tool-agnostic name |
| **`~/.local/share/chezmoi-bin/`** | Rejected — `share/` is XDG-data convention, executables are unusual there; couples name to tool; needs `.chezmoiignore.tmpl` carve-out |

Decision is reversible later (rename source dir again) but the cost of revisiting is identical to the cost of this migration — picking the most extensible option upfront has positive expected value.
