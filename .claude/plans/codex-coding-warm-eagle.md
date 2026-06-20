# Plan: `agent-warmup` — interactive Claude quota-window warmup

## Context

**Goal.** Automatically start the Claude Pro/Max **5-hour subscription usage
window** at a fixed time (e.g. 06:00 on workdays), so a fresh window is already
running before the user begins real work — plus an ad-hoc "warm up at this time"
one-shot. This implements [backlog/agent-quota-warmup-at-time.md](../../backlog/agent-quota-warmup-at-time.md).

**Why the obvious design is wrong (key finding).** The backlog's candidate v1
("isolated cwd + `claude -p 'Reply exactly: hi'`") is **obsolete as of the
June 15, 2026 Anthropic billing split.** Web research (corroborated across
multiple sources) confirms:

- The 5-hour window is triggered **only by interactive usage** — interactive
  Claude.ai chat and **interactive terminal Claude Code** advance/start it.
- **Headless `claude -p`** (plus Agent SDK, GitHub Actions, third-party agents)
  now draws from a **separate metered Agent SDK credit pool** (~$20 Pro /
  $100 Max5x / $200 Max20x, API rates, no rollover). Framing: *"if a human
  presses enter you stay on subscription; if a robot presses enter while you're
  away, that usage moves to the metered credit."*

So a `claude -p` warmup would **silently burn API credit and never move the
window**. The only mechanism that can move the 5-hour window is a **genuine
interactive Claude Code TUI session**. The realistic automated form of that:
launch real interactive `claude` in a **detached tmux session** (PTY-backed,
subscription auth, isolated cwd), then `tmux send-keys` a tiny prompt + Enter.

**Residual uncertainty (must verify empirically).** Whether Anthropic still
classifies a *tmux-driven* interactive session as "interactive" is unconfirmed.
The billing system almost certainly keys off client/session **type**, not who
physically pressed Enter, so a real interactive TUI should count — but the plan
includes a manual verification step before trusting the recurring install.

**Decisions captured from the user:**
- Pivot to **interactive-tmux** warmup (only thing that can move the window).
- Support **recurring** (launchd/systemd timer) **+ one-shot** (pueue).
- **Standalone** tool — leave `agent-wakeup`, the delayed-run scheduler, and the
  dashboard-TUI as separate backlog items.
- Also apply **code-quality fixes** to the existing Codex `agent-wakeup` (no
  history rewrite), with conventional commit messages.

## Design overview

New single-file uv-script CLI **`dot_dotfiles/bin/executable_agent-warmup`**
(PEP 723, `argparse`), mirroring the `executable_pqsum` pattern (on `~/.dotfiles/bin`
PATH, no shell wrapper needed). Claude-only (per backlog; Codex/OpenCode have
different quota systems).

Core mechanism reuses the proven interactive-spawn pattern from
`dot_config/shell/22_sesh.sh` (`tmux new-session -d ... "claude"`) and the pueue
group convention from `dot_config/television/executable_agent-wakeup.py:458`.

**Isolation choices:**
- Dedicated tmux socket `tmux -L agent-warmup` — keeps warmup sessions out of the
  user's main server/workspace and independent of it.
- Isolated cwd `${XDG_CACHE_HOME:-$HOME/.cache}/agent-warmup/claude` — no project
  `CLAUDE.md`/context. (Cache convention per `executable_lan-scan.sh`.)
- Bare `claude` (NOT `specstory run claude`) so no transcript is saved; NOT
  `--bare` (that forces `ANTHROPIC_API_KEY` = API billing, defeating the purpose).
  Default `--model haiku` (matches `AICAP_CLAUDE_MODEL` default in
  `dot_config/shell/04_ai_agents.sh:44`) to keep window-token consumption tiny.
- Force subscription auth: `unset ANTHROPIC_API_KEY` in the spawned env.

### Subcommands

