# herdr — "copy focused pane" shortcuts + Quick Actions

## Context

herdr (the Rust terminal multiplexer / AI-agent orchestrator this repo ships as a
tmux-coexisting trial tool) exposes rich per-pane data over its socket CLI, but
there's no one-keypress way to grab that data onto the clipboard. The user wants
three (now four) copy operations for the **currently focused pane**, reachable
both as dedicated keyboard shortcuts and from herdr-plus's **Quick Actions**
fuzzy launcher:

1. Copy the pane's **process info** (what's actually running in it).
2. Copy the pane's **coordinate** — session → workspace(space) → tab → pane, in a
   form you can paste back into the herdr CLI to re-target the pane.
3. Copy the pane's **full content** — both a *visible-screen* variant and a
   *full-scrollback* variant (user chose "add both").
4. All of the above also surfaced as herdr-plus **Quick Actions**.

Everything needed already exists; this is glue, not new capability:
- `herdr pane process-info` / `herdr pane get` / `herdr pane read` supply the data.
- The repo's own `x copy` (`dot_dotfiles/bin/executable_x`, on PATH at
  `~/.dotfiles/bin/x`) is the clipboard sink — auto-picks pbcopy/wl-copy/xclip/
  xsel/OSC52, so it works on the desktop and over SSH.
- `dot_config/herdr/executable_review-mark.sh` is the exact pattern to copy: a
  small POSIX helper that takes a pane id, shells out to the herdr CLI, and is
  wired into a `[[keys.command]]` binding via `$HERDR_ACTIVE_PANE_ID`.

## Confirmed decisions

- **Surfaces**: both dedicated keybindings **and** Quick Actions entries.
- **Format**: distilled human-readable text (not raw JSON).
- **Content**: two variants — visible screen **and** full scrollback.

## Design

One helper script drives all four ops; two wiring surfaces call it.

### 1. New helper — `dot_config/herdr/executable_pane-copy.sh`

POSIX `sh`, same header/error style as `executable_review-mark.sh`.

```
usage: pane-copy.sh process|coord|content [PANE_ID] [--source visible|recent]
```

- **Pane resolution**: use `PANE_ID` arg if non-empty; otherwise fall back to
  `herdr pane current` → `jq -r .result.pane.pane_id`. (Keybindings pass
  `$HERDR_ACTIVE_PANE_ID`; Quick Actions pass `$HERDR_PLUS_PANE_ID`; either can be
  empty in edge cases, hence the fallback.)
- **Clipboard sink**: pipe the built text to `x copy`. Resolve `x` robustly since
  a herdr command-pane / quick-action pane may run via `sh -c` without the
  interactive PATH: try `command -v x`, else `$HOME/.dotfiles/bin/x`. Guard
  `command -v herdr` and `jq` up front like review-mark.sh does.
- **`process`** — from `herdr pane process-info`, emit a distilled block: one line
  per `foreground_processes[]` entry showing `cmdline`, `pid`, `cwd`, plus a
  header line with the pane id and `shell_pid`.
- **`coord`** — from `herdr pane get` (`workspace_id` / `tab_id` / `pane_id`),
  `herdr workspace get` + `herdr tab get` for best-effort labels, and the session
  name resolved by matching `$HERDR_SOCKET_PATH` against
  `herdr session list --json` (fallback `default`). Emit a paste-ready block:
  ```
  session=default
  workspace=w5 (chezmoi)
  tab=w5:t3 (…)
  pane=w5:p3
  socket=/home/daviddwlee84/.config/herdr/herdr.sock
  # herdr pane get w5:p3
  ```
  The `socket=` line documents how the CLI targets a non-default session (there is
  **no `--session` flag** on the `pane`/`tab`/`workspace` subcommands — session is
  selected only via `HERDR_SOCKET_PATH`; confirmed in exploration).
- **`content`** — `herdr pane read <pane> --source <visible|recent> --format text`
  piped straight to `x copy`. Default `--source recent`.
- Print a one-line confirmation to stdout (e.g. `copied process info for w5:p3`) so
  the transient command-pane shows feedback before closing.

