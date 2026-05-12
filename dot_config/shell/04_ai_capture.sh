# 04_ai_capture.sh - AI-powered review of past commands (shared bash + zsh).
# Moved from dot_config/zsh/tools/04_ai_capture.zsh. Zsh-isms replaced:
#   ${=AICAP_AGENT_PRIORITY}        → portable split (setopt sh_word_split / bash auto-split)
#   ${${url#*://}%%/*} (nested)     → two sequential assignments (bash doesn't nest)
#   print -r --                     → printf '%s\n'
#   print -u2                       → printf '%s\n' >&2
#   print -n                        → printf '%s'
#   frames[$(( (i%10)+1 ))]         → ${frames[*]:$(( i%10 )):1} (bash-style 0-idx slice)
#   ${pipestatus[1]}                → shell-dispatched ($PIPESTATUS[0] / $pipestatus[1])
#   &!                              → & disown
#   read -q "var?prompt"            → shell-dispatched (bash uses read -n 1 -p)
#   emulate -L zsh                  → gated on $ZSH_VERSION
#
# Depends on cpblock from dot_config/zsh/tools/03_tmux_capture.zsh (still
# zsh-only — relies on ZLE BUFFER/POSTDISPLAY). In bash, `aifix`/`aiexplain`
# error out with a hint to use `aifix-stdin` / `aifix-run` / `aifix-rerun`
# which don't need cpblock.
#
#   aifix [N] [-a AGENT] [-p PROMPT] [--raw] [--no-meta]
#   aiexplain [N] [-a AGENT] [-p PROMPT] [--raw] [--no-meta]
#   aiblock                                                    # Python TUI
#
# Agent auto-detection order and per-vendor lightweight model pins live in
# dot_config/shell/04_ai_agents.sh (the SSOT, sourced at shell init). This
# file READS the resulting AICAP_* env vars; it does NOT define defaults.
# To change the autodetect order globally, edit AICAP_AGENT_PRIORITY in the
# SSOT. To pin a different model for one tool, `export AICAP_<AGENT>_MODEL=…`
# before invoking it.
# Override via -a AGENT (per-call) or AICAP_AGENT env var (per-shell).
# Advisory-only by design; there is no --execute flag.
# For a back-and-forth interactive session, use `aiblock` → "Spawn agent".
#
# A fifth agent type `http` talks an OpenAI-compatible chat-completions endpoint
# directly via curl + jq. Use it for OpenRouter free models or local Ollama
# without depending on any agent CLI being installed:
#
#   AICAP_AGENT=http aifix              # OpenRouter (free Gemini Flash by default)
#   AICAP_AGENT=http \
#     AICAP_HTTP_URL=http://localhost:11434/v1/chat/completions \
#     AICAP_HTTP_MODEL=qwen2.5-coder:7b aifix
#
# `http` is opt-in: it is never auto-detected (nothing on PATH to probe).
#
# Env vars (set in ~/.shellrc.adhoc or ~/.config/{zsh/secrets.zsh,bash/secrets.sh}
# to override — those files always win against the SSOT's `: "${VAR:=…}"` defaults):
#
#   AICAP_AGENT            default: (unset — auto-detect via AICAP_AGENT_PRIORITY)
#                                        force a specific agent: opencode | claude |
#                                        codex | cursor-agent | http
#   AICAP_AGENT_PRIORITY   default: opencode claude codex cursor-agent     (SSOT)
#   AICAP_CLAUDE_MODEL     default: haiku                                  (SSOT)
#   AICAP_OPENCODE_MODEL   default: github-copilot/claude-haiku-4.5        (SSOT)
#   AICAP_CODEX_MODEL      default: (unset — gpt-5-mini errors on ChatGPT auth) (SSOT)
#   AICAP_CURSOR_MODEL     default: (unset — let cursor-agent pick)        (SSOT)
#   AICAP_HTTP_URL         default: https://openrouter.ai/api/v1/chat/completions (SSOT)
#   AICAP_HTTP_MODEL       default: google/gemini-2.0-flash-exp:free        (SSOT)
#   AICAP_HTTP_API_KEY     default: $OPENROUTER_API_KEY (empty = no auth header)
#   AICAP_SHOW_METADATA    default: 1  (tokens / cost / model on stderr; this file only)
#   AICAP_PRETTIFY         default: 1  (auto: glow → bat → raw; non-tty = raw)
#   AICAP_SPINNER          default: 1  (braille on stderr while agent thinks)
#
# Vars marked (SSOT) live in dot_config/shell/04_ai_agents.sh — change them
# there once, all four consumers (aifix, aiblock, aisuggest, tsum) see it.

