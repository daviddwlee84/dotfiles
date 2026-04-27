# Optimize `.dotfiles_backup`: yes/no → backup modes

## Context

The `~/.dotfiles_backup/<TIMESTAMP>/` snapshot was implemented when this
repo was first being onboarded onto chezmoi: every existing dotfile risked
being overwritten on first apply, so a blanket pre-apply copy of a
hardcoded allowlist (`~/.zshrc`, `~/.zshenv`, `~/.gitconfig`,
`~/.tmux.conf`, `~/.config/{nvim,zsh,mise,alacritty,yazi,zellij}`) was
the safe default.

That assumption no longer holds. On a steady-state fleet host, almost
every file in that allowlist is **already** managed by chezmoi and
identical to the source. `chezmoi apply` would not modify any of them,
but `run_before_01_backup_dotfiles.sh.tmpl` blindly `cp -a`'s them all
anyway — once a day per host, into a fresh timestamped subdirectory.
Disk waste + zero usefulness once onboarding is past.

Optimization: replace the binary `backupDotfiles` boolean with a
**three-mode** prompt and teach the run-script to consult `chezmoi
status` so the common case (steady-state apply with no drift) produces
**no backup at all**, while a real diff that would be overwritten still
gets captured. Also add minimal read-only inspect helpers (`just
list-backups`, `just diff-backup`) so an emergency recovery path doesn't
require remembering the timestamp directory layout.

## Confirmed design (from clarification round)

| Decision | Choice |
|---|---|
| Mode names | `smart` / `full` / `off` |
| New default | `smart` |
| Legacy migration | Auto-derive from old `backupDotfiles` bool (`true→full`, `false→off`); no forced re-init |
| New helpers | `just list-backups` + `just diff-backup <TS>` (read-only; no `restore-backup` recipe) |

## Current implementation surface (verified)

| Surface | Path | Lines |
|---|---|---|
| Prompt definition | `.chezmoi.toml.tmpl` | 76 (`backupDotfiles = promptBoolOnce ... true`) |
| Prompt schema | `scripts/init/dotfiles_init.py` | 211–215 (`Prompt("backupDotfiles", "bool", ...)`) |
| Bundles | `scripts/init/dotfiles_init.py` | 245, 252, 260, 281 (4 of 5 bundles set it) |
| Backup script | `run_before_01_backup_dotfiles.sh.tmpl` | full file (65 lines) — `every, before` per `chezmoiscripts-layout.md:30` |
| Dockerfile ARG | `Dockerfile` | 24 (`ARG CHEZMOI_BACKUP_DOTFILES=false`), 139 (`--promptBool ...=${CHEZMOI_BACKUP_DOTFILES}`) |
| Layout doc | `docs/this_repo/chezmoiscripts-layout.md` | 30 |

No callers / consumers of `~/.dotfiles_backup` today — write-only artifact.
Not mentioned in `.chezmoiignore.tmpl`. Not in `README.md`.

## Three modes

| Mode | Behavior | When useful |
|---|---|---|
| `smart` (DEFAULT) | Run `chezmoi status`; back up only paths whose 2nd column is `M` (would be modified) or `D` (would be deleted). Steady-state clean host: **no backup dir created** thanks to existing empty-dir cleanup. | Steady-state fleet apply. The 99% case post-onboarding. |
| `full` | Current behavior — copy the hardcoded files+dirs allowlist if they exist on disk. | First-time onboarding of an existing system; paranoid mode. |
| `off` | Skip entirely. | Docker, CI, ephemeral envs. |

Why `chezmoi status` column 2 is the right signal: chezmoi's own help
defines column 2 as "the difference between the actual state and the
target state, and what effect running `chezmoi apply` will have". `M`/`D`
is exactly the set of files whose on-disk content would be lost. `A`
means the target file does not exist yet — nothing to back up. Space
means in sync — nothing to back up.

## Files to modify

### 1. `.chezmoi.toml.tmpl` (line 76)

```diff
-# 在 chezmoi apply 之前備份現有的 dotfiles
-backupDotfiles = {{ promptBoolOnce . "backupDotfiles" "Backup existing dotfiles before chezmoi overwrites them" true }}
+# 在 chezmoi apply 之前備份現有的 dotfiles。
+# smart = 只備份 chezmoi 將要覆蓋/刪除的檔案（用 `chezmoi status` 偵測）；
+# full  = 備份固定 allowlist（onboard 第一次最保險）；
+# off   = 完全跳過（CI / Docker / 一次性環境用）
+backupMode = {{ promptChoiceOnce . "backupMode" "Backup mode for existing dotfiles (smart|full|off)" (list "smart" "full" "off") "smart" | quote }}
```

### 2. `run_before_01_backup_dotfiles.sh.tmpl` (full rewrite)

