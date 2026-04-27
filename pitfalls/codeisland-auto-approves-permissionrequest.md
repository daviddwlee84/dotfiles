# Claude Code shows "Allowed by PermissionRequest hook" / "Plan approved." without ever clicking confirm

**Symptoms** (grep this section):

```
  ⎿  Allowed by PermissionRequest hook

⏺ Plan approved.
```

- `ExitPlanMode` is "approved" instantly — no notch popup, no native Claude Code confirm dialog, no user interaction.
- Same banner can appear for arbitrary `Bash(...)` / `Edit` permission prompts when the live mode would normally request confirmation.
- After the silent approval the session also drops into **Accept Edits**, forcing manual `Shift+Tab` recovery (this second symptom is a sibling pitfall — see [Related](#related)).
- `~/.claude/settings.json` contains a `hooks.PermissionRequest` entry pointing at `~/.codeisland/codeisland-hook.sh` with `"timeout": 86400` (24 h).

**First seen**: 2026-04
**Affects**: macOS hosts where [CodeIsland](https://github.com/wxtsky/CodeIsland) is installed (the macOS notch HUD; brew cask `wxtsky/tap/codeisland`). Independent of Claude Code version.
**Status**: workaround documented — **disable auto-approve from inside the CodeIsland HUD app** (no in-repo enforcement; see [Workaround](#workaround) and [Repo-enforced removal — deliberately not implemented](#repo-enforced-removal--deliberately-not-implemented)).

## Symptom

After installing or updating CodeIsland (or after any first-launch on a fresh machine where the cask landed via `brew bundle`), every plan-mode exit and most subsequent permission prompts get rubber-stamped:

```
⏺ <ExitPlanMode>
  ⎿  Allowed by PermissionRequest hook

⏺ Plan approved.
```

The "Allowed by PermissionRequest hook" line is Claude Code's own message — it appears whenever a `PermissionRequest` hook returns an `allow` decision. The user did not click anything; the auto-approval is upstream of Claude Code's own UI.

Inspecting the live config confirms the hook entry:

```bash
$ jq '.hooks.PermissionRequest' ~/.claude/settings.json
[
  {
    "matcher": "",
    "hooks": [
      {
        "type": "command",
        "command": "~/.codeisland/codeisland-hook.sh",
        "timeout": 86400
      }
    ]
  }
]
```

`codeisland-hook.sh` itself is a thin relay (~80 lines) that forwards the hook event JSON over a Unix socket (`/tmp/codeisland-$(id -u).sock`) to the native bridge binary `~/.codeisland/codeisland-bridge` (Mach-O, ~750 KB). Reading the shell wrapper alone never reveals the approval logic — that lives inside the binary / the SwiftUI HUD app's settings panel.

## Root cause

CodeIsland advertises "Auto hook install" with "auto-repair and version tracking": the macOS app actively writes and re-writes hook entries into each detected coding-agent CLI's config on every launch — see [docs/tools/agent-overlays.md → CodeIsland integration](../docs/tools/agent-overlays.md#codeisland-integration-macos-only). One of the entries it installs is a `PermissionRequest` hook with a 24-hour timeout (`86400` seconds), which intercepts every Claude Code permission decision before the native UI gets a chance to render.

When the hook fires, the relay forwards the request to the macOS HUD app. The app **decides whether to surface a visible confirm dialog or auto-approve silently** based on settings stored inside the app — most likely a "trust this session" / "auto-approve" toggle, but the exact toggle name and condition (per-session, per-tool, after a timeout, after N approvals, etc.) lives inside the closed-source binary and we have not characterised it definitively.

What we **do** know:

- Our chezmoi overlay does **not** install this hook. `dot_claude/modify_settings.json` is the file that manages `~/.claude/settings.json`, and its hook-aware merger only ever appends `~/.claude/hooks/notify.sh` to `Notification` and `Stop`. CodeIsland writes its own entry; the merger sees it on the next apply and preserves it untouched (additive, not overwrite). Verified by reading the merger source and running `bats tests/unit/agent_overlays.bats`.
- The other CodeIsland-installed hooks (`Notification`, `PermissionDenied`, `PostToolUse`, `PreToolUse`, `SessionStart`, `SessionEnd`, `Stop`, `SubagentStart`, `SubagentStop`, `UserPromptSubmit`, `PreCompact`, `PostToolUseFailure`) all use a 5-second timeout — only `PermissionRequest` gets the 24-hour budget, which is consistent with "wait for the user to interact with the notch popup". So there is a path inside CodeIsland that is supposed to wait for input; the auto-approve we observe is happening on a parallel path inside the same binary.

## Workaround

**Recommended — toggle off auto-approve in the CodeIsland HUD app.**

1. Open the CodeIsland menu-bar / notch HUD.
2. Look for an "auto-approve" / "trust" / "permission" / "skip confirmation" toggle in the app's settings panel and disable it.
3. Re-launch `claude`, enter plan mode (`Shift+Tab` until the indicator shows `plan`), and run a prompt that triggers `ExitPlanMode`.
4. Expected after the toggle is off: a visible confirm prompt (either the notch popup or Claude Code's native one) instead of `Allowed by PermissionRequest hook` + `Plan approved.`

When you find the exact setting name + path, please update this section so future-us doesn't have to re-discover it.

**Escape hatch — temporarily strip the hook by hand.** If the HUD toggle isn't where it should be (or doesn't exist on your CodeIsland version), you can remove the hook entry directly:

```bash
# Edit ~/.claude/settings.json and delete the hooks.PermissionRequest array entry
# whose .hooks[0].command equals "~/.codeisland/codeisland-hook.sh".
# Or, scripted:
jq 'del(.hooks.PermissionRequest)' ~/.claude/settings.json > /tmp/s.json && \
  mv /tmp/s.json ~/.claude/settings.json
```

**Caveat — CodeIsland will re-install it on next launch.** Per [agent-overlays.md → CodeIsland integration](../docs/tools/agent-overlays.md#codeisland-integration-macos-only), the app's "auto-repair" runs on startup. The hook will be back the next time you open the HUD app (or sometimes within seconds, if the app is already running and re-checks). To make the removal stick, you also need to keep the HUD app from running — quit it from the menu bar and remove it from Login Items (`System Settings → General → Login Items`).

### Repo-enforced removal — deliberately not implemented

A repo-managed solution exists in design but is **not wired up** (per user decision 2026-04-27 — preferred to surface this as documentation only, since it interacts with a third-party app whose behaviour may change). For future-us:

The hook-aware merger in [`dot_claude/modify_settings.json`](../dot_claude/modify_settings.json) already does *additive* merging by command-string match. The mirror operation — *subtractive* removal — would extend the same jq filter with a "blocklist" pass:

```jq
# After the additive append in the existing reduce, add a filter step:
| .hooks |= with_entries(
    .value |= map(select(
      (.hooks[0].command? // "") as $cmd
      | ($cmd | IN($block_cmds[]) | not)
    ))
  )
```

Where `$block_cmds` is a small list passed via `--argjson block_cmds '["~/.codeisland/codeisland-hook.sh"]'`. The list could be empty by default and populated only when a new chezmoi prompt (`disableCodeIslandPermissionRequest` or similar) is set true at init. Note that flat removal would strip the entry from **all** event arrays, not just `PermissionRequest`; if the goal is "keep CodeIsland's other hooks but kill the one that auto-approves", the filter needs to scope by event key as well — track per-event blocklists in `$overlay.removeHooks.<event>` and gate each `select` accordingly. None of this is implemented; capturing the design here so the next time it comes up we don't redesign from scratch.

## Prevention

- When a new coding-agent CLI grows a `PermissionRequest` (or equivalent) hook surface, treat it the way Claude Code's settings.json is treated in [docs/tools/agent-overlays.md](../docs/tools/agent-overlays.md): plan for additive merging *and* potential subtractive removal of third-party-installed entries.
- Keep `~/.claude/settings.json` checks in `chezmoi diff` clean (no churn from CodeIsland re-installing the hook over our overlay) — this is what the additive merger guarantees today.
- Don't paper over the symptom by raising `permissions.defaultMode` further (e.g. trying to set it to a non-existent "always-deny" mode). The defaultMode = `bypassPermissions` overlay is the right knob for the sibling pitfall (mode reset after interactive prompt) but doesn't address this one — the auto-approval happens *before* the mode-fallback path runs.

## Related

- [`docs/tools/agent-overlays.md` → CodeIsland integration](../docs/tools/agent-overlays.md#codeisland-integration-macos-only) — overlay design, why CodeIsland's entries are preserved by our merger, brewfile hook-up.
- [`pitfalls/claude-code-permission-mode-resets-after-interactive-prompt.md`](claude-code-permission-mode-resets-after-interactive-prompt.md) — the *sibling* pitfall: after `ExitPlanMode` (or any interactive popup) Claude Code drops the permission mode back to `acceptEdits`. Same surface area, different mechanism (Claude-Code-side state machine, not a CodeIsland hook).
- [`docs/tools/claude-code-keybindings.md`](../docs/tools/claude-code-keybindings.md) — recovery cycle (`Shift+Tab` to get back to bypass) and the unfortunate fact that Claude Code does not expose a single keybinding to jump straight into plan mode.
- [`dot_claude/modify_settings.json`](../dot_claude/modify_settings.json) — the hook-aware merger that would host the deferred subtractive removal logic.
