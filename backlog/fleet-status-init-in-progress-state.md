# Add `init-in-progress` state to `fleet-status` readiness probe

**Status**: P? · S
**Captured**: 2026-05-08, after real-world testing of commit `015587f`

## Context

`fleet-status` (introduced in `015587f`) probes each host over SSH and
classifies it into one of 12 states (up-to-date, behind, ahead, dirty, drift,
ready-to-update, busy, toml-mismatch, not-init, no-source, no-chezmoi,
unreachable). The classification is single-pass: the first matching condition
wins per the priority table in `_classify_readiness`.

Real-world test on 2026-05-08 surfaced a misclassification:

- User had manually started `chezmoi update --init` on `david_ubuntu` over a
  separate SSH session
- Chezmoi paused at the interactive `[O]verwrite/[A]bort?` prompt for a
  hand-edited file
- User then ran `just fleet-status` from their mac
- Probe reported `david_ubuntu` as `no-source`
- Five seconds later, `just fleet-apply` ran and `david_ubuntu` reported a
  *different* failure: `toml-mismatch` (template render failed because the
  remote's persisted `chezmoi.toml` was missing a new `promptBoolOnce` key)

The `no-source` was a probe artifact: the source dir on `david_ubuntu` was
mid-init or git-locked at the moment of the probe (likely `chezmoi update`'s
`--init` was rebuilding `~/.local/share/chezmoi/.git/` or had it under
`flock`). The static probe interpreted the transient absence as permanent.

## Proposal

Add a 13th state `init-in-progress` (yellow ⏳, like `busy`) that is detected
*before* the `no-source` / `toml-mismatch` / `not-init` checks:

```python
# Pseudocode for _classify_readiness
if has_active_chezmoi_pid(host):  # pgrep chezmoi on the remote
    return "init-in-progress" if not source_dir_exists else "busy"
```

The split between `init-in-progress` and `busy`:
- `busy` = chezmoi is running AND source dir exists (normal in-flight apply)
- `init-in-progress` = chezmoi is running AND source dir is missing/partial
  (init/clone phase — the probe should NOT predict `no-source` because the
  init may be about to create it)

Hint for the new state:
- `init-in-progress`: "chezmoi is initializing/cloning the source dir on this
  host — wait for it to finish or check the active SSH session"

## Estimated effort

S (small):
1. Add `init-in-progress` to `_READINESS_STYLE`, `_READINESS_HINTS` in
   `scripts/fleet_apply.py` (~10 LoC)
2. Update `_classify_readiness` to check for live chezmoi PID *before*
   classifying source absence as `no-source` (~5 LoC)
3. Add to the state list in:
   - `docs/this_repo/fleet-apply.md` (state table + workflow)
   - `CLAUDE.md` (the `fleet-status ≠ fleet-apply-status` invariant block,
     state enumeration)
4. Live-test by manually running `chezmoi update --init` on a host while
   probing it (race window is small but reproducible by adding a `read -n1`
   before the init in a test branch)

## Open questions

1. Is the `pgrep chezmoi` already done by the existing `busy` probe? If yes,
   reuse that; if no, factor out so we don't probe twice.
2. Should the probe distinguish `init-in-progress` from `init-paused-at-prompt`
   (the latter requires checking if the chezmoi process is in
   `state=S+ wchan=tty_read` — Linux only, doesn't work on macOS via SSH)?
   Probably overkill for v1.
3. UX: should `fleet-apply` refuse to start on hosts in `init-in-progress`
   state, or just warn? Probably warn (user may want to override after killing
   the stuck init).

## Don't do this if

- The misclassification is acceptable as a known edge case (user just ran
  `chezmoi update --init` in another SSH session ⇒ they know what they're
  doing; the `no-source` reading is a 1-shot stale value that self-resolves
  within seconds)
- The added complexity isn't worth it — `pgrep` over SSH adds ~50ms per host,
  and the existing `busy` probe already covers 80% of the "active chezmoi"
  case

In that case, document the edge case in `docs/this_repo/fleet-apply.md`
"Known caveats" instead of adding a state.

## Related

- `pitfalls/fleet-apply-self-stuck-running.md` — sibling fleet bug, also
  surfaced 2026-05-08
- Commit `015587f` — introduced `fleet-status`
