# 44_copilot_embed.sh - embeddings + semantic search over the Copilot proxy
#   (shared bash + zsh). Sibling to 43_copilot_proxy.sh — loads AFTER it, so the
#   _copilot_base / _copilot_alive / copilot-proxy helpers already exist.
#
# The copilot-api proxy (43_copilot_proxy.sh) is OpenAI-compatible and also
# serves POST /v1/embeddings, backed by a GitHub Copilot subscription. Copilot
# exposes three 1536-dim embedding models (text-embedding-3-small [default],
# text-embedding-ada-002, text-embedding-3-small-inference). This file turns
# that into two tools: a raw embedding primitive and a semantic-search app.
#
# Public surface:
#   copilot-embed [--model M] [--json] [TEXT | -]  - embed TEXT (or stdin) → vector
#   copilot-embed -l                               - list available embedding models
#   semsearch index [PATH...]                      - build/refresh a search index
#   semsearch <QUERY> [-k N] [--corpus PATH]       - semantic search a corpus
#     (semsearch is a thin wrapper over scripts/semsearch.py, run via uv)
#
# GOTCHA (verified 2026-07): the proxy requires the embeddings request `input`
# to be an ARRAY. A scalar string 400s with a generic "Bad Request" — this is
# the fork's issue #100 (caozhiyuan/copilot-api). copilot-embed always wraps the
# text in a one-element array; semsearch.py batches many texts per array.
#
# Env (SSOT in 04_ai_agents.sh; override in ~/.shellrc.adhoc):
#   AICAP_EMBED_MODEL   default: text-embedding-3-small  - model for /v1/embeddings
#                                                          (empty → endpoint default)
#   COPILOT_PROXY_PORT  default: 4141                    - proxy port (from 43)

# Skip silently if already sourced (idempotent — safe to dot in sub-shells).
[ -n "${_COPILOT_EMBED_SOURCED:-}" ] && return 0
_COPILOT_EMBED_SOURCED=1

# Defensive load: if 43_copilot_proxy.sh wasn't sourced first (e.g. someone
# dot-sourced this file directly without running rc), pull it in so the shared
# _copilot_* helpers exist. Same pattern as 04_ai_capture.sh / 05_ai_run.sh.
if ! command -v _copilot_base >/dev/null 2>&1 \
   && [ -r "$HOME/.config/shell/43_copilot_proxy.sh" ]; then
  # shellcheck disable=SC1091
  source "$HOME/.config/shell/43_copilot_proxy.sh"
fi

# --- embedding primitive --------------------------------------------------------

