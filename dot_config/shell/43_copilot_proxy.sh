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
#   copilot-proxy [start|stop|status|restart|doctor|logs|whoami|auth]  - manage the proxy
#   copilot-proxy doctor [--live]  - diagnose prereqs/auth/proxy/model-entitlement/
#                                upstream; --live sends one real request. The
#                                model-entitlement check catches the common
#                                "400 model_not_supported" case, where a Copilot
#                                plan serves no Anthropic models at all — that
#                                looks like a network fault in the logs but is an
#                                account-policy fact.
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
#   - the pinned package is INSTALLED ONCE into _copilot_pkg_prefix and the proxy
#     runs that binary directly. It deliberately does NOT use `bunx` at launch:
#     bunx re-resolves the package on every start, and bun stalls forever
#     resolving through a socks ALL_PROXY — which wedged `start` at "Resolving
#     dependencies" AND kept bun's global cache lock, so every retry hung too.
#     See pitfalls/copilot-proxy-start-hangs-at-resolving-dependencies.md.
#     Override the spec with COPILOT_API_PKG; force a re-install with
#     `copilot-proxy reinstall`.
#   - no ZLE/compdef/setopt/glob-qualifiers here (bash would error on source).
#
# Env (set in ~/.shellrc.adhoc or ~/.config/{zsh/secrets.zsh,bash/secrets.sh}):
#   COPILOT_PROXY_PORT   default: 4141        - port the proxy listens on
#   COPILOT_API_PKG      default: @jeffreycao/copilot-api@1.13.14
#                                             - package spec to install (pin/
#                                               upgrade; copilot-api@0.7.0 = old
#                                               original). Changing it re-installs.
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

# --- pinned package install (run the binary, never `bunx` at launch) -------------
#
# Why an install prefix instead of `bunx <pkg> start`: bunx re-resolves the
# package on EVERY launch, and bun hangs indefinitely resolving through a socks
# ALL_PROXY (curl through the same proxy is fine, which is what makes it so
# confusing). The wedged installer then keeps bun's global cache lock, so every
# retry hangs identically and stacks another zombie. Installing once and exec'ing
# the resulting binary removes the per-start resolve entirely — a warm start does
# zero network before it binds the port. Full story:
# pitfalls/copilot-proxy-start-hangs-at-resolving-dependencies.md

# Package NAME without the trailing @version, keeping any @scope/ prefix.
# The naive "${spec%@*}" eats the whole string on a scoped spec with no version
# (@jeffreycao/copilot-api -> ""), so test on the scope-stripped copy.
_copilot_pkg_name() {
  local spec base
  spec="$(_copilot_pkg)"
  base="${spec#@}"
  case "$base" in
    *@*) printf '%s' "${spec%@*}" ;;
    *)   printf '%s' "$spec" ;;
  esac
}

_copilot_pkg_prefix() { printf '%s' "${XDG_DATA_HOME:-$HOME/.local/share}/copilot-api/pkg"; }
_copilot_pkg_bin()    { printf '%s' "$(_copilot_pkg_prefix)/node_modules/.bin/copilot-api"; }
# Records the spec the prefix currently holds, so bumping COPILOT_API_PKG (or the
# pinned default) re-installs instead of silently running the old version.
_copilot_pkg_stamp()  { printf '%s' "$(_copilot_pkg_prefix)/.installed-spec"; }

# Is the CURRENTLY pinned spec installed and runnable?
_copilot_pkg_ready() {
  local bin stamp
  bin="$(_copilot_pkg_bin)"; stamp="$(_copilot_pkg_stamp)"
  [ -x "$bin" ] || return 1
  [ -f "$stamp" ] || return 1
  [ "$(command head -n 1 "$stamp" 2>/dev/null)" = "$(_copilot_pkg)" ]
}

