# Plan: Prompt-time NL→shell suggestions, learned-and-rebuilt from `zsh-ai-cmd`

## Context

The repo has a strong **post-output** AI layer (`aifix` / `aiexplain` / `aiblock` in `dot_config/zsh/tools/04_ai_capture.zsh`) but no **prompt-time** "type English → press hotkey → ghost-text shell command → Tab to accept" experience. Upstream `kylesnowschwartz/zsh-ai-cmd` (MIT) is a polished implementation of that UX, but its provider router only knows about its own list (anthropic / openai / gemini / deepseek / ollama / copilot / claude_cli) and not this repo's `_aiagent_autodetect` flow at `04_ai_capture.zsh:36-45` (claude → opencode → codex → cursor-agent).

**Approach (decided with user, revised):** *study and rebuild.* Read upstream end-to-end, write a plain-English architecture doc that captures the ZLE widget mechanics (state machine, region_highlight ghost-text rendering, dismiss-on-buffer-change), **then** implement a minimal own version that:

- Reuses our existing `_aiagent_invoke` (`04_ai_capture.zsh:98`) — same agent autodetect, same model envs, same spinner-suppression pattern.
- Lives in one file under our own naming convention.
- Has no vendored code → no MIT attribution headaches, no upstream-drift maintenance.
- Maps to the same UX (Alt+; trigger, ghost-text, Tab/→ accept).

This is the "reimplement minimally" option from the earlier menu, but front-loaded with a documented learning pass so future maintainers can defend the design.

## Phases

### Phase A — Investigate upstream (read-only research)

Read the upstream repo end-to-end and capture findings into `docs/tools/zsh-inline-ai.md` (NEW, see Phase B). Files to read in order:

| Upstream file | What we want to extract |
|---|---|
| `zsh-ai-cmd.plugin.zsh` | The ZLE widget, the bindkey calls, the state variables (`_ZSH_AI_CMD_*` globals), accept/dismiss handlers, integration with `region_highlight`, how it interacts with `BUFFER` / `LBUFFER` / `POSTDISPLAY`. |
| `prompt.zsh` (if it exists separately) | The system-prompt framing — how upstream tells the model "single command, no prose, no fences". |
| `providers/anthropic.zsh` | The HTTPS API pattern (`curl` + `jq`) — for understanding only; we won't use this path. |
| `providers/claude_cli.zsh` | The CLI passthrough pattern — closest match to our `_aiagent_invoke` shim style. |
| `README.md` | All `ZSH_AI_CMD_*` env knobs and what they do. |

Tooling: clone shallowly to `/tmp/zsh-ai-cmd-study` for inspection (NOT into the repo); read with `cat` or `bat`. Do **not** copy any file into our tree. Note the upstream commit SHA we read so the doc is reproducible.

### Phase B — Write architecture doc (`docs/tools/zsh-inline-ai.md`)

A new docs page that captures both upstream's mechanics and our adapted design. Sections:

1. **Goal & UX** — one-paragraph description; screenshot/asciinema slot (TODO marker, not blocking).
2. **Why we don't vendor** — rationale: provider integration must hit `_aiagent_invoke`, file under our naming scheme, no upstream-drift cost.
3. **ZLE widget anatomy** (learned from upstream):
   - State variables: which globals track "is a suggestion active", original buffer position, the suggestion text, the highlight start/end indices.
   - Trigger flow: bindkey → widget enters → snapshot `BUFFER` → call provider → on response, append suggestion to `BUFFER` (or set `POSTDISPLAY`) and add a `region_highlight` entry styling the appended bytes as `fg=8`.
   - Accept flow: bound on Tab/→ (only while a suggestion is active) — clears the highlight, leaves the text in `BUFFER`, deactivates the state.
   - Dismiss flow: zsh hooks (`zle-line-pre-redraw` or per-keystroke detection) compare `BUFFER` against snapshot; mismatch = user typed = clear suggestion.
   - Re-trigger flow: pressing the trigger again replaces the previous suggestion.
