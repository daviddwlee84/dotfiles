# Plan: `tsum` — AI-powered tmux session summarizer

## Context

User routinely has 10+ tmux sessions open with cryptic names (`9`, `10`, `19`,
`20`, `tries/2026-03-23-RL-Investigation`, `coding-agent/…`). Glancing at
`tmux ls` no longer tells them what each session is *for* or which windows are
load-bearing. The user wants a single command that asks an LLM to summarize
every session ("what is this session", "which 1-3 windows are important"),
shown both as plain stdout (`tsum`) and as a tmux popup picker that switches
clients on Enter.

Outcome: one new command `tsum` + one new tmux menu entry, reusing the repo's
existing agent autodetect order (claude → opencode → codex → cursor-agent) and
caching results for 10 min in `$XDG_CACHE_HOME` so the LLM cost stays bounded.

## Architecture

Three layers, one per managed file:

```
┌── ~/.config/tmux/tmux-session-summary.py    ── core: capture + LLM + cache
├── ~/.config/shell/61_tmux_summary.sh        ── thin POSIX wrapper `tsum`
└── ~/.config/tmux/executable_menu-session.sh ── menu row → popup → fzf
```

Core in Python because the repo already has `scripts/aiblock.py` as the
template for PEP 723 / `uv run --script` agent invokers — caching JSON,
parsing `tmux list-windows -F`, building structured prompts, and fzf piping
are all cleaner in Python than POSIX sh. Wrapper is POSIX (in `dot_config/shell/`)
so bash users get `tsum` too — the function does nothing zsh-specific.

## Files to add / modify

### 1. New: `dot_config/tmux/executable_tmux-session-summary.py`

PEP 723 inline-deps script (`#!/usr/bin/env -S uv run --script`, deps:
`rich>=13.9`). Modeled directly on
[`scripts/aiblock.py`](../../scripts/aiblock.py) — reuse the
`AGENT_CONFIG` dict + `AICAP_*` env-var defaults verbatim (see
`scripts/aiblock.py:55-78`) so a user's existing `AICAP_AGENT` /
`AICAP_CLAUDE_MODEL` overrides apply transparently.

Subcommands (CLI surface):

```
tmux-session-summary.py list       [--deep] [--refresh] [--dry-run]
tmux-session-summary.py picker     [--deep] [--refresh]
```

Behaviour:

- **`list`** — print one block per session to stdout. Plain text, switch-friendly:
  ```
  9    [12w] dotfiles edits — agent contract refactor
         └ w7: nvim CLAUDE.md   (primary editor)
         └ w2: chezmoi apply test runner
  10   [10w] ML scraper — currently running
         └ w3: python scrape.py (5h uptime, active)
  ```
- **`picker`** — print TSV `<session>\t<one-line-summary>` to stdout for fzf
  consumption.
- **`--deep`** — additionally include `tmux capture-pane -p -S -20 -t <sess>:<win>`
  output for each window's active pane in the LLM prompt. Off by default;
  inflates tokens 10–50× and risks leaking pane contents.
- **`--refresh` / `-r`** — bypass cache, force a fresh LLM call.
- **`--dry-run`** — print the prompt that *would* be sent to the LLM without
  invoking; lets the user see what context is leaked before trusting it.

Capture pipeline (per CLAUDE.md "Tmux Content Capture Patterns"):

1. `tmux list-sessions -F '#{session_name}|#{session_windows}|#{session_created}|#{session_attached}|#{session_last_attached}'`
2. For each session: `tmux list-windows -t <s> -F '#{window_index}|#{window_name}|#{window_active}|#{pane_current_path}|#{pane_current_command}|#{window_panes}'`
3. (`--deep` only) `tmux capture-pane -p -S -20 -t <s>:<active_win>` once per session

Caching:

- Path: `$XDG_CACHE_HOME/tmux-session-summary/<hostname>-<sig>.json`
  (falls back to `~/.cache/tmux-session-summary/` if `XDG_CACHE_HOME` unset).