# One `bun add` attempt in $1. $2 = "noproxy" strips the proxy env, anything else
# honours it. $3 = seconds budget, enforced by polling — `timeout(1)` is not in
# macOS base, and this file is sourced by both shells. Returns 124 on expiry.
#
# The kill on expiry is the load-bearing part: a stalled `bun add` left running
# keeps bun's global install-cache lock, and THAT is what made every subsequent
# start hang too. Never let one escape.
_copilot_pkg_install_try() {
  local dir="$1" mode="$2" budget="$3" pkg pid i=0
  pkg="$(_copilot_pkg)"
  if [ "$mode" = "noproxy" ]; then
    ( cd "$dir" 2>/dev/null && command env \
        -u ALL_PROXY -u all_proxy -u HTTP_PROXY -u http_proxy \
        -u HTTPS_PROXY -u https_proxy \
        bun add "$pkg" --no-summary >/dev/null 2>&1 ) &
  else
    ( cd "$dir" 2>/dev/null && command bun add "$pkg" --no-summary >/dev/null 2>&1 ) &
  fi
  pid=$!
  while [ "$i" -lt "$budget" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null
      return $?
    fi
    sleep 1
    i=$((i + 1))
  done
  # Braces + 2>/dev/null swallow the shell's own async "Killed" job notification:
  # we report the timeout ourselves, and a raw job-control message here reads like
  # a crash. Kill the whole process group's `bun add` too — the subshell's child
  # is the one actually holding the cache lock.
  { kill -9 "$pid" 2>/dev/null
    command pkill -9 -f "bun add.*$(_copilot_pkg_name)" 2>/dev/null
    wait "$pid" 2>/dev/null
  } 2>/dev/null
  return 124
}

# Ensure the pinned spec is installed. No-op (and no network) once it is.
_copilot_ensure_pkg() {
  local spec prefix bin
  spec="$(_copilot_pkg)"; prefix="$(_copilot_pkg_prefix)"; bin="$(_copilot_pkg_bin)"

  _copilot_pkg_ready && return 0

  if ! command -v bun >/dev/null 2>&1; then
    printf '%s\n' "copilot-proxy: bun not found (needs bun via mise)." >&2
    return 1
  fi
  command mkdir -p "$prefix" || return 1
  # A private package.json keeps `bun add` from walking up and polluting $HOME.
  [ -f "$prefix/package.json" ] || printf '%s\n' \
    '{"name":"copilot-api-runner","private":true,"version":"0.0.0"}' >"$prefix/package.json"

  printf '%s\n' "copilot-proxy: installing $spec (one-time — later starts skip this) ..."
  # Attempt 1 honours the ambient env: on a host where the npm registry is only
  # reachable THROUGH the proxy, stripping it would break the install. Attempt 2
  # strips it, which is what rescues the socks stall. COPILOT_INSTALL_NOPROXY=1
  # skips straight to attempt 2 (saves the 45s stall on a known-bad host).
  if [ "${COPILOT_INSTALL_NOPROXY:-0}" = "1" ] \
     || ! _copilot_pkg_install_try "$prefix" env 45; then
    if [ "${COPILOT_INSTALL_NOPROXY:-0}" != "1" ]; then
      printf '%s\n' "copilot-proxy: install stalled with the proxy env — retrying without it ..." >&2
      # Drop bun's cache lock dir before retrying; the killed attempt may have
      # left it behind, and a stale lock hangs the retry for the same reason.
      command rm -rf -- "${BUN_INSTALL:-$HOME/.bun}/install/cache/.tmp" 2>/dev/null
    fi
    if ! _copilot_pkg_install_try "$prefix" noproxy 90; then
      printf '%s\n' "copilot-proxy: could not install $spec — run 'copilot-proxy doctor'." >&2
      return 1
    fi
  fi

  if [ ! -x "$bin" ]; then
    printf '%s\n' "copilot-proxy: install finished but $bin is missing." >&2
    return 1
  fi
  printf '%s\n' "$spec" >"$(_copilot_pkg_stamp)"
}

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
#   - "[1m]" suffix: Copilot serves opus-5 / opus-4-8 / sonnet-5 with a 1M context
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
    printf '%s' "claude-opus-5[1m]"
  fi
}

# Is the proxy answering on its port?
_copilot_alive() {
  command curl -fsS --max-time 2 "$(_copilot_base)/v1/models" >/dev/null 2>&1
}

# --- doctor helpers -------------------------------------------------------------

# Every model id the proxy will accept: the raw `.id` PLUS the `.claude_model_id`
# alias (which is the one carrying the "[1m]" suffix Claude Code sends). Checking
# only `.id` — as _copilot_model_list does — would reject a valid "...[1m]" pin.
_copilot_served_models() {
  local json
  json="$(command curl -fsS --max-time 5 "$(_copilot_base)/v1/models" 2>/dev/null)" || return 1
  if command -v jq >/dev/null 2>&1; then
    printf '%s\n' "$json" | jq -r '.data[] | .id, (.claude_model_id // empty)' 2>/dev/null | command sort -u
  else
    printf '%s\n' "$json" \
      | command grep -oE '"(id|claude_model_id)":"[^"]*"' \
      | command sed 's/.*":"//;s/"//' | command sort -u
  fi
}

# The model Claude Code would actually send from THIS directory, and where it
# came from. Mirrors copilot-model's precedence: project pin > $COPILOT_CLAUDE_MODEL
# > state file > built-in default. Echoes "<model>|<source>" ('|' never occurs in
# a model id or a path we emit here).
_copilot_effective_model() {
  local settings=".claude/settings.local.json" m
  if [ -f "$settings" ] && command -v jq >/dev/null 2>&1 \
     && [ "$(jq -r '.env.ANTHROPIC_BASE_URL // empty' "$settings" 2>/dev/null)" != "" ]; then
    m="$(jq -r '.env.ANTHROPIC_MODEL // empty' "$settings" 2>/dev/null)"
    if [ -n "$m" ]; then printf '%s|%s' "$m" "project pin: $settings"; return 0; fi
  fi
  if [ -n "${COPILOT_CLAUDE_MODEL:-}" ]; then
    printf '%s|%s' "$COPILOT_CLAUDE_MODEL" '$COPILOT_CLAUDE_MODEL'
  elif [ -f "$(_copilot_model_state)" ]; then
    printf '%s|%s' "$(command head -n 1 "$(_copilot_model_state)")" "state file: $(_copilot_model_state)"
  else
    printf '%s|%s' "$(_copilot_default_model)" "built-in default"
  fi
}

