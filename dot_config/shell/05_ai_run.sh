# 05_ai_run.sh — quick "run one prompt through coding agent X" wrappers
#
#   ocr "prompt"      → opencode run     (agent tag [oc])
#   ccr "prompt"      → claude -p        (agent tag [cc])
#   cxr "prompt"      → codex exec       (agent tag [cx])
#   cur "prompt"      → cursor-agent -p  (agent tag [cu])
#   agr "prompt"      → agyc -p          (Antigravity CLI; agent tag [ag])
#   olr "prompt"      → ollama run       (shell-only sugar — see note below)
#   air "prompt"      → autodetect via $AICAP_AGENT_PRIORITY, -a / -m overrides
#
# Mnemonic mirrors the agent-session tags in
# dot_config/television/cable/agent-sessions.toml so muscle memory
# carries across `tv agent-sessions` (browse old) and these (start new).
#
# Difference from aifix / aiexplain (dot_config/shell/04_ai_capture.sh):
#   - aifix is capture-and-diagnose: needs a captured terminal block,
#     stdin, a tee'd run, or shell-history rerun.
#   - These wrappers just forward a fresh prompt and stream the agent's
#     reply straight back. No spinner, no metadata, no buffering.
#
# Pass-through forwarding: extra flags reach the underlying CLI, so
#   ccr -c 'continue from prior turn'
# expands to `claude -p --model haiku -c 'continue from prior turn'`
# (continue last session). Same trick works for `--resume`, custom
# `--model` overrides (claude honors the last `--model` flag), etc.
# Exception: `olr` is prompt-only, see comment on the function.
#
# Ollama note: `olr` is intentionally **not** an AICAP agent in the
# canonical sense — it does not appear in `_aiagent_invoke`, is not in
# the autodetect priority, and the four Python consumers of the SSOT
# (per the CLAUDE.md cross-file rule) do not parse `AICAP_OLLAMA_MODEL`.
# `olr` is shell-only sugar over `ollama run`. The cross-platform
# OpenRouter / OpenAI-compat / remote-Ollama-via-HTTP path is the
# existing `http` agent in 04_ai_capture.sh — opt in via
# `AICAP_AGENT=http air "…"`.

# Defensive load: if 04_ai_agents.sh wasn't sourced first, pull it in.
# Same pattern as 04_ai_capture.sh.
if [ -z "${_AICAP_AGENT_CONFIG_SOURCED:-}" ] && [ -r "$HOME/.config/shell/04_ai_agents.sh" ]; then
  # shellcheck disable=SC1091
  source "$HOME/.config/shell/04_ai_agents.sh"
fi

