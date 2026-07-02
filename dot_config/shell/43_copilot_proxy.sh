# 43_copilot_proxy.sh - GitHub Copilot -> Anthropic/OpenAI proxy for Claude Code
#   (shared bash + zsh).
#
# Runs ericc-ch/copilot-api (a reverse-engineered proxy) so a GitHub Copilot
# subscription can back Claude Code (and any OpenAI/Anthropic-compatible client).
# Full guide + risks: docs/tools/copilot-claude-proxy.md.
#
# Public surface:
#   copilot-proxy [start|stop|status|restart|logs|whoami|auth]   - manage the proxy
#   copilot-run <cmd...>       - run any command with the proxy env injected
#                                (auto-starts the proxy first)
#   claude-copilot [args...]   - one-off Claude Code session on the proxy
#                                (specstory-wrapped when available; zero file writes)
#   copilot-here [on|off|status] - sticky per-project toggle via the gitignored
#                                ./.claude/settings.local.json (never touches the
#                                committed .claude/settings.json)
#   copilot-model [<id>|-l|-c] - switch the pinned model (edits settings.local.json
#                                when copilot-here is on, else the global state file)
#
# Settings-layer design (why settings.local.json / env vars, and NOT the
# committed .claude/settings.json nor ~/.claude/settings.json):
#   - ~/.claude/settings.json is chezmoi-managed (dot_claude/modify_settings.json)
#     and would make the proxy always-on for every project.
#   - ./.claude/settings.json is committed (claude-plans-here puts plansDirectory
#     there) — proxy config must not leak into git.
#   - Claude Code precedence (low→high): user < project < settings.local.json
#     (gitignored) < CLI flags; shell env vars beat every settings-file env block.
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

# Global default-model state file (used by copilot-run/claude-copilot when the
# project has no copilot-here pin). Written by `copilot-model`.
_copilot_model_state() {
  printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/copilot-proxy/model"
}

# Resolve the model for env injection: $COPILOT_CLAUDE_MODEL > state file > default.
_copilot_default_model() {
  if [ -n "${COPILOT_CLAUDE_MODEL:-}" ]; then
    printf '%s' "$COPILOT_CLAUDE_MODEL"
  elif [ -f "$(_copilot_model_state)" ]; then
    command head -n 1 "$(_copilot_model_state)"
  else
    printf '%s' "claude-opus-4.8"
  fi
}

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

# --- session wrapper (Layer 1: one-off, zero file writes) ------------------------

# Run any command with the copilot-proxy env injected (per-process only —
# nothing is written to disk). Auto-starts the proxy when it isn't answering.
# Shell env vars beat every settings-file env block, so this wins even inside
# a project that pins something else.
# Example:
#   copilot-run claude                      # raw Claude Code on the proxy
#   copilot-run specstory run claude        # specstory-wrapped session
copilot-run() {
  if [ "$#" -eq 0 ]; then
    printf '%s\n' "Usage: copilot-run <cmd> [args...]   (injects ANTHROPIC_* proxy env)" >&2
    return 1
  fi
  if ! _copilot_alive; then
    copilot-proxy start || return 1
  fi
  local model; model="$(_copilot_default_model)"
  # `command env` (not bare var-prefix) so the vars are strictly per-process:
  # POSIX var-prefix on a *function* call would leak into the current shell.
  command env \
    ANTHROPIC_BASE_URL="$(_copilot_base)" \
    ANTHROPIC_AUTH_TOKEN="dummy" \
    ANTHROPIC_MODEL="$model" \
    ANTHROPIC_DEFAULT_OPUS_MODEL="$model" \
    ANTHROPIC_DEFAULT_SONNET_MODEL="claude-sonnet-5" \
    ANTHROPIC_DEFAULT_HAIKU_MODEL="claude-haiku-4.5" \
    ANTHROPIC_SMALL_FAST_MODEL="claude-haiku-4.5" \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1" \
    "$@"
}

# One-off Claude Code session backed by the Copilot proxy. Nothing on disk
# changes — revert is just running plain `claude` next time.
# Wraps in `specstory run` when specstory is installed (markdown auto-save,
# same convention as scode/svibe); opt out with --no-specstory. Extra args go
# to the claude CLI (via specstory's -c "custom command" passthrough).
# Example:
#   claude-copilot                 # specstory run claude (proxy env)
#   claude-copilot -c              # continue last session
#   claude-copilot --no-specstory  # raw claude, no markdown auto-save
claude-copilot() {
  local ss="auto"
  case "${1:-}" in
    --no-specstory) ss="never"; shift ;;
    --specstory)    shift ;;
    -h|--help)
      printf '%s\n' "Usage: claude-copilot [--no-specstory] [claude args...]"
      printf '%s\n' "  One-off Claude Code session on the Copilot proxy (no file writes)."
      printf '%s\n' "  Sticky per-project instead: copilot-here on"
      return 0 ;;
  esac
  if [ "$ss" = "auto" ] && command -v specstory >/dev/null 2>&1; then
    if [ "$#" -gt 0 ]; then
      copilot-run specstory run claude -c "claude $*"
    else
      copilot-run specstory run claude
    fi
  else
    copilot-run claude "$@"
  fi
}

