# Surface `hvibe`/`hcode` inside herdr's UI (keybinding / tv / Projects)

**Status**: P? — follow-ups to the shipped `hvibe`/`hcode` (2026-07), not spiked
**Effort**: S (keybinding) / S–M (tv action) / S (Projects TOML)
**Related**: `dot_config/shell/24_herdr.sh` (`hvibe`/`hcode`), `dot_config/herdr/create_config.toml`, `dot_config/television/cable/herdr-sesh.toml`, [docs/tools/herdr.md](../docs/tools/herdr.md) → "Session helpers"

## Context

`hvibe`/`hcode` currently launch by *typing* the command in a shell. These follow-ups surface the whole-pack layout from **inside herdr's UI** so you don't have to drop to a prompt. All three are additive and independent — pick whichever earns its keep.

Custom herdr commands receive `$HERDR_SOCKET_PATH`, `$HERDR_ACTIVE_PANE_ID`, `$HERDR_ACTIVE_PANE_CWD` and run from the focused pane's cwd — that's the hook for passing "the current project dir" into `hvibe`.

## Option A — keybinding in `create_config.toml`

Bind e.g. `prefix+alt+v` → `hvibe`, `prefix+alt+c` → `hcode`:

```toml
[[keys.command]]
key = "prefix+alt+v"
type = "pane"      # temporary pane, closes when the command exits
command = "hvibe -p \"$HERDR_ACTIVE_PANE_CWD\""
```

Design calls / caveats:
- `type="pane"` opens a **tiling split**, not a floating popup (herdr issue [#785](https://github.com/ogulcancelik/herdr/issues/785) — centered float for `[[keys.command]]` is *not planned*; only plugins get `--placement overlay`). The launcher pane is short-lived (hvibe creates + focuses a new workspace, then the launcher pane closes), so the transient split is tolerable — verify it doesn't leave a stray pane behind.
- `hvibe` resolves the git root from `$HERDR_ACTIVE_PANE_CWD`; if that pane isn't in a repo, hvibe errors (by design). Consider a `type="pane"` so the error is visible before the pane closes.
- Pick keys that don't collide — `prefix+shift+*` is reserved by herdr built-ins; `prefix+alt+*` is free (same rule as the tmux side). Run `herdr server reload-config` and check `diagnostics` for collisions.
- Aliases don't expand in non-interactive shells — bind the **function name** `herdr-vibe` (or `hvibe` only if the command runs through an interactive `$SHELL -lc`). Safer: `command = "zsh -lic 'hvibe -p \"$HERDR_ACTIVE_PANE_CWD\"'"` or call `herdr-vibe` directly.

## Option B — tv `herdr-sesh` channel action

The `herdr-sesh` channel's `dir` rows (zoxide frecency) currently Enter → `herdr workspace create --cwd <dir> --focus` (empty workspace). Add a second keybinding (e.g. `Ctrl+V`) that runs `hvibe -p "$ref"` on the selected dir instead — one keystroke from "pick a project" to "full pack". Mirror an `hcode` variant on another key if wanted.
- Edit `[keybindings]` + a new `[actions.vibe]` block in `dot_config/television/cable/herdr-sesh.toml` (dispatch on `kind==dir`).
- Keep the existing Enter (empty workspace) for the "just cd there" case.
- Cross-check the tmux-side `sesh` channel doesn't need the mirror (it uses `svibe`, separate).

## Option C — herdr-plus Projects static TOML

For a **fixed** per-repo layout, add a `~/.config/herdr-plus/projects/<repo>.toml` (chezmoi-managed under `dot_config/herdr/plugins/config/cloudmanic.herdr-plus/projects/`) with explicit tabs/panes — launch via the Projects picker (`prefix+O`). Lowest value: static, no parametric agent count, and `hvibe` already covers the dynamic case. Only worth it for a repo whose layout never varies (e.g. a fixed dev-server + logs + editor set that `hcode`/`hvibe` don't model).

## Recommendation

Ship **A** first (smallest, highest daily payoff — "open the pack" on a hotkey from any pane), then **B** if the zoxide-dir → pack flow gets used. Skip **C** unless a fixed-layout repo actually shows up.
