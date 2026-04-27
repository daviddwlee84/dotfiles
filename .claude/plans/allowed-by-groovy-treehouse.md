# Plan — Claude Code plan-mode auto-approval + keybindings hygiene

## Context

The user noticed `ExitPlanMode` being approved with `⎿ Allowed by PermissionRequest hook` and `⏺ Plan approved.` without ever clicking confirm. After approval the session also drops into **Accept Edits** (instead of staying in `bypassPermissions`), forcing manual `Shift+Tab` recovery. The user wants the root cause documented, the keybinding situation understood, and `~/.claude/keybindings.json` brought under chezmoi.

### Investigation findings (verbatim, from `~/.claude/settings.json`)

CodeIsland — the macOS notch HUD installed via `~/.codeisland/` — has registered itself as a `PermissionRequest` hook with a 24-hour timeout:

```json
"PermissionRequest": [
  {
    "matcher": "",
    "hooks": [
      {"type": "command", "command": "~/.codeisland/codeisland-hook.sh", "timeout": 86400}
    ]
  }
]
```

Our chezmoi overlay (`dot_claude/modify_settings.json`) **did not install this**; CodeIsland writes it itself on launch. The overlay's hook-aware merger correctly preserves it — the merger is doing its job. CodeIsland installs analogous entries for `Notification`, `PermissionDenied`, `PostToolUse`, `PreToolUse`, `SessionStart`, `SessionEnd`, `Stop`, `SubagentStart`, `SubagentStop`, `UserPromptSubmit`, `PreCompact`, `PostToolUseFailure` — 13 events total.

`codeisland-hook.sh` is a relay: it forwards the JSON event over a Unix socket (`/tmp/codeisland-$(id -u).sock`) to the native bridge binary `~/.codeisland/codeisland-bridge` (746 KB Mach-O). The auto-approval decision lives **inside the native binary / the macOS HUD app's settings**, not in any shell-readable config — so the actual fix is to disable auto-approve from the CodeIsland app's UI.

Authoritative facts confirmed against `code.claude.com/docs`:
- The only mode-related keybinding action documented is `chat:cycleMode` (Shift+Tab cycle). There is **no** `enter-plan-mode` / `setMode` action; you cannot bind a single key to jump straight into plan.
- `permissions.defaultMode` is the canonical setting key; valid values include `default`, `acceptEdits`, `plan`, `bypassPermissions`, `auto`, `dontAsk`. There is no documented setting that controls *where* `ExitPlanMode` lands — it always drops into `acceptEdits` by design.
- `~/.claude/keybindings.json` is officially supported. Schema: `https://www.schemastore.org/claude-code-keybindings.json`. Docs: `https://code.claude.com/docs/en/keybindings`.
- `permissions.defaultMode = "bypassPermissions"` is the only available workaround for "session keeps dropping back to acceptEdits after interactive prompts" — already in our overlay (`dot_claude/modify_settings.json:65-67`). It mitigates the post-question reset path but does NOT change the immediate ExitPlanMode → acceptEdits transition (that is a hardcoded Claude Code state machine, not a settings-driven default).

User decisions (gathered):
- **CodeIsland**: document only — recommend toggling auto-approve off in the CodeIsland HUD app. No repo-managed subtractive removal.
- **keybindings.json**: manage as a `modify_` overlay (jq-based), so we can add user deltas without owning the full default keymap.

## Recommended approach

Five small, mostly-documentation changes plus one new chezmoi-managed file. No invasive runtime changes. No subtractive merge added to `modify_settings.json`.

### 1. New pitfall — CodeIsland silently auto-approves `ExitPlanMode` and other permission prompts

**New file**: `pitfalls/codeisland-auto-approves-permissionrequest.md`

Title by **symptom**, per `pitfalls/README.md` rule: "Claude Code shows 'Allowed by PermissionRequest hook' / 'Plan approved.' without ever clicking confirm".

