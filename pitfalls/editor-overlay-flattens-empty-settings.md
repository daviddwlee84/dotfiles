# Cursor lost its color theme / file icons after `chezmoi apply` — settings.json collapsed to only the 6 overlay keys

**Symptoms** (grep this section): Cursor (or VSCode / Antigravity) loses its `workbench.colorTheme` and `workbench.iconTheme` after `chezmoi apply`; editor reverts to `Dark Modern` + no file icons; `settings.json` is suddenly ~286 bytes containing *only* the overlay keys (`editor.fontFamily`, `editor.fontSize`, `editor.lineNumbers`, `editor.formatOnSave`, `editor.acceptSuggestionOnEnter`, `terminal.integrated.fontFamily`); `keybindings.json` reset to the 5-binding chezmoi template; "theme changed / shortcuts feel weird after reinstall"; user blames the Brewfile cask reinstall (it's **not** the cause)
**First seen**: 2026-07-02 (daviddwlee84@Da-Weis-Mac-mini, macOS, `chezmoi apply --init`)
**Affects**: any editor managed by `.chezmoitemplates/editor/modify.sh` (VSCode `Code`, Cursor, Antigravity × macOS + Linux) **when the live `settings.json` is empty or absent at apply time**. A fresh install of the editor, a never-opened editor, or a profile whose `User/settings.json` hasn't been written yet are the common triggers.
**Status**: **not a bug in the overlay** — working as designed (`jq '. * $overlay'` on an empty base yields overlay-only). No code fix; this doc is the record + the recovery procedure. Could graduate to a guard (see Prevention) if it recurs.

## Symptom

After `chezmoi apply`, Cursor opens with the default `Dark Modern` theme and
**no file icons** (Material Icon Theme gone). The live file:

```
$ stat -f '%Sm  (%z bytes)' ~/Library/Application\ Support/Cursor/User/settings.json
Jul  2 15:35:37 2026  (286 bytes)

$ cat ~/Library/Application\ Support/Cursor/User/settings.json
{
  "editor.fontFamily": "Hack Nerd Font Mono, Menlo, Monaco, 'Courier New', monospace",
  "editor.fontSize": 12,
  "editor.lineNumbers": "relative",
  "editor.formatOnSave": true,
  "editor.acceptSuggestionOnEnter": "smart",
  "terminal.integrated.fontFamily": "Hack Nerd Font Mono"
}
```

Exactly the 6 keys in [`.chezmoitemplates/editor/overlay.json`](../.chezmoitemplates/editor/overlay.json)
— every other user key (theme, icon theme, and everything else) is gone.
`keybindings.json` is simultaneously the plain chezmoi template (740 bytes,
`create_` seed).

Crucially, **the other editors are untouched**: VSCode and Antigravity
`settings.json` are 9–10 KB with their theme keys intact, same shared overlay.
Only the editor whose live file was empty at apply time got flattened.

## Root cause

Two red herrings to kill first:

1. **The Brewfile cask reinstall did NOT do this.** `brew` installs
   `/Applications/Cursor.app` (the app binary); user settings live in
   `~/Library/Application Support/Cursor/User/` and brew never touches them.
   ("`Using cursor` / skip" is decided by brew's own Caskroom receipt, *not*
   by whether `/Applications/Cursor.app` exists — a manually-dmg-installed app
   with no receipt gets *adopted*, which is why `anki`/`aerospace`/`codeisland`
   threw `bundle short version … mismatch` and were left alone.)

2. **The overlay merge is correct and non-destructive** — *when the base has
   content*. [`.chezmoitemplates/editor/modify.sh`](../.chezmoitemplates/editor/modify.sh)
   is a `modify_` script: chezmoi pipes the live file to stdin, the script runs
   `jq '. * $overlay'`, stdout becomes the new file. `. * $overlay` is a deep
   merge that enforces **only** the overlay keys and preserves everything else:

   ```
   # themed base → theme PRESERVED (this is the normal, safe case)
   echo '{"workbench.colorTheme":"One Dark Pro","editor.fontSize":99}' | jq '. * $overlay'
   → { "workbench.colorTheme": "One Dark Pro", "editor.fontSize": 12, ...overlay... }

   # EMPTY base → collapses to overlay-only (THE TRAP)
   echo '{}' | jq '. * $overlay'
   → { ...overlay keys only... }
   ```

The trap: when the live `settings.json` is **empty or missing**, the script's
`base=$(cat); [ -z "$base" ] && base='{}'` turns it into `{}`, and `{} * $overlay`
= overlay-only. chezmoi then writes that as the managed file. There was never
any theme key in the base to preserve, so the user's theme (which had been set
via Cursor's UI *after* some earlier apply, or on a fresh profile that hadn't
persisted yet) is silently dropped.