# Defensive load: if 04_ai_agents.sh wasn't sourced first (e.g. someone
# dot-sourced this file directly without running rc), pull it in now.
if [ -z "${_AICAP_AGENT_CONFIG_SOURCED:-}" ] && [ -r "$HOME/.config/shell/04_ai_agents.sh" ]; then
  # shellcheck disable=SC1091
  source "$HOME/.config/shell/04_ai_agents.sh"
fi

# UX-only flags that don't apply to the Python consumers — these stay here.
: "${AICAP_SHOW_METADATA:=1}"
: "${AICAP_PRETTIFY:=1}"
: "${AICAP_SPINNER:=1}"

_aiagent_autodetect() {
  local cand
  # Word-split $AICAP_AGENT_PRIORITY. The original `${=…}` was zsh's explicit
  # word-splitting flag (zsh doesn't split unquoted params by default); bash
  # does auto-split unquoted. Dispatch:
  local _priority="${AICAP_AGENT_PRIORITY:-opencode claude codex cursor-agent}"
  if [ -n "$ZSH_VERSION" ]; then
    setopt local_options sh_word_split
  fi
  # shellcheck disable=SC2086
  for cand in $_priority; do
    if command -v "$cand" &>/dev/null; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

# Background spinner on stderr while the agent is thinking. Skipped when
# AICAP_SPINNER=0 or stderr isn't a tty (so pipes / file redirects stay
# clean). The spinner subprocess is disowned via `& disown` so it survives
# the command substitution that invokes the agent.
_AICAP_SPIN_PID=
_aicap_spinner_start() {
  [ "$AICAP_SPINNER" != "1" ] && return 0
  [ ! -t 2 ] && return 0
  local label="${1:-thinking}"
  (
    trap 'exit 0' TERM INT HUP
    local -a frames
    frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0
    while true; do
      # ${arr[*]:N:1} is bash-style array slicing (0-indexed); zsh supports
      # the same syntax. Quoted, a 1-element slice expands as one word.
      printf '\r\e[K%s %s' "${frames[*]:$(( i % 10 )):1}" "$label" >&2
      i=$(( i + 1 ))
      sleep 0.1
    done
  ) & disown
  _AICAP_SPIN_PID=$!
}

_aicap_spinner_stop() {
  [ -z "$_AICAP_SPIN_PID" ] && return 0
  kill "$_AICAP_SPIN_PID" 2>/dev/null
  # Drain; both shells wait on PIDs even if disowned as long as we know the PID.
  wait "$_AICAP_SPIN_PID" 2>/dev/null
  _AICAP_SPIN_PID=
  [ -t 2 ] && printf '\r\e[K' >&2
}

# Pretty-print stdin as Markdown: glow > bat > raw. Skips prettify if stdout
# is NOT a tty (so pipes stay clean) or AICAP_PRETTIFY=0.
_aicap_prettify() {
  if [ "$AICAP_PRETTIFY" != "1" ] || [ ! -t 1 ]; then
    cat
  elif command -v glow &>/dev/null; then
    glow -
  elif command -v bat &>/dev/null; then
    bat --language=md --style=plain --paging=never --color=always
  else
    cat
  fi
}

# Invoke a coding-agent in one-shot mode.
#
# Writes reply (text) to stdout. Writes metadata line to stderr when
# AICAP_SHOW_METADATA=1 and the agent supports structured JSON output.
# Currently only Claude's JSON includes usage/cost — other agents just get a
# "<agent> (<model>)" line on stderr.
_aiagent_invoke() {
  local agent="$1" prompt="$2"
  local json reply model_used tokens_in tokens_out cache_read cache_create cost duration rc

  # Ensure spinner cleans up if the caller returns or we hit a trap.
  trap '_aicap_spinner_stop' EXIT INT TERM

  case "$agent" in
    claude)
      # Conditional --model: empty AICAP_CLAUDE_MODEL → claude picks its
      # own default (robust if the pinned alias is ever retired).
      local -a claude_model_args
      claude_model_args=()
      [ -n "$AICAP_CLAUDE_MODEL" ] && claude_model_args=(--model "$AICAP_CLAUDE_MODEL")
      local claude_model_label="${AICAP_CLAUDE_MODEL:-(default)}"
      if [ "$AICAP_SHOW_METADATA" = "1" ] && command -v jq &>/dev/null; then
        _aicap_spinner_start "claude $claude_model_label (json)…"
        json=$(claude -p "${claude_model_args[@]}" --output-format json "$prompt")
        rc=$?
        _aicap_spinner_stop
        (( rc != 0 )) && return $rc
        reply=$(printf '%s\n' "$json" | jq -r '.result // empty')
        model_used=$(printf '%s\n' "$json" | jq -r '.modelUsage | keys | first // "?"')
        tokens_in=$(printf '%s\n' "$json" | jq -r '.usage.input_tokens // "?"')
        tokens_out=$(printf '%s\n' "$json" | jq -r '.usage.output_tokens // "?"')
        cache_read=$(printf '%s\n' "$json" | jq -r '.usage.cache_read_input_tokens // 0')
        cache_create=$(printf '%s\n' "$json" | jq -r '.usage.cache_creation_input_tokens // 0')
        cost=$(printf '%s\n' "$json" | jq -r '.total_cost_usd // "?"')
        duration=$(printf '%s\n' "$json" | jq -r '.duration_ms // "?"')
        printf '%s\n' "claude ($model_used) | in=$tokens_in out=$tokens_out cache=(r:$cache_read,w:$cache_create) | cost=\$$cost ${duration}ms" >&2
        printf '%s\n' "$reply"
      else
        printf '%s\n' "claude ($claude_model_label)" >&2
        _aicap_spinner_start "claude $claude_model_label…"
        claude -p "${claude_model_args[@]}" "$prompt"
        rc=$?
        _aicap_spinner_stop
        return $rc
      fi
      ;;
    opencode)
      local -a opencode_model_args
      opencode_model_args=()
      [ -n "$AICAP_OPENCODE_MODEL" ] && opencode_model_args=(-m "$AICAP_OPENCODE_MODEL")
      local opencode_model_label="${AICAP_OPENCODE_MODEL:-(default)}"
      printf '%s\n' "opencode ($opencode_model_label)" >&2
      _aicap_spinner_start "opencode $opencode_model_label…"
      opencode run "${opencode_model_args[@]}" "$prompt"
      rc=$?
      _aicap_spinner_stop
      return $rc
      ;;
    codex)
      # AICAP_CODEX_MODEL defaults to empty since gpt-5-mini is rejected on
      # ChatGPT-account auth. Users on API-key auth can re-pin via the env.
      local -a codex_model_args
      codex_model_args=()
      [ -n "$AICAP_CODEX_MODEL" ] && codex_model_args=(-m "$AICAP_CODEX_MODEL")
      local codex_model_label="${AICAP_CODEX_MODEL:-(default)}"
      printf '%s\n' "codex ($codex_model_label)" >&2
      _aicap_spinner_start "codex $codex_model_label…"
      codex exec "${codex_model_args[@]}" "$prompt"
      rc=$?
      _aicap_spinner_stop
      return $rc
      ;;
    cursor-agent)
      if [ -n "$AICAP_CURSOR_MODEL" ]; then
        printf '%s\n' "cursor-agent ($AICAP_CURSOR_MODEL)" >&2
        _aicap_spinner_start "cursor-agent $AICAP_CURSOR_MODEL…"
        cursor-agent -p --model "$AICAP_CURSOR_MODEL" "$prompt"
      else
        printf '%s\n' "cursor-agent" >&2
        _aicap_spinner_start "cursor-agent…"
        cursor-agent -p "$prompt"
      fi
      rc=$?
      _aicap_spinner_stop
      return $rc
      ;;
    http)
      # OpenAI-compatible chat-completions over curl. Covers OpenRouter (with
      # API key) and local Ollama (no auth) with the same code path. Never
      # auto-detected — opt in via AICAP_AGENT=http or `-a http`.
      local url="$AICAP_HTTP_URL" model="$AICAP_HTTP_MODEL"
      local key="${AICAP_HTTP_API_KEY:-${OPENROUTER_API_KEY:-}}"
      if ! command -v jq &>/dev/null; then
        printf '%s\n' "aifix: jq is required for the http agent" >&2
        return 1
      fi
      if ! command -v curl &>/dev/null; then
        printf '%s\n' "aifix: curl is required for the http agent" >&2
        return 1
      fi
      # Extract host from URL. Original used zsh-nested `${${url#*://}%%/*}`;
      # bash doesn't support nested expansion, so do it in two steps.
      local host
      host="${url#*://}"
      host="${host%%/*}"
      [ "$AICAP_SHOW_METADATA" != "1" ] && printf '%s\n' "http ($model @ $host)" >&2
      _aicap_spinner_start "http $model…"
      local payload response
      payload=$(jq -n --arg m "$model" --arg p "$prompt" \
        '{model: $m, messages: [{role: "user", content: $p}], stream: false}')
      local -a curl_args
      curl_args=(-sS -X POST "$url" -H 'Content-Type: application/json' -d "$payload")
      [ -n "$key" ] && curl_args+=(-H "Authorization: Bearer $key")
      response=$(curl "${curl_args[@]}")
      rc=$?
      _aicap_spinner_stop
      if (( rc != 0 )); then
        printf '%s\n' "http: curl failed (rc=$rc) — check AICAP_HTTP_URL ($url)" >&2
        return $rc
      fi
      local err
      err=$(printf '%s\n' "$response" | jq -r '.error.message // (.error | strings) // empty' 2>/dev/null)
      if [ -n "$err" ]; then
        printf '%s\n' "http: API error: $err" >&2
        return 1
      fi
      reply=$(printf '%s\n' "$response" | jq -r '.choices[0].message.content // empty')
      if [ -z "$reply" ]; then
        printf '%s\n' "http: empty reply (raw response: $response)" >&2
        return 1
      fi
      if [ "$AICAP_SHOW_METADATA" = "1" ]; then
        tokens_in=$(printf '%s\n' "$response" | jq -r '.usage.prompt_tokens // "?"')
        tokens_out=$(printf '%s\n' "$response" | jq -r '.usage.completion_tokens // "?"')
        printf '%s\n' "http ($model @ $host) | in=$tokens_in out=$tokens_out" >&2
      fi
      printf '%s\n' "$reply"
      ;;
    *) printf '%s\n' "aifix: unknown agent '$agent' (supported: opencode, claude, codex, cursor-agent, http)" >&2; return 1 ;;
  esac
}

