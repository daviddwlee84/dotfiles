# Plan: Fix motdStyle source/target confusion + docs gotcha

## Context

User manually edited `~/.config/chezmoi/chezmoi.toml` from `motdStyle = "fastfetch-full"` to `"fastfetch-slim"`, then SSH'd to localhost — but the banner still shows `fastfetch-full` output. They expected the toml change alone to take effect.

**Root cause** (diagnosed via Bash):
- `~/.config/chezmoi/chezmoi.toml` → `motdStyle = "fastfetch-slim"` ✅
- `~/.zlogin` → `_motd_style="${MOTD_STYLE:-fastfetch-full}"` ← stale, rendered at last `chezmoi apply` when the value was `fastfetch-full`
- No `MOTD_STYLE` env var, no `~/.zshrc.adhoc` override

This is the **classic chezmoi source-vs-target gotcha**: `chezmoi.toml` is only the data source consulted during template rendering. `~/.zlogin` is a generated artifact frozen at last `chezmoi apply`. Editing the source without re-applying is a no-op for the target.

Two improvements:
1. **Immediate fix** (one command for the user, no code change): `chezmoi apply ~/.zlogin`
2. **Docs fix** (prevents future-you and other fleet operators from re-discovering this): add a clear "How to switch styles" section to `docs/zsh/motd.md` that distinguishes the three update paths and explicitly calls out the apply requirement.

## Scope

**In:**
- A small targeted edit to `docs/zsh/motd.md` clarifying the three update paths (chezmoi prompt re-init, chezmoi.toml + apply, runtime env override) with explicit emphasis on `chezmoi apply` being mandatory after toml edits.
- Show the user the diagnostic that proves the root cause and the one-line fix.

**Out:**
- Auto-apply hook on chezmoi.toml changes — over-engineered, breaks the explicit-apply mental model.
- Onchange script that warns when `~/.zlogin` is stale — false-positive heavy, not worth the complexity.
- Any change to `dot_zlogin.tmpl` itself — already correct.
- Re-running `chezmoi init --force` — works but heavier than needed; `chezmoi apply` is sufficient since the chezmoi.toml is already updated.

## Files to modify

| Path | Action |
|---|---|
| `docs/zsh/motd.md` | Replace the existing "Switching styles" section with a clearer 3-path layout that emphasizes `chezmoi apply` is required after toml edits |

## Implementation sketch

The existing `docs/zsh/motd.md` already has a "Switching styles" section with two subsections (`At install time`, `At runtime`). Add a third subsection (or reorganize into three paths), placed in increasing order of "how heavy is this":

1. **Per-session (no persistence)**: `MOTD_STYLE=fastfetch-slim ssh host` — env var on the SSH command line.
2. **Persistent runtime override**: add `export MOTD_STYLE=fastfetch-slim` to `~/.zshrc.adhoc`. No chezmoi apply needed; survives reboots; per-machine.
3. **Edit chezmoi source** (the path that just bit the user):
   - Either edit `~/.config/chezmoi/chezmoi.toml` directly (`motdStyle = "..."`) **OR** re-run `chezmoi init --force`.
   - **Then** run `chezmoi apply ~/.zlogin` to re-render the file.
   - **Without `chezmoi apply` the change has no effect** — `~/.zlogin` is regenerated, not interpreted live. Add a callout box or bold warning here.

The current docs already mention these but doesn't sequence them or warn about the apply requirement. The fix is a clarifying rewrite, not net-new content.

## User-facing fix (one command)

```bash
chezmoi apply ~/.zlogin
ssh localhost   # now shows fastfetch-slim
```

Verify the rendered file:

```bash
grep '_motd_style=' ~/.zlogin
# Expected: _motd_style="${MOTD_STYLE:-fastfetch-slim}"
```

## Verification

```bash
# Before: stale ~/.zlogin
grep '_motd_style=' ~/.zlogin   # shows fastfetch-full

# Run apply
chezmoi apply ~/.zlogin

# After
grep '_motd_style=' ~/.zlogin   # now shows fastfetch-slim

# End-to-end: SSH and confirm slim output (figlet hostname + 7-line fastfetch summary, no Apple logo)
ssh localhost

# Sanity: docs strict build still produces no NEW warnings
uv run mkdocs build --strict 2>&1 | grep -c "^WARNING"
# Expected: same count as before this change (11 pre-existing, unrelated)
```

## Critical files

- `/Users/daviddwlee84/.local/share/chezmoi/docs/zsh/motd.md` — the only file edited
- `/Users/daviddwlee84/.local/share/chezmoi/dot_zlogin.tmpl` — reference only, already correct (defensive `index . "motdStyle" | default "figlet"` fallback works here)
- `/Users/daviddwlee84/.local/share/chezmoi/.chezmoi.toml.tmpl` — reference only, prompt declared correctly

## Non-goals

- NOT modifying `dot_zlogin.tmpl` (no bug in template).
- NOT adding any auto-apply hook or onchange watcher.
- NOT touching `.chezmoi.toml.tmpl` / `Dockerfile` / `dotfiles_init.py` / ansible role.
