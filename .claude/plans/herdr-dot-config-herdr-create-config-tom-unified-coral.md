# herdr config: document behavior model + small parity fixes + `create_`→`modify_`

## Context

Scope (per user, converged): **primarily document herdr's real behavior model**; do a **small
muscle-memory fix** (split keys); **no forcing of cwd/workspace behavior**; add a **documented
nesting-inside-tmux** section. Convert management to **`modify_`** so edits actually propagate.

**Verified this session (live herdr CLI + binary/embedded-config extraction + web):**

- herdr on both hosts (mac `/opt/homebrew/bin/herdr` v0.7.1; `david_ubuntu` via interactive SSH — earlier `NOT_ON_PATH` was a non-interactive-login PATH artifact). **Config byte-identical across hosts** (`diff`=0) — no chezmoi drift; any cross-host behavior gap is binary/version/run-mode, not config.
- **Real cwd/naming model** (from `herdr pane list`): every pane has **`cwd`** (shell startup dir, fixed) and **`foreground_cwd`** (live, tracked via **OSC7** shell integration). New tabs spawn at the **workspace root** (`$HOME` here), *not* the focused pane's cwd. Workspace label auto-follows the **root/primary pane's** live cwd basename (`cd` in tab 1 renames the space; other tabs don't). **User insight (correct, expected):** `cd` inside a **child process / subshell** (e.g. `chezmoi cd`) doesn't emit OSC7 up to herdr, so `foreground_cwd` — and thus the space's git-repo detection and `prefix+G` lazygit location — don't update. This is inherent to OSC7 tracking; **document, don't fix.**
- **`new_cwd` authoritative values** (embedded default-config comment): `follow` = inherit source pane/workspace (default); `home` = `$HOME`; `current` = **herdr's own process dir** (NOT the focused pane — my earlier `current` idea was wrong, dropped); or a fixed path. **No value yields "new tab in focused pane's live cwd"** — only an explicit `herdr tab create --cwd …` does.
- **Split keys:** herdr native splits are `prefix+v`/`prefix+minus`; our config binds only `split_vertical = "prefix+|"`, never tmux's `%`/`"`. herdr `[keys]` **accepts arrays** → one action can carry both.
- **Nesting (herdr inside tmux):** real known conflict — outer tmux eats `Ctrl+b`, inner herdr never sees its prefix ([discussion #759](https://github.com/ogulcancelik/herdr/discussions/759)). **Confirmed: this repo's tmux keeps tmux's default `bind -T prefix C-b send-prefix` (no override/unbind), so `Ctrl+b Ctrl+b` already forwards a literal `Ctrl+b` to inner herdr — zero config change needed.** Other levers: herdr `keys.prefix` is rebindable; herdr's own double-prefix sends a literal prefix; `herdr --remote <target> [--remote-keybindings local|server]` manages remotes natively without nesting; `allow_nested` (default false) is herdr-in-herdr only.
- **Why switch `create_`→`modify_`:** `create_` seeds once, so source edits never reach an already-seeded host without manual refresh (the "out of sync" cause). `modify_` overlay enforces our managed tables every apply while preserving herdr's runtime writeback. Precedent: `dot_codex/modify_config.toml.tmpl`. (Both hosts' live files currently have no `onboarding` line and match source → writeback minimal → low-risk.)

---

## Changes

### 1. Convert `create_` → `modify_` (TOML overlay)

- `git mv dot_config/herdr/create_config.toml dot_config/herdr/modify_config.toml.tmpl`; rewrite as an executable modify_ script (chezmoi pipes current target on stdin → script prints new contents).
- Desired config body (with comments) → **`.chezmoitemplates/herdr/config.toml`**, referenced `{{ template "herdr/config.toml" . }}` (mirrors codex's `.chezmoitemplates/agents/`).
- **Overlay model — template-as-base, pull-through unmanaged keys:** managed tables = `theme`, `ui`, `terminal`, `keys` (incl. `[[keys.command]]` AoT). Parse template with **tomlkit** (comments + array-of-tables; stdlib `tomllib` is read-only, codex's inline emitter can't do AoT); parse live stdin with `tomllib`; copy every top-level live key **not** in the managed set into the template (auto-preserves `onboarding`, `[session]`, `[remote]`, `[update]`, `[experimental]`). Emit `tomlkit.dumps`.
- Runtime guard like codex: `uv run --no-project --quiet --with tomlkit --python '>=3.11' python -` → `python3` → **fallback prints raw template** (not stdin: fresh host stdin is empty).

### 2. Split-key parity (fixes `prefix + %`) — the "small muscle-memory" fix

```toml
split_vertical   = ["prefix+|", "prefix+%"]        # side-by-side (left/right) = tmux -h
split_horizontal = ["prefix+minus", "prefix+\""]   # stacked (top/bottom)     = tmux -v
```

Validate tokens via `herdr server reload-config` diagnostics.

### 3. New-tab cwd — keep `follow`, fix comment; binding is **test-gated**

- Keep `new_cwd = "follow"`; **fix the misleading inline comment** to the authoritative semantics (drop "new panes inherit the focused pane's cwd").
- **Test 3a:** confirm whether `$HERDR_ACTIVE_PANE_CWD` (injected into `[[keys.command]]`) is the **live** `foreground_cwd` vs startup `cwd` — probe via a throwaway command binding + `herdr pane current`.
- **3b (conditional):** if live → optionally add a `[[keys.command]]` on `prefix+C` = `herdr tab create --cwd "$HERDR_ACTIVE_PANE_CWD" --focus` (native `prefix+c` unchanged). If not / user declines → document new-tab-cwd as a gap. (User chose "先實測再決定".)

### 4. Nesting inside tmux — **document only, no config change**

- `Ctrl+b Ctrl+b` already reaches inner herdr (tmux default `send-prefix` confirmed present). Document this as the recommended path (per user).
- In `herdr.md` add a "Running herdr nested inside tmux (multi-remote)" section covering the three solutions with trade-offs: (a) **double-prefix `Ctrl+b Ctrl+b`** [recommended, zero config], (b) rebind inner herdr `keys.prefix` (global cost), (c) prefer **native `herdr --remote`** + named sessions instead of nesting. Note the repo's `bind -n C-*` root-table bindings shadow inner-app Ctrl keys, so herdr's prefix+X actions are reached via double-prefix, and prefix-free direct-Ctrl herdr binds are not viable here. Cite [#759](https://github.com/ogulcancelik/herdr/discussions/759).

### 5. Full keybinding parity audit (user-requested earlier)

Refresh the tmux→herdr table in `herdr.md`. Implement the clear win (splits). Present these **optional** rows for the user to accept/skip; don't bake unasked:

| tmux | herdr action | verdict |
|---|---|---|
| `\|`/`-`/`%`/`"` | `split_vertical`/`split_horizontal` | **fix → arrays** |
| `W` kill window | `close_tab` (`prefix+shift+x`) | optional: `close_tab="prefix+shift+w"` |
| `H/J/K/L`+`M-hjkl` resize | `resize_mode` (modal `prefix+r`) | **gap** — document |
| `N` new session | `new_workspace` | optional bind |
| everything else (focus/zoom/kill-pane/swap/reload/rename/copy) | matching herdr defaults/rebinds | keep |

### 6. Docs (CLAUDE.md cross-file rules)

- `docs/tools/herdr.md` **+ `.zh-TW`**: (a) rewrite "Config writeback (why `create_`)" → `modify_`; (b) update Config bullet (~line 12); (c) **new "cwd & workspace-naming model" section** — two cwd fields, OSC7 tracking + the subshell/`chezmoi cd` caveat, new-tab spawn at workspace root, workspace label follows root pane, accurate `new_cwd` value table; (d) splits row → `|`/`%` and `-`/`"`; (e) new nesting section (change 4); (f) add resize-mode to Gaps.
- `docs/tools/chezmoi-prefixes.md` (~line 207): `create_config.toml` → `modify_config.toml.tmpl` (2nd `modify_` TOML precedent).
- `README.md` (~line 258) if it names the prefix; `CLAUDE.md` prefix-semantics note (minor).

---

## Verification (validate-with-the-app invariant)

1. `chezmoi cat ~/.config/herdr/config.toml` → managed tables + comments intact; fake stdin `onboarding = false` preserved; empty stdin → full template.
2. `chezmoi apply ~/.config/herdr/config.toml` → live file updates every run.
3. `herdr server reload-config` → `diagnostics`: no collisions / no parse error on arrays + `new_cwd`.
4. Splits: `prefix+%`→L/R, `prefix+"`→stacked, `|`/`-` still work.
5. New-tab cwd: run test 3a; act per 3b.
6. Nesting: from inside tmux, launch herdr, press `Ctrl+b Ctrl+b c` → confirm inner herdr new-tab (proves passthrough).
7. TOML lint: `uv run --with tomlkit python -c "import tomllib;tomllib.load(open('$HOME/.config/herdr/config.toml','rb'))"`.

## Out of scope / follow-ups
- Stat-gating herdr config on binary presence (`.chezmoiignore.tmpl`).
- Cross-host binary/version/run-mode discrepancy (config already in sync).
- Workspace auto-naming behavior change (documented only).