# Core dispatcher: given an already-captured block, build the prompt, invoke
# the agent, pipe reply through the prettifier. Shared by the four sources:
# cpblock (aifix/aiexplain), stdin (aifix-stdin), tee'd CMD run (aifix-run),
# and thefuck-style rerun (aifix-rerun).
#
#   _ai_dispatch_core <name> <source-label> <default-prompt>
#                     <agent> <raw> <no-meta> <prompt-override> <block>
_ai_dispatch_core() {
  local name="$1" source_label="$2" default_prompt="$3"
  local agent="$4" raw="$5" no_meta="$6" prompt_override="$7" block="$8"
  if [ -z "$block" ]; then
    printf '%s\n' "$name: empty block" >&2
    return 1
  fi
  local prompt="${prompt_override:-$default_prompt}

$block"
  printf '%s\n' "$name ← $source_label" >&2

  # Per-call env overrides: --no-meta / --raw flip env-var behaviour locally
  # so _aiagent_invoke + _aicap_prettify see the intended values.
  local saved_show="$AICAP_SHOW_METADATA" saved_pretty="$AICAP_PRETTIFY"
  (( no_meta )) && AICAP_SHOW_METADATA=0
  (( raw ))    && AICAP_PRETTIFY=0

  if (( raw )); then
    _aiagent_invoke "$agent" "$prompt"
  else
    _aiagent_invoke "$agent" "$prompt" | _aicap_prettify
  fi
  local rc=$?

  AICAP_SHOW_METADATA="$saved_show"
  AICAP_PRETTIFY="$saved_pretty"
  return $rc
}