### 2. Keybindings — `.chezmoitemplates/herdr/config.toml`

Add four `[[keys.command]]` entries (managed body; **not** the `modify_` script).
Proposed keys — validated for collision against herdr defaults during testing via
the which-key overlay, adjusted if any clash:

| Key | Action |
|---|---|
| `prefix+P` | `pane-copy.sh process "$HERDR_ACTIVE_PANE_ID"` |
| `prefix+L` | `pane-copy.sh coord "$HERDR_ACTIVE_PANE_ID"` (L = location) |
| `prefix+V` | `pane-copy.sh content "$HERDR_ACTIVE_PANE_ID" --source visible` |
| `prefix+B` | `pane-copy.sh content "$HERDR_ACTIVE_PANE_ID" --source recent` (B = buffer) |

Each `type = "pane"` with a `description`, matching the existing lazygit /
review-mark entries.

### 3. Quick Actions — new `quick-actions/` dir under the herdr-plus config

Mirror the existing `dot_config/herdr/plugins/config/cloudmanic.herdr-plus/projects/`
managed file with a sibling `quick-actions/` dir holding four plain managed TOMLs
(herdr-plus doesn't rewrite these, so no `create_`/`modify_` needed):

- `copy-pane-process.toml` → `command = "~/.config/herdr/pane-copy.sh process \"$HERDR_PLUS_PANE_ID\""`
- `copy-pane-coord.toml` → `... coord ...`
- `copy-pane-visible.toml` → `... content ... --source visible`
- `copy-pane-scrollback.toml` → `... content ... --source recent`

Each is `name = "Copy pane: …"` + `command = …` (default `command` type). The
`$HERDR_PLUS_PANE_ID` env var (exported by herdr-plus from the focused pane) is the
pane target.

## Files

- **New**: `dot_config/herdr/executable_pane-copy.sh`
- **New**: `dot_config/herdr/plugins/config/cloudmanic.herdr-plus/quick-actions/{copy-pane-process,copy-pane-coord,copy-pane-visible,copy-pane-scrollback}.toml`
- **Edit**: `.chezmoitemplates/herdr/config.toml` (+4 `[[keys.command]]`)
- **Edit (docs, required by CLAUDE.md)**: `docs/tools/herdr.md` + `docs/tools/herdr.zh-TW.md`
  — document the four copy shortcuts, the Quick Actions, and the `pane-copy.sh`
  helper (extend the existing keybinding/helper sections).

## Out of scope (optional follow-ups)

- Shell-function aliases (`hpcopy`/…) in `dot_config/shell/24_herdr.sh` — the user
  asked for herdr shortcuts + Quick Actions, not shell verbs. Note as a follow-up.
- No shell-completion files: `pane-copy.sh` is a herdr helper (like
  `review-mark.sh`), not a `dot_dotfiles/bin` CLI, so the Section-F completion rule
  doesn't apply.

## Verification

1. `chezmoi diff` then `chezmoi apply` (deploys the helper, config overlay, and
   quick-action TOMLs).
2. Reload herdr config in place: `herdr server reload-config`.
3. **Keybindings**: from a focused pane, press `prefix+P` / `prefix+L` /
   `prefix+V` / `prefix+B`; after each, run `x paste` (or paste into an editor) and
   confirm the distilled text matches the pane. Confirm the which-key overlay shows
   the four descriptions and no key collides with a herdr default.
4. **Direct CLI check** of the helper against a known pane id, e.g.
   `~/.config/herdr/pane-copy.sh coord w5:p3 && x paste` — verify the
   session/workspace/tab/pane block and that `herdr pane get w5:p3` (from the copied
   comment) round-trips.
5. **Quick Actions**: `prefix+y` → the four "Copy pane: …" entries appear and each
   copies the focused pane's data (validates `$HERDR_PLUS_PANE_ID` + PATH-robust `x`).
6. Edge case: run a copy action with an empty pane arg to confirm the
   `herdr pane current` fallback works.
7. `uv run mkdocs build --strict` — docs changes pass (nav already lists herdr).