| Command | Behavior |
|---|---|
| `agent-warmup run [--model H] [--prompt P] [--timeout S] [--keep] [--verify]` | Spawn detached tmux + interactive `claude` in isolated cwd; wait for ready; handle first-run folder-trust prompt; send prompt + Enter; wait for a reply; optionally send `/usage` and capture the panel (`--verify`); log to `run-<ts>.log`; kill session unless `--keep`; notify on failure. |
| `agent-warmup at (--at EXPR \| --delay EXPR) [run-flags]` | Queue a one-shot `agent-warmup run` via pueue (`--delay`/absolute), group `agent-warmup`, label `agent-warmup:oneshot:<ts>`. |
| `agent-warmup install (--daily DAYS --time HH:MM) [run-flags]` | Generate + load a recurring timer: macOS LaunchAgent (`StartCalendarInterval`) or Linux systemd user `.service`+`.timer`. Imperative/opt-in, written outside chezmoi management. |
| `agent-warmup uninstall` | Unload + remove the generated timer. |
| `agent-warmup status [--json]` | Show pending pueue one-shots + installed timer state + last N `run-*.log` summaries (timestamp, exit, whether `/usage` captured). |
| `agent-warmup cancel` | Remove pending pueue one-shots for this tool. |
| `agent-warmup verify` | Alias for `run --verify --keep` — the empirical experiment helper; prints the `/usage` panel for the user to eyeball. |

### `run` orchestration detail
1. `mkdir -p` cache + isolated cwd; acquire a lockfile (refuse if a prior warmup
   session is still alive — clean up stale ones).
2. `tmux -L agent-warmup new-session -d -s warmup-<ts> -c <isolated-cwd>` with env
   `ANTHROPIC_API_KEY` unset, running `claude --model <model>`.
3. Poll `tmux -L agent-warmup capture-pane` until the input box is ready; if a
   folder-trust prompt appears ("Do you trust the files…"), send Enter to accept
   (or pre-seed trust in the isolated `.claude/`). **Gotcha to handle.**
