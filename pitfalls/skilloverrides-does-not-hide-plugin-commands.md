# `skillOverrides` silently does nothing for plugin commands (claude-hud, etc.)

## Symptoms

- A plugin's slash commands keep appearing in every Claude Code session's
  `The following skills are available for use with the Skill tool:` listing,
  even after adding them to `skillOverrides` in `~/.claude/settings.json`:

  ```json
  "skillOverrides": {
    "claude-hud:setup": "off",
    "claude-hud:configure": "off"
  }
  ```

- **No error anywhere.** Claude Code accepts the keys, keeps them in the file
  across restarts, `/doctor` is clean, the JSON stays valid. The setting is
  simply inert.
- `"user-invocable-only"` is equally inert for the same keys.
- The identical mechanism **works** for plain user skills in `~/.claude/skills/`
  — `{"mihome-ir": "off"}` really does drop `mihome-ir` from the listing. So the
  feature looks like it works, and you conclude your value or spelling is wrong
  rather than that the whole path is unsupported.
- Grepping the CC binary is misleading: the listing filter genuinely reads
  `skillOverrides` and genuinely excludes `"off"` / `"user-invocable-only"`.

Verified on Claude Code **2.1.220** (2026-07).

## Root cause

The per-session skill listing is built by (minified names from the 2.1.220
bundle, for future re-grepping):

```js
let r = await YR(t),                                  // skills  (~/.claude/skills)
    n = aUt(e.getMcp().commands),                     // MCP commands
    o = Qpr().filter((d) => !d.disableModelInvocation && !OEe(d)),   // commands
    i = sUt( RE([...r, ...o, ...n], "name") )
```

`OEe(e)` is the override gate — `let t = GUe(e); return t === "user-invocable-only" || t === "off"`
— and `GUe` looks the value up as `skillOverrides[e.name] ?? skillOverrides[e.unqualifiedName]`.

Two things defeat you:

1. The `!OEe(d)` filter is applied to **only one** of the three source arrays.
2. `e.name` at filter time is the *raw* command name, which is **not** the
   `plugin:command` string the listing later renders (`- ${e.name}: …` runs on
   the post-`sUt` objects). So the key you can see in the listing is not the key
   the lookup uses, and there is no way to discover the real one from outside.

Consequence: `skillOverrides` is a **user-skills-only** lever. Plugin-supplied
commands are not addressable through it at all.

## Workaround

Disable the whole plugin instead, in `enabledPlugins`:

```json
"enabledPlugins": {
  "claude-hud@claude-hud": false
}
```

Verified to actually drop the commands from the listing:

```console
$ claude -p 'Reply with ONLY the literal skill names listed in your available-skills
  system reminder that start with "claude-hud". If none, reply NONE.'
NONE
```

That headless one-liner is the **only** reliable way to test any of this — the
listing is not visible from inside a running session you can edit settings in,
and settings are read at process start, so you need a fresh process per attempt.

### Why this was safe for claude-hud specifically

Disabling a plugin normally costs you its features. It did not here, because
nothing we use goes through the plugin loader:

- **The HUD keeps rendering.** `statusLine.command` in `settings.json` globs
  `~/.claude/plugins/cache/claude-hud/claude-hud/*/` and execs `dist/index.js`
  directly. Confirm by piping a real payload through it with the plugin off:

  ```console
  $ printf '%s' '{"model":{"id":"claude-opus-5","display_name":"Opus 5"},...}' \
      | eval "$(jq -r '.statusLine.command' ~/.claude/settings.json)"
  [Opus 5] │ CC v2.1.207 │ ⏱️  572h 52m
  Context ░░░░░░░░░░ 0%
  ```

- **Updates keep working.** They run through
  `dot_ansible/roles/coding_agents/files/claude_hud_sync.py` (`just upgrade-plugins`),
  which only rewrites `installed_plugins.json` and the versioned cache dir. It
  never reads `enabledPlugins`.

- **The cache is not garbage-collected.** The `.in_use` / `.last_inuse_sweep`
  sweep targets *orphan* version dirs (`"Skipping orphan cleanup, in use by live
  session"`); a disabled-but-installed plugin stays listed in
  `installed_plugins.json`, so it is not an orphan. Even if it were swept,
  `claude_hud_sync.py --only-if-missing` re-clones it on the next `chezmoi apply`.

Trade-off: `/claude-hud:setup` and `/claude-hud:configure` stop resolving. Flip
`enabledPlugins` back to `true` (or toggle in `/plugin`) for the rare
reconfigure. Day-to-day config is a managed file at
`dot_claude/plugins/claude-hud/config.json`.

## Scale check before you bother

The saving is ~45 tokens/session (two `- name: description` lines) — about
0.02% of a 200k window. Worth doing as tidiness for a plugin used twice a year;
**not** worth it for anything you actually invoke. Measure first: `/plugin` →
Installed shows a per-skill `~N tok` figure.

## See also

- [`docs/tools/lsp.md`](../docs/tools/lsp.md) § Via Claude Code plugins — the
  `enabledPlugins` map and why claude-hud is `false` there.
- [`dot_claude/modify_settings.json.tmpl`](../dot_claude/modify_settings.json.tmpl)
  header comment — the enforced setting and its rationale.
- The "LSP Plugin Recommendation" popup is **Claude Code's own** feature, not
  claude-hud's (its `src/` has no LSP code) — it survives the disable. The
  earlier claim in `lsp.md` that claude-hud drove it was wrong.
