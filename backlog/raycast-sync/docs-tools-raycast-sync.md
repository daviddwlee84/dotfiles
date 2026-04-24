# Raycast config sync (non-Pro cross-machine)

> **PAUSED — see `../raycast-sync-non-pro.md`** for why. This doc is
> preserved as the user-facing spec for when the project resumes.

> Raycast Pro (paid) has Cloud Sync. This is the non-Pro equivalent: a
> git-tracked, redacted export that round-trips via the built-in
> `.rayconfig` Export/Import feature.

## TL;DR

```sh
# First machine (source of truth):
just raycast-sync          # export + redact + gitleaks + stage raycast/
git commit && git push

# New machine:
chezmoi apply              # installs Raycast via Brewfile
# Then either:
just raycast-import        # re-import raycast/raycast.json
# or set syncRaycast=true in chezmoi prompts → happens automatically.
```

> **Critical one-time setup — clear the Export Password**
>
> Raycast stores a default Export Password (`12345678`) that encrypts every
> `.rayconfig` export. The password field is **not** in the Advanced/Export
> dialog — it's in a different tab. Clear it once:
>
> 1. Raycast Settings (`Cmd+,`) → **Extensions** tab
> 2. Filter box: type `export`
> 3. Select **Raycast → Export Settings & Data**
> 4. Right pane: **Export Password** → click the eye icon → select all → delete → empty
>
> **NOTE (2026-04-24)**: Empirically, current Raycast (1.104) seems to
> forbid an empty password field. If that's still the case when you resume
> this work, the bulk-export path is fully blocked and you should pivot to
> the per-category exports path described in `../raycast-sync-non-pro.md`.

## What this syncs

- Hotkeys, quicklinks, snippets, aliases, floating notes
- User settings (appearance, search behavior, etc.)
- Installed **store** extensions list (for auto-reinstall via
  `raycast://extensions/<author>/<name>` deep links)

## What this does NOT sync (and can't)

| Surface | Why not | Workaround |
|---|---|---|
| Extension API keys / OAuth tokens | Raycast stores them in macOS Keychain, per-machine | `raycast/secrets.env.example` lists which ones you need to re-enter |
| `raycast-enc.sqlite` (indexes, cache, local activity) | Encrypted with a per-machine key stored in macOS Keychain — bytes are useless on machine B | N/A — it rebuilds itself |
| `com.raycast.macos.plist` | Contains machine-bound state (window positions, account link, etc.) | N/A |
| Locally-developed extensions not in the store | No install URL | Keep them in their own repo and symlink/clone separately |

## How it works

- **Source format**: Raycast's Export (Settings → Advanced → Export) produces
  a `.rayconfig` file — gzipped JSON (**only** when the Export Password is
  empty; see blocker above). We decompress it to `raycast/raycast.json`,
  pretty-print, sort keys, normalize `$HOME`, and redact by key name
  (`password`, `token`, `apiKey`, `secret`, ...).
- **Redaction**: `scripts/raycast_sync.py` applies a key-name redactor, then
  runs `scripts/redact_secrets.py` over the output for a gitleaks sweep (URL
  tokens, AWS keys, PEM blocks, etc. that the key-name heuristic misses).
- **Extensions manifest**: The tool walks the JSON to find the extension
  list and emits `raycast/extensions.json` with `{id, name, author, version,
  source}` per entry. Used on import to reinstall via
  `raycast://extensions/...` deep links before feeding the .rayconfig back.
- **Secrets template**: For each store extension that declares a `password`
  preference, a commented placeholder is emitted in
  `raycast/secrets.env.example` — a checklist, not a loader (Raycast reads
  secrets from its own UI, not env vars).

## Files

