# Herdr — Rust terminal multiplexer + AI-agent orchestrator (trial)

[ogulcancelik/herdr](https://github.com/ogulcancelik/herdr) is a Rust terminal multiplexer with **built-in coding-agent awareness** (it tracks per-pane agent state: idle / working / blocked / done). It sits in the same niche as tmux/zellij but is mouse-first and agent-native. Docs: <https://herdr.dev/docs/>.

This repo ships herdr as a **trial tool that coexists with tmux** — you run `herdr` *or* `tmux`, never nested. Nothing about the existing tmux / `sesh` / `tmuxp` / workmux setup changes; herdr is purely additive so you can evaluate it without losing your daily driver.

- **Install**:
  - **Both platforms** — GitHub release **single static binary** (`herdr-{linux,macos}-{x86_64,aarch64}`) into `~/.local/bin/herdr`, managed by the `# --- herdr ... ---` block in `dot_ansible/roles/devtools/tasks/main.yml`. No tarball, so no unarchive step.
  - macOS is **deliberately not** Homebrew, and it is the only tool in this repo where that's true. Upstream disables `herdr update` on Homebrew/mise/Nix installs because the package manager owns the binary — which removes the *only* pane-preserving upgrade path and leaves a server restart, i.e. killing every pane process, as the sole option. The formula was dropped in favour of the release binary so macOS gets `--handoff` too. Boxes provisioned before the switch are migrated by a one-time `brew uninstall herdr` in the same role (leaving both installed would put two binaries on `PATH` and risk a client/server `protocol_mismatch` against yourself).
- **Verify**: `herdr --version` · validate config with `herdr server reload-config`
- **Upgrade**: `just upgrade-herdr` (→ `herdr update --handoff`) on both platforms — **run it from outside herdr**, see below

> **`herdr update` refuses to run from inside a herdr pane.** The handoff replaces the server process that owns the pane you are typing in, so it fails closed:
>
> ```console
> $ herdr update --handoff          # from a pane inside herdr
> update failed: run `herdr update` outside herdr after detaching from the session
> ```
>
> The flow is **detach (`prefix+q`) → run it in a plain terminal → reattach with bare `herdr`**. Detaching does not kill anything (client close ≠ session loss), and `--handoff` then swaps the server without exiting pane processes — verified 2026-07 upgrading 0.7.1 → 0.7.5 with a Claude Code session running in a pane, which survived uninterrupted. `just upgrade-herdr` encodes this: it *skips with instructions* rather than failing when it detects `HERDR_ENV`/`HERDR_PANE_ID`, so `just upgrade-all` from a herdr pane doesn't die here. Full trace: [`pitfalls/herdr-update-handoff-refuses-inside-pane.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/herdr-update-handoff-refuses-inside-pane.md).

> **Install is version-blind; upgrades are yours to run.** The Linux ansible task gates on `herdr --version` returning non-zero — *"is it installed at all"*, not *"is it current"* — so a fresh box gets whatever is latest that day and `chezmoi apply` never touches it again. This is the repo's [install-vs-upgrade split](../this_repo/upgrades.md) working as designed, but herdr drifts faster than most because its config can outrun the binary (a `[[keys.command]]` using `type = "popup"`, added in 0.7.4, makes an older herdr reject **the entire keys block** — `reload-config` reports `status: "partial"` + `keeping current keys settings`, and only that one diagnostic line tells you).

> **Every herdr upgrade stales the agent integrations.** `herdr integration status` versions each one (`current (v9)` / `outdated (v7 < v9)`); reinstall with `herdr integration install <agent>`. These files (`~/.claude/hooks/herdr-agent-state.sh`, `~/.codex/herdr-agent-state.sh`, `~/.cursor/herdr-agent-state.sh`, `~/.config/opencode/plugins/herdr-agent-state.js`) are written by herdr and are **not** chezmoi-managed, so `chezmoi apply` will not restore or clobber them. `just upgrade-herdr` reports which went stale but deliberately does not auto-install them.
- **Config**: `~/.config/herdr/config.toml` — chezmoi **`modify_` overlay** (`dot_config/herdr/modify_config.toml.tmpl` + managed body in `.chezmoitemplates/herdr/config.toml`). The overlay enforces our managed tables on every `chezmoi apply` while preserving whatever herdr writes back at runtime (see [Config management](#config-management-why-modify_)).

> **Why a package-managed herdr strands its own server — the reason macOS left Homebrew.** herdr's socket API is protocol-versioned, and a package-manager upgrade cannot restart the server, so after `brew upgrade herdr` every CLI call (and therefore every `tv herdr-*` channel, `hvibe`/`hcode`, and `[[keys.command]]` helper) fails `protocol_mismatch` until the server restarts — which kills all pane processes. `herdr update --handoff`, the live pane-preserving path, is **disabled on Homebrew/mise/Nix installs**, so a brew-installed herdr has no way to avoid that restart. This repo now installs the self-managed release binary on macOS too, which is what closes the gap; the pitfall below is kept because it still describes what happens on any box that has not been migrated (and `just upgrade-herdr` skips with instructions when it detects a package-managed install). Check with `herdr status` (`compatible:` / `restart_needed:`), not `herdr --version`. Full recovery matrix: [`pitfalls/herdr-brew-upgrade-strands-running-server.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/herdr-brew-upgrade-strands-running-server.md).

> **Not gated by `enableVimMode`.** That flag governs shell + tmux modal editing; herdr's copy mode (`prefix+[`) is vi-style natively regardless (`h/j/k/l`, `w/b/e`, `{`/`}`, `v`/Space to select, `y`/Enter to copy, `q`/Esc to leave), so there is nothing to gate.

---

## Model differences vs tmux

herdr's hierarchy is **Session → Workspace → Tab → Pane** — one level deeper than tmux (Session → Window → Pane). A "Workspace" is a project-level container; a "Tab" groups panes. The CLI (`herdr session|workspace|tab|pane|agent …`, most with `--json`) is the scripting surface that replaces `tmux switch-client` / `list-sessions` etc.

The important twist vs tmux: a single herdr **server hosts multiple named sessions**, each its own persistent tree with its own socket. That top **Session** level is closer to "multiple tmux servers / sockets" than to a tmux session — the tmux thing you'd call a session (`vibe/<repo>`) maps to a herdr **Workspace**, not a herdr Session.

### Named sessions

- `herdr` — launch or attach the **default** session (socket `~/.config/herdr/herdr.sock`).
- `herdr --session NAME` — launch/attach a **named** session (socket `~/.config/herdr/sessions/<NAME>/herdr.sock`).
- `herdr session list [--json]` — all sessions with `running` + `socket_path`. **The `--json` `socket_path` is authoritative** — the plain-text table prints `herdr.socket`, but the real socket is `herdr.sock`.
- `herdr session attach NAME` · `herdr session stop NAME` · `herdr session delete NAME` (`default` is a valid `NAME` for stop).

**Targeting a session from the CLI subcommands**: there is **no `--session`/`--socket` flag** on `workspace`/`tab`/`pane`/`agent`. The only lever is the **`HERDR_SOCKET_PATH`** env var — set it to a session's `socket_path` and every subcommand routes there. Inside a herdr pane it is already exported to the current session's socket, so scripts run *inside* herdr target the current session for free. This is exactly how `hvibe --session NAME` works (see below).

## Search pane content with `herdr-grep`

Herdr can read one pane but has no native cross-pane grep. This repo deploys **`herdr-grep`**, which packages `pane list → pane read → rg` and prints the exact Session / Workspace / Tab / Pane containing each match:

```console
$ herdr-grep -F 'connection refused'
[session=default workspace=w1 tab=w1:t2 pane=w1:p4] 183:connection refused while opening socket
```

```bash
herdr-grep 'error|failed'                   # regex; current/default session
herdr-grep -F -i 'connection refused'       # literal, case-insensitive
herdr-grep --visible 'ready'                # current visible screens only
herdr-grep --source recent-unwrapped 'url'  # retained history without hard wraps
herdr-grep --session work 'panic'           # one running named session
herdr-grep --all-sessions 'rate limit'      # every running local session
herdr-grep --all-sessions --json 'panic'    # structured matches + errors
herdr-grep --pick 'error|failed'             # grep first, then fzf-pick and jump/attach
herdr-grep --pick --all-sessions 'panic'     # outside Herdr: pick, pre-focus, attach session
herdr-grep -F -- -leading-dash              # protect a pattern beginning with `-`
```

| Aspect | Behavior |
|---|---|
| Default scope | The ambient session when `HERDR_SOCKET_PATH` is set (inside Herdr); otherwise `default`. `--session NAME` resolves the authoritative socket from `herdr session list --json`; `--all-sessions` scans running sessions only. An ambient socket that cannot be mapped uniquely returns 2 rather than being mislabeled. |
| Content source | `recent` by default (full retained scrollback); `--visible` for the current screen; `--source recent-unwrapped` when terminal wrapping splits a phrase. |
| Output | Human output repeats `session/workspace/tab/pane` on every matching line. `--json` adds socket, cwd, agent state, byte-offset submatches, `complete`, and structured errors. Line numbers are **relative to this capture**, not persistent pane coordinates. |
| Interactive picker | `--pick PATTERN` sends the filtered matches to fzf. Enter exact-focuses the pane; outside Herdr it then attaches the selected session. Alt+S reruns the same pattern against `recent-unwrapped`; Alt+V returns to `visible`. |
| Exit status | `0` = match + complete scan; `1` = clean no-match; `2` = usage/error/**incomplete scan**. If a pane disappears mid-scan, good matches are preserved, the failure goes to stderr/JSON, and the command returns 2. |

Inside Herdr, **`prefix+Alt+F`** runs `herdr-grep --pick --visible`: type the grep pattern once, then use fzf to refine the already-filtered matches. Agent panes use Herdr's exact `agent focus`; ordinary split panes are reached through a validated shortest path of directional `pane neighbor` / `pane focus` calls, with final active workspace/tab plus `pane layout.focused_pane_id` verification. The picker refuses a different-session selection while already attached (detach first rather than nest). From a normal shell, `--pick --all-sessions` pre-focuses the selected target and then attaches its session, matching `hhere`'s focus-then-attach model. Preview line numbers refer to the earlier capture and may drift while the pane keeps printing.

The search is bounded by what the live Herdr server still retains: closed panes, output older than the history limit, and alternate-screen content already discarded cannot be recovered. The command runs where the Unix socket is accessible. For a remote server, run the deployed CLI through SSH, for example `ssh server 'herdr-grep --all-sessions -F -- "connection refused"'`; **`herdr --remote` is an interactive thin-client attach, not an RPC prefix for pane subcommands**.

`tv herdr-agent-panes` and `tv herdr-review` still fuzzy-search metadata only (pane/session identifiers, state, cwd). Their visible pane text is a preview and is not part of Television's searchable source. Television runs its source before—and cannot receive—the live query, so content selection deliberately uses `herdr-grep --pick` → fzf instead of a `tv herdr-grep` channel.

## cwd & workspace-naming model

herdr tracks cwd differently from tmux, which trips up two common expectations (all verified via `herdr pane list`):

- **Every pane has two cwds.** `cwd` = the shell's *startup* directory (fixed at spawn); `foreground_cwd` = the *live* cwd, tracked via **OSC 7** shell integration. A `cd` in the shell updates `foreground_cwd`; the startup `cwd` never changes.
- **`cd` inside a child process / subshell doesn't propagate.** Because tracking is OSC 7-based, a `cd` in a subshell that doesn't re-emit OSC 7 — e.g. `chezmoi cd`, which spawns a *new* shell in the source dir — is invisible to herdr. `foreground_cwd` stays put, so the space's git-repo detection and the `prefix+G` lazygit location don't follow the subshell. This is inherent to OSC 7, **not** a herdr bug — expected behavior.
- **New tabs follow the focused pane's live cwd (herdr ≥0.7.x).** With `new_cwd = "follow"` (below), a *new tab* inherits the focused pane's live cwd — same as a *split*. herdr [issue #912](https://github.com/ogulcancelik/herdr/issues/912) changed `follow` so tabs behave like splits; the older "new tab opens at the workspace root (often `$HOME`)" was treated as a bug and removed. There is **no `new_cwd` value** (and no workspace-level cwd — `herdr workspace get` exposes none) that opens a new tab at the workspace root; for that use **`prefix+C`** (below).
- **The workspace ("space") label auto-follows the root/primary pane's live cwd basename** (e.g. → `chezmoi`, `trading-journal`). `cd` in **tab 1** renames the space; `cd` in other tabs does not. No config knob controls this.
- **A relative `--cwd` is resolved by the SERVER, and a miss falls back to `$HOME` silently.** `herdr workspace create --cwd ../foo` joins `../foo` to the directory `herdr server` was launched from — *not* to your shell's `$PWD` — and when that path doesn't exist herdr returns `{"result":{"type":"ok"}}` with the pane opened at `$HOME`. No error, no warning. **tmux is the opposite**: `new-session -c ../foo` is resolved client-side, which is why the `shere`/`scode`/`svibe` originals never needed a guard and their herdr ports did. Any user-supplied path must be absolutized in the calling shell before it reaches the CLI — `24_herdr.sh` does this in `_herdr_abs_dir`. See [`pitfalls/hhere-p-relative-path-opens-workspace-at-home.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/hhere-p-relative-path-opens-workspace-at-home.md).

**`new_cwd` values** (`[terminal]`) — the CWD policy for new panes/tabs/workspaces when no explicit `--cwd` is given:

| value | meaning |
|---|---|
| `follow` (default) | inherit the **source** pane — for both a split *and* a new tab, the focused pane's live cwd (herdr ≥0.7.x) |
| `home` | `$HOME` |
| `current` | herdr's **own process** directory (NOT the focused pane) |
| `"~/path"` | a fixed path |

**No `new_cwd` value opens a new tab at the workspace ("space") root** — `follow` now tracks the focused pane, and herdr exposes no workspace-level cwd field. This repo ships that behavior as a keybind: **`prefix+C`** → `~/.config/herdr/new-tab-at-space-root.sh` (`dot_config/herdr/executable_new-tab-at-space-root.sh`), which derives the space root — the lowest-numbered tab's pane live cwd, i.e. what herdr uses for the space label — and runs `herdr tab create --workspace <wid> --cwd <root> --focus`. Native `prefix+c` **and the mouse "+" button** keep the follow-focused-pane behavior; a keybind cannot intercept the mouse button.

```toml
[[keys.command]]
key = "prefix+C"
type = "pane"
command = "~/.config/herdr/new-tab-at-space-root.sh \"$HERDR_ACTIVE_PANE_ID\""
description = "new tab at the workspace (space) root dir"
```

## Feasibility matrix (current tmux experience → herdr)

| Current capability | herdr story | How it's handled here |
|---|---|---|
| Catppuccin theme + light/dark | **Native** `[theme]` + `auto_switch` | Configured in `config.toml` |
| Splits / zoom / new tab+workspace / pane nav | **Native** `[keys]` actions | Rebound to tmux muscle memory |
| Session persistence (resurrect/continuum) | **Native** detach/reattach | Skipped — native |
| Mouse / right-click menus | **Native** mouse-first | Skipped — native |
| Agent status 🤖/💬/✅ (workmux, 6 files) | **Native** agent-state rollups in sidebar | Skipped — native (workmux untouched for tmux). Panel ordered as an **attention queue**, not grouped by space: `ui.agent_panel_sort = "priority"` (herdr's default is `"spaces"`) |
| `sesh` fuzzy switch + `tmuxp` layouts | **Plugin** [herdr-plus](https://github.com/cloudmanic/herdr-plus) Projects + Quick Actions | Plugin + Projects templates |
| `tv` channel popups (`prefix+T/U/a`) | **Custom command panes** (`[[keys.command]] type="pane"`) | Key bindings + 2 herdr-aware channels |
| lazygit / scratch popups | **Custom command panes** | Key bindings |
| URL picker (`prefix+u`, tmux-fzf-url) | **Custom command pane + helper** | `prefix+u` → `url-pick.sh` (fzf → `x open`); `--source recent` scans scrollback |
| File-path picker (`prefix+p`; extrakto `prefix+Tab` on tmux) | **Custom command pane + helper** | `prefix+p` → `path-pick.sh` — two-tier (exists-under-cwd first) → `x copy` |
| Search all pane content + jump | **CLI pipeline + fzf + exact-focus helper** | `prefix+Alt+F` → `herdr-grep --pick --visible`; Alt+S searches unwrapped scrollback |
| Seamless `Ctrl-hjkl` nvim↔pane nav | **No herdr-aware smart-splits** | **Gap** — workaround below |
| OSC133 copy-mode (`cpout`/`cpblock`) | tmux-specific | **Gap** — `cpcmd` (zsh history) still works |
| Per-window status glyphs + bookmarks ⭐📌 | Partial — `report-metadata --token` (per-pane metadata tokens, orthogonal to agent state) | **Review-pending flag** (`hmark`/`prefix+m` + `tv herdr-review` inbox); decorative status-bar glyphs still a gap (no format-string interpolation) |
| AI session-summary / agent-wakeup capture | re-portable against `herdr pane read` / `pane list --json` | **Deferred** — out of trial scope |

## Keybindings

Prefix is `ctrl+b` (same as tmux). Built-in actions can only be *rebound* (herdr's action set is fixed); everything else is a `[[keys.command]]` custom command. Custom commands receive `$HERDR_SOCKET_PATH`, `$HERDR_ACTIVE_PANE_ID`, `$HERDR_ACTIVE_PANE_CWD` and run from the focused pane's cwd.

> **Two families of herdr env vars.** The `HERDR_ACTIVE_PANE_*` vars above are injected **only** into `[[keys.command]]` invocations. Every shell *running inside a herdr pane* also gets an **ambient** set: `HERDR_ENV=1`, `HERDR_PANE_ID`, `HERDR_TAB_ID`, `HERDR_WORKSPACE_ID`, and `HERDR_SOCKET_PATH` (the current session's socket). Scripts use `HERDR_ENV` as the "am I inside herdr?" test and inherit `HERDR_SOCKET_PATH` to target the current session — that's what `hvibe`/`hcode` rely on.

| Key | Action | Type |
|---|---|---|
| `prefix + c` / `prefix + 1..9` | new tab / switch tab | built-in default |
| `prefix + C` | new tab at the workspace (**space**) root dir — `prefix+c` + mouse "+" stay follow-focused-pane | command pane |
| `prefix + h/j/k/l` | focus pane | built-in default |
| `prefix + \|` / `prefix + %` · `prefix + minus` / `prefix + "` | split side-by-side / stacked (tmux muscle memory — both the intuitive key and the tmux default) | rebound (arrays) |
| `prefix + z` / `prefix + x` | zoom / close pane | built-in default |
| `prefix + w` / `prefix + g` | workspace navigator (navigate-mode: **`j`/`k`** *or* arrows to move, Enter to pick) / session navigator ([in-popup keys](#navigator-keys)) | built-in; `navigate_workspace_*` rebound to `j`/`k` + arrows |
| `prefix + ctrl + 1..9` | jump directly to **workspace** N (`switch_workspace`) | rebound (indexed) |
| `prefix + alt + 1..9` | jump directly to **agent** N's pane (`focus_agent`) | rebound (indexed) |

> **Why ctrl/alt, not shift, for the indexed jumps**: under the Kitty keyboard protocol (which herdr uses) `shift+1` still carries the printable `!`, so herdr matches the symbol rather than `shift+1` — `prefix+shift+1..9` silently does nothing. `ctrl+digit` / `alt+digit` have no printable form and disambiguate cleanly.
| `prefix + [` | vi copy mode (`hjkl`, `w/b/e`, `{/}`, `v`, `y`) | built-in default |
| `prefix + q` | detach | built-in default |
| `prefix + ?` | keybinds help overlay — lists every active binding with labels (herdr's native which-key; manually invoked, not an auto-timeout hint) | built-in default |
| `prefix + ,` | rename tab | rebound (tmux muscle memory) |
| `prefix + shift + r` | reload config (`prefix + r` stays resize mode) | rebound |
| `prefix + shift + b` | new git worktree (moved off `prefix + shift + g`) | rebound |
| `prefix + G` | lazygit | command pane |
| `prefix + M` | btop system monitor | command pane |
| `prefix + N` | nvtop GPU monitor | command pane |
| `prefix + U` | `tv tools` (CLI launcher) | command pane |
| `` prefix + u `` | **URL picker** — fzf-pick a URL from the pane and open it (`x open`); tmux-fzf-url analog. `--source recent` = full scrollback | command pane |
| `prefix + T` | `tv herdr-sesh` (workspace/dir switcher) | command pane |
| `prefix + a` | `tv herdr-agent-panes` (live agent panes) | command pane |
| `prefix + f` | `tv fleet-hosts` (SSH picker) | command pane |
| `prefix + Alt + F` | prompt for pane-content pattern → `herdr-grep --pick --visible` → fzf exact jump; Alt+S = scrollback, Alt+V = visible | command pane |
| `prefix + m` | toggle **review-pending** flag (⭐) on the current pane | command pane |
| `prefix + i` | `tv herdr-review` — review-pending **inbox** (flagged panes) | command pane |
| `prefix + P` | copy focused pane's **process info** to the clipboard | command pane |
| `prefix + D` | copy focused pane's **coordinate** (session>space>tab>pane) | command pane |
| `prefix + V` | copy focused pane's **content** (visible screen) | command pane |
| `prefix + S` | copy focused pane's **content** (full scrollback) | command pane |
| `prefix + d` | copy the **workspace ("space") root dir** — the right-click "Copy dir" herdr doesn't have ([details](#copy-to-clipboard)) | command pane |
| `prefix + ctrl + d` | copy the focused pane's **live cwd** (the `pwd`/`abspath` answer) | command pane |
| `` prefix + p `` | **copy a file path** from the pane — two-tier fzf (paths that exist under the pane cwd on top), copies the resolved absolute path (`x copy`) | command pane |
| `` prefix + ` `` | scratch shell | command pane |
| `prefix + E` | **run any command** in the pane's cwd — fzf-pick from history or type it; the popup closes itself when the command exits ([details](#run-any-command)) | command **popup** |
| `prefix + O` | herdr-plus **Projects** (layout launcher) | plugin action |
| `prefix + y` | herdr-plus **Quick Actions** | plugin action |

> Uppercase letters resolve to `prefix+shift+<letter>`, which herdr reserves for built-ins (`shift+g` worktree, `shift+t` rename-tab, `shift+h/j/k/l` swap-pane). `prefix+G`/`prefix+T` are freed by the rebinds above; `herdr server reload-config` reports any remaining collisions in its `diagnostics`.

### Session navigator (`prefix + g`) — in-popup keys {#navigator-keys}

The navigator is herdr's Cmd-K analog: a `space → tab → pane` tree with fuzzy search and agent-state filters. Its footer only advertises `enter switch · / search · b/w/i/d/a states · j/k/↑↓ move · esc close`, but several keys are live and **undocumented upstream** (verified against herdr 0.7.5 `src/app/input/modal.rs`):

| Key | Effect |
|---|---|
| `space` | **toggle expand/collapse of the highlighted space** — fires only on a *space* row; silently no-ops on tab/pane rows |
| `ctrl + d` / `ctrl + u` | half-page down / up |
| `home` / `end` (or `G`) | first / last row |
| `backspace` | drop an active state filter (`b`/`w`/`i`/`d`) back to all |
| `a` | clear the query **and** the state filter |
| `esc` | closes the popup immediately (on ≤ 0.7.2 it cleared query + filter first and only closed on a second press) |

**Three limits that stop `space` from acting as a collapse-all** (`src/app/actions.rs`):

1. **Every open resets to fully expanded** — `open_navigator_from()` clears `expanded_workspaces` then re-inserts every workspace. Collapse state does not survive closing the popup.
2. **Any search query or `b`/`w`/`i`/`d` filter force-expands everything** (`expanded = query_kind != Empty || …`). Collapsing only has a visible effect under `a` / empty query.
3. **The navigator's expand set is separate from the sidebar's** `collapsed_space_keys` — the latter is what `~/.config/herdr/session.json` persists, driven by the sidebar's right-click `Expand` / `Close group` menu. Collapsing a space in one does not affect the other.

There is **no expand-all / collapse-all and no depth cap**. Upstream asks for both were closed unactioned under the issue-template policy (issues are bug-only): [#1256](https://github.com/ogulcancelik/herdr/issues/1256) (`ui.goto_depth = "workspace" | "tab" | "pane"`) and [#1255](https://github.com/ogulcancelik/herdr/issues/1255) (vim `h`/`l` to collapse/expand) → [discussion #1248](https://github.com/ogulcancelik/herdr/discussions/1248).

> **For a spaces-only overview, reach for `prefix + T`** (`tv herdr-sesh`) instead. It is a flat workspace list by construction — a permanent collapse-all view — and it can additionally *create* a space from a zoxide frecency dir, which the native navigator cannot. `prefix + w` is the other space-level option (native sidebar navigate mode) but has no fuzzy search.

## Session helpers: `hvibe` / `hcode` / `hhere` / `hroot` (herdr analogs of `svibe` / `scode` / `shere` / `sroot`)

Four shell functions in [`dot_config/shell/24_herdr.sh`](../shells/aliases.md#session-management) are the herdr counterparts of the tmux `svibe` / `scode` / `shere` / `sroot` helpers. The two **heavyweight** ones (`hvibe` / `hcode`) spin up a whole coding workspace in one motion; the two **lightweight** ones (`hhere` / `hroot`) just open a plain workspace at a directory and attach — no git repo, no agent layout. They shell out to the native `herdr workspace|tab|pane` CLI and **reuse the pure logic verbatim** (specstory wrapping, `--on-exit shell|kill|restart`, git-root resolution, agent-CLI detection) from `22_sesh.sh`; only the layout calls differ. Need the `herdr` server running + `jq`.

| Command | Builds workspace | Layout |
|---|---|---|
| `hvibe [N] [CLI]` / `hvibe --agents claude,codex,opencode` | `vibe/<repo>` | tab `agents` (N even-width agent panes) + tab `git` (lazygit) + tab `edit` (nvim) |
| `hvibe --tab-per-agent …` | `vibe/<repo>` | one tab **per agent** + `git` + `edit` tabs |
| `hcode [CLI]` | `coding-agent/<repo>` | tab `editor` (nvim 75% \| agent 25%) + tab `monitor` (btop) |
| `hhere [CMD...]` | `<basename $PWD>` | single tab, plain shell at `$PWD` (or `-p DIR`); optional `CMD` in the root pane |
| `hroot [CMD...]` | `<basename git-root>` | same as `hhere` but at the current git root (falls back to `$PWD`) |

- **The plain-open pair (`hhere` / `hroot`)** fills the gap where every other herdr entry point forces a git repo + a full agent layout. With tmux, `tmux new-session` lands you in `$PWD` directly; herdr adds a Workspace layer, so without these you'd launch herdr, create a space (which opens at `$HOME` per `new_cwd`), then `cd` by hand. `hhere` does the one-shot: `herdr workspace create --cwd "$PWD"` → focus → attach if outside. No git requirement; the optional command runs **raw** (no specstory/on-exit wrapping — that stays with `hcode`/`hvibe`). `hhere -h` / `hroot -h` for flags. **Label caveat**: herdr auto-relabels a workspace to its root pane's *live* cwd basename after a `cd` in tab 1 (see the **cwd & workspace-naming model** section above), so the idempotent-focus is best-effort — a drifted label makes a re-run open a fresh workspace. **`-p DIR` is absolutized in your shell** (via `_herdr_abs_dir`, shared with `hcode`/`hvibe`) before it reaches herdr, so relative paths like `hhere -p ../sibling` work and a typo'd DIR is a hard error instead of a silent workspace at `$HOME` — see the `--cwd` bullet in the cwd model section for why that guard exists.
- **Idempotent per repo**: re-running focuses the existing `vibe/<repo>` / `coding-agent/<repo>` workspace instead of duplicating (matches svibe's "attach if exists").
- **Attach-aware (like svibe's `$TMUX` branch)**: run from **inside** herdr → the workspace/tab focus calls switch the live client (no new client). Run from a **plain terminal outside** herdr → the helper brings up a client attached to the session so the new workspace is actually visible (herdr's `workspace focus` only moves an *already-attached* client, so without this the pack was built invisibly). `--no-attach` builds detached either way. Detection is the ambient `HERDR_ENV`.
- **`--session NAME`** targets a specific running herdr session (see [Named sessions](#named-sessions)). Default: the **current** session when inside herdr (via inherited `HERDR_SOCKET_PATH`), else the **default** session. The override is scoped with `local -x HERDR_SOCKET_PATH` so it never leaks into your shell. A `--session` that isn't running errors with a `herdr --session NAME` hint (start it first — hvibe won't spawn a server).
- **Agent visibility**: herdr tracks agent state **per pane**, so in the default splits layout every agent still surfaces individually in herdr's agent tracking (verified: two agents in one tab appear as two separate entries in `herdr agent list`). The compact left sidebar rolls a *tab's* status into one dot — use `--tab-per-agent` if you want each agent to own a tab-level status dot.
- **Even columns**: herdr has no `select-layout even-horizontal`, so `hvibe` sets each split's `--ratio` explicitly (`1/(N-m+1)`) to keep the agent panes even; `hcode` uses `--ratio 0.75` to give nvim 75%.
- Same flags as svibe/scode: `--on-exit`, `--no-specstory`, `--no-attach`, `-p/--path`, plus `--session NAME`; `hvibe` also takes `--min-width` / `--tab-per-agent` and honors `$HVIBE_MIN_WIDTH` / `$HVIBE_LAUNCH_STAGGER`. Full flag help: `hvibe -h` / `hcode -h`.

The tmux `svibe` / `scode` remain the tmux-side equivalents (see [sesh](sesh.md)); the two families coexist — `hvibe`/`hcode` only touch herdr, `svibe`/`scode` only touch tmux.

## herdr-plus plugin (sesh + tmuxp + menu analog)

[herdr-plus](https://github.com/cloudmanic/herdr-plus) adds **Projects** (declarative multi-tab/multi-pane workspace templates with a fuzzy picker — the `tmuxp`/`tmuxinator` analog) and **Quick Actions** (a fuzzy command launcher — the popup-menu analog).

**Install is automated** by the `devtools` ansible role (the `# --- herdr-plus plugin ---` block) — idempotent, runs on every `chezmoi apply`, skipped once installed. It shells out to:

```bash
herdr plugin install cloudmanic/herdr-plus   # manual fallback / what the role runs
```

`herdr plugin install` **downloads a prebuilt release binary when no Go toolchain is present**, so it works with or without Go. The one trap: if a *stale* Go is on `PATH` (e.g. an old `/usr/local/go` shadowing a newer one) herdr tries to build from source and fails (`invalid go version … must match format 1.23`) instead of falling back. The ansible task sidesteps this by prepending mise's Go (`mise which go` → its bin dir) when available; to fix it by hand, put a modern Go first: `PATH="$(dirname "$(mise which go)"):$PATH" herdr plugin install cloudmanic/herdr-plus`. (Go is mise-managed now, gated on `installExtraRuntimes`.)

Project templates are chezmoi-managed under `dot_config/herdr/plugins/config/cloudmanic.herdr-plus/projects/` → the same path under `~/.config/`. The shipped `chezmoi.toml` mirrors this repo's tmuxinator `chezmoi` session (editor/git/shell tabs). Bind `prefix+O` → Projects and `prefix+y` → Quick Actions (already in the config).

**Quick Actions** are chezmoi-managed alongside them, under `…/cloudmanic.herdr-plus/quick-actions/` (one TOML per action). The repo ships the six **copy** actions (see [Copy pane + space facts](#copy-to-clipboard)) plus the plugin's five **starter** examples (GitHub / Google / Search Google / Open Repo / Reveal Working Dir), adapted for Linux — macOS `open` → the repo's cross-platform [`x open`](../shells/aliases.md), and the repo-select points at `daviddwlee84/*`. Because this managed dir is non-empty, herdr-plus does **not** auto-seed those examples itself (it only seeds into an *empty* dir), which is why they're vendored here; delete any TOML you don't want. Add your own by dropping a TOML here, or ship a repo-local set in `<repo>/.herdr-plus/quick-actions/`.

> **Quick Actions are for one-off, non-interactive commands** (the shipped examples all `open <url>`). herdr-plus runs a chosen action via `sh -c` with no PTY and no interactive stdin, so an interactive TUI misbehaves — btop exits immediately, nvtop can't receive F10. For a TUI you want the lazygit-style *floating command pane* (`[[keys.command]] type="pane"`) instead — that's why **btop** (`prefix+M`) and **nvtop** (`prefix+N`) are keybinds, not Quick Actions.

## Television integration {#television-integration}

Most `tv` channels (`tools`, `fleet-hosts`, `mlflow`, `kill-process`, `ssh-config`) have **non-tmux-coupled actions**, so they run unchanged in a herdr command pane — just bind a key to `tv <channel>`. Only the channels whose actions call `tmux …` need herdr-aware variants. Three ship here:

- `herdr-sesh` (`dot_config/television/cable/herdr-sesh.toml`) — lists herdr sessions/workspaces + zoxide dirs; Enter dispatches `herdr session attach` / `herdr workspace focus` / `herdr workspace create --cwd` instead of `sesh connect` / `tmux switch-client`. `Ctrl+D` closes the selected workspace; **`Alt+Y` copies its directory** (works on workspace *and* zoxide-dir rows — see [`dir` vs `cwd`](#space-dir)). The preview shows that derived dir above the raw `workspace get` JSON, so you can see what `Alt+Y` will hand you.
- `herdr-agent-panes` (`dot_config/television/cable/herdr-agent-panes.toml`) — same source as `agent-panes`, but switch/kill use `herdr pane focus` / `herdr pane close`.
- `herdr-review` (`dot_config/television/cable/herdr-review.toml`) — the **review-pending inbox**: lists only panes carrying the ⭐ flag (a non-empty `tokens.review`). Enter focuses the pane's workspace/tab and **keeps** the flag; `Alt+C` focuses **and** clears it ("mark read"). Bound to `prefix+i`. See the **Review-pending flag** section below.

The original tmux-bound `sesh` / `agent-panes` channels are left intact for coexistence.

> **`mode = "execute"`, not `"fork"`, for the Enter action of a channel bound to a command pane.** A `type = "pane"` binding only vanishes when its command exits, and tv exits after an `execute` action but stays alive after a `fork` one — so a `fork` Enter leaves the picker pane hovering over the workspace you just focused. `herdr-sesh`'s `[actions.open]` is `execute` for exactly this reason; its `ctrl-d` (`close_ws`) keeps `fork` because it pairs with `reload_source` and tv must survive to redraw the list. Same trade-off applies to `herdr-agent-panes` / `herdr-review`, which are still `fork` (their Enter re-focuses without leaving the picker — deliberate for triage, change it if you want one-shot jumps).

## Agent state (replaces the 6-file workmux integration)

herdr detects agent state natively and rolls it up into the sidebar (a blocked agent marks its pane/tab/workspace). Claude Code is detected via **screen-manifest heuristics** (terminal title + OSC progress), not lifecycle hooks. If the heuristics prove insufficient, state can be pushed explicitly:

```bash
herdr pane report-agent w1:p1 --agent claude --state working
```

For the trial we rely on native detection — the tmux-side workmux 🤖/💬/✅ system (Claude/OpenCode hooks → `@workmux_status`) is untouched and only applies under tmux.

### Optional agent integrations (the onboarding "install" button)

herdr's first-run onboarding offers to **install optional agent integrations** (`herdr integration install <agent>`), so agents report state directly instead of relying on screen heuristics. Pressing *install* sets these up for every detected agent. What it writes (verified on this machine):

| Agent | What `herdr integration install` creates | Touches a repo-managed file? |
|---|---|---|
| claude | `~/.claude/hooks/herdr-agent-state.sh` **+ a hook entry in `~/.claude/settings.json`** | Yes — but the repo's hook-aware `modify_settings.json.tmpl` merger **preserves** it (same as it does for CodeIsland). `chezmoi apply` is a no-op; it won't strip the herdr hook. |
| codex | `~/.codex/herdr-agent-state.sh` only | No — `~/.codex/config.toml` is untouched (identical to the chezmoi-computed target). |
| opencode | `~/.config/opencode/plugins/herdr-agent-state.js` (separate plugin) | No — only `workmux-status.ts` is managed; herdr's plugin coexists. |
| cursor | `~/.cursor/herdr-agent-state.sh` + hook | Script lives outside chezmoi; coexists. |

These integration files are **not** vendored into the repo, so they do **not** reproduce on other machines (press *install* again there, or skip onboarding). They use herdr's own socket and do not interfere with tmux/workmux (different mechanism). To remove: `herdr integration uninstall <agent>` — and for **claude**, rerun `chezmoi apply` afterwards so the merger drops the now-removed hook from `settings.json`.

### Config management (why `modify_`)

herdr can rewrite `~/.config/herdr/config.toml` at runtime — finishing onboarding prepends `onboarding = false`, and the in-app *settings* popups (theme / sound / toasts / pane labels) persist there on *apply*. It edits in place and keeps existing comments, but it owns the file at runtime.

This file was originally seeded once with the `create_` prefix so `chezmoi apply` wouldn't clobber that writeback. The cost: **repo edits never reached an already-seeded machine** — split-key rebinds and comment fixes made in the source silently never arrived without a manual `cp … source-path` refresh. That is the real reason a host could feel "out of sync" while `chezmoi diff` showed clean (the diff was clean *because* `create_` never re-touches the file). Note this is independent of hosts: `chezmoi diff` of the source against each host's live file can be byte-identical yet a repo edit still won't land until you refresh.

It is now a **`modify_` overlay** — `dot_config/herdr/modify_config.toml.tmpl`, a small script that:

- uses the managed body in `.chezmoitemplates/herdr/config.toml` as the base (comments + tmux-parity rationale), enforcing the `[theme]` / `[ui]` / `[terminal]` / `[keys]` tables on every apply, and
- **pulls through every other top-level key** the live file has (`onboarding`, `[session]`, `[remote]`, `[update]`, `[experimental]`, …) so herdr's runtime writeback survives.

TOML has no `jq`, so the merge runs in Python via `uv run --with tomlkit` (tomlkit round-trips comments **and** the `[[keys.command]]` array-of-tables; stdlib `tomllib` is read-only and the codex `modify_` emitter can't emit AoT). It degrades to system `python3`, then to emitting the raw managed template, so a fresh host without Python still gets a full config. Second TOML-overlay precedent alongside `~/.codex/config.toml` (`dot_codex/modify_config.toml.tmpl`).

To change herdr's managed config, edit `.chezmoitemplates/herdr/config.toml` and `chezmoi apply` — it now reaches every host. Validate with `herdr server reload-config` (reports keybind collisions in its `diagnostics`; an empty `diagnostics` array + `"status":"applied"` means the config — including array key bindings — parsed clean).

## Persistence & restore (accidental close)

Two native layers, no plugin needed:

- **Client/terminal close ≠ session loss.** herdr runs a persistent **server** (named session `default`, socket `~/.config/herdr/herdr.sock`). Closing the terminal window just detaches — workspaces/tabs/panes and their running processes stay alive. Reattach with bare `herdr` (or `herdr session attach default`); `herdr session list` shows it `running`. This is tmux detach/reattach, built in.
- **Full server restart / reboot / crash.** `[session]` in the config exposes `resume_agents_on_restore = true` — resumes supported AI-agent panes back into their *native conversation sessions* after a server restart (requires the official `herdr integration install <agent>` hooks) — plus an option to save recent pane screen history across restarts. This covers the tmux-resurrect/continuum case natively, gated on those keys + integrations.

## Remote sessions (`herdr --remote`)

herdr can run a **local thin client attached to a herdr server on another host over SSH**:

```bash
herdr --remote <ssh-target> [--session NAME] [--handoff]
herdr --remote local_ubuntu          # <ssh-target> is any host/alias from ~/.ssh/config
```

What it does (from <https://herdr.dev/docs/remote>):

- SSHes to `<ssh-target>`, detects the remote platform, and **auto-installs a matching herdr server binary there** — the remote does **not** need herdr pre-installed (it does need SSH access + permission to install/run a binary).
- Bridges your **local clipboard** (including image paste) to the remote server and keeps your **local keybindings** (`--remote-keybindings server` to use the server's instead).
- `--session NAME` picks/creates a named session on the remote; `--handoff` opts into live handoff.

**Config** — the `[remote]` block in `config.toml`:

- `manage_ssh_config = true` (default) — herdr runs the bridge SSH through a generated config that includes your `~/.ssh/config` first and adds `ServerAliveInterval`/`ServerAliveCountMax` so idle NAT/network timeouts don't drop the session. Set `false` to run plain SSH against your config unchanged.
- `remote_image_paste` (`[keys]`) — raw-key image-paste binding, active only under `--remote`.

**Troubleshooting `remote platform detection failed: Connection closed by <host> port 22`**: this is a **transient SSH-level close**, not a herdr config problem. Verify the SSH path herdr uses actually works, then just retry:

```bash
ssh -o BatchMode=yes -o ConnectTimeout=5 <ssh-target> 'uname -sm'   # should print e.g. "Linux x86_64"
```

If plain SSH works, retry `herdr --remote <ssh-target>`; if it keeps failing, check `~/.config/herdr/herdr-client.log` / `herdr.log` right after the failure. Common real causes: SSH auth needing an interactive prompt the bridge can't answer, or sshd rate-limiting rapid connections (`MaxStartups`).

## Running herdr nested inside tmux (multi-remote)

The repo's default stance is herdr **or** tmux, not nested. But you can deliberately nest — tmux as the outer window manager with several inner herdr clients, some local and some `herdr --remote <host>` to different servers. The catch is the **prefix collision**: both default to `Ctrl+b`, so outer tmux swallows it and inner herdr never sees its prefix ([herdr #759](https://github.com/ogulcancelik/herdr/discussions/759)).

Three ways to resolve it, in order of preference here:

1. **Double-prefix passthrough (recommended, zero config).** tmux keeps its default `bind -T prefix C-b send-prefix` (confirmed present in this repo — not overridden), so **`Ctrl+b Ctrl+b`** forwards a literal `Ctrl+b` to the inner herdr; its prefix bindings then work normally (`Ctrl+b Ctrl+b c` = inner new tab). No herdr or tmux change needed — classic tmux-in-tmux muscle memory.
2. **Rebind the inner herdr prefix.** Set `keys.prefix` (e.g. `"ctrl+a"` / `"ctrl+space"`) so the inner herdr uses a non-colliding prefix — one keystroke instead of the double-tap. Cost: it changes herdr's prefix even when run standalone (no longer matching tmux's `Ctrl+b`).
3. **Don't nest — use herdr's native remoting.** `herdr --remote <target> [--remote-keybindings local|server]` runs a local thin client against a remote herdr server without tmux in the middle, and herdr hosts multiple named sessions itself. For a pure "multiple remotes" need this is often cleaner than nesting; `--remote-keybindings local` (default) keeps your local keymap, `server` uses the remote's.

Notes: this repo's tmux uses many root-table `bind -n C-*` bindings that **shadow** inner-app `Ctrl` keys, so herdr's prefix-free *direct* terminal shortcuts aren't reliable under tmux — reach herdr actions through its prefix (via 1 or 2). herdr's own `allow_nested` (config, default `false`) governs herdr-inside-**herdr** only (detected via `HERDR_ENV`), not herdr-inside-tmux.

## Review-pending flag (mark-unread / ⭐)

The tmux setup has a per-window bookmark (`@bookmark_status` + `toggle-bookmark.sh`, rendered via `#{?@bookmark_status,…}`). herdr has **no `#{@option}` status-bar interpolation**, so that exact mechanism doesn't port — but the *use case* that actually matters here does: **"the agent finished (`done`) but I haven't reviewed it yet."** herdr collapses a `done` pane to `idle` the moment you peek in, losing the only signal that it still needs attention.

The fix uses herdr's **per-pane metadata tokens**, which are orthogonal to native agent detection:

```bash
herdr pane report-metadata <pane> --source review --token review="⭐ REVIEW"   # set (persistent — no --ttl-ms)
herdr pane report-metadata <pane> --source review --clear-token review         # clear
```

Verified: a pane can carry `tokens.review = "⭐ REVIEW"` while `agent_status:"idle"` — so peeking in does **not** wipe the flag (the whole point). `herdr pane get` surfaces the `tokens` map and `herdr pane list` (native JSON — **no** `--json` flag) lets the inbox enumerate flagged panes, so there is **no sidecar file**; herdr itself is the source of truth. Presence of the token *is* the flag, so the glyph text is free-form.

> **herdr ≥ 0.7.4 only, and the token needs a row layout to be visible.** 0.7.4 replaced `--custom-status` / the flat `custom_status` field with this namespaced token map — a silent removal, not listed as a breaking change. Two consequences: on older herdr the helper dies with `unknown --custom-status`, and unlike `custom_status` a token is rendered **only** where a sidebar row layout names it. That is why `.chezmoitemplates/herdr/config.toml` pins `[ui.sidebar.agents] rows` with `"$review"` appended to herdr's default first row — drop that and the flag still works through `prefix+i`, but the ⭐ disappears from the sidebar. See [`pitfalls/herdr-0.7.4-drops-custom-status.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/herdr-0.7.4-drops-custom-status.md).

Surfaces (all sharing one script, `~/.config/herdr/review-mark.sh` = `dot_config/herdr/executable_review-mark.sh` — the analog of tmux's `toggle-bookmark.sh`):

| Surface | Action |
|---|---|
| `hmark` / `hunmark` (aliases in `dot_config/shell/24_herdr.sh`) | set / clear on the current pane (ambient `$HERDR_PANE_ID`), or pass a pane id |
| `prefix+m` | toggle the flag on the focused pane (uses `$HERDR_ACTIVE_PANE_ID`) |
| `tv herdr-review` / `prefix+i` | the **inbox**: lists only flagged panes. `Enter` focuses & **keeps** the ⭐ (you may still be mid-review); `Alt+C` focuses **and** clears it ("mark read") |

Three names must move together: `TOKEN` in `review-mark.sh`, the `.tokens.review` lookups in [`herdr-review.toml`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/television/cable/herdr-review.toml), and `"$review"` in the sidebar row layout.

## Run any command in a popup (`prefix + E`) {#run-any-command}

`prefix + G` proves the shape — a transient pane that runs something and vanishes when it exits — but its command is hardcoded. `prefix + E` is the generalisation: **fzf-pick a command from shell history (or just type a new one), it runs in the focused pane's cwd, and the popup closes itself on exit.** Helper: `~/.config/herdr/run-command.sh` = [`dot_config/herdr/executable_run-command.sh`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/herdr/executable_run-command.sh).

**Why `type = "popup"` and not the alternatives** — this is the only binding here that is not a command *pane*:

| Approach | Problem |
|---|---|
| `type = "pane"` (`prefix+G/M/N`) | splits the **tiled layout** for the duration; everything reflows |
| `prefix + c` → type → `exit` | four steps, and churns the tab bar |
| **`type = "popup"`** | session-modal float **above** the layout — nothing reflows, and you land exactly where you were |

`type = "popup"` requires **herdr ≥ 0.7.4** (added in #1125, with `width`/`height` in cells or percentages). It is the true `tmux display-popup -E` analog.

`prefix + `` ` `` (scratch shell) is a popup too, for the same reason — as a command pane it took over the layout and read as a *zoom* of the current window rather than a scratch space. `prefix+G` / `prefix+M` / `prefix+N` (lazygit / btop / nvtop) deliberately stay `type = "pane"`: you quit those immediately with `q`, so the temporary split costs nothing, and popups are **session-modal** — you cannot touch another pane while one is open. That modality is why this is decided per binding rather than globally.

**It cannot be a herdr-plus Quick Action** (`prefix + y`), which is the intuitive place to look. Two blockers: Quick Actions run through `sh -c` with **no PTY/stdin** — the same reason `btop`/`nvtop` are command panes rather than Quick Actions — and every action is a fixed `command = "…"` string with no free-text field.

Behaviour:

| | |
|---|---|
| **cwd** | `--cwd` → `$HERDR_ACTIVE_PANE_CWD` → `herdr pane get` `foreground_cwd` → `$PWD`. Preferring the env var means it still works when the CLI is protocol-mismatched with a stale server |
| **picker** | fzf over `$HISTFILE` (default `~/.zsh_history`), newest-first and de-duplicated. **Enter** runs the highlighted history entry; **`Alt+Enter` runs exactly what you typed**, even when history still matches it; typing something with no match at all and pressing Enter also runs it as a new command; `Esc` runs nothing. Falls back to a plain `read` prompt when fzf is absent |
| **shell** | `$SHELL -ic` by default, so this repo's aliases and functions resolve (`gst`, `cas`, `x`, …). `--sh` switches to `sh -c` — fast, but aliases do not exist |
| **on exit** | closes on success; on failure prints `[exit N]` and waits for Enter so the error stays readable. `HERDR_RUN_HOLD=always\|never` overrides |

> Two portability traps are handled inside the helper and are worth knowing if you edit it: `~/.zsh_history` is extended-history format (`: <ts>:<elapsed>;<cmd>`) **and contains non-UTF8 bytes**, so BSD `sed` aborts with `sed: RE error: illegal byte sequence` unless the parse runs under `LC_ALL=C`; and the newest-first reversal uses POSIX `awk` because `tail -r` is BSD-only while `tac` is GNU-only.

> **Why `Alt+Enter` had to exist.** Plain Enter cannot express *"run exactly what I typed"* while fzf still has a match — type `ls -la` with `ls -la /tmp` in history and Enter takes the history entry, which makes the picker feel like it can only replay old commands. `--expect=alt-enter` adds the escape hatch. Note that fzf's line layout is **not fixed**: with `--print-query --expect`, a no-match Enter prints only the query (one line), while an accepted match prints query / key / selection. The helper therefore reads the key from line 2 (empty or absent ⇒ plain Enter) and only trusts line 3 on exit code 0.

## Copy pane + space facts to the clipboard {#copy-to-clipboard}

Six one-keypress "grab this onto the clipboard" ops, all driven by one helper (`~/.config/herdr/pane-copy.sh` = [`dot_config/herdr/executable_pane-copy.sh`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/herdr/executable_pane-copy.sh)). It distills a herdr CLI call into human-readable text and pipes it to the repo's own [`x copy`](../shells/aliases.md) (auto-selects pbcopy / wl-copy / xclip / xsel / OSC 52; `x` is resolved by absolute-path fallback since a command-pane may run without the interactive PATH). The pane defaults to the **current focused pane** (`herdr pane current`); the keybinds pass `$HERDR_ACTIVE_PANE_ID`, the Quick Actions pass `$HERDR_PLUS_PANE_ID`, and either falls through to the current-pane lookup when empty.

| Op | Key | Quick Action | What lands on the clipboard |
|---|---|---|---|
| `process` | `prefix+P` | *Copy pane: process info* | foreground processes — `cmdline` + `pid` + `cwd` (from `herdr pane process-info`) |
| `coord` | `prefix+D` | *Copy pane: coordinate* | a paste-ready `session` / `workspace` / `tab` / `pane` id block + the `socket` path + a `# herdr pane get <pane>` line |
| `content` (visible) | `prefix+V` | *Copy pane: content (visible)* | the pane's on-screen text (`herdr pane read --source visible`) |
| `content` (scrollback) | `prefix+S` | *Copy pane: content (scrollback)* | the pane's scrollback (`--source recent --lines 1000`), capped at herdr's own per-`pane read` hard ceiling of 1000 lines — a pane retaining more than that (check `.scroll.max_offset_from_bottom` from `herdr pane get`) only yields its most recent 1000 lines; there's no pagination flag to reach further back |
| `dir` | `prefix+d` | *Copy space: dir* | the **workspace ("space") root directory** — see below |
| `cwd` | `prefix+ctrl+d` | *Copy pane: cwd* | the focused pane's **live** working directory (what `pwd` / [`abspath`](../shells/aliases.md) returns) |

The **coordinate** answers "which `session > space > tab > pane` is this?" in a form you can feed back to the CLI. herdr has **no `--session` flag** on the `pane`/`tab`/`workspace` subcommands — a session is targeted only via `HERDR_SOCKET_PATH` — so the block includes the `socket=` line as the session selector (the session *name* is resolved by matching that socket against `herdr session list --json`).

Both surfaces share the same helper: the `[[keys.command]]` binds in [`.chezmoitemplates/herdr/config.toml`](https://github.com/daviddwlee84/dotfiles/blob/main/.chezmoitemplates/herdr/config.toml) and the `copy-*.toml` **Quick Actions** under `dot_config/herdr/plugins/config/cloudmanic.herdr-plus/quick-actions/` (fuzzy-launched via `prefix+y`). `P/D/V/S` are uppercase (`prefix+shift+<letter>`) chosen to dodge herdr's reserved `shift+H/J/K/L` (swap-pane) and this repo's `shift+B` (new_worktree) / `shift+R` (reload); lowercase `d` was the only free mnemonic letter left for the dir ops, with `ctrl+d` keeping the pair adjacent. Confirm no collision with `herdr server reload-config` (empty `diagnostics`).

### `dir` vs `cwd`, and why the right-click menu can't do this {#space-dir}

`dir` is the answer to *"what directory is this space about?"* — the thing you'd want from a right-click **Copy dir** on a sidebar workspace row. Three ways to reach it:

| Surface | How | Scope |
|---|---|---|
| `prefix+d` | keybind | the **focused** workspace |
| `prefix+y` → *Copy space: dir* | herdr-plus Quick Action | the **focused** workspace |
| `prefix+T` → **`Alt+Y`** | [`herdr-sesh`](#television-integration) tv channel | **any** workspace in the list — strictly more than right-click could give |

**herdr's context menus cannot be extended.** They are a fixed enum compiled into the binary — the whole inventory is one packed string blob (`Rename` · `Close` · `New worktree` · `Open worktree...` · `Close group` · `Expand` · `Delete worktree checkout...` for spaces; `New tab` · `Rename pane` · `Split right` · `Split down` · `Close pane` · `Swap with focused pane` · `Clear pane name` for panes). Verified on 0.7.5 from three directions: `config.toml` has no menu table (only `[[keys.command]]` and `ui.right_click_passthrough_modifier`, which governs whether right-click reaches the *inner app*); the plugin manifest's `[[actions]]` carries `contexts = ["workspace"]` that **looks** like menu placement but is inert; and `herdr api schema --json` contains no occurrence of "menu" at all, so nothing can inject one at runtime either.

> **Upstream status (re-check on herdr upgrades).** Requested four times — [#1511](https://github.com/ogulcancelik/herdr/issues/1511) (user-defined menu entries), [#1671](https://github.com/ogulcancelik/herdr/issues/1671), [#1776](https://github.com/ogulcancelik/herdr/issues/1776), [#1830](https://github.com/ogulcancelik/herdr/issues/1830) — **all closed `NOT_PLANNED`**, three of them auto-closed by `kangal-bot` for being feature requests on a bug-only tracker. #1776 is where a maintainer-facing report states plainly that `contexts` *"currently only surfaces in the `plugin action list` API response."* The redirected discussions ([#1609](https://github.com/ogulcancelik/herdr/discussions/1609), [#1672](https://github.com/ogulcancelik/herdr/discussions/1672), [#1722](https://github.com/ogulcancelik/herdr/discussions/1722)) are all still open and unanswered.

**How the space dir is derived — and its one caveat.** herdr exposes **no workspace-level cwd anywhere**: `herdr workspace get` and `herdr api snapshot` both return the same `label` / `number` / `tab_count` / `pane_count` object. So it is computed, by [`~/.config/herdr/space-root.sh`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/herdr/executable_space-root.sh) — the SSOT shared by `pane-copy.sh dir`, the `prefix+C` new-tab helper, and the tv channel's preview + `Alt+Y`:

- **Space root = the cwd of the workspace's *oldest surviving* tab.** `.number` on a tab is a monotonic **creation counter**, not the display index — a space can hold tabs numbered `10/13/14/15` shown as `1/2/3/4` — so `sort_by(.number)[0]` means "oldest", which is the right notion of "the tab this space started as".
- **Caveat: the sidebar label is pinned at creation and never re-derived**, so once you `cd` inside that oldest tab the label and the derived dir drift apart, and nothing in the API can recover the original path. Observed live: a space labelled `2026-05-14-grafana-provisioning-with-docker-otel-lgtm` whose oldest tab sits in `…/grafana/dashboards/Jingle.AI`. `dir` reports the latter — the true current directory, not the stale name.

`cwd` exists because the two genuinely diverge in normal use: a space rooted at `2026-07-24-unify-ashare-sdk` was observed with panes sitting in three unrelated `Documents/Program/*` trees. `dir` is the project; `cwd` is where *this pane* actually is.

## Open a URL from the pane (`prefix+u`)

The herdr analog of tmux's `prefix + u` ([`joshmedeski/tmux-fzf-url`](https://github.com/joshmedeski/tmux-fzf-url)). `prefix+u` opens an fzf popup listing every URL in the focused pane; pick one (or several — fzf multi-select) and each opens in the browser. Lowercase `u` is deliberately paired with uppercase `U` (`tv tools`), matching the tmux muscle memory.

One helper drives it: `~/.config/herdr/url-pick.sh` = [`dot_config/herdr/executable_url-pick.sh`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/herdr/executable_url-pick.sh). It reads the pane (`herdr pane read`), runs the **same extraction/rewrite passes as tmux-fzf-url**, and opens each choice with the repo's cross-platform [`x open`](../shells/aliases.md) (wslview / open / xdg-open). It mirrors `pane-copy.sh` exactly: pane defaults to `$HERDR_ACTIVE_PANE_ID` (the keybind var) with a `herdr pane current` fallback, and `x` is resolved by absolute-path fallback since a command-pane may run without the interactive PATH.

| Aspect | Behavior |
|---|---|
| Scope | **Visible screen by default** (matches tmux-fzf-url). `url-pick.sh <pane> --source recent` scans the full retained scrollback |
| Patterns | `http(s)` / `ftp` / `file`, bare `www.` → `http://`, `IPv4[:port]` → `http://`, `git@…` SSH remotes → `https://…`, quoted `"owner/repo"` → `github.com/owner/repo`, `import "pkg"` → `npmjs.com/package/pkg` |
| Open | `x open <url>` per selection; multi-select opens all |
| No URLs | prints `no URLs found` and pauses ~1.5 s (a command pane closes the instant the script exits — tmux uses the status line instead) |

Bound via a `[[keys.command]] type="pane"` in [`.chezmoitemplates/herdr/config.toml`](https://github.com/daviddwlee84/dotfiles/blob/main/.chezmoitemplates/herdr/config.toml) — no tv channel needed (fzf is the faithful port). Copy-mode URL opening (tmux's `tmux-open` `o`) has no herdr equivalent; use `prefix+u` for the picker.

## Copy a file path from the pane (`prefix+p`)

The copy-path sibling of the URL picker. `prefix+p` opens an fzf popup of the file paths in the focused pane; pick one (or several) and the path is copied to the clipboard. Lowercase `p` ("copy **p**ath") sits under the uppercase copy family (`prefix+P/D/V/S`), the same `u`/`U` convention. On tmux the analog is the **extrakto** plugin (`prefix + Tab`) — see [tmux keybindings](tmux/keybindings.md).

Helper: `~/.config/herdr/path-pick.sh` = [`dot_config/herdr/executable_path-pick.sh`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/herdr/executable_path-pick.sh), a direct sibling of `url-pick.sh`/`pane-copy.sh` (same pane + `x`-resolution + `herdr pane read` plumbing), copying via [`x copy`](../shells/aliases.md).

**The noise problem, and how it's handled.** Unlike URLs (which self-identify with `scheme://`), file paths have no marker, so a regex alone matches dates (`2024/01/02`), rates (`10k/s`) and fractions (`1/2`). Two defenses:

| Defense | Behavior |
|---|---|
| Extraction | extrakto's path heuristics — slash-bearing tokens (`/…`, `~/…`, `./`, `a/b/c`) + bare `file.ext`; trailing `",):` stripped; rate/fraction tokens excluded outright |
| Existence check (the noise-killer) | Each candidate is resolved against the pane cwd (`$HERDR_ACTIVE_PANE_CWD`, else `herdr pane get` `foreground_cwd`, else process-info cwd) and `test -e`'d |
| **Two-tier list** | Paths that **exist** show first (copied as their resolved **absolute** path); everything else — remote / stale / hypothetical — appears below a `── unverified ──` separator (still selectable), so real-but-unresolvable paths aren't lost |

`path:line:col` suffixes (grep `-n` / stack traces / compiler output) are stripped before the existence test, so `pkg.py:42:5` validates as `pkg.py`. Scope is the visible screen by default (`--source recent` for scrollback); multi-select copies newline-joined; an empty result prints `no file paths found` and pauses ~1.5 s.

## AI usage / quota status

herdr has **no native usage/quota/token display** (the sidebar shows agent *state* only). It does expose a per-pane hook — `herdr pane report-metadata <pane> --source ID --token usage="…" --ttl-ms N` — that a driver could push a `"Claude 62% • Codex 78%"` label into (the same hook the **Review-pending flag** section above uses, but since herdr 0.7.4 tokens are a namespaced map, so a `usage` token and the `review` token coexist instead of contending for one field). A Codex-only community plugin ([jerryfane/herdr-codex-usage-kit](https://github.com/jerryfane/herdr-codex-usage-kit)) already does this from the same `~/.codex` data [CodexBar](https://github.com/steipete/CodexBar) reads; nothing covers Claude/ChatGPT quota. Deferred — CodexBar's menu bar stays the multi-provider view. Design + options captured in [`backlog/herdr-usage-status-driver.md`](https://github.com/daviddwlee84/dotfiles/blob/main/backlog/herdr-usage-status-driver.md).

## Gaps (no clean herdr equivalent)

- **Seamless `Ctrl-hjkl` nvim↔pane navigation.** `vim-tmux-navigator` is tmux-coupled (the `is_vim` `ps`/`pane_tty` heuristic + the nvim plugin). herdr has no smart-splits equivalent — its pane focus is `prefix+h/j/k/l`, which won't pass through to nvim splits at the edge. Workaround: inside nvim use its own `<C-w>hjkl`. This is the biggest UX regression vs tmux.
- **OSC133 copy-mode** (`cpout` / `cpblock`, prompt-jump, last-output yank) is tmux-specific. herdr's copy mode (`prefix+[`) is vi-style but has no OSC133 prompt-boundary awareness. `cpcmd` (zsh history, multiplexer-agnostic) still works.
- **Decorative status-bar glyphs** (📌/🔖 as free-floating window labels): herdr has no `#{@option}` format-string interpolation, so tmux-style status-bar bookmarks don't port. *(The specific "mark-unread / review-pending ⭐" use case IS solved — see the **Review-pending flag** section above — via a per-pane metadata token; only the purely decorative status-bar glyph remains a gap.)*
- **Per-key pane resize.** tmux binds `prefix+H/J/K/L` (and `M-hjkl` for fine steps) to resize directly; herdr has no per-key resize — it uses a modal `resize_mode` (`prefix+r`), then `h/j/k/l`. Not exact parity, but a close analog.

> **Not a gap:** vi copy-mode itself *is* native (`prefix+[`), and per-pane agent state is detected natively — the two things I expected to be missing turned out to be built in.

## See also

- [tmux setup](tmux/README.md) · [Television (tv)](tv.md) · [sesh](sesh.md) · [workmux](workmux.md)
- [Tool managers — where tools come from](../this_repo/tool-managers.md)
