# Plan — Add `http` agent + `AICAP_AGENT` override to ai-capture

## Context

`dot_config/zsh/tools/04_ai_capture.zsh` powers `aifix` / `aiexplain` / `aiblock` (one-shot agent review of terminal output). It currently auto-detects one of four installed CLIs in fixed order (`claude → opencode → codex → cursor-agent`) and routes the prompt through the matched CLI. This locks the user out of two cheap/free routes:

- **OpenRouter free models** (`openrouter/google/gemini-2.0-flash-exp:free` etc.) — useful when the local host has no agent CLI installed but does have `curl` + an API key.
- **Local Ollama** (`http://localhost:11434/v1/chat/completions`) — useful for privacy-sensitive output and offline / air-gapped hosts.

We also have no clean way to force a specific agent without typing `-a <agent>` on every call, even when several CLIs are installed.

The change: add a new `http` agent type that talks an OpenAI-compatible chat-completions endpoint directly (covers both OpenRouter and Ollama since they share the schema), and add an `AICAP_AGENT` env var that overrides the auto-detect chain. Auto-detect order stays unchanged. The `http` agent is opt-in via `AICAP_AGENT=http` (it has nothing to probe on PATH).

## Design

### New env vars

| Var | Default | Purpose |
|---|---|---|
| `AICAP_AGENT` | `<unset>` | If set, skip auto-detect and use this agent. One of: `claude` `opencode` `codex` `cursor-agent` `http`. Per-call `-a` flag still wins. |
| `AICAP_HTTP_URL` | `https://openrouter.ai/api/v1/chat/completions` | Full chat-completions URL. Set to `http://localhost:11434/v1/chat/completions` for Ollama. |
| `AICAP_HTTP_MODEL` | `google/gemini-2.0-flash-exp:free` | Model name as expected by the endpoint. |
| `AICAP_HTTP_API_KEY` | `${OPENROUTER_API_KEY:-}` | Bearer token. Empty = no `Authorization` header (Ollama works this way). |

`OPENROUTER_API_KEY` fallback is intentional — OpenRouter docs already use that name and many users will have it set in their secrets.

### Code changes

#### 1. `dot_config/zsh/tools/04_ai_capture.zsh`

- Add the four `:` defaults (lines ~28-34 block) for the new vars except `AICAP_AGENT` (which must stay unset to mean "auto").
- New `http` branch in `_aiagent_invoke()` (after `cursor-agent)` at line 161). Build JSON payload with `jq -n --arg m … --arg p …`, `curl -sS -X POST` with optional `Authorization` header, `jq` out `.choices[0].message.content`. Surface `.error.message` to stderr if present. Emit a metadata line (`http (<model>) | in=<n> out=<n>`) when `AICAP_SHOW_METADATA=1`. Spinner label `http <model>…`.
- In the dispatchers (`_ai_capture_dispatch`, `aifix-stdin`, `aifix-run`), before the auto-detect call: `[[ -z "$agent" && -n "$AICAP_AGENT" ]] && agent=$AICAP_AGENT`. Per-call `-a` flag already short-circuits before this, so its precedence is preserved.
- `_aiagent_autodetect` stays unchanged — `http` is opt-in and never auto-selected.
- `_ai_print_help` env-var snapshot grows four new lines (`AICAP_AGENT`, `AICAP_HTTP_URL`, `AICAP_HTTP_MODEL`, `AICAP_HTTP_API_KEY` — mask the key as `<set>`/`<unset>` so it's not echoed verbatim).
- Update the unknown-agent error string in `_aiagent_invoke` (line 162) to include `http`.
- Top-of-file comment block (lines 1-27) gets a short note on `http` and the OpenRouter / Ollama use cases.

`05_aisuggest.zsh` (line 6-9, 58-59) reuses `_aiagent_invoke` and `_aiagent_autodetect` unchanged — picks up the new agent automatically. Verify by reading the file (no edit expected).

#### 2. `scripts/aiblock.py`

- `AGENT_CONFIG` dict (lines ~63-68) gets a fifth entry `"http"` with model from `AICAP_HTTP_MODEL`. Mark it as "always available" in `detect_agents()` (lines ~79-81) when `AICAP_AGENT == "http"` or when the user explicitly picks it from the TUI — don't auto-include otherwise (no PATH probe matches).
- Spawn-agent path that builds the CLI invocation needs an `http` branch that mirrors the zsh one (use `urllib.request` from stdlib, no extra deps). Reuse zsh's metadata format on stderr for parity.
- Read `AICAP_AGENT` env var as the initial selection if set.

#### 3. Docs

- `docs/tools/aicapture.md` — add a "Provider routing" section with two concrete recipes:
  - OpenRouter free: `export AICAP_AGENT=http; export AICAP_HTTP_MODEL=google/gemini-2.0-flash-exp:free; export OPENROUTER_API_KEY=…`
  - Ollama local: `export AICAP_AGENT=http; export AICAP_HTTP_URL=http://localhost:11434/v1/chat/completions; export AICAP_HTTP_MODEL=qwen2.5-coder:7b`
- The page is already in MkDocs nav; no `mkdocs.yml` change needed (verify via `uv run mkdocs build --strict`).
- `docs/shells/aliases.md` — no rows change (no new aliases/functions, just env vars).

## Critical files

- `dot_config/zsh/tools/04_ai_capture.zsh` — primary change site
- `dot_config/zsh/tools/05_aisuggest.zsh` — verify unaffected
- `scripts/aiblock.py` — parity update
- `docs/tools/aicapture.md` — env var table + recipes

## Existing utilities to reuse

- `_aicap_spinner_start` / `_aicap_spinner_stop` (lines 51-76) — wrap the curl call exactly like other branches do.
- `_aicap_prettify` (lines 80-90) — already wraps the agent reply in `_ai_dispatch_core`. No change needed; `http` reply is plain markdown text just like the other agents.
- `jq` is already a hard dep on the claude JSON path (line 107) and is in the `cli_basics` ansible role; no new install task needed.
- `curl` is universally present.

## Verification

1. **Syntax**: `zsh -n dot_config/zsh/tools/04_ai_capture.zsh` (no execution).
2. **Path-A — OpenRouter** (needs `OPENROUTER_API_KEY` in env):
   ```
   AICAP_AGENT=http aiexplain 1
   ```
   Expect: spinner, then `http (google/gemini-2.0-flash-exp:free) | in=N out=N` on stderr, prettified reply on stdout.
3. **Path-B — Ollama** (needs `ollama serve` running with `qwen2.5-coder:7b` pulled):
   ```
   AICAP_AGENT=http \
   AICAP_HTTP_URL=http://localhost:11434/v1/chat/completions \
   AICAP_HTTP_MODEL=qwen2.5-coder:7b \
     aiexplain 1
   ```
4. **Error path**: bad URL → curl rc≠0, stderr message, no hung spinner. Bad API key → `.error.message` surfaced verbatim.
5. **No-regression**: with `AICAP_AGENT` unset and `claude` on PATH, `aifix` still routes to claude (auto-detect path unchanged).
6. **Help text**: `aifix -h` lists the four new env vars.
7. **aiblock TUI**: launch `aiblock`, confirm `http` appears as a selectable agent when `AICAP_AGENT=http` and that the "Spawn agent" / one-shot paths both succeed against Ollama.
8. **MkDocs**: `uv run mkdocs build --strict` passes.