ocr() {
  if [ $# -eq 0 ]; then
    printf '%s\n' "usage: ocr [opencode flags] <prompt>" >&2
    return 1
  fi
  local -a model_args=()
  [ -n "$AICAP_OPENCODE_MODEL" ] && model_args=(-m "$AICAP_OPENCODE_MODEL")
  opencode run "${model_args[@]}" "$@"
}

ccr() {
  if [ $# -eq 0 ]; then
    printf '%s\n' "usage: ccr [claude flags] <prompt>" >&2
    return 1
  fi
  local -a model_args=()
  [ -n "$AICAP_CLAUDE_MODEL" ] && model_args=(--model "$AICAP_CLAUDE_MODEL")
  claude -p "${model_args[@]}" "$@"
}

cxr() {
  if [ $# -eq 0 ]; then
    printf '%s\n' "usage: cxr [codex flags] <prompt>" >&2
    return 1
  fi
  local -a model_args=()
  [ -n "$AICAP_CODEX_MODEL" ] && model_args=(-m "$AICAP_CODEX_MODEL")
  codex exec "${model_args[@]}" "$@"
}

cur() {
  if [ $# -eq 0 ]; then
    printf '%s\n' "usage: cur [cursor-agent flags] <prompt>" >&2
    return 1
  fi
  local -a model_args=()
  [ -n "$AICAP_CURSOR_MODEL" ] && model_args=(--model "$AICAP_CURSOR_MODEL")
  cursor-agent -p "${model_args[@]}" "$@"
}

# Antigravity CLI one-shot. `agyc` is a collision-free symlink → ~/.local/bin/agy
# (the Antigravity IDE squats the bare `agy`/`antigravity` names — the symlink is
# created by the ansible coding_agents role). No model arg: the CLI has no --model
# flag (model is account/config-side). Pass-through: `agr -c 'continue'` works.
agr() {
  if [ $# -eq 0 ]; then
    printf '%s\n' "usage: agr [agy flags] <prompt>" >&2
    return 1
  fi
  agyc -p "$@"
}

# Convenience aliases for the two Antigravity binaries (Google ships both as `agy`).
# `agyc` itself is a real symlink on PATH (ansible) so autodetect/which work; these
# are interactive sugar. The IDE alias is guarded so it stays harmless where the IDE
# isn't installed (e.g. Linux servers).
alias antigravity-cli='agyc'
[ -x "$HOME/.antigravity/antigravity/bin/agy" ] && alias agy-ide="$HOME/.antigravity/antigravity/bin/agy"

# `ollama run MODEL [PROMPT]` puts the model positionally before the
# prompt, so pass-through would land user flags AFTER the model and
# break parsing. Treat "$@" as the prompt only. Advanced ollama flags
# → drop to `ollama run` directly, or use `air -a http` for the
# OpenAI-compat path against localhost:11434.
olr() {
  if [ $# -eq 0 ]; then
    printf '%s\n' "usage: olr <prompt>   (model = \$AICAP_OLLAMA_MODEL = ${AICAP_OLLAMA_MODEL:-<unset>})" >&2
    return 1
  fi
  local model="${AICAP_OLLAMA_MODEL:-qwen2.5-coder:7b}"
  ollama run "$model" "$@"
}

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
          "usage: air [-a AGENT] [-m MODEL] [--] <prompt> [agent flags…]" \
          "" \
          "  -a AGENT   opencode | claude | codex | agyc | cursor-agent | ollama | http" \
          "             (default: \$AICAP_AGENT, else auto-detect via \$AICAP_AGENT_PRIORITY)" \
          "  -m MODEL   override AICAP_<AGENT>_MODEL for this call only" \
          "  --         end of air flags; everything after forwards to the agent CLI" \
          "" \
          "env (current):" \
          "  AICAP_AGENT_PRIORITY = ${AICAP_AGENT_PRIORITY}" \
          "  AICAP_AGENT          = ${AICAP_AGENT:-<unset = auto-detect>}" \
          "  AICAP_CLAUDE_MODEL   = ${AICAP_CLAUDE_MODEL:-<unset>}" \
          "  AICAP_OPENCODE_MODEL = ${AICAP_OPENCODE_MODEL:-<unset>}" \
          "  AICAP_CODEX_MODEL    = ${AICAP_CODEX_MODEL:-<unset>}" \
          "  AICAP_CURSOR_MODEL   = ${AICAP_CURSOR_MODEL:-<unset>}" \
          "  AICAP_OLLAMA_MODEL   = ${AICAP_OLLAMA_MODEL:-<unset>}" \
          "  AICAP_HTTP_MODEL     = ${AICAP_HTTP_MODEL:-<unset>}"
        return 0 ;;
      --) shift; prompt_args+=("$@"); break ;;
      -*) prompt_args+=("$1"); shift ;;
      *)  prompt_args+=("$1"); shift ;;
    esac
  done
  if [ "${#prompt_args[@]}" -eq 0 ]; then
    printf '%s\n' "air: missing prompt (try: air -h)" >&2
    return 1
  fi

  if [ -z "$agent" ]; then
    if [ -n "${AICAP_AGENT:-}" ]; then
      agent="$AICAP_AGENT"
    else
      agent=$(_aiagent_autodetect) || {
        printf '%s\n' "air: no agent CLI on PATH (priority: \$AICAP_AGENT_PRIORITY = $AICAP_AGENT_PRIORITY)" >&2
        printf '%s\n' "air: hint — set AICAP_AGENT=http or pass -a http for OpenRouter/Ollama HTTP" >&2
        return 1
      }
    fi
  fi

  # Subshell isolates the per-call -m override so it doesn't leak.
  case "$agent" in
    opencode|oc)     ( [ -n "$model_override" ] && AICAP_OPENCODE_MODEL="$model_override"; ocr "${prompt_args[@]}" ) ;;
    claude|cc)       ( [ -n "$model_override" ] && AICAP_CLAUDE_MODEL="$model_override";   ccr "${prompt_args[@]}" ) ;;
    codex|cx)        ( [ -n "$model_override" ] && AICAP_CODEX_MODEL="$model_override";    cxr "${prompt_args[@]}" ) ;;
    cursor-agent|cu) ( [ -n "$model_override" ] && AICAP_CURSOR_MODEL="$model_override";   cur "${prompt_args[@]}" ) ;;
    agyc|agy|ag)     ( agr "${prompt_args[@]}" ) ;;  # no model flag; -m override ignored
    ollama|ol)       ( [ -n "$model_override" ] && AICAP_OLLAMA_MODEL="$model_override";   olr "${prompt_args[@]}" ) ;;
    http)
      # `_aiagent_invoke` is fine here: curl returns the full JSON in one
      # shot anyway, so streaming isn't a factor. Joining prompt_args
      # with single spaces matches how 04_ai_capture.sh constructs the
      # http payload (single text content string).
      ( [ -n "$model_override" ] && AICAP_HTTP_MODEL="$model_override"
        _aiagent_invoke http "${prompt_args[*]}" )
      ;;
    *)
      printf '%s\n' "air: unknown agent '$agent' (supported: opencode|oc, claude|cc, codex|cx, cursor-agent|cu, agyc|ag, ollama|ol, http)" >&2
      return 1
      ;;
  esac
}