4. **Why `region_highlight` not `POSTDISPLAY`** — POSTDISPLAY is owned by `zsh-autosuggestions`. Using `region_highlight` on bytes appended to `BUFFER` (then peeled off on accept/dismiss) keeps both UIs cohabiting. Document the visual interaction observed.
5. **Provider integration in our impl** — call signature into `_aiagent_invoke`, with the spinner / metadata / prettify all suppressed (`AICAP_SHOW_METADATA=0 AICAP_SPINNER=0 AICAP_PRETTIFY=0`). System-prompt template lives inline in our zsh file, with an `AISUGGEST_PROMPT_OVERRIDE` env knob for power users.
6. **Configuration table** — every env var our impl exposes (`AISUGGEST_KEY`, `AISUGGEST_AGENT`, `AISUGGEST_MODEL`, `AISUGGEST_HIGHLIGHT`, `AISUGGEST_PROMPT_OVERRIDE`).
7. **Interaction with other plugins**:
   - `zsh-autosuggestions` (POSTDISPLAY) — co-existence model.
   - `zsh-vi-mode` — bindkey wipe + `zvm_after_init` rebind.
   - `zsh-syntax-highlighting` — typically reapplies on `zle-line-pre-redraw`; verify our `region_highlight` entries survive its repaint.
8. **Troubleshooting** — widget not firing, ghost text not clearing, wrong agent picked.
9. **Re-study recipe** — how to re-read upstream for new ideas (clone command, files to read, what to look for).
10. **Attribution** — upstream link + thanks; explicitly state code is our own, design is upstream-inspired.

This doc is written *during* Phase A's investigation; it's the artifact that proves we understood upstream before reimplementing.

### Phase C — Implement our version

#### C.1 `dot_config/zsh/tools/05_aisuggest.zsh` (NEW)

Single file, all our own code, no upstream copying. Numbering `05_*` slots after `04_ai_capture.zsh` so `_aiagent_invoke` and `_aiagent_autodetect` are defined when this file sources. Naming `aisuggest` keeps it in the `ai*` family (`aifix`, `aiexplain`, `aiblock`, now `aisuggest`).

Structure:

1. **Header comment** — purpose, env knobs, override path, link to `docs/tools/zsh-inline-ai.md`. Pattern from `04_ai_capture.zsh:1-26`.
2. **Hard preconditions** — bail-early if no agent on PATH, no curl/jq, no zle:
   ```zsh
   [[ -o zle ]] || return 0
   _aiagent_autodetect &>/dev/null || return 0
   ```
3. **Env defaults**:
   ```zsh
   : "${AISUGGEST_KEY:=^[;}"        # Alt+;
   : "${AISUGGEST_HIGHLIGHT:=fg=8}"
   : "${AISUGGEST_AGENT:=}"          # empty = autodetect at invoke time
   : "${AISUGGEST_MODEL:=}"          # empty = use AICAP_*_MODEL default
   : "${AISUGGEST_PROMPT_OVERRIDE:=}"
   ```
4. **State globals** (typeset -g) — current suggestion, snapshot buffer, region_highlight index, "active" flag.
5. **Provider shim** `_aisuggest_query`:
   ```zsh
   _aisuggest_query() {
       local user_input="$1"
       local agent="${AISUGGEST_AGENT:-$(_aiagent_autodetect)}" || return 1
       local prompt
       if [[ -n "$AISUGGEST_PROMPT_OVERRIDE" ]]; then
           prompt="${AISUGGEST_PROMPT_OVERRIDE}\n\nRequest: ${user_input}"
       else
           prompt="Suggest a single POSIX shell command for this request. Reply with ONLY the command on one line — no markdown fences, no commentary, no leading prompt symbol. Request: ${user_input}"
       fi
       AICAP_SHOW_METADATA=0 AICAP_SPINNER=0 AICAP_PRETTIFY=0 \
           _aiagent_invoke "$agent" "$prompt" 2>/dev/null \
           | head -1 | sed -e 's/^[[:space:]]*[$#]\{0,1\}[[:space:]]*//' -e 's/^`\+//' -e 's/`\+$//'
   }
   ```
   The `head -1 | sed` post-filter strips markdown fences and leading `$`/`#` prompt markers in case the model adds them despite the system prompt — defensive belt-and-braces.