| Path | Purpose |
|---|---|
| `scripts/raycast_sync.py` | The tool. Subcommands: `export` / `redact` / `import` / `diff` / `inspect`. |
| `raycast/raycast.json` | Redacted Raycast export (source of truth). |
| `raycast/extensions.json` | Store extensions manifest for auto-reinstall. |
| `raycast/secrets.env.example` | Checklist of API keys to re-enter per machine. |
| `.chezmoiscripts/global/run_onchange_after_32_raycast_config.sh.tmpl` | Apply-time import, gated by `syncRaycast` prompt. |
| `raycast/` in `.chezmoiignore.tmpl` | Keeps the source dir from deploying as `~/raycast/`. |

## Commands (justfile)

```
just raycast-export    # Trigger Raycast Export dialog, ingest the file, redact
just raycast-redact    # Re-run redaction only (idempotent)
just raycast-diff      # Fresh export vs committed — drift check
just raycast-import    # Reinstall extensions, re-gzip, open Import dialog
just raycast-sync      # export → redact → git add → check-secrets
```

## Apply-time behavior

`.chezmoiscripts/global/run_onchange_after_32_raycast_config.sh.tmpl`
re-fires whenever the SHA256 of `raycast/raycast.json` or
`raycast/extensions.json` changes. It:

1. Skips entirely if OS != darwin or `syncRaycast` is false.
2. Skips if Raycast.app is missing (run after Brewfile installs it).
3. Invokes `scripts/raycast_sync.py import --dir raycast`, which triggers
   store-extension reinstalls via `raycast://` deep links, prepares a
   `.rayconfig` bundle in `~/Downloads/`, and prompts you to complete the
   Import dialog in the Raycast GUI.

## AppleScript GUI automation (opt-in)

The tool supports `--auto-gui` on `export`/`import` which invokes
`osascript` to click the Export/Import buttons. This needs **Accessibility**
permission granted to your terminal (System Settings → Privacy & Security →
Accessibility). Without it, `osascript` fails with `-1719` and the tool
falls back to printing instructions + polling for the export file.

The GUI path is deliberately off by default; polling is reliable, needs zero
setup, and survives Raycast UI revisions.

## Redaction details

- **Key-name heuristic**: values under keys matching
  `/(password|secret|token|apikey|api_key|access_key|access_token|refresh_token|client_secret|private_key|cookie|authorization|bearer|credential)/i`
  become `<REDACTED>`.
- **Path normalization**: `/Users/<username>/` → `$HOME/`.
- **Gitleaks sweep**: the repo's `scripts/redact_secrets.py` runs over the
  redacted JSON to catch anything the key-name pass missed.
- **Pre-commit hook**: `redact-agent-secrets` is wired to also pick up
  `^raycast/.*\.json$`, so a stray secret is caught before it hits the
  remote.

## Troubleshooting

- **"timed out waiting for a new *.rayconfig under ~/Downloads"**: Raycast
  Export wasn't triggered (or wasn't saved under `~/Downloads`) within 5
  min. Re-run `just raycast-export` and complete the dialog when prompted.
  The tool auto-detects any `*.rayconfig` file (e.g.
  `Raycast 2026-04-24 16.13.06.rayconfig`).
- **"is not a gzipped JSON export (first 2 bytes: b'(F')"**: the Export
  Password in `Extensions → Raycast → Export Settings & Data → Export
  Password` is non-empty (default `12345678`). The field lives in the
  Extensions tab, not in the Export dialog itself — the Export dialog just
  shows a tooltip pointing there. Clear it (reveal → select all → delete →
  save), export again, re-run. Raycast's encryption uses a non-public key
  derivation; we confirmed empirically that all standard OpenSSL / PBKDF2 /
  scrypt schemes fail to decode it even with `12345678`, so there is no
  `--password` escape hatch.

## Security notes

- The JSON **is** git-tracked. Read it once after the first export to
  sanity-check. Quicklinks with embedded URLs/usernames, snippet text, and
  raw aliases are all visible there — they're not secrets in the
  gitleaks sense but may be personal.
- The `--password` option on `.rayconfig` export is deliberately NOT used
  here. We already redact, and a password on the encrypted `.rayconfig`
  would just add a secret-sharing problem between your machines.