- Signature: SHA-256 over the sorted `tmux list-sessions` + `list-windows`
  output (so adding a window invalidates; idle navigation doesn't).
- TTL: 10 min from `generated_at` ISO-8601 stamp.
- Cache contains one record per session keyed by `session_name`; if a session
  vanishes between runs it's just dropped.
- `tsum -r` writes a fresh entry, replacing whatever existed.

Agent invocation:

- Reuse `AGENT_CONFIG` from `scripts/aiblock.py:72-78` (claude / opencode /
  codex / cursor-agent / http). Autodetect order matches
  `dot_config/zsh/tools/04_ai_capture.zsh:58-67`. Pin model defaults to the
  cheap tier already chosen in that file (`haiku`, `gpt-5-mini`, etc.) — these
  are summarization tasks, no need for frontier models.
- One LLM call per `tsum` invocation, not per session: send all sessions in
  one structured prompt, ask for a JSON array of `{session, summary,
  important_windows[]}` back. JSON output is parsed; on parse failure fall
  back to raw text rendering.
- Use the same `_aicap_spinner_start/stop` pattern from
  `dot_config/zsh/tools/04_ai_capture.zsh:74-98` (re-implemented in Python
  with `rich.status.Status` or a small braille spinner on stderr).

Failure modes:

- No agent CLI on PATH → exit 1 with the same message style as
  `04_ai_capture.zsh:328` (mentions all four candidates by name).
- Not inside tmux **and** no `--list-from-pty` flag → exit 1 with hint.
- LLM call times out (>60s) → fall back to printing the raw metadata
  capture without summaries (degraded mode beats no output).

### 2. New: `dot_config/shell/61_tmux_summary.sh`

POSIX-shared shell wrapper, sourced by both `~/.zshrc` and `~/.bashrc`
(slot 61 sits right after `60_tmux_status.sh` which it complements).

```sh
# Skip silently if tmux not on PATH (cron, headless boxes pre-ansible).
command -v tmux >/dev/null 2>&1 || return 0

tsum() {
    # Flags: -d|--deep, -r|--refresh, -i|--interactive (fzf picker), --dry-run
    # Default: print plain-text summary list
    # -i: pipe `picker` mode to fzf, on Enter call `tmux switch-client -t {1}`
    # All other flags forwarded to ~/.config/tmux/tmux-session-summary.py
    …
}
```

Notes:

- ~40 lines total; argparse loop + one of two invocation paths (plain `list`
  or `picker | fzf …`).
- Does NOT depend on `_aiagent_autodetect` from `04_ai_capture.zsh` (zsh-only)
  — early-return uses a tiny POSIX probe: `for c in claude opencode codex
  cursor-agent; do command -v "$c" >/dev/null && break; done` or skip the
  probe entirely and let the Python script emit the canonical error.
- `-i` requires `fzf` on PATH; otherwise prints a hint and falls back to plain
  list.

### 3. Modify: `dot_config/tmux/executable_menu-session.sh`

Add one row inside the existing `rows=( … )` array (this submenu is the right
home: the feature is *about understanding sessions*; LLM is just the
implementation). Conditional on `~/.config/tmux/tmux-session-summary.py`
existing so the row hides on hosts that haven't done `chezmoi apply` yet:

```bash
if [ -x "$HOME/.config/tmux/tmux-session-summary.py" ]; then
  rows+=(
    "AI session summary"  u  "display-popup -E -w 90% -h 70% -d '#{pane_current_path}' -T ' AI session summary ' '$HOME/.config/tmux/tmux-session-summary.py picker | fzf --delimiter=\"\\t\" --with-nth=2 --preview \"echo {2}\" --bind \"enter:execute-silent(tmux switch-client -t {1})+abort\"'"
  )
fi
```

Hard rule check (CLAUDE.md "Tmux Popup Menu"):

- Popup at 90%×70% — the inner fzf paginates so the menu-too-tall failure
  doesn't apply to fzf content.
- The outer `display-menu` row count: this submenu currently has ~8 rows; one
  more is safe well under the 14-row cap. Verify by running
  `prefix+Space → Sessions` after install.
- The fzf invocation has braces and pipes — they live inside the *executed
  shell command* not the tmux `display-menu` parser, so the parser-quoting
  trap doesn't apply.

### 4. Modify: `docs/shells/aliases.md`

Add one row to the function table (header at `docs/shells/aliases.md:38-39`):

```markdown
| `tsum` | function | `dot_config/shell/61_tmux_summary.sh` | AI-summarize tmux sessions (claude/opencode/codex/cursor-agent fallback; cached 10 min; `-d` deep, `-i` fzf-pick & switch). |
```

### 5. Optional: `docs/tools/tmux/session-summary.md` + `mkdocs.yml` nav

Short reference page (~80 lines) covering: invocation forms, env vars
(`AICAP_*`, `TSUM_CACHE_TTL`), what gets sent to the LLM (so users can audit
before opting in), deep-mode warning, cache invalidation rules. **Defer
unless the user wants it** — `aliases.md` row + inline header docstring in
the Python script may be enough.

If added: append a nav entry under `Tools → Tmux` in `mkdocs.yml`, then
`uv run mkdocs build --strict`.

## Reused utilities (do not reinvent)

| Need | Reuse from | Why |
|---|---|---|
| Agent CLI fallback order | `dot_config/zsh/tools/04_ai_capture.zsh:58-67` | Same order the user already expects (`_aiagent_autodetect`) — inlined as a Python equivalent in the new script. |
| Per-agent invocation flags / env defaults | `scripts/aiblock.py:55-78` (`AGENT_CONFIG`, `AICAP_*`) | Already proven; using identical env vars means user's `AICAP_CLAUDE_MODEL=haiku` etc. carry over automatically. |
| Spinner on stderr while LLM is thinking | `dot_config/zsh/tools/04_ai_capture.zsh:74-98` (`_aicap_spinner_start/stop`) | Reimplement small Python equivalent — non-tty/AICAP_SPINNER=0 must remain a no-op. |
| Tmux metadata capture format | `dot_config/shell/60_tmux_status.sh:114` (`tmux list-windows -aF '…'`) and `dot_config/zsh/tools/38_workmux.zsh:39` | Same format strings; consistent across helpers. |
| Pane content capture | `dot_config/zsh/tools/03_tmux_capture.zsh` (`tmux capture-pane -p …`) | Same flag set; `--deep` mode mirrors `cpout`'s scope (just last N lines, no copy-mode chain needed since we don't need OSC 133 boundaries). |
| Popup script convention | `dot_config/tmux/executable_menu-agents.sh:11` (`display-popup -E -w 80% -h 70% -d '#{pane_current_path}' -T ' Title '`) | Same template; just swap the inner command. |