```bash
#!/bin/bash
# Backup existing dotfiles before chezmoi overwrites them.
# Mode comes from .backupMode; legacy `.backupDotfiles` bool is auto-derived
# for hosts that haven't re-init'd since the prompt was renamed.
set -euo pipefail

{{- $mode := "smart" -}}
{{- if hasKey . "backupMode" -}}
{{-   $mode = .backupMode -}}
{{- else if hasKey . "backupDotfiles" -}}
{{-   $mode = (ternary "full" "off" .backupDotfiles) -}}
{{- end }}
MODE='{{ $mode }}'

[[ "$MODE" == "off" ]] && exit 0

BACKUP_BASE="$HOME/.dotfiles_backup"
TODAY=$(date +%Y%m%d)
# Daily dedup: skip if any backup from today already exists
if ls -d "${BACKUP_BASE}/${TODAY}_"* &>/dev/null; then exit 0; fi

BACKUP_DIR="${BACKUP_BASE}/$(date +%Y%m%d_%H%M%S)"
BACKED_UP=0

copy_one() {
  local src="$1"
  [[ -e "$src" ]] || return 0
  local rel="${src#$HOME/}"
  mkdir -p "${BACKUP_DIR}/$(dirname "$rel")"
  cp -a "$src" "${BACKUP_DIR}/${rel}"
  BACKED_UP=$((BACKED_UP + 1))
}

case "$MODE" in
  smart)
    # `chezmoi status` lines: "<col1><col2> <relpath-from-$HOME>"
    # col2 ∈ {M,D} ⇒ apply will overwrite/delete the on-disk file → back up
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      col2="${line:1:1}"
      relpath="${line:3}"
      case "$col2" in M|D) copy_one "$HOME/$relpath" ;; esac
    done < <(chezmoi status 2>/dev/null || true)
    ;;
  full)
    for f in "$HOME/.zshrc" "$HOME/.zshenv" "$HOME/.gitconfig" "$HOME/.tmux.conf"; do copy_one "$f"; done
    for d in "$HOME/.config/nvim" "$HOME/.config/zsh" "$HOME/.config/mise" \
             "$HOME/.config/alacritty" "$HOME/.config/yazi" "$HOME/.config/zellij"; do copy_one "$d"; done
    ;;
  *)
    echo "[BACKUP] Unknown mode '$MODE' (expected smart|full|off); skipping." >&2
    exit 0
    ;;
esac

if [[ $BACKED_UP -eq 0 ]]; then
  rmdir "$BACKUP_DIR" 2>/dev/null || true
else
  echo "[BACKUP/$MODE] Backed up $BACKED_UP item(s) to $BACKUP_DIR"
fi

exit 0
```

**Risk note**: invoking `chezmoi status` from inside a `run_before` script
means chezmoi recursively spawns chezmoi. `chezmoi status` is read-only
(no state mutation) and chezmoi 2.69 supports concurrent read invocations
in practice. First-apply verification step below confirms no deadlock.

### 3. `scripts/init/dotfiles_init.py`

Replace `Prompt("backupDotfiles", "bool", ...)` (lines 211–215) with:

```python
Prompt("backupMode", "choice", "Preferences",
       "Backup mode for existing dotfiles",
       "smart = only files chezmoi will overwrite (uses `chezmoi status`); full = hardcoded allowlist; off = skip.",
       default="smart",
       prompt_text="Backup mode for existing dotfiles (smart|full|off)",
       choices=("smart", "full", "off")),
```

Update BUNDLES (lines 235–288):
- `personal-mac`, `work-mac`, `server-linux`: replace `"backupDotfiles": True` with `"backupMode": "smart"`
- `minimal`: replace `"backupDotfiles": False` with `"backupMode": "off"`
- `custom`: unchanged (no override → falls back to default `smart`)

### 4. `Dockerfile` (lines 24, 139)

```diff
-ARG CHEZMOI_BACKUP_DOTFILES=false
+ARG CHEZMOI_BACKUP_MODE=off
...
-    --promptBool "Backup existing dotfiles before chezmoi overwrites them=${CHEZMOI_BACKUP_DOTFILES}" \
+    --promptChoice "Backup mode for existing dotfiles (smart|full|off)=${CHEZMOI_BACKUP_MODE}" \
```

### 5. `justfile` — add a new section (under or near the `chezmoi-*` block)

