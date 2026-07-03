# Plan: terminal translation helpers (`fy` / `fyn` / `fyw`)

## Context

The user reviewed a Deep Research report on terminal translation tools and asked whether
anything is worth building for this dotfiles repo. The report's three categories map very
unevenly onto what already exists here:

- **LLM prose/doc translation** — already ~90% built. The repo has a mature LLM dispatch
  layer (`_aiagent_invoke`, `_ai_dispatch_core`, `air`, the `AICAP_*` SSOT with fast
  lightweight model pins, plus a `http` agent for OpenRouter/local-Ollama). `aifix-stdin -p
  "translate…"` already does translation today.
- **Instant word lookup** — a genuine gap, but the user explicitly chose to *reuse existing
  plumbing* and *shell functions* over installing a dedicated tool (`translate-shell`).
- **Offline/privacy** — reachable for free via the existing `http` agent pointed at a local
  Ollama; no new engine (Argos/CTranslate2 is heavy) needed.

The user's concrete need (their words): quick zh↔en lookup **and** knowing the *correct /
natural* way a native speaker would phrase something. That is an LLM's sweet spot, not a
dictionary's — which is exactly why reusing the LLM layer (not adding `trans`/`llm`/`aichat`)
is the right call.

**Outcome:** one new shared shell file exposing three thin functions over the existing AI
dispatch, plus the one mandatory doc mirror. Zero new dependencies, no SSOT changes, no new
installed tools.

## Scope decision (what we are *not* doing, and why)

- **Not** installing `translate-shell` / `llm` / `aichat` / `argos-translate`. User chose
  "reuse existing plumbing." Installing another LLM CLI would duplicate `air`/`_aiagent_invoke`.
- **Not** adding a ZLE keybinding or a full `executable_` CLI + tv channel. User chose
  "shell functions/aliases" only.
- **Not** touching the `AICAP_*` SSOT (`04_ai_agents.sh`). The existing lightweight model
  pins (claude→haiku, opencode→copilot-haiku) are already fast/cheap and ideal for
  translation. Avoids the documented "4 Python consumers" maintenance pain.

## Implementation

### New file: `dot_config/shell/05_translate.sh` (shared tier)

Sibling of `05_ai_run.sh`; loads after `04_ai_capture.sh` so it can call
`_ai_dispatch_core` / `_aiagent_autodetect` at runtime (all shell files are sourced before
the first prompt, so definition-time order is irrelevant). Mirror the exact style of
`aifix-stdin` (`dot_config/shell/04_ai_capture.sh:435`) and `air`
(`dot_config/shell/05_ai_run.sh:117`): `local -a` / `[[ ]]` / `(( ))` — bash+zsh compatible,
no ZLE/`setopt`/`bindkey` (so it stays in the shared tier and sources cleanly in both shells).

Each function:
1. `[ -n "$ZSH_VERSION" ] && emulate -L zsh` (match siblings).
2. Parse flags: `-a AGENT`, `-t LANG` (target override), `-p PROMPT` (advanced override),
   `--raw` / `--no-meta`, `-h`. Reuse `_ai_print_help` where convenient.
3. Collect remaining args as the text. **If no text args and stdin is not a tty** (`[ ! -t 0 ]`),
   read `block=$(cat)` — supports both `fy "text"` and `echo text | fy`. If neither, print
   usage to stderr and `return 2` (house style).
4. Resolve agent: `-a` → `$AICAP_AGENT` → `_aiagent_autodetect` (same cascade as
   `aifix-stdin:451`; keeps the "no agent → hint about `-a http`" behavior).
5. Delegate to
   `_ai_dispatch_core <name> <source-label> "$default_prompt" "$agent" <raw> <no_meta> "$prompt_override" "$block"`.
   `_ai_dispatch_core` composes `"$default_prompt\n\n$block"`, invokes, and (when raw=0)
   pipes through `_aicap_prettify` (glow→bat→raw).

**Function specs**

