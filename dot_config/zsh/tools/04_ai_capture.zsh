# AI-powered review of past commands — pipes the Nth block to a coding-agent
# CLI in one-shot / advisory mode (agent prints its reply to stdout; no file
# edits). Depends on 03_tmux_capture.zsh for `cpblock`.
#
#   aifix [N] [-a AGENT] [-p PROMPT]       # diagnose + suggest fix
#   aiexplain [N] [-a AGENT] [-p PROMPT]   # explain what happened
#   aiblock                                 # launch the questionary+rich TUI
#
# Agent auto-detection order: claude → opencode → codex → cursor-agent.
# Override via -a AGENT. Advisory-only by design; there is no --execute flag.
# For a back-and-forth interactive session, use `aiblock` → "Spawn agent".

_aiagent_autodetect() {
  local cand
  for cand in claude opencode codex cursor-agent; do
    if command -v "$cand" &>/dev/null; then
      print -r -- "$cand"
      return 0
    fi
  done
  return 1
}

# Invoke a coding-agent in one-shot mode. Mirror of the case-map in
# dot_config/zsh/tools/42_gitlab.zsh (glcreate-ai) so we stay consistent with
# the repo's one canonical invocation style.
_aiagent_invoke() {
  local agent=$1 prompt=$2
  case "$agent" in
    claude)       claude -p "$prompt" ;;
    opencode)     opencode run "$prompt" ;;
    codex)        codex exec "$prompt" ;;
    cursor-agent) cursor-agent -p "$prompt" ;;
    *) print -u2 "aifix: unknown agent '$agent' (supported: claude, opencode, codex, cursor-agent)"; return 1 ;;
  esac
}

# Shared dispatcher for aifix / aiexplain. Parses flags, captures the block,
# builds the prompt, invokes the agent. stdout = agent reply (pipe-friendly);
# stderr = one-line status ("aifix: claude ← block -3").
_ai_capture_dispatch() {
  emulate -L zsh
  local name=$1; shift
  local default_prompt=$1; shift
  local n=1 agent="" prompt_override=""
  while (( $# )); do
    case "$1" in
      -a|--agent)  agent=$2; shift 2 ;;
      -p|--prompt) prompt_override=$2; shift 2 ;;
      -h|--help)
        print -r -- "usage: $name [N] [-a AGENT] [-p PROMPT]"
        print -r -- "  N          block index back (default 1 = last)"
        print -r -- "  -a AGENT   claude | opencode | codex | cursor-agent (default: auto-detect)"
        print -r -- "  -p PROMPT  override default prompt"
        return 0 ;;
      --) shift; break ;;
      -*) print -u2 "$name: unknown flag: $1"; return 1 ;;
      *)  n=$1; shift ;;
    esac
  done
  if [[ ! "$n" =~ ^[0-9]+$ ]] || (( n < 1 )); then
    print -u2 "$name: N must be a positive integer (got: $n)"
    return 1
  fi
  if [[ -z "$agent" ]]; then
    agent=$(_aiagent_autodetect) || {
      print -u2 "$name: no coding-agent CLI found on PATH (tried: claude, opencode, codex, cursor-agent)"
      return 1
    }
  fi
  # Capture block via cpblock. 2>/dev/null drops cpblock's own status line;
  # we print our own below. cpblock's own clipboard-copy side-effect is OK.
  local block
  block=$(cpblock "$n" 2>/dev/null) || {
    print -u2 "$name: cpblock $n failed (check: echo \$precmd_functions | grep osc133; run 'exec zsh' if the shell pre-dates chezmoi apply)"
    return 1
  }
  if [[ -z "$block" ]]; then
    print -u2 "$name: cpblock $n returned empty"
    return 1
  fi
  local prompt="${prompt_override:-$default_prompt}

$block"
  print -u2 "$name: $agent ← block -$n"
  _aiagent_invoke "$agent" "$prompt"
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

# aiblock — launch the Python TUI (scripts/aiblock.py) resolved via
# chezmoi source-path, cached per-shell.
_AIBLOCK_SCRIPT=""
aiblock() {
  emulate -L zsh
  if [[ -z "$_AIBLOCK_SCRIPT" ]]; then
    local base
    base=$(chezmoi source-path 2>/dev/null) || {
      print -u2 "aiblock: could not resolve chezmoi source-path"
      return 1
    }
    _AIBLOCK_SCRIPT="$base/scripts/aiblock.py"
  fi
  if [[ ! -f "$_AIBLOCK_SCRIPT" ]]; then
    print -u2 "aiblock: $_AIBLOCK_SCRIPT not found (run 'chezmoi apply' after a git pull)"
    return 1
  fi
  uv run --script "$_AIBLOCK_SCRIPT" "$@"
}