```just
# ============================================================================
# Dotfiles backup (~/.dotfiles_backup)
# ============================================================================

# List all backup snapshots with file count
list-backups:
    @if [ ! -d "$HOME/.dotfiles_backup" ]; then echo "No backups in ~/.dotfiles_backup"; exit 0; fi
    @for d in "$HOME"/.dotfiles_backup/*/; do \
        [ -d "$d" ] || continue; \
        ts=$(basename "$d"); \
        n=$(find "$d" -type f 2>/dev/null | wc -l | tr -d ' '); \
        printf '%s  (%s file(s))\n' "$ts" "$n"; \
    done

# Diff a backup snapshot against current files in ~ (read-only inspection)
diff-backup ts:
    @snap="$HOME/.dotfiles_backup/{{ts}}"; \
    if [ ! -d "$snap" ]; then echo "No such backup: {{ts}}" >&2; exit 1; fi; \
    find "$snap" -type f | while read -r backed; do \
        rel="${backed#$snap/}"; live="$HOME/$rel"; \
        if [ ! -e "$live" ]; then \
            printf '\n=== %s: in backup, missing from live ===\n' "$rel"; \
        elif ! cmp -s "$backed" "$live"; then \
            printf '\n=== %s ===\n' "$rel"; \
            diff -u "$backed" "$live" || true; \
        fi; \
    done
```

(Style matches existing recipes: doc-comment, `@`-prefixed quiet lines,
shell continuation. No `set -e` per just convention; explicit `|| true`
where useful. No new dependency — pure POSIX `find`/`cmp`/`diff`.)

### 6. `docs/this_repo/chezmoiscripts-layout.md` line 30

```diff
-| `run_before_01_backup_dotfiles.sh.tmpl` | every, before | Backs up `~/.zshrc` etc. before chezmoi overwrites; safe but bundled with the others for consistency |
+| `run_before_01_backup_dotfiles.sh.tmpl` | every, before | Backs up dotfiles before chezmoi overwrites. Three modes via `backupMode`: `smart` (default; uses `chezmoi status` to back up only files apply would modify/delete), `full` (hardcoded allowlist — onboarding mode), `off`. Honors legacy `backupDotfiles` bool. |
```

## What is intentionally NOT changed

- **Daily dedup** (`if ls -d "${BACKUP_BASE}/${TODAY}_"*`) stays — same
  rationale: prevents N applies on the same day producing N backup dirs.
- **Empty-dir cleanup** (`rmdir` if `BACKED_UP=0`) stays — `smart` mode on
  a clean host hits this path and produces zero footprint.
- **`~/.dotfiles_backup` path** stays.
- **No `just restore-backup` recipe** (per design choice). Inspect-only.
- **No new pruning recipe** (`prune-backups [DAYS]` left as future work).
- **`.chezmoiignore.tmpl`** untouched — script was never gated there.
- **`README.md`** untouched — backup is an internal mechanism; agent
  docs in `chezmoiscripts-layout.md` are sufficient.

## Verification

After implementing:

1. **Schema parity** — `uv run --script scripts/init/dotfiles_init.py doctor`
   must exit 0. This is the canonical drift check across `.chezmoi.toml.tmpl`,
   `Dockerfile`, and `PROMPTS`.
2. **smart on clean host** — on this dev machine where files are mostly
   in-sync: `chezmoi apply -v` should print no `[BACKUP/...]` line and
   `~/.dotfiles_backup/$(date +%Y%m%d)_*` should not exist (or, if a
   pre-existing one exists from earlier today, `rm -rf` first to test).
3. **smart on dirty host** — `echo '# drift' >> ~/.zshrc; chezmoi apply -v`
   must produce a backup containing only `~/.zshrc` (plus any other real
   diffs `chezmoi status` reports).
4. **full mode** — hand-edit `~/.config/chezmoi/chezmoi.toml` to
   `backupMode = "full"`, re-apply, confirm full allowlist (4 files + 6
   dirs) is captured (matches pre-change behavior verbatim).
5. **off mode** — `backupMode = "off"`, apply, confirm no backup dir.
6. **Legacy migration** — temporarily replace `backupMode = "..."` with
   legacy `backupDotfiles = true`; `chezmoi apply -v` must behave as
   `full`. Then `backupDotfiles = false` → must behave as `off`. (Proves
   the run-script's `hasKey`-based fallback works.)
7. **Docker** — `docker build --build-arg CHEZMOI_BACKUP_MODE=smart -t
   dotfiles:test .` then exec into the container and `grep backupMode
   ~/.config/chezmoi/chezmoi.toml`.
8. **Helpers** — create a fake snapshot
   (`mkdir -p ~/.dotfiles_backup/20260101_000000 && echo old >
   ~/.dotfiles_backup/20260101_000000/.zshrc`), then:
   - `just list-backups` shows it with count `(1 file(s))`.
   - `just diff-backup 20260101_000000` shows a unified diff vs current `~/.zshrc`.

## Cross-file invariant (per CLAUDE.md "Dockerfile + dotfiles_init wrapper")

Items 1, 3, 4 must land in the **same commit** — `dotfiles_init.py
doctor` will fail otherwise. Items 2 (run-script), 5 (justfile), 6
(layout doc) are independent surfaces but logically part of the same
change; group them in the same commit per the docs-mirror rule in
`CLAUDE.md`.