Why only Cursor and not VSCode/Antigravity in the 2026-07 incident: at
apply time Cursor's `User/settings.json` happened to be empty/absent (fresh
profile state), while the other two had long-lived 9 KB files. Same overlay,
different base → different outcome. **Nothing is wrong with the overlay; the
failure is entirely a function of the base file being empty at apply time.**

## Recovery

**No file backup exists** in the general case — check these in order, stop at
the first hit:

1. **Settings Sync** (best, full restore): `~/Library/Application Support/Cursor/User/sync/`
   — if present, sign in and pull. In the 2026-07 incident it was absent.
2. **A sibling editor still has your config.** VSCode/Antigravity share the
   same theme prefs most users pick. Read the theme keys straight out of the
   intact file:
   ```sh
   grep -nE 'colorTheme|iconTheme' \
     ~/Library/Application\ Support/Code/User/settings.json
   ```
   In the incident both siblings showed `Dark Modern` + `material-icon-theme`,
   which matched what Cursor's own theme picker still had highlighted.
3. **A still-running old editor window** holds the original in memory — BUT
   the moment you touch any setting via its UI (even clicking "Edit in
   settings.json" on a hint), the editor flushes its in-memory settings to
   disk, overwriting the last recoverable state. Read the values via the
   Command Palette (`Preferences: Color Theme` / `File Icon Theme` show the
   active one highlighted) **before** editing anything.
4. **Time Machine / APFS snapshots**: `tmutil listlocalsnapshots /`. OS-update
   snapshots don't contain user Library; only real TM backups help.
5. `globalStorage/storage.json` `theme` key is **not** reliable — it's rewritten
   to the *current* (post-wipe) value on the next launch (`vs-dark`).

Then write the two keys back into the live file (extensions stay installed, so
re-selecting is instant), e.g.:

```json
{
  "...existing overlay keys...": "...",
  "workbench.colorTheme": "Default Dark Modern",
  "workbench.iconTheme": "material-icon-theme"
}
```

The overlay will **preserve** these on every future apply (verified: themed
base → theme kept). No repo change needed once the base is non-empty.

`keybindings.json` is a `create_` seed (written once, never re-touched) — if
you had custom bindings before and no backup, they're gone; the current file
is the repo template.

## Prevention

For the user: **set the editor theme once so `settings.json` is non-empty
before/after the first apply.** A non-empty base is immune — the overlay only
ever *adds* its 6 keys and leaves the rest verbatim.

Possible hardening (not implemented — only if this recurs): in
`.chezmoitemplates/editor/modify.sh`, treat an empty/absent base as
"pass through nothing to manage yet" instead of seeding overlay-only —
i.e. `[ -z "$base" ] && { printf ''; exit 0; }` so chezmoi writes an
*empty* managed file (or, better, skip) rather than a lossy overlay-only
one. Trade-off: the overlay's font/format keys then won't apply until the
user has opened the editor once. Decide deliberately before changing — the
current behavior is arguably correct for a truly fresh box (you *want* the
fonts), it only bites when a themed profile transiently reads as empty.

## Related

- [`.chezmoitemplates/editor/modify.sh`](../.chezmoitemplates/editor/modify.sh) — the shared overlay script (6 wrappers: VSCode/Cursor/Antigravity × macOS/Linux)
- [`.chezmoitemplates/editor/overlay.json`](../.chezmoitemplates/editor/overlay.json) — the 6 keys it enforces
- [`pitfalls/modify-script-jq-bootstrap-cycle.md`](modify-script-jq-bootstrap-cycle.md) — sibling: the *same* script's other failure mode (missing `jq`/`python3` on cold-start → pass-through guard)
- [`docs/tools/chezmoi-prefixes.md`](../docs/tools/chezmoi-prefixes.md) — `modify_` vs `create_` semantics; why `settings.json` is `modify_` (overlay) and `keybindings.json` is `create_` (seed-once)
