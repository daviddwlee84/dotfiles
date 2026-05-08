# Claude Code `/doctor`: `keybindings.json must have a "bindings" array`

## Symptom

Verbatim from `claude` → `/doctor` (Claude Code v2.1.116, native install,
darwin-x64):

```
✘ Keybinding configuration issues · /Users/david/.claude/keybindings.json
└ keybindings.json must have a "bindings" array
  └ Use format: { "bindings": [ ... ] }
```

The file looked fine on disk (well-formed JSON, two metadata fields):

```json
{
  "$schema": "https://www.schemastore.org/claude-code-keybindings.json",
  "$docs": "https://code.claude.com/docs/en/keybindings"
}
```

`/doctor` exited non-zero on this single check; nothing else broken. Pressing
`f` ("fix with Claude") would have worked but didn't address the *source* of
the bad file: our chezmoi `modify_keybindings.json` overlay's bootstrap
branch.

## Root cause

`dot_claude/modify_keybindings.json` is a `modify_` script: chezmoi pipes the
current target file into stdin and the script emits new contents. The
**bootstrap path** (when the live file does not exist yet — fresh machine,
fresh `~/.claude/`) emitted only the `$schema` + `$docs` metadata stub,
deliberately omitting `.bindings` so we wouldn't ship a managed bindings list
that drifts as Claude Code renames/adds actions. The plan was: Claude Code
on first launch falls back to defaults, then writes the file back with
concrete entries; a subsequent `chezmoi apply` deep-merges our metadata in
without clobbering the live `.bindings` array.

That plan was correct for older Claude Code versions, which tolerated a
missing `.bindings` key. **v2.1.116 (and probably earlier in the 2.1.x
series) made `.bindings` mandatory** — the file is rejected with the doctor
error above, and Claude Code apparently does *not* heal the file by writing
defaults back. So the bootstrap stub became a permanent broken state on
fresh installs.

A separate aggravating factor: the steady-state `jq '. * $overlay'` filter
preserved whatever was on disk, so once a host had been bootstrapped with
the broken stub, no later `chezmoi apply` would fix it — the merge faithfully
preserved the missing `.bindings`.

## Fix

`dot_claude/modify_keybindings.json` was patched in two places:

1. **Bootstrap branch**: emit `"bindings": []` alongside the metadata.
   Empty array is sufficient — Claude Code accepts it and uses built-in
   defaults for everything.
2. **Steady-state branch**: heal-mode jq pipeline that injects
   `"bindings": []` only when the key is absent, never when it's already
   populated. This unbreaks hosts that were bootstrapped with the old stub
   without clobbering anyone's user-defined bindings:

   ```jq
   (. * $overlay)
   | if has("bindings") then . else . + {bindings: []} end
   ```

The healing leg is the load-bearing part — without it, every
already-bootstrapped host would need a manual fix.

## Verification

```bash
chezmoi diff ~/.claude/keybindings.json   # shows + "bindings": []
chezmoi apply ~/.claude/keybindings.json
claude   # then /doctor — Keybinding section should now be ✔ / absent
```

## Lessons

- A `modify_` script's bootstrap branch is a one-shot opportunity to write a
  *valid* file. If upstream tightens schema requirements, the stub goes
  stale silently — `/doctor` (or equivalent app self-check) is the only
  signal. Always include a healing leg in the steady-state branch so
  schema-tightening regressions can be repaired by the next
  `chezmoi apply`, not by manual edits across the fleet.
- "Conservative overlay that preserves whatever the app wrote" is great for
  not-clobbering the user, terrible for healing past mistakes. Add explicit
  `if has(...) then . else . + {default} end` rescue clauses for every key
  the app now requires.
- Empty `[]` for an array Claude Code uses for overrides is semantically
  equivalent to "use built-in defaults" — confirmed by `/doctor` accepting
  the file post-heal. Don't be tempted to ship a populated default list;
  that's the [Case study in `docs/tools/agent-overlays.md`](../docs/tools/agent-overlays.md)
  drift trap.

## Related

- [`dot_claude/modify_keybindings.json`](../dot_claude/modify_keybindings.json) — the patched script
- [`docs/tools/claude-code-keybindings.md`](../docs/tools/claude-code-keybindings.md) — user-facing docs
- [`docs/tools/agent-overlays.md`](../docs/tools/agent-overlays.md) — `modify_` overlay rationale
- [`pitfalls/modify-script-jq-bootstrap-cycle.md`](modify-script-jq-bootstrap-cycle.md) — adjacent bootstrap-ordering trap
