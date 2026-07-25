# Claude Code keybindings (`~/.claude/keybindings.json`)

Claude Code stores its TUI keymap in a separate file from `~/.claude/settings.json`. This page documents the file format, the scope of customisation, and how this repo manages it via a `modify_` overlay.

| Surface | Path |
|---|---|
| Live file | `~/.claude/keybindings.json` |
| Source overlay | [`dot_claude/modify_keybindings.json`](../../dot_claude/modify_keybindings.json) |
| Schema | <https://www.schemastore.org/claude-code-keybindings.json> |
| Docs | <https://code.claude.com/docs/en/keybindings> |

## File shape

```json
{
  "$schema": "https://www.schemastore.org/claude-code-keybindings.json",
  "$docs": "https://code.claude.com/docs/en/keybindings",
  "bindings": [
    {
      "context": "Chat",
      "bindings": {
        "shift+tab": "chat:cycleMode",
        "enter": "chat:submit",
        "ctrl+j": "chat:newline",
        "...": "..."
      }
    },
    { "context": "Global", "bindings": { "...": "..." } }
  ]
}
```

The top-level `$schema` and `$docs` strings exist for editor integrations (autocomplete, hover-doc lookups). They are **not consumed by Claude Code itself** — but pinning them in the source-of-truth overlay keeps every machine quotable from the same canonical URLs. `$schema` is the [JSON Schema](https://json-schema.org/) standard convention; `$docs` is a Claude-Code-specific extension that JSON Schema validators ignore. For a general primer on the mechanism — including how to author a schema for one of our own configs — see [JSON Schema in this repo](json-schema.md).

`bindings` is an array of context-keyed entries. Each entry's `bindings` object maps a key string (`shift+tab`, `meta+p`, `ctrl+x ctrl+e` for sequences) to an action name (`chat:cycleMode`, `chat:submit`, …).

### Contexts available

Read from the user's live file as of 2026-04: `Global`, `Chat`, `Autocomplete`, `Settings`, `Doctor`, `Confirmation`, `Tabs`, `Transcript`, `HistorySearch`, `Task`, `ThemePicker`, `Scroll`, `Help`, `Attachments`, `Footer`, `MessageSelector`, `DiffDialog`, `ModelPicker`, `Select`, `Plugin`. Inspect your own copy for the full default set:

```bash
jq '.bindings[] | .context' ~/.claude/keybindings.json
```

## The `chat:cycleMode` limitation

Permission modes (`default`, `acceptEdits`, `plan`, `bypassPermissions`, `auto`, `dontAsk`) are switched only via the **single** action `chat:cycleMode` — bound to `shift+tab` by default. There is no documented action that jumps **directly** to a specific mode (no `chat:setMode`, no `chat:enterPlan`, etc.). Confirmed against `code.claude.com/docs/en/keybindings` 2026-04-27.

Practical consequences:

- You cannot bind a single key to "enter plan mode" — the only path is `Shift+Tab` `Shift+Tab` … through the cycle.
- The cycle order is `default → acceptEdits → plan → bypassPermissions` (and possibly `auto` if enabled in your build); to reach `bypassPermissions` from `acceptEdits` (the state you typically land in after `ExitPlanMode`, see below) you press `Shift+Tab` twice.
- Adding a duplicate binding (e.g. mapping a more accessible key to `chat:cycleMode`) doesn't shorten the path — it just gives you two ways to advance the same cycle. You still cycle.

If/when Claude Code grows a per-mode action, fold the new action into [`dot_claude/modify_keybindings.json`](../../dot_claude/modify_keybindings.json) following the merge guidance below.

### Sibling pitfalls

- [`pitfalls/claude-code-permission-mode-resets-after-interactive-prompt.md`](../../pitfalls/claude-code-permission-mode-resets-after-interactive-prompt.md) — the mode silently resets after `AskUserQuestion`, CodeIsland popups, remote-control inject, and `ExitPlanMode`. Lands in `acceptEdits` regardless of `permissions.defaultMode`.
- [`pitfalls/codeisland-auto-approves-permissionrequest.md`](../../pitfalls/codeisland-auto-approves-permissionrequest.md) — on macOS with the CodeIsland HUD installed, `ExitPlanMode` (and other permission requests) get rubber-stamped silently with `⎿ Allowed by PermissionRequest hook` / `⏺ Plan approved.` The `chat:cycleMode` recovery above is one of the visible fallout paths.

## How the `modify_` overlay works

[`dot_claude/modify_keybindings.json`](../../dot_claude/modify_keybindings.json) is a tiny shell script (mirrors the shape of [`dot_claude/modify_settings.json.tmpl`](../../dot_claude/modify_settings.json.tmpl)). Two execution paths:

1. **Bootstrap (empty stdin — live file does not exist yet)**: emit a minimal stub containing only `$schema` + `$docs`. Claude Code falls back to built-in defaults for any binding not present in the file.
2. **Steady-state (live file exists)**: pipe the live JSON into `jq '. * $overlay'`, which deep-merges the overlay over the live tree. The live `.bindings` array is preserved verbatim because the overlay has no `.bindings` key and `jq`'s `*` operator only replaces arrays that match an overlay key path.

Verify locally:

```bash
# Bootstrap path
echo '' | "$(chezmoi source-path ~/.claude/keybindings.json)"

# Steady-state path
cat ~/.claude/keybindings.json | "$(chezmoi source-path ~/.claude/keybindings.json)" | jq '."$schema", (.bindings | length)'
```

Apply / inspect via chezmoi:

```bash
chezmoi diff ~/.claude/keybindings.json   # only $schema/$docs lines should ever differ
chezmoi apply ~/.claude/keybindings.json  # idempotent on second run
```

### Adding a personal binding override (future)

The overlay does **not** ship binding overrides today. The reason: `jq '. * $overlay'` replaces arrays wholesale at matching key paths — if we put a `bindings: [...]` entry in the overlay for one context, every other context would survive (because the merge is keyed on `$schema`/`$docs`/`bindings` at the top level, and `bindings` IS present in both), but the merge would replace the **entire** `bindings` array, clobbering every default Claude Code ships.

To add overrides safely, extend the script's jq filter to merge `bindings` by `.context`. A sketch (not implemented):

```jq
. as $base
| ($overlay | del(.bindings)) as $non_bindings_overlay
| ($overlay.bindings // []) as $overlay_bindings
| ($base * $non_bindings_overlay) as $merged
| $merged
| .bindings = (
    ($merged.bindings // []) as $live_bindings
    | reduce $overlay_bindings[] as $entry (
        $live_bindings;
        # If a context exists in $live, deep-merge .bindings; else append.
        if any(.[]; .context == $entry.context) then
          map(if .context == $entry.context
              then .bindings = (.bindings + $entry.bindings)
              else . end)
        else . + [$entry] end
      )
  )
```

Don't write this filter speculatively — wait until there's a concrete binding worth pinning across machines, then implement and add a `bats` test in `tests/unit/agent_overlays.bats` alongside the existing Claude settings merger tests.

## See also

- [`dot_claude/modify_settings.json.tmpl`](../../dot_claude/modify_settings.json.tmpl) — the sibling overlay for `settings.json`. The hook-aware merger pattern there is the reference for any future array-merge work in this overlay.
- [`docs/tools/agent-overlays.md`](agent-overlays.md) — overall design of the coding-agent CLI overlays in this repo (Claude / OpenCode / Codex / Cursor).
- [`docs/tools/chezmoi-prefixes.md`](chezmoi-prefixes.md) — `modify_` vs `create_` semantics and the rationale for choosing `modify_` here.
