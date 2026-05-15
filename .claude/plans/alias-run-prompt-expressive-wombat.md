# Plan: Quick "run a prompt through coding agent X" shell wrappers

## Context

The repo already has rich AI capture tooling (`aifix`, `aiexplain`, `aiblock`,
`aifix-run`, `aifix-rerun`) in `dot_config/shell/04_ai_capture.sh`, but those
are all **single-turn diagnose-the-output** wrappers — they require a captured
terminal block, stdin, a tee'd command, or shell-history rerun. None of them
let you just type a fresh prompt and stream the agent's reply back.

The user wants short mnemonics that mirror the agent-session tags in
`dot_config/television/cable/agent-sessions.toml:17-19` (`[oc]`/`[cc]`/`[cx]`/`[cu]`):

- `ocr "prompt"` → `opencode run …`
- `ccr "prompt"` → `claude -p …`
- `cxr "prompt"` → `codex exec …`
- `cur "prompt"` → `cursor-agent -p …`
- `olr "prompt"` → `ollama run …` (sugar over local Ollama)
- `air "prompt"` → autodetect via `AICAP_AGENT_PRIORITY`, supports `-a` / `-m`

These pair the "browse sessions" UX (`tv agent-sessions`) with a matching
"start a new one-shot" UX. No naming collisions in `docs/shells/aliases.md`
(`ocr`/`ccr`/`cxr`/`cur`/`olr`/`air` are all free; `cur` ≠ `curl` by length;
`ocr` doesn't shadow any installed binary on either reference machine).

The existing `_aiagent_invoke` helper in `04_ai_capture.sh:150-284`
**should not be reused** for this — when `AICAP_SHOW_METADATA=1` the Claude
branch (lines 167-180) forces full-buffer capture of the reply via
`json=$(claude -p … --output-format json …)` so it can parse usage/cost
out of the JSON. That kills streaming for long agent responses. The clean
precedent is `glcreate-ai` in `dot_config/shell/42_gitlab.sh:105-111`,
which inlines the per-agent CLI dispatch directly and streams stdout.

---

## Implementation

### 1. New file: `dot_config/shell/05_ai_run.sh` (~140 lines)

POSIX-compatible shared file (both shells source it via the standard
`$XDG_CONFIG_HOME/shell/*.sh` loader). Number `05` deliberately places it
**after** `04_ai_agents.sh` (SSOT) and `04_ai_capture.sh` so it can:
- Inherit `AICAP_*_MODEL` env vars
- Reuse `_aiagent_autodetect` from `04_ai_capture.sh:77-94` for `air`

**Header comment** must explain the deliberate diverge from `aifix`:
- These wrappers stream stdout straight through (no spinner, no metadata).
- They are pass-through: extra flags forward to the underlying CLI, so
  `ccr -c "prompt"` → `claude -p --model haiku -c "prompt"` (continue last
  session). Same for `--resume`, custom `--model` overrides, etc.
- Ollama is intentionally NOT added to `_aiagent_invoke` or the autodetect
  priority — `olr` is a shell-only sugar wrapper; the four Python
  consumers of the SSOT (per the CLAUDE.md cross-file rule) do not need
  to know about it. The existing `http` agent path remains the
  cross-platform OpenAI-compat fallback (covers OpenRouter + remote
  endpoints + Ollama-via-localhost when the user prefers that).

**Per-agent wrappers (5 functions):** each ~10 lines, identical shape —
empty-arg → usage; build conditional model-args array; exec CLI with
`"$@"` pass-through. Model-args array is empty when the SSOT pin is
empty, so the CLI's own default applies (matches the
`AICAP_<AGENT>_MODEL`-conditional pattern at `04_ai_capture.sh:161-163`,
`192-193`, `206-207`, `216-220`).