Body:
- Verbatim symptom strings (`Allowed by PermissionRequest hook`, `Plan approved.`).
- First seen 2026-04-27. Affects: any machine with CodeIsland installed.
- Root cause: CodeIsland writes a 24-hour-timeout `PermissionRequest` hook that relays to its HUD app; the app/binary contains an auto-approve path that doesn't surface a visible confirm dialog under conditions yet to be characterised (likely a "trust this session" / "auto-approve" toggle in the HUD UI, or a fallback-after-timeout behaviour).
- Why our overlay does **not** cause this: cite the hook-aware merger in `dot_claude/modify_settings.json` and the parallel-entry preservation pattern in `docs/tools/agent-overlays.md`. The merger never injects CodeIsland entries.
- **Workaround**: open the CodeIsland HUD app and disable any "auto-approve" / "trust" toggle. If the toggle isn't found, the escape hatch is to remove the `PermissionRequest` hook entry from `~/.claude/settings.json` by hand (CodeIsland will re-install it on next launch unless the HUD app is also disabled at startup) — note this trade-off explicitly.
- **Repo-enforced removal — deliberately not implemented** (per user choice). Document this decision and what the implementation would look like for future-us (extend the jq merger in `dot_claude/modify_settings.json` with a "subtract by command-string" pass that strips entries where `.hooks[0].command == "~/.codeisland/codeisland-hook.sh"` from a configurable event list, gated behind a new chezmoi prompt). One-paragraph note only — don't write the code.
- Cross-link to: `docs/tools/agent-overlays.md` (CodeIsland coexistence section), `pitfalls/claude-code-permission-mode-resets-after-interactive-prompt.md` (the related but distinct issue of mode resetting after `AskUserQuestion`).

### 2. Extend the existing permission-mode-reset pitfall

**Edit**: `pitfalls/claude-code-permission-mode-resets-after-interactive-prompt.md`

