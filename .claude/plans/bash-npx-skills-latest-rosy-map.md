# Quick fixes: NVM lazy-loader stale orphan + CodeIsland PermissionRequest auto-approve

## Context

Two unrelated rough edges hit in the same session.

### Problem 1 — `npx` non-interactive noise
`zsh: command not found: _nvm_lazy_load` (×3) before `npx` works in Claude Code's Bash shell. Root cause: a pre-chezmoi orphan at `~/.config/zsh/tools/02_legacy.zsh` (NOT chezmoi-managed; lives in `tools/` subdir, separate path from the chezmoi-managed `~/.config/zsh/02_legacy_tools.zsh` at the parent dir) defines `npx() { _nvm_lazy_load; npx "$@"; }` and friends. When `_nvm_lazy_load` runs it `unset -f`s itself + the wrappers, then sources `nvm.sh`, then re-invokes `npx "$@"`. Something in nvm.sh's source (or a downstream call to `npm`/`node` from inside the npx process) re-hits the stale wrapper after `_nvm_lazy_load` is already unset, hence the noise. The chezmoi-managed `02_legacy_tools.zsh` deliberately does **not** define lazy wrappers (it gates nvm sourcing entirely behind `LOAD_NVM=1`), so it's the orphan that breaks things.

### Problem 2 — `ExitPlanMode` silent auto-approve

**Major finding:** Upstream-fixed in CodeIsland v1.0.23 (released 2026-04-25, two days ago).