# Print the shared flag-help + env-var snapshot. Used by -h on each wrapper.
_ai_print_help() {
  local name="$1" usage="$2"
  printf '%s\n' "usage: $name $usage"
  printf '%s\n' "  -a AGENT   claude | opencode | codex | cursor-agent | http (default: auto-detect)"
  printf '%s\n' "  -p PROMPT  override default prompt"
  printf '%s\n' "  --raw      disable prettify (glow/bat), print raw agent reply"
  printf '%s\n' "  --no-meta  suppress the stderr metadata line"
  printf '%s\n' ""
  printf '%s\n' "env vars:"
  printf '%s\n' "  AICAP_AGENT          = ${AICAP_AGENT:-<unset = auto-detect>}"
  printf '%s\n' "  AICAP_CLAUDE_MODEL   = ${AICAP_CLAUDE_MODEL}"
  printf '%s\n' "  AICAP_OPENCODE_MODEL = ${AICAP_OPENCODE_MODEL}"
  printf '%s\n' "  AICAP_CODEX_MODEL    = ${AICAP_CODEX_MODEL}"
  printf '%s\n' "  AICAP_CURSOR_MODEL   = ${AICAP_CURSOR_MODEL:-<unset>}"
  printf '%s\n' "  AICAP_HTTP_URL       = ${AICAP_HTTP_URL}"
  printf '%s\n' "  AICAP_HTTP_MODEL     = ${AICAP_HTTP_MODEL}"
  if [ -n "${AICAP_HTTP_API_KEY:-${OPENROUTER_API_KEY:-}}" ]; then
    printf '%s\n' "  AICAP_HTTP_API_KEY   = <set>"
  else
    printf '%s\n' "  AICAP_HTTP_API_KEY   = <unset>"
  fi
  printf '%s\n' "  AICAP_SHOW_METADATA  = ${AICAP_SHOW_METADATA}"
  printf '%s\n' "  AICAP_PRETTIFY       = ${AICAP_PRETTIFY}"
  printf '%s\n' "  AICAP_SPINNER        = ${AICAP_SPINNER}"
}