Add an "ExitPlanMode lands in acceptEdits, not the configured defaultMode" section. Today the doc describes the AskUserQuestion / CodeIsland-popup path; the ExitPlanMode path is a sibling but not mentioned. Note explicitly:
- `permissions.defaultMode = "bypassPermissions"` does NOT prevent the ExitPlanMode → acceptEdits transition.
- There is no documented Claude Code setting that overrides this.
- Workaround: `Shift+Tab` cycles back to bypass (one keypress, since the cycle order is `default → acceptEdits → plan → bypassPermissions` and we're starting from acceptEdits). Document this so future-us doesn't re-investigate.

### 3. Manage `~/.claude/keybindings.json` via a modify_ overlay

**New file**: `dot_claude/modify_keybindings.json` (executable shell script, `modify_` prefix per `docs/tools/chezmoi-prefixes.md`).

Design — mirror `dot_claude/modify_settings.json`:
- Read live target contents from stdin. If empty (fresh machine, Claude Code hasn't generated defaults yet), emit a minimal stub `{"$schema": "...", "$docs": "...", "bindings": []}` and exit.
- Otherwise, jq-merge a small overlay onto the live file. Initial overlay contents:
  ```json
  {
    "$schema": "https://www.schemastore.org/claude-code-keybindings.json",
    "$docs": "https://code.claude.com/docs/en/keybindings"
  }
  ```
  No `bindings` overrides yet — the live defaults are kept verbatim. This is intentional: the overlay file becomes the place to add personal customisations later, without owning the full default keymap (which would diverge silently when Claude Code ships new defaults).
- Header comment explaining: (a) why `modify_` not `create_` (we want re-applies to enforce metadata + future deltas), (b) why we don't ship the full default keymap (drift risk), (c) where to add per-user binding overrides (a clearly-marked spot inside the `overlay=` heredoc), (d) cross-reference to `docs/tools/claude-code-keybindings.md`.
- Reuse the same `set -eu` / `printf '%s' "$base" | jq --argjson overlay …` shape as `modify_settings.json` so the two files read identically.

**Reused utilities** (no new dependencies): `jq` (already installed by the `base` ansible role per `dot_claude/modify_settings.json:25`).

### 4. New docs page

**New file**: `docs/tools/claude-code-keybindings.md`

Sections:
- What `~/.claude/keybindings.json` is, with the authoritative `$schema` / `$docs` URLs.
- The available action namespaces and the canonical contexts (Global, Chat, Autocomplete, Settings, Confirmation, Tabs, Transcript, HistorySearch, Task, ThemePicker, Scroll, Help, Attachments, Footer, MessageSelector, DiffDialog, ModelPicker, Select, Plugin) — extracted from the live file the user has now (don't enumerate every binding, just say "see the live file for the full default set").
- The `chat:cycleMode` limitation: only one mode-related action exists; **no** "jump to plan", "jump to bypass", etc.; cite the docs.
- How our `dot_claude/modify_keybindings.json` overlay works and where to drop personal binding overrides.
- Pointer to `pitfalls/claude-code-permission-mode-resets-after-interactive-prompt.md` for the mode-reset gotcha.
- Pointer to `pitfalls/codeisland-auto-approves-permissionrequest.md` for the auto-approve gotcha.

**Edit**: `mkdocs.yml` — add the new page to the **Tools** nav, alphabetical placement near the existing `agent-overlays.md` / `agent-skills.md` entries. Verify with `uv run mkdocs build --strict`.

### 5. Cross-links and CLAUDE.md update

**Edit**: `docs/tools/agent-overlays.md` — add a one-line pointer to `claude-code-keybindings.md` in its "Related" / "Case studies" section. The two pages are siblings (both about Claude Code config files we manage).

**Edit**: `CLAUDE.md` — add Claude Code to the existing **Keyboard shortcuts (cross-tool conflict check)** table. New row: `Claude Code (TUI)` | `dot_claude/modify_keybindings.json` (overlay) + `~/.claude/keybindings.json` (live) | `Ctrl+R` (history:search — conflicts with atuin/zsh-history-substring), `Ctrl+T` (toggleTodos — conflicts with our television picker if launched from inside Claude), `Shift+Tab` (cycleMode — only intercepted inside Claude). One row, table-format, no narrative bloat.

No new chezmoi prompt (the modify_ overlay needs no machine-specific gating). No `Dockerfile` / `dotfiles_init.py` / parity-check change.

## Files to be touched (summary)

| File | Action | Why |
|---|---|---|
| `pitfalls/codeisland-auto-approves-permissionrequest.md` | NEW | Capture root cause; recommend HUD-app fix |
| `pitfalls/claude-code-permission-mode-resets-after-interactive-prompt.md` | EDIT | Add ExitPlanMode section |
| `dot_claude/modify_keybindings.json` | NEW | jq overlay seeding `$schema`/`$docs`; future-deltas hook |
| `docs/tools/claude-code-keybindings.md` | NEW | User-facing doc explaining the file + the cycleMode limitation |
| `mkdocs.yml` | EDIT | Nav entry under **Tools** for the new page |
| `docs/tools/agent-overlays.md` | EDIT | One-line cross-link to the new keybindings page |
| `CLAUDE.md` | EDIT | Add Claude Code row to keyboard-shortcut conflict table |

Critical existing references (do not modify, but read while implementing):
- `dot_claude/modify_settings.json` — model for the new modify_keybindings overlay
- `docs/tools/agent-overlays.md` — pattern documentation for the hook-aware / overlay pattern
- `docs/tools/chezmoi-prefixes.md` — `modify_` vs `create_` semantics

## Verification

End-to-end:
1. `chezmoi diff ~/.claude/keybindings.json` — should show only the `$schema`/`$docs` lines being touched (since the overlay only adds metadata). `chezmoi apply ~/.claude/keybindings.json` should be idempotent on second invocation.
2. Inspect `~/.claude/keybindings.json` after apply: `$schema` and `$docs` present at the top; the full `bindings` array (Global / Chat / etc.) preserved unchanged.
3. `chezmoi diff ~/.claude/settings.json` — should be a no-op (nothing in this plan touches `dot_claude/modify_settings.json`); the live file should still contain the CodeIsland `PermissionRequest` entry verbatim and our `notify.sh` entries in `Notification` and `Stop`.
4. `uv run mkdocs build --strict` — green; the new page is reachable from the Tools nav and any in-repo cross-links resolve.
5. `uv run --script scripts/init/dotfiles_init.py doctor` — green; no new prompts means no parity drift.
6. Open the CodeIsland HUD UI, locate the auto-approve toggle (or the relevant trust/permission setting), disable it. Re-launch `claude`, enter plan mode (`Shift+Tab`), and run a prompt that would normally `ExitPlanMode`. Expected: a visible confirm dialog (HUD or Claude Code native), no silent "Plan approved." with `⎿ Allowed by PermissionRequest hook`. (This step depends on CodeIsland's actual UI, so it's a manual ack-test; record the path/setting found in the new pitfall doc once known.)
7. Inside `claude`, after exiting plan mode, confirm a single `Shift+Tab` returns to `bypassPermissions` (matches the documented cycle order).
