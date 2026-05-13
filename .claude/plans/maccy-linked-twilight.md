# Cross-platform clipboard-history helper — hybrid (Maccy on mac + CopyQ on Linux)

## Context

A previous helper at `dot_config/shell/56_raycast_clipboard.sh.tmpl` exposed `rcb`/`rcbl`/`rcbe` to query Raycast's clipboard history. Raycast 1.7+ moved to SQLCipher with a key derivation that cannot be recovered from the keychain without binary reverse-engineering. The helper was deleted 2026-05; the post-mortem lives at [`pitfalls/raycast-clipboard-sqlcipher-key-not-recoverable.md`](../../pitfalls/raycast-clipboard-sqlcipher-key-not-recoverable.md).

The user wants a *queryable* clipboard-history workflow with a unified shell API (`cb` / `cbl` / `cbe`) that works the same on macOS and Ubuntu desktop, so muscle memory carries across hosts. `ubuntu_server` (no display server) should gracefully no-op with a hint.

## Decision: hybrid backend, unified API

Different tool per OS, single shell helper dispatches by backend detection:

| OS | Tool | Install | Has CLI? |
|---|---|---|---|
| macOS | **Maccy** | `brew install --cask maccy` (signed, healthy on brew, `auto_updates`, macOS 14+) | No — query plaintext SQLite |
| Ubuntu desktop | **CopyQ** | `sudo apt install copyq` (stock 22.04 / 24.04 repos) | Yes — `copyq read/select/eval` |
| Ubuntu server | none | skip | n/a |

**Why hybrid, not CopyQ-everywhere**: the CopyQ Homebrew cask is deprecated (disabled 2026-09-01) — not the upstream project, only the cask, because `CopyQ.app` isn't signed for macOS Gatekeeper (upstream issue [hluk/CopyQ#3498](https://github.com/hluk/CopyQ/issues/3498)). CopyQ on Linux is unaffected and remains the canonical pick. Maccy is the most maintained signed-and-on-brew clipboard manager for macOS; trade-off is no shipped CLI, so the helper queries Maccy's plaintext SQLite directly.

**Coexistence with Raycast** (per user choice): both Raycast and Maccy will record every Cmd+C on macOS in parallel. No functional conflict — storage duplication only. Manual disable of Raycast's clipboard module is optional and not part of this change.

## File changes

### 1. macOS install — `dot_config/homebrew/Brewfile.darwin.tmpl`

Add one line under "Casks - System Utilities" (existing section, no Jinja2 gate — Maccy is small, useful on every mac, signed, auto-updating):

```
cask "maccy"                       # Plaintext-SQLite clipboard history (scriptable)
```

No prompt added to `.chezmoi.toml.tmpl`; if a toggle is wanted later, follow the CLAUDE.md cross-file rule (`PROMPTS` tuple + `BUNDLES` + Dockerfile ARG + `scripts/init/dotfiles_init.py`).

### 2. Linux install — `dot_ansible/roles/gui_apps_linux/tasks/main.yml`

Add an apt-install task following the existing apt-source pattern (Cursor/VSCode style, but no third-party apt repo needed — stock Ubuntu has it):

```yaml
- name: Install CopyQ via apt (stock repos)
  become: yes
  ansible.builtin.apt:
    name: copyq
    state: present
  when: profile == "ubuntu_desktop"
  tags: [sudo]
```

CopyQ ships `/etc/xdg/autostart/com.github.hluk.copyq.desktop`, so the tray daemon starts on next X session login — no extra systemd-user unit needed.

### 3. Shell helper — `dot_config/shell/56_clipboard_history.sh`

New file (plain `.sh`, **not** `.sh.tmpl` — uses runtime backend detection, no chezmoi vars). POSIX subset, both shells source. Slot 56 reused (the deleted Raycast helper occupied it).

**Public API:**

| Function | Purpose |
|---|---|
| `cbl [N]` | List recent N items (default 20), tab-separated `<index>\t<first-line-preview>` |
| `cb` | fzf picker → copy selected item to system clipboard (moves to top of stack) |
| `cbe` | fzf picker → edit selection in `$EDITOR` → write back as a new clip |