- [CodeIsland #128 — `[bug] claude code 完成 plan 后总会自动执行`](https://github.com/wxtsky/CodeIsland/issues/128) — closed; same symptom we documented in our pitfall.
- [CodeIsland #126 — `feat: make auto-approve tools configurable in settings`](https://github.com/wxtsky/CodeIsland/pull/126) — merged 2026-04-25.
- [CodeIsland v1.0.23 release notes](https://github.com/wxtsky/CodeIsland/releases/tag/v1.0.23): _"Make auto-approve tools configurable in Settings; **default no longer auto-approves `ExitPlanMode`** so plan-mode exit prompts an approval dialog (#126)."_

This machine's state right now:
- `defaults read /Applications/CodeIsland.app/.../Info.plist CFBundleShortVersionString` → **1.0.21**
- Brew cask metadata stale at 1.0.17, formula tracks 1.0.22, GitHub release is v1.0.23
- `~/.claude/settings.json` `hooks.PermissionRequest` still has the codeisland-hook.sh entry (24h timeout)

The repo's overlay already sets `permissions.defaultMode = "bypassPermissions"` (`dot_claude/modify_settings.json:64-67`) — the *sibling*-pitfall fix is in place. The auto-approve was the only outstanding symptom, and it's solved by upgrading CodeIsland.

**Pivot:** The previously-sketched "subtractive jq filter to strip the hook" (pitfall lines 87-103) is now the *wrong* fix. Stripping the `PermissionRequest` hook entirely would also kill the legitimate notch-popup confirm dialog — which v1.0.23 now uses correctly. So the repo-side change becomes documentation, not code.

---

## Part 1 — NVM lazy-loader orphan

### What's already true (so the user's concerns are addressed)

User's concern: "如果目標機器本身已經有NVM的話會怎麽樣？" + "原本是再想能在不影響原機器的情況下套用dotfiles" + "NVM init實在是有點慢."

- **The repo already moved off NVM.** `dot_config/zsh/02_legacy_tools.zsh:51-54` only sources `nvm.sh` if `LOAD_NVM=1` is set. mise is canonical (`dot_config/zsh/tools/05_mise.zsh:14`, `dot_config/mise/config.toml.tmpl:12` → `node = "lts"`). This was already the design before today.
- **Existing `~/.nvm/` install is NOT touched.** chezmoi never writes into `~/.nvm`. The binary `~/.nvm/versions/node/v22.11.0/bin/npx` stays on disk. nvm just isn't auto-sourced. Anyone who really needs nvm can `LOAD_NVM=1 zsh` (one-shot) or `echo 'export LOAD_NVM=1' >> ~/.zshrc.adhoc` (per-machine, opt-in, never committed).
- **Slow zsh startup:** that's exactly why nvm is gated. mise (~10 ms init) replaces the slow `nvm.sh` source. Removing the orphan does NOT slow startup — it removes the broken lazy-wrappers, but the chezmoi-managed file already keeps NVM out of the hot path.

Net effect of this fix on the host: **no functional regression**. The orphan was already redundant with the chezmoi-managed file; deleting it just removes the noise.

### The fix

**Step 1 — Delete the orphan locally** (one-time, this machine):
```bash
rm ~/.config/zsh/tools/02_legacy.zsh
```

No repo-side enforcement (no `.chezmoiremove`, no `run_once_*` cleanup). Rationale: the orphan may exist with hand-customised content on other hosts (work laptop, fleet); a blanket removal is too aggressive. The grep-friendly pitfall doc below makes ad-hoc cleanup trivial when the symptom resurfaces.

**Step 2 — New pitfall doc** at `/Users/daviddwlee84/.local/share/chezmoi/pitfalls/zsh-nvm-lazy-loader-orphan.md`:
- **Symptom**: literal grep-friendly error string `zsh: command not found: _nvm_lazy_load` in non-interactive shells (Claude Code Bash, scripted invocations, CI).
- **First seen**: 2026-04-27.
- **Affects**: macOS hosts that adopted chezmoi mid-life (the orphan exists from before chezmoi management started 2025-02 era).
- **Status**: workaround documented; ad-hoc `rm` per host (no `.chezmoiremove` enforcement — too aggressive for hand-customised variants on other hosts).
- **Root cause**: `~/.config/zsh/tools/02_legacy.zsh` is a stale lazy-loader from the pre-chezmoi era; the chezmoi-managed `dot_config/zsh/02_legacy_tools.zsh` (different filename, different dir) gates nvm sourcing behind `LOAD_NVM=1` and superseded the orphan but never overwrote it (different paths).
- **Why it surfaces non-interactively**: `dot_zshrc.tmpl` globs both `~/.config/zsh/tools/*.zsh` and `~/.config/zsh/*.zsh` for ALL shells (interactive + non-interactive). The orphan's `npx()` wrapper fires under `npx` calls, then `_nvm_lazy_load` is `unset -f`'d before something downstream re-invokes it (probably nvm.sh's own internal `npm`/`node` calls hitting the same stale wrapper namespace).
- **Workaround**: `rm ~/.config/zsh/tools/02_legacy.zsh` (per host). If you customised the file with your own lazy-loader, move that customisation into `~/.zshrc.adhoc` (machine-local, not chezmoi-managed) before deleting.
- **Prevention**: when migrating tool init from `tools/<n>.zsh` to top-level `<n>_tools.zsh`, document the old path in a pitfall like this one and rely on grep when the symptom resurfaces — the orphan is harmless on hosts that never sourced it for non-interactive shells.

### Out of scope (intentionally)

- **Audit other potential orphans in `~/.config/zsh/tools/`**: there are likely more pre-chezmoi files there. Worth a follow-up `just orphans` recipe / script. **Not** in this quick fix — would need to diff the full directory listing against `chezmoi managed`. Track in TODO.md instead (see Part 3 below).
- **Rebuild a working lazy-loader for users who actually want nvm**: a correct version (gated `[[ -o interactive ]]`, reentrant-safe) belongs in `~/.zshrc.adhoc` (machine-local). The repo doesn't auto-install it because the design choice is "mise canonical."

---

## Part 2 — CodeIsland PermissionRequest auto-approve

### The fix (upstream)

```bash
brew upgrade --cask wxtsky/tap/codeisland   # picks up v1.0.23
# Quit the running CodeIsland HUD app from the menu bar
open -a CodeIsland                          # relaunch the new build
defaults read /Applications/CodeIsland.app/Contents/Info.plist CFBundleShortVersionString
# Expected: 1.0.23
```

After v1.0.23 is running:
- `ExitPlanMode` no longer auto-approves by default.
- A new "Auto-approve Tools" section in the CodeIsland Settings → Behavior page lets the user toggle each tool individually (per PR #126 description). User can verify ExitPlanMode is OFF in that UI.
- The `hooks.PermissionRequest` entry stays in `~/.claude/settings.json` — that's correct now: it powers the legitimate notch-popup confirm dialog. We do NOT want to strip it.

The user's existing `permissions.defaultMode = "bypassPermissions"` overlay (already in place) keeps the sibling pitfall fixed: after the user approves a plan via the popup, Claude Code drops to `acceptEdits` (hardcoded post-`ExitPlanMode`, see sibling pitfall) — `Shift+Tab` ×2 recovers `bypassPermissions`. That part is unchanged and out of scope.

### Repo-side changes (documentation only)

**Edit `pitfalls/codeisland-auto-approves-permissionrequest.md`:**

1. Bump **Status** (line 18) from "workaround documented" to:
   > **Status**: upstream-fixed in CodeIsland v1.0.23 (2026-04-25). On affected hosts: `brew upgrade --cask wxtsky/tap/codeisland`, then quit + relaunch the HUD. See [Workaround → upstream upgrade](#workaround) and the new "Repo-enforced removal — deliberately not implemented" stays-deliberate rationale below.

2. Insert a new top sub-section under **Workaround**, BEFORE the existing HUD-toggle text:
   > **Recommended (since 2026-04-25) — upgrade to CodeIsland v1.0.23+.** PR [#126](https://github.com/wxtsky/CodeIsland/pull/126) makes the auto-approve list configurable AND removes `ExitPlanMode` from the default auto-approve set. After upgrading, plan-mode exit prompts a real confirm dialog. The Settings → Behavior → "Auto-approve Tools" section lets you flip individual tools on/off if you want to re-enable specific ones. Tracking issue: [CodeIsland #128](https://github.com/wxtsky/CodeIsland/issues/128).

3. Keep the existing HUD-toggle paragraph as a **fallback for hosts on <v1.0.23**.

4. Keep the **escape hatch — strip the hook by hand** + **CodeIsland will re-install it** paragraphs verbatim (still relevant for hosts that haven't upgraded yet).

5. Edit "Repo-enforced removal — deliberately not implemented" (lines 87-103):
   - Keep the section title as-is.
   - Update the lead paragraph to: _"Still deliberately not implemented (decision reaffirmed 2026-04-27): the upstream fix in v1.0.23 is the right path, and stripping the `PermissionRequest` hook would also disable the legitimate notch-popup confirm dialog. The jq-filter sketch below is preserved for the unlikely future case where we need to subtractively remove a different bad-actor hook."_
   - Keep the jq sketch (lines 93-101) verbatim. It's a useful reference even if not wired up.

**Edit `docs/tools/agent-overlays.md` "CodeIsland integration (macOS only)" section:**
- Add a one-line note: as of CodeIsland v1.0.23, default auto-approve set no longer includes `ExitPlanMode`; the merger continues to additively preserve all CodeIsland hook entries (which is what we want — no subtractive logic added).

**No code changes** in `dot_claude/modify_settings.json`, `tests/unit/agent_overlays.bats`, `.chezmoi.toml.tmpl`, `Dockerfile`, or `scripts/init/dotfiles_init.py`. The merger logic and `defaultMode = bypassPermissions` are correct as-is.

---

## Part 3 — Add to TODO.md

Add one entry to [`TODO.md`](../../TODO.md):

```markdown
- [ ] **[?/S] Audit `~/.config/zsh/tools/` for other pre-chezmoi orphans** — `02_legacy.zsh` was caught and removed via `.chezmoiremove` (see [pitfall](pitfalls/zsh-nvm-lazy-loader-orphan.md)). Likely siblings exist (`27_thefuck.zsh`, etc. — chezmoi managed list does NOT include all `tools/*.zsh` we see on disk). Diff `ls ~/.config/zsh/tools/` against `chezmoi managed --include=files | grep tools/` and add any non-managed files to `.chezmoiremove` after verifying they're truly stale.
```

---

## Critical files to modify

| Surface | Path | Change |
|---|---|---|
| NVM cleanup (this machine) | `~/.config/zsh/tools/02_legacy.zsh` | `rm` (other hosts: ad-hoc when symptom resurfaces) |
| NVM diagnosis doc | `/Users/daviddwlee84/.local/share/chezmoi/pitfalls/zsh-nvm-lazy-loader-orphan.md` (NEW) | Symptom-titled pitfall (grep-friendly for future hosts) |
| CodeIsland upstream | macOS host | `brew upgrade --cask wxtsky/tap/codeisland` + quit + relaunch |
| CodeIsland pitfall update | `/Users/daviddwlee84/.local/share/chezmoi/pitfalls/codeisland-auto-approves-permissionrequest.md` | Status + Workaround upstream-upgrade section + reaffirm "subtractive removal stays unimplemented" rationale |
| CodeIsland overlay docs | `/Users/daviddwlee84/.local/share/chezmoi/docs/tools/agent-overlays.md` | One-line v1.0.23 note in CodeIsland integration section |
| Follow-up tracker | `/Users/daviddwlee84/.local/share/chezmoi/TODO.md` | New `[?/S]` entry for tools/ orphan audit |

No changes needed in: `dot_claude/modify_settings.json` (overlay logic correct), `tests/unit/agent_overlays.bats` (tests still valid; test on line 264 asserting `defaultMode == "auto"` is technically stale but unrelated to this task — track separately if needed), `.chezmoi.toml.tmpl`, `Dockerfile`, `scripts/init/dotfiles_init.py`, `mkdocs.yml` (pitfalls/ + TODO.md are reference-only per CLAUDE.md, not in MkDocs nav).

---

## Verification

### Part 1 — NVM orphan

```bash
# Reproduce the noise BEFORE the fix
zsh -c 'npx --version' 2>&1 | head
# Expected: 3× "zsh: command not found: _nvm_lazy_load" lines, then a version

# Apply the fix
rm ~/.config/zsh/tools/02_legacy.zsh

# Confirm
zsh -c 'npx --version' 2>&1 | head
# Expected: just the version, no error lines

# Confirm chezmoi is not surprised by the deletion (the orphan was never managed)
chezmoi managed --include=files | grep "02_legacy" || echo "not managed (expected)"
```

### Part 2 — CodeIsland upgrade

```bash
# Before upgrade
defaults read /Applications/CodeIsland.app/Contents/Info.plist CFBundleShortVersionString
# Current observed: 1.0.21

brew upgrade --cask wxtsky/tap/codeisland
# (cask metadata may need `brew tap wxtsky/tap` first; brew info already shows the tap)

# Quit running CodeIsland from menu bar, then relaunch
osascript -e 'tell application "CodeIsland" to quit' 2>/dev/null || true
sleep 1
open -a CodeIsland
sleep 2
defaults read /Applications/CodeIsland.app/Contents/Info.plist CFBundleShortVersionString
# Expected: 1.0.23

# Confirm hook still installed (it should — that's correct now)
jq '.hooks.PermissionRequest[0].hooks[0].command' ~/.claude/settings.json
# Expected: "~/.codeisland/codeisland-hook.sh"

# End-to-end test: launch claude in plan mode, trigger ExitPlanMode
# Expected: visible confirm dialog (notch popup), NOT silent "Allowed by PermissionRequest hook"
# After approval: Claude Code lands in acceptEdits (hardcoded post-ExitPlanMode); Shift+Tab×2 recovers bypassPermissions
```

### Part 3 — TODO entry

```bash
# Sanity check the new entry is well-formed
grep -A1 "Audit.*orphans" /Users/daviddwlee84/.local/share/chezmoi/TODO.md
```
