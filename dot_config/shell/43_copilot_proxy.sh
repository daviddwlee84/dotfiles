# 43_copilot_proxy.sh - GitHub Copilot -> Anthropic/OpenAI proxy for Claude Code
#   (shared bash + zsh).
#
# Runs the maintained copilot-api fork (caozhiyuan/copilot-api, npm
# @jeffreycao/copilot-api) so a GitHub Copilot subscription can back Claude Code
# (and any OpenAI/Anthropic-compatible client). The original ericc-ch/copilot-api
# is unmaintained (its issue #233 points at the fork) but still works via
# COPILOT_API_PKG=copilot-api@0.7.0 — flags differ per package, see
# _copilot_pkg_flavor. Both packages share the same token file, so switching
# needs no re-auth. Full guide + risks: docs/tools/copilot-claude-proxy.md.
#
# Public surface:
#   copilot-proxy [start|stop|status|restart|logs|whoami|auth]   - manage the proxy
#   copilot-run <cmd...>       - run any command with the proxy env injected
#                                (auto-starts the proxy first)
#   claude-copilot [args...]   - one-off Claude Code session on the proxy
#                                (specstory-wrapped when available; zero file writes)
#   claude-copilot-once [args...] - one-shot session via the copilot-here pin
#                                (settings.local.json; auto-reverted, even on Ctrl-C)
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
#     (gitignored) < CLI flags. GOTCHA (verified 2026-07): current Claude Code
#     lets the settings.local.json env block BEAT inherited shell env vars —
#     so copilot-run/claude-copilot cannot override a project where
#     `copilot-here on` points elsewhere (run `copilot-here off` first).
#
# Portability notes (POSIX subset, both shells source this file):
#   - runs the proxy via `bunx` (matches 07_bunx_cli.sh); pinned version avoids a
#     per-launch @latest registry round-trip. Override with COPILOT_API_PKG.
#   - no ZLE/compdef/setopt/glob-qualifiers here (bash would error on source).
#
# Env (set in ~/.shellrc.adhoc or ~/.config/{zsh/secrets.zsh,bash/secrets.sh}):
#   COPILOT_PROXY_PORT   default: 4141        - port the proxy listens on
#   COPILOT_API_PKG      default: @jeffreycao/copilot-api@1.13.14
#                                             - bunx package spec (pin/upgrade;
#                                               copilot-api@0.7.0 = old original)
#   COPILOT_PROXY_RATE   default: 15          - --rate-limit seconds; ONLY used
#                                               by the original package (the fork
#                                               has no rate limiter)
#   COPILOT_PROXY_QUIET  default: 0           - 1 = inject extra quota-saving env
#                                               (fewer background calls, but a
#                                               slightly degraded Claude Code UX)

# --- shared constants / helpers -------------------------------------------------

_copilot_port() { printf '%s' "${COPILOT_PROXY_PORT:-4141}"; }
_copilot_pkg()  { printf '%s' "${COPILOT_API_PKG:-@jeffreycao/copilot-api@1.13.14}"; }

# CLI flavor from the package spec: the ORIGINAL bare `copilot-api` takes
# --rate-limit/--wait and has `check-usage`; the fork (and anything else)
# doesn't. Strips a trailing @version, but not the @scope/ prefix.
_copilot_pkg_flavor() {
  local name; name="$(_copilot_pkg)"
  case "$name" in
    copilot-api|copilot-api@*) printf 'original' ;;
    *) printf 'fork' ;;
  esac
}
_copilot_base() { printf 'http://localhost:%s' "$(_copilot_port)"; }
_copilot_logfile() { printf '%s' "${TMPDIR:-/tmp}/copilot-api-$(_copilot_port).log"; }
_copilot_pidfile() { printf '%s' "${TMPDIR:-/tmp}/copilot-api-$(_copilot_port).pid"; }