# Shared dispatcher for aifix / aiexplain. Captures via cpblock (zsh-only).
_ai_capture_dispatch() {
  [ -n "$ZSH_VERSION" ] && emulate -L zsh
  local name="$1"; shift
  local default_prompt="$1"; shift
  local n=1 agent="" prompt_override="" raw=0 no_meta=0
  while (( $# )); do
    case "$1" in
      -a|--agent)   agent="$2"; shift 2 ;;
      -p|--prompt)  prompt_override="$2"; shift 2 ;;
      --raw)        raw=1; shift ;;
      --no-meta)    no_meta=1; shift ;;
      -h|--help)    _ai_print_help "$name" "[N] [-a AGENT] [-p PROMPT] [--raw] [--no-meta]"
                    printf '%s\n' "  N          block index back (default 1 = last)"
                    return 0 ;;
      --) shift; break ;;
      -*) printf '%s\n' "$name: unknown flag: $1" >&2; return 1 ;;
      *)  n="$1"; shift ;;
    esac
  done
  if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n < 1 )); then
    printf '%s\n' "$name: N must be a positive integer (got: $n)" >&2
    return 1
  fi
  if [ -z "$agent" ]; then
    if [ -n "$AICAP_AGENT" ]; then
      agent="$AICAP_AGENT"
    else
      agent=$(_aiagent_autodetect) || {
        printf '%s\n' "$name: no coding-agent CLI found on PATH (tried: opencode, claude, codex, cursor-agent)" >&2
        printf '%s\n' "$name: hint — set AICAP_AGENT=http to use OpenRouter / Ollama directly" >&2
        return 1
      }
    fi
  fi
  if ! command -v cpblock &>/dev/null; then
    printf '%s\n' "$name: cpblock not defined (zsh-only; loaded from dot_config/zsh/tools/03_tmux_capture.zsh)" >&2
    printf '%s\n' "$name: in bash, use \`aifix-stdin\` / \`aifix-run\` / \`aifix-rerun\` instead" >&2
    return 1
  fi
  local block
  block=$(cpblock "$n" 2>/dev/null) || {
    printf '%s\n' "$name: cpblock $n failed (run 'exec zsh' if the shell pre-dates chezmoi apply)" >&2
    return 1
  }
  _ai_dispatch_core "$name" "block -$n" "$default_prompt" \
    "$agent" "$raw" "$no_meta" "$prompt_override" "$block"
}