# HTTP reachability probe. Any HTTP status means the host answered — an
# unauthenticated 400/401 from the Copilot API is a SUCCESSFUL reach. Only a
# connect/read failure is a fault. Echoes "<code>|<seconds>", empty on failure.
# $2, when non-empty, routes through that proxy (e.g. http://127.0.0.1:7891).
_copilot_probe() {
  local url="$1" via="${2:-}" out
  if [ -n "$via" ]; then
    out="$(command curl -o /dev/null -s -w '%{http_code}|%{time_total}' --max-time 12 -x "$via" "$url" 2>/dev/null)" || return 1
  else
    out="$(command curl -o /dev/null -s -w '%{http_code}|%{time_total}' --max-time 12 --noproxy '*' "$url" 2>/dev/null)" || return 1
  fi
  case "$out" in 000*) return 1 ;; esac
  printf '%s' "$out"
}

# Model ids GitHub serves for this account RIGHT NOW, bypassing the proxy.
#
# Why this exists: copilot-api fetches /models ONCE at startup and caches it for
# the whole process lifetime. A degraded startup fetch (flaky VPN/Clash node,
# transient GitHub response) leaves the proxy serving a truncated list forever,
# and every request for a missing model returns a 400 "model_not_supported" that
# looks exactly like an entitlement problem. Comparing live-upstream against
# proxy-cached is the only way to tell those two apart. Verified 2026-07.
#
# Secrets: the ghu_/bearer tokens are passed via `curl -K -` (stdin config), NOT
# argv — argv is world-readable via `ps`. Never echo either token.
_copilot_upstream_models() {
  local tokfile="$HOME/.local/share/copilot-api/github_token"
  [ -f "$tokfile" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1

  local ghu ex api ctok up
  ghu="$(command head -n 1 "$tokfile" 2>/dev/null)"
  [ -n "$ghu" ] || return 1

  ex="$(printf 'header = "Authorization: token %s"\n' "$ghu" \
        | command curl -fsS --max-time 10 -K - \
            -H 'user-agent: GitHubCopilotChat/0.26.7' \
            https://api.github.com/copilot_internal/v2/token 2>/dev/null)" || return 1

  api="$(printf '%s' "$ex" | jq -r '.endpoints.api // "https://api.githubcopilot.com"' 2>/dev/null)"
  ctok="$(printf '%s' "$ex" | jq -r '.token // empty' 2>/dev/null)"
  [ -n "$ctok" ] || return 1

  up="$(printf 'header = "Authorization: Bearer %s"\n' "$ctok" \
        | command curl -fsS --max-time 12 -K - \
            -H 'user-agent: GitHubCopilotChat/0.26.7' \
            -H 'copilot-integration-id: vscode-chat' \
            "$api/models" 2>/dev/null)" || return 1

  printf '%s' "$up" | jq -r '.data[]?.id // empty' 2>/dev/null | command sort -u
}

# Normalise a model id for cross-source comparison: lowercase, dots -> dashes
# (upstream says claude-opus-4.8, the proxy says claude-opus-4-8), drop the
# Claude Code-only "[1m]" suffix. Reads ids on stdin, one per line.
_copilot_norm_models() {
  command tr 'A-Z' 'a-z' | command sed 's/\[1m\]$//; s/\./-/g' | command sort -u
}

# macOS system HTTP proxy as "host:port", empty when disabled/not macOS.
_copilot_system_proxy() {
  command -v scutil >/dev/null 2>&1 || return 0
  command scutil --proxy 2>/dev/null | command awk '
    /HTTPEnable/ { en=$3 } /HTTPProxy/ { h=$3 } /HTTPPort/ { p=$3 }
    END { if (en == 1 && h != "" && p != "") printf "%s:%s", h, p }'
}

# PIDs of bun package-installer processes still resolving copilot-api, one per
# line (empty when none). bun stalls indefinitely resolving through a socks
# ALL_PROXY (even when curl to the same registry is fine), and a stalled
# `bun add` keeps bun's global install-cache lock — which wedges every later
# install too. _copilot_pkg_install_try now bounds and kills its own attempts, so
# this should stay empty; it remains as a safety net for a stall we didn't spawn
# (a hand-run `bunx @jeffreycao/copilot-api`, or a zombie left by the pre-install
# design that resolved on every launch). A live `bun add … copilot-api` is never
# normal at rest — install is a one-shot — so a match is a clean signal.
# Verified 2026-07: five stacked zombies from five retries, none ever bound the port.
_copilot_stale_installers() {
  command pgrep -f 'bun add.*copilot-api' 2>/dev/null
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

  if ! command -v bun >/dev/null 2>&1; then
    printf '%s\n' "copilot-proxy: bun not found (needs bun via mise)." >&2
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
      # Install the pinned package BEFORE backgrounding anything. Resolving it at
      # launch (the old `bunx <pkg> start`) is what used to hang forever behind a
      # socks proxy, with nothing but "Resolving dependencies" in the log.
      _copilot_ensure_pkg || return 1
      local bin srv_pid
      bin="$(_copilot_pkg_bin)"

      # Flag sets differ per package: only the original has --rate-limit/--wait
      # (the fork ships no rate limiter — mitigate with COPILOT_PROXY_QUIET=1).
      if [ "$(_copilot_pkg_flavor)" = "original" ]; then
        printf '%s\n' "copilot-proxy: starting ($pkg) on port $port (rate-limit ${COPILOT_PROXY_RATE:-15}s) ..."
        # nohup + background; detach so it survives the shell. Log to a file.
        nohup "$bin" start \
          --port "$port" \
          --rate-limit "${COPILOT_PROXY_RATE:-15}" \
          --wait \
          >"$logf" 2>&1 &
      else
        printf '%s\n' "copilot-proxy: starting ($pkg) on port $port ..."
        nohup "$bin" start \
          --port "$port" \
          >"$logf" 2>&1 &
      fi
      srv_pid=$!
      printf '%s\n' "$srv_pid" >"$pidf"
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
        # Crashed on its own (bad flag, port taken, auth) — don't sit out the
        # remaining seconds pretending we're still waiting.
        if ! kill -0 "$srv_pid" 2>/dev/null; then
          command rm -f -- "$pidf"
          printf '%s\n' "copilot-proxy: server exited during startup — check 'copilot-proxy logs'." >&2
          return 1
        fi
        sleep 1
        i=$((i + 1))
      done
      # Timed out. REAP what we spawned: the old code returned and left it running,
      # so each retry stacked another orphan (5 of them, in the wild) and none ever
      # bound the port.
      kill "$srv_pid" 2>/dev/null
      command rm -f -- "$pidf"
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
    doctor|test)
      # Diagnose the whole path: prereqs -> auth -> proxy -> model entitlement
      # -> upstream reachability -> (optional) a real inference round-trip.
      #
      # The model-entitlement check is the one that matters most: a Copilot plan
      # that serves no Anthropic models fails EVERY request with a 400
      # "model_not_supported", which reads like a network fault in the logs but
      # is an account-policy fact no amount of proxy tuning will fix.
      local _live=0
      case "${2:-}" in --live) _live=1 ;; esac

      # Colour only when stdout is a terminal, so `copilot-proxy doctor | tee`
      # and CI capture stay readable. printf (not $'..') keeps this sh-portable.
      local _g='' _r_='' _y='' _z=''
      if [ -t 1 ]; then
        _g="$(printf '\033[32m')"; _r_="$(printf '\033[31m')"
        _y="$(printf '\033[33m')"; _z="$(printf '\033[0m')"
      fi

      local _fail=0 _warn=0
      _ok()   { printf '  %s✓%s %-16s %s\n' "$_g" "$_z" "$1" "$2"; }
      _bad()  { printf '  %s✗%s %-16s %s\n' "$_r_" "$_z" "$1" "$2"; _fail=$((_fail+1)); }
      _note() { printf '  %s!%s %-16s %s\n' "$_y" "$_z" "$1" "$2"; _warn=$((_warn+1)); }
      _skip() { printf '  · %-16s %s\n' "$1" "$2"; }
      _hint() { printf '    %-16s → %s\n' "" "$1"; }

      printf '\ncopilot-proxy doctor   port %s   pkg %s\n\n' "$port" "$pkg"

      printf '%s\n' "Prerequisites"
      local _tool
      for _tool in bun curl jq; do
        if command -v "$_tool" >/dev/null 2>&1; then _ok "$_tool" "$(command -v "$_tool")"
        elif [ "$_tool" = jq ]; then _note "$_tool" "not found — some checks degrade to grep"
        else _bad "$_tool" "not found"; fi
      done

      printf '\n%s\n' "Package"
      # The proxy runs an INSTALLED binary, not `bunx <pkg>` — so a warm start does
      # no network at all. An un-installed prefix is not a fault: the next start
      # installs it once.
      if _copilot_pkg_ready; then
        _ok "installed" "$pkg"
        _skip "bin" "$(_copilot_pkg_bin)"
      else
        _note "not installed" "$pkg — the next 'copilot-proxy start' installs it (one-time)"
        _hint "copilot-proxy reinstall   # or force it now"
      fi

      printf '\n%s\n' "Authentication"
      local _tok="$HOME/.local/share/copilot-api/github_token"
      if [ -f "$_tok" ]; then _ok "token file" "$_tok"
      else _bad "token file" "absent"; _hint "copilot-proxy auth"; fi

      printf '\n%s\n' "Proxy"
      if _copilot_alive; then _ok "listening" "$(_copilot_base)"
      else
        _bad "listening" "nothing answering on port $port"
        _hint "copilot-proxy start"
      fi
      # A wedged package installer is the non-obvious reason a proxy never binds
      # the port (see _copilot_stale_installers): 'copilot-proxy start' just says
      # "did not come up in time" and the log shows only "Resolving dependencies".
      # Flag it hard when nothing is listening (this IS the fault), softer when
      # the proxy is up (a leftover, but still worth clearing — it holds bun's
      # cache lock and will hang the next restart).
      local _stale _stale_n
      _stale="$(_copilot_stale_installers)"
      if [ -n "$_stale" ]; then
        _stale_n="$(printf '%s\n' "$_stale" | command grep -c .)"
        if _copilot_alive; then
          _note "stale installer" "$_stale_n leftover 'bun add … copilot-api' proc(s) — harmless now, but they hold bun's cache lock (a restart will hang)"
        else
          _bad "stale installer" "$_stale_n wedged 'bun add … copilot-api' proc(s) — start is blocked at \"Resolving dependencies\", never binds port $port"
        fi
        _hint "pkill -f 'bun add.*copilot-api'; rm -rf \"\$HOME/.bun/install/cache/.tmp\"/*; copilot-proxy start"
        _hint "re-hangs? bun is stalling on the socks proxy — env -u ALL_PROXY -u HTTPS_PROXY -u HTTP_PROXY copilot-proxy start"
      else
        _skip "installer" "no wedged 'bun add' process"
      fi
      if _copilot_shim_enabled; then
        if _copilot_shim_alive; then _ok "throttle shim" "up on $(_copilot_shim_base) → clients use this"
        else _bad "throttle shim" "enabled but DOWN"; _hint "copilot-proxy shim on"; fi
      else
        _skip "throttle shim" "off"
      fi

      printf '\n%s\n' "Models"
      local _served _n _claude _model _src _pin
      if _served="$(_copilot_served_models)" && [ -n "$_served" ]; then
        _n="$(printf '%s\n' "$_served" | command grep -c .)"
        _claude="$(printf '%s\n' "$_served" | command grep -ci '^claude' || true)"
        _ok "served" "$_n model ids"
        if [ "$_claude" -gt 0 ]; then
          _ok "claude models" "$_claude ids available"
        else
          _bad "claude models" "0 of $_n — the proxy is serving no Anthropic models"
        fi

        # Live upstream vs proxy-cached. This distinguishes the two causes of a
        # 400 model_not_supported that are otherwise indistinguishable:
        #   stale cache  -> upstream HAS claude, proxy doesn't  -> restart
        #   entitlement  -> upstream lacks claude too           -> org policy
        local _up _up_claude _missing _served_norm _m
        if _up="$(_copilot_upstream_models)" && [ -n "$_up" ]; then
          _up_claude="$(printf '%s\n' "$_up" | command grep -ci '^claude' || true)"
          _ok "upstream" "$(printf '%s\n' "$_up" | command grep -c .) ids from GitHub, $_up_claude claude"
          # set-difference without process substitution (POSIX subset: this file
          # is sourced by both bash and zsh, and `<(...)` is neither's contract).
          _served_norm="$(printf '%s\n' "$_served" | _copilot_norm_models)"
          _missing="$(printf '%s\n' "$_up" | _copilot_norm_models | command grep -i '^claude' \
            | while IFS= read -r _m; do
                [ -n "$_m" ] || continue
                printf '%s\n' "$_served_norm" | command grep -qxF "$_m" || printf '%s\n' "$_m"
              done)"
          if [ -n "$_missing" ]; then
            _bad "STALE CACHE" "upstream serves claude ids the proxy does not:"
            printf '%s\n' "$_missing" | while IFS= read -r _m; do [ -n "$_m" ] && _hint "$_m"; done
            _hint "copilot-api caches /models at STARTUP — a flaky fetch poisons the session"
            _hint "copilot-proxy restart   # re-fetch the list"
          elif [ "$_up_claude" -gt 0 ] && [ "$_claude" -eq 0 ]; then
            _bad "STALE CACHE" "upstream has claude, the proxy does not"
            _hint "copilot-proxy restart"
          elif [ "$_up_claude" -eq 0 ]; then
            _note "entitlement" "GitHub itself serves no claude models for this account"
            _hint "org Copilot policy disables Anthropic — a restart will NOT help"
          else
            _ok "cache" "proxy list matches upstream (no claude ids missing)"
          fi
        else
          _skip "upstream" "could not query GitHub directly (need token + jq) — cache check skipped"
        fi

        _pin="$(_copilot_effective_model)"
        _model="${_pin%%|*}"; _src="${_pin##*|}"
        if printf '%s\n' "$_served" | command grep -qxF "$_model"; then
          _ok "pinned model" "$_model  ($_src)"
        else
          _bad "pinned model" "$_model  ($_src)"
          _hint "not in the served list → every request returns 400 model_not_supported"
          _hint "copilot-model -l   # list served ids"
        fi
      else
        _bad "served" "could not fetch $(_copilot_base)/v1/models"
      fi

      printf '\n%s\n' "Upstream (GitHub Copilot API)"
      local _sysproxy _r _code _t
      _sysproxy="$(_copilot_system_proxy)"
      for _h in api.enterprise.githubcopilot.com api.githubcopilot.com; do
        if _r="$(_copilot_probe "https://$_h/models")"; then
          _code="${_r%%|*}"; _t="${_r##*|}"
          _ok "$_h" "direct HTTP $_code in ${_t}s"
        else
          _bad "$_h" "direct — no response within 12s"
          _hint "connection blocked or upstream unreachable without a proxy"
        fi
        if [ -n "$_sysproxy" ]; then
          if _r="$(_copilot_probe "https://$_h/models" "http://$_sysproxy")"; then
            _code="${_r%%|*}"; _t="${_r##*|}"
            _ok "$_h" "via $_sysproxy HTTP $_code in ${_t}s"
          else
            _bad "$_h" "via $_sysproxy — no response within 12s"
            _hint "your system proxy cannot reach this host; bypass it or fix the rule"
          fi
        fi
      done
      _skip "" "HTTP 400/401 = reached (an unauthenticated probe is expected to be rejected)"

      printf '\n%s\n' "Network / local proxy"
      if [ -n "$_sysproxy" ]; then
        _note "system proxy" "$_sysproxy (macOS HTTP+HTTPS)"
        local _ph="${_sysproxy%%:*}" _pp="${_sysproxy##*:}"
        if command nc -z -G 2 "$_ph" "$_pp" >/dev/null 2>&1; then
          _ok "proxy port" "$_sysproxy is listening"
        else
          _bad "proxy port" "$_sysproxy is NOT listening — system proxy points at a dead port"
          _hint "start Clash/mihomo, or turn the macOS system proxy off"
        fi
      else
        _skip "system proxy" "disabled"
      fi
      if command pgrep -f -i 'clash|mihomo' >/dev/null 2>&1; then
        _note "clash/mihomo" "running — long streaming POSTs can be dropped by a flaky node"
        _hint "an ETIMEDOUT mid-request (not at connect) usually means the proxy node died"
      else
        _skip "clash/mihomo" "not running"
      fi
      if [ -n "${HTTPS_PROXY:-${https_proxy:-}}" ]; then
        _note "env proxy" "HTTPS_PROXY is set — bun/node honour this, the macOS setting alone they ignore"
      else
        _skip "env proxy" "HTTPS_PROXY unset (bun reaches upstream directly)"
      fi

      printf '\n%s\n' "Live probe"
      if [ "$_live" -ne 1 ]; then
        _skip "skipped" "pass --live to send one real request (consumes 1 quota unit)"
      elif ! _copilot_alive; then
        _skip "skipped" "proxy is not running"
      elif [ -z "${_served:-}" ]; then
        _skip "skipped" "no served model to probe with"
      else
        # Pick a chat model, never an embedding one, and never a "[1m]" alias:
        # that suffix is Claude Code-only sugar and the proxy rejects it from a
        # raw API client (see _copilot_default_model's notes).
        local _probe_model _body
        _probe_model="$(printf '%s\n' "$_served" \
          | command grep -vi 'embedding' | command grep -v '\[1m\]' | command head -n 1)"
        _body="$(printf '{"model":"%s","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' "$_probe_model")"
        # Probe the base CLIENTS use (the shim when it's up), so the live check
        # exercises the same chain Claude Code does.
        if _r="$(command curl -o /dev/null -s -w '%{http_code}|%{time_total}' --max-time 60 \
                   -X POST "$(_copilot_client_base)/v1/messages?beta=true" \
                   -H 'content-type: application/json' -d "$_body" 2>/dev/null)"; then
          _code="${_r%%|*}"; _t="${_r##*|}"
          case "$_code" in
            2*) _ok "round-trip" "$_probe_model → HTTP $_code in ${_t}s" ;;
            000) _bad "round-trip" "$_probe_model → no response (timeout/reset)"
                 _hint "this is the streaming-fault class; suspect the local proxy chain" ;;
            *)  _bad "round-trip" "$_probe_model → HTTP $_code in ${_t}s"
                _hint "copilot-proxy logs 40" ;;
          esac
        else
          _bad "round-trip" "request failed outright"
        fi
      fi

      printf '\n'
      if [ "$_fail" -gt 0 ]; then
        printf '%s\n\n' "$_fail failed, $_warn warning(s)"
        unset -f _ok _bad _note _skip _hint 2>/dev/null
        return 1
      fi
      printf '%s\n\n' "all checks passed ($_warn warning(s))"
      unset -f _ok _bad _note _skip _hint 2>/dev/null
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
      _copilot_ensure_pkg || return 1
      printf '%s\n' "copilot-proxy: launching copilot-api device login ..."
      "$(_copilot_pkg_bin)" auth
      ;;
    reinstall)
      # Force a clean re-install of the pinned spec (normally only needed if the
      # prefix got corrupted — a version bump re-installs on its own via the stamp).
      printf '%s\n' "copilot-proxy: removing $(_copilot_pkg_prefix) ..."
      command rm -rf -- "$(_copilot_pkg_prefix)"
      _copilot_ensure_pkg || return 1
      printf '%s\n' "copilot-proxy: installed $(_copilot_pkg) → $(_copilot_pkg_bin)"
      ;;
    whoami|usage)
      # Real login check: exchanges the stored token against GitHub and prints
      # the account / plan / quota. Fails loudly if the token is missing/expired.
      if [ ! -f "$HOME/.local/share/copilot-api/github_token" ]; then
        printf '%s\n' "copilot-proxy: not authenticated — run 'copilot-proxy auth' first." >&2
        return 1
      fi
      if [ "$(_copilot_pkg_flavor)" = "original" ]; then
        _copilot_ensure_pkg || return 1
        "$(_copilot_pkg_bin)" check-usage
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
        _copilot_ensure_pkg || return 1
        "$(_copilot_pkg_bin)" debug
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
      printf '%s\n' "Usage: copilot-proxy [start|stop|restart|status|doctor [--live]|logs [shim|N [gen]]|shim [on|off|status]|whoami|auth|reinstall]"
      printf '%s\n' "  doctor (alias: test)  diagnose prereqs, auth, proxy, model entitlement, upstream"
      printf '%s\n' "                        reachability. --live adds one real request (costs 1 quota unit)."
      printf '%s\n' "  reinstall             wipe + re-install the pinned package (a version bump"
      printf '%s\n' "                        re-installs on its own; this is for a corrupted prefix)."
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