**Backend dispatch** (`_clip_backend` internal helper):

- Manual override: `CLIP_BACKEND=maccy` or `CLIP_BACKEND=copyq` env var skips autodetect.
- macOS autodetect order: Maccy (probe SQLite paths) → CopyQ (if installed manually).
- Linux autodetect order: CopyQ (`command -v copyq` + `copyq size` to verify daemon is up).
- No backend found → one-line install hint to stderr, returns non-zero. The hint is the same install command from §1 / §2.

**Maccy SQLite path probe** (handles both sandbox modes):

1. `$HOME/Library/Application Support/Maccy/Storage.sqlite` (brew cask, non-sandboxed)
2. `$HOME/Library/Containers/org.p0deje.Maccy/Data/Library/Application Support/Maccy/Storage.sqlite` (Mac App Store, sandboxed)

**CopyQ backend internals:**

- `cbl` → `copyq eval` with a small JS loop printing `i\tread(i).split("\n")[0]\n` for `i < min(size(), N)`.
- `cb` → `copyq select <idx>` (atomic: moves to top of stack + writes to system clipboard).
- `cbe` → `copyq read <idx>` → tempfile → `$EDITOR` → `copyq copy - < tmpfile`.

**Maccy backend internals** (Core Data tables — see Verification §3 below for the required schema-confirmation step):

- `cbl` → `sqlite3` JOIN of `ZHISTORYITEM` + `ZHISTORYITEMCONTENT`, filter on `ZTYPE = 'public.utf8-plain-text'`, ORDER BY `ZFIRSTCOPIEDAT DESC`, LIMIT N.
- `cb` → SELECT `ZVALUE` by Z_PK → pipe to `pbcopy`. Maccy will re-record the clip at top of stack (acceptable side effect — adds a duplicate at index 0, not a bug).
- `cbe` → same as `cb` but via tempfile + `$EDITOR`.

Tier: **shared** per CLAUDE.md "three-tier file placement" — POSIX only, no ZLE widgets / `bindkey` / `setopt` / `compdef`. Both shells source it.

### 4. Documentation

- **`docs/tools/clipboard.md`** — append a new section "Clipboard History" after the existing OSC-52 section. Cover: backend choice (Maccy on mac, CopyQ on Linux), why hybrid (CopyQ cask deprecation), the three commands, Raycast coexistence note, DB paths per backend.
- **`docs/shells/aliases.md`** — three rows per existing schema (`Command | Type | Source File | Description`):
  - `cb` / function / `dot_config/shell/56_clipboard_history.sh` / fzf-pick clipboard history → copy
  - `cbl` / function / `dot_config/shell/56_clipboard_history.sh` / list recent N clipboard items
  - `cbe` / function / `dot_config/shell/56_clipboard_history.sh` / fzf-pick → edit in $EDITOR → re-copy
- **`docs/playbooks/linux-gui-apps.md`** — add one row to the "Ansible-managed" inventory table at `:74-83`: `CopyQ | apt (stock) | ✅ via apt upgrade | same role | /usr/bin/copyq`.

## Critical files to modify

| Path | Change |
|---|---|
| `dot_config/homebrew/Brewfile.darwin.tmpl` | +1 line `cask "maccy"` under System Utilities |
| `dot_ansible/roles/gui_apps_linux/tasks/main.yml` | +5 line apt task, gated `profile == ubuntu_desktop`, tagged `sudo` |
| `dot_config/shell/56_clipboard_history.sh` | **new** ~80-line POSIX helper with backend dispatch |
| `docs/tools/clipboard.md` | +1 section ("Clipboard History") |
| `docs/shells/aliases.md` | +3 rows |
| `docs/playbooks/linux-gui-apps.md` | +1 row in Ansible-managed inventory |

## Verification

1. **Install paths**:
   - macOS: `chezmoi apply` → `brew list --cask | grep maccy` shows installed. Launch Maccy once from Spotlight (one-time login-item registration; no Accessibility prompt — Maccy uses `NSPasteboard.changeCount` polling).
   - Linux desktop: ansible re-apply → `dpkg -s copyq` shows installed; `copyq --version` prints; `ls /etc/xdg/autostart/com.github.hluk.copyq.desktop` exists.
   - Linux server: re-apply → no install attempted; running `cb` prints the install hint.