# --- per-project toggle (Layer 2: sticky, gitignored settings.local.json) --------

# Env keys we own in .claude/settings.local.json (kept in one place so `off`
# removes exactly what `on` added).
_copilot_here_keys='["ANTHROPIC_BASE_URL","ANTHROPIC_AUTH_TOKEN","ANTHROPIC_MODEL","ANTHROPIC_DEFAULT_OPUS_MODEL","ANTHROPIC_DEFAULT_SONNET_MODEL","ANTHROPIC_DEFAULT_HAIKU_MODEL","ANTHROPIC_SMALL_FAST_MODEL","CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"]'

# Pin THIS project to the Copilot proxy via ./.claude/settings.local.json —
# the gitignored local layer that overrides the committed .claude/settings.json
# (so claude-plans-here's plansDirectory stays untouched). Plain `claude` then
# uses the proxy here until `copilot-here off`.
# Example:
#   copilot-here on        # pin project to the proxy
#   copilot-here status    # pinned? which model?
#   copilot-here off       # unpin (removes only our env keys)
copilot-here() {
  if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' "copilot-here: jq is required" >&2; return 1
  fi

  local settings=".claude/settings.local.json"
  local action="${1:-status}"
  case "$action" in
    on)
      command mkdir -p .claude
      local base='{}'
      [ -f "$settings" ] && base="$(command cat "$settings")"
      [ -n "$base" ] || base='{}'
      local model; model="$(_copilot_default_model)"
      local tmp; tmp="$(command mktemp "${TMPDIR:-/tmp}/copilot-here.XXXXXX")" || return 1
      if printf '%s' "$base" | jq \
          --arg base_url "$(_copilot_base)" --arg model "$model" '
          .env = ((.env // {}) + {
            ANTHROPIC_BASE_URL: $base_url,
            ANTHROPIC_AUTH_TOKEN: "dummy",
            ANTHROPIC_MODEL: $model,
            ANTHROPIC_DEFAULT_OPUS_MODEL: $model,
            ANTHROPIC_DEFAULT_SONNET_MODEL: "claude-sonnet-5",
            ANTHROPIC_DEFAULT_HAIKU_MODEL: "claude-haiku-4.5",
            ANTHROPIC_SMALL_FAST_MODEL: "claude-haiku-4.5",
            CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1"
          })' >"$tmp"; then
        command mv -- "$tmp" "$settings"
      else
        command rm -f -- "$tmp"
        printf '%s\n' "copilot-here: jq failed; $settings unchanged" >&2
        return 1
      fi
      # Claude Code only auto-gitignores settings.local.json when IT creates the
      # file — since we created it, belt-and-braces via .git/info/exclude.
      if command git rev-parse --git-dir >/dev/null 2>&1; then
        if ! command git check-ignore -q "$settings" 2>/dev/null; then
          local exclude; exclude="$(command git rev-parse --git-dir)/info/exclude"
          printf '%s\n' ".claude/settings.local.json" >>"$exclude"
        fi
      fi
      printf '%s\n' "copilot-here: ON — $settings pins Claude Code to $(_copilot_base) (model: $model)"
      printf '%s\n' "  plain \`claude\` in this project now uses the proxy (restart any running session)"
      _copilot_alive || printf '%s\n' "  ⚠ proxy not running — start it with: copilot-proxy start"
      ;;
    off)
      if [ ! -f "$settings" ]; then
        printf '%s\n' "copilot-here: already off (no $settings)"
        return 0
      fi
      local tmp; tmp="$(command mktemp "${TMPDIR:-/tmp}/copilot-here.XXXXXX")" || return 1
      # Remove only OUR env keys; drop .env when it empties; keep other content.
      if jq --argjson keys "$_copilot_here_keys" '
          .env = ((.env // {}) | with_entries(select(.key as $k | ($keys | index($k)) == null)))
          | if .env == {} then del(.env) else . end' \
          "$settings" >"$tmp"; then
        if [ "$(jq -r 'if . == {} then "empty" else "kept" end' "$tmp")" = "empty" ]; then
          command rm -f -- "$tmp" "$settings"
          printf '%s\n' "copilot-here: OFF — removed $settings (it held only proxy config)"
        else
          command mv -- "$tmp" "$settings"
          printf '%s\n' "copilot-here: OFF — proxy env removed from $settings (other content kept)"
        fi
        printf '%s\n' "  plain \`claude\` is back on the real Anthropic backend (restart any running session)"
      else
        command rm -f -- "$tmp"
        printf '%s\n' "copilot-here: jq failed; $settings unchanged" >&2
        return 1
      fi
      ;;
    status)
      if [ -f "$settings" ] && [ "$(jq -r '.env.ANTHROPIC_BASE_URL // empty' "$settings" 2>/dev/null)" != "" ]; then
        printf '%s\n' "copilot-here: ON  (base: $(jq -r '.env.ANTHROPIC_BASE_URL' "$settings"), model: $(jq -r '.env.ANTHROPIC_MODEL // "(unset)"' "$settings"))"
        _copilot_alive || printf '%s\n' "  ⚠ proxy not running — start it with: copilot-proxy start"
      else
        printf '%s\n' "copilot-here: off  (enable: copilot-here on; one-off: claude-copilot)"
        return 1
      fi
      ;;
    -h|--help|help)
      printf '%s\n' "Usage: copilot-here [on|off|status]   (toggles ./.claude/settings.local.json)"
      ;;
    *)
      printf '%s\n' "copilot-here: unknown action '$action' (try --help)" >&2
      return 1
      ;;
  esac
}