```sh
ocr() {                                      # opencode → [oc]
  [ $# -eq 0 ] && { printf '%s\n' "usage: ocr [opencode flags] <prompt>" >&2; return 1; }
  local -a model_args=()
  [ -n "$AICAP_OPENCODE_MODEL" ] && model_args=(-m "$AICAP_OPENCODE_MODEL")
  opencode run "${model_args[@]}" "$@"
}

ccr() {                                      # claude → [cc]
  [ $# -eq 0 ] && { printf '%s\n' "usage: ccr [claude flags] <prompt>" >&2; return 1; }
  local -a model_args=()
  [ -n "$AICAP_CLAUDE_MODEL" ] && model_args=(--model "$AICAP_CLAUDE_MODEL")
  claude -p "${model_args[@]}" "$@"
}

cxr() {                                      # codex → [cx]
  [ $# -eq 0 ] && { printf '%s\n' "usage: cxr [codex flags] <prompt>" >&2; return 1; }
  local -a model_args=()
  [ -n "$AICAP_CODEX_MODEL" ] && model_args=(-m "$AICAP_CODEX_MODEL")
  codex exec "${model_args[@]}" "$@"
}

cur() {                                      # cursor-agent → [cu]
  [ $# -eq 0 ] && { printf '%s\n' "usage: cur [cursor-agent flags] <prompt>" >&2; return 1; }
  local -a model_args=()
  [ -n "$AICAP_CURSOR_MODEL" ] && model_args=(--model "$AICAP_CURSOR_MODEL")
  cursor-agent -p "${model_args[@]}" "$@"
}

olr() {                                      # ollama (shell-only sugar)
  [ $# -eq 0 ] && { printf '%s\n' "usage: olr <prompt>   (model = \$AICAP_OLLAMA_MODEL)" >&2; return 1; }
  local model="${AICAP_OLLAMA_MODEL:-qwen2.5-coder:7b}"
  ollama run "$model" "$@"
}
```

Note `olr` is **prompt-only** (no pass-through) because `ollama run` puts
the model positionally before the prompt — mixing flags in `"$@"` would
land them after the model and break parsing. Documented in the header.
For advanced ollama use, drop to `ollama run` directly or set
`AICAP_AGENT=http air "…"` for the OpenAI-compat path.

**Autodetect wrapper `air`** (~40 lines): parses `-a AGENT`, `-m MODEL`,
`-h|--help`, `--` separator, then dispatches to one of the five wrappers
above. Subshell isolation for the `-m` override so per-call model
selection doesn't leak into the parent shell:

```sh
air() {
  [ -n "$ZSH_VERSION" ] && emulate -L zsh
  local agent="" model_override=""
  local -a prompt_args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -a|--agent) agent="$2"; shift 2 ;;
      -m|--model) model_override="$2"; shift 2 ;;
      -h|--help)
        printf '%s\n' \
          "usage: air [-a AGENT] [-m MODEL] [--] <prompt> [flags…]" \
          "  -a AGENT   opencode | claude | codex | cursor-agent | ollama | http" \
          "             (default: \$AICAP_AGENT or auto-detect via \$AICAP_AGENT_PRIORITY)" \
          "  -m MODEL   override the agent's AICAP_<AGENT>_MODEL pin for this call" \
          "  --         end of air flags; everything after is forwarded to the agent CLI"
        return 0 ;;
      --) shift; prompt_args+=("$@"); break ;;
      *)  prompt_args+=("$1"); shift ;;
    esac
  done
  [ "${#prompt_args[@]}" -eq 0 ] && { printf '%s\n' "air: missing prompt (try: air -h)" >&2; return 1; }

  if [ -z "$agent" ]; then
    agent="${AICAP_AGENT:-$(_aiagent_autodetect)}" || {
      printf '%s\n' "air: no agent CLI on PATH (priority: \$AICAP_AGENT_PRIORITY)" >&2
      printf '%s\n' "air: hint — AICAP_AGENT=http air … for OpenRouter/Ollama HTTP" >&2
      return 1
    }
  fi

  case "$agent" in
    opencode|oc)     ( [ -n "$model_override" ] && AICAP_OPENCODE_MODEL="$model_override"; ocr "${prompt_args[@]}" ) ;;
    claude|cc)       ( [ -n "$model_override" ] && AICAP_CLAUDE_MODEL="$model_override";   ccr "${prompt_args[@]}" ) ;;
    codex|cx)        ( [ -n "$model_override" ] && AICAP_CODEX_MODEL="$model_override";    cxr "${prompt_args[@]}" ) ;;
    cursor-agent|cu) ( [ -n "$model_override" ] && AICAP_CURSOR_MODEL="$model_override";   cur "${prompt_args[@]}" ) ;;
    ollama|ol)       ( [ -n "$model_override" ] && AICAP_OLLAMA_MODEL="$model_override";   olr "${prompt_args[@]}" ) ;;
    http)            ( [ -n "$model_override" ] && AICAP_HTTP_MODEL="$model_override"
                       # `_aiagent_invoke` is fine here because http isn't streaming-sensitive
                       # (curl returns the full JSON response in one go anyway).
                       _aiagent_invoke http "${prompt_args[*]}" ) ;;
    *) printf '%s\n' "air: unknown agent '$agent' (supported: opencode, claude, codex, cursor-agent, ollama, http)" >&2; return 1 ;;
  esac
}
```