6. **The widget** `_aisuggest_widget` — see Phase B doc for the state-machine spec; key operations:
   - Snapshot `LBUFFER+RBUFFER`.
   - Run spinner-suppressed `_aisuggest_query` synchronously (acceptable for MVP; can move async later).
   - Append result to `RBUFFER` and add a `region_highlight` entry covering the appended span: `region_highlight+=("$start $end ${AISUGGEST_HIGHLIGHT}")`.
   - Set the "active" flag.
   - Call `zle redisplay`.
7. **The accept widget** `_aisuggest_accept` — bound to Tab and `^[[C` (right-arrow) but only via a `zle-line-pre-redraw` shim that swaps the binding while a suggestion is active (avoids breaking Tab completion globally). Clears the highlight and the active flag, keeps the text.
8. **The dismiss hook** — `zle-line-pre-redraw` callback: if the active flag is set and `BUFFER` differs from snapshot (modulo the appended suggestion), clear the suggestion and the highlight.
9. **Registration**:
   ```zsh
   zle -N aisuggest _aisuggest_widget
   zle -N aisuggest-accept _aisuggest_accept
   bindkey -M emacs "$AISUGGEST_KEY" aisuggest
   bindkey -M viins "$AISUGGEST_KEY" aisuggest
   bindkey -M vicmd "$AISUGGEST_KEY" aisuggest
   ```

Estimated size: ~120–180 lines of zsh, comparable to the existing `12_television.zsh` widget block.

#### C.2 `dot_zshrc.tmpl` (EDIT lines 30-32 — `zvm_after_init`)

`zsh-vi-mode` wipes all bindkeys on init; `zvm_after_init` is the only safe place to (re-)bind. Extend:

```zsh
zvm_after_init() {
    [ -f "$ZSH_CONFIG_DIR/tools/10_fzf.zsh" ] && source "$ZSH_CONFIG_DIR/tools/10_fzf.zsh"
    if zle -l | grep -q '^aisuggest$'; then
        bindkey -M viins "${AISUGGEST_KEY:-^[;}" aisuggest
        bindkey -M vicmd "${AISUGGEST_KEY:-^[;}" aisuggest
        bindkey -M emacs "${AISUGGEST_KEY:-^[;}" aisuggest
    fi
}
```

No changes to the `plugins=(…)` array at `dot_zshrc.tmpl:21-26` — this is not an OMZ plugin, it loads via `load_zsh_dir "$ZSH_CONFIG_DIR/tools"` at `dot_zshrc.tmpl:88`.

#### C.3 `mkdocs.yml` (EDIT — nav + llmstxt)

- Under `nav:` → `Tools:`, add `- Inline AI suggestions: tools/zsh-inline-ai.md` near `aicapture` and `agent-overlays`.
- Under `plugins.llmstxt.sections.Tools`, add `- tools/zsh-inline-ai.md`.
- `uv run mkdocs build --strict` must pass.

#### C.4 `CLAUDE.md` (EDIT — keyboard shortcuts table around lines 82-88)

Append:

```
| aisuggest (`05_aisuggest.zsh`) | `dot_config/zsh/tools/05_aisuggest.zsh`, `dot_zshrc.tmpl` zvm_after_init | `Alt+;` (configurable via `AISUGGEST_KEY`); rebound inside `zvm_after_init` to survive zsh-vi-mode's keybind wipe |
```

Also update the "Known conflict zones" prose at `CLAUDE.md:90` to note Alt+; is now claimed; Alt+/ remains free.

#### C.5 `README.md` (EDIT — Config Files)

Add a one-liner near the existing `04_ai_capture.zsh` mention (around `README.md:173`):