# --- model switcher -------------------------------------------------------------

# Switch which Copilot model is pinned. Claude Code's own /model picker sends
# Anthropic ids the Copilot backend rejects (model_not_supported), so pin here.
#
# Write target (never the committed .claude/settings.json):
#   - copilot-here is ON in this project → ./.claude/settings.local.json
#   - otherwise → global state file (~/.local/state/copilot-proxy/model), which
#     claude-copilot / copilot-run / the next `copilot-here on` pick up.
# Example:
#   copilot-model opus-4.8       # fuzzy → claude-opus-4.8
#   copilot-model -l             # list available (live from proxy)
#   copilot-model -c             # print current (+ where it came from)
copilot-model() {
  if [ -n "$ZSH_VERSION" ]; then
    emulate -L zsh
    setopt localoptions pipefail
  else
    set -o pipefail
  fi

  local settings=".claude/settings.local.json"
  local statef; statef="$(_copilot_model_state)"

  # copilot-here mode? (local settings file carries our proxy env)
  local target="state"
  if [ -f "$settings" ] && command -v jq >/dev/null 2>&1 \
     && [ "$(jq -r '.env.ANTHROPIC_BASE_URL // empty' "$settings" 2>/dev/null)" != "" ]; then
    target="local"
  fi

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

  # Current pinned model, from whichever layer is active.
  _copilot_model_current() {
    if [ "$target" = "local" ]; then
      jq -r '.env.ANTHROPIC_MODEL // "(unset)"' "$settings"
    else
      _copilot_default_model
    fi
  }

  local arg="${1:-}"
  case "$arg" in
    -l|--list) _copilot_model_list; return 0 ;;
    -c|--current)
      if [ "$target" = "local" ]; then
        printf '%s  (project: %s)\n' "$(_copilot_model_current)" "$settings"
      else
        printf '%s  (global: %s)\n' "$(_copilot_model_current)" "$statef"
      fi
      return 0 ;;
    -h|--help)
      printf '%s\n' "Usage: copilot-model [<model-id>|-l|-c]"
      printf '%s\n' "  Writes ./.claude/settings.local.json when copilot-here is on,"
      printf '%s\n' "  else the global state file used by claude-copilot / copilot-run."
      return 0 ;;
  esac

  if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' "copilot-model: jq is required" >&2; return 1
  fi

  local models want resolved
  models="$(_copilot_model_list 2>/dev/null)"

  # No arg + fzf available → interactive pick.
  if [ -z "$arg" ]; then
    if ! command -v fzf >/dev/null 2>&1; then
      printf '%s\n' "copilot-model: pass a model id (fzf not found). Try: copilot-model -l" >&2
      return 1
    fi
    local cur; cur="$(_copilot_model_current)"
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

  local old; old="$(_copilot_model_current)"
  if [ "$old" = "$resolved" ]; then
    printf '%s\n' "copilot-model: already using $resolved (no change)"
    return 0
  fi

  if [ "$target" = "local" ]; then
    local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/copilot-model.XXXXXX")" || return 1
    if jq --arg m "$resolved" \
         '.env.ANTHROPIC_MODEL = $m | .env.ANTHROPIC_DEFAULT_OPUS_MODEL = $m' \
         "$settings" >"$tmp"; then
      command mv -- "$tmp" "$settings"
      printf '%s\n' "copilot-model: $old -> $resolved  (project: $settings)"
      printf '%s\n' "  ⟳ restart Claude Code to apply (exit, then: claude -c)"
    else
      command rm -f -- "$tmp"
      printf '%s\n' "copilot-model: failed to update $settings" >&2
      return 1
    fi
  else
    command mkdir -p "$(command dirname "$statef")"
    printf '%s\n' "$resolved" >"$statef"
    printf '%s\n' "copilot-model: $old -> $resolved  (global: $statef)"
    printf '%s\n' "  applies to the next claude-copilot / copilot-run / copilot-here on"
  fi
}