## Cross-file maintenance touchpoints (per CLAUDE.md)

- **Alias/shell function** → add row to `docs/shells/aliases.md` ✓ (covered in §4 above).
- **Three-tier file placement** → core script under `dot_config/tmux/`,
  wrapper in `dot_config/shell/` (POSIX shared) — both shells get `tsum`. No
  zsh-only widgets needed. ✓
- **Keybinding cross-check** → no new `Ctrl+`/`Alt+` binding (menu-entry only,
  reached via `prefix+Space → Sessions`). ✓
- **`docs/**/*.md` nav** → only triggers if §5 (the optional doc page) is
  added. Defer until the user asks. ✓
- **chezmoi-templating** → none of the new files need `{{ … }}` predicates;
  they Just Work on macOS / Linux alike. The Python shebang `#!/usr/bin/env
  -S uv run --script` is the same pattern as `scripts/aiblock.py`. ✓

## Verification (run after implementation)

1. `chezmoi apply` (then `source ~/.zshrc` or `exec zsh`) — confirms the new
   files land and `tsum` is on PATH.
2. `tsum --dry-run` — prints the prompt that would be sent (audit what's
   leaked to the LLM; no API call).
3. `tsum` on the user's current host (12 sessions visible in the snapshot):
   confirm one-block-per-session output, plausible summaries.
4. `tsum` again immediately → cache hit, returns in <500 ms with no spinner.
5. `tsum -r` → cache bypass, fresh LLM call.
6. `tsum -d` → output includes pane-content-informed details (e.g. picks up
   on a long-running `python scrape.py`).
7. `tsum -i` → fzf opens with summaries, Enter switches client to the chosen
   session.
8. `prefix+Space → Sessions → AI session summary` → tmux popup opens, fzf
   inside, Enter switches the underlying client. **Resize terminal vertically
   to ~22 rows and retest** (CLAUDE.md "menu-too-tall silent failure" rule).
9. `AICAP_AGENT=opencode tsum -r` → verifies the fallback chain honours the
   override env var.
10. Unset every agent CLI from PATH (`PATH=/usr/bin tsum`) → exits 1 with the
    "install one of claude/opencode/codex/cursor-agent" message.
11. `mkdocs build --strict` if §5 doc page added; otherwise skip.

## Out of scope (intentionally)

- Per-session lazy caching (user picked the simpler 10-min-blanket strategy).
- A standalone Python TUI like `aiblock` — `tsum -i` via fzf is leaner.
- Auto-renaming sessions based on the summary (destructive; ask later).
- Multi-host summary (this is local-host only; fleet-status already exists).
- Putting the menu row under `executable_menu-agents.sh` instead of
  `executable_menu-session.sh` — the feature is *about sessions*, AI is the
  implementation detail.
