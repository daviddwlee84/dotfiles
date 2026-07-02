# 43_copilot_proxy.sh - GitHub Copilot -> Anthropic/OpenAI proxy for Claude Code
#   (shared bash + zsh).
#
# Runs ericc-ch/copilot-api (a reverse-engineered proxy) so a GitHub Copilot
# subscription can back Claude Code (and any OpenAI/Anthropic-compatible client).
# Full guide + risks: docs/tools/copilot-claude-proxy.md.
#
# Public surface:
#   copilot-proxy [start|stop|status|restart|logs|whoami|auth]   - manage the proxy
#   copilot-model [<id>|-l|-c]                             - switch model in a
#                                                            project's .claude/settings.json
#
# Portability notes (POSIX subset, both shells source this file):
#   - runs the proxy via `bunx` (matches 07_bunx_cli.sh); pinned version avoids a
#     per-launch @latest registry round-trip. Override with COPILOT_API_PKG.
#   - no ZLE/compdef/setopt/glob-qualifiers here (bash would error on source).
#
# Env (set in ~/.shellrc.adhoc or ~/.config/{zsh/secrets.zsh,bash/secrets.sh}):
#   COPILOT_PROXY_PORT   default: 4141        - port the proxy listens on
#   COPILOT_PROXY_RATE   default: 15          - --rate-limit seconds (be gentle;
#                                               Claude Code is chatty → abuse risk)
#   COPILOT_API_PKG      default: copilot-api@0.7.0  - bunx package spec (pin/upgrade)

# --- shared constants / helpers -------------------------------------------------

_copilot_port() { printf '%s' "${COPILOT_PROXY_PORT:-4141}"; }
_copilot_pkg()  { printf '%s' "${COPILOT_API_PKG:-copilot-api@0.7.0}"; }
_copilot_base() { printf 'http://localhost:%s' "$(_copilot_port)"; }
_copilot_logfile() { printf '%s' "${TMPDIR:-/tmp}/copilot-api-$(_copilot_port).log"; }
_copilot_pidfile() { printf '%s' "${TMPDIR:-/tmp}/copilot-api-$(_copilot_port).pid"; }

# Is the proxy answering on its port?
_copilot_alive() {
  command curl -fsS --max-time 2 "$(_copilot_base)/v1/models" >/dev/null 2>&1
}

# --- proxy manager --------------------------------------------------------------

# Manage the copilot-api proxy. Subcommands: start|stop|status|restart|logs|auth.
# Example:
#   copilot-proxy start          # background-start on $COPILOT_PROXY_PORT
#   copilot-proxy status         # is it up? which models?
copilot-proxy() {
  if [ -n "$ZSH_VERSION" ]; then
    emulate -L zsh
    setopt localoptions pipefail
  else
    set -o pipefail
  fi

  if ! command -v bunx >/dev/null 2>&1; then
    printf '%s\n' "copilot-proxy: bunx not found (needs bun via mise)." >&2
    return 1
  fi

  local port pkg logf pidf
  port="$(_copilot_port)"; pkg="$(_copilot_pkg)"
  logf="$(_copilot_logfile)"; pidf="$(_copilot_pidfile)"

  local action="${1:-status}"
  case "$action" in
    start)
      if _copilot_alive; then
        printf '%s\n' "copilot-proxy: already running on port $port" >&2
        return 0
      fi
      # First run needs `copilot-proxy auth` to store a ghu_ token; warn if absent.
      if [ ! -f "$HOME/.local/share/copilot-api/github_token" ]; then
        printf '%s\n' "copilot-proxy: not authenticated yet — run 'copilot-proxy auth' first." >&2
        return 1
      fi
      printf '%s\n' "copilot-proxy: starting ($pkg) on port $port (rate-limit ${COPILOT_PROXY_RATE:-15}s) ..."
      # nohup + background; detach so it survives the shell. Log to a file.
      nohup bunx "$pkg" start \
        --port "$port" \
        --rate-limit "${COPILOT_PROXY_RATE:-15}" \
        --wait \
        >"$logf" 2>&1 &
      printf '%s\n' "$!" >"$pidf"
      # Wait up to ~20s for it to answer.
      local i=0
      while [ "$i" -lt 20 ]; do
        if _copilot_alive; then
          printf '%s\n' "copilot-proxy: up → $(_copilot_base)  (logs: copilot-proxy logs)"
          return 0
        fi
        sleep 1
        i=$((i + 1))
      done
      printf '%s\n' "copilot-proxy: did not come up in time — check 'copilot-proxy logs'." >&2
      return 1
      ;;
    stop)
      # Prefer the tracked pid; fall back to a broad match.
      if [ -f "$pidf" ]; then
        local pid; pid="$(cat "$pidf" 2>/dev/null)"
        [ -n "$pid" ] && kill "$pid" 2>/dev/null
        command rm -f -- "$pidf"
      fi
      command pkill -f "copilot-api.*--port $port" 2>/dev/null
      sleep 1
      if _copilot_alive; then
        printf '%s\n' "copilot-proxy: still answering on $port (another instance?)" >&2
        return 1
      fi
      printf '%s\n' "copilot-proxy: stopped (port $port free)"
      ;;
    restart)
      copilot-proxy stop
      copilot-proxy start
      ;;
    status)
      if _copilot_alive; then
        printf '%s\n' "copilot-proxy: RUNNING on $(_copilot_base)"
        printf '%s\n' "  models: $(command curl -fsS --max-time 3 "$(_copilot_base)/v1/models" 2>/dev/null \
          | command grep -o '"id":"[^"]*"' | command sed 's/"id":"//;s/"//' | command grep -i claude | command tr '\n' ' ')"
      else
        printf '%s\n' "copilot-proxy: not running on port $port  (start: copilot-proxy start)"
        return 1
      fi
      ;;
    logs)
      if [ -f "$logf" ]; then command tail -n "${2:-40}" "$logf"; else
        printf '%s\n' "copilot-proxy: no log file at $logf" >&2; return 1; fi
      ;;
    auth)
      # One-time device login → stores a ghu_ token copilot-api can exchange.
      printf '%s\n' "copilot-proxy: launching copilot-api device login ..."
      bunx "$pkg" auth
      ;;
    whoami|usage)
      # Real login check: exchanges the stored token against GitHub and prints
      # the account / plan / quota. Fails loudly if the token is missing/expired.
      if [ ! -f "$HOME/.local/share/copilot-api/github_token" ]; then
        printf '%s\n' "copilot-proxy: not authenticated — run 'copilot-proxy auth' first." >&2
        return 1
      fi
      bunx "$pkg" check-usage
      ;;
    -h|--help|help)
      printf '%s\n' "Usage: copilot-proxy [start|stop|restart|status|logs [N]|whoami|auth]"
      ;;
    *)
      printf '%s\n' "copilot-proxy: unknown action '$action' (try --help)" >&2
      return 1
      ;;
  esac
}

