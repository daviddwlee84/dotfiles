# Discover running coding-agent sessions across tmux panes

## Context

Today there is no good way to answer the question "which coding-agent sessions
do I have running, and where?". Sessions get scattered across tmux
sessions/windows/panes (and across multiple agents — `claude`, `cursor-agent`,
`codex`, `opencode`, `aider`, `goose`), and the only existing handle is
CodeIsland, which is macOS-only and only knows the **terminal app**, not the
specific tmux pane. There's no way to jump straight to the pane where the
session lives.

This repo is in a strong starting position. It already has:

- A 850-line multi-agent **stored-session** enumerator
  (`dot_config/television/executable_agent-sessions.py`) and a TV channel
  (`dot_config/television/cable/agent-sessions.toml`) that browse Claude /
  Codex / OpenCode / Cursor session **history** with rich preview &
  resume-in-shell actions.
- A pane-enumeration pattern (`dot_config/tmux/executable_break-all-panes.sh`)
  using `tmux list-panes -F '#{pane_id}'` + `#{pane_current_command}`.
- A height-aware tmux popup-menu system
  (`dot_config/tmux/executable_menu.sh` + 6 submenus) with tier trimming and a
  ~14-row cap.
- A Claude hook script (`dot_claude/hooks/executable_notify.sh.tmpl`) wired via
  `dot_claude/modify_settings.json` and CodeIsland-coexistent.
- A cargo-upgrade infrastructure (`scripts/upgrade_tools.sh` `cat_cargo`)
  that auto-upgrades any `cargo install`'d binary.

What's missing is the **live tmux dimension**: cross-reference pane PIDs to
running agents and let the user jump to them. The community has converged on
two patterns:

- **`gavraz/recon`** — Rust binary, tmux-native popup, Claude-only. Reads
  `~/.claude/sessions/{PID}.json` (authoritative — Claude Code writes one per
  process) and `tmux capture-pane` for live status (Working / Input-waiting /
  Idle / New). Installed via `cargo install --git`. Latest v0.6.0 (2026-04).
- **`nielsgroen/claude-tmux`** — Rust, similar UX, also Claude-only.

Both miss Codex / OpenCode / Cursor. Per user choice we ship **both**:
recon for a fast Claude-only "what are my Claude agents doing right now?"
popup, and a new multi-agent TV channel for the cross-agent overview.

Status-line indicator (per-pane working/idle/error glyph in the window list)
is **explicitly deferred** — it's already scoped in
`backlog/tmux-window-status-indicators.md` Option C and gated on a separate
user signal.

---

## Approach

Two complementary surfaces, sharing zero code:

| Surface | Scope | When to reach for it |
|---|---|---|
| `tv agent-panes` (new TV channel + new mode in existing `agent-sessions.py`) | All four agents (cc/cx/oc/cu), live tmux panes only | "Where am I running stuff?" cross-agent overview, jump-to-pane |
| `recon` (cargo-installed) | Claude-only, with live status (Working/Idle/Waiting) parsed from pane capture | "Which Claude needs my attention?" — recon's status detection is richer than what we'd duplicate |

`prefix + a` opens the multi-agent picker (primary). recon is reachable from
the popup menu (`prefix + Space → Agents → Claude dashboard`) — no top-level
binding to keep the keymap clean. The menu entry can be promoted to a
top-level bind later if the user finds themselves using recon often enough.

---

## Files to create / modify

### New files

1. **`dot_config/television/cable/agent-panes.toml`** — new TV channel,
   sibling of `agent-sessions.toml`. Single-source (no Ctrl+S cycling needed
   — the picker is already filtered to running panes). Keybindings:
   - `Enter` → `tmux switch-client -t SESSION \; select-window -t WIN \; select-pane -t PANE`
   - `Alt+T` → same as Enter (consistency with `agent-sessions.toml`)
   - `Alt+K` → `tmux kill-pane -t TARGET` (with confirm prompt)
   - `Ctrl+Y` → copy `session:win.pane` target string to clipboard
   - `Alt+P` → copy directory path
   - `Alt+R` → cycle preview (capture-pane snapshot ↔ stored transcript head)
   - Preview: `tmux capture-pane -ep -t TARGET | tail -n 80` for live state,
     fall back to the existing `agent-sessions.py transcript` renderer for
     stored history.

2. **(optional) `dot_config/tmux/executable_menu-agents.sh`** — new submenu
   row in `menu.sh` for "Agents → ▸". Two entries:
   - `Live agent panes (tv)` → `tv agent-panes`
   - `Claude dashboard (recon)` → `display-popup -E -w 80% -h 60% recon`
   Falls back to direct rows in `menu-popups.sh` if not worth a whole submenu
   — decide at implementation time based on whether other agent-related
   actions (kill all idle, attach to longest-running) emerge.

### Modified files

