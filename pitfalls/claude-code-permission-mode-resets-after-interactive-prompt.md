# Claude Code permission mode resets after every interactive prompt (hook AskUserQuestion / remote-control inject / CodeIsland popup)

**Symptoms** (grep this section):
- Started session in `bypassPermissions` (or `plan`) mode via `Shift+Tab`
- Answered an interactive question — could be a hook-driven `AskUserQuestion`, a CodeIsland popup, or a remote-control session injecting input — and the mode silently dropped back to `acceptEdits` (the default auto-edit mode)
- Subsequent `Bash(...)` invocations now prompt for permission individually, breaking flow
- No notification, no log line, no warning that the mode changed
- `Shift+Tab` cycles back to `bypassPermissions` and the prompts stop — until the next interactive question, then the cycle repeats

**First seen**: 2026-04
**Affects**: Claude Code (all versions through 2.x), any setup using interactive prompts mid-session — `AskUserQuestion` tool, hook-driven UIs (CodeIsland macOS notch HUD, claude-hud, etc.), remote-control / SSH-injected sessions
**Status**: working as intended (Anthropic) — workaround documented (set `permissions.defaultMode` in `~/.claude/settings.json`)

## Symptom

Reproduction:

1. Launch `claude`, press `Shift+Tab` until the mode indicator shows `bypass permissions` (or `auto-accept edits` — the bug applies to any non-default mode).
2. Run a prompt that triggers an interactive question. Easiest reproductions:
   - A hook that calls `AskUserQuestion` (e.g. CodeIsland's question popup shown over the macOS notch).
   - A remote-control session (e.g. tmux send-keys driving Claude from another pane) that injects an answer into a `?` prompt.
   - Any `claude-hud` / dashboard plugin that pops a choice picker.
3. Answer the question.
4. Issue any command that would normally need permission (e.g. `Bash(rm ...)` or `Edit` on a path outside the trusted scope).
5. **Expected**: stays in bypass, no prompt. **Actual**: drops to `acceptEdits`, prompts for permission.

The drop is silent — no banner, no `tmux show-messages` entry, no stderr line. The only signal is the bottom-of-screen mode indicator changing colour/label, which is easy to miss when attention is on the question's answer.

## Root cause

Claude Code's permission mode is **session-scoped state that resets at every "user-intervention checkpoint"**. The design treats `bypassPermissions` and `plan` as *temporary elevated states* that any interactive interruption invalidates, on the principle that "the user has been pulled out of the flow, so re-confirm the safe default before continuing."

Concrete reset triggers (observed):

- Any `AskUserQuestion` tool completion (whether triggered by Claude itself, a hook, or a plugin).
- Session resume / fork.
- Recovery after `SIGINT` (Ctrl+C in some paths).
- Some plugin-driven UI completions (CodeIsland's question popup, remote-control input injection).
- **`ExitPlanMode` approval (auto-approved via PermissionRequest hook OR manually approved)** — see [ExitPlanMode is a special case](#exitplanmode-is-a-special-case) below. Lands in `acceptEdits` regardless of `permissions.defaultMode`, which is different from every other trigger in this list.

Anthropic's stated rationale on related GitHub issues is the safety inversion: it's better to *under*-permit and re-prompt than to silently keep the user in bypass after an unexpected pause. They explicitly call this "working as intended" and have not committed to a `permissions.persistMode` opt-out. There is discussion but no ETA.

This interacts especially badly with two of our usage patterns:

1. **CodeIsland integration** — its hooks fire on `Notification` / `PermissionRequest` / `Stop`, frequently surfacing question popups. Each one resets the mode.
2. **Remote-control sessions** (driving Claude from a parallel tmux pane / mux script) — answering injected prompts looks like an interactive event to Claude, so mode resets even though the human didn't touch the keyboard.

## Workaround

Set the **default mode** to `bypassPermissions` in `~/.claude/settings.json`. After a reset, the "default" Claude falls back to is now bypass, so the visible behaviour is "mode never changes."

Managed in this repo via `dot_claude/modify_settings.json` (see [`docs/tools/agent-overlays.md`](../docs/tools/agent-overlays.md)):

```json
{
  "permissions": {
    "defaultMode": "bypassPermissions"
  }
}
```

The hook-aware merger merges this normally (`permissions` is not under `.hooks`, so it goes through the regular `base * overlay_no_hooks` deep-merge — verified additive with CodeIsland's runtime-installed hook entries).

### Alternative if `bypassPermissions` is too broad

If you don't want a global bypass, use `acceptEdits` (the existing default) but expand `permissions.allow` so the noisy commands stop prompting:

```json
{
  "permissions": {
    "defaultMode": "acceptEdits",
    "allow": [
      "Bash(git *)",
      "Bash(just *)",
      "Bash(uv *)",
      "Bash(npm *)",
      "Bash(rg *)",
      "Bash(fd *)",
      "Bash(ls *)"
    ]
  }
}
```

This trades "everything passes" for "the common-case bash invocations pass" — interactive prompts still reset the mode but reset to `acceptEdits` + allowlist, which is usually unobtrusive enough.

### What does NOT work

- Setting `permissionMode` from a `SessionStart` / `UserPromptSubmit` hook. In Claude Code 2.x the mode is not writable from hook output JSON; only `additionalContext` and a few other fields are honoured. The hook can read the current mode but can't restore it.
- Wrapping `claude` to re-press `Shift+Tab` after every reset. The reset happens mid-session inside the TUI loop, not at process boundaries, so an outer wrapper can't see it.

### `ExitPlanMode` is a special case

`ExitPlanMode` does **not** honour `permissions.defaultMode`. After approving a plan (either by clicking the native confirm dialog or — on macOS with CodeIsland's PermissionRequest hook installed — silently via [`pitfalls/codeisland-auto-approves-permissionrequest.md`](codeisland-auto-approves-permissionrequest.md)), Claude Code lands in **`acceptEdits`** regardless of what `defaultMode` is set to. This is hardcoded into the post-approval state machine and matches the UI flow ("Approve and accept edits" is one of the buttons; the auto-approved path lands in the same place).

Concretely:

```
Mode before ExitPlanMode: plan          (because Shift+Tab put you there)
defaultMode in settings.json:           bypassPermissions
Mode immediately after ExitPlanMode:    acceptEdits   ← surprising
```

Confirmed against `code.claude.com/docs` (consulted 2026-04-27): there is **no documented setting** that overrides where `ExitPlanMode` lands. Searched for `planExitMode`, `planModeExitTo`, `exitPlanMode`, `permissions.exitPlanModeMode` — none exist. There is also no keybinding action that jumps directly to a specific permission mode (only `chat:cycleMode`, see [`docs/tools/claude-code-keybindings.md`](../docs/tools/claude-code-keybindings.md)), so a hook-driven workaround that calls "set mode to X" is not exposed either.

**Workaround**: one `Shift+Tab` press takes you from `acceptEdits` → `plan` → `bypassPermissions` (cycle order is `default → acceptEdits → plan → bypassPermissions`, so from `acceptEdits` you press `Shift+Tab` twice to reach `bypassPermissions`). Annoying but the only available recovery. If/when Claude Code grows a setting that controls this, fold it into `dot_claude/modify_settings.json` next to the existing `permissions.defaultMode`.

## Prevention

- Use the `defaultMode` overlay above. Verified by `chezmoi apply` → inspect `~/.claude/settings.json` → confirm `permissions.defaultMode == "bypassPermissions"` AND `hooks.Notification` still contains both the CodeIsland entry and our `notify.sh` entry.
- Be aware that `bypassPermissions` widens the trust boundary repo-wide. If you collaborate with less-trusted code (random clones, AI-generated PRs landing on your machine), consider the `acceptEdits + allowlist` variant instead.

## Related

- [`docs/tools/agent-overlays.md`](../docs/tools/agent-overlays.md) — full overlay design, including why `permissions.*` lives outside the hook-aware merge path
- [`docs/tools/claude-code-keybindings.md`](../docs/tools/claude-code-keybindings.md) — the `Shift+Tab` cycle order, why no "jump straight to mode X" keybinding exists, and how to add personal keybinding overrides via the `modify_keybindings.json` overlay
- [`dot_claude/modify_settings.json`](../dot_claude/modify_settings.json) — the actual overlay
- [`pitfalls/codeisland-auto-approves-permissionrequest.md`](codeisland-auto-approves-permissionrequest.md) — the *sibling* pitfall: `ExitPlanMode` getting silently approved (CodeIsland-driven). The auto-approval is a different mechanism from the mode-reset issue documented here, but they compound: silent approval lands in `acceptEdits`, which is exactly what the `ExitPlanMode` section above describes.
- Anthropic GitHub issues (search "permission mode reset", "bypassPermissions resets after question", "AskUserQuestion mode") — multiple open issues, all marked as expected behaviour
- Adjacent: CodeIsland coexistence pattern in `docs/tools/agent-overlays.md` → "Pattern B — Mixed files (hook-aware merger)"