2. **Helper smoke test** (both platforms):
   - Open new shell → `type cb cbl cbe` shows three functions.
   - macOS: copy "test123" via Cmd+C → `cbl` shows it at index 0; `cb` → fzf opens → ↩ → `pbpaste` returns "test123"; `cbe` → fzf → opens `$EDITOR` → save edited text → `pbpaste` shows the edit.
   - Linux: same flow using `xclip -selection clipboard -o` (or `wl-paste` on Wayland). Also `copyq size` should match what `cbl | wc -l` reports.

3. **Maccy schema verification — REQUIRED before merging the helper**:
   - On the dev mac, after Maccy is installed and has recorded a few items, run:

     ```bash
     sqlite3 "$HOME/Library/Application Support/Maccy/Storage.sqlite" ".schema"
     ```

   - Confirm the table/column names assumed in §3 (`ZHISTORYITEM`, `ZHISTORYITEMCONTENT`, `ZFIRSTCOPIEDAT`, `ZVALUE`, `ZTYPE`). Core Data adds a `Z_PK` primary key automatically; the join column may be `ZITEM` or `ZHISTORYITEM` depending on Maccy's model.
   - If the actual schema diverges, update the SQL in `cbl` / `cb` / `cbe` before merging. **Do not commit the helper with unverified SQL.**

4. **No regression with Raycast** (macOS): copy via Cmd+C, confirm both Raycast's clipboard menu (`⌥⌘C`) and Maccy's menu (`⇧⌘C` default) show the item. Pasting from either works independently.

5. **OSC-52 `x` wrapper untouched**: confirm `dot_dotfiles/bin/executable_x` (`x copy` / `x paste`, per [`docs/tools/clipboard.md:106-127`](../../docs/tools/clipboard.md)) still works. The new helper is additive — does not modify the OSC-52 layer.

## Reused utilities / patterns

- **fzf preview** — match the existing tab-delimited `--with-nth=2.. --delimiter='\t'` pattern used elsewhere in `dot_config/shell/` (will scan slot 30s/40s during implementation for the exact idiom).
- **Tool-presence guard** — `command -v <bin> >/dev/null 2>&1 && <bin> <ping-cmd> >/dev/null 2>&1` — same shape as the workmux guard pattern from CLAUDE.md ("Workmux status icon integration").
- **Brewfile cask gating** — Jinja2 `{{ if .someVar -}}` blocks per existing `installAiDesktopApps` / `installLlmTools` pattern. Maccy uses no gate (universal).
- **Ansible apt+sudo tag** — same `tags: [sudo]` + `become: yes` + `profile == "ubuntu_desktop"` shape as other gui_apps_linux tasks.
- A `tv clipboard` television channel. (Possible follow-up if the fzf experience wants sharing with other pickers.)

## Out of scope

- Disabling Raycast's clipboard module — explicit user choice was "coexist".
- True in-place edit on Maccy (`cbe` adds a new clip via pbcopy rather than mutating the original Z_PK row). Direct DB writes are not safe — would race with Maccy's in-memory state and risk corruption on app restart.
- Encryption of the clipboard DB. Threat-model caveats from the OpenCode comparison apply: secrets you `cat .env` to the terminal land in the DB plaintext. Mitigations: 1Password / Bitwarden use the macOS concealed-pasteboard type (`org.nspasteboard.ConcealedType`) and are never recorded by either Maccy or CopyQ; toggle Maccy's "Ignore Events" or CopyQ's "Disable Clipboard Storing" before pasting secrets.
- The 2026-09-01 CopyQ cask disable date — not load-bearing under the hybrid design (mac doesn't use the cask).

## Follow-up

- After the helper merges, if Maccy's actual Core Data schema differs from what's assumed in §3, append a one-paragraph "Schema reference" note to `docs/tools/clipboard.md` so the SQL stays maintainable.
- Consider opening `pitfalls/maccy-sandbox-vs-cask-path.md` if the SQLite-path probe order catches a subtle MAS-vs-cask divergence in the wild (e.g., a user with the App Store version sees a different path than the brew-cask version).