# --- throttle shim (optional, in front of the fork) -----------------------------
# A tiny Bun reverse proxy that caps concurrent in-flight upstream requests and
# transparently retries 403/429 (GitHub enterprise abuse throttling) BEFORE any
# body streams — so downstream agents never see "Please run /login". Toggle with
# `copilot-proxy shim on|off`; tune via COPILOT_SHIM_{PORT,MAX,RETRIES,BACKOFF_MS}.
_copilot_shim_port()    { printf '%s' "${COPILOT_SHIM_PORT:-4142}"; }
_copilot_shim_base()    { printf 'http://localhost:%s' "$(_copilot_shim_port)"; }
_copilot_shim_script()  { printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/shell/copilot-throttle-shim.js"; }
_copilot_shim_logfile() { printf '%s' "${TMPDIR:-/tmp}/copilot-shim-$(_copilot_shim_port).log"; }
_copilot_shim_pidfile() { printf '%s' "${TMPDIR:-/tmp}/copilot-shim-$(_copilot_shim_port).pid"; }
_copilot_shim_state()   { printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/copilot-proxy/shim"; }

# Enabled? env COPILOT_PROXY_SHIM overrides a persisted on/off state file.
_copilot_shim_enabled() {
  case "${COPILOT_PROXY_SHIM:-}" in
    1|on|true|yes)  return 0 ;;
    0|off|false|no) return 1 ;;
  esac
  local sf; sf="$(_copilot_shim_state)"
  [ -f "$sf" ] && [ "$(command head -n1 "$sf" 2>/dev/null)" = "on" ]
}

# Is the shim port answering at all? (curl w/o -f: any HTTP reply = exit 0, so a
# 502 from a fork-down passthrough still counts as "shim process is up".)
_copilot_shim_alive() {
  command curl -s -o /dev/null --max-time 2 "$(_copilot_shim_base)/v1/models" >/dev/null 2>&1
}

# Base URL Claude Code should talk to: the shim when it's enabled AND actually
# up, otherwise the fork directly (never break just because the shim is down).
_copilot_client_base() {
  if _copilot_shim_enabled && _copilot_shim_alive; then _copilot_shim_base; else _copilot_base; fi
}

# Base URL for PERSISTENT pins (copilot-here settings.local.json): the shim when
# it's enabled (it's auto-started with the proxy, so it'll be up when in use),
# else the fork. Not gated on currently-alive since the file outlives this shell.
_copilot_pinned_base() {
  if _copilot_shim_enabled; then _copilot_shim_base; else _copilot_base; fi
}

# Start the shim (idempotent). Points it at the fork; inherits COPILOT_SHIM_*.
_copilot_shim_start() {
  if _copilot_shim_alive; then return 0; fi
  if ! command -v bun >/dev/null 2>&1; then
    printf '%s\n' "copilot-proxy: shim needs 'bun' (via mise) — skipping." >&2
    return 1
  fi
  local script; script="$(_copilot_shim_script)"
  if [ ! -f "$script" ]; then
    printf '%s\n' "copilot-proxy: shim script not found at $script" >&2
    return 1
  fi
  COPILOT_SHIM_PORT="$(_copilot_shim_port)" COPILOT_SHIM_UPSTREAM="$(_copilot_base)" \
    nohup bun "$script" >"$(_copilot_shim_logfile)" 2>&1 &
  printf '%s\n' "$!" >"$(_copilot_shim_pidfile)"
  local i=0
  while [ "$i" -lt 10 ]; do
    _copilot_shim_alive && return 0
    sleep 1; i=$((i + 1))
  done
  printf '%s\n' "copilot-proxy: shim did not come up — check $(_copilot_shim_logfile)" >&2
  return 1
}

# Stop the shim.
_copilot_shim_stop() {
  local pidf; pidf="$(_copilot_shim_pidfile)"
  if [ -f "$pidf" ]; then
    local pid; pid="$(command cat "$pidf" 2>/dev/null)"
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
    command rm -f -- "$pidf"
  fi
  command pkill -f "copilot-throttle-shim.js" 2>/dev/null
  return 0
}

# Global default-model state file (used by copilot-run/claude-copilot when the
# project has no copilot-here pin). Written by `copilot-model`.
_copilot_model_state() {
  printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/copilot-proxy/model"
}

