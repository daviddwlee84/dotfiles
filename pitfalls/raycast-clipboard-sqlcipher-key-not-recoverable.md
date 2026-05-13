# Raycast Clipboard History DB unlock — keychain `database_key` does NOT decrypt `raycast-enc.sqlite`

**Symptoms** (grep this section):
- Want to read Raycast's clipboard history programmatically (export, fzf
  picker, backup) and notice `~/Library/Application Support/com.raycast.macos/`
  contains `raycast-enc.sqlite` + `raycast-activities-enc.sqlite` +
  `raycast-emoji.sqlite` (no plaintext `Clipboard.sqlite` like older
  Raycast versions had)
- `xxd raycast-enc.sqlite | head` shows random bytes — not the
  `SQLite format 3\0` magic. So it's encrypted.
- `strings /Applications/Raycast.app/Contents/MacOS/Raycast | grep cipher_`
  proves Raycast embeds **SQLCipher** (`PRAGMA cipher_compatibility`,
  `PRAGMA cipher_kdf_algorithm`, `using raw key and salt` etc).
- macOS Keychain has a matching-looking entry:
  ```
  security find-generic-password -s Raycast -a database_key -w
  → 64 hex chars (= 32 bytes, AES-256 sized)
  ```
- ❌ That key, with `PRAGMA key = "x'<hex>'"`, fails to decrypt with
  `Parse error: file is not a database (26)` on **every** combination of:
  - `cipher_compatibility = 4` / `3` / `2` / `1`
  - Raw ASCII key form (`PRAGMA key = '<hex>';`) — KDF-from-passphrase mode
  - `cipher_page_size = 1024` and other non-default sizes
  - Tried against all three `*-enc.sqlite` files
- `cipher_settings` after the (silently-failing) `PRAGMA key` reports the
  SQLCipher-4 defaults (kdf_iter=256000, page_size=4096, HMAC_SHA512,
  PBKDF2_HMAC_SHA512, plaintext_header_size=0) — i.e. nothing exotic at
  the SQLCipher layer.
- File header is 16 bytes of true entropy (no `cipher_plaintext_header_size`).
- Other Raycast keychain entries (`raycast-store_credentials`,
  `urlcache_key`, `Codex`, `Plaud Key`) are clearly for unrelated features.

**First seen**: 2026-05 on Apple Silicon Mac mini, Raycast 1.7x, macOS 15.
Older blog posts and the cleanup-tool ecosystem all reference a long-gone
plaintext `Clipboard.sqlite` schema (`ZCLIPBOARDHISTORYITEM` Core Data
table) — that file does NOT exist on current Raycast installs.

**Affects**: anyone trying to script over Raycast's clipboard history,
write an alfred-equivalent CLI, build a backup tool, migrate to another
clipboard manager, or feed clip history to an LLM context window.

**Status**: **unsolved without binary reverse-engineering.**

Strong evidence Raycast derives the actual SQLCipher master key from the
keychain `database_key` value plus *something else* (machine UUID, Secure
Enclave-bound key via `SecKeyCreateWithData`, account-bound iCloud key,
fixed app salt, …). Two clues point this way:
1. `database_key`'s keychain `cdat` is **newer** than `raycast-emoji.sqlite`'s
   filesystem `mtime`, so it cannot be the literal SQLCipher key (rotating
   the key would have re-encrypted the file and bumped its mtime).
2. The Raycast binary contains the string
   `"ImageProxy Key/Salt should be set on launch from AppDelegate"` —
   suggesting AppDelegate computes a Key+Salt pair at launch and feeds
   it to subsystems, rather than passing the raycast keychain blob directly.

**What does NOT work** (confirmed dead ends — don't redo):
- `sqlcipher` CLI with the keychain hex value, every PRAGMA combo above
- Treating the hex as base64 (wrong size: 32 → 24 bytes)
- Treating the hex string as 64 raw ASCII bytes (wrong size for raw mode)
- Running queries against `raycast-activities-enc.sqlite` or
  `raycast-emoji.sqlite` with the same key (also fail; not a per-file key
  problem — the master derivation is wrong)
- Searching GitHub for `raycast-enc.sqlite sqlcipher` — zero useful hits
  as of 2026-05; the ecosystem still references the deprecated plaintext
  schema only

**What MIGHT work** (untried, ~hours of effort):
- Frida/LLDB attach to running Raycast, hook
  `sqlcipher_codec_ctx_init_kdf_salt` or `sqlite3_key`, dump the actual
  key argument. Requires disabling SIP **or** using a debug build of
  Raycast (doesn't exist publicly). High-effort, fragile across Raycast
  updates.
- Statically RE the AppDelegate via Hopper / Ghidra / IDA looking for the
  call site that reads `database_key` from keychain and traces it to the
  `sqlite3_key()` call. Same fragility caveat.
- Watch for [Frida-trace](https://frida.re/) write-ups; if anyone solves
  it, they'll publish.

**Workarounds** (use one of these instead of fighting Raycast):
- **Maccy** (open source, plaintext SQLite at
  `~/Library/Containers/org.p0deje.Maccy/Data/Library/Application Support/Maccy/Storage.sqlite`
  — actually queryable). Free.
- **CopyClip / Pastebot / Paste** — paid alternatives, varying
  scriptability. Pastebot has AppleScript/Shortcuts hooks.
- **macOS built-in pbpaste** — only the most recent clip; no history.
- **clipboard-history Raycast extension** with manual export — Raycast
  extensions have read access to their own data via the public API; a
  custom extension could `export-as-json` to disk on a hotkey. Limited
  to whatever the extension API exposes (currently no full-history dump).

**Cross-references**:
- This pitfall was discovered after a half-built helper at
  `dot_config/shell/56_raycast_clipboard.sh.tmpl` (rcb / rcbl / rcbe) was
  written assuming the old plaintext schema. The helper was deleted on
  2026-05 once the SQLCipher reality became clear. If you're tempted to
  re-add it: read this file first.

**Reproduce** (to confirm Raycast hasn't changed the scheme since this
was written):
```bash
# 1. Confirm enc files exist
ls ~/Library/Application\ Support/com.raycast.macos/raycast-enc.sqlite

# 2. Confirm header has no SQLite magic
xxd ~/Library/Application\ Support/com.raycast.macos/raycast-enc.sqlite \
  | head -1
# expect: random bytes, not "SQLite format 3"

# 3. Confirm the keychain key still doesn't unlock
brew install sqlcipher    # if missing
KEY=$(security find-generic-password -s Raycast -a database_key -w)
cp ~/Library/Application\ Support/com.raycast.macos/raycast-enc.sqlite{,-wal,-shm} /tmp/
sqlcipher /tmp/raycast-enc.sqlite <<SQL
PRAGMA key = "x'$KEY'";
SELECT count(*) FROM sqlite_master;
SQL
# expect: "Parse error ...: file is not a database (26)"
# if it returns a row count → schema changed, update this pitfall and
# revisit the helper.
```