# --- specstory `-c` passthrough (why the base command must come from config) ----
#
# specstory's `-c/--command` REPLACES the provider's configured command — it does
# NOT append to it. The shipped config says as much: "Use of these is equivalent
# to -c \"custom command\"" — same slot, last write wins. So a hardcoded
# `-c "claude $*"` silently drops every flag in `claude_cmd` the moment
# claude-copilot has args to pass through.
#
# Symptom that found this (verified 2026-07, specstory 2.5.0): with
# `claude_cmd = "claude --dangerously-skip-permissions"` in the specstory config,
# a bare `claude-copilot-once` took the no-`-c` branch and correctly ran in
# bypass-permissions mode, but `claude-copilot-once --resume X` took the `-c`
# branch and fell back to ~/.claude/settings.json's permissions.defaultMode
# ("auto"). Same wrapper, opposite permission mode, no warning either way.
#
# Deriving the base command from the config keeps specstory the single source of
# truth for BOTH branches: change `claude_cmd` there and both paths follow.
# `--no-specstory` deliberately does NOT inherit it (opting out of specstory
# means opting out of its config too).

# Effective `claude_cmd`, honouring specstory's own precedence:
#   project ./.specstory/cli/config.toml > user ~/.specstory/cli/config.toml
#   > bare `claude`
# Matches UNCOMMENTED assignments only — both shipped configs carry a commented
# `# claude_cmd = "claude"` example, and matching that would re-introduce the very
# bug this exists to fix. Handles TOML's double- and single-quoted strings.
_copilot_specstory_claude_cmd() {
  local f cmd=''
  for f in ".specstory/cli/config.toml" "$HOME/.specstory/cli/config.toml"; do
    [ -f "$f" ] || continue
    cmd="$(command sed -n \
      -e "s/^[[:space:]]*claude_cmd[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
      -e "s/^[[:space:]]*claude_cmd[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" \
      "$f" 2>/dev/null | command head -n 1)"
    if [ -n "$cmd" ]; then break; fi
  done
  printf '%s' "${cmd:-claude}"
}