3. **`dot_config/television/executable_agent-sessions.py`** — add a `panes`
   mode (sixth top-level command, alongside `all` / `opencode` / `claude` /
   `codex` / `cursor` / `cursor-ide`). Algorithm:

   ```
   for each row of `tmux list-panes -aF '<format>'`:
     # format: session_name \t window_index \t window_name \t pane_index \t pane_id \t pane_pid \t pane_current_command \t pane_current_path \t pane_active
     if pane_current_command in {claude, cursor-agent, codex, opencode, aider, goose, node, deno, bun, python}:
       agent_tag, session_id = _resolve_agent(pane_pid, pane_current_command, pane_current_path)
       if agent_tag is None:
         continue   # node/python that's not an agent
       title = _lookup_title(agent_tag, session_id)   # reuse existing helpers
       emit TSV row
   ```

   Per-agent resolution strategy (in priority order, most authoritative first):
   - **Claude (`cc`)** — read `~/.claude/sessions/{pane_pid}.json` (Claude Code
     writes this per process; documented by recon, claude-control, and
     verified). Authoritative: PID → `session_id` + `transcript_path`. Zero
     heuristics.
   - **Codex (`cx`)** — walk pane PID's process tree
     (`pgrep -P <pid>` or `ps -o pid,comm --ppid`), match `codex` binary,
     then cross-reference `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` by
     mtime + cwd match. Best-effort.
   - **OpenCode (`oc`)** — `node` shows up as `pane_current_command`; need
     `ps -o args -p <pane_pid>` to disambiguate (`opencode` in argv). Then
     cross-reference `~/.local/share/opencode/opencode.db` by latest session
     with matching cwd.
   - **Cursor Agent CLI (`cu`)** — same as Codex, but against
     `~/.cursor/chats/<wsHash>/<chatId>/store.db`.
   - **Aider / goose** — out of scope for v1; skip silently. Add later if
     user has them installed (no detection cost when not running).

   TSV columns (extends existing 6-col schema with two pane-specific cols):
   `agent_tag \t when \t session_id \t dir \t title_snippet \t specstory_path \t pane_target \t pane_pid`

   Reuses these existing helpers from the same file:
   - `_fmt_when()`, `_truncate()`, `_compress_home()` (formatting)
   - `_iter_claude_sessions()`, `_iter_opencode_sessions()`,
     `_iter_codex_sessions()`, `_iter_cursor_sessions()` (storage walks for
     title/snippet lookup)
   - The existing `transcript` mode for the alt-preview render.

4. **`dot_config/tmux/keybindings.conf`** — add one binding near the existing
   `prefix + T` (sesh tv) / `prefix + U` (tools tv) cluster around
   line 358-365:

   ```
   # prefix + a: live agent panes picker (tv) — find running claude / cursor /
   # codex / opencode panes across all tmux sessions and jump to them.
   bind-key "a" display-popup -E -w 80% -h 70% -d '#{pane_current_path}' \
     -T ' Live agent panes (tv) ' "tv agent-panes"
   ```

   `prefix + a` is currently unbound (verified). Lowercase to match the
   `g`/`T`/`O`/`U` cluster.

5. **`dot_config/tmux/executable_menu.sh`** — add **one** new tier-0 row:
   `"a" "Live agent panes" "display-popup -E -w 80% -h 70% 'tv agent-panes'"`.
   Stays under the 14-row cap (current top menu has ≤14 rows per CLAUDE.md
   warning). Recon entry goes in a new "Agents" submenu (see file 2 above).