# Embed TEXT (positional arg) or stdin ("-" or piped) via the proxy's
# /v1/embeddings endpoint. Auto-starts the proxy when it isn't answering.
# stdout = data (JSON), stderr = status — so `copilot-embed foo | jq …` is clean.
# Example:
#   copilot-embed "hello world" | jq 'length'      # → 1536
#   printf 'some doc text' | copilot-embed          # embed from stdin
#   copilot-embed --json "hi" | jq '.usage'         # full response
#   copilot-embed -l                                # which embedding models?
copilot-embed() {
  if [ -n "$ZSH_VERSION" ]; then
    emulate -L zsh
    setopt localoptions pipefail
  else
    set -o pipefail
  fi

  if ! command -v curl >/dev/null 2>&1; then
    printf '%s\n' "copilot-embed: curl is required" >&2; return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' "copilot-embed: jq is required" >&2; return 1
  fi

  local model="${AICAP_EMBED_MODEL:-text-embedding-3-small}"
  local want_json=0 do_list=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -m|--model)   model="$2"; shift 2 ;;
      --model=*)    model="${1#--model=}"; shift ;;
      --json)       want_json=1; shift ;;
      -l|--list)    do_list=1; shift ;;
      -h|--help)
        printf '%s\n' "Usage: copilot-embed [--model M] [--json] [TEXT | -]"
        printf '%s\n' "       copilot-embed -l        # list embedding models"
        printf '%s\n' "  Embeds TEXT (or stdin) via the Copilot proxy /v1/embeddings."
        printf '%s\n' "  Default output: the vector as a JSON array on stdout."
        return 0 ;;
      --)           shift; break ;;
      -*)
        printf '%s\n' "copilot-embed: unknown flag '$1' (try --help)" >&2; return 1 ;;
      *)            break ;;
    esac
  done

  # Make sure the proxy is up (mirror copilot-run's auto-start).
  if ! _copilot_alive; then
    copilot-proxy start >&2 || return 1
  fi

  # -l: list the embedding-model ids the proxy advertises.
  if [ "$do_list" = "1" ]; then
    command curl -fsS --max-time 3 "$(_copilot_base)/v1/models" 2>/dev/null \
      | jq -r '.data[].id' | command grep -i embed | command sort
    return 0
  fi

  # Text from the remaining arg(s), or stdin ("-" or piped).
  local text
  if [ "$#" -gt 0 ] && [ "$1" != "-" ]; then
    text="$*"
  else
    if [ -t 0 ]; then
      printf '%s\n' "copilot-embed: no text — pass an arg or pipe stdin (see --help)" >&2
      return 1
    fi
    text="$(command cat)"
  fi
  if [ -z "$text" ]; then
    printf '%s\n' "copilot-embed: empty input" >&2; return 1
  fi

  # Build the payload. input MUST be an array (scalar 400s — issue #100).
  # Empty model → omit the key so the endpoint default applies.
  local payload
  if [ -n "$model" ]; then
    payload=$(jq -n --arg m "$model" --arg t "$text" '{model: $m, input: [$t]}')
  else
    payload=$(jq -n --arg t "$text" '{input: [$t]}')
  fi

  local response rc
  response=$(command curl -sS --max-time 60 -X POST "$(_copilot_base)/v1/embeddings" \
    -H 'Content-Type: application/json' -d "$payload")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "copilot-embed: curl failed (rc=$rc) — is the proxy up? (copilot-proxy status)" >&2
    return "$rc"
  fi

  local err
  err=$(printf '%s' "$response" | jq -r '.error.message // (.error | strings) // empty' 2>/dev/null)
  if [ -n "$err" ]; then
    printf '%s\n' "copilot-embed: API error: $err" >&2
    return 1
  fi

  if [ "$want_json" = "1" ]; then
    printf '%s\n' "$response" | jq .
    return 0
  fi

  local vec
  vec=$(printf '%s' "$response" | jq -c '.data[0].embedding // empty')
  if [ -z "$vec" ]; then
    printf '%s\n' "copilot-embed: empty embedding (raw: $response)" >&2
    return 1
  fi
  # Interactive nicety: dimension + token usage to stderr (kept off pipes).
  if [ -t 2 ]; then
    local dim toks
    dim=$(printf '%s' "$vec" | jq 'length')
    toks=$(printf '%s' "$response" | jq -r '.usage.prompt_tokens // "?"')
    printf '%s\n' "copilot-embed: ${model:-default} | dim=$dim tokens=$toks" >&2
  fi
  printf '%s\n' "$vec"
}

# --- semantic search app --------------------------------------------------------

# Thin wrapper over scripts/semsearch.py (resolved via chezmoi source-path,
# cached per-shell — exact mirror of aiblock() in 04_ai_capture.sh). The Python
# side does the chunking, batched embedding, incremental cache, and cosine
# ranking; it reads the proxy base from COPILOT_EMBED_BASE and the model from
# AICAP_EMBED_MODEL (both set here / by the SSOT).
# Example:
#   semsearch index                    # index the default corpus (chezmoi docs/tools)
#   semsearch index ~/notes            # index a directory
#   semsearch "how do I switch model"  # query the last-indexed / default corpus
#   semsearch "vector math" -k 5       # top-5
_SEMSEARCH_SCRIPT=""
semsearch() {
  case "${1:-}" in
    ""|-h|--help)
      printf '%s\n' "Usage: semsearch index [PATH...]        # build/refresh an index"
      printf '%s\n' "       semsearch <QUERY> [-k N] [--corpus PATH]"
      printf '%s\n' "  Semantic search over local text via Copilot embeddings."
      printf '%s\n' "  Default corpus: <chezmoi source>/docs/tools."
      [ -z "${1:-}" ] && return 1
      return 0 ;;
  esac

  if ! command -v uv >/dev/null 2>&1; then
    printf '%s\n' "semsearch: uv is required (mise use -g uv)" >&2; return 1
  fi
  if [ -z "$_SEMSEARCH_SCRIPT" ]; then
    local base
    base=$(chezmoi source-path 2>/dev/null) || {
      printf '%s\n' "semsearch: could not resolve chezmoi source-path" >&2
      return 1
    }
    _SEMSEARCH_SCRIPT="$base/scripts/semsearch.py"
  fi
  if [ ! -f "$_SEMSEARCH_SCRIPT" ]; then
    printf '%s\n' "semsearch: $_SEMSEARCH_SCRIPT not found (run 'chezmoi apply' after a git pull)" >&2
    return 1
  fi

  # Any subcommand that talks to the proxy needs it up; start it once here.
  if ! _copilot_alive; then
    copilot-proxy start >&2 || return 1
  fi

  COPILOT_EMBED_BASE="$(_copilot_base)" uv run --script "$_SEMSEARCH_SCRIPT" "$@"
}