### 2. Edit: `dot_config/shell/04_ai_agents.sh` (SSOT) — add one line

Add `AICAP_OLLAMA_MODEL` to the env-var block near the other
`AICAP_*_MODEL` lines. Default to `qwen2.5-coder:7b` (a sensible Ollama
coding model). Export at the bottom alongside the others.

```sh
: "${AICAP_OLLAMA_MODEL:=qwen2.5-coder:7b}"
…
export AICAP_OLLAMA_MODEL
```

This is the **only** SSOT change. We deliberately do NOT add `ollama` to
`AICAP_AGENT_PRIORITY` (parallels how `http` is opt-in per the comment at
`04_ai_capture.sh:42`).

### 3. Edit: `docs/shells/aliases.md` — add rows in the AI Capture section

Add 6 rows mirroring the existing aifix/aiexplain entries (function,
source file, scope, one-line). Reference `04_ai_run.sh` as the source.
Add a short note that these are streaming pass-through wrappers (unlike
aifix which is capture-and-diagnose).

### 4. NOT changed: CLAUDE.md cross-file rule for the AICAP SSOT

The existing rule covers "when adding a NEW agent" — ollama is not being
added as a new AICAP agent in the canonical sense (it's not in
`_aiagent_invoke`, not in autodetect, not parsed by the four Python
consumers). The shell-only `olr` wrapper and the new
`AICAP_OLLAMA_MODEL` env var are documented in the new file's header
comment, which is sufficient.

---

## Critical files

| Action | Path |
|---|---|
| **new** | `dot_config/shell/05_ai_run.sh` — six functions + header doc |
| **edit** | `dot_config/shell/04_ai_agents.sh` — one new `AICAP_OLLAMA_MODEL` env line + export |
| **edit** | `docs/shells/aliases.md` — new rows in AI Capture section |

---

## Verification

1. **Apply**: `chezmoi apply` — exercises template logic; no `.tmpl` files
   touched in this plan so there's no rendering risk, but apply is the
   canonical install path.
2. **Reload shell**: `exec zsh` (or `exec bash`), then `type ocr ccr cxr cur olr air` —
   all six should show `function`.
3. **Smoke each wrapper** with the cheapest model available (use the
   AICAP defaults — claude haiku is fast/cheap):
   ```sh
   ccr 'say "ack" and nothing else'        # expect: ack
   ocr 'say "ack" and nothing else'        # expect: ack
   cxr 'say "ack" and nothing else'        # only if codex auth configured
   cur 'say "ack" and nothing else'        # only if cursor-agent auth configured
   olr 'say "ack" and nothing else'        # only if ollama serve is running
   ```
4. **Autodetect path**: `air 'say "ack"'` → should dispatch to whichever
   agent is first on `$AICAP_AGENT_PRIORITY` and currently installed.
5. **Per-call override**: `air -a claude -m sonnet 'one-word: hi'` →
   should run claude with `--model sonnet` for this call only; afterward
   `echo $AICAP_CLAUDE_MODEL` still shows the SSOT default `haiku`.
6. **Pass-through forwarding**: `ccr -c 'continue from prior turn'` →
   should reach claude with `-p --model haiku -c "continue…"`. Verify
   the `-c` reaches claude by checking it picks up the last session.
7. **No-arg usage**: each of `ocr` / `ccr` / `cxr` / `cur` / `olr` / `air`
   with zero args should print a usage line to stderr and exit 1.
8. **Bash compatibility**: `bash -c 'source ~/.config/shell/04_ai_agents.sh; source ~/.config/shell/04_ai_capture.sh; source ~/.config/shell/05_ai_run.sh; type air'`
   — should report `air is a function` with no parse errors. Specifically
   confirms the `local -a` array syntax works in bash (used in both shells'
   common dir, must be POSIX-safe; `local -a` is bash/zsh-compatible).
9. **Lint**: `shellcheck -s bash dot_config/shell/05_ai_run.sh` — clean,
   matching the standard for the other files in `dot_config/shell/`.