aifix() {
  _ai_capture_dispatch aifix \
    "Here is a command I ran in my terminal and its output. Diagnose any errors and suggest a concrete fix. Be brief and specific." \
    "$@"
}

aiexplain() {
  _ai_capture_dispatch aiexplain \
    "Here is a command I ran in my terminal and its output. Explain what happened in plain language. Be concise." \
    "$@"
}

# -----------------------------------------------------------------------------
# Non-tmux Tier 1: stdin / run / rerun sources
# -----------------------------------------------------------------------------
# These three cover the "no tmux available" case (VSCode integrated terminal,
# bare Ghostty without tmux, quick SSH) by NOT relying on cpblock / OSC 133.
# Each composes zero magic — user explicitly picks the source.
#
# See backlog/ai-capture-non-tmux-output.md for why we don't do automatic
# tee redirection (Tier 2) or PTY proxy wrapping (Tier 3).

# aifix-stdin: read whatever the caller piped in. Universal.
#   tail -200 /var/log/nginx/error.log | aifix-stdin
#   curl -sS https://weird.api/thing | aifix-stdin -p "explain this JSON"
#   aifix-stdin < build.log
aifix-stdin() {
  [ -n "$ZSH_VERSION" ] && emulate -L zsh
  local name=aifix-stdin agent="" prompt_override="" raw=0 no_meta=0
  local default_prompt="Here is output captured from my terminal. Diagnose any errors and suggest a concrete fix. Be brief and specific."
  while (( $# )); do
    case "$1" in
      -a|--agent)   agent="$2"; shift 2 ;;
      -p|--prompt)  prompt_override="$2"; shift 2 ;;
      --raw)        raw=1; shift ;;
      --no-meta)    no_meta=1; shift ;;
      -h|--help)    _ai_print_help "$name" "[-a AGENT] [-p PROMPT] [--raw] [--no-meta]"
                    printf '%s\n' "  Reads block from stdin. No tmux / cpblock dependency."
                    return 0 ;;
      *) printf '%s\n' "$name: unexpected arg: $1 (did you mean -p?)" >&2; return 1 ;;
    esac
  done
  if [ -z "$agent" ]; then
    if [ -n "$AICAP_AGENT" ]; then
      agent="$AICAP_AGENT"
    else
      agent=$(_aiagent_autodetect) || {
        printf '%s\n' "$name: no coding-agent CLI found on PATH (set AICAP_AGENT=http for OpenRouter / Ollama)" >&2
        return 1
      }
    fi
  fi
  # -t 0 checks if stdin is a terminal. If it is, user likely forgot to pipe.
  if [ -t 0 ]; then
    printf '%s\n' "$name: stdin is a tty — did you forget to pipe? Example:" >&2
    printf '%s\n' "  some-command 2>&1 | $name" >&2
    return 1
  fi
  local block
  block=$(cat)
  _ai_dispatch_core "$name" "stdin" "$default_prompt" \
    "$agent" "$raw" "$no_meta" "$prompt_override" "$block"
}