# Single-quote ONE argument for embedding in specstory's `-c` command STRING.
# specstory shell-splits that string honouring quotes (verified: `-p 'a b'`
# arrives as a single argv entry), so quoting is both possible and necessary —
# the old `"claude $*"` flattened `claude-copilot -p "two words"` into two
# separate arguments. POSIX escape for an embedded quote: close, \', reopen.
_copilot_shquote() {
  printf "'%s'" "$(printf '%s' "${1:-}" | command sed "s/'/'\\\\''/g")"
}

# One-off Claude Code session backed by the Copilot proxy. Nothing on disk
# changes — revert is just running plain `claude` next time.
# Wraps in `specstory run` when specstory is installed (markdown auto-save,
# same convention as scode/svibe); opt out with --no-specstory. Extra args go
# to the claude CLI via specstory's -c "custom command" passthrough, appended to
# the configured `claude_cmd` (see the block above — `-c` REPLACES that command,
# so we have to rebuild it or its flags are lost).
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
      # Rebuild what `-c` clobbers: the configured base command (ITS flags left
      # unquoted so specstory splits them normally) + each of our args quoted.
      local _cc_cmd _cc_arg
      _cc_cmd="$(_copilot_specstory_claude_cmd)"
      for _cc_arg in "$@"; do
        _cc_cmd="$_cc_cmd $(_copilot_shquote "$_cc_arg")"
      done
      copilot-run specstory run claude -c "$_cc_cmd"
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
        local _drift; _drift="$(_copilot_here_drift)"
        [ -n "$_drift" ] && { printf '%s\n' "  ⚠ stale vs current defaults:"; printf '%s\n' "$_drift"; printf '%s\n' "  refresh in place: copilot-here on"; }
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
    # Already pinned here. If the pin drifted from current defaults (model bump,
    # proxy moved), offer to refresh it in place; otherwise leave it untouched.
    # Either way it was already ON, so it stays ON on exit (no revert, no trap).
    local _drift; _drift="$(_copilot_here_drift)"
    if [ -n "$_drift" ]; then
      printf '%s\n' "claude-copilot-once: this project's copilot-here pin looks stale:" >&2
      printf '%s\n' "$_drift" >&2
      if _copilot_confirm "  override with current defaults? (keep = default) [y/N]"; then
        copilot-here on || return 1
      else
        printf '%s\n' "claude-copilot-once: kept the existing pin (stays ON on exit)." >&2
      fi
    else
      printf '%s\n' "claude-copilot-once: copilot-here already ON here — leaving the pin in place on exit."
    fi
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

