# Herdr — Rust terminal multiplexer + AI-agent orchestrator (trial)

[ogulcancelik/herdr](https://github.com/ogulcancelik/herdr) is a Rust terminal multiplexer with **built-in coding-agent awareness** (it tracks per-pane agent state: idle / working / blocked / done). It sits in the same niche as tmux/zellij but is mouse-first and agent-native. Docs: <https://herdr.dev/docs/>.

This repo ships herdr as a **trial tool that coexists with tmux** — you run `herdr` *or* `tmux`, never nested. Nothing about the existing tmux / `sesh` / `tmuxp` / workmux setup changes; herdr is purely additive so you can evaluate it without losing your daily driver.

- **Install**:
  - macOS — Homebrew (`herdr` is in homebrew-core; managed by the `dot_ansible/roles/devtools/tasks/main.yml` macOS list)
  - Linux — GitHub release **single static binary** (`herdr-linux-{x86_64,aarch64}`) into `~/.local/bin/herdr` (managed by the `# --- herdr ... ---` block in the same role). No tarball, so no unarchive step.
- **Verify**: `herdr --version` · validate config with `herdr server reload-config`
- **Upgrade**: brew on macOS; `herdr update` for the self-managed Linux binary
- **Config**: `~/.config/herdr/config.toml` — chezmoi **`modify_` overlay** (`dot_config/herdr/modify_config.toml.tmpl` + managed body in `.chezmoitemplates/herdr/config.toml`). The overlay enforces our managed tables on every `chezmoi apply` while preserving whatever herdr writes back at runtime (see [Config management](#config-management-why-modify_)).

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

## cwd & workspace-naming model

herdr tracks cwd differently from tmux, which trips up two common expectations (all verified via `herdr pane list`):

- **Every pane has two cwds.** `cwd` = the shell's *startup* directory (fixed at spawn); `foreground_cwd` = the *live* cwd, tracked via **OSC 7** shell integration. A `cd` in the shell updates `foreground_cwd`; the startup `cwd` never changes.
- **`cd` inside a child process / subshell doesn't propagate.** Because tracking is OSC 7-based, a `cd` in a subshell that doesn't re-emit OSC 7 — e.g. `chezmoi cd`, which spawns a *new* shell in the source dir — is invisible to herdr. `foreground_cwd` stays put, so the space's git-repo detection and the `prefix+G` lazygit location don't follow the subshell. This is inherent to OSC 7, **not** a herdr bug — expected behavior.
- **New tabs spawn at the workspace root, not the focused pane's cwd.** With `new_cwd = "follow"` (below), a *split* inherits the focused pane's cwd, but a *new tab* falls back to the workspace's cwd (often `$HOME`). Confirmed: every non-first tab's root pane has `cwd = $HOME`.
- **The workspace ("space") label auto-follows the root/primary pane's live cwd basename** (e.g. → `chezmoi`, `trading-journal`). `cd` in **tab 1** renames the space; `cd` in other tabs does not. No config knob controls this.

**`new_cwd` values** (`[terminal]`) — the CWD policy for new panes/tabs/workspaces when no explicit `--cwd` is given:

| value | meaning |
|---|---|
| `follow` (default) | inherit the **source** pane/workspace (split → focused pane's live cwd; new tab → workspace root) |
| `home` | `$HOME` |
| `current` | herdr's **own process** directory (NOT the focused pane) |
| `"~/path"` | a fixed path |

**No `new_cwd` value opens a new tab in the focused pane's live cwd** — only an explicit `herdr tab create --cwd …` does (verified: `tab create --cwd PATH` spawns the new tab's shell in `PATH`). For a "new tab here" key, bind a command pane to `herdr tab create --cwd "$HERDR_ACTIVE_PANE_CWD" --focus` (e.g. on `prefix+C`; native `prefix+c` stays = workspace root):

```toml
[[keys.command]]
key = "prefix+C"
type = "pane"
command = "herdr tab create --cwd \"$HERDR_ACTIVE_PANE_CWD\" --focus"
description = "new tab in the current pane's cwd"
```

## Feasibility matrix (current tmux experience → herdr)

| Current capability | herdr story | How it's handled here |
|---|---|---|
| Catppuccin theme + light/dark | **Native** `[theme]` + `auto_switch` | Configured in `config.toml` |
| Splits / zoom / new tab+workspace / pane nav | **Native** `[keys]` actions | Rebound to tmux muscle memory |
| Session persistence (resurrect/continuum) | **Native** detach/reattach | Skipped — native |
| Mouse / right-click menus | **Native** mouse-first | Skipped — native |
| Agent status 🤖/💬/✅ (workmux, 6 files) | **Native** agent-state rollups in sidebar | Skipped — native (workmux untouched for tmux) |
| `sesh` fuzzy switch + `tmuxp` layouts | **Plugin** [herdr-plus](https://github.com/cloudmanic/herdr-plus) Projects + Quick Actions | Plugin + Projects templates |
| `tv` channel popups (`prefix+T/U/a`) | **Custom command panes** (`[[keys.command]] type="pane"`) | Key bindings + 2 herdr-aware channels |
| lazygit / scratch popups | **Custom command panes** | Key bindings |
| Seamless `Ctrl-hjkl` nvim↔pane nav | **No herdr-aware smart-splits** | **Gap** — workaround below |
| OSC133 copy-mode (`cpout`/`cpblock`) | tmux-specific | **Gap** — `cpcmd` (zsh history) still works |
| Per-window status glyphs + bookmarks ⭐📌 | **No format-string interpolation** | **Gap** — native agent dots replace the agent part |
| AI session-summary / agent-wakeup capture | re-portable against `herdr pane read` / `pane list --json` | **Deferred** — out of trial scope |

## Keybindings

Prefix is `ctrl+b` (same as tmux). Built-in actions can only be *rebound* (herdr's action set is fixed); everything else is a `[[keys.command]]` custom command. Custom commands receive `$HERDR_SOCKET_PATH`, `$HERDR_ACTIVE_PANE_ID`, `$HERDR_ACTIVE_PANE_CWD` and run from the focused pane's cwd.

> **Two families of herdr env vars.** The `HERDR_ACTIVE_PANE_*` vars above are injected **only** into `[[keys.command]]` invocations. Every shell *running inside a herdr pane* also gets an **ambient** set: `HERDR_ENV=1`, `HERDR_PANE_ID`, `HERDR_TAB_ID`, `HERDR_WORKSPACE_ID`, and `HERDR_SOCKET_PATH` (the current session's socket). Scripts use `HERDR_ENV` as the "am I inside herdr?" test and inherit `HERDR_SOCKET_PATH` to target the current session — that's what `hvibe`/`hcode` rely on.

| Key | Action | Type |
|---|---|---|
| `prefix + c` / `prefix + 1..9` | new tab / switch tab | built-in default |
| `prefix + h/j/k/l` | focus pane | built-in default |
| `prefix + \|` / `prefix + %` · `prefix + minus` / `prefix + "` | split side-by-side / stacked (tmux muscle memory — both the intuitive key and the tmux default) | rebound (arrays) |
| `prefix + z` / `prefix + x` | zoom / close pane | built-in default |
| `prefix + w` / `prefix + g` | workspace navigator (navigate-mode: **`j`/`k`** *or* arrows to move, Enter to pick) / session navigator | built-in; `navigate_workspace_*` rebound to `j`/`k` + arrows |
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
| `prefix + U` | `tv tools` (CLI launcher) | command pane |
| `prefix + T` | `tv herdr-sesh` (workspace/dir switcher) | command pane |
| `prefix + a` | `tv herdr-agent-panes` (live agent panes) | command pane |
| `prefix + f` | `tv fleet-hosts` (SSH picker) | command pane |
| `` prefix + ` `` | scratch shell | command pane |
| `prefix + O` | herdr-plus **Projects** (layout launcher) | plugin action |
| `prefix + y` | herdr-plus **Quick Actions** | plugin action |

> Uppercase letters resolve to `prefix+shift+<letter>`, which herdr reserves for built-ins (`shift+g` worktree, `shift+t` rename-tab, `shift+h/j/k/l` swap-pane). `prefix+G`/`prefix+T` are freed by the rebinds above; `herdr server reload-config` reports any remaining collisions in its `diagnostics`.

## Session helpers: `hvibe` / `hcode` / `hhere` / `hroot` (herdr analogs of `svibe` / `scode` / `shere` / `sroot`)

Four shell functions in [`dot_config/shell/24_herdr.sh`](../shells/aliases.md#session-management) are the herdr counterparts of the tmux `svibe` / `scode` / `shere` / `sroot` helpers. The two **heavyweight** ones (`hvibe` / `hcode`) spin up a whole coding workspace in one motion; the two **lightweight** ones (`hhere` / `hroot`) just open a plain workspace at a directory and attach — no git repo, no agent layout. They shell out to the native `herdr workspace|tab|pane` CLI and **reuse the pure logic verbatim** (specstory wrapping, `--on-exit shell|kill|restart`, git-root resolution, agent-CLI detection) from `22_sesh.sh`; only the layout calls differ. Need the `herdr` server running + `jq`.

| Command | Builds workspace | Layout |
|---|---|---|
| `hvibe [N] [CLI]` / `hvibe --agents claude,codex,opencode` | `vibe/<repo>` | tab `agents` (N even-width agent panes) + tab `git` (lazygit) + tab `edit` (nvim) |
| `hvibe --tab-per-agent …` | `vibe/<repo>` | one tab **per agent** + `git` + `edit` tabs |
| `hcode [CLI]` | `coding-agent/<repo>` | tab `editor` (nvim 75% \| agent 25%) + tab `monitor` (btop) |
| `hhere [CMD...]` | `<basename $PWD>` | single tab, plain shell at `$PWD` (or `-p DIR`); optional `CMD` in the root pane |
| `hroot [CMD...]` | `<basename git-root>` | same as `hhere` but at the current git root (falls back to `$PWD`) |

- **The plain-open pair (`hhere` / `hroot`)** fills the gap where every other herdr entry point forces a git repo + a full agent layout. With tmux, `tmux new-session` lands you in `$PWD` directly; herdr adds a Workspace layer, so without these you'd launch herdr, create a space (which opens at `$HOME` per `new_cwd`), then `cd` by hand. `hhere` does the one-shot: `herdr workspace create --cwd "$PWD"` → focus → attach if outside. No git requirement; the optional command runs **raw** (no specstory/on-exit wrapping — that stays with `hcode`/`hvibe`). `hhere -h` / `hroot -h` for flags. **Label caveat**: herdr auto-relabels a workspace to its root pane's *live* cwd basename after a `cd` in tab 1 (see the **cwd & workspace-naming model** section above), so the idempotent-focus is best-effort — a drifted label makes a re-run open a fresh workspace.
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

## Television integration

Most `tv` channels (`tools`, `fleet-hosts`, `mlflow`, `kill-process`, `ssh-config`) have **non-tmux-coupled actions**, so they run unchanged in a herdr command pane — just bind a key to `tv <channel>`. Only the channels whose actions call `tmux …` need herdr-aware variants. Two ship here:

- `herdr-sesh` (`dot_config/television/cable/herdr-sesh.toml`) — lists herdr sessions/workspaces + zoxide dirs; Enter dispatches `herdr session attach` / `herdr workspace focus` / `herdr workspace create --cwd` instead of `sesh connect` / `tmux switch-client`.
- `herdr-agent-panes` (`dot_config/television/cable/herdr-agent-panes.toml`) — same source as `agent-panes`, but switch/kill use `herdr pane focus` / `herdr pane close`.

The original tmux-bound `sesh` / `agent-panes` channels are left intact for coexistence.

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
| claude | `~/.claude/hooks/herdr-agent-state.sh` **+ a hook entry in `~/.claude/settings.json`** | Yes — but the repo's hook-aware `modify_settings.json` merger **preserves** it (same as it does for CodeIsland). `chezmoi apply` is a no-op; it won't strip the herdr hook. |
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

## AI usage / quota status

herdr has **no native usage/quota/token display** (the sidebar shows agent *state* only). It does expose a per-pane hook — `herdr pane report-metadata <pane> --source ID --custom-status "…" --ttl-ms N` — that a driver could push a `"Claude 62% • Codex 78%"` label into. A Codex-only community plugin ([jerryfane/herdr-codex-usage-kit](https://github.com/jerryfane/herdr-codex-usage-kit)) already does this from the same `~/.codex` data [CodexBar](https://github.com/steipete/CodexBar) reads; nothing covers Claude/ChatGPT quota. Deferred — CodexBar's menu bar stays the multi-provider view. Design + options captured in [`backlog/herdr-usage-status-driver.md`](https://github.com/daviddwlee84/dotfiles/blob/main/backlog/herdr-usage-status-driver.md).

## Gaps (no clean herdr equivalent)

- **Seamless `Ctrl-hjkl` nvim↔pane navigation.** `vim-tmux-navigator` is tmux-coupled (the `is_vim` `ps`/`pane_tty` heuristic + the nvim plugin). herdr has no smart-splits equivalent — its pane focus is `prefix+h/j/k/l`, which won't pass through to nvim splits at the edge. Workaround: inside nvim use its own `<C-w>hjkl`. This is the biggest UX regression vs tmux.
- **OSC133 copy-mode** (`cpout` / `cpblock`, prompt-jump, last-output yank) is tmux-specific. herdr's copy mode (`prefix+[`) is vi-style but has no OSC133 prompt-boundary awareness. `cpcmd` (zsh history, multiplexer-agnostic) still works.
- **Status-bar format glyphs + bookmarks** (⭐/📌/🔖): herdr has no `#{@option}` format-string interpolation. Native agent dots cover the agent part; manual bookmarks have no analog.
- **Per-key pane resize.** tmux binds `prefix+H/J/K/L` (and `M-hjkl` for fine steps) to resize directly; herdr has no per-key resize — it uses a modal `resize_mode` (`prefix+r`), then `h/j/k/l`. Not exact parity, but a close analog.

> **Not a gap:** vi copy-mode itself *is* native (`prefix+[`), and per-pane agent state is detected natively — the two things I expected to be missing turned out to be built in.

## See also

- [tmux setup](tmux/README.md) · [Television (tv)](tv.md) · [sesh](sesh.md) · [workmux](workmux.md)
- [Tool managers — where tools come from](../this_repo/tool-managers.md)