```
~/.config/zsh/tools/05_aisuggest.zsh — prompt-time NL→shell ghost-text suggestions (Alt+; default; uses claude/opencode/codex/cursor-agent autodetect — no API key needed). Inspired by kylesnowschwartz/zsh-ai-cmd; full design in docs/tools/zsh-inline-ai.md.
```

No edits to "Upstream Clones" — nothing cloned.

## Trigger key: Alt+; (with Alt+/ documented as alternative)

Existing Alt-letter bindings: T (tools-picker), R (tv-history), P (tv-files), G (tv-gitlog), E (tv-env), A (tv-aliases), I (tv-gitops), S (sesh-sessions). Non-letter `;` and `\` are free. Picked Alt+; per user choice; documented Alt+/ as alternative (with caveat about Ctrl+/ confusion on some terminal stacks).

## Risks + mitigations

1. **State machine bugs** — region_highlight indices off-by-one, suggestion not clearing on edit, Tab not accepting, Tab still firing completion when no suggestion is active. Mitigation: write the architecture doc (Phase B) BEFORE writing code; manual testing matrix in §Verification.
2. **`zsh-syntax-highlighting` repaints over our region_highlight.** ZSH-syntax-highlighting reruns on every redraw. If our `region_highlight` entry gets clobbered, we'll need to re-add it inside our `zle-line-pre-redraw` callback. Investigate during Phase A; document in Phase B; handle in Phase C.
3. **`zsh-autosuggestions` POSTDISPLAY collision.** Different mechanism (postdisplay) but same visual region. Likely co-existing; if not, document `ZSH_AUTOSUGGEST_MANUAL_REBIND=1` workaround.
4. **Tab override scope.** Tab is sacred for completion. Our impl must scope the override strictly to "while a suggestion is active". The `zle-line-pre-redraw` swap-bind pattern handles this; verify in test matrix.
5. **`_aiagent_invoke` synchronous latency.** ~1-3s on `haiku`. Widget appears to "freeze" during the call. MVP-acceptable; future enhancement = move to async via zsh's `zle -F` file descriptor handler.
6. **Model returns prose / fences despite system prompt.** Defensive `head -1 | sed` strips fences and leading `$`/`#`. If still noisy, add a sanity check: bail if the suggestion contains a newline or is implausibly long (> 500 chars).
7. **Hard repo invariants honored:** install vs upgrade split (no auto-update, no external clones), keybinding-conflict table updated, README + docs in same commit, no `state: latest` ansible changes, `mkdocs build --strict` passes.

## Verification

