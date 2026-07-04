# Herdr — Rust terminal multiplexer + AI-agent orchestrator (trial)

[ogulcancelik/herdr](https://github.com/ogulcancelik/herdr) is a Rust terminal multiplexer with **built-in coding-agent awareness** (it tracks per-pane agent state: idle / working / blocked / done). It sits in the same niche as tmux/zellij but is mouse-first and agent-native. Docs: <https://herdr.dev/docs/>.

This repo ships herdr as a **trial tool that coexists with tmux** — you run `herdr` *or* `tmux`, never nested. Nothing about the existing tmux / `sesh` / `tmuxp` / workmux setup changes; herdr is purely additive so you can evaluate it without losing your daily driver.

- **Install**:
  - macOS — Homebrew (`herdr` is in homebrew-core; managed by the `dot_ansible/roles/devtools/tasks/main.yml` macOS list)
  - Linux — GitHub release **single static binary** (`herdr-linux-{x86_64,aarch64}`) into `~/.local/bin/herdr` (managed by the `# --- herdr ... ---` block in the same role). No tarball, so no unarchive step.
- **Verify**: `herdr --version` · validate config with `herdr server reload-config`
- **Upgrade**: brew on macOS; `herdr update` for the self-managed Linux binary
- **Config**: `~/.config/herdr/config.toml` — chezmoi **seed-once** (`dot_config/herdr/create_config.toml`, the `create_` prefix). herdr writes UI settings back into this file (see [Config writeback](#config-writeback-why-create_)), so chezmoi plants it on a fresh machine and then never touches it.

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
| `prefix + \|` / `prefix + minus` | split side-by-side / stacked | rebound |
| `prefix + z` / `prefix + x` | zoom / close pane | built-in default |
| `prefix + w` / `prefix + g` | workspace nav / session navigator | built-in default |
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

## Session helpers: `hvibe` / `hcode` (herdr analogs of `svibe` / `scode`)

Two shell functions in [`dot_config/shell/24_herdr.sh`](../shells/aliases.md#session-management) spin up a whole coding workspace in one motion — the herdr counterparts of the tmux `svibe` / `scode` helpers. They shell out to the native `herdr workspace|tab|pane` CLI and **reuse svibe's pure logic verbatim** (specstory wrapping, `--on-exit shell|kill|restart`, git-root resolution, agent-CLI detection) from `22_sesh.sh`; only the layout calls differ. Need the `herdr` server running + `jq`.

| Command | Builds workspace | Layout |
|---|---|---|
| `hvibe [N] [CLI]` / `hvibe --agents claude,codex,opencode` | `vibe/<repo>` | tab `agents` (N even-width agent panes) + tab `git` (lazygit) + tab `edit` (nvim) |
| `hvibe --tab-per-agent …` | `vibe/<repo>` | one tab **per agent** + `git` + `edit` tabs |
| `hcode [CLI]` | `coding-agent/<repo>` | tab `editor` (nvim 75% \| agent 25%) + tab `monitor` (btop) |

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

### Config writeback (why `create_`)

herdr **writes UI/runtime settings back into `~/.config/herdr/config.toml`** — e.g. finishing onboarding prepends `onboarding = false`, and the in-app *settings* popups (theme / sound / toasts / pane labels) persist there on *apply*. It edits in place and keeps existing comments, but it owns the file at runtime. That is why chezmoi manages it as **`create_` (seed-once)**: a plain managed file would be clobbered on every `chezmoi apply` (re-removing `onboarding=false` → the onboarding screen reappears, and reverting any UI change). Consequence: edits to `create_config.toml` in the repo do **not** auto-propagate to a machine that already has the file — refresh it deliberately with `cp ~/.config/herdr/config.toml "$(chezmoi source-path ~/.config/herdr/config.toml)"` (then strip the runtime `onboarding`/state lines).

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

## AI usage / quota status

herdr has **no native usage/quota/token display** (the sidebar shows agent *state* only). It does expose a per-pane hook — `herdr pane report-metadata <pane> --source ID --custom-status "…" --ttl-ms N` — that a driver could push a `"Claude 62% • Codex 78%"` label into. A Codex-only community plugin ([jerryfane/herdr-codex-usage-kit](https://github.com/jerryfane/herdr-codex-usage-kit)) already does this from the same `~/.codex` data [CodexBar](https://github.com/steipete/CodexBar) reads; nothing covers Claude/ChatGPT quota. Deferred — CodexBar's menu bar stays the multi-provider view. Design + options captured in [`backlog/herdr-usage-status-driver.md`](https://github.com/daviddwlee84/dotfiles/blob/main/backlog/herdr-usage-status-driver.md).

## Gaps (no clean herdr equivalent)

- **Seamless `Ctrl-hjkl` nvim↔pane navigation.** `vim-tmux-navigator` is tmux-coupled (the `is_vim` `ps`/`pane_tty` heuristic + the nvim plugin). herdr has no smart-splits equivalent — its pane focus is `prefix+h/j/k/l`, which won't pass through to nvim splits at the edge. Workaround: inside nvim use its own `<C-w>hjkl`. This is the biggest UX regression vs tmux.
- **OSC133 copy-mode** (`cpout` / `cpblock`, prompt-jump, last-output yank) is tmux-specific. herdr's copy mode (`prefix+[`) is vi-style but has no OSC133 prompt-boundary awareness. `cpcmd` (zsh history, multiplexer-agnostic) still works.
- **Status-bar format glyphs + bookmarks** (⭐/📌/🔖): herdr has no `#{@option}` format-string interpolation. Native agent dots cover the agent part; manual bookmarks have no analog.

> **Not a gap:** vi copy-mode itself *is* native (`prefix+[`), and per-pane agent state is detected natively — the two things I expected to be missing turned out to be built in.

## See also

- [tmux setup](tmux/README.md) · [Television (tv)](tv.md) · [sesh](sesh.md) · [workmux](workmux.md)
- [Tool managers — where tools come from](../this_repo/tool-managers.md)