4. `send-keys` the prompt text, then `Enter` (mirror agent-wakeup's `C-u TEXT Enter`).
5. Poll until a response renders or `--timeout` (default ~90s) elapses.
6. If `--verify`: `send-keys "/usage" Enter`, wait, capture the rendered panel.
7. Capture final pane → append to `run-<ts>.log` with ISO timestamp + exit status.
8. `kill-session` unless `--keep`. On any failure (timeout, claude exited
   non-zero, auth error), emit a desktop notification.

### Notifications (no shared helper exists — add a tiny internal one)
The repo has no central notify utility. Add a small internal function:
`osascript -e 'display notification …'` on darwin, `notify-send` on Linux (guarded
by `command -v`), always also print to stderr. Keep it inside the script.

### Recurring timer generation
- **macOS** → `~/Library/LaunchAgents/com.<user>.agent-warmup.plist` with
  `StartCalendarInterval` (array of `{Weekday, Hour, Minute}` for the requested
  days/time), `ProgramArguments = [<abs path to>/agent-warmup, run]`, explicit
  `PATH` in `EnvironmentVariables` (chezmoi→cargo→uv→~/bin→brew, mirroring
  `scripts/fleet/exec.py:_PATH_PRELUDE`) since launchd has a minimal env. Load via
  `launchctl bootstrap gui/$(id -u) <plist>`. Validate with **`plutil -lint`**.
- **Linux** → `~/.config/systemd/user/agent-warmup.{service,timer}`; `service`
  is `Type=oneshot` calling `agent-warmup run`; `timer` uses `OnCalendar=`.
  `systemctl --user daemon-reload && systemctl --user enable --now agent-warmup.timer`.
  Validate with **`systemd-analyze verify`**.
- Caveat to document: if the machine is asleep at the scheduled time, the job
  fires on wake (launchd coalesces; systemd `Persistent=true`) — so window
  geometry may shift. Keychain must be unlocked (user logged in) for subscription
  auth to work from launchd.

## Code-quality fixes to existing `agent-wakeup` (separate commits)
File `dot_config/television/executable_agent-wakeup.py`:
- **Tighten `_QUOTA_LINE_RE`** (`:138`) with word boundaries; the bare `quota` and
  `hit your .*limit` are over-broad (Issue B).
- **Fold the HUD post-hoc string checks into the regex** in
  `_is_claude_hud_usage_line` (`:157`) so detection isn't split across regex +
  three `startswith`/substring checks (Issue D).
- **Add an explanatory comment** on the `recommended_action` (full text) vs
  `active_quota_text`/`detect_quota` (last-24-lines) asymmetry (`:244`, `:326`) —
  document, don't change behavior (Issue C).

File `dot_config/shell/62_agent_wakeup.sh`:
- **Guard empty script path**: `[ -z "$_aw_script" ] || [ ! -x … ]` (Issue F).

## Critical files
- **New:** `dot_dotfiles/bin/executable_agent-warmup` (the CLI).
- **New:** `dot_config/zsh/tools/49_agent_warmup_completion.zsh` +
  `dot_config/bash/49_agent_warmup_completion.bash` (hand-written Strategy B
  completions, kept in sync — per CLAUDE.md "new in-house CLI" rule; pattern from
  `48_pqsum_completion.zsh`).
- **New:** `docs/tools/agent-warmup.md` + nav entry in `mkdocs.yml`
  (run `uv run mkdocs build --strict`).
- **New:** `pitfalls/headless-claude-p-does-not-move-5h-window.md` (symptom-titled:
  warmup "succeeds" but `/usage` shows no new window / API credit drained).
- **Edit:** `backlog/agent-quota-warmup-at-time.md` — record the billing finding,
  mark candidate v1 obsolete, link to the implemented tool.
- **Edit:** `docs/zsh/zsh-completions.md` Section F table (add `agent-warmup` row).
- **Edit:** existing `agent-wakeup` files for the quality fixes above.

## Cross-file maintenance (per CLAUDE.md)
- In-house CLI → two completion files + Section F table row. ✅ above.
- New docs page → `mkdocs.yml` nav + `mkdocs build --strict`. ✅ above.
- Recurring timer is **imperative/opt-in** (generated by `install`, untracked) —
  deliberately **not** chezmoi-managed, so **no** `.chezmoi.toml.tmpl` prompt /
  `gen-prompts` churn and no per-machine forced install.
- `tool-managers.md`: agent-warmup is repo-shipped (like pqsum/fleet), not a
  manager-installed tool → check whether pqsum/fleet have rows; only add one if
  that's the established convention.
- Commit messages: conventional `feat(agent):` / `fix(agent):` / `docs(agent):`
  with a body and `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

## Verification
**1. Empirical window experiment (do FIRST, before trusting recurring install):**
- Near a known reset boundary, run `agent-warmup verify`. Inspect the kept tmux
  session and the captured `/usage` panel: confirm a **new 5-hour session window
  started/advanced**. If it does **not** move the window, stop and revisit (the
  tmux-interactive classification assumption failed) — update the pitfall + backlog.

**2. Functional checks:**
- `agent-warmup run --keep` → attach to `tmux -L agent-warmup` and confirm the
  prompt was sent and answered in the isolated cwd (no project context loaded).
- `agent-warmup at --delay 1m` → `pueue status` shows the queued job; it fires.
- `agent-warmup install --daily weekdays --time 06:00` then:
  - macOS: `plutil -lint` the plist; `launchctl print gui/$(id -u)/…`;
    `launchctl kickstart -k gui/$(id -u)/com.<user>.agent-warmup` to force a run.
  - Linux: `systemd-analyze verify` the units; `systemctl --user list-timers`;
    `systemctl --user start agent-warmup.service` to force a run.
- `agent-warmup status` reflects pending one-shots, installed timer, last runs.
- `agent-warmup uninstall` cleanly removes the timer.

**3. agent-wakeup fixes:** `python3 -c "import ast; ast.parse(open('dot_config/television/executable_agent-wakeup.py').read())"`
plus a quick `agent-wakeup status` smoke; source `62_agent_wakeup.sh` in both
`zsh` and `bash` to confirm no syntax error.

**4. Docs:** `uv run mkdocs build --strict` passes.
