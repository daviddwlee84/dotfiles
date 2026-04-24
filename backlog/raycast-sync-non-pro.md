# Raycast config sync for non-Pro users (paused — export format blocks us)

**TODO tag**: `P?/XL` — needs reverse-engineering or a Raycast-side opt-in before it's worth resurrecting.
**Sibling surface**: [`pitfalls/raycast-library-files-not-portable-across-machines.md`](../pitfalls/raycast-library-files-not-portable-across-machines.md) — kept live; stands on its own as a trap-warning regardless of whether this sync ships.

## Goal

Non-Pro Raycast users have no official cross-machine config sync (Raycast Pro offers Cloud Sync; no equivalent for free tier). Build something that round-trips hotkeys / quicklinks / snippets / aliases / extensions list across machines, git-tracked and redacted.

## Why this is paused

Raycast's bulk export (`Settings → Advanced → Export` → `.rayconfig` file) is **AES-encrypted with a key derivation that does not match any public scheme**, even when the user supplies the password.

Verified empirically against a real 837 KB export on Raycast 1.104.12 using pw `12345678`:

| Scheme family | Tried | Result |
|---|---|---|
| `openssl enc -d -aes-256-cbc -nosalt -k 12345678` (+ `-md md5/sha1/sha256`) | Yes | Garbage output; no gzip magic |
| `openssl enc -pbkdf2` (iters 1/1000/5000/10000/16384/100000, SHA1/256/512) | Yes (via pycryptodome) | No plausible decodes |
| scrypt (N=1024, 16384; r=8; p=1) with salts `""`, zeros, first-8-of-file, `"com.raycast.macos"` | Yes | No plausible decodes |
| Direct hash as key (MD5/SHA1/SHA256/SHA512 of password, padded/truncated to 32 bytes) with IV = first 16 bytes OR zero IV OR hash-derived IV | Yes | No plausible decodes |
| `EVP_BytesToKey` (OpenSSL legacy) with MD5/SHA1/SHA256, no salt and file-offset salt | Yes | No plausible decodes |
| AES-128 vs AES-256, CBC / ECB / CTR | Yes for all of the above | No plausible decodes |

"No plausible decodes" = **0** outputs where first 2 bytes are gzip magic `1f8b` OR first 200 bytes pass a printable-ASCII-ratio check after starting with `{` or `[`.

File structure observed:

```
offset 0..15    random-looking (likely IV, since it changes every export)
offset 16..N    ciphertext (N always a multiple of 16 = AES block size)
no 'Salted__' magic; no gzip magic anywhere; no OpenSSL header
```

The null hypothesis — **Raycast mixes keychain-bound or install-bound material into the KDF** — best matches the data. The user's password alone is insufficient even if the KDF were public, which makes a `--password` CLI flag pure theatre.

**Additional UX blocker**: Raycast forces the Export Password field to be non-empty. We initially thought the user could clear it (per some stale community writeups) — they cannot. The field in `Extensions → Raycast → Export Settings & Data → Export Password` pre-fills with `12345678` and does not accept empty.

## What was built (for revival)

Preserved verbatim under [`./raycast-sync/`](raycast-sync/). The active-location copies were removed from the repo so the feature doesn't appear half-wired.