# aifix-run: run CMD, tee stdout+stderr to a log, feed "$ CMD\n<output>\n(exit code: N)"
# to the agent. Use `--` to separate flags from the command.
#   aifix-run -- cargo build --release
#   aifix-run -p "is this safe?" -- ansible-playbook deploy.yml
#
# isatty caveat: teeing makes CMD's stdout a pipe, so TUI apps (vim, less)
# render in degraded mode. Don't use this for interactive tools.
aifix-run() {
  [ -n "$ZSH_VERSION" ] && emulate -L zsh
  local name=aifix-run agent="" prompt_override="" raw=0 no_meta=0
  local default_prompt="Here is a command I ran in my terminal and its output. Diagnose any errors and suggest a concrete fix. Be brief and specific."
  while (( $# )); do
    case "$1" in
      -a|--agent)   agent="$2"; shift 2 ;;
      -p|--prompt)  prompt_override="$2"; shift 2 ;;
      --raw)        raw=1; shift ;;
      --no-meta)    no_meta=1; shift ;;
      -h|--help)    _ai_print_help "$name" "[-a AGENT] [-p PROMPT] [--raw] [--no-meta] -- CMD [ARG...]"
                    printf '%s\n' "  Runs CMD with stdout+stderr teed to a log, feeds to agent."
                    printf '%s\n' "  Use \`--\` to separate flags from the command."
                    return 0 ;;
      --) shift; break ;;
      -*) printf '%s\n' "$name: unknown flag: $1" >&2; return 1 ;;
      *) break ;;
    esac
  done
  if (( $# == 0 )); then
    printf '%s\n' "$name: missing command. Usage: $name [flags] -- CMD [ARG...]" >&2
    return 1
  fi
  if [ -z "$agent" ]; then
    if [ -n "$AICAP_AGENT" ]; then
      agent="$AICAP_AGENT"
    else
      agent=$(_aiagent_autodetect) || {
        printf '%s\n' "$name: no coding-agent CLI found on PATH (set AICAP_AGENT=http for OpenRouter / Ollama)" >&2
        return 1
      }
    fi
  fi
  local log
  log=$(mktemp -t aifix-run.XXXXXX) || { printf '%s\n' "$name: mktemp failed" >&2; return 1; }
  # Record the command line as the block's first line so the agent knows
  # what was run.
  printf '%s\n' "\$ $*" > "$log"
  "$@" 2>&1 | tee -a "$log"
  # Capture pipeline exit status. zsh uses ${pipestatus[1]} (1-indexed),
  # bash uses ${PIPESTATUS[0]} (0-indexed).
  local rc
  if [ -n "$ZSH_VERSION" ]; then
    rc=${pipestatus[1]}
  else
    rc=${PIPESTATUS[0]}
  fi
  printf '\n' >> "$log"
  printf '%s\n' "(exit code: $rc)" >> "$log"
  local block
  block=$(<"$log")
  rm -f "$log"
  _ai_dispatch_core "$name" "run \`${1}…\` (exit $rc)" "$default_prompt" \
    "$agent" "$raw" "$no_meta" "$prompt_override" "$block"
}

# aifix-rerun: thefuck-style. Re-executes the last command from shell history
# via aifix-run. Prompts for confirmation unless -y, because re-running has
# side effects if the command isn't idempotent.
aifix-rerun() {
  [ -n "$ZSH_VERSION" ] && emulate -L zsh
  local name=aifix-rerun yes=0
  local -a forward
  forward=()
  while (( $# )); do
    case "$1" in
      -y|--yes) yes=1; shift ;;
      -h|--help) _ai_print_help "$name" "[-y] [-a AGENT] [-p PROMPT] [--raw] [--no-meta]"
                 printf '%s\n' "  Re-executes the last command from shell history via aifix-run."
                 printf '%s\n' "  Prompts for confirmation unless -y (side effects beware)."
                 return 0 ;;
      *) forward+=("$1"); shift ;;
    esac
  done
  # fc -ln -2 -2: skip aifix-rerun itself (which is -1), grab the one before.
  # `fc` works in both bash and zsh.
  local cmd
  cmd=$(fc -ln -2 -2 2>/dev/null)
  cmd="${cmd#	}"; cmd="${cmd# }"
  if [ -z "$cmd" ]; then
    printf '%s\n' "$name: no prior command in shell history" >&2
    return 1
  fi
  printf '%s\n' "$name: will re-execute:" >&2
  printf '%s\n' "  $cmd" >&2
  printf '%s\n' "⚠ side effects if the command is not idempotent (network calls, file writes, etc.)" >&2
  if (( ! yes )); then
    # zsh's `read -q "var?prompt"` reads 1 char and returns 0 only for y/Y.
    # bash uses `read -n 1 -p "prompt" var`; we then compare $var.
    local reply
    if [ -n "$ZSH_VERSION" ]; then
      read -q "reply?Proceed? [y/N] "
    else
      read -r -n 1 -p "Proceed? [y/N] " reply
    fi
    printf '\n'
    if [ "$reply" != "y" ] && [ "$reply" != "Y" ]; then
      printf '%s\n' "$name: aborted" >&2
      return 130
    fi
  fi
  # Delegate to aifix-run via eval (preserves quoting for $cmd's shell syntax).
  eval "aifix-run ${forward[*]} -- $cmd"
}