# Resolve the model for env injection: $COPILOT_CLAUDE_MODEL > state file > default.
#
# Model-id shape matters (verified 2026-07):
#   - HYPHENATED ids (claude-opus-4-8), not dotted (claude-opus-4.8): Claude
#     Code only recognizes hyphenated family names — dotted ids fall back to
#     a legacy "[Opus 4] retired" label AND a 200k context assumption.
#   - "[1m]" suffix: Copilot serves opus-4-8 / sonnet-5 with a 1M context
#     window; the suffix makes Claude Code strip it, send the context-1m
#     beta header, and size HUD/compaction to 1M (otherwise it assumes 200k
#     and shows >100% context). Claude Code-only: raw API clients must send
#     the plain id — the proxy rejects a literal "...[1m]" model.
_copilot_default_model() {
  if [ -n "${COPILOT_CLAUDE_MODEL:-}" ]; then
    printf '%s' "$COPILOT_CLAUDE_MODEL"
  elif [ -f "$(_copilot_model_state)" ]; then
    command head -n 1 "$(_copilot_model_state)"
  else
    printf '%s' "claude-opus-4-8[1m]"
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
      # Rotate the previous session's log (keep last 3) so a restart doesn't wipe
      # it — the start commands below truncate ($logf) via `>`. logf.1 = previous
      # session, logf.2/.3 = older. Debugging a transient (e.g. 403) survives.
      if [ -f "$logf" ]; then
        command rm -f "$logf.3" 2>/dev/null
        [ -f "$logf.2" ] && command mv -f "$logf.2" "$logf.3"
        [ -f "$logf.1" ] && command mv -f "$logf.1" "$logf.2"
        command mv -f "$logf" "$logf.1"
      fi
      # Flag sets differ per package: only the original has --rate-limit/--wait
      # (the fork ships no rate limiter — mitigate with COPILOT_PROXY_QUIET=1).
      if [ "$(_copilot_pkg_flavor)" = "original" ]; then
        printf '%s\n' "copilot-proxy: starting ($pkg) on port $port (rate-limit ${COPILOT_PROXY_RATE:-15}s) ..."
        # nohup + background; detach so it survives the shell. Log to a file.
        nohup bunx "$pkg" start \
          --port "$port" \
          --rate-limit "${COPILOT_PROXY_RATE:-15}" \
          --wait \
          >"$logf" 2>&1 &
      else
        printf '%s\n' "copilot-proxy: starting ($pkg) on port $port ..."
        nohup bunx "$pkg" start \
          --port "$port" \
          >"$logf" 2>&1 &
      fi
      printf '%s\n' "$!" >"$pidf"
      # Wait up to ~20s for it to answer.
      local i=0
      while [ "$i" -lt 20 ]; do
        if _copilot_alive; then
          if _copilot_shim_enabled; then
            _copilot_shim_start && printf '%s\n' "copilot-proxy: throttle shim up → $(_copilot_shim_base) (→ $(_copilot_base))"
          fi
          printf '%s\n' "copilot-proxy: up → $(_copilot_client_base)  (logs: copilot-proxy logs)"
          return 0
        fi
        sleep 1
        i=$((i + 1))
      done
      printf '%s\n' "copilot-proxy: did not come up in time — check 'copilot-proxy logs'." >&2
      return 1
      ;;
    stop)
      # Tear down the shim first (harmless if not running).
      _copilot_shim_stop
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
        if _copilot_shim_enabled; then
          if _copilot_shim_alive; then
            printf '%s\n' "  shim:   ON, up on $(_copilot_shim_base)  → clients use this"
          else
            printf '%s\n' "  shim:   ON but DOWN (clients fall back to $(_copilot_base); try 'copilot-proxy shim on')"
          fi
        else
          printf '%s\n' "  shim:   off  (enable: copilot-proxy shim on)"
        fi
      else
        printf '%s\n' "copilot-proxy: not running on port $port  (start: copilot-proxy start)"
        return 1
      fi
      ;;
    logs)
      # logs [N] [gen]  — tail the fork log; gen 1..3 = a rotated prev session.
      # logs shim [N]    — tail the throttle shim's log instead.
      local _lf _n
      if [ "${2:-}" = "shim" ]; then
        _lf="$(_copilot_shim_logfile)"; _n="${3:-40}"
      else
        _lf="$logf"; _n="${2:-40}"
        case "${3:-}" in 1|2|3) _lf="$logf.$3" ;; esac
      fi
      if [ -f "$_lf" ]; then command tail -n "$_n" "$_lf"; else
        printf '%s\n' "copilot-proxy: no log file at $_lf" >&2; return 1; fi
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
      if [ "$(_copilot_pkg_flavor)" = "original" ]; then
        bunx "$pkg" check-usage
      elif _copilot_alive; then
        # Fork has no check-usage subcommand; its /usage endpoint serves the
        # GitHub quota payload (same data as the bundled /usage-viewer).
        if command -v jq >/dev/null 2>&1; then
          command curl -fsS --max-time 5 "$(_copilot_base)/usage" | jq '{
            plan: (.copilot_plan // .access_type_sku // "unknown"),
            quota_reset: (.quota_reset_date // null),
            quotas: ((.quota_snapshots // {}) | map_values(
              if type == "object" then
                {remaining, entitlement, percent_remaining, unlimited}
              else . end))
          }'
        else
          command curl -fsS --max-time 5 "$(_copilot_base)/usage"
        fi
      else
        # Proxy down → the fork's `debug` still validates auth state / paths.
        printf '%s\n' "copilot-proxy: not running — showing auth/debug info instead of quota." >&2
        bunx "$pkg" debug
      fi
      ;;
    shim)
      # shim [on|off|status] — persist the toggle, and start/stop it live if the
      # fork is already running.
      local sf; sf="$(_copilot_shim_state)"
      case "${2:-status}" in
        on)
          command mkdir -p "$(command dirname "$sf")"; printf 'on\n' >"$sf"
          if _copilot_alive; then
            _copilot_shim_start && printf '%s\n' "copilot-proxy: shim ON → $(_copilot_shim_base) (→ $(_copilot_base))"
          else
            printf '%s\n' "copilot-proxy: shim enabled; will start with the proxy ('copilot-proxy start')."
          fi
          printf '%s\n' "  NOTE: restart Claude Code so it picks up ANTHROPIC_BASE_URL=$(_copilot_shim_base)"
          ;;
        off)
          printf 'off\n' >"$sf"; _copilot_shim_stop
          printf '%s\n' "copilot-proxy: shim OFF (clients use $(_copilot_base) directly)"
          printf '%s\n' "  NOTE: restart Claude Code to point back at $(_copilot_base)"
          ;;
        status|*)
          if _copilot_shim_enabled; then
            printf '%s\n' "copilot-proxy: shim ON ($(_copilot_shim_alive && echo up || echo down)) on $(_copilot_shim_base)"
          else
            printf '%s\n' "copilot-proxy: shim off"
          fi
          ;;
      esac
      ;;
    -h|--help|help)
      printf '%s\n' "Usage: copilot-proxy [start|stop|restart|status|logs [shim|N [gen]]|shim [on|off|status]|whoami|auth]"
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
# GOTCHA (verified 2026-07): current Claude Code lets the settings.local.json
# env block beat inherited shell env, so this does NOT win inside a project
# where `copilot-here on` pins something else — `copilot-here off` first.
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
  # If the shim is enabled but not up (e.g. toggled on after the proxy started),
  # bring it up now so ANTHROPIC_BASE_URL below resolves to it.
  if _copilot_shim_enabled && ! _copilot_shim_alive; then _copilot_shim_start; fi
  local model; model="$(_copilot_default_model)"
  # Opt-in quota savers (COPILOT_PROXY_QUIET=1): prepended as NAME=VALUE args
  # to `env`. Off by default — they degrade the Claude Code UX a little.
  if [ "${COPILOT_PROXY_QUIET:-0}" = "1" ]; then
    set -- \
      CLAUDE_CODE_ATTRIBUTION_HEADER="0" \
      CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION="false" \
      CLAUDE_CODE_ENABLE_AWAY_SUMMARY="0" \
      DISABLE_NON_ESSENTIAL_MODEL_CALLS="1" \
      "$@"
  fi
  # `command env` (not bare var-prefix) so the vars are strictly per-process:
  # POSIX var-prefix on a *function* call would leak into the current shell.
  command env \
    ANTHROPIC_BASE_URL="$(_copilot_client_base)" \
    ANTHROPIC_AUTH_TOKEN="dummy" \
    ANTHROPIC_MODEL="$model" \
    ANTHROPIC_DEFAULT_OPUS_MODEL="$model" \
    ANTHROPIC_DEFAULT_SONNET_MODEL="claude-sonnet-5[1m]" \
    ANTHROPIC_DEFAULT_HAIKU_MODEL="claude-haiku-4-5" \
    ANTHROPIC_SMALL_FAST_MODEL="claude-haiku-4-5" \
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
# removes exactly what `on` added — including the COPILOT_PROXY_QUIET extras,
# regardless of the knob's value at `off` time).
_copilot_here_keys='["ANTHROPIC_BASE_URL","ANTHROPIC_AUTH_TOKEN","ANTHROPIC_MODEL","ANTHROPIC_DEFAULT_OPUS_MODEL","ANTHROPIC_DEFAULT_SONNET_MODEL","ANTHROPIC_DEFAULT_HAIKU_MODEL","ANTHROPIC_SMALL_FAST_MODEL","CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC","CLAUDE_CODE_ATTRIBUTION_HEADER","CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION","CLAUDE_CODE_ENABLE_AWAY_SUMMARY","DISABLE_NON_ESSENTIAL_MODEL_CALLS"]'

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
      local quiet="${COPILOT_PROXY_QUIET:-0}"
      local tmp; tmp="$(command mktemp "${TMPDIR:-/tmp}/copilot-here.XXXXXX")" || return 1
      if printf '%s' "$base" | jq \
          --arg base_url "$(_copilot_pinned_base)" --arg model "$model" --arg quiet "$quiet" '
          .env = ((.env // {}) + {
            ANTHROPIC_BASE_URL: $base_url,
            ANTHROPIC_AUTH_TOKEN: "dummy",
            ANTHROPIC_MODEL: $model,
            ANTHROPIC_DEFAULT_OPUS_MODEL: $model,
            ANTHROPIC_DEFAULT_SONNET_MODEL: "claude-sonnet-5[1m]",
            ANTHROPIC_DEFAULT_HAIKU_MODEL: "claude-haiku-4-5",
            ANTHROPIC_SMALL_FAST_MODEL: "claude-haiku-4-5",
            CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1"
          } + (if $quiet == "1" then {
            CLAUDE_CODE_ATTRIBUTION_HEADER: "0",
            CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION: "false",
            CLAUDE_CODE_ENABLE_AWAY_SUMMARY: "0",
            DISABLE_NON_ESSENTIAL_MODEL_CALLS: "1"
          } else {} end))' >"$tmp"; then
        command mv -- "$tmp" "$settings"
      else
        command rm -f -- "$tmp"
        printf '%s\n' "copilot-here: jq failed; $settings unchanged" >&2
        return 1
      fi
      # Claude Code only auto-gitignores settings.local.json when IT creates the
      # file — since we created it, belt-and-braces via .git/info/exclude (a
      # per-clone, never-committed ignore, so the proxy toggle leaves nothing to
      # commit — unlike Claude Code's own root-.gitignore entry).
      if command git rev-parse --git-dir >/dev/null 2>&1; then
        if ! command git check-ignore -q "$settings" 2>/dev/null; then
          local exclude; exclude="$(command git rev-parse --git-dir)/info/exclude"
          # MUST be the un-anchored **/ form, NOT a bare .claude/settings.local.json:
          # a pattern with an internal slash is anchored to the repo ROOT, so it
          # would not ignore the file when THIS project lives in a subdirectory of
          # a larger repo (e.g. skills/foo/.claude/…). **/ matches at any depth —
          # one idempotent line covers root + every nested project.
          printf '%s\n' "**/.claude/settings.local.json" >>"$exclude"
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