# --- pin staleness: detect drift + confirm-to-refresh ---------------------------

# POSIX y/N prompt. Returns 0 only on an explicit yes; a non-interactive stdin
# (no TTY) returns 1 — the safe default (keep, don't override). We only call this
# right before launching an interactive Claude Code session, so reading stdin is
# fine. NOT `read -q` (zsh-only) — this file is sourced by bash too.
_copilot_confirm() {
  local _ans
  [ -t 0 ] || return 1
  printf '%s ' "${1:-Proceed? [y/N]}" >&2
  IFS= read -r _ans || return 1
  case "$_ans" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

# Has THIS project's copilot-here pin drifted from what `copilot-here on` would
# write now (default model bumped, proxy port/shim moved)? Prints one
# "key: old -> new" line per drifted key to stdout; exit 0 = stale (drift
# printed), 1 = up-to-date or not pinned. `copilot-here on` re-merges exactly
# these keys, so refreshing a stale pin is just running it again.
_copilot_here_drift() {
  local settings=".claude/settings.local.json"
  [ -f "$settings" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  local want_base want_model cur found=1
  want_base="$(_copilot_pinned_base)"
  want_model="$(_copilot_default_model)"
  # ANTHROPIC_BASE_URL is only set while the pin is ON — absent → nothing to do.
  cur="$(jq -r '.env.ANTHROPIC_BASE_URL // empty' "$settings" 2>/dev/null)"
  [ -n "$cur" ] || return 1
  [ "$cur" = "$want_base" ]  || { printf '  base_url : %s -> %s\n' "$cur" "$want_base";  found=0; }
  cur="$(jq -r '.env.ANTHROPIC_MODEL // "(unset)"' "$settings" 2>/dev/null)"
  [ "$cur" = "$want_model" ] || { printf '  model    : %s -> %s\n' "$cur" "$want_model"; found=0; }
  cur="$(jq -r '.env.ANTHROPIC_DEFAULT_OPUS_MODEL // "(unset)"' "$settings" 2>/dev/null)"
  [ "$cur" = "$want_model" ] || { printf '  opus     : %s -> %s\n' "$cur" "$want_model"; found=0; }
  cur="$(jq -r '.env.ANTHROPIC_DEFAULT_SONNET_MODEL // "(unset)"' "$settings" 2>/dev/null)"
  [ "$cur" = "claude-sonnet-5[1m]" ] || { printf '  sonnet   : %s -> %s\n' "$cur" "claude-sonnet-5[1m]"; found=0; }
  return $found
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
#   copilot-model opus-5           # fuzzy → claude-opus-5 (the default; opus-4-8 etc. work too)
#   copilot-model 'opus-5[1m]'     # same + 1M-context hint for Claude Code
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
        claude-opus-5 claude-opus-4-8 claude-opus-4-7 claude-opus-4-6 claude-opus-4-5 \
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