# --- model switcher -------------------------------------------------------------

# Switch which Copilot model the current dir's .claude/settings.json uses.
# Claude Code's own /model picker sends Anthropic ids the Copilot backend rejects
# (model_not_supported), so pin the model here instead. Restart Claude Code after.
# Example:
#   copilot-model opus-4.8       # fuzzy → claude-opus-4.8
#   copilot-model -l             # list available (live from proxy)
#   copilot-model -c             # print current
copilot-model() {
  if [ -n "$ZSH_VERSION" ]; then
    emulate -L zsh
    setopt localoptions pipefail
  else
    set -o pipefail
  fi

  local settings=".claude/settings.json"

  # List available model ids (live proxy, else a static Claude fallback).
  _copilot_model_list() {
    local json
    if json="$(command curl -fsS --max-time 3 "$(_copilot_base)/v1/models" 2>/dev/null)"; then
      printf '%s\n' "$json" | command grep -o '"id":"[^"]*"' | command sed 's/"id":"//;s/"//' | command sort
    else
      printf '%s\n' \
        claude-opus-4.8 claude-opus-4.7 claude-opus-4.6 claude-opus-4.5 \
        claude-sonnet-5 claude-sonnet-4.6 claude-sonnet-4.5 claude-haiku-4.5
      printf '%s\n' "copilot-model: proxy not reachable — showing fallback list" >&2
    fi
  }

  local arg="${1:-}"
  case "$arg" in
    -l|--list) _copilot_model_list; return 0 ;;
    -c|--current)
      if [ -f "$settings" ] && command -v jq >/dev/null 2>&1; then
        jq -r '.env.ANTHROPIC_MODEL // "(unset)"' "$settings"
      else
        printf '%s\n' "copilot-model: no $settings (or jq missing)" >&2; return 1
      fi
      return 0 ;;
    -h|--help)
      printf '%s\n' "Usage: copilot-model [<model-id>|-l|-c]   (edits ./.claude/settings.json)"
      return 0 ;;
  esac

  if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' "copilot-model: jq is required" >&2; return 1
  fi
  if [ ! -f "$settings" ]; then
    printf '%s\n' "copilot-model: $settings not found (run from your project dir)" >&2; return 1
  fi

  local models want resolved
  models="$(_copilot_model_list 2>/dev/null)"

  # No arg + fzf available → interactive pick.
  if [ -z "$arg" ]; then
    if ! command -v fzf >/dev/null 2>&1; then
      printf '%s\n' "copilot-model: pass a model id (fzf not found). Try: copilot-model -l" >&2
      return 1
    fi
    local cur; cur="$(jq -r '.env.ANTHROPIC_MODEL // "(unset)"' "$settings")"
    want="$(printf '%s\n' "$models" | command fzf --prompt="model> " --height=40% --reverse \
      --header="current: $cur")" || { printf '%s\n' "cancelled"; return 0; }
    [ -n "$want" ] || { printf '%s\n' "cancelled"; return 0; }
    resolved="$want"
  else
    # Resolve: exact, else claude-<arg>, else unique substring.
    if printf '%s\n' "$models" | command grep -qxF "$arg"; then
      resolved="$arg"
    elif printf '%s\n' "$models" | command grep -qxF "claude-$arg"; then
      resolved="claude-$arg"
    else
      local hits count
      hits="$(printf '%s\n' "$models" | command grep -F "$arg" || true)"
      count="$(printf '%s\n' "$hits" | command grep -c . )"
      if [ "$count" = "1" ] && [ -n "$hits" ]; then
        resolved="$hits"
      else
        printf '%s\n' "copilot-model: '$arg' did not match a unique model. Try: copilot-model -l" >&2
        return 1
      fi
    fi
  fi

  local old; old="$(jq -r '.env.ANTHROPIC_MODEL // "(unset)"' "$settings")"
  if [ "$old" = "$resolved" ]; then
    printf '%s\n' "copilot-model: already using $resolved (no change)"
    return 0
  fi

  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/copilot-model.XXXXXX")" || return 1
  if jq --arg m "$resolved" \
       '.env.ANTHROPIC_MODEL = $m | .env.ANTHROPIC_DEFAULT_OPUS_MODEL = $m' \
       "$settings" >"$tmp"; then
    command mv -- "$tmp" "$settings"
    printf '%s\n' "copilot-model: $old -> $resolved"
    printf '%s\n' "  ⟳ restart Claude Code to apply (exit, then: claude -c)"
  else
    command rm -f -- "$tmp"
    printf '%s\n' "copilot-model: failed to update $settings" >&2
    return 1
  fi
}