# --- one-shot pinned session (Layer 2, auto-reverted) ---------------------------

# Combine copilot-here (settings.local.json pin — beats inherited env, see Gotchas)
# with claude-copilot's ephemerality: pin THIS project, run ONE specstory-wrapped
# session, then unpin — even on Ctrl-C / kill. The proxy must already be up (we only
# notify; start it with `copilot-proxy start`). If copilot-here is already ON here,
# the existing pin is left untouched on exit (safe to run inside a pinned project).
# Example:
#   claude-copilot-once                 # pin, run, auto-unpin
#   claude-copilot-once -c              # continue last session
#   claude-copilot-once --no-specstory  # raw claude, no markdown auto-save
claude-copilot-once() {
  case "${1:-}" in
    -h|--help)
      printf '%s\n' "Usage: claude-copilot-once [--no-specstory] [claude args...]"
      printf '%s\n' "  Pin THIS project to the proxy (copilot-here on), run one Claude Code"
      printf '%s\n' "  session, then auto-unpin (copilot-here off) — even on Ctrl-C."
      printf '%s\n' "  Needs the proxy already running:  copilot-proxy start"
      return 0 ;;
  esac

  # 1. Proxy must already be answering — notify only, never auto-start.
  if ! _copilot_alive; then
    printf '%s\n' "claude-copilot-once: proxy not reachable on port $(_copilot_port)." >&2
    printf '%s\n' "  start it first:  copilot-proxy start" >&2
    return 1
  fi
  # copilot-here needs jq — fail early with a clear message.
  if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' "claude-copilot-once: jq is required (used by copilot-here)" >&2
    return 1
  fi

  # 2. Don't clobber an existing pin: only turn OFF what we turn ON.
  local _cco_was_on=0
  if [ -f ".claude/settings.local.json" ] \
     && [ "$(jq -r '.env.ANTHROPIC_BASE_URL // empty' ".claude/settings.local.json" 2>/dev/null)" != "" ]; then
    _cco_was_on=1
  fi

  if [ "$_cco_was_on" = "0" ]; then
    copilot-here on || return 1
    # Auto-unpin even on Ctrl-C / kill. Mirror tmux_status_run's INT/TERM/HUP
    # trap + explicit normal-path cleanup; a bare function-scope EXIT trap would
    # fire on the wrong event when bash sources this file.
    trap '_copilot_once_trap' INT TERM HUP
  else
    printf '%s\n' "claude-copilot-once: copilot-here already ON here — leaving the pin in place on exit."
  fi

  # 3. One session — specstory-wrapped + arg passthrough (reuses claude-copilot).
  claude-copilot "$@"
  local _rc=$?

  # 4. Revert only what we enabled.
  if [ "$_cco_was_on" = "0" ]; then
    trap - INT TERM HUP
    copilot-here off
  fi

  # 5. We never auto-stop the proxy — remind how.
  printf '%s\n' "claude-copilot-once: session ended. Proxy still running on $(_copilot_base)."
  printf '%s\n' "  stop it when done:  copilot-proxy stop"
  return $_rc
}