| Fn | raw | Target | Default prompt (essence) |
|----|-----|--------|--------------------------|
| `fy` | 1 (plain, no glow border) | bidirectional auto, or `-t LANG` | "Translate the text below between Traditional Chinese (zh-Hant, Taiwan usage) and English: if Chinese → natural idiomatic English, else → Traditional Chinese. Output ONLY the translation — no quotes, no notes, no romanization." With `-t LANG`: "Translate the text below into `LANG`. Output ONLY the translation." |
| `fyn` | 0 (prettify) | auto opposite, or `-t LANG` | "I want to express the idea below. Show how a native speaker would say it naturally and correctly. Give 2–4 phrasings across registers (formal/neutral/casual) as a short markdown list, each with a ≤10-word nuance note. If my phrasing is unnatural or a common mistake, say so in one line. Chinese input → target English; English → Traditional Chinese. Be concise." |
| `fyw` | 0 (prettify) | bilingual | "For the word/short phrase below, give a compact markdown reference: meaning(s) in Traditional Chinese + English; part of speech; 2–3 common collocations; 2 example sentences with translation; near-synonyms and how they differ. Keep it tight." |

- **`fy`** = the workhorse quick translate (中翻英 / 英翻中, auto-direction handled by the
  model, not shell — robust, no CJK byte-detection needed).
- **`fyn`** = the "正確用法 / how a native says it" feature the user emphasized.
- **`fyw`** = LLM word lookup with usage/collocations/synonyms (covers the "速查單字" case
  the dictionary tool would have served, but with usage notes a dictionary lacks).

**Offline/privacy** falls out with no extra code: `fy -a http "…"` (or `AICAP_AGENT=http`)
hits the OpenAI-compatible `http` agent; point `AICAP_HTTP_URL` at
`http://localhost:11434/v1/chat/completions` for a fully-local Ollama route.

### Mandatory doc mirror: `docs/shells/aliases.md`

Per the `CLAUDE.md` cross-file rule (shell function in `dot_config/{shell,zsh,bash}/` →
row in `docs/shells/aliases.md`):

- Add a `## AI Translate` section immediately after the `## AI Run` block (after line 777),
  with a one-line intro (reuses AICAP dispatch; `-a http` for offline) and a 3-row table for
  `fy` / `fyn` / `fyw` in the existing `| Command | Type | Source File | Description |` format,
  Source File = `dot_config/shell/05_translate.sh`.
- Add `- [AI Translate](#ai-translate)` to the Table of Contents (after the `AI Run` entry,
  line 35).

No other mirrors apply: not an `executable_` CLI (so no two-file completions), not a new
prompt key or stable CLI (so no `SKILL.md.tmpl` edit), no new installed tool (so no
`tool-managers.md` A–Z row), no SSOT/model-pin change.

## Verification

1. **Lint:** `shellcheck dot_config/shell/05_translate.sh` using the same dialect the sibling
   `04_ai_capture.sh` / `05_ai_run.sh` pass under (they use `local -a` / `[[ ]]` / `(( ))`).
2. **Both-shell source smoke** (the shared-tier invariant):
   `zsh -ic 'source ~/.config/shell/05_translate.sh; typeset -f fy fyn fyw >/dev/null && echo zsh-ok'`
   and the bash equivalent — after `chezmoi apply` deploys the file and its AI-layer deps.
3. **Functional** (after `chezmoi apply` + `exec zsh`):
   - `fy "The build failed because the env file was missing."` → Traditional Chinese.
   - `fy 今天天氣很好，適合出去走走` → English.
   - `echo "會議改到下午三點" | fy` → stdin path works.
   - `fy -t ja "good morning"` → Japanese (explicit target).
   - `fyn "I want to ask my boss for a day off tomorrow"` → registered native alternatives list.
   - `fyw serendipity` → reference card (meaning / POS / collocations / examples / synonyms).
   - `fy` with no args and a tty stdin → usage + `return 2`.
   - Offline: with a local Ollama running,
     `AICAP_HTTP_URL=http://localhost:11434/v1/chat/completions AICAP_HTTP_MODEL=<model> fy -a http "hello"`.
4. **Docs:** `uv run mkdocs build --strict` (aliases.md is in nav) to confirm the new section
   + ToC anchor resolve.

## Files touched

- **New:** `dot_config/shell/05_translate.sh`
- **Edit:** `docs/shells/aliases.md` (new `## AI Translate` section + ToC entry)

## Possible follow-ups (not in this plan)

- If LLM latency ever feels too slow for pure word lookup, revisit adding `translate-shell`
  (`trans -d`) as a brew+apt tool for the instant-dictionary niche — complementary, not a
  replacement.
- A `tv` picker or ZLE "translate current buffer" widget, if the function UX proves it earns one.