| Original path | Preserved as | Status | Notes |
|---|---|---|---|
| `scripts/raycast_sync.py` | [`./raycast-sync/raycast_sync.py`](raycast-sync/raycast_sync.py) | **Never git-tracked** (only in working tree during the session); reconstructed here from final-session state. | Standalone PEP-723 CLI: `export` / `redact` / `import` / `diff` / `inspect`. Handles gzip↔JSON, key-name redaction (`password`/`token`/`apiKey`/…), `$HOME` path normalization, extensions-manifest extraction via a schema-tolerant walker, `secrets.env.example` emitter. Polls `~/Downloads/*.rayconfig` with per-file mtime baseline so it auto-detects `Raycast <timestamp>.rayconfig`. Sniffs gzip magic; dies with a clear message on encrypted input. |
| `.chezmoiscripts/global/run_onchange_after_32_raycast_config.sh.tmpl` | [`./raycast-sync/run_onchange_after_32_raycast_config.sh.tmpl`](raycast-sync/run_onchange_after_32_raycast_config.sh.tmpl) | Was committed at `5e25f33`; recoverable also via `git show 5e25f33:.chezmoiscripts/global/run_onchange_after_32_raycast_config.sh.tmpl`. | Apply-time auto-import, gated by `syncRaycast` prompt and OS=darwin. SHA256-hashes `raycast/{raycast,extensions}.json` so chezmoi only re-fires on source change. |
| `docs/tools/raycast-sync.md` | [`./raycast-sync/docs-tools-raycast-sync.md`](raycast-sync/docs-tools-raycast-sync.md) | **Never git-tracked**; reconstructed here. | Full user-facing workflow doc (TL;DR, what-syncs/doesn't table, redaction pipeline, AppleScript `--auto-gui` notes, troubleshooting). |
| `raycast/` (source-of-truth dir) | Never populated because export never succeeded. `.chezmoiignore.tmpl` entry `raycast/**` kept it from deploying as `~/raycast/`. | N/A — the entry itself is reverted |
| `syncRaycast` prompt in `.chezmoi.toml.tmpl` + `Dockerfile` + `scripts/init/dotfiles_init.py` (three-file cross-surface per the CLAUDE.md invariant) | Opt-in boolean, darwin-only. | Reverted in all three files |
| `raycast` added to `DEFAULT_PATHS` in `scripts/redact_secrets.py` + new `REDACTABLE_SUFFIXES = {".md", ".json"}` + pre-commit regex `^raycast/.*\.json$` | Extended the agent-artifact redaction pipeline to cover JSON alongside Markdown. | Reverted |
| `justfile` recipes `raycast-{export,redact,import,diff,sync}` | User-facing entrypoints. | Reverted |
| `CLAUDE.md` redaction table row + "update THREE places when adding a surface" rule | Docs for the three-file wiring pattern. | Reverted (restored to original 4-row Markdown-only table) |
| `README.md` Config Files entry | User-facing. | Reverted |
| `pitfalls/raycast-library-files-not-portable-across-machines.md` | Explains why copying `~/Library/Application Support/com.raycast.macos/` doesn't work (per-machine keychain encryption on `raycast-enc.sqlite`). | **KEPT** — valid standalone warning |

## What's factually confirmed (ground truth, survives the pause)

1. **`~/Library/Application Support/com.raycast.macos/raycast-enc.sqlite` is per-machine keychain-encrypted.** Raw-file sync across machines results in empty hotkeys / quicklinks / snippets on the target machine. Reference: [Raycast security doc](https://developers.raycast.com/information/security).

2. **macOS Sonoma+ breaks symlinked `~/Library/Application Support/*` preferences.** The old "symlink into iCloud / Dropbox" trick from the 2020-era writeups no longer works.

3. **`com.raycast.macos.plist` contains machine-bound state** (window positions, account link). Not safe to sync even if you got past (1) + (2).

4. **Extension API keys / OAuth tokens** are stored in macOS Keychain separately from the main encrypted DB. Even if we could decrypt `.rayconfig`, these wouldn't travel — every Raycast extension that authenticates to an external service would need its secret re-entered on the target machine.

5. **Three separate export commands exist** in Raycast's built-in extensions (seen in Settings → Extensions → filter `export`):
   - `Quicklinks → Export Quicklinks`
   - `Raycast → Export Settings & Data` (the encrypted bulk one)
   - `Snippets → Export Snippets`

   **We did not investigate whether the two per-category exports are encrypted.** This is the cheapest next experiment when resuming — if either of those produces plain JSON/plist, the sync strategy pivots to per-category exports and skips the encrypted bulk entirely.

## Revival paths, easiest first

### Option A — per-category exports (cheapest spike)

1. Run `Export Quicklinks` and `Export Snippets` in Raycast. Inspect bytes.
2. If either is plain text / JSON / plist: rewrite `raycast_sync.py` to drive those two commands (plus any analogous `Export Aliases`, `Export Hotkeys`, `Export Floating Notes` if they exist) via `raycast://` deep links instead of the bulk export. Redaction + extensions-manifest logic from commit `5e25f33` still applies.
3. Known compromise: hotkeys/settings/aliases may have no per-category export. They'd become "re-enter per machine", documented alongside the existing keychain-bound secrets caveat.
4. Effort: **M** if the per-category files are plain; **XL** if they're also encrypted and Option A collapses into Option B.

### Option B — write a Raycast extension that dumps via the Storage API

Raycast's extension SDK gives extensions access to `LocalStorage` and a few adjacent read APIs. A custom extension installed locally (not published) could read the user's config and write plain JSON to disk. This sidesteps the export-file encryption entirely.

- Effort: **L** (new TypeScript extension project, test locally, document install).
- Portability: extensions run inside Raycast's sandbox, so they only see what the SDK exposes. If the SDK can't read hotkeys / aliases / settings, this doesn't help for those.
- Reference: <https://developers.raycast.com/api-reference/storage>, <https://developers.raycast.com/api-reference/preferences>.

### Option C — reverse-engineer Raycast.app's encryption

- Effort: **XL**, ethically grey (Raycast isn't open-source), and likely to break on every Raycast update.
- Don't pursue unless Raycast adds first-party tamper-signed docs of the format.

### Option D — wait for Raycast to expose an unencrypted export flag

- Zero effort on our side; infinite latency. File a feature request against [raycast/extensions](https://github.com/raycast/extensions) asking for a `--plain` export option or an extension-side dumper.

## Attempted scheme list (so future-me doesn't redo it)

Brute-force script (stored at `/tmp/try_decrypt2.py` during the session; not committed) iterated through:

```
passwords:  [b"12345678", b"raycast", b"", b"Raycast", b"RAYCAST"]
PBKDF2:     iters = 1, 1000, 5000, 10000, 16384, 100000
            salt  = "", 0x00*8, 0x00*16, file[:8], file[:16],
                    "com.raycast.macos", "raycast", "salt"
scrypt:     N=1024 or 16384; r=8, p=1; salts ""/0x00*8/file[:8]
direct:     md5/sha1/sha256/sha512 of password, 3× repeated & truncated to 32;
            IVs = file[:16], hash[:16], zeros, key[:16]
EVP:        EVP_BytesToKey with md5/sha1/sha256; salts ""/file[:8]
modes:      AES-CBC (first-16 as IV & rest as ct; whole-file as ct with zero IV),
            AES-ECB, AES-CTR (first-8 as nonce)
```

Zero hits against a plausibility filter requiring gzip magic OR `{`/`[` start plus ≥180/200 printable bytes in the first 200-byte window.

## Lessons that should graduate to AGENTS.md if this pattern recurs

None yet. If a second closed-source macOS app turns out to have the same "forced non-empty password + keychain-bound KDF" pattern and we keep bumping into it, promote this into a Hard invariant warning agents not to invest brute-force time on cold targets.

## If you resume this

1. Start with **Option A** (per-category exports: inspect `Export Quicklinks` / `Export Snippets`) — ~30 minutes to find out if it's viable.
2. Recover the script: `cp backlog/raycast-sync/raycast_sync.py scripts/raycast_sync.py && chmod +x scripts/raycast_sync.py`. The redactor, manifest walker, AppleScript `--auto-gui` fallback, and instruction-printing polling code are all reusable as-is; only `resolve_rayconfig_for_export` and `rayconfig_to_json` need swapping for per-category handling.
3. Recover the apply-time script: `cp backlog/raycast-sync/run_onchange_after_32_raycast_config.sh.tmpl .chezmoiscripts/global/` (or `git show 5e25f33:.chezmoiscripts/global/run_onchange_after_32_raycast_config.sh.tmpl > .chezmoiscripts/global/run_onchange_after_32_raycast_config.sh.tmpl`).
4. Recover the user-facing docs: `cp backlog/raycast-sync/docs-tools-raycast-sync.md docs/tools/raycast-sync.md`.
5. Re-wire the 9 files. The `syncRaycast` chezmoi prompt machinery (three-file cross-surface with `doctor` parity check) is the most finicky part; `git show 5e25f33 -- .chezmoi.toml.tmpl Dockerfile scripts/init/dotfiles_init.py justfile CLAUDE.md README.md .chezmoiignore.tmpl .pre-commit-config.yaml scripts/redact_secrets.py` replays each one — pick out just the raycast hunks with `git show ... | grep -A4 -B1 -i raycast`.
6. Keep the redaction pipeline extension (`DEFAULT_PATHS += "raycast"`, `REDACTABLE_SUFFIXES`) — it's generically useful for any future JSON-config surface and isn't Raycast-specific.