# aiblock — launch the Python TUI (scripts/aiblock.py) resolved via
# chezmoi source-path, cached per-shell. The Python side reads the same
# AICAP_* env vars so model defaults stay consistent.
#
# History passing: `fc -ln …` only works inside the current interactive
# shell — a subshell doesn't inherit the in-memory history buffer and
# `fc -R` only pulls whatever HISTFILE has on disk (which misses unflushed
# recent commands). Dump the current shell's history into a temp file and
# hand the path to the TUI via $AIBLOCK_HIST_DUMP.
_AIBLOCK_SCRIPT=""
aiblock() {
  [ -n "$ZSH_VERSION" ] && emulate -L zsh
  if [ -z "$_AIBLOCK_SCRIPT" ]; then
    local base
    base=$(chezmoi source-path 2>/dev/null) || {
      printf '%s\n' "aiblock: could not resolve chezmoi source-path" >&2
      return 1
    }
    _AIBLOCK_SCRIPT="$base/scripts/aiblock.py"
  fi
  if [ ! -f "$_AIBLOCK_SCRIPT" ]; then
    printf '%s\n' "aiblock: $_AIBLOCK_SCRIPT not found (run 'chezmoi apply' after a git pull)" >&2
    return 1
  fi
  local histdump
  histdump=$(mktemp -t aiblock-hist.XXXXXX) || {
    printf '%s\n' "aiblock: mktemp failed" >&2
    return 1
  }
  # fc -ln -30: last 30 entries, no numbering. Trailing newline per entry.
  fc -ln -30 > "$histdump" 2>/dev/null
  AIBLOCK_HIST_DUMP="$histdump" uv run --script "$_AIBLOCK_SCRIPT" "$@"
  local rc=$?
  rm -f "$histdump"
  return $rc
}