1. **Phase A done** — `docs/tools/zsh-inline-ai.md` Phase B sections exist and capture state-machine details with reference to specific upstream lines (commit SHA recorded).
2. `chezmoi apply` — new file at `~/.config/zsh/tools/05_aisuggest.zsh` materializes; `~/.zshrc` `zvm_after_init` reflects rebind.
3. `exec zsh`. `zle -l | grep '^aisuggest'` → shows two widgets. `bindkey | grep '\^\[;'` → shows binding under viins/vicmd/emacs.
4. **Functional matrix**:
   - Type `find files larger than 100 MB`, press `Alt+;`, expect ghost text rendering `find . -size +100M …` at end of buffer in `fg=8`. Press `Tab` → highlight clears, command stays. Press Enter → executes.
   - Same input, press `Alt+;`, then type any letter → suggestion + highlight clear.
   - Empty buffer, press `Alt+;` → no-op (don't query for empty input).
   - Re-trigger: type request, `Alt+;`, get suggestion, edit input, `Alt+;` again → new suggestion replaces old.
5. **Vi-mode**: `Esc` → vicmd, `i` → insert, retrigger. Must work (proves rebind path).
6. **Job control sanity**: `sleep 100` then `Ctrl+Z` → still suspends.
7. **Provider override**: `export AISUGGEST_AGENT=opencode; exec zsh` → confirm routing to opencode (verify via temporary `set -x` inside `_aisuggest_query`).
8. **Tab completion not broken**: with no active suggestion, Tab still completes filenames as before.
9. `uv run mkdocs build --strict` — passes.
10. `chezmoi apply` second run — idempotent.

## Critical files (absolute paths)

**Phase A (read-only research; not in repo):**
- `/tmp/zsh-ai-cmd-study/zsh-ai-cmd.plugin.zsh` — clone target for study
- `/tmp/zsh-ai-cmd-study/providers/claude_cli.zsh` — closest provider analog
- `/tmp/zsh-ai-cmd-study/README.md` — env-knob reference

**Phase B (NEW docs):**
- `/Users/daviddwlee84/.local/share/chezmoi/docs/tools/zsh-inline-ai.md` — architecture + design + config

**Phase C (NEW + EDIT):**
- `/Users/daviddwlee84/.local/share/chezmoi/dot_config/zsh/tools/05_aisuggest.zsh` (NEW) — own implementation
- `/Users/daviddwlee84/.local/share/chezmoi/dot_zshrc.tmpl` (EDIT lines 30-32) — `zvm_after_init` rebind
- `/Users/daviddwlee84/.local/share/chezmoi/mkdocs.yml` (EDIT) — nav + llmstxt
- `/Users/daviddwlee84/.local/share/chezmoi/CLAUDE.md` (EDIT lines 82-88) — keybinding table row
- `/Users/daviddwlee84/.local/share/chezmoi/README.md` (EDIT around line 173) — Config Files entry

**Reused (no edits):**
- `/Users/daviddwlee84/.local/share/chezmoi/dot_config/zsh/tools/04_ai_capture.zsh` — `_aiagent_invoke` (line 98) and `_aiagent_autodetect` (line 36) are the public surface our shim calls into.

---

## Phase D — Bug fix + wrap-up (2026-04-27)

### What happened post-MVP

After Phase C shipped, the user reported the widget "shows the loading animate but nothing is generated" — spinner runs, then no ghost text appears. Two diagnostic surfaces were added during debugging:

1. **CLI surface** `aisuggest [--debug] "<text>"` — same pipeline as the widget but synchronous, prints to stdout. `--debug` shows raw agent reply / sanitized / post-filtered for layer-by-layer comparison.
2. **Widget logging** — every step of `_aisuggest_widget`, `_aisuggest_show_ghost`, `_aisuggest_activate`, `_aisuggest_deactivate`, `_aisuggest_pre_redraw` writes a line to `$AISUGGEST_LOG` (default `/tmp/aisuggest.log`) when `AISUGGEST_DEBUG=1`. Toggle at runtime — no restart needed.

### Diagnosis (confirmed in user's log on 2026-04-27 09:18)

```
widget: rendered ghost, activated
pre_redraw: BUFFER=[show current disk space] snap=[show current disk space] POSTDISPLAY=[]
pre_redraw: POSTDISPLAY was cleared externally — re-asserting
show_ghost: POSTDISPLAY=[  ⇥  command df -h] start=23 end=41 rh_count=5
deactivate: called from _aisuggest_accept_tab
```

Translation: between widget exit and the actual screen draw, `zsh-autosuggestions`' own line-pre-redraw / widget-wrapper logic was clearing `POSTDISPLAY` (probably its history-fetch returning empty for novel input). Our hook fired *after* it and re-asserted, but the fix had to land before the user could see anything.

### Fix (already in chezmoi source, NOT yet deployed)

Two layers in `dot_config/zsh/tools/05_aisuggest.zsh`:

1. **Primary**: in `_aisuggest_activate`, call `_zsh_autosuggest_disable` (function-existence-checked) to pause zsh-autosuggestions while a suggestion is live; restored by `_zsh_autosuggest_enable` in `_aisuggest_deactivate`. Tracked via new `_AISUGGEST_AUTOSUGGEST_PAUSED` global so we only re-enable if we paused (don't disturb other code that might have toggled it).
2. **Fallback (already in place)**: `_aisuggest_pre_redraw` re-asserts POSTDISPLAY when active and POSTDISPLAY went empty. Catches the (hopefully rare) case where someone runs without zsh-autosuggestions but with another POSTDISPLAY consumer.

The fix has been written to the chezmoi source but **`chezmoi apply` has NOT been run yet**, so `~/.config/zsh/tools/05_aisuggest.zsh` is still the previous version (with re-assert only). The user's screenshot showed the re-assert version working visually.

### Remaining steps

1. **Apply** — `chezmoi apply` to deploy the autosuggest-pause fix.
2. **Re-test** — `exec zsh; export AISUGGEST_DEBUG=1; : > /tmp/aisuggest.log; <trigger>; cat /tmp/aisuggest.log`. Expect:
   - `activate: ... autosuggest_paused=1`
   - No `pre_redraw: POSTDISPLAY was cleared externally — re-asserting` line on the happy path (autosuggestions paused, never clears).
   - `deactivate: called from _aisuggest_accept_tab` after Tab.
   - Visually: ghost text appears immediately, no flicker.
3. **Negative test** — type something with a history match (e.g. `ls`), press Alt+;, confirm autosuggestions resumes after Tab/dismiss (its hint should reappear on next prompt).
4. **Doc update** — extend `docs/tools/zsh-inline-ai.md` "Interaction with other plugins" section to document:
   - The collision was real (POSTDISPLAY contention).
   - We pause zsh-autosuggestions via `_zsh_autosuggest_disable` while active, re-enable on deactivate.
   - The pre-redraw re-assert is a fallback.
   - `AISUGGEST_DEBUG=1` + `/tmp/aisuggest.log` is the canonical diagnostic.
5. **Doc update** — add a "Debugging" subsection covering:
   - The CLI: `aisuggest "<text>"` and `aisuggest --debug "<text>"`.
   - The log: `export AISUGGEST_DEBUG=1; : > /tmp/aisuggest.log; <reproduce>; cat /tmp/aisuggest.log`.
   - Common failure-mode → log-line mapping (the four-row table from the earlier debugging round).
6. **Script comment update** — extend the header in `dot_config/zsh/tools/05_aisuggest.zsh` to mention the CLI form (`aisuggest [--debug] "<text>"`) and `AISUGGEST_DEBUG=1` for runtime widget tracing.
7. **Commit** — single commit covering Phases C + D (the original implementation + diagnostic surface + fix). Use the `agent-history-hygiene` skill to also stage `.specstory/history/*.md` and `.claude/plans/*.md` (this file) alongside the feature diff.

### Files touched in Phase D (already-edited in source; verify before commit)

- `dot_config/zsh/tools/05_aisuggest.zsh`
  - Header roadmap block (Phase D start)
  - `_aisuggest_log` calls in widget body
  - `aisuggest` CLI function with `--debug`
  - `_aisuggest_show_ghost` log lines
  - `_aisuggest_activate` log line + zsh-autosuggestions pause (NEW; deployed pending apply)
  - `_aisuggest_deactivate` log line + zsh-autosuggestions resume (NEW; deployed pending apply)
  - `_aisuggest_pre_redraw` log lines + re-assert fallback
- `docs/tools/zsh-inline-ai.md`
  - Roadmap section appended (already done)
  - **Pending**: Interaction-with-plugins update + Debugging subsection
- No changes to `dot_zshrc.tmpl`, `mkdocs.yml`, `CLAUDE.md`, `README.md` in Phase D.

### Verification of the wrap-up

- `chezmoi apply` clean and idempotent (second run = no-op).
- `zsh -n ~/.config/zsh/tools/05_aisuggest.zsh` syntax-OK.
- `uv run mkdocs build --strict` passes.
- Manual functional test:
  - Type description, Alt+;, see ghost text immediately (no re-assert path needed).
  - Tab to accept; buffer fills.
  - Type novel input again, Alt+;, ghost text; type any letter to dismiss; verify zsh-autosuggestions ghost text resumes for subsequent input.
  - `sleep 100` then Ctrl+Z still suspends (SIGTSTP intact).
- `git log --oneline -1` shows a single descriptive commit.