6. **`dot_ansible/roles/devtools/tasks/main.yml`** — add a task to install
   recon respecting the install-only invariant:

   ```yaml
   - name: Install recon (Claude Code tmux dashboard) via cargo
     ansible.builtin.command:
       cmd: cargo install --git https://github.com/gavraz/recon --locked
     args:
       creates: "{{ ansible_user_dir }}/.cargo/bin/recon"
     when:
       - ansible_user_dir is defined
       - cargo_bin.stat.exists | default(false)
     register: recon_install
     changed_when: "'Installing' in (recon_install.stdout | default(''))"
   ```

   Gated on cargo presence (devtools role already installs rustup earlier in
   the file — verify and reuse the existing `cargo_bin` stat var if it
   exists, otherwise add one). The `creates:` guard preserves
   re-apply idempotence per the [Install vs upgrade is split](../../CLAUDE.md#install-vs-upgrade-is-split-on-purpose)
   invariant. Upgrades flow through `scripts/upgrade_tools.sh cargo` →
   `cargo install-update -a`, which already covers `cargo install --git`
   binaries.

### Docs (per CLAUDE.md cross-file rules)

7. **New `docs/tools/agent-panes-discovery.md`** — covers both surfaces
   (`tv agent-panes` and recon), keybinds, when to use which. Includes:
   - One-paragraph why (the jump-to-pane gap CodeIsland leaves)
   - `tv agent-panes` keybind table + screenshot-style preview
   - recon install / popup keybind / status semantics
   - Troubleshooting: "I see `node` panes I don't recognize" → the agent
     filter is conservative; if a node pane isn't tagged, it's not an agent.
   - Cross-link to `docs/tools/tmux/README.md` (popup menu) and existing
     `agent-sessions.toml` channel docs.

8. **`mkdocs.yml`** — add nav entry under "Tools" section:
   `- Agent pane discovery: tools/agent-panes-discovery.md`. Run
   `uv run mkdocs build --strict` to verify.

9. **`README.md`** — one-line bullet under "What You Get → Tools" mentioning
   the new `tv agent-panes` channel + recon.

10. **`CLAUDE.md`** keybindings table (the cross-tool conflict block
    around the "Free Alt slots" line) — append `prefix + a` to the tmux row
    with note "live agent panes picker".

11. **`docs/tools/tmux/keybindings.md`** — add `prefix + a` row.

12. **`backlog/tmux-window-status-indicators.md`** — add a one-liner note at
    the top of the "Decision" block: "Discovery primitive shipped 2026-04 as
    `tv agent-panes` + recon — when option C lands, it can reuse the same
    PID→session resolution code in `agent-sessions.py`."

---

## Verification

Run these end-to-end after implementation, in this order:

1. **Static checks first**:
   - `uv run mkdocs build --strict` — catches broken nav / anchors.
   - `python -m py_compile dot_config/television/executable_agent-sessions.py`
     — quick syntax check.
   - `chezmoi diff` — review every file change before apply.

2. **TV channel works standalone (no tmux switch)**:
   - Open 2-3 tmux panes, start `claude` in one, `opencode` in another,
     `codex` in a third.
   - In a 4th pane: `~/.config/television/agent-sessions.py panes` →
     verify TSV output has one row per agent pane with correct `session:win.pane`
     target and resolved session IDs.
   - `tv agent-panes` → fzf picker shows the three panes; preview shows
     `tmux capture-pane` snapshot of the focused row.

3. **Pane switching works**:
   - From the picker, press `Enter` on a non-current pane → tmux focus
     should switch to that exact session/window/pane.
   - Press `Alt+K` on an idle pane → kills the pane after confirm.

4. **Tmux popup binding**:
   - `prefix + a` → opens the picker as a popup. `Esc` closes cleanly.

5. **Tmux popup menu integration**:
   - `prefix + Space` → "Live agent panes" row appears in tier 0 →
     selecting it opens the picker.

6. **recon install + use** (post `chezmoi apply` triggering ansible):
   - `which recon` → `~/.cargo/bin/recon` (Linux + macOS).
   - In a tmux session with at least one `claude` running:
     `tmux display-popup -E -w 80% -h 60% recon` → recon TUI shows the
     Claude pane(s) with status (Working / Idle / Waiting). Enter switches.
   - From popup menu: `prefix + Space → Agents → Claude dashboard` →
     opens recon.

7. **Cross-platform sanity**:
   - macOS: verify cargo-installed recon runs without Gatekeeper prompts
     (`cargo install --git` builds locally so should be unsigned-but-allowed).
   - Linux (if available): same drill via the chezmoi+ansible apply path.

8. **Idempotence (`chezmoi apply` twice in a row)**:
   - Second apply should NOT re-run `cargo install --git ...` (the
     `creates:` guard catches `~/.cargo/bin/recon`). If it does, fix the
     guard.

9. **Upgrade path**:
   - `just upgrade-cargo` (or `~/scripts/upgrade_tools.sh cargo`) →
     verify recon is in the upgrade list (it should be — cargo-update picks
     up `--git` installs).

---

## Critical files (reference for implementation)

| File | Lines | Why it matters |
|---|---|---|
| `dot_config/television/executable_agent-sessions.py` | 1-850 (extend at end with new `_mode_panes()` + dispatch entry) | Reuse `_fmt_when`, `_truncate`, `_iter_*` storage walkers, `transcript` mode |
| `dot_config/television/cable/agent-sessions.toml` | 1-503 (model new file after this) | Channel structure, source/display/preview/keybindings format reference |
| `dot_config/tmux/executable_break-all-panes.sh` | 25-44 | `tmux list-panes -F` + `pane_current_command` enumeration pattern |
| `dot_config/tmux/keybindings.conf` | 358-365 (add new bind near `prefix + T/U`) | Existing `display-popup tv ...` cluster |
| `dot_config/tmux/executable_menu.sh` | (height-aware tier dispatch) | Where the new menu row goes |
| `dot_ansible/roles/devtools/tasks/main.yml` | (cargo install block) | Install-only invariant; reuse existing cargo task pattern |
| `backlog/tmux-window-status-indicators.md` | 30-37 (deferred Option C block) | Sibling deferred work — annotate that discovery shipped first |
| `CLAUDE.md` | "Keyboard shortcuts (cross-tool conflict check)" table | Update with `prefix + a` |

---

## Out of scope (recorded for future)

- **Status-line indicator** (Option C from backlog) — explicitly deferred
  per user choice. When revisited, the per-pane state file in
  `${XDG_RUNTIME_DIR:-/tmp}/tmux-agent-state-$UID/$TMUX_PANE` can reuse
  this PR's PID→session resolution for the live state lookup.
- **Aider / goose / other agents** — add later when needed; skipping now
  keeps the agent-detection list short and fast.
- **Multi-host** ("show me agent panes across all my fleet machines") — would
  need fleet-apply integration; out of scope for v1.
- **Auto-launch from picker** ("if no Claude is running here, start one") —
  the existing `scode` layout already covers this; don't duplicate.
