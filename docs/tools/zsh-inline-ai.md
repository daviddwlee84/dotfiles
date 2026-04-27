# aisuggest — prompt-time NL→shell ghost text

Type a natural-language description at the zsh prompt → press the trigger → ghost text appears showing the suggested command → Tab or → to accept, keep typing to dismiss. Inspired by [`kylesnowschwartz/zsh-ai-cmd`](https://github.com/kylesnowschwartz/zsh-ai-cmd) (MIT); reimplemented from scratch with our own naming so it routes through the existing [`_aiagent_invoke`](aicapture.md) layer (claude → opencode → codex → cursor-agent autodetect, no API key needed).

This is the **prompt-time** counterpart to [`aicapture`](aicapture.md). Two distinct use cases:

| | `aicapture` (`aifix` / `aiexplain`) | `aisuggest` |
|---|---|---|
| Trigger | After a command ran; type `aifix` | While typing; press `Alt+;` |
| Input | Captured tmux output of a past block | Current `BUFFER` text (natural language) |
| Output | Multi-paragraph diagnosis (Markdown) | One shell command (ghost text → buffer) |
| UI | Streamed to stdout in the next prompt | ZLE postdisplay + region_highlight |

## Quick start

```sh
# Type a description, press Alt+; for a suggestion
find files larger than 100 MB
# (Alt+;)
find files larger than 100 MB  ⇥  find . -size +100M       ← ghost text in fg=8
# (Tab)
find . -size +100M                                          ← buffer replaced; press Enter
```

If the suggestion happens to be an *extension* of what you already typed (e.g. `git log --` → `git log --oneline -20`), the ghost text shows only the *suffix* with no `⇥` indicator, so you can keep typing characters that match and the suggestion stays alive.

## Configuration

| Env var | Default | Notes |
|---|---|---|
| `AISUGGEST_KEY` | `^[;` (Alt+;) | zsh keybind notation. Override in `~/.zshrc.adhoc`. Ctrl+Z is intentionally NOT used (preserves SIGTSTP); `^[/` (Alt+/) is a fine alternative on layouts where `;` is awkward. |
| `AISUGGEST_AGENT` | empty (autodetect) | Pin to `claude` / `opencode` / `codex` / `cursor-agent` to skip autodetect. |
| `AISUGGEST_MODEL` | empty (per-agent default) | When empty, falls through to `AICAP_<AGENT>_MODEL` from `04_ai_capture.zsh`. |
| `AISUGGEST_HIGHLIGHT` | `fg=8` | zsh `region_highlight` style for the ghost text. |
| `AISUGGEST_PROMPT_OVERRIDE` | empty | Replace the built-in system prompt entirely. Power-user knob. |
| `AISUGGEST_DEBUG` | `0` | `1` enables debug logging. |
| `AISUGGEST_LOG` | `/tmp/aisuggest.log` | Debug log path. |

Override in `~/.zshrc.adhoc` (untracked) or `~/.config/zsh/secrets.zsh`. Don't edit `dot_config/zsh/tools/05_aisuggest.zsh` directly.

## ZLE widget anatomy (how the ghost text actually works)

This section captures the design we adopted from upstream (commit [`cda55e1`](https://github.com/kylesnowschwartz/zsh-ai-cmd/commit/cda55e1)) so future maintainers can reason about it without re-reading the upstream code.

### State machine — Dormant ↔ Active

The widget has two states. Five globals track Active state:

| Global | Role |
|---|---|
| `_AISUGGEST_ACTIVE` | `0`/`1` flag — main gate for accept/dismiss handlers |
| `_AISUGGEST_SUGGESTION` | The full suggested command text |
| `_AISUGGEST_BUFFER_AT_SUGGESTION` | Snapshot of `$BUFFER` when ghost text was rendered |
| `_AISUGGEST_LAST_HIGHLIGHT` | The exact `region_highlight` entry we appended (so we can remove only that one on deactivate, not clobber other plugins') |
| `_AISUGGEST_ORIG_TAB` / `_AISUGGEST_ORIG_RIGHT` | The Tab and right-arrow widgets bound *before* we activated, so we can restore them on deactivate |

### Trigger flow (Alt+; pressed)

1. Bail if `BUFFER` is empty (no input → nothing to translate).
2. Background the agent invocation (`_aiagent_invoke`) writing to a temp file.
3. Animate a spinner via `POSTDISPLAY` while the agent thinks. Polling `read -t 0.1 -k 1` lets *any* keypress cancel.
4. On response: sanitize (strip ANSI escapes + control chars), then call `_aisuggest_show_ghost` and `_aisuggest_activate`.

### Display: POSTDISPLAY + region_highlight (NOT BUFFER mutation)

We use zsh's `POSTDISPLAY` variable (text rendered after the cursor, never part of `BUFFER`) plus a single `region_highlight` entry styling its bytes. Two display modes:

- **Suggestion is a prefix-extension of buffer**: `POSTDISPLAY="${suggestion#$BUFFER}"`. Pure inline completion — the suggestion *grows* the buffer when accepted.
- **Suggestion is different**: `POSTDISPLAY="  ⇥  ${suggestion}"`. Tab-hint indicator tells the user "Tab will *replace*, not append".

The `region_highlight` entry covers byte indices `[$#BUFFER, $#BUFFER + $#POSTDISPLAY)` and is stored verbatim in `_AISUGGEST_LAST_HIGHLIGHT` so we can remove exactly that entry — leaving any other plugin's highlights untouched — via:

```zsh
region_highlight=("${(@)region_highlight:#$_AISUGGEST_LAST_HIGHLIGHT}")
```

### Why POSTDISPLAY (and not append-to-BUFFER)

POSTDISPLAY is "text shown after the cursor that isn't part of the editable buffer". Modifying `BUFFER` would force the user to manually edit out the suggestion if they want to dismiss it — that's the wrong UX. POSTDISPLAY is invisible to `BUFFER`-reading code and clears trivially by setting `POSTDISPLAY=""`.

### Activate: dynamically rebind Tab and →

The clever bit. Tab is sacred — globally rebinding it to "accept suggestion" would break filename completion forever. So `_aisuggest_activate` *temporarily* steals Tab and right-arrow:

```zsh
_AISUGGEST_ORIG_TAB=$(bindkey -M main '^I' | awk '{print $2}')
bindkey '^I'  _aisuggest_accept_tab
bindkey '^[[C' _aisuggest_accept_right
```

`_aisuggest_deactivate` restores them. So Tab → accept while a suggestion is live, Tab → completion the rest of the time.

### Dismiss: `line-pre-redraw` hook with smart prefix logic

A hook fires on every redraw. If active and `$BUFFER != $_AISUGGEST_BUFFER_AT_SUGGESTION`:

- **Buffer is still a prefix of the suggestion** → re-render ghost text and update the snapshot. (User typed forward characters that match — keep the suggestion alive.)
- **Buffer diverged** → deactivate, clear POSTDISPLAY + highlight, restore Tab/→.

We register the hook via `add-zle-hook-widget line-pre-redraw` when available (chains alongside `zsh-syntax-highlighting`'s and `zsh-autosuggestions`' hooks); falls back to direct `zle -N zle-line-pre-redraw` otherwise. Chaining is important — overriding the widget kills syntax highlighting.

### Line-finish: deactivate on Enter

`zle-line-finish` fires when the line is submitted (Enter). We deactivate to restore Tab/→ before the line runs — otherwise next-line state is stale.

## Provider integration

`_aisuggest_query` is the single shim into our agent layer. It:

1. Picks an agent: `${AISUGGEST_AGENT:-$(_aiagent_autodetect)}` (autodetect from `04_ai_capture.zsh:36-45` — same order as `aifix`/`aiexplain`).
2. Builds the system prompt (built-in unless `AISUGGEST_PROMPT_OVERRIDE` is set).
3. Calls a *low-latency* invocation that suppresses metadata, spinner, and prettify (`AICAP_SHOW_METADATA=0 AICAP_SPINNER=0 AICAP_PRETTIFY=0`) via `_aiagent_invoke`.
4. Post-filters: `head -1` (one line only) and `sed` to strip leading `$`/`#` prompt symbols and surrounding backticks the model might add despite the system prompt.

For Claude specifically, we'd ideally use the upstream-style flag profile (`--no-session-persistence --effort low --no-chrome --tools "" --setting-sources ""`) to drop response time from ~5s to ~1.5s. Future enhancement; the MVP relies on `_aiagent_invoke`'s default flags.

### System prompt design

Inspired by upstream's prompt (rules-only, no chain-of-thought, with examples). Key rules:

- One command, no markdown, no prose.
- BSD vs GNU awareness (the model gets PWD + OS via context).
- Prefix standard tools with `command` to bypass aliases (so `ls -la` → `command ls -la`).
- Example pairs covering: file find, grep, git, lsof, du, date, tar, ffmpeg.

Override the whole thing via `AISUGGEST_PROMPT_OVERRIDE`.

## Interaction with other plugins

### `zsh-autosuggestions` (POSTDISPLAY clobber — root cause + fix)

Both plugins write `POSTDISPLAY`. The diagnostic log on 2026-04-27 showed our widget renders ghost text, then by the time the next pre-redraw fires, POSTDISPLAY is empty:

```
widget: rendered ghost, activated
pre_redraw: BUFFER=[show current disk space] snap=[show current disk space] POSTDISPLAY=[]
```

**Root cause** (in `~/.oh-my-zsh/custom/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh:220-221`): autosuggestions binds every non-underscore-prefixed, non-`autosuggest-*` ZLE widget as a "modify" widget — the comment in source says "Assume any unspecified widget might modify the buffer". The wrapper function `_zsh_autosuggest_modify` (`src/widgets.zsh:39`) does this around every wrapped invocation:

```zsh
local orig_postdisplay="$POSTDISPLAY"   # save (empty before our widget)
POSTDISPLAY=                            # clear
_zsh_autosuggest_invoke_original_widget $@   # ← runs our _aisuggest_widget
# … then, if BUFFER didn't change …
POSTDISPLAY="${orig_postdisplay:…}"     # restore the empty value, clobbering ours
```

Pressing Alt+; doesn't change BUFFER (we don't write to it), so the BUFFER-unchanged branch fires and POSTDISPLAY gets reset to the (empty) pre-widget value.

**Fix.** Tell zsh-autosuggestions to not wrap our widgets, by adding them to its `ZSH_AUTOSUGGEST_IGNORE_WIDGETS` array at file source time:

```zsh
typeset -ga ZSH_AUTOSUGGEST_IGNORE_WIDGETS
ZSH_AUTOSUGGEST_IGNORE_WIDGETS+=(aisuggest _aisuggest_accept_tab _aisuggest_accept_right _aisuggest_pre_redraw)
```

This works because autosuggestions' `_zsh_autosuggest_start` runs as a `precmd` hook and re-binds widgets every prompt by default — it reads the ignore list fresh on each rebind, so appending in our file sourced after OMZ takes effect on the next prompt.

**Defense-in-depth.** `_aisuggest_pre_redraw` still re-asserts POSTDISPLAY if it goes empty while active, in case another POSTDISPLAY consumer slips in. Cheap insurance.

Why we don't call `_zsh_autosuggest_disable` instead: `_zsh_autosuggest_disable` itself calls `_zsh_autosuggest_clear`, which sets POSTDISPLAY="" — actively making the problem worse if invoked at the wrong moment. `ZSH_AUTOSUGGEST_IGNORE_WIDGETS` is the surgical fix.

### `zsh-vi-mode` (bindkey wipe)

`zsh-vi-mode` calls a private function on init that drops every `bindkey`. It exposes a `zvm_after_init` hook so plugins can re-apply their bindings. Our trigger key is rebound there; see `dot_zshrc.tmpl`. The Tab/→ swap-bind happens *during* widget invocation (after init) so it's not affected.

### `zsh-syntax-highlighting` (line-pre-redraw)

Repaints `region_highlight` on every redraw. Because we use `add-zle-hook-widget` (chains rather than overrides), our hook runs alongside theirs. Our highlight entry is appended after theirs each redraw — visible and correctly styled.

## Debugging

Two surfaces for diagnosis when the widget misbehaves:

### CLI (synchronous, no ZLE in the picture)

```sh
aisuggest "find files larger than 100 MB"           # prints the suggested command
aisuggest --debug "find files larger than 100 MB"   # also prints raw / sanitized / final to stderr
```

Use this to test whether `_aisuggest_query` itself is healthy — agent reachable, prompt followed, post-filter not over-stripping. If the CLI works but the widget doesn't, the bug is in the widget-specific path (subshell, spinner, POSTDISPLAY render).

### Widget tracing

```sh
export AISUGGEST_DEBUG=1                            # toggleable at runtime, no restart
: > /tmp/aisuggest.log                              # truncate
# trigger Alt+; on a description
cat /tmp/aisuggest.log
```

Each step writes a labelled line: `widget: enter`, `widget: backgrounded pid=…`, `widget: spinner exited at i=N, reading tmpfile`, `widget: raw stdout (len=N)=[…]`, `show_ghost: POSTDISPLAY=[…]`, `activate: orig_tab=[…] autosuggest_paused=…`, `pre_redraw: BUFFER=[…] snap=[…] POSTDISPLAY=[…]`, `deactivate: called from <function>`.

Common failure modes → log signatures:

| Symptom | Log line that points to it | Likely fix |
|---|---|---|
| Spinner runs, then nothing visible | `rendered ghost, activated` followed by `pre_redraw: ... POSTDISPLAY=[]` | POSTDISPLAY contention — verify `_zsh_autosuggest_disable` ran (`autosuggest_paused=1` in activate log line); fallback re-assert should trigger |
| Spinner cancels almost immediately | `widget: read cancelled at i=N (key='…')` | Stale input in the TTY buffer or a key event leaking through; switch cancel mechanism |
| Spinner runs, "no suggestion" message | `widget: empty suggestion → 'no suggestion' branch`, `widget: raw stdout (len=0)` | Subshell-context agent failure — check `widget: raw stderr=[…]` for the underlying error |
| Widget activates then immediately deactivates | `deactivate: called from _aisuggest_pre_redraw (POSTDISPLAY was [...])` | Buffer mismatch; check `pre_redraw` BUFFER vs snap |

Disable debug logging: `export AISUGGEST_DEBUG=0` (no restart needed; `_aisuggest_log` checks the flag at call time).

## Troubleshooting

| Symptom | Diagnosis |
|---|---|
| Trigger does nothing | Check `bindkey \| grep '\^\[;'` — if missing, `zvm_after_init` didn't rebind. Check `zle -l \| grep aisuggest` — if missing, the file didn't source (look for guard-bail at top: missing claude/opencode/codex/cursor-agent CLI, or missing curl/jq). |
| Ghost text appears but Tab opens completion menu instead of accepting | `_aisuggest_activate` failed to swap-bind Tab. Check `bindkey '^I'` while active — should show `_aisuggest_accept_tab`. |
| Ghost text doesn't clear on edit | The `line-pre-redraw` hook isn't firing. Check `zle -l \| grep -i pre-redraw` — if `add-zle-hook-widget` wasn't available, fallback set `zle-line-pre-redraw` directly which can be clobbered by other plugins. |
| Suggestions take >5s | Default agent uses `_aiagent_invoke`'s standard flags (claude with JSON output). Pin a faster agent: `export AISUGGEST_AGENT=opencode`. |
| Wrong agent picked | Set `AISUGGEST_AGENT` explicitly. `_aiagent_autodetect`'s order is claude → opencode → codex → cursor-agent; whichever is first on PATH wins. |
| Job control broken (`Ctrl+Z` doesn't suspend) | Someone set `AISUGGEST_KEY=^Z`. Reset to default `^[;`. |
| Pressed Enter, got `command not found: <my words>` | The ghost text is a hint, not the buffer contents. **Tab or →** replaces `BUFFER` with the suggestion; **Enter** runs `BUFFER` as-is. Press Tab first, *then* Enter. |

Enable debug logging:

```sh
export AISUGGEST_DEBUG=1
export AISUGGEST_LOG=~/.cache/aisuggest.log
exec zsh
# Trigger a few suggestions, then:
tail -f ~/.cache/aisuggest.log
```

## Re-study upstream for new ideas

Upstream evolves; we don't auto-pull. Re-read with:

```sh
git clone --depth 1 https://github.com/kylesnowschwartz/zsh-ai-cmd /tmp/zsh-ai-cmd-study
```

Files worth re-reading on a refresh pass:

- `zsh-ai-cmd.plugin.zsh` — widget mechanics, state machine, sanitization.
- `prompt.zsh` — prompt design changes; consider porting good rule additions.
- `providers/claude-code.zsh` — claude CLI flag profile for low latency.
- `CHANGELOG.md` — what changed since `cda55e1` (the commit our design was learned from).

If upstream adds a feature we want (e.g., async-via-`zle -F` for non-blocking spinner), we port the *idea* into our `05_aisuggest.zsh`, not the code.

## Roadmap — ideas worth porting

Concrete enhancements identified during the upstream study at commit `cda55e1`. Listed roughly in payoff-vs-effort order; pick one when you next touch this file.

### 1. Low-latency claude flag profile *(high payoff, low risk)*

Today our `_aisuggest_query` shells out via `_aiagent_invoke` which calls `claude -p --model "$AICAP_CLAUDE_MODEL"` (with JSON output for metadata). For inline suggestions we don't need the metadata, and Claude Code's CLI startup dominates the 1–3 s response time. Upstream's [`providers/claude-code.zsh`](https://github.com/kylesnowschwartz/zsh-ai-cmd/blob/main/providers/claude-code.zsh) uses a stripped-down profile that they measure as ~1.5× faster:

```sh
claude -p --no-session-persistence --effort low \
       --disable-slash-commands --strict-mcp-config \
       --setting-sources "" --no-chrome --tools "" \
       --system-prompt "$prompt" "$user_input"
```

Two ways to take this:

- **A.** Add a parallel low-latency path in `_aisuggest_query`: when `agent == claude`, bypass `_aiagent_invoke` and shell out directly with the upstream flag profile + `--system-prompt`. Keeps `_aiagent_invoke` unchanged for `aifix`/`aiexplain`.
- **B.** Add a new `_aiagent_invoke_fast` in `04_ai_capture.zsh` that takes a system prompt separately and uses the stripped-down flags for *all* agents (opencode `--no-system-context`, etc.). Cleaner abstraction; more work; touches `aifix`/`aiexplain`.

(A) is the safer first move.

### 2. `--system-prompt` separation *(small but cleaner)*

Currently we concatenate system + context + user input into one `prompt` string and pass it as the user message. Claude follows it, but `--system-prompt` ([upstream uses this](https://github.com/kylesnowschwartz/zsh-ai-cmd/blob/main/providers/claude-code.zsh)) lets the model treat rules as immutable system context. Tighter rule-following, occasionally fewer "explanation slipped through" cases. Pairs naturally with idea (1).

### 3. Async via `zle -F` *(medium effort, big UX win)*

Today `_aisuggest_widget` blocks the prompt for the duration of the agent call. The spinner-on-POSTDISPLAY animation hides this *visually*, but you can't keep typing during the wait — any keypress cancels the request. zsh's `zle -F <fd> <handler>` lets you register a callback when an FD becomes readable, so you can fire the agent in the background, return immediately to the prompt, and have the suggestion *land* asynchronously when the FD has data. Upstream doesn't do this either, but it's the natural next UX leap. Sketch: `mkfifo` or `mktemp` → fork agent → `zle -F $fd _aisuggest_on_response` → user types freely → callback fires when response arrives → render ghost text if buffer hasn't diverged.

Constraint: must handle "user submitted line before response arrived" gracefully — `_aisuggest_line_finish` should kill the FD watcher.

### 4. Direct API providers (anthropic / openai / gemini) *(only if needed)*

We currently *only* support the four CLIs (`claude`, `opencode`, `codex`, `cursor-agent`). Users without any of those installed get nothing. Upstream supports direct API calls via `curl` + `jq` for anthropic / openai / gemini / deepseek / ollama / copilot. If we ever want a no-CLI fallback, port the [`providers/anthropic.zsh`](https://github.com/kylesnowschwartz/zsh-ai-cmd/blob/main/providers/anthropic.zsh) pattern (single `curl -s` POST, `jq -r '.content[0].text'` extract). Pair with upstream's [`ZSH_AI_CMD_API_KEY_COMMAND`](https://github.com/kylesnowschwartz/zsh-ai-cmd/blob/main/README.md#custom-api-key-retrieval) pattern so users can pull the key from `op`, `pass`, GNOME Keyring, AWS Secrets Manager, etc. — flexible without baking provider knowledge into us.

Flag for pickup: this is a *user-driven* enhancement — only do it when someone asks for it, since it adds curl/jq dependencies on the hot path and a maintenance surface.

### 5. Sanitize regression test *(cheap insurance)*

Upstream ships [`test-sanitize.sh`](https://github.com/kylesnowschwartz/zsh-ai-cmd/blob/main/test-sanitize.sh) — feeds crafted ANSI / control-character payloads through `_zsh_ai_cmd_sanitize` and asserts no leakage. Our `_aisuggest_sanitize` is a verbatim port; one bad regex change could re-introduce escape-injection. Add a tiny `tests/aisuggest_sanitize.sh` shellscript that sources `05_aisuggest.zsh` and asserts on a handful of payloads (CSI sequence, raw ESC, NULL byte, BEL, DEL). 30 lines, runs in <1 s.

### 6. Per-provider model env vars *(consistency with upstream)*

Today `AISUGGEST_MODEL` is a single env var that overrides whichever agent is picked (we override `AICAP_<AGENT>_MODEL` in the shim). Upstream uses provider-specific names: `ZSH_AI_CMD_ANTHROPIC_MODEL`, `ZSH_AI_CMD_OPENAI_MODEL`, etc. — lets a user pin different models per provider without re-exporting on agent change. If we ever support multiple agents in one session, switch to `AISUGGEST_<AGENT>_MODEL` (and keep `AISUGGEST_MODEL` as a fallback for back-compat).

### 7. CHANGELOG-driven re-sync cadence

Upstream's [`CHANGELOG.md`](https://github.com/kylesnowschwartz/zsh-ai-cmd/blob/main/CHANGELOG.md) is concise. A quarterly `git -C /tmp/zsh-ai-cmd-study log --oneline cda55e1..HEAD` + skim is enough to spot porting candidates. Set a `/schedule` reminder when you want this on a cadence; otherwise just run it next time you're in this file.

## Attribution

UX design and ZLE-widget mechanics learned from [`kylesnowschwartz/zsh-ai-cmd`](https://github.com/kylesnowschwartz/zsh-ai-cmd) (MIT, by Kyle Snow Schwartz). All code in `dot_config/zsh/tools/05_aisuggest.zsh` is our own implementation, written to integrate with this repo's existing `_aiagent_invoke` layer. We're grateful for the upstream design — go star their repo if you appreciate the original.