# Internal: INT/TERM/HUP handler — unpin, clear trap, re-raise INT so the
# interactive shell sees correct exit semantics (mirrors _tmux_status_run_trap
# in dot_config/shell/60_tmux_status.sh).
_copilot_once_trap() {
  copilot-here off >/dev/null 2>&1
  trap - INT TERM HUP
  printf '\n%s\n' "claude-copilot-once: interrupted — unpinned (copilot-here off). Proxy still up." >&2
  kill -INT $$ 2>/dev/null
}

# --- model switcher -------------------------------------------------------------

# Switch which Copilot model is pinned. Claude Code's own /model picker sends
# dated Anthropic ids the Copilot backend rejects (model_not_supported), so pin
# here. Use the HYPHENATED ids the proxy lists (claude-opus-4-8); an optional
# "[1m]" suffix tells Claude Code the model has a 1M context window (see
# _copilot_default_model) — it is stripped before validating against the proxy.
#
# Write target (never the committed .claude/settings.json):
#   - copilot-here is ON in this project → ./.claude/settings.local.json
#   - otherwise → global state file (~/.local/state/copilot-proxy/model), which
#     claude-copilot / copilot-run / the next `copilot-here on` pick up.
# Example:
#   copilot-model opus-4-8         # fuzzy → claude-opus-4-8 (opus-4.8 works too)
#   copilot-model 'opus-4-8[1m]'   # same + 1M-context hint for Claude Code
#   copilot-model -l               # list available (live from proxy)
#   copilot-model -c               # print current (+ where it came from)
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
        claude-opus-4-8 claude-opus-4-7 claude-opus-4-6 claude-opus-4-5 \
        claude-sonnet-5 claude-sonnet-4-6 claude-sonnet-4-5 claude-haiku-4-5
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
    # "[1m]" is a Claude Code-only 1M-context hint, not a real proxy id:
    # strip it for validation, re-append on the resolved id.
    local suffix="" base="$arg"
    case "$arg" in
      *"[1m]") suffix="[1m]"; base="${arg%\[1m\]}" ;;
    esac
    # Proxy ids are hyphenated (claude-opus-4-8) but muscle memory says
    # opus-4.8 — normalize dots to hyphens and accept both.
    local norm; norm="$(printf '%s' "$base" | command tr '.' '-')"
    # Resolve: exact, else claude-<arg>, else unique substring.
    local cand; resolved=""
    for cand in "$base" "claude-$base" "$norm" "claude-$norm"; do
      if printf '%s\n' "$models" | command grep -qxF "$cand"; then
        resolved="$cand"
        break
      fi
    done
    if [ -z "$resolved" ]; then
      local hits count
      hits="$(printf '%s\n' "$models" | command grep -F "$norm" || true)"
      count="$(printf '%s\n' "$hits" | command grep -c . )"
      if [ "$count" = "1" ] && [ -n "$hits" ]; then
        resolved="$hits"
      else
        printf '%s\n' "copilot-model: '$arg' did not match a unique model. Try: copilot-model -l" >&2
        return 1
      fi
    fi
    resolved="$resolved$suffix"
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
