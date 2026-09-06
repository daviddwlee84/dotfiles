# 43_copilot_proxy.sh - GitHub Copilot agent gateway for Claude Code and Codex
#   (shared bash + zsh).
#
# Runs the maintained copilot-api fork (caozhiyuan/copilot-api, npm
# @jeffreycao/copilot-api) so a GitHub Copilot subscription can back Claude Code,
# Codex, and any OpenAI/Anthropic-compatible client. The original ericc-ch/copilot-api
# is unmaintained (its issue #233 points at the fork) but still works via
# COPILOT_API_PKG=copilot-api@0.7.0 — flags differ per package, see
# _copilot_pkg_flavor. Both packages share the same token file, so switching
# needs no re-auth. Full guide + risks: docs/tools/copilot-claude-proxy.md.
#
# Public surface:
#   copilot-proxy [start|stop|status|stats|events|quota|bench|update|...] - manage/measure
#   copilot-proxy doctor [--live]  - diagnose prereqs/auth/proxy/model-entitlement/
#                                upstream; --live sends one real request. The
#                                model-entitlement check catches the common
#                                "400 model_not_supported" case, where a Copilot
#                                plan serves no Anthropic models at all — that
#                                looks like a network fault in the logs but is an
#                                account-policy fact.
#   copilot-run <cmd...>       - run any command with the proxy env injected
#                                (auto-starts the proxy first)
#   claude-copilot [--fast] [args...] - one-off Claude Code session on the proxy
#                                (specstory-wrapped when available; zero file writes)
#   claude-copilot-once [--fast] [args...] - one-shot session via the copilot-here pin
#                                (settings.local.json; auto-reverted, even on Ctrl-C)
#   codex-copilot [args...]    - one-off Codex session on the Responses gateway
#   codex-copilot-once [args...] - identical zero-persistence spelling
#   copilot-here [on|off|status] - sticky per-project toggle via the gitignored
#                                ./.claude/settings.local.json (never touches the
#                                committed .claude/settings.json)
#   copilot-model [<id>|-l|-c|--auto] - switch the pinned model (edits settings.local.json
#                                when copilot-here is on, else the global state file;
#                                --auto = Claude, else capability-ranked OpenAI,
#                                then Gemini; -c also shows the role profile)
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
#     `copilot-proxy update VERSION` persists an exact verified selection;
#     COPILOT_API_PKG remains a highest-priority temporary override. Force a
#     clean install of the selected spec with `copilot-proxy reinstall`.
#   - no ZLE/compdef/setopt/glob-qualifiers here (bash would error on source).
#
# Env (set in ~/.shellrc.adhoc or ~/.config/{zsh/secrets.zsh,bash/secrets.sh}):
#   COPILOT_PROXY_PORT   default: 4141        - port the proxy listens on
#   COPILOT_PROXY_START_TIMEOUT default: 45   - seconds allowed for the startup
#                                               model-catalog fetch
#   COPILOT_HTTP_PROXY   default: auto        - Node→GitHub /models egress:
#                          auto   = if proxy-status finds Clash/Verge/mihomo (or
#                                   macOS System Proxy), start with --proxy-env
#                                   + HTTPS_PROXY. Node ignores System Proxy;
#                                   TUN/Mixin used to hide this on GFW hosts.
#                          always = same, but warn when no local proxy is found
#                          never  = never pass --proxy-env (non-GFW machines)
#                          http://127.0.0.1:PORT = force that URL
#   COPILOT_API_PKG      default: unset       - temporary highest-priority
#                                               package override. Otherwise use
#                                               persisted selection, then built-in
#                                               @jeffreycao/copilot-api@2.3.4.
#   COPILOT_PROXY_RATE   default: 15          - --rate-limit seconds; ONLY used
#                                               by the original package (the fork
#                                               has no rate limiter)
#   COPILOT_SHIM_MIN     default: 4           - adaptive concurrency floor
#   COPILOT_SHIM_MAX     default: 8           - adaptive concurrency ceiling;
#                                               set MIN=MAX for a fixed cap
#   COPILOT_PROXY_QUIET  default: 0           - 1 = inject extra quota-saving env
#                                               (fewer background calls, but a
#                                               slightly degraded Claude Code UX)

# --- shared constants / helpers -------------------------------------------------

_copilot_port() { printf '%s' "${COPILOT_PROXY_PORT:-4141}"; }
_copilot_builtin_pkg() { printf '%s' '@jeffreycao/copilot-api@2.3.4'; }
_copilot_builtin_integrity() { printf '%s' 'sha512-yRMH3wQAH74a0K/3Gl0S3itSL7Dza/7qOGG32PXV3tKRd4feG3utpuIQf42HhnhIdcBwMz3qhmeWBPQrPxZQMQ=='; }
_copilot_pkg_selection_state() { printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/copilot-proxy/package.json"; }
_copilot_pkg() {
  if [ -n "${COPILOT_API_PKG:-}" ]; then printf '%s' "$COPILOT_API_PKG"; return; fi
  local sf; sf="$(_copilot_pkg_selection_state)"
  if [ -f "$sf" ]; then
    if command -v jq >/dev/null 2>&1; then
      local selected; selected="$(jq -r '.spec // empty' "$sf" 2>/dev/null)"
      if [ -n "$selected" ]; then printf '%s' "$selected"; return; fi
    else
      local selected; selected="$(command sed -n 's/.*"spec"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$sf" | command head -n1)"
      if [ -n "$selected" ]; then printf '%s' "$selected"; return; fi
    fi
  fi
  _copilot_builtin_pkg
}

_copilot_expected_integrity() {
  [ -n "${COPILOT_API_PKG:-}" ] && return 0
  local sf; sf="$(_copilot_pkg_selection_state)"
  if [ -f "$sf" ] && command -v jq >/dev/null 2>&1; then
    jq -r '.integrity // empty' "$sf" 2>/dev/null
  elif [ "$(_copilot_pkg)" = "$(_copilot_builtin_pkg)" ]; then
    _copilot_builtin_integrity
  fi
}

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

# One package-install attempt in $1. $2 = "noproxy" strips the proxy env,
# "npm" uses npm without proxy env (a useful fallback when Bun rejects a TUN /
# MITM certificate chain), and anything else runs Bun with the ambient env.
# $3 = seconds budget, enforced by polling — `timeout(1)` is not in macOS base,
# and this file is sourced by both shells. Returns 124 on expiry.
#
# The kill on expiry is the load-bearing part: a stalled `bun add` left running
# keeps bun's global install-cache lock, and THAT is what made every subsequent
# start hang too. Never let one escape.
_copilot_pkg_install_try() {
  local dir="$1" mode="$2" budget="$3" pkg pid i=0 log
  pkg="$(_copilot_pkg)"
  log="${TMPDIR:-/tmp}/copilot-pkg-install-$$.log"
  if [ "$mode" = "noproxy" ]; then
    ( cd "$dir" 2>/dev/null && command env \
        -u ALL_PROXY -u all_proxy -u HTTP_PROXY -u http_proxy \
        -u HTTPS_PROXY -u https_proxy \
        bun add "$pkg" --no-summary >"$log" 2>&1 ) &
  elif [ "$mode" = "npm" ]; then
    ( cd "$dir" 2>/dev/null && command env \
        -u ALL_PROXY -u all_proxy -u HTTP_PROXY -u http_proxy \
        -u HTTPS_PROXY -u https_proxy \
        npm install --no-audit --no-fund --save-exact "$pkg" >"$log" 2>&1 ) &
  else
    ( cd "$dir" 2>/dev/null && command bun add "$pkg" --no-summary >"$log" 2>&1 ) &
  fi
  pid=$!
  while [ "$i" -lt "$budget" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null
      local rc=$?
      if [ "$rc" -ne 0 ] && [ -s "$log" ]; then
        command tail -n 3 "$log" >&2
      fi
      command rm -f -- "$log"
      return "$rc"
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
    command pkill -9 -f "npm install.*$(_copilot_pkg_name)" 2>/dev/null
    wait "$pid" 2>/dev/null
  } 2>/dev/null
  command rm -f -- "$log"
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
      # Bun and Node do not always use the same CA store. A Clash/TUN node that
      # produces UNKNOWN_CERTIFICATE_VERIFICATION_ERROR in Bun can still be
      # installed safely by npm with normal TLS verification enabled.
      if command -v npm >/dev/null 2>&1; then
        printf '%s\n' "copilot-proxy: Bun install failed — retrying with npm's CA stack ..." >&2
        if ! _copilot_pkg_install_try "$prefix" npm 90; then
          printf '%s\n' "copilot-proxy: could not install $spec — run 'copilot-proxy doctor'." >&2
          return 1
        fi
      else
        printf '%s\n' "copilot-proxy: could not install $spec — run 'copilot-proxy doctor'." >&2
        return 1
      fi
    fi
  fi

  if [ ! -x "$bin" ]; then
    printf '%s\n' "copilot-proxy: install finished but $bin is missing." >&2
    return 1
  fi
  # For the built-in or persisted pin, cross-check the version that is actually
  # ON DISK against the trusted selection. Bun verifies registry integrity itself;
  # this covers the npm fallback path and a Bun-only lock.
  #
  # The `package-lock.json` entry is evidence ONLY when its `version` matches the
  # installed one. npm writes that lock and never removes it, while a later `bun
  # add` writes `bun.lock` and leaves package-lock.json untouched — so a prefix
  # that once took the npm fallback keeps a lock pinning the OLD version's
  # integrity forever. Comparing that against the new pin fails 100% of the time
  # and wedges every start with "integrity does not match the trusted pin", even
  # though the correct version is installed. Version-gate it, or don't read it.
  # See pitfalls/copilot-proxy-stale-package-lock-integrity.md
  local expected_integrity actual_integrity installed_version lock_version integrity_meta
  expected_integrity="$(_copilot_expected_integrity)"
  if [ -n "$expected_integrity" ] && command -v jq >/dev/null 2>&1; then
    installed_version="$(_copilot_pkg_actual_version 2>/dev/null || true)"
    actual_integrity=""
    if [ -f "$prefix/package-lock.json" ] && [ -n "$installed_version" ]; then
      lock_version="$(jq -r --arg p "node_modules/$(_copilot_pkg_name)" '.packages[$p].version // empty' "$prefix/package-lock.json" 2>/dev/null)"
      if [ "$lock_version" = "$installed_version" ]; then
        actual_integrity="$(jq -r --arg p "node_modules/$(_copilot_pkg_name)" '.packages[$p].integrity // empty' "$prefix/package-lock.json" 2>/dev/null)"
      fi
    fi
    if [ -n "$actual_integrity" ]; then
      if [ "$actual_integrity" != "$expected_integrity" ]; then
        printf '%s\n' "copilot-proxy: installed package integrity does not match the trusted pin." >&2
        printf '%s\n' "  on disk: $(_copilot_pkg_name)@$installed_version   pinned: $spec" >&2
        return 1
      fi
    else
      # No usable lock entry — verify the INSTALLED version against the registry.
      integrity_meta="$(_copilot_registry_metadata "${installed_version:-${spec##*@}}" 2>/dev/null || true)"
      actual_integrity="$(printf '%s' "$integrity_meta" | jq -r '.dist.integrity // empty' 2>/dev/null)"
      if [ -z "$actual_integrity" ] || [ "$actual_integrity" != "$expected_integrity" ]; then
        printf '%s\n' "copilot-proxy: could not verify the installed package against trusted npm integrity." >&2
        printf '%s\n' "  on disk: $(_copilot_pkg_name)@${installed_version:-unknown}   pinned: $spec" >&2
        return 1
      fi
    fi
  fi
  printf '%s\n' "$spec" >"$(_copilot_pkg_stamp)"
}

_copilot_pkg_actual_version() {
  local f
  f="$(_copilot_pkg_prefix)/node_modules/$(_copilot_pkg_name)/package.json"
  [ -f "$f" ] || return 1
  if command -v jq >/dev/null 2>&1; then jq -r '.version // empty' "$f" 2>/dev/null
  else command sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | command head -n1; fi
}

_copilot_registry_metadata() {
  # $1 version or "latest". Prefer canonical npm; a configured mirror is only
  # a fallback and is identified to the caller on stderr.
  local version="$1" encoded='%40jeffreycao%2Fcopilot-api' url registry
  url="https://registry.npmjs.org/$encoded/$version"
  if command curl -fsSL --max-time 20 "$url" 2>/dev/null; then return 0; fi
  registry="$(command npm config get registry 2>/dev/null | command sed 's:/*$::')"
  [ -n "$registry" ] && [ "$registry" != "https://registry.npmjs.org" ] || return 1
  printf '%s\n' "copilot-proxy: canonical npm unavailable; using configured registry $registry" >&2
  command curl -fsSL --max-time 20 "$registry/$encoded/$version"
}

_copilot_write_selection() {
  local spec="$1" integrity="$2" registry="$3" sf tmp
  sf="$(_copilot_pkg_selection_state)"; tmp="$sf.tmp.$$"
  command mkdir -p "$(command dirname "$sf")" || return 1
  jq -n --arg spec "$spec" --arg integrity "$integrity" --arg registry "$registry" \
    --arg selected_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{spec:$spec,integrity:$integrity,registry:$registry,selected_at:$selected_at}' >"$tmp" || return 1
  command mv -f "$tmp" "$sf"
}

_copilot_update_check() {
  command -v jq >/dev/null 2>&1 || { printf '%s\n' "copilot-proxy: update requires jq." >&2; return 1; }
  local meta latest selected actual
  meta="$(_copilot_registry_metadata latest)" || {
    printf '%s\n' "copilot-proxy: could not query npm metadata." >&2; return 1; }
  latest="$(printf '%s' "$meta" | jq -r '.version // empty')"
  selected="$(_copilot_pkg)"; actual="$(_copilot_pkg_actual_version 2>/dev/null || true)"
  printf '%s\n' "copilot-proxy package"
  printf '%s\n' "  built-in: $(_copilot_builtin_pkg)"
  printf '%s\n' "  selected: $selected"
  printf '%s\n' "  installed: ${actual:-not installed}"
  printf '%s\n' "  official latest: ${latest:-unknown}"
  [ "$selected" = "@jeffreycao/copilot-api@$latest" ] || \
    printf '%s\n' "  update available: copilot-proxy update $latest"
}

_copilot_update_exact() {
  local version="$1"
  if [ -n "${COPILOT_API_PKG:-}" ]; then
    printf '%s\n' "copilot-proxy: COPILOT_API_PKG is active; refusing to mutate persisted selection." >&2
    return 1
  fi
  printf '%s' "$version" | command grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$' || {
    printf '%s\n' "copilot-proxy: update requires an exact version (for example 2.3.4)." >&2; return 1; }
  for _tool in jq curl openssl bun; do command -v "$_tool" >/dev/null 2>&1 || {
    printf '%s\n' "copilot-proxy: update requires $_tool." >&2; return 1; }; done

  local meta spec integrity tarball registry prefix stage previous archive digest expected
  meta="$(_copilot_registry_metadata "$version")" || { printf '%s\n' "copilot-proxy: version $version was not found." >&2; return 1; }
  spec="@jeffreycao/copilot-api@$version"
  integrity="$(printf '%s' "$meta" | jq -r '.dist.integrity // empty')"
  tarball="$(printf '%s' "$meta" | jq -r '.dist.tarball // empty')"
  registry="$(printf '%s' "$tarball" | command sed -E 's#(https?://[^/]+).*#\1#')"
  [ -n "$integrity" ] && [ -n "$tarball" ] || { printf '%s\n' "copilot-proxy: registry metadata lacks tarball integrity." >&2; return 1; }
  case "$integrity" in sha512-*) ;; *) printf '%s\n' "copilot-proxy: unsupported integrity algorithm: $integrity" >&2; return 1 ;; esac

  prefix="$(_copilot_pkg_prefix)"; stage="$prefix.stage.$$"; previous="$prefix.previous"; archive="${TMPDIR:-/tmp}/copilot-api-$version-$$.tgz"
  command rm -rf -- "$stage"
  command mkdir -p "$stage" || return 1
  printf '%s\n' '{"name":"copilot-api-runner","private":true,"version":"0.0.0"}' >"$stage/package.json"
  printf '%s\n' "copilot-proxy: downloading and verifying $spec ..."
  if ! command curl -fsSL --max-time 60 "$tarball" -o "$archive"; then command rm -rf -- "$stage"; return 1; fi
  digest="$(command openssl dgst -sha512 -binary "$archive" | command openssl base64 -A)"
  expected="${integrity#sha512-}"
  command rm -f -- "$archive"
  if [ "$digest" != "$expected" ]; then
    command rm -rf -- "$stage"
    printf '%s\n' "copilot-proxy: SHA-512 integrity mismatch; refusing the update." >&2
    return 1
  fi

  if ! COPILOT_API_PKG="$spec" _copilot_pkg_install_try "$stage" env 90; then
    command rm -rf -- "$stage/node_modules" "$stage/bun.lock" "$stage/package-lock.json"
    if ! COPILOT_API_PKG="$spec" _copilot_pkg_install_try "$stage" noproxy 90; then
      command rm -rf -- "$stage/node_modules" "$stage/bun.lock" "$stage/package-lock.json"
      if ! command -v npm >/dev/null 2>&1 \
         || ! COPILOT_API_PKG="$spec" _copilot_pkg_install_try "$stage" npm 90; then
        command rm -rf -- "$stage"
        return 1
      fi
    fi
  fi
  [ -x "$stage/node_modules/.bin/copilot-api" ] || { command rm -rf -- "$stage"; return 1; }
  local staged_version
  staged_version="$(jq -r '.version // empty' "$stage/node_modules/@jeffreycao/copilot-api/package.json" 2>/dev/null)"
  [ "$staged_version" = "$version" ] || { command rm -rf -- "$stage"; printf '%s\n' "copilot-proxy: staged version mismatch ($staged_version)." >&2; return 1; }
  "$stage/node_modules/.bin/copilot-api" --help >/dev/null 2>&1 || { command rm -rf -- "$stage"; printf '%s\n' "copilot-proxy: staged binary failed its help smoke test." >&2; return 1; }
  printf '%s\n' "$spec" >"$stage/.installed-spec"

  local was_running sf state_backup
  was_running=0
  sf="$(_copilot_pkg_selection_state)"
  state_backup="$(_copilot_pkg_selection_state).previous"
  _copilot_alive && was_running=1
  [ "$was_running" -eq 0 ] || copilot-proxy stop || return 1
  command rm -rf -- "$previous"
  [ ! -e "$prefix" ] || command mv "$prefix" "$previous" || return 1
  command mv "$stage" "$prefix" || { [ ! -e "$previous" ] || command mv "$previous" "$prefix"; return 1; }
  command rm -f -- "$state_backup"
  [ ! -f "$sf" ] || command cp -f "$sf" "$state_backup"
  if ! _copilot_write_selection "$spec" "$integrity" "$registry"; then
    command rm -rf -- "$prefix"; [ ! -e "$previous" ] || command mv "$previous" "$prefix"; return 1
  fi

  if [ "$was_running" -eq 1 ] && ! copilot-proxy start; then
    printf '%s\n' "copilot-proxy: new version failed startup; rolling back." >&2
    copilot-proxy stop >/dev/null 2>&1 || true
    command rm -rf -- "$prefix"
    [ ! -e "$previous" ] || command mv "$previous" "$prefix"
    if [ -f "$state_backup" ]; then command mv -f "$state_backup" "$sf"; else command rm -f -- "$sf"; fi
    copilot-proxy start || printf '%s\n' "copilot-proxy: rollback restored files but the old proxy did not restart." >&2
    return 1
  fi
  printf '%s\n' "copilot-proxy: selected and installed $spec (previous generation: $previous)"
}

# --- throttle + metrics shim (default, in front of the fork) --------------------
# A tiny Bun reverse proxy that caps concurrent in-flight upstream requests,
# transparently retries 403/429/500/502/503/504 BEFORE any upstream model body
# streams — so downstream agents never see transient gateway/throttle failures — and keeps
# a streamed response alive with SSE comment frames while an OpenAI reasoning
# model thinks (copilot-api withholds headers until the first token and sends no
# `ping`, so the socket is otherwise silent for minutes and gets reaped; see
# pitfalls/copilot-proxy-openai-model-silent-stall.md). Toggle with
# `copilot-proxy shim on|off`; tune via COPILOT_SHIM_{PORT,MIN,MAX,RETRIES,
# BACKOFF_MS,PING_MS,PING_AFTER_MS,STALL_MS} — the whole COPILOT_SHIM_* env is
# inherited by the spawned process, so `export` them before `shim on`.
_copilot_shim_port()    { printf '%s' "${COPILOT_SHIM_PORT:-4142}"; }
_copilot_shim_base()    { printf 'http://localhost:%s' "$(_copilot_shim_port)"; }
_copilot_shim_script()  { printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/shell/copilot-throttle-shim.js"; }
_copilot_shim_logfile() { printf '%s' "${TMPDIR:-/tmp}/copilot-shim-$(_copilot_shim_port).log"; }
_copilot_shim_pidfile() { printf '%s' "${TMPDIR:-/tmp}/copilot-shim-$(_copilot_shim_port).pid"; }
_copilot_shim_state()   { printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/copilot-proxy/shim"; }

# Enabled by default. COPILOT_PROXY_SHIM or the persisted state can explicitly
# disable it as a break-glass direct-to-:4141 route.
_copilot_shim_enabled() {
  case "${COPILOT_PROXY_SHIM:-}" in
    1|on|true|yes)  return 0 ;;
    0|off|false|no) return 1 ;;
  esac
  local sf; sf="$(_copilot_shim_state)"
  [ ! -f "$sf" ] || [ "$(command head -n1 "$sf" 2>/dev/null)" != "off" ]
}

# Is this metrics-capable shim answering (not merely an arbitrary process or an
# older passthrough build on the same port)?
_copilot_shim_alive() {
  command curl -fsS -o /dev/null --max-time 2 "$(_copilot_shim_base)/_shim/health" >/dev/null 2>&1
}

_copilot_shim_health_json() {
  command curl -fsS --max-time 2 "$(_copilot_shim_base)/_shim/health" 2>/dev/null
}

# Live limiter control is deliberately process-local. Persistent defaults still
# come from exported COPILOT_SHIM_MIN/MAX and take effect on the next shim start.
# The custom header is required by the loopback-only admin endpoint, preventing
# a browser form or a LAN peer from changing admission control accidentally.
_copilot_limiter_request() {
  local method="${1:-GET}" body="${2:-}"
  local response code response_body error
  if [ "$method" = GET ]; then
    response="$(command curl -sS --max-time 3 -w '\n%{http_code}' "$(_copilot_shim_base)/_shim/config")" || return 1
  else
    response="$(command curl -sS --max-time 3 -X PATCH \
      -H 'content-type: application/json' \
      -H 'x-copilot-shim-admin: 1' \
      -d "$body" -w '\n%{http_code}' "$(_copilot_shim_base)/_shim/config")" || return 1
  fi
  code="$(printf '%s\n' "$response" | command tail -n 1)"
  response_body="$(printf '%s\n' "$response" | command sed '$d')"
  case "$code" in
    2*) printf '%s' "$response_body" ;;
    *)
      error="$(printf '%s' "$response_body" | jq -r '.error // empty' 2>/dev/null)"
      [ -n "$error" ] || error="running shim may predate live limiter support; restart it after active requests drain"
      printf '%s\n' "copilot-proxy: limiter request failed (HTTP $code): $error" >&2
      return 1 ;;
  esac
}

# The maintained fork currently removes Responses service_tier before sending
# to GitHub Copilot. Inspect the installed bundle rather than guessing from the
# user's Codex config; a future fork version that changes this returns unknown.
_copilot_fast_tier_state() {
  [ "$(_copilot_pkg_flavor)" = fork ] || { printf '%s' unknown; return 0; }
  local dist
  for dist in "$(_copilot_pkg_prefix)"/node_modules/"$(_copilot_pkg_name)"/dist/server-*.js; do
    [ -f "$dist" ] || continue
    if command grep -Eq 'payload\.service_tier[[:space:]]*=[[:space:]]*void 0|delete websocketPayload\.service_tier' "$dist" 2>/dev/null; then
      printf '%s' stripped
      return 0
    fi
  done
  printf '%s' unknown
}

_copilot_fast_routing_json() {
  _copilot_shim_enabled || return 1
  _copilot_shim_alive || return 1
  command curl -fsS --max-time 4 "$(_copilot_shim_base)/_shim/fast-routing" 2>/dev/null
}

_copilot_fast_model_for() {
  [ -n "${1:-}" ] || return 1
  local routing
  routing="$(_copilot_fast_routing_json)" || return 1
  printf '%s' "$routing" | jq -er --arg model "$1" '
    .mappings[$model] // (if ([.mappings[]] | index($model)) then $model else empty end)' 2>/dev/null
}

# Base URL managed clients should use. An enabled-but-down shim is a hard fault:
# launchers start it and fail rather than silently bypassing request metrics.
_copilot_client_base() {
  if _copilot_shim_enabled; then _copilot_shim_base; else _copilot_base; fi
}

_copilot_require_shim() {
  _copilot_shim_enabled || return 0
  _copilot_shim_alive || _copilot_shim_start || {
    printf '%s\n' "copilot-proxy: managed client refused to bypass the enabled metrics shim." >&2
    printf '%s\n' "  use 'copilot-proxy shim off' only for an intentional direct-mode escape." >&2
    return 1
  }
}

# Base URL for PERSISTENT pins (copilot-here settings.local.json): the shim when
# it's enabled (it's auto-started with the proxy, so it'll be up when in use),
# else the fork. Not gated on currently-alive since the file outlives this shell.
_copilot_pinned_base() {
  if _copilot_shim_enabled; then _copilot_shim_base; else _copilot_base; fi
}

# PIDs listening on $1, newest last. Empty when nothing holds the port (or when
# lsof is unavailable, in which case callers must not treat it as "port free").
_copilot_port_pids() {
  command -v lsof >/dev/null 2>&1 || return 1
  command lsof -nP -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null
}

# Start the shim (idempotent). Points it at the fork; inherits COPILOT_SHIM_*.
#
# The reclaim step is load-bearing. `_copilot_shim_alive` probes /_shim/health,
# which an OLDER passthrough build of this script does not serve — it forwards
# the path upstream, so :4141 answers 404 and the probe reports "not alive".
# Without the reclaim we then spawn a doomed process that dies instantly with
# EADDRINUSE, and every managed launcher fails closed against a shim that is in
# fact running. Symptom: "shim did not come up" plus a wall of
# `GET /_shim/health 404` in the PROXY's log.
# See pitfalls/copilot-proxy-shim-eaddrinuse-stale-build.md
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
  # Port occupied but not answering /_shim/health: reclaim it when it is one of
  # our own shims (stale or old-build), otherwise name the squatter and bail —
  # killing an unrelated process on a well-known port is not ours to do.
  local port pids pid squatters=""
  port="$(_copilot_shim_port)"
  if pids="$(_copilot_port_pids "$port")" && [ -n "$pids" ]; then
    for pid in $pids; do
      if command ps -o command= -p "$pid" 2>/dev/null | command grep -q 'copilot-throttle-shim\.js'; then
        kill "$pid" 2>/dev/null
      else
        squatters="$squatters $pid($(command ps -o comm= -p "$pid" 2>/dev/null))"
      fi
    done
    if [ -n "$squatters" ]; then
      printf '%s\n' "copilot-proxy: port $port is held by another process:$squatters" >&2
      printf '%s\n' "  free it, or pick a different port with COPILOT_SHIM_PORT." >&2
      return 1
    fi
    # Give the reclaimed listener a moment to release the socket.
    local w=0
    while [ "$w" -lt 5 ]; do
      pids="$(_copilot_port_pids "$port" || true)"
      [ -z "$pids" ] && break
      sleep 1; w=$((w + 1))
    done
  fi
  COPILOT_SHIM_PORT="$port" COPILOT_SHIM_UPSTREAM="$(_copilot_base)" \
    nohup bun "$script" >"$(_copilot_shim_logfile)" 2>&1 &
  printf '%s\n' "$!" >"$(_copilot_shim_pidfile)"
  local i=0
  while [ "$i" -lt 10 ]; do
    _copilot_shim_alive && return 0
    sleep 1; i=$((i + 1))
  done
  printf '%s\n' "copilot-proxy: shim did not come up — check $(_copilot_shim_logfile)" >&2
  [ -s "$(_copilot_shim_logfile)" ] && command tail -n 5 "$(_copilot_shim_logfile)" >&2
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

_copilot_metrics_cli() {
  local script; script="$(_copilot_shim_script)"
  if [ ! -f "$script" ]; then
    printf '%s\n' "copilot-proxy: metrics script not found at $script" >&2
    return 1
  fi
  command bun "$script" "$@"
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
#   - "[1m]" suffix: Claude Code uses it to size HUD/compaction for a 1M context
#     window. _copilot_model_for_claude derives it from live /v1/models metadata
#     for every provider, rather than guessing from a hard-coded Claude list.
#     Claude Code-only: raw API clients must send the plain id.
_copilot_default_model() {
  if [ -n "${COPILOT_CLAUDE_MODEL:-}" ]; then
    printf '%s' "$COPILOT_CLAUDE_MODEL"
  elif [ -f "$(_copilot_model_state)" ]; then
    command head -n 1 "$(_copilot_model_state)"
  else
    # Backward-compatible offline fallback. This is NOT an entitlement claim:
    # both Sol and Astra are currently restricted in the live Copilot catalog;
    # use `copilot-model --auto` whenever the catalog is reachable.
    printf '%s' "gpt-5.6-sol[1m]"
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

# Classify curl failures without treating an HTTP rejection as a transport
# failure. Kept separate so the optional codex_apps route can explain timeout,
# certificate and generic network failures without conflating them with the
# localhost model gateway.
_copilot_probe_failure_kind() {
  local rc="${1:-1}" msg
  msg="$(printf '%s' "${2:-}" | command tr 'A-Z' 'a-z')"
  case "$rc" in
    28) printf '%s' timeout; return 0 ;;
    35|51|53|58|59|60|64|66|77|80|82|83|90|91) printf '%s' tls; return 0 ;;
  esac
  case "$msg" in
    *timed\ out*|*timeout*) printf '%s' timeout ;;
    *certificate*|*ssl*|*tls*) printf '%s' tls ;;
    *) printf '%s' network ;;
  esac
}

# Probe an optional HTTP endpoint and always emit a structured result:
#   reached|HTTP_CODE|SECONDS|
#   failed|timeout|SECONDS|short curl error
#   failed|tls|SECONDS|short curl error
#   failed|network|SECONDS|short curl error
# Any non-000 HTTP status is reachability success; auth/handshake rejection is
# expected for the unauthenticated codex_apps endpoint probe.
_copilot_optional_http_probe() {
  local url="$1" via="${2:-}" out rc metrics code elapsed err kind
  if [ -n "$via" ]; then
    out="$(command curl -o /dev/null -sS -w '\n%{http_code}|%{time_total}' \
      --max-time 12 -x "$via" "$url" 2>&1)"; rc=$?
  else
    out="$(command curl -o /dev/null -sS -w '\n%{http_code}|%{time_total}' \
      --max-time 12 --noproxy '*' "$url" 2>&1)"; rc=$?
  fi
  metrics="$(printf '%s\n' "$out" | command tail -n 1)"
  code="${metrics%%|*}"; elapsed="${metrics##*|}"
  if [ "$rc" -eq 0 ] && [ -n "$code" ] && [ "$code" != 000 ]; then
    printf 'reached|%s|%s|' "$code" "$elapsed"
    return 0
  fi
  err="$(printf '%s\n' "$out" | command sed '$d' | command tr '\n|' ' /' | command cut -c1-120)"
  kind="$(_copilot_probe_failure_kind "$rc" "$err")"
  printf 'failed|%s|%s|%s' "$kind" "${elapsed:-0}" "$err"
}

# Model ids GitHub serves for this account RIGHT NOW.
#
# Why this exists: copilot-api fetches /models ONCE at startup and caches it for
# the whole process lifetime. A degraded OR geo-filtered startup fetch leaves
# the proxy serving a truncated list forever, and every request for a missing
# model returns a 400 "model_not_supported" that looks exactly like an
# entitlement problem. Comparing live-upstream against proxy-cached is the only
# way to tell those apart. Verified 2026-07.
#
# $1 selects the egress path for the curl probe (curl follows the macOS system
# proxy by default — which is exactly what made the old doctor mis-diagnose
# "entitlement" when System Proxy was ON but Node was going direct):
#   (empty)           — curl defaults (may use System Proxy on macOS)
#   direct            — --noproxy '*' (true direct egress)
#   http://host:port  — force -x that proxy
#
# Secrets: the ghu_/bearer tokens are passed via `curl -K -` (stdin config), NOT
# argv — argv is world-readable via `ps`. Never echo either token.
_copilot_upstream_models() {
  local via="${1:-}"
  local tokfile="$HOME/.local/share/copilot-api/github_token"
  [ -f "$tokfile" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1

  local ghu ex api ctok up
  ghu="$(command head -n 1 "$tokfile" 2>/dev/null)"
  [ -n "$ghu" ] || return 1

  # Transport: keep as one argv word so zsh doesn't glob `*`.
  local xargs=()
  case "$via" in
    "") ;;
    direct) xargs=(--noproxy '*') ;;
    http://*|https://*|socks5://*|socks5h://*) xargs=(-x "$via") ;;
    *) return 1 ;;
  esac

  # bash arrays work when this file is sourced from bash; zsh too. Avoid
  # unquoted $* expansion of `--noproxy *`.
  ex="$(printf 'header = "Authorization: token %s"\n' "$ghu" \
        | command curl -fsS --max-time 10 -K - \
            -H 'user-agent: GitHubCopilotChat/0.26.7' \
            "${xargs[@]}" \
            https://api.github.com/copilot_internal/v2/token 2>/dev/null)" || return 1

  api="$(printf '%s' "$ex" | jq -r '.endpoints.api // "https://api.githubcopilot.com"' 2>/dev/null)"
  ctok="$(printf '%s' "$ex" | jq -r '.token // empty' 2>/dev/null)"
  [ -n "$ctok" ] || return 1

  up="$(printf 'header = "Authorization: Bearer %s"\n' "$ctok" \
        | command curl -fsS --max-time 12 -K - \
            -H 'user-agent: GitHubCopilotChat/0.26.7' \
            -H 'copilot-integration-id: vscode-chat' \
            "${xargs[@]}" \
            "$api/models" 2>/dev/null)" || return 1

  printf '%s' "$up" | jq -r '.data[]?.id // empty' 2>/dev/null | command sort -u
}

# Resolve the HTTP(S) proxy URL that Node should use for GitHub /models.
# Prints a URL or nothing. Never prints secrets. Relies on 50_networking.sh
# helpers when available; falls back to macOS System Proxy / common ports.
#
# COPILOT_HTTP_PROXY:
#   auto|always|never|<url>
_copilot_resolve_http_proxy() {
  local mode="${COPILOT_HTTP_PROXY:-auto}"
  case "$mode" in
    never|off|0|false|no) return 0 ;;
    http://*|https://*|socks5://*|socks5h://*)
      printf '%s' "$mode"
      return 0
      ;;
    always|auto|on|1|true|yes|"") ;;
    *)
      printf '%s\n' "copilot-proxy: unknown COPILOT_HTTP_PROXY='$mode' (use auto|always|never|http://...)" >&2
      return 0
      ;;
  esac

  # Prefer the shared detector (Clash Verge / mihomo / CFW / System Proxy).
  if command -v __net_detect_proxy >/dev/null 2>&1; then
    if __net_detect_proxy 2>/dev/null \
       && [ -n "${_NET_PROXY_CACHE:-}" ] \
       && [ "$_NET_PROXY_CACHE" != "none" ]; then
      printf '%s' "$_NET_PROXY_CACHE"
      return 0
    fi
  fi

  # Fallback when 50_networking.sh isn't sourced yet (rare; file order is 43→50).
  local sys
  sys="$(_copilot_system_proxy)"
  if [ -n "$sys" ]; then
    printf '%s' "http://$sys"
    return 0
  fi
  return 0
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

# Manage the copilot-api proxy. Subcommands include start/stop/status/restart,
# logs, limiter, metrics, auth, update and diagnostics.
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
        _copilot_require_shim || return 1
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
      local bin srv_pid http_proxy_url use_proxy_env=0
      bin="$(_copilot_pkg_bin)"
      http_proxy_url="$(_copilot_resolve_http_proxy)"
      if [ -n "$http_proxy_url" ]; then
        use_proxy_env=1
        printf '%s\n' "copilot-proxy: Node will fetch /models via $http_proxy_url (--proxy-env; COPILOT_HTTP_PROXY=${COPILOT_HTTP_PROXY:-auto})"
      else
        case "${COPILOT_HTTP_PROXY:-auto}" in
          always|on|1|true|yes)
            printf '%s\n' "copilot-proxy: COPILOT_HTTP_PROXY=always but no local proxy detected — starting DIRECT (Claude catalog may be geo-filtered)." >&2
            printf '%s\n' "  hint: start Clash Verge / mihomo, or set COPILOT_HTTP_PROXY=http://127.0.0.1:7897" >&2
            ;;
        esac
      fi

      # Flag sets differ per package: only the original has --rate-limit/--wait
      # (the fork ships no rate limiter — mitigate with COPILOT_PROXY_QUIET=1).
      # --proxy-env makes Node honour HTTPS_PROXY (macOS System Proxy alone is ignored).
      if [ "$(_copilot_pkg_flavor)" = "original" ]; then
        printf '%s\n' "copilot-proxy: starting ($pkg) on port $port (rate-limit ${COPILOT_PROXY_RATE:-15}s) ..."
        # Original package: HTTPS_PROXY alone is enough (no --proxy-env flag).
        if [ "$use_proxy_env" -eq 1 ]; then
          nohup env HTTP_PROXY="$http_proxy_url" HTTPS_PROXY="$http_proxy_url" \
            http_proxy="$http_proxy_url" https_proxy="$http_proxy_url" \
            "$bin" start \
            --port "$port" \
            --rate-limit "${COPILOT_PROXY_RATE:-15}" \
            --wait \
            >"$logf" 2>&1 &
        else
          nohup "$bin" start \
            --port "$port" \
            --rate-limit "${COPILOT_PROXY_RATE:-15}" \
            --wait \
            >"$logf" 2>&1 &
        fi
      else
        printf '%s\n' "copilot-proxy: starting ($pkg) on port $port ..."
        # Fork: needs --proxy-env so Node fetch honours HTTPS_PROXY.
        if [ "$use_proxy_env" -eq 1 ]; then
          nohup env HTTP_PROXY="$http_proxy_url" HTTPS_PROXY="$http_proxy_url" \
            http_proxy="$http_proxy_url" https_proxy="$http_proxy_url" \
            "$bin" start \
            --port "$port" \
            --proxy-env \
            >"$logf" 2>&1 &
        else
          nohup "$bin" start \
            --port "$port" \
            >"$logf" 2>&1 &
        fi
      fi
      srv_pid=$!
      printf '%s\n' "$srv_pid" >"$pidf"
      # Catalog startup can exceed 20s on a slow Clash/TUN hop even though the
      # process is healthy. Keep checking the child so true crashes still fail
      # immediately; only the network-bound model refresh gets a wider budget.
      local i=0 start_timeout="${COPILOT_PROXY_START_TIMEOUT:-45}"
      while [ "$i" -lt "$start_timeout" ]; do
        if _copilot_alive; then
          if _copilot_shim_enabled; then
            if ! _copilot_shim_start; then
              kill "$srv_pid" 2>/dev/null
              command rm -f -- "$pidf"
              printf '%s\n' "copilot-proxy: fork started, but the required metrics shim failed; stopped the fork." >&2
              return 1
            fi
            printf '%s\n' "copilot-proxy: throttle/metrics shim up → $(_copilot_shim_base) (→ $(_copilot_base))"
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
        local status_json status_count status_claude _shim_health _shim_detail _fast_state _fast_count
        status_json="$(command curl -fsS --max-time 3 "$(_copilot_base)/v1/models" 2>/dev/null || true)"
        status_count="$(printf '%s' "$status_json" | jq -r '.data | length' 2>/dev/null || printf '?')"
        status_claude="$(printf '%s' "$status_json" | jq -r '[.data[]?.id | select(startswith("claude-"))] | join(" ")' 2>/dev/null)"
        [ -n "$status_claude" ] || status_claude='none'
        printf '%s\n' "copilot-proxy: RUNNING on $(_copilot_base)"
        printf '%s\n' "  models: $status_count served; Claude: $status_claude"
        if _copilot_shim_enabled; then
          if _copilot_shim_alive; then
            _shim_health="$(_copilot_shim_health_json || true)"
            _shim_detail="$(printf '%s' "$_shim_health" | jq -r '
              if (.limit // null) == null then ""
              else " (active \(.active)/\(.limit), queued \(.queued), range \(.min)..\(.max))" end' 2>/dev/null)"
            printf '%s\n' "  shim:   ON, up on $(_copilot_shim_base)${_shim_detail}  → clients use this"
            _fast_state="$(printf '%s' "$_shim_health" | jq -r '.fast_routing.state // "old-shim"' 2>/dev/null)"
            _fast_count="$(printf '%s' "$_shim_health" | jq -r '.fast_routing.mappings // 0' 2>/dev/null)"
            printf '%s\n' "  fast:   $_fast_state ($_fast_count mapping(s); details: copilot-proxy doctor)"
          else
            printf '%s\n' "  shim:   ON but DOWN (managed clients fail closed; try 'copilot-proxy shim on')"
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
        local _actual_version _expected_integrity
        _actual_version="$(_copilot_pkg_actual_version 2>/dev/null || true)"
        _expected_integrity="$(_copilot_expected_integrity 2>/dev/null || true)"
        _skip "built-in" "$(_copilot_builtin_pkg)"
        _skip "actual" "${_actual_version:-unknown}"
        [ -z "$_expected_integrity" ] || _skip "integrity" "$_expected_integrity"
        if [ -f "$(_copilot_pkg_prefix)/bun.lock" ] && command grep -q '@jeffreycao/copilot-api@1\.' "$(_copilot_pkg_prefix)/bun.lock" 2>/dev/null; then
          _note "lock drift" "bun.lock mentions an older package; installed package + stamp remain authoritative"
        fi
      else
        _note "not installed" "$pkg — the next 'copilot-proxy start' installs it (one-time)"
        _hint "copilot-proxy reinstall   # or force it now"
      fi
      _skip "updates" "copilot-proxy update --check (never auto-installs latest)"

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
        if _copilot_shim_alive; then
          local _health _health_detail
          _health="$(_copilot_shim_health_json || true)"
          _health_detail="$(printf '%s' "$_health" | jq -r '
            if (.limit // null) == null then ""
            else "active \(.active)/\(.limit), queued \(.queued), range \(.min)..\(.max)" end' 2>/dev/null)"
          _ok "throttle shim" "up on $(_copilot_shim_base)${_health_detail:+ — $_health_detail}"
        else _bad "throttle shim" "enabled but DOWN"; _hint "copilot-proxy shim on"; fi
      else
        _skip "throttle shim" "off"
      fi

      printf '\n%s\n' "Models"
      local _served _n _claude _model _src _pin _profile _profile_catalog
      local _role_rows _role _role_model _role_bad
      local _http_proxy _up_direct _up_via _dir_n _dir_c _via_n _via_c
      local _fast_json _fast_state _fast_routes
      _http_proxy="$(_copilot_resolve_http_proxy)"
      if [ -n "$_http_proxy" ]; then
        _note "http proxy" "$_http_proxy (COPILOT_HTTP_PROXY=${COPILOT_HTTP_PROXY:-auto}) — Node needs --proxy-env to use this"
      else
        _skip "http proxy" "none detected (COPILOT_HTTP_PROXY=${COPILOT_HTTP_PROXY:-auto})"
      fi

      if _served="$(_copilot_served_models)" && [ -n "$_served" ]; then
        _n="$(printf '%s\n' "$_served" | command grep -c .)"
        _claude="$(printf '%s\n' "$_served" | command grep -ci '^claude' || true)"
        _ok "served" "$_n model ids"
        if [ "$_claude" -gt 0 ]; then
          _ok "claude models" "$_claude ids available"
        else
          _note "claude models" "0 of $_n — Anthropic unavailable; role-aware OpenAI fallback will be used"
        fi

        # A/B: true-direct vs via local Clash/Verge. GitHub geo-filters the
        # Claude catalog on CN egress; curl's default path follows System Proxy
        # so a single "upstream" probe used to mis-label that as entitlement.
        _dir_c=0; _via_c=0
        if _up_direct="$(_copilot_upstream_models direct)" && [ -n "$_up_direct" ]; then
          _dir_n="$(printf '%s\n' "$_up_direct" | command grep -c .)"
          _dir_c="$(printf '%s\n' "$_up_direct" | command grep -ci '^claude' || true)"
          _ok "upstream direct" "$_dir_n ids, $_dir_c claude (--noproxy)"
        else
          _skip "upstream direct" "could not query GitHub direct (need token + jq, or blocked)"
        fi
        if [ -n "$_http_proxy" ]; then
          if _up_via="$(_copilot_upstream_models "$_http_proxy")" && [ -n "$_up_via" ]; then
            _via_n="$(printf '%s\n' "$_up_via" | command grep -c .)"
            _via_c="$(printf '%s\n' "$_up_via" | command grep -ci '^claude' || true)"
            _ok "upstream via proxy" "$_via_n ids, $_via_c claude ($_http_proxy)"
          else
            _bad "upstream via proxy" "no response through $_http_proxy"
            _hint "Clash/mihomo node may be down — try another PROXY selection"
          fi
        fi

        if [ "$_via_c" -gt 0 ] && [ "$_dir_c" -eq 0 ]; then
          _note "egress geo" "Claude appears ONLY via local proxy — GitHub filters Anthropic on direct/CN egress"
          if [ "$_claude" -eq 0 ]; then
            _bad "MISSING --proxy-env" "copilot-api started without HTTPS_PROXY, so it cached the direct (no-Claude) catalog"
            _hint "copilot-proxy restart   # auto uses --proxy-env when a local proxy is detected"
            _hint "or: COPILOT_HTTP_PROXY=http://127.0.0.1:7897 copilot-proxy restart"
          fi
        elif [ "$_via_c" -eq 0 ] && [ "$_dir_c" -eq 0 ] && [ -n "${_up_direct}${_up_via}" ]; then
          _note "entitlement" "neither direct nor via-proxy catalogs include Claude"
          _hint "org Copilot policy may disable Anthropic — a restart will NOT help"
        elif [ "$_claude" -eq 0 ] && [ "$_via_c" -gt 0 ]; then
          _bad "STALE CACHE" "via-proxy upstream has Claude but the running process does not"
          _hint "copilot-proxy restart"
        elif [ "$_claude" -gt 0 ]; then
          _ok "cache" "served Claude list looks healthy"
        fi

        _pin="$(_copilot_effective_model)"
        _model="${_pin%%|*}"; _src="${_pin##*|}"
        if printf '%s\n' "$_served" | command grep -qxF "$_model"; then
          _ok "pinned model" "$_model  ($_src)"
        else
          _bad "pinned model" "$_model  ($_src)"
          _hint "not in the served list → every request returns 400 model_not_supported"
          _hint "copilot-model --auto   # Claude; else capability-ranked OpenAI, then Gemini"
          _hint "copilot-model -l       # list served ids"
        fi

        # Validate the aliases Claude Code may use for background/subagent work,
        # not just ANTHROPIC_MODEL. One stale Sonnet/Haiku id is enough to make
        # selected features fail with 400 while ordinary chat still succeeds.
        if [ -f ".claude/settings.local.json" ] \
           && [ -n "$(jq -r '.env.ANTHROPIC_BASE_URL // empty' ".claude/settings.local.json" 2>/dev/null)" ]; then
          _profile="$(jq '{
            main: (.env.ANTHROPIC_MODEL // ""),
            fable: (.env.ANTHROPIC_DEFAULT_FABLE_MODEL // ""),
            opus: (.env.ANTHROPIC_DEFAULT_OPUS_MODEL // ""),
            sonnet: (.env.ANTHROPIC_DEFAULT_SONNET_MODEL // ""),
            haiku: (.env.ANTHROPIC_DEFAULT_HAIKU_MODEL // "")
          }' ".claude/settings.local.json" 2>/dev/null)"
        else
          _profile_catalog="$(_copilot_model_catalog 2>/dev/null || true)"
          _profile="$(_copilot_model_profile_json "$_model" "$_profile_catalog" 2>/dev/null || true)"
        fi
        _role_bad=''
        if [ -n "$_profile" ]; then
          _role_rows="$(printf '%s' "$_profile" | jq -r '
            ["fable",.fable], ["opus",.opus], ["sonnet",.sonnet], ["haiku",.haiku]
            | @tsv' 2>/dev/null)"
          while IFS="$(printf '\t')" read -r _role _role_model; do
            [ -n "$_role" ] || continue
            if [ -z "$_role_model" ]; then
              _bad "role $_role" "unset — Claude Code may choose its native default and get model_not_supported"
              _role_bad=1
            elif ! printf '%s\n' "$_served" | command grep -qxF "$_role_model"; then
              _bad "role $_role" "$_role_model is not served"
              _role_bad=1
            fi
          done <<EOF
$_role_rows
EOF
          if [ -z "$_role_bad" ]; then
            _ok "model roles" "$(printf '%s' "$_profile" | jq -r '"fable=\(.fable), opus=\(.opus), sonnet=\(.sonnet), haiku=\(.haiku)"')"
          else
            _hint "copilot-model --auto   # rewrite main + every Claude Code role alias"
          fi
        else
          _bad "model roles" "could not compute the effective role profile"
        fi
        if _copilot_shim_enabled; then
          if _copilot_shim_alive && _fast_json="$(_copilot_fast_routing_json)"; then
            _fast_state="$(printf '%s' "$_fast_json" | jq -r '.state // "unknown"')"
            _fast_routes="$(printf '%s' "$_fast_json" | jq -r '
              [.mappings | to_entries[]? | select(.key | endswith("[1m]") | not)
               | "\(.key)->\(.value)"] | join(", ")')"
            case "$_fast_state" in
              ready|stale)
                _ok "fast routing" "$_fast_state${_fast_routes:+ — $_fast_routes}"
                _hint "Codex /fast is translated before the fork strips service_tier; Claude uses: claude-copilot --fast"
                ;;
              unavailable)
                _note "fast routing" "live catalog has no eligible -fast sibling; fast requests fall back to the standard model"
                ;;
              *)
                _note "fast routing" "$_fast_state — fast requests fall back to the standard model"
                _hint "inspect: copilot-proxy logs shim 40"
                ;;
            esac
          else
            _bad "fast routing" "shim is running an old build or its routing endpoint is unavailable"
            _hint "restart after applying these dotfiles: copilot-proxy restart"
          fi
        else
          _note "fast routing" "shim is off; the fork strips Codex service_tier and no model translation occurs"
          _hint "copilot-proxy shim on"
        fi
        case "$(_copilot_fast_tier_state)" in
          stripped) _skip "fork tier" "service_tier stripping detected (expected; the shim translates it first)" ;;
          *) _skip "fork tier" "could not prove whether this installed package forwards service_tier" ;;
        esac
      else
        _bad "served" "could not fetch $(_copilot_base)/v1/models"
        # Still run the A/B so a stopped proxy doesn't hide the geo diagnosis.
        if _up_direct="$(_copilot_upstream_models direct)" && [ -n "$_up_direct" ]; then
          _dir_c="$(printf '%s\n' "$_up_direct" | command grep -ci '^claude' || true)"
          _ok "upstream direct" "$(printf '%s\n' "$_up_direct" | command grep -c .) ids, $_dir_c claude"
        fi
        if [ -n "$_http_proxy" ] && _up_via="$(_copilot_upstream_models "$_http_proxy")" && [ -n "$_up_via" ]; then
          _via_c="$(printf '%s\n' "$_up_via" | command grep -ci '^claude' || true)"
          _ok "upstream via proxy" "$(printf '%s\n' "$_up_via" | command grep -c .) ids, $_via_c claude"
          if [ "$_via_c" -gt 0 ]; then
            _hint "start with proxy: copilot-proxy start   # will attach --proxy-env automatically"
          fi
        fi
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
        _note "env proxy" "HTTPS_PROXY is set — bun/node honour this (and --proxy-env), the macOS System Proxy alone they ignore"
      else
        _skip "env proxy" "HTTPS_PROXY unset in this shell (copilot-proxy start auto-injects it when a local proxy is detected)"
      fi

      printf '\n%s\n' "Codex Apps (ChatGPT MCP)"
      _skip "route" "https://chatgpt.com/backend-api/wham/apps — independent of localhost inference and Codex Desktop"
      if [ "$_live" -ne 1 ]; then
        _skip "skipped" "pass --live to probe the optional Apps/Connectors MCP route (no inference quota)"
      else
        local _apps_url _apps_direct _apps_via _as _av _at _ae
        local _direct_apps_ok=0 _via_apps_ok=0
        _apps_url='https://chatgpt.com/backend-api/wham/apps'
        _apps_direct="$(_copilot_optional_http_probe "$_apps_url")"
        IFS='|' read -r _as _av _at _ae <<EOF
$_apps_direct
EOF
        if [ "$_as" = reached ]; then
          _direct_apps_ok=1
          _ok "apps direct" "HTTP $_av in ${_at}s (HTTP rejection still proves reachability)"
        else
          _note "apps direct" "$_av failure after ${_at}s${_ae:+ — $_ae}"
        fi

        if [ -n "$_http_proxy" ]; then
          _apps_via="$(_copilot_optional_http_probe "$_apps_url" "$_http_proxy")"
          IFS='|' read -r _as _av _at _ae <<EOF
$_apps_via
EOF
          if [ "$_as" = reached ]; then
            _via_apps_ok=1
            _ok "apps via proxy" "HTTP $_av in ${_at}s ($_http_proxy)"
          elif [ "$_direct_apps_ok" -eq 1 ]; then
            _skip "apps via proxy" "$_av failure; direct route already works"
          else
            _note "apps via proxy" "$_av failure after ${_at}s${_ae:+ — $_ae}"
          fi
        fi

        if [ "$_direct_apps_ok" -eq 0 ] && [ "$_via_apps_ok" -eq 1 ]; then
          _note "apps routing" "ChatGPT Apps works only through the explicit HTTP proxy"
          _hint "launch Codex with HTTP_PROXY=$_http_proxy HTTPS_PROXY=$_http_proxy (and NO_PROXY=localhost,127.0.0.1,::1)"
        elif [ "$_direct_apps_ok" -eq 0 ] && [ "$_via_apps_ok" -eq 0 ]; then
          _hint "this affects Apps/Connectors only; /status can still show localhost model inference working"
          _hint "timeout → inspect Clash/TUN rules; tls → inspect certificate interception / custom CA"
        fi
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
      # logs [N] [gen]          — tail the fork log; gen 1..3 = rotated session.
      # logs [-f|--follow] [N]  — follow the current fork log across rotation.
      # logs shim [-f] [N]      — tail/follow the throttle shim log.
      local _lf="$logf" _n=40 _n_set=0 _gen='' _follow=0 _target=fork _arg
      shift
      if [ "${1:-}" = shim ]; then _target=shim; _lf="$(_copilot_shim_logfile)"; shift; fi
      for _arg in "$@"; do
        case "$_arg" in
          -f|--follow) _follow=1 ;;
          *[!0-9]*|'')
            printf '%s\n' "copilot-proxy: logs: unknown argument '$_arg'" >&2
            return 2 ;;
          *)
            if [ "$_n_set" -eq 0 ]; then _n="$_arg"; _n_set=1
            elif [ "$_target" = fork ] && [ -z "$_gen" ]; then _gen="$_arg"
            else
              printf '%s\n' "copilot-proxy: logs: too many numeric arguments" >&2
              return 2
            fi ;;
        esac
      done
      case "$_n" in 0|*[!0-9]*) printf '%s\n' "copilot-proxy: logs: line count must be a positive integer" >&2; return 2 ;; esac
      if [ -n "$_gen" ]; then
        case "$_gen" in 1|2|3) _lf="$logf.$_gen" ;; *) printf '%s\n' "copilot-proxy: logs: generation must be 1..3" >&2; return 2 ;; esac
        if [ "$_follow" -eq 1 ]; then
          printf '%s\n' "copilot-proxy: logs: cannot follow a rotated generation" >&2
          return 2
        fi
      fi
      if [ -f "$_lf" ]; then
        if [ "$_follow" -eq 1 ]; then command tail -n "$_n" -F "$_lf"
        else command tail -n "$_n" "$_lf"; fi
      else
        printf '%s\n' "copilot-proxy: no log file at $_lf" >&2; return 1; fi
      ;;
    limiter)
      if ! _copilot_shim_alive; then
        printf '%s\n' "copilot-proxy: limiter requires the running shim; try 'copilot-proxy shim on'." >&2
        return 1
      fi
      local _limiter_action="${2:-status}" _limiter_json='' _min='' _max='' _limit='' _value
      case "$_limiter_action" in
        status)
          _limiter_json="$(_copilot_limiter_request GET)" || return 1
          ;;
        reset)
          _limiter_json="$(_copilot_limiter_request PATCH '{"reset":true}')" || return 1
          ;;
        set)
          if ! command -v jq >/dev/null 2>&1; then
            printf '%s\n' "copilot-proxy: limiter set requires jq" >&2
            return 1
          fi
          shift 2
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --min|--max|--limit)
                [ "$#" -ge 2 ] || { printf '%s\n' "copilot-proxy: limiter set: $1 needs a value" >&2; return 2; }
                _value="$2"
                case "$_value" in 0|*[!0-9]*) printf '%s\n' "copilot-proxy: limiter set: $1 must be a positive integer" >&2; return 2 ;; esac
                case "$1" in --min) _min="$_value" ;; --max) _max="$_value" ;; --limit) _limit="$_value" ;; esac
                shift 2 ;;
              *) printf '%s\n' "copilot-proxy: limiter set: unknown argument '$1'" >&2; return 2 ;;
            esac
          done
          [ -n "${_min}${_max}${_limit}" ] || { printf '%s\n' "copilot-proxy: limiter set needs --min, --max, or --limit" >&2; return 2; }
          _limiter_json="$(jq -nc \
            --arg min "$_min" --arg max "$_max" --arg limit "$_limit" '
              {} + (if $min == "" then {} else {min: ($min|tonumber)} end)
                 + (if $max == "" then {} else {max: ($max|tonumber)} end)
                 + (if $limit == "" then {} else {limit: ($limit|tonumber)} end)')"
          _limiter_json="$(_copilot_limiter_request PATCH "$_limiter_json")" || return 1
          ;;
        *)
          printf '%s\n' "Usage: copilot-proxy limiter [status|set --min N --max N --limit N|reset]" >&2
          return 2 ;;
      esac
      if command -v jq >/dev/null 2>&1; then
        printf '%s' "$_limiter_json" | jq '{limit,min,max,active,queued,adaptive,cooldown_ms_remaining,successes_to_increase,throttle_events,last_throttle_status,startup}'
      else
        printf '%s\n' "$_limiter_json"
      fi
      if [ "$_limiter_action" != status ]; then
        printf '%s\n' "copilot-proxy: live limiter updated for this shim process only; export COPILOT_SHIM_MIN/MAX before restart to persist." >&2
      fi
      ;;
    auth)
      # One-time device login → stores a ghu_ token copilot-api can exchange.
      _copilot_ensure_pkg || return 1
      printf '%s\n' "copilot-proxy: launching copilot-api device login ..."
      if [ "$(_copilot_pkg_flavor)" = "original" ]; then
        "$(_copilot_pkg_bin)" auth
      else
        # Fork ≥ 2.3.x nests the device flow under `auth login` (`auth` alone now
        # only prints usage and exits 1 with "Unknown command copilot", because
        # citty reads the --provider VALUE as the missing subcommand). Older forks
        # took `auth --provider`. Probe the help text instead of the version so a
        # bump either way keeps working.
        if "$(_copilot_pkg_bin)" auth --help 2>&1 | command grep -qE '^[[:space:]]*login([[:space:]]|$)'; then
          "$(_copilot_pkg_bin)" auth login --provider copilot
        else
          "$(_copilot_pkg_bin)" auth --provider copilot
        fi
      fi
      ;;
    update)
      case "${2:---check}" in
        --check) _copilot_update_check ;;
        *) _copilot_update_exact "$2" ;;
      esac
      ;;
    reinstall)
      # Force a clean re-install of the pinned spec (normally only needed if the
      # prefix got corrupted — a version bump re-installs on its own via the stamp).
      printf '%s\n' "copilot-proxy: removing $(_copilot_pkg_prefix) ..."
      command rm -rf -- "$(_copilot_pkg_prefix)"
      _copilot_ensure_pkg || return 1
      printf '%s\n' "copilot-proxy: installed $(_copilot_pkg) → $(_copilot_pkg_bin)"
      ;;
    stats|events)
      local _metric_action="$action"
      shift
      _copilot_metrics_cli "$_metric_action" "$@"
      ;;
    bench)
      shift
      if ! _copilot_alive; then copilot-proxy start || return 1; fi
      if ! _copilot_shim_enabled; then
        printf '%s\n' "copilot-proxy: bench requires the metrics shim; run 'copilot-proxy shim on'." >&2
        return 1
      fi
      _copilot_require_shim || return 1
      local _has_model=0 _arg _bench_model
      for _arg in "$@"; do [ "$_arg" = "--model" ] && _has_model=1; done
      _bench_model="$(_copilot_default_model)"; _bench_model="${_bench_model%\[1m\]}"
      printf '%s\n' "copilot-proxy: benchmark sends real inference requests and consumes quota." >&2
      if [ "$_has_model" -eq 1 ]; then
        _copilot_metrics_cli bench --base "$(_copilot_shim_base)" "$@"
      else
        _copilot_metrics_cli bench --base "$(_copilot_shim_base)" --model "$_bench_model" "$@"
      fi
      ;;
    quota|whoami|usage)
      # Real login check: exchanges the stored token against GitHub and prints
      # the account / plan / quota. Fails loudly if the token is missing/expired.
      local _quota_json=0
      [ "${2:-}" = "--json" ] && _quota_json=1
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
        if [ "$_quota_json" -eq 1 ] || ! command -v jq >/dev/null 2>&1; then
          command curl -fsS --max-time 5 "$(_copilot_base)/usage"
        else
          command curl -fsS --max-time 5 "$(_copilot_base)/usage" | jq '{
            plan: (.copilot_plan // .access_type_sku // "unknown"),
            quota_reset: (.quota_reset_date // null),
            quotas: ((.quota_snapshots // {}) | map_values(
              if type == "object" then
                {remaining, entitlement, percent_remaining, unlimited}
              else . end))
          }'
        fi
      else
        printf '%s\n' "copilot-proxy: quota is live data and the proxy is not running." >&2
        return 1
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
          command mkdir -p "$(command dirname "$sf")" || return 1
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
      printf '%s\n' "Usage: copilot-proxy [start|stop|restart|status|stats|events|quota|bench|limiter|update|doctor|...]"
      printf '%s\n' "  stats [day|week|month] [--model ID] [--scope normal|benchmark|all] [--json]"
      printf '%s\n' "  events [day|week|month] [--model ID] [--scope ...] [--limit N] [--json]"
      printf '%s\n' "  quota [--json]       live plan/quota payload from the running fork"
      printf '%s\n' "  logs [-f] [N] | logs shim [-f] [N]   tail/follow current logs (-F across restart)"
      printf '%s\n' "  limiter status | set --min N --max N --limit N | reset   live, process-local"
      printf '%s\n' "  bench [--model ID] [--runs 1..10] [--max-output 32..2048] [--concurrency 1..4] [--json]"
      printf '%s\n' "  update --check | update VERSION   inspect latest or install an exact verified version"
      printf '%s\n' "  doctor (alias: test)  diagnose prereqs, auth, proxy, Claude catalog (direct vs via"
      printf '%s\n' "                        Clash), upstream reachability and Codex Apps."
      printf '%s\n' "                        --live probes Apps and costs 1 inference quota unit."
      printf '%s\n' "  COPILOT_HTTP_PROXY    auto|always|never|http://127.0.0.1:PORT  (default auto)"
      printf '%s\n' "                        auto attaches --proxy-env when proxy-status finds a local proxy."
      printf '%s\n' "  reinstall             wipe + re-install the selected package (for a corrupted prefix)."
      ;;
    *)
      printf '%s\n' "copilot-proxy: unknown action '$action' (try --help)" >&2
      return 1
      ;;
  esac
}

# --- session wrapper (Layer 1: one-off, guarded user-model state) ----------------

# Claude Code's `/model` picker says "Enter to set as default" and writes the
# selected custom model to ~/.claude/settings.json. That user-level key outlives
# both the per-process env used by claude-copilot and the settings.local.json pin
# removed by copilot-here off. The result is a plain/native Claude session whose
# model menu still says `gpt-*` even though no proxy env remains.
#
# Guard only the single foreign-written `.model` key. Hooks, plugins, permissions,
# and every other user setting may legitimately change while Claude is running and
# must survive. A pre-existing proxy-only value is treated as stale (no baseline),
# while a native value such as `sonnet` is restored if `/model` overwrites it.
_copilot_claude_settings_file() {
  printf '%s' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
}

_copilot_model_value_is_proxy_only() {
  local value="${1:-}" state_value=""
  [ -n "$value" ] || return 1

  # The state file is the durable source used by copilot-run / copilot-here.
  # Compare with and without Claude Code's display-only [1m] suffix.
  if [ -f "$(_copilot_model_state)" ]; then
    state_value="$(command head -n 1 "$(_copilot_model_state)" 2>/dev/null)"
    if [ "$value" = "$state_value" ] \
       || [ "${value%\[1m\]}" = "${state_value%\[1m\]}" ]; then
      return 0
    fi
  fi

  # OpenAI/Gemini ids are custom-provider values, not valid native Anthropic
  # defaults. Do NOT classify every [1m] suffix as proxy-only: native Claude
  # subscriptions also expose explicit 1M model choices. A Claude id is cleaned
  # only when it exactly matches the proxy state-file pin above.
  case "$value" in
    gpt-*|gemini-*) return 0 ;;
  esac
  return 1
}

_copilot_model_guard_begin() {
  _copilot_model_guard_file="$(_copilot_claude_settings_file)"
  _copilot_model_guard_had_native=0
  _copilot_model_guard_native_json=''
  _copilot_model_guard_changed=0

  [ -f "$_copilot_model_guard_file" ] || return 0
  jq -e 'has("model")' "$_copilot_model_guard_file" >/dev/null 2>&1 || return 0

  local value
  value="$(jq -r '.model | strings' "$_copilot_model_guard_file" 2>/dev/null)"
  if ! _copilot_model_value_is_proxy_only "$value"; then
    _copilot_model_guard_native_json="$(jq -c '.model' "$_copilot_model_guard_file" 2>/dev/null)" || return 1
    _copilot_model_guard_had_native=1
  fi
}

_copilot_model_guard_restore() {
  local settings="${_copilot_model_guard_file:-$(_copilot_claude_settings_file)}"
  [ -f "$settings" ] || return 0
  jq -e 'has("model")' "$settings" >/dev/null 2>&1 || return 0

  local current tmp
  current="$(jq -r '.model | strings' "$settings" 2>/dev/null)"
  _copilot_model_value_is_proxy_only "$current" || return 0

  tmp="$(command mktemp "${TMPDIR:-/tmp}/copilot-claude-model.XXXXXX")" || return 1
  if [ "${_copilot_model_guard_had_native:-0}" = "1" ]; then
    if jq --argjson model "$_copilot_model_guard_native_json" '.model = $model' "$settings" >"$tmp"; then
      command mv -- "$tmp" "$settings"
      _copilot_model_guard_changed=1
      printf '%s\n' "copilot-proxy: restored native user model in $settings"
      return 0
    fi
  else
    if jq 'del(.model)' "$settings" >"$tmp"; then
      command mv -- "$tmp" "$settings"
      _copilot_model_guard_changed=1
      printf '%s\n' "copilot-proxy: removed stale proxy model from $settings"
      return 0
    fi
  fi

  command rm -f -- "$tmp"
  printf '%s\n' "copilot-proxy: could not restore $settings; model key left unchanged" >&2
  return 1
}

_copilot_clean_stale_user_model() {
  _copilot_model_guard_begin || return 1
  _copilot_model_guard_restore
}

# Explain the launch that would result from running plain `claude` in the
# current directory, without exposing auth tokens. This keeps the four relevant
# sources in one diagnostic instead of making the user inspect user/project/local
# JSON plus inherited env by hand.
_copilot_claude_launch_report() {
  local user_settings project_settings local_settings
  local user_model user_base user_env_model
  local project_model project_base project_env_model
  local local_model local_base local_env_model
  local shell_base shell_model effective_base effective_base_source
  local effective_model effective_model_source backend running_count

  user_settings="$(_copilot_claude_settings_file)"
  project_settings=".claude/settings.json"
  local_settings=".claude/settings.local.json"

  user_model=''; user_base=''; user_env_model=''
  project_model=''; project_base=''; project_env_model=''
  local_model=''; local_base=''; local_env_model=''
  if [ -f "$user_settings" ]; then
    user_model="$(jq -r '.model | strings' "$user_settings" 2>/dev/null)"
    user_base="$(jq -r '.env.ANTHROPIC_BASE_URL | strings' "$user_settings" 2>/dev/null)"
    user_env_model="$(jq -r '.env.ANTHROPIC_MODEL | strings' "$user_settings" 2>/dev/null)"
  fi
  if [ -f "$project_settings" ]; then
    project_model="$(jq -r '.model | strings' "$project_settings" 2>/dev/null)"
    project_base="$(jq -r '.env.ANTHROPIC_BASE_URL | strings' "$project_settings" 2>/dev/null)"
    project_env_model="$(jq -r '.env.ANTHROPIC_MODEL | strings' "$project_settings" 2>/dev/null)"
  fi
  if [ -f "$local_settings" ]; then
    local_model="$(jq -r '.model | strings' "$local_settings" 2>/dev/null)"
    local_base="$(jq -r '.env.ANTHROPIC_BASE_URL | strings' "$local_settings" 2>/dev/null)"
    local_env_model="$(jq -r '.env.ANTHROPIC_MODEL | strings' "$local_settings" 2>/dev/null)"
  fi
  shell_base="${ANTHROPIC_BASE_URL:-}"
  shell_model="${ANTHROPIC_MODEL:-}"

  # Verified Claude Code precedence for env blocks on this setup:
  # user settings < project settings < inherited shell env < settings.local.
  if [ -n "$local_base" ]; then effective_base="$local_base"; effective_base_source="$local_settings env"
  elif [ -n "$shell_base" ]; then effective_base="$shell_base"; effective_base_source="shell env"
  elif [ -n "$project_base" ]; then effective_base="$project_base"; effective_base_source="$project_settings env"
  elif [ -n "$user_base" ]; then effective_base="$user_base"; effective_base_source="$user_settings env"
  else effective_base=''; effective_base_source="Anthropic default"; fi

  if [ -n "$local_env_model" ]; then effective_model="$local_env_model"; effective_model_source="$local_settings env"
  elif [ -n "$shell_model" ]; then effective_model="$shell_model"; effective_model_source="shell env"
  elif [ -n "$project_env_model" ]; then effective_model="$project_env_model"; effective_model_source="$project_settings env"
  elif [ -n "$user_env_model" ]; then effective_model="$user_env_model"; effective_model_source="$user_settings env"
  elif [ -n "$local_model" ]; then effective_model="$local_model"; effective_model_source="$local_settings model"
  elif [ -n "$project_model" ]; then effective_model="$project_model"; effective_model_source="$project_settings model"
  elif [ -n "$user_model" ]; then effective_model="$user_model"; effective_model_source="$user_settings model"
  else effective_model="account/default"; effective_model_source="no explicit model"; fi

  if [ -z "$effective_base" ]; then backend="Anthropic"
  elif printf '%s' "$effective_base" | command grep -Eq 'localhost|127\.0\.0\.1'; then backend="local/custom proxy"
  else backend="custom Anthropic-compatible endpoint"; fi

  printf '\n%s\n' "Plain Claude launch audit (cwd: $PWD)"
  printf '  %-16s model=%s  env-model=%s  base=%s\n' "user settings" \
    "${user_model:-unset}" "${user_env_model:-unset}" "${user_base:-unset}"
  printf '  %-16s model=%s  env-model=%s  base=%s\n' "project settings" \
    "${project_model:-unset}" "${project_env_model:-unset}" "${project_base:-unset}"
  printf '  %-16s model=%s  env-model=%s  base=%s\n' "local settings" \
    "${local_model:-unset}" "${local_env_model:-unset}" "${local_base:-unset}"
  printf '  %-16s model=%s  base=%s\n' "shell env" "${shell_model:-unset}" "${shell_base:-unset}"
  printf '  %-16s %s (%s)\n' "effective backend" "$backend" "$effective_base_source"
  printf '  %-16s %s (%s)\n' "effective model" "$effective_model" "$effective_model_source"

  running_count="$(command pgrep -x claude 2>/dev/null | command wc -l | command tr -d ' ')"
  if [ "${running_count:-0}" -gt 0 ] 2>/dev/null; then
    printf '  %-16s %s process(es) (restart relevant sessions to apply changes)\n' "running Claude" "$running_count"
  fi

  if [ -z "$effective_base" ] && _copilot_model_value_is_proxy_only "$effective_model"; then
    printf '%s\n' "  ⚠ native Anthropic backend with a proxy-only model default; run: copilot-here off"
  fi
}

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
  if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' "copilot-run: jq is required to build the model role profile" >&2
    return 1
  fi
  if ! _copilot_alive; then
    copilot-proxy start || return 1
  fi
  # If the shim is enabled but not up (e.g. toggled on after the proxy started),
  # bring it up now so ANTHROPIC_BASE_URL below resolves to it.
  _copilot_require_shim || return 1
  # Inject the SAME block `copilot-here on` writes — _copilot_env_json_for_model
  # is the single source of truth, and --live swaps the pinned base for the one
  # this process should use right now. The COPILOT_PROXY_QUIET quota-savers come
  # from that block too.
  #
  # This was a hand-maintained SECOND copy of the key list, i.e. exactly the
  # drift that function's comment warns about: `copilot-here on` and `copilot-run`
  # could inject different env on the same machine, and only one of them was
  # covered by the drift check.
  local env_json _kv selected_model command_path command_name explicit_model
  selected_model="$(_copilot_default_model)"
  command_path="$1"
  command_name="$(command basename -- "$command_path" 2>/dev/null || printf '%s' "$command_path")"
  if [ "$command_name" = "claude" ]; then
    shift
    explicit_model="$(_copilot_claude_model_arg "$@")"
    [ -n "$explicit_model" ] && selected_model="$(_copilot_claude_fast_base_model "$explicit_model")"
    set -- "$command_path" "$@"
  fi
  env_json="$(_copilot_env_json_for_model --live "$selected_model")" || return 1
  # Prepend each NAME=VALUE as an `env` argument; order is irrelevant to env(1).
  # A here-doc rather than a pipe: the loop MUST run in this shell or every
  # `set --` is discarded with the subshell.
  while IFS= read -r _kv; do
    [ -n "$_kv" ] || continue
    set -- "$_kv" "$@"
  done <<EOF
$(printf '%s\n' "$env_json" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
EOF
  # `command env` (not bare var-prefix) so the vars are strictly per-process:
  # POSIX var-prefix on a *function* call would leak into the current shell.
  command env "$@"
}

# Pick the best model for Codex from the raw gateway catalog. This is
# deliberately NOT _copilot_pick_best_model: Claude Code prefers native Claude
# when entitled, while Codex should stay on a native Responses-capable OpenAI
# model as long as one is served. Claude/Gemini remain useful last-resort
# Responses Lite fallbacks.
_copilot_codex_pick_best_model() {
  local models preferred c rows tier remaining_models remaining_rows
  # Same two-stage policy as _copilot_pick_best_model (tier pre-pass, then the
  # curated allowlist, then lexical), but in Codex's vendor order: OpenAI first,
  # then Claude, then grok, then Gemini. $1 (optional) = raw catalog JSON.
  models="$(command cat | command sed 's/\[1m\]$//' \
    | command grep -vE -- '-fast$' | command sort -u)"
  [ -n "$models" ] || return 1
  rows=''
  [ -n "${1:-}" ] && rows="$(printf '%s' "$1" | _copilot_tier_rows \
    | _copilot_tier_rows_for_ids "$models")"

  tier="$(_copilot_tier_prepass '^(gpt-|o[0-9])' "$rows" "$models" \
    gpt-6-astra gpt-5.6-sol gpt-5.6-terra gpt-5.5 gpt-5.4 gpt-5.3-codex \
    gpt-5.6-luna gpt-5.4-mini gpt-5-mini || true)"
  if [ -n "$tier" ]; then printf '%s' "$tier"; return 0; fi

  for preferred in \
    gpt-6-astra gpt-5.6-sol gpt-5.6-terra gpt-5.5 gpt-5.4 gpt-5.3-codex \
    gpt-5.6-luna gpt-5.4-mini gpt-5-mini
  do
    if printf '%s\n' "$models" | command grep -qxF "$preferred"; then
      printf '%s' "$preferred"
      return 0
    fi
  done
  c="$(printf '%s\n' "$models" | command grep -E '^(gpt-|o[0-9])' | command grep -viE 'mini|nano|luna|-fast$' \
        | command sort -V | command tail -1)"
  if [ -n "$c" ]; then printf '%s' "$c"; return 0; fi
  c="$(printf '%s\n' "$models" | command grep -iE 'codex' | command sort -V | command tail -1)"
  if [ -n "$c" ]; then printf '%s' "$c"; return 0; fi
  c="$(printf '%s\n' "$models" | command grep -E '^(gpt-|o[0-9])' | command sort -V | command tail -1)"
  if [ -n "$c" ]; then printf '%s' "$c"; return 0; fi

  tier="$(_copilot_tier_prepass '^claude-' "$rows" "$models" \
    claude-fable-5 \
    claude-opus-5 claude-opus-4-8 claude-opus-4-7 claude-opus-4-6 \
    claude-sonnet-5 claude-sonnet-4-6 claude-sonnet-4-5 \
    claude-opus-4-5 claude-haiku-4-5 || true)"
  if [ -n "$tier" ]; then printf '%s' "$tier"; return 0; fi

  for preferred in \
    claude-fable-5 \
    claude-opus-5 claude-opus-4-8 claude-opus-4-7 claude-opus-4-6 \
    claude-sonnet-5 claude-sonnet-4-6 claude-sonnet-4-5 \
    claude-opus-4-5 claude-haiku-4-5
  do
    if printf '%s\n' "$models" | command grep -qxF "$preferred"; then
      printf '%s' "$preferred"
      return 0
    fi
  done
  c="$(printf '%s\n' "$models" | command grep -E '^claude-' | command sort -V | command tail -1)"
  if [ -n "$c" ]; then printf '%s' "$c"; return 0; fi

  # xAI — no allowlist on purpose, see _copilot_pick_best_model.
  tier="$(_copilot_tier_best_complete '^grok-' "$rows" "$models" || true)"
  if [ -n "$tier" ]; then printf '%s' "$tier"; return 0; fi
  c="$(printf '%s\n' "$models" | command grep -E '^grok-' | command grep -viE 'mini|nano|lite|-fast$' \
        | _copilot_latest_model)"
  if [ -n "$c" ]; then printf '%s' "$c"; return 0; fi
  c="$(printf '%s\n' "$models" | command grep -E '^grok-' | _copilot_latest_model)"
  if [ -n "$c" ]; then printf '%s' "$c"; return 0; fi

  tier="$(_copilot_tier_best_complete '^gemini-' "$rows" "$models" 2>/dev/null || true)"
  if [ -n "$tier" ]; then printf '%s' "$tier"; return 0; fi
  c="$(printf '%s\n' "$models" | command grep -E '^gemini-' | command grep -viE 'flash' \
        | command sort -V | command tail -1)"
  if [ -n "$c" ]; then printf '%s' "$c"; return 0; fi
  c="$(printf '%s\n' "$models" | command grep -E '^gemini-' | command sort -V | command tail -1)"
  if [ -n "$c" ]; then printf '%s' "$c"; return 0; fi

  # Any remaining vendor (for example MAI) still gets its catalog tier before
  # the offline lexical catch-all. Known vendor rows are excluded because their
  # ordering above is deliberate and must not be interleaved here.
  remaining_models="$(printf '%s\n' "$models" | command grep -vE '^(claude|gpt|grok|gemini)-' || true)"
  remaining_rows="$(printf '%s\n' "$rows" \
    | command awk -F'\t' '$2 !~ /^(claude|gpt|grok|gemini)-/')"
  tier="$(_copilot_tier_best_complete '.*' "$remaining_rows" "$remaining_models" 2>/dev/null || true)"
  if [ -n "$tier" ]; then printf '%s' "$tier"; return 0; fi
  printf '%s\n' "$models" | command sort -V | command tail -1
}

# Effective SpecStory Codex command, matching SpecStory's own precedence.
# `specstory run ... -c` replaces this command wholesale, so callers must append
# to this value rather than fall back to a bare `codex` and silently lose the
# configured reasoning / sandbox flags.
_copilot_specstory_codex_cmd() {
  local f cmd=''
  for f in ".specstory/cli/config.toml" "$HOME/.specstory/cli/config.toml"; do
    [ -f "$f" ] || continue
    cmd="$(command sed -n \
      -e "s/^[[:space:]]*codex_cmd[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
      -e "s/^[[:space:]]*codex_cmd[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" \
      "$f" 2>/dev/null | command head -n 1)"
    if [ -n "$cmd" ]; then break; fi
  done
  printf '%s' "${cmd:-codex}"
}

# Codex stores one global models_cache.json without provider namespacing. A
# custom Copilot gateway refresh can therefore replace the first-party metadata
# catalog with the gateway's much smaller adapter subset, making a bundled model
# such as gpt-5.6-sol fall back to generic metadata. Pin this launcher to the
# catalog bundled with the installed Codex binary instead. The binary version is
# part of the path, so upgrades regenerate automatically while repeat launches
# avoid another `codex debug models --bundled` subprocess.
_copilot_codex_catalog_file() {
  command -v codex >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1

  local raw_version version cache_dir catalog_file tmp
  raw_version="$(command codex --version 2>/dev/null)" || return 1
  version="$(printf '%s' "$raw_version" | command sed 's/[^[:alnum:]._-]/_/g')"
  [ -n "$version" ] || return 1

  cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/copilot-proxy/codex-models"
  catalog_file="$cache_dir/$version.json"
  if [ -s "$catalog_file" ] \
     && jq -e '.models | type == "array" and length > 0' "$catalog_file" >/dev/null 2>&1; then
    printf '%s' "$catalog_file"
    return 0
  fi

  command mkdir -p "$cache_dir" || return 1
  tmp="$(command mktemp "$cache_dir/.catalog.XXXXXX")" || return 1
  if command codex debug models --bundled >"$tmp" 2>/dev/null \
     && jq -e '.models | type == "array" and length > 0' "$tmp" >/dev/null 2>&1; then
    command mv -- "$tmp" "$catalog_file"
    printf '%s' "$catalog_file"
  else
    command rm -f -- "$tmp"
    return 1
  fi
}

# One-off Codex session backed by the local Copilot gateway. Provider settings
# are CLI overrides only: plain `codex`, ~/.codex/config.toml and project config
# remain untouched. The alias-like sibling below exists for Claude wrapper
# muscle memory; both names have identical zero-persistence semantics.
codex-copilot() {
  local ss="auto" arg explicit_model=0 model='' catalog='' models=''
  case "${1:-}" in
    --no-specstory) ss="never"; shift ;;
    --specstory)    shift ;;
    -h|--help)
      printf '%s\n' "Usage: codex-copilot [--no-specstory] [codex args...]"
      printf '%s\n' "  One-off Codex session on the local Copilot Responses gateway."
      printf '%s\n' "  Auto model: OpenAI/Codex > Claude > grok > Gemini > other served chat models."
      printf '%s\n' "  Alias: codex-copilot-once"
      return 0 ;;
  esac

  if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' "codex-copilot: jq is required for live model selection" >&2
    return 1
  fi
  if ! _copilot_alive; then copilot-proxy start || return 1; fi
  # Normal mode requires the shim for metrics and Responses normalization.
  # Explicit `shim off` is the only break-glass route around it.
  _copilot_require_shim || return 1

  catalog="$(_copilot_model_catalog)" || {
    printf '%s\n' "codex-copilot: could not read the live gateway model catalog" >&2
    return 1
  }
  for arg in "$@"; do
    [ "$arg" = "--" ] && break
    case "$arg" in -m|--model|-m=*|--model=*) explicit_model=1 ;; esac
  done
  if [ "$explicit_model" -eq 0 ]; then
    models="$(printf '%s' "$catalog"       | _copilot_auto_candidate_ids "$(_copilot_entitlement_baseline_model)")"
    model="$(printf '%s\n' "$models" | _copilot_codex_pick_best_model "$catalog")" || {
      printf '%s\n' "codex-copilot: no usable chat model in the live gateway catalog" >&2
      return 1
    }
    set -- -m "$model" "$@"
    case "$model" in
      claude-*|gemini-*)
        printf '%s\n' "codex-copilot: --auto -> $model (Responses Lite; tool_search unavailable)" >&2 ;;
      *) printf '%s\n' "codex-copilot: --auto -> $model" >&2 ;;
    esac
  fi

  # Keep these overrides per-process/per-invocation. `name = OpenAI` is an
  # upstream gateway requirement; the dummy key only satisfies Codex's provider
  # auth contract and is ignored by our unauthenticated localhost listener.
  local base cmd context='' compact=''
  base="$(_copilot_client_base)"
  cmd="$(_copilot_specstory_codex_cmd)"
  if [ -n "$model" ]; then
    context="$(printf '%s' "$catalog" | jq -r --arg id "$model" '
      first(.data[]? | select(.id == $id) | .capabilities.limits.max_context_window_tokens) // empty' 2>/dev/null)"
    compact="$(printf '%s' "$catalog" | jq -r --arg id "$model" '
      first(.data[]? | select(.id == $id) | .capabilities.limits.max_prompt_tokens) // empty' 2>/dev/null)"
  fi
  # Prepend discovered metadata; any explicit user `-c` remains later in argv
  # and therefore retains normal Codex CLI precedence.
  if [ -n "$compact" ]; then set -- -c "model_auto_compact_token_limit=$compact" "$@"; fi
  if [ -n "$context" ]; then set -- -c "model_context_window=$context" "$@"; fi

  local bundled_catalog='' provider_args=""
  if bundled_catalog="$(_copilot_codex_catalog_file)"; then
    # Prepend so an explicit later user -c retains normal Codex precedence.
    set -- -c "model_catalog_json=\"$bundled_catalog\"" "$@"
  else
    printf '%s\n' "codex-copilot: warning: could not build the bundled Codex model catalog; metadata may fall back" >&2
  fi
  # Build a shell-safe command fragment for SpecStory; direct execution below
  # uses the original argv and does not round-trip through a string.
  for arg in \
    -c 'model_provider="copilot_api"' \
    -c 'model_providers.copilot_api.name="OpenAI"' \
    -c "model_providers.copilot_api.base_url=\"$base\"" \
    -c 'model_providers.copilot_api.env_key="GITHUB_COPILOT_API_KEY"' \
    -c 'model_providers.copilot_api.requires_openai_auth=true' \
    -c 'model_providers.copilot_api.supports_websockets=false' \
    -c 'model_providers.copilot_api.wire_api="responses"' \
    -c 'model_providers.copilot_api.request_max_retries=3' \
    -c 'model_providers.copilot_api.stream_max_retries=1' \
    -c 'model_providers.copilot_api.stream_idle_timeout_ms=300000' \
    -c 'features.remote_compaction_v2=true' \
    -c 'features.code_mode.excluded_tool_namespaces=["mcp__codex_apps__sites"]'
  do provider_args="$provider_args $(_copilot_shquote "$arg")"; done
  for arg in "$@"; do provider_args="$provider_args $(_copilot_shquote "$arg")"; done

  if [ "$ss" = "auto" ] && command -v specstory >/dev/null 2>&1; then
    command env GITHUB_COPILOT_API_KEY=dummy specstory run codex -c "$cmd$provider_args"
  else
    # Mirror the approval posture the specstory path inherits from `codex_cmd`.
    _copilot_codex_has_sandbox_flag "$@" \
      || set -- --sandbox danger-full-access "$@"
    _copilot_codex_has_approval_flag "$@" \
      || set -- --ask-for-approval never "$@"
    command env GITHUB_COPILOT_API_KEY=dummy codex \
      -c 'model_provider="copilot_api"' \
      -c 'model_providers.copilot_api.name="OpenAI"' \
      -c "model_providers.copilot_api.base_url=\"$base\"" \
      -c 'model_providers.copilot_api.env_key="GITHUB_COPILOT_API_KEY"' \
      -c 'model_providers.copilot_api.requires_openai_auth=true' \
      -c 'model_providers.copilot_api.supports_websockets=false' \
      -c 'model_providers.copilot_api.wire_api="responses"' \
      -c 'model_providers.copilot_api.request_max_retries=3' \
      -c 'model_providers.copilot_api.stream_max_retries=1' \
      -c 'model_providers.copilot_api.stream_idle_timeout_ms=300000' \
      -c 'features.remote_compaction_v2=true' \
      -c 'features.code_mode.excluded_tool_namespaces=["mcp__codex_apps__sites"]' \
      "$@"
  fi
}

codex-copilot-once() { codex-copilot "$@"; }

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
# `--no-specstory` still does NOT inherit the COMMAND — no custom binary, no
# configured flags, nothing that would drag `--resume` or an --append-system-prompt
# into a path the user explicitly asked to keep raw. It only asserts the same
# PERMISSION POSTURE (see _copilot_claude_has_permission_flag), because that
# posture is a property of this wrapper — a trusted, hands-off localhost gateway
# — not of specstory. Without that, `claude-copilot --no-specstory` silently
# dropped to ~/.claude/settings.json's defaultMode while the specstory path ran
# in bypass: same wrapper, opposite permission mode, no warning. The Windows
# port has always injected it directly (Copilot.psm1); this matches it.

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

# A wrapper-only --fast that appears after Claude arguments is almost certainly
# misplaced. Respect prompt/data boundaries so literal prompt text never trips it.
_copilot_claude_has_late_fast() {
  local a leading=1 skip=0
  for a in "$@"; do
    if [ "$leading" -eq 1 ]; then
      case "$a" in
        --fast|--no-specstory|--specstory) continue ;;
        *) leading=0 ;;
      esac
    fi
    [ "$a" = "--" ] && return 1
    if [ "$skip" -eq 1 ]; then skip=0; continue; fi
    case "$a" in
      --append-system-prompt|--system-prompt|--settings|--model|--permission-mode|--permission-prompts|--permission-prompt-tool)
        skip=1 ;;
      --fast) return 0 ;;
    esac
  done
  return 1
}

# True when argv already states a permission posture, so the wrapper must not
# add a second, contradictory one. Keep in sync with the Windows twin
# Test-CopilotClaudePermissionFlag.
_copilot_claude_has_permission_flag() {
  local a skip=0
  for a in "$@"; do
    # `--` ends options even when it follows -p; it is not -p's data value.
    [ "$a" = "--" ] && return 1
    if [ "$skip" -eq 1 ]; then skip=0; continue; fi
    case "$a" in
      --append-system-prompt|--system-prompt|--settings|--model)
        skip=1 ;;
      --dangerously-skip-permissions|--restricted|\
      --permission-mode|--permission-mode=*|\
      --permission-prompts|--permission-prompts=*|\
      --permission-prompt-tool|--permission-prompt-tool=*) return 0 ;;
    esac
  done
  return 1
}

# True only for an explicit posture that must OVERRIDE bypass, not for bypass
# itself. The SpecStory base command may already contain the seeded bypass; in
# that case merely declining to add a second token is insufficient — strip the
# configured token before appending the user's explicit mode.
_copilot_claude_has_nonbypass_permission_flag() {
  local a skip=0
  for a in "$@"; do
    [ "$a" = "--" ] && return 1
    if [ "$skip" -eq 1 ]; then skip=0; continue; fi
    case "$a" in
      --append-system-prompt|--system-prompt|--settings|--model)
        skip=1 ;;
      --restricted|\
      --permission-mode|--permission-mode=*|\
      --permission-prompts|--permission-prompts=*|\
      --permission-prompt-tool|--permission-prompt-tool=*) return 0 ;;
    esac
  done
  return 1
}

_copilot_claude_drop_bypass_token() {
  # Only rewrite the exact repo-seeded command. Arbitrary project/user
  # `claude_cmd` strings own their permission posture; parsing/reconstructing
  # shell text here can silently corrupt prompt data or tokens after `--`.
  case "$1" in
    'claude --dangerously-skip-permissions') printf '%s\n' 'claude' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# Codex has TWO independent permission axes. Detect them separately: a caller
# who asks for `--sandbox read-only` still wants the wrapper's no-prompt approval
# default, and a caller who asks for `--ask-for-approval untrusted` still wants
# the wrapper's full-access sandbox default. The compound modes cover both.
_copilot_codex_has_approval_flag() {
  local a
  for a in "$@"; do
    [ "$a" = "--" ] && return 1
    case "$a" in
      -a|-a?*|--ask-for-approval|--ask-for-approval=*|--approve-for-me|\
      --full-auto|--dangerously-bypass-approvals-and-sandbox) return 0 ;;
    esac
  done
  return 1
}

_copilot_codex_has_sandbox_flag() {
  local a
  for a in "$@"; do
    [ "$a" = "--" ] && return 1
    case "$a" in
      -s|-s?*|--sandbox|--sandbox=*|--approve-for-me|\
      --full-auto|--dangerously-bypass-approvals-and-sandbox) return 0 ;;
    esac
  done
  return 1
}

# Single-quote ONE argument for embedding in specstory's `-c` command STRING.
# specstory shell-splits that string honouring quotes (verified: `-p 'a b'`
# arrives as a single argv entry), so quoting is both possible and necessary —
# the old `"claude $*"` flattened `claude-copilot -p "two words"` into two
# separate arguments. POSIX escape for an embedded quote: close, \', reopen.
_copilot_shquote() {
  printf "'%s'" "$(printf '%s' "${1:-}" | command sed "s/'/'\\\\''/g")"
}

# One-off Claude Code session backed by the Copilot proxy. The launcher itself
# writes no user config; if Claude Code's `/model` picker writes its custom model
# to ~/.claude/settings.json, a subshell EXIT guard restores only that `.model`
# key (including Ctrl-C/non-zero exits) while preserving every unrelated change.
# Wraps in `specstory run` when specstory is installed (markdown auto-save,
# same convention as scode/svibe); opt out with --no-specstory. Extra args go
# to the claude CLI via specstory's -c "custom command" passthrough, appended to
# the configured `claude_cmd` (see the block above — `-c` REPLACES that command,
# so we have to rebuild it or its flags are lost).
# Example:
#   claude-copilot                 # specstory run claude (proxy env)
#   claude-copilot -c              # continue last session
#   claude-copilot --fast          # this session uses a live-catalog fast sibling
#   claude-copilot --no-specstory  # raw claude, no markdown auto-save
_copilot_claude_model_arg() {
  local arg expect=0 skip=0 found=''
  for arg in "$@"; do
    [ "$arg" = "--" ] && break
    if [ "$expect" -eq 1 ]; then found="$arg"; expect=0; continue; fi
    if [ "$skip" -eq 1 ]; then skip=0; continue; fi
    case "$arg" in
      --append-system-prompt|--system-prompt|--settings|--permission-mode|--permission-prompts|--permission-prompt-tool)
        skip=1 ;;
      --model) expect=1 ;;
      --model=*) found="${arg#--model=}" ;;
    esac
  done
  printf '%s' "$found"
}

_copilot_claude_fast_base_model() {
  local explicit="$1" effective catalog profile role
  case "$explicit" in
    '') effective="$(_copilot_effective_model)"; printf '%s' "${effective%%|*}"; return 0 ;;
    opus|fable|sonnet|haiku|opusplan)
      effective="$(_copilot_effective_model)"
      effective="${effective%%|*}"
      catalog="$(_copilot_model_catalog 2>/dev/null || true)"
      profile="$(_copilot_model_profile_json "$effective" "$catalog" 2>/dev/null || true)"
      [ -n "$profile" ] || { printf '%s' "$explicit"; return 0; }
      role="$explicit"; [ "$role" = opusplan ] && role=opus
      printf '%s' "$profile" | jq -r --arg role "$role" '.[$role] // empty'
      ;;
    default) effective="$(_copilot_effective_model)"; printf '%s' "${effective%%|*}" ;;
    *) printf '%s' "$explicit" ;;
  esac
}

# Resolve the model whose prompt ceiling must govern this Claude process. The
# final --model wins; role aliases are expanded through the same live profile as
# ANTHROPIC_DEFAULT_* so the compact window follows the actual provider id.
_copilot_claude_launch_model() {
  local explicit
  explicit="$(_copilot_claude_model_arg "$@")"
  _copilot_claude_fast_base_model "$explicit"
}

# A settings.local pin outranks process env for keys it contains. Refuse only
# the unsafe case: a persisted window larger than the explicitly launched
# model's live prompt ceiling. A smaller pin merely compacts early.
_copilot_assert_pinned_compact_safe() {
  local model="$1" settings=".claude/settings.local.json" catalog limit pinned
  [ -f "$settings" ] || return 0
  [ -n "$(jq -r '.env.ANTHROPIC_BASE_URL // empty' "$settings" 2>/dev/null)" ] || return 0
  pinned="$(jq -r '.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW // empty' "$settings" 2>/dev/null)"
  case "$pinned" in ''|*[!0-9]*) return 0 ;; esac
  catalog="$(_copilot_model_catalog 2>/dev/null || true)"
  limit="$(_copilot_claude_compact_window "$model" "$catalog" 2>/dev/null)" || return 0
  if [ "$pinned" -gt "$limit" ]; then
    printf '%s\n' "claude-copilot: active copilot-here pin has compact window $pinned, but $model allows $limit." >&2
    printf '%s\n' "  run: copilot-model $(_copilot_strip_context_hint "$model")   (then restart Claude Code)" >&2
    return 1
  fi
}

claude-copilot() {
  local ss="auto" fast=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --fast) fast=1; shift ;;
      --no-specstory) ss="never"; shift ;;
      --specstory) ss="auto"; shift ;;
      -h|--help)
      printf '%s\n' "Usage: claude-copilot [--fast] [--no-specstory] [claude args...]"
      printf '%s\n' "  One-off Claude Code session on the Copilot proxy (no file writes)."
      printf '%s\n' "  --fast selects this session's live-catalog fast sibling; unavailable falls back with a warning."
      printf '%s\n' "  Sticky per-project instead: copilot-here on"
      return 0 ;;
      *) break ;;
    esac
  done

  if _copilot_claude_has_late_fast "$@"; then
    printf '%s\n' "claude-copilot: '--fast' must come before other arguments; refusing to forward it." >&2
    return 2
  fi
  if [ "$fast" -eq 1 ]; then
    local explicit_model base_model fast_model _fast_arg
    for _fast_arg in "$@"; do
      if [ "$_fast_arg" = "--" ]; then
        printf '%s\n' "claude-copilot: --fast cannot be combined with '--' (the resolved --model would become prompt data)." >&2
        return 2
      fi
    done
    if [ -n "${_copilot_resolved_fast_for_once:-}" ]; then
      # claude-copilot-once already resolved/pinned this exact sibling. Reuse it
      # so a catalog/routing TTL boundary cannot make launch disagree with drift.
      fast_model="$_copilot_resolved_fast_for_once"
      base_model="$fast_model"
    elif ! command -v jq >/dev/null 2>&1; then
      printf '%s\n' "claude-copilot: --fast needs jq; using the standard model." >&2
    else
      if ! _copilot_alive; then copilot-proxy start || return 1; fi
      _copilot_require_shim || return 1
      explicit_model="$(_copilot_claude_model_arg "$@")"
      base_model="$(_copilot_claude_fast_base_model "$explicit_model")"
      fast_model="$(_copilot_fast_model_for "$base_model" 2>/dev/null || true)"
    fi
    if [ -n "$fast_model" ]; then
      # Appended last so it overrides an explicit earlier --model while still
      # using that value as the base model whose sibling was resolved.
      set -- "$@" --model "$fast_model"
      printf '%s\n' "claude-copilot: --fast -> $fast_model (session only)" >&2
    elif command -v jq >/dev/null 2>&1; then
      printf '%s\n' "claude-copilot: --fast unavailable for ${base_model:-the selected model}; using the standard model." >&2
    fi
  fi
  (
    local launch_model
    launch_model="$(_copilot_claude_launch_model "$@")" || exit 1
    _copilot_assert_pinned_compact_safe "$launch_model" || exit 1
    COPILOT_CLAUDE_MODEL="$launch_model"
    export COPILOT_CLAUDE_MODEL

    _copilot_model_guard_begin || exit 1
    trap '_copilot_model_guard_restore' EXIT

    if [ "$ss" = "auto" ] && command -v specstory >/dev/null 2>&1; then
      # Always rebuild the complete command, including zero-argument sessions.
      # Otherwise a custom bare claude_cmd prompts at zero args while the same
      # wrapper with --resume gets bypass — the pitfall this block exists to fix.
      local _cc_cmd _cc_arg
      _cc_cmd="$(_copilot_specstory_claude_cmd)"
      if _copilot_claude_has_nonbypass_permission_flag "$@"; then
        _cc_cmd="$(_copilot_claude_drop_bypass_token "$_cc_cmd")"
      elif ! _copilot_claude_has_permission_flag "$@" \
           && [ "$_cc_cmd" != 'claude --dangerously-skip-permissions' ]; then
        # Assert the wrapper's unattended posture independently of a custom
        # SpecStory command, matching Windows. Arbitrary command text is never
        # rewritten; an existing non-seeded bypass may be duplicated harmlessly.
        _cc_cmd="$_cc_cmd --dangerously-skip-permissions"
      fi
      for _cc_arg in "$@"; do
        _cc_cmd="$_cc_cmd $(_copilot_shquote "$_cc_arg")"
      done
      copilot-run specstory run claude -c "$_cc_cmd"
    else
      # Same permission posture as the specstory path, which gets it from
      # `claude_cmd` in specstory's config. Placed BEFORE "$@" so an explicit
      # user flag still wins inside claude's own parser.
      if _copilot_claude_has_permission_flag "$@"; then
        copilot-run claude "$@"
      else
        copilot-run claude --dangerously-skip-permissions "$@"
      fi
    fi
  )
}

# --- per-project toggle (Layer 2: sticky, gitignored settings.local.json) --------

# Env keys we own in .claude/settings.local.json (kept in one place so `off`
# removes exactly what `on` added — including the COPILOT_PROXY_QUIET extras,
# regardless of the knob's value at `off` time).
_copilot_here_keys='["ANTHROPIC_BASE_URL","ANTHROPIC_AUTH_TOKEN","ANTHROPIC_MODEL","ANTHROPIC_DEFAULT_FABLE_MODEL","ANTHROPIC_DEFAULT_OPUS_MODEL","ANTHROPIC_DEFAULT_SONNET_MODEL","ANTHROPIC_DEFAULT_HAIKU_MODEL","ANTHROPIC_SMALL_FAST_MODEL","CLAUDE_CODE_AUTO_COMPACT_WINDOW","CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC","CLAUDE_CODE_ATTRIBUTION_HEADER","CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION","CLAUDE_CODE_ENABLE_AWAY_SUMMARY","DISABLE_NON_ESSENTIAL_MODEL_CALLS"]'

# The EXACT env object `copilot-here on` would write right now, as JSON.
#
# SINGLE SOURCE OF TRUTH for both `copilot-here on` (what it merges in) and
# _copilot_here_drift (what it compares against). These were two hand-maintained
# copies and they had already diverged: `on` wrote 8 keys while the drift check
# compared only 4, so a pin written by an older `on` — current models but no
# ANTHROPIC_DEFAULT_HAIKU_MODEL / ANTHROPIC_SMALL_FAST_MODEL /
# CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC — reported "no drift" while `on`
# would still have changed it. Add a key here and BOTH sides follow.
#
# `--live` (first arg) resolves ANTHROPIC_BASE_URL with _copilot_client_base —
# what THIS process should talk to right now — instead of the _copilot_pinned_base
# a settings file records. copilot-run passes it; the two on-disk callers don't.
# The Windows port spells the same switch `-Pinned`, opted in from the other side.
#
# Needs jq; every caller already requires it.
_copilot_env_json_for_model() {
  local base_fn=_copilot_pinned_base
  if [ "${1:-}" = "--live" ]; then base_fn=_copilot_client_base; shift; fi
  local selected="$1" catalog="${2:-}" profile compact='' compact_rc=0
  if [ "$#" -lt 2 ]; then catalog="$(_copilot_model_catalog 2>/dev/null || true)"; fi
  profile="$(_copilot_model_profile_json "$selected" "$catalog")" || return 1
  compact="$(_copilot_claude_compact_window "$selected" "$catalog")" || compact_rc=$?
  if [ "$compact_rc" -eq 3 ]; then
    printf '%s\n' "copilot-proxy: $(_copilot_strip_context_hint "$selected") has a prompt ceiling below Claude Code's 100000-token minimum" >&2
    return 1
  elif [ "$compact_rc" -ne 0 ]; then
    printf '%s\n' "copilot-proxy: compact ceiling unavailable for $(_copilot_strip_context_hint "$selected"); Claude Code will use its built-in assumption" >&2
    compact=''
  fi
  jq -n \
    --arg base_url "$("$base_fn")" \
    --argjson profile "$profile" \
    --arg compact "$compact" \
    --arg quiet "${COPILOT_PROXY_QUIET:-0}" '
    {
      ANTHROPIC_BASE_URL: $base_url,
      ANTHROPIC_AUTH_TOKEN: "dummy",
      ANTHROPIC_MODEL: $profile.main,
      ANTHROPIC_DEFAULT_FABLE_MODEL: $profile.fable,
      ANTHROPIC_DEFAULT_OPUS_MODEL: $profile.opus,
      ANTHROPIC_DEFAULT_SONNET_MODEL: $profile.sonnet,
      ANTHROPIC_DEFAULT_HAIKU_MODEL: $profile.haiku,
      ANTHROPIC_SMALL_FAST_MODEL: $profile.haiku,
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1"
    } + (if $compact != "" then {
      CLAUDE_CODE_AUTO_COMPACT_WINDOW: $compact
    } else {} end) + (if $quiet == "1" then {
      CLAUDE_CODE_ATTRIBUTION_HEADER: "0",
      CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION: "false",
      CLAUDE_CODE_ENABLE_AWAY_SUMMARY: "0",
      DISABLE_NON_ESSENTIAL_MODEL_CALLS: "1"
    } else {} end)'
}

_copilot_env_json() {
  _copilot_env_json_for_model "$(_copilot_default_model)"
}

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
      local base_url model want_env old_model old_compact has_compact requested_model="${2:-}"
      if [ -n "$requested_model" ]; then
        want_env="$(_copilot_env_json_for_model "$requested_model")" || return 1
      else
        want_env="$(_copilot_env_json)" || return 1
      fi
      base_url="$(printf '%s' "$want_env" | jq -r '.ANTHROPIC_BASE_URL')"
      model="$(printf '%s' "$want_env" | jq -r '.ANTHROPIC_MODEL')"
      old_model="$(printf '%s' "$base" | jq -r '.env.ANTHROPIC_MODEL // empty' 2>/dev/null)"
      old_compact="$(printf '%s' "$base" | jq -r '.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW // empty' 2>/dev/null)"
      has_compact="$(printf '%s' "$want_env" | jq -r 'has("CLAUDE_CODE_AUTO_COMPACT_WINDOW")')"
      local tmp; tmp="$(command mktemp "${TMPDIR:-/tmp}/copilot-here.XXXXXX")" || return 1
      if printf '%s' "$base" | jq --argjson want "$want_env" \
          --arg old_model "$old_model" --arg new_model "$model" --arg has_compact "$has_compact" '
          .env = ((.env // {}) + $want)
          | if $has_compact == "false" and (($old_model | sub("\\[1m\\]$"; "")) != ($new_model | sub("\\[1m\\]$"; "")))
            then del(.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW) else . end' >"$tmp"; then
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
      printf '%s\n' "copilot-here: ON — $settings pins Claude Code to $base_url (model: $model)"
      if [ "$has_compact" = "true" ]; then
        printf '%s\n' "  compact window: $(printf '%s' "$want_env" | jq -r '.CLAUDE_CODE_AUTO_COMPACT_WINDOW') tokens (live model metadata)"
      elif [ -n "$old_compact" ] && [ "$(_copilot_strip_context_hint "$old_model")" = "$(_copilot_strip_context_hint "$model")" ]; then
        printf '%s\n' "  ⚠ compact window: $old_compact tokens (last-known; live metadata unavailable)"
      else
        printf '%s\n' "  ⚠ compact window not pinned; refresh with 'copilot-here on' when the proxy is available"
      fi
      printf '%s\n' "  plain \`claude\` in this project now uses the proxy (restart any running session)"
      _copilot_alive || printf '%s\n' "  ⚠ proxy not running — start it with: copilot-proxy start"
      ;;
    off)
      if [ ! -f "$settings" ]; then
        _copilot_clean_stale_user_model || return 1
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
        _copilot_clean_stale_user_model || return 1
        printf '%s\n' "  plain \`claude\` is back on the real Anthropic backend (restart any running session)"
      else
        command rm -f -- "$tmp"
        printf '%s\n' "copilot-here: jq failed; $settings unchanged" >&2
        return 1
      fi
      ;;
    status)
      local _status_rc=0
      if [ -f "$settings" ] && [ "$(jq -r '.env.ANTHROPIC_BASE_URL // empty' "$settings" 2>/dev/null)" != "" ]; then
        printf '%s\n' "copilot-here: ON  (base: $(jq -r '.env.ANTHROPIC_BASE_URL' "$settings"), model: $(jq -r '.env.ANTHROPIC_MODEL // "(unset)"' "$settings"))"
        printf '%s\n' "  compact window: $(jq -r '.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW // "unverified"' "$settings")"
        local _drift; _drift="$(_copilot_here_drift)"
        [ -n "$_drift" ] && { printf '%s\n' "  ⚠ stale vs current defaults:"; printf '%s\n' "$_drift"; printf '%s\n' "  refresh in place: copilot-here on"; }
        _copilot_alive || printf '%s\n' "  ⚠ proxy not running — start it with: copilot-proxy start"
      else
        printf '%s\n' "copilot-here: off  (enable: copilot-here on; one-off: claude-copilot)"
        _status_rc=1
      fi
      _copilot_claude_launch_report
      return "$_status_rc"
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
      printf '%s\n' "Usage: claude-copilot-once [--fast] [--no-specstory] [claude args...]"
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

  # The model this launch will actually use. Computed BEFORE the pinned/unpinned
  # split so both branches agree: the drift check below has to compare the pin
  # against what --fast is about to ask for, not against the global default.
  # Leading options only, matching claude-copilot's own parser — a bare --fast
  # buried in a prompt string (`-p "...--fast..."`) must not count.
  local _cco_explicit _cco_model='' _cco_arg _cco_fast=0 _cco_fast_model=''
  for _cco_arg in "$@"; do
    case "$_cco_arg" in
      --fast) _cco_fast=1 ;;
      --no-specstory|--specstory) ;;
      *) break ;;
    esac
  done
  if [ "$_cco_fast" -eq 1 ]; then
    for _cco_arg in "$@"; do
      if [ "$_cco_arg" = "--" ]; then
        printf '%s\n' "claude-copilot-once: --fast cannot be combined with '--' (the resolved --model would become prompt data)." >&2
        return 2
      fi
    done
  fi
  if _copilot_claude_has_late_fast "$@"; then
    printf '%s\n' "claude-copilot-once: '--fast' must come before other arguments; refusing to forward it." >&2
    printf '%s\n' "  try:  claude-copilot-once --fast $*" >&2
    return 2
  fi
  if [ "$_cco_fast" -eq 1 ]; then _copilot_require_shim || return 1; fi
  _cco_explicit="$(_copilot_claude_model_arg "$@")"
  if [ -n "$_cco_explicit" ] || [ "$_cco_fast" -eq 1 ]; then
    _cco_model="$(_copilot_claude_fast_base_model "$_cco_explicit")"
    if [ "$_cco_fast" -eq 1 ]; then
      # Idempotent on an id that is already a fast sibling, so re-running
      # --fast against a fast pin resolves to that same pin (no drift).
      _cco_fast_model="$(_copilot_fast_model_for "$_cco_model" 2>/dev/null || true)"
      [ -n "$_cco_fast_model" ] && _cco_model="$_cco_fast_model"
    fi
  fi

  if [ "$_cco_was_on" = "0" ]; then
    if [ -n "$_cco_model" ]; then
      copilot-here on "$_cco_model" || return 1
    else
      copilot-here on || return 1
    fi
    # Auto-unpin even on Ctrl-C / kill. Mirror tmux_status_run's INT/TERM/HUP
    # trap + explicit normal-path cleanup; a bare function-scope EXIT trap would
    # fire on the wrong event when bash sources this file.
    trap '_copilot_once_trap' INT TERM HUP
  else
    # Already pinned here. If the pin drifted from current defaults (model bump,
    # proxy moved), offer to refresh it in place; otherwise leave it untouched.
    # Either way it was already ON, so it stays ON on exit (no revert, no trap).
    local _drift; _drift="$(_copilot_here_drift "$_cco_model")"
    if [ -n "$_drift" ]; then
      printf '%s\n' "claude-copilot-once: this project's copilot-here pin looks stale:" >&2
      printf '%s\n' "$_drift" >&2
      if _copilot_confirm "  override with current defaults? (keep = default) [y/N]"; then
        if [ -n "$_cco_model" ]; then
          copilot-here on "$_cco_model" || return 1
        else
          copilot-here on || return 1
        fi
      else
        printf '%s\n' "claude-copilot-once: kept the existing pin (stays ON on exit)." >&2
        if [ "$_cco_fast" -eq 1 ]; then
          # settings.local.json outranks process env for the keys it holds, so
          # --fast can only move the main model this session.
          printf '%s\n' "  --fast still applies to the session's main model, but the pinned" >&2
          printf '%s\n' "  ANTHROPIC_DEFAULT_* role models stay on the non-fast ids." >&2
        fi
      fi
    else
      printf '%s\n' "claude-copilot-once: copilot-here already ON here — leaving the pin in place on exit."
    fi
  fi

  # 3. One session — specstory-wrapped + arg passthrough (reuses claude-copilot).
  # Pass the already-resolved fast id through one internal, session-only env so
  # the inner wrapper does not re-query catalog/routing and race the pin decision.
  # Bash and zsh both dynamically scope locals into called shell functions.
  # This avoids an ambient/exported env knob that could override an unrelated
  # direct claude-copilot --fast invocation.
  local _copilot_resolved_fast_for_once=''
  if [ "$_cco_fast" -eq 1 ] && [ -n "$_cco_fast_model" ]; then
    _copilot_resolved_fast_for_once="$_cco_fast_model"
  fi
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
# write now (default model bumped, proxy port/shim moved, a key added since the
# pin was written)? Prints one "KEY : old -> new" line per drifted key to stdout;
# exit 0 = stale (drift printed), 1 = up-to-date or not pinned. `copilot-here on`
# re-merges exactly these keys, so refreshing a stale pin is just running it again.
#
# Drift is defined as "the set of keys `copilot-here on` would actually CHANGE",
# computed by diffing the live file against _copilot_env_json — not a hand-picked
# subset (that is how three keys silently went unchecked). Note the asymmetry is
# deliberate: keys present in the file but absent from the want-set are NOT drift,
# because `on` merges and never removes them (only `off` does).
# Drift of THIS project's pin against what a launch would want right now.
# $1 (optional) = the model that launch will actually use. Without it the
# want-side is the global default, which knows nothing about --fast or about the
# pin itself — so a fast pin would always look "stale" against its own sibling.
_copilot_here_drift() {
  local settings=".claude/settings.local.json"
  [ -f "$settings" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  # ANTHROPIC_BASE_URL is only set while the pin is ON — absent → nothing to do.
  [ -n "$(jq -r '.env.ANTHROPIC_BASE_URL // empty' "$settings" 2>/dev/null)" ] || return 1
  local want out
  if [ -n "${1:-}" ]; then
    want="$(_copilot_env_json_for_model "$1")" || return 1
  else
    want="$(_copilot_env_json)" || return 1
  fi
  out="$(jq -r --argjson want "$want" '
    (.env // {}) as $cur
    | [ $want
        | to_entries[]
        | select($cur[.key] != .value)
        | "  \(.key) : \($cur[.key] // "(unset)") -> \(.value)" ]
    | .[]' "$settings" 2>/dev/null)"
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
  return 0
}

# --- model switcher -------------------------------------------------------------

# The live model catalog is the SSOT for ids, aliases and context limits. Keep
# this separate from _copilot_served_models: doctor wants ids + aliases, while
# role selection wants each raw id's capability metadata.
_copilot_model_catalog() {
  command curl -fsS --max-time 5 "$(_copilot_base)/v1/models" 2>/dev/null
}

_copilot_catalog_valid() {
  command -v jq >/dev/null 2>&1 || return 1
  jq -e '(.data | type) == "array"' >/dev/null 2>&1
}

_copilot_catalog_ids() {
  if command -v jq >/dev/null 2>&1; then
    jq -r '.data[]?.id // empty' 2>/dev/null | command sort -u
  else
    command grep -o '"id":"[^"]*"' | command sed 's/"id":"//;s/"//' | command sort -u
  fi
}

# The entitlement floor is an explicitly selected/persisted model, never the
# built-in fallback (which may itself be unavailable on a lower plan).
_copilot_entitlement_baseline_model() {
  local settings='.claude/settings.local.json' state pinned=''
  if [ -f "$settings" ] && command -v jq >/dev/null 2>&1 \
     && [ -n "$(jq -r '.env.ANTHROPIC_BASE_URL // empty' "$settings" 2>/dev/null)" ]; then
    pinned="$(jq -r '.env.ANTHROPIC_MODEL // empty' "$settings" 2>/dev/null)"
    if [ -n "$pinned" ]; then printf '%s' "$pinned"; return 0; fi
  fi
  if [ -n "${COPILOT_CLAUDE_MODEL:-}" ]; then
    printf '%s' "$COPILOT_CLAUDE_MODEL"
  else
    state="$(_copilot_model_state)"
    [ -f "$state" ] && command head -n 1 "$state"
  fi
}

# Selectable ids whose advertised plan set is no narrower than the baseline.
# If no explicit baseline exists, require the broadest restriction set found in
# this catalog (or an unrestricted entry). This does not claim restricted_to is
# perfect entitlement proof; it prevents auto from knowingly widening beyond a
# model the user already selected, while manual model ids remain unrestricted.
_copilot_auto_candidate_ids() {
  local baseline
  baseline="$(_copilot_strip_context_hint "${1:-}")"
  command -v jq >/dev/null 2>&1 || return 1
  jq -r --arg current "$baseline" '
    def eligible:
      select((.policy.state // "enabled") != "disabled")
      | select(.model_picker_enabled != false)
      | select((.capabilities.type // "chat") != "embeddings");
    def plans: (.billing.restricted_to // []);
    [.data[]? | eligible] as $served
    | [$served[] | select(((.id // "") | endswith("-fast")) | not)] as $all
    | ($all | map(plans) | add // [] | unique) as $universe
    | (first($served[] | select(.id == $current) | plans) // null) as $cur
    | (if $cur == null or ($cur | length) == 0 then $universe else $cur end) as $need
    | $all[]
    | (plans) as $have
    | select(($have | length) == 0
             or all($need[]; . as $p | $have | index($p) != null))
    | .id' 2>/dev/null | command sort -u
}

# The catalog rows a *derived* selection may consider. Mirrors the Windows
# Get-CopilotSelectableModelIds predicate: no disabled policy, nothing the model
# picker hides, no embeddings. Deliberately NOT applied to `-l`, `-L/--details`,
# `--json` or manual id resolution — diagnostics must show everything, and
# pinning a non-picker model by name has to stay possible.
_copilot_selectable_ids() {
  command -v jq >/dev/null 2>&1 || { _copilot_catalog_ids; return; }
  jq -r '
    .data[]?
    | select((.policy.state // "enabled") != "disabled")
    | select(.model_picker_enabled != false)
    | select((.capabilities.type // "chat") != "embeddings")
    | .id // empty' 2>/dev/null | command sort -u
}

# Capability-tier rows for the ranker, "TIER<TAB>ID", best tier = 3.
#
# `model_picker_category` is Copilot's own tier taxonomy and it lines up exactly
# with OpenAI's *durable* capability tiers — Sol and Astra are `powerful`, Terra
# is `versatile`, Luna is `lightweight`. That matters because generation and
# tier advance independently: gpt-6-astra is the gen-6 flagship while Terra and
# Luna stayed on 5.6, so "higher version wins" would happily promote a future
# gpt-6-luna over gpt-5.6-sol. Ranking on the tier first is what makes that
# impossible. It also tiers grok/gemini/mai, which we keep no allowlist for.
#
# `-fast` siblings are excluded by name, not by the picker predicate: they are
# picker-enabled AND inherit their standard sibling's category (gpt-5.6-sol-fast
# is `powerful`), so a tier-only rank would happily pin one as the main model.
#
# An older fork that does not surface the field emits no rows at all, which
# makes the pre-pass a silent no-op and leaves the historical ranker untouched.
_copilot_tier_rows() {
  command -v jq >/dev/null 2>&1 || return 0
  jq -r '
    .data[]?
    | select((.policy.state // "enabled") != "disabled")
    | select(.model_picker_enabled != false)
    | select((.capabilities.type // "chat") != "embeddings")
    | select(((.id // "") | endswith("-fast")) | not)
    | (.model_picker_category // "") as $c
    | (if   $c == "powerful"    then 3
       elif $c == "versatile"   then 2
       elif $c == "lightweight" then 1
       else 0 end) as $t
    | select($t > 0)
    | "\($t)\t\(.id)"' 2>/dev/null
}

# Generation of a model id, as a `sort -V`-comparable string. Only the leading
# numeric run counts, so the tier codename never leaks into the comparison:
# gpt-6-astra and gpt-6-nova are both "6" (same generation, so neither is
# "newer"), gpt-5.6-sol is "5.6", claude-opus-4-8 is "4.8". Digit-dash-digit is
# normalised to a dot first, because Anthropic spells minor versions with `-`.
_copilot_model_version() {
  local tail
  case "$1" in
    gpt-*) tail="${1#gpt-}" ;;
    o[0-9]*) tail="${1#o}" ;;
    gemini-*) tail="${1#gemini-}" ;;
    grok-*) tail="${1#grok-}" ;;
    mai-code-*) tail="${1#mai-code-}" ;;
    claude-fable-*) tail="${1#claude-fable-}" ;;
    claude-opus-*) tail="${1#claude-opus-}" ;;
    claude-sonnet-*) tail="${1#claude-sonnet-}" ;;
    claude-haiku-*) tail="${1#claude-haiku-}" ;;
    *) return 1 ;;
  esac
  # Only a numeric run at the START of the recognized generation slot counts.
  # gpt-oss-120b therefore has no generation; it is not "GPT-120".
  printf '%s' "$tail" \
    | command sed -En 's/^([0-9]+([.-][0-9]+)*).*/\1/p' \
    | command tr '-' '.'
}

# Intersect catalog-derived rows on stdin with a newline-separated candidate
# list. Rankers accept both on purpose (catalog supplies metadata; stdin scopes
# eligibility), so neither source may silently widen the other.
_copilot_tier_rows_for_ids() {
  local ids="$1"
  {
    printf '%s\n' "$ids"
    printf '%s\n' '__COPILOT_TIER_ROWS__'
    command cat
  } | command awk -F'\t' '
    $0 == "__COPILOT_TIER_ROWS__" { rows=1; next }
    !rows { ids[$0]=1; next }
    ids[$2] { print }'
}

# Newest id on stdin by recognized generation first, full id second. IDs with
# no generation (for example grok-code-fast-1) sort below grok-4.6 instead of
# winning merely because "code" is lexically after "4".
_copilot_latest_model() {
  local id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    printf '%s\t%s\n' "$(_copilot_model_version "$id" 2>/dev/null || true)" "$id"
  done | command sort -t"$(printf '\t')" -k1,1V -k2,2V \
    | command tail -1 | command cut -f2-
}

# Best id matching an ERE among tier rows on stdin: highest tier first, then the
# version-greatest id inside that tier. `sort -V`, never plain `sort`, so
# gpt-10-x beats gpt-9-x and claude-opus-4-10 beats claude-opus-4-8.
_copilot_tier_best() {
  local rows top
  rows="$(command awk -F'\t' -v re="$1" '$2 ~ re' 2>/dev/null)"
  [ -n "$rows" ] || return 1
  top="$(printf '%s\n' "$rows" | command cut -f1 | command sort -n | command tail -1)"
  [ -n "$top" ] || return 1
  printf '%s\n' "$rows" | command awk -F'\t' -v t="$top" '$1==t{print $2}' \
    | while IFS= read -r id; do
        printf '%s\t%s\n' "$(_copilot_model_version "$id")" "$id"
      done \
    | command sort -t"$(printf '\t')" -k1,1V -k2,2V \
    | command tail -1 | command cut -f2-
}

# Tier ordering is safe only when EVERY scoped id in that vendor has a row.
# Partial metadata must degrade to the curated/lexical fallback: otherwise a
# lightweight new id with metadata can outrank a known flagship whose category
# happens to be absent in an older/mixed catalog.
_copilot_tier_best_complete() {
  local re="$1" rows="$2" models="$3" candidates covered
  candidates="$(printf '%s\n' "$models" | command grep -E "$re" || true)"
  [ -n "$candidates" ] || return 1
  covered="$(printf '%s\n' "$rows" | command awk -F'\t' -v re="$re" '$2 ~ re {print $2}')"
  [ "$(printf '%s\n' "$candidates" | command sort -u)" =     "$(printf '%s\n' "$covered" | command sort -u)" ] || return 1
  printf '%s\n' "$rows" | _copilot_tier_best "$re"
}

# Tier pre-pass for one vendor arm. $1=ERE $2=tier rows $3=served ids $4..=that
# arm's allowlist. Prints the winner, or nothing when the allowlist should own
# the decision. Set COPILOT_MODEL_EXPLAIN=1 to trace on fd 2.
_copilot_tier_prepass() {
  local re="$1" rows="$2" served="$3" pick known top_known newest pick_v known_v pick_tier known_tier
  shift 3
  [ -n "$rows" ] || return 1
  pick="$(_copilot_tier_best_complete "$re" "$rows" "$served")" || return 1
  [ -n "$pick" ] || return 1

  # An id we curate by name is never promoted here — the allowlist loop that
  # follows owns it. That is precisely what keeps the allowlist an override:
  # demote a model by moving it down the list, promote it by moving it up.
  for known in "$@"; do
    if [ "$pick" = "$known" ]; then
      [ -n "${COPILOT_MODEL_EXPLAIN:-}" ] && \
        printf '  %-12s : top tier -> %s, which the allowlist owns -> allowlist wins\n' \
          "$re" "$pick" >&2
      return 1
    fi
  done

  # Only beat the curated set when genuinely newer than the best allowlisted id
  # actually being served, so an unknown same-generation sibling cannot displace
  # a vetted pick.
  top_known=''
  pick_tier="$(printf '%s\n' "$rows" | command awk -F'\t' -v id="$pick" '$2==id{print $1; exit}')"
  for known in "$@"; do
    known_tier="$(printf '%s\n' "$rows" | command awk -F'\t' -v id="$known" '$2==id{print $1; exit}')"
    if [ "$known_tier" = "$pick_tier" ] \
       && printf '%s\n' "$served" | command grep -qxF "$known"; then
      if [ -z "$top_known" ]; then
        top_known="$known"
      else
        top_known="$(printf '%s\n%s\n' "$top_known" "$known" | command sort -V | command tail -1)"
      fi
    fi
  done
  if [ -n "$top_known" ]; then
    # Compare GENERATIONS, not ids: `sort -V` breaks a numeric tie alphabetically,
    # so an unknown same-generation sibling (gpt-6-nova next to an allowlisted
    # gpt-6-astra) would otherwise win purely on its codename.
    pick_v="$(_copilot_model_version "$pick")"
    known_v="$(_copilot_model_version "$top_known")"
    newest="$(printf '%s\n%s\n' "$pick_v" "$known_v" | command sort -V | command tail -1)"
    if [ -z "$pick_v" ] || [ "$pick_v" = "$known_v" ] || [ "$newest" != "$pick_v" ]; then
      [ -n "${COPILOT_MODEL_EXPLAIN:-}" ] && \
        printf '  %-12s : top tier -> %s (gen %s), not newer than served %s (gen %s) -> allowlist wins\n' \
          "$re" "$pick" "${pick_v:-?}" "$top_known" "${known_v:-?}" >&2
      return 1
    fi
  fi

  [ -n "${COPILOT_MODEL_EXPLAIN:-}" ] && \
    printf '  %-12s : top tier -> %s (newer than served %s) -> pre-pass wins\n' \
      "$re" "$pick" "${top_known:-<none>}" >&2
  printf '%s' "$pick"
}

_copilot_strip_context_hint() {
  printf '%s' "${1%\[1m\]}"
}

# Claude Code exposes one process-wide auto-compact capacity, separate from the
# [1m] model hint used for its HUD/full context classification. Feed it the
# provider's real prompt ceiling so its own default ~95% trigger fires before
# Copilot rejects the request. Exit 2 = unavailable; 3 = known but below
# Claude Code's configurable 100k minimum (unsafe to round upward).
_copilot_claude_compact_window() {
  local requested="${1:-}" catalog="${2:-}" raw value
  [ -n "$requested" ] || return 2
  raw="$(_copilot_strip_context_hint "$requested")"
  if [ "$#" -lt 2 ]; then catalog="$(_copilot_model_catalog 2>/dev/null || true)"; fi
  [ -n "$catalog" ] && command -v jq >/dev/null 2>&1 || return 2
  value="$(printf '%s' "$catalog" | jq -r --arg id "$raw" '
    def number_or_null:
      if type == "number" then .
      elif type == "string" then (tonumber? // null)
      else null end;
    first(.data[]? | select(.id == $id) | .capabilities.limits) as $limits
    | if $limits == null then empty
      else ($limits.max_prompt_tokens | number_or_null) as $prompt
      | ($limits.max_context_window_tokens | number_or_null) as $context
      | ($limits.max_output_tokens | number_or_null) as $output
      | if $prompt != null then ($prompt | floor)
        elif $context != null and $output != null and $context > $output
        then (($context - $output) | floor)
        else empty end
      end
  ' 2>/dev/null)"
  case "$value" in ''|*[!0-9]*) return 2 ;; esac
  [ "$value" -ge 100000 ] || return 3
  if [ "$value" -gt 1000000 ]; then value=1000000; fi
  printf '%s' "$value"
}

# Convert a raw proxy id to the spelling Claude Code should receive. A live
# max_context_window_tokens >= 1M earns [1m]; if the proxy is down, preserve an
# explicitly stored suffix but do not invent one. Raw API clients never use this.
_copilot_model_for_claude() {
  local requested="${1:-}" catalog="${2:-}" raw had_hint=0 context=''
  [ -n "$requested" ] || return 1
  case "$requested" in *"[1m]") had_hint=1 ;; esac
  raw="$(_copilot_strip_context_hint "$requested")"
  if [ "$#" -lt 2 ]; then catalog="$(_copilot_model_catalog 2>/dev/null || true)"; fi
  if [ -n "$catalog" ] && command -v jq >/dev/null 2>&1; then
    context="$(printf '%s' "$catalog" | jq -r --arg id "$raw" '
      first(.data[]? | select(.id == $id) | .capabilities.limits.max_context_window_tokens) // empty
    ' 2>/dev/null)"
    case "$context" in
      ''|*[!0-9]*) printf '%s' "$raw" ;;
      *) if [ "$context" -ge 1000000 ]; then printf '%s[1m]' "$raw"; else printf '%s' "$raw"; fi ;;
    esac
  elif [ "$had_hint" -eq 1 ]; then
    printf '%s[1m]' "$raw"
  else
    printf '%s' "$raw"
  fi
}

_copilot_first_served() {
  local models="$1" candidate
  shift
  for candidate in "$@"; do
    if printf '%s\n' "$models" | command grep -qxF "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

# Pick the best raw served id for the main Claude Code model. Claude stays the
# first choice when entitled. Without Claude, rank OpenAI by capability tier,
# deliberately placing lightweight Luna behind the older flagship/coding tiers.
# Reads newline-separated raw ids on stdin and prints one raw id.
_copilot_pick_best_model() {
  local models preferred c rows tier remaining_models remaining_rows
  # $1 (optional) = raw catalog JSON. With it, each vendor arm first runs the
  # capability-tier pre-pass so a genuinely newer flagship wins without waiting
  # for someone to hand-edit the allowlist; without it (offline, or a fork too
  # old to report model_picker_category) the historical allowlist + lexical
  # ranker runs unchanged. See _copilot_tier_rows for why tier beats version.
  models="$(command cat | command sed 's/\[1m\]$//' \
    | command grep -vE -- '-fast$' | command sort -u)"
  [ -n "$models" ] || return 1
  rows=''
  [ -n "${1:-}" ] && rows="$(printf '%s' "$1" | _copilot_tier_rows \
    | _copilot_tier_rows_for_ids "$models")"

  tier="$(_copilot_tier_prepass '^claude-' "$rows" "$models" \
    claude-fable-5 \
    claude-opus-5 claude-opus-4-8 claude-opus-4-7 claude-opus-4-6 \
    claude-sonnet-5 claude-sonnet-4-6 claude-sonnet-4-5 \
    claude-opus-4-5 claude-haiku-4-5 || true)"
  if [ -n "$tier" ]; then printf '%s' "$tier"; return 0; fi

  for preferred in \
    claude-fable-5 \
    claude-opus-5 claude-opus-4-8 claude-opus-4-7 claude-opus-4-6 \
    claude-sonnet-5 claude-sonnet-4-6 claude-sonnet-4-5 \
    claude-opus-4-5 claude-haiku-4-5
  do
    if printf '%s\n' "$models" | command grep -qxF "$preferred"; then
      printf '%s' "$preferred"
      return 0
    fi
  done
  c="$(printf '%s\n' "$models" | command grep -E '^claude-' | command sort -V | command tail -1)"
  if [ -n "$c" ]; then printf '%s' "$c"; return 0; fi

  tier="$(_copilot_tier_prepass '^(gpt-|o[0-9])' "$rows" "$models" \
    gpt-6-astra gpt-5.6-sol gpt-5.6-terra gpt-5.5 gpt-5.4 gpt-5.3-codex \
    gpt-5.6-luna gpt-5.4-mini gpt-5-mini || true)"
  if [ -n "$tier" ]; then printf '%s' "$tier"; return 0; fi

  for preferred in \
    gpt-6-astra gpt-5.6-sol gpt-5.6-terra gpt-5.5 gpt-5.4 gpt-5.3-codex \
    gpt-5.6-luna gpt-5.4-mini gpt-5-mini
  do
    if printf '%s\n' "$models" | command grep -qxF "$preferred"; then
      printf '%s' "$preferred"
      return 0
    fi
  done

  c="$(printf '%s\n' "$models" | command grep -E '^(gpt-|o[0-9])' | command grep -viE 'mini|nano|luna|-fast$' \
        | command sort -V | command tail -1)"
  if [ -n "$c" ]; then printf '%s' "$c"; return 0; fi
  c="$(printf '%s\n' "$models" | command grep -iE 'codex' | command sort -V | command tail -1)"
  if [ -n "$c" ]; then printf '%s' "$c"; return 0; fi
  c="$(printf '%s\n' "$models" | command grep -E '^(gpt-|o[0-9])' | command sort -V | command tail -1)"
  if [ -n "$c" ]; then printf '%s' "$c"; return 0; fi

  # xAI. No allowlist on purpose — grok bumps versions faster than we can track,
  # and the tier rows already rank it correctly when the catalog is available.
  tier="$(_copilot_tier_best_complete '^grok-' "$rows" "$models" || true)"
  if [ -n "$tier" ]; then printf '%s' "$tier"; return 0; fi
  c="$(printf '%s\n' "$models" | command grep -E '^grok-' | command grep -viE 'mini|nano|lite|-fast$' \
        | _copilot_latest_model)"
  if [ -n "$c" ]; then printf '%s' "$c"; return 0; fi
  c="$(printf '%s\n' "$models" | command grep -E '^grok-' | _copilot_latest_model)"
  if [ -n "$c" ]; then printf '%s' "$c"; return 0; fi

  tier="$(_copilot_tier_best_complete '^gemini-' "$rows" "$models" 2>/dev/null || true)"
  if [ -n "$tier" ]; then printf '%s' "$tier"; return 0; fi
  c="$(printf '%s\n' "$models" | command grep -E '^gemini-' | command grep -viE 'flash' \
        | command sort -V | command tail -1)"
  if [ -n "$c" ]; then printf '%s' "$c"; return 0; fi
  c="$(printf '%s\n' "$models" | command grep -E '^gemini-' | command sort -V | command tail -1)"
  if [ -n "$c" ]; then printf '%s' "$c"; return 0; fi

  # Any remaining vendor (for example MAI) still gets its catalog tier before
  # the offline lexical catch-all. Known vendor rows are excluded because their
  # ordering above is deliberate and must not be interleaved here.
  remaining_models="$(printf '%s\n' "$models" | command grep -vE '^(claude|gpt|grok|gemini)-' || true)"
  remaining_rows="$(printf '%s\n' "$rows" \
    | command awk -F'\t' '$2 !~ /^(claude|gpt|grok|gemini)-/')"
  tier="$(_copilot_tier_best_complete '.*' "$remaining_rows" "$remaining_models" 2>/dev/null || true)"
  if [ -n "$tier" ]; then printf '%s' "$tier"; return 0; fi
  printf '%s\n' "$models" | command sort -V | command tail -1
}

# Build the full Claude Code role profile for one selected main model. Native
# Claude profiles use the strongest served model in each Claude family. OpenAI
# profiles map quality/balanced/fast roles to Sol/Terra/Luna, with every role
# falling back to the selected main rather than an unserved hard-coded id.
_copilot_model_profile_json() {
  command -v jq >/dev/null 2>&1 || return 1
  local selected="${1:-$(_copilot_default_model)}" catalog="${2:-}" models raw main
  local fable_raw opus_raw sonnet_raw haiku_raw grok_rows
  if [ "$#" -lt 2 ]; then catalog="$(_copilot_model_catalog 2>/dev/null || true)"; fi
  # Derived role models go through the picker predicate (Windows parity with
  # Get-CopilotModelProfile); an explicitly named model is still honoured above.
  if [ -n "$catalog" ]; then
    models="$(printf '%s' "$catalog" | _copilot_auto_candidate_ids "$selected")"
  else models=''; fi
  raw="$(_copilot_strip_context_hint "$selected")"
  main="$(_copilot_model_for_claude "$selected" "$catalog")"

  case "$raw" in
    claude-*)
      fable_raw="$(printf '%s\n' "$models" | command grep '^claude-fable-' | _copilot_latest_model)"
      [ -n "$fable_raw" ] || fable_raw="$raw"

      opus_raw="$(printf '%s\n' "$models" | command grep '^claude-opus-' | _copilot_latest_model)"
      [ -n "$opus_raw" ] || opus_raw="$raw"

      sonnet_raw="$(printf '%s\n' "$models" | command grep '^claude-sonnet-' | _copilot_latest_model)"
      [ -n "$sonnet_raw" ] || sonnet_raw="$raw"

      haiku_raw="$(printf '%s\n' "$models" | command grep '^claude-haiku-' | _copilot_latest_model)"
      [ -n "$haiku_raw" ] || haiku_raw="$raw"
      ;;
    gpt-*|o[0-9]*|*codex*)
      fable_raw="$raw"; opus_raw="$raw"
      sonnet_raw="$(_copilot_first_served "$models" gpt-5.6-terra 2>/dev/null || true)"
      [ -n "$sonnet_raw" ] || sonnet_raw="$raw"
      haiku_raw="$(_copilot_first_served "$models" \
        gpt-5.6-luna gpt-5.4-mini gpt-5-mini 2>/dev/null || true)"
      [ -n "$haiku_raw" ] || haiku_raw="$raw"
      ;;
    grok-*)
      # No curated grok roles — derive them from the tier rows instead.
      fable_raw="$raw"; opus_raw="$raw"
      grok_rows="$(printf '%s' "$catalog" | _copilot_tier_rows \
        | _copilot_tier_rows_for_ids "$models")"
      sonnet_raw="$(_copilot_tier_best_complete '^grok-' "$grok_rows" "$models" 2>/dev/null || true)"
      if [ -n "$sonnet_raw" ]; then
        haiku_raw="$(printf '%s\n' "$grok_rows" \
          | command awk -F'\t' '$1==1 && $2 ~ /^grok-/{print $2}' \
          | command sort -V | command tail -1)"
        [ -n "$haiku_raw" ] || haiku_raw="$sonnet_raw"
      else
        sonnet_raw="$raw"; haiku_raw="$raw"
      fi
      ;;
    *)
      fable_raw="$raw"; opus_raw="$raw"; sonnet_raw="$raw"; haiku_raw="$raw"
      ;;
  esac

  jq -n \
    --arg main "$main" \
    --arg fable "$(_copilot_model_for_claude "$fable_raw" "$catalog")" \
    --arg opus "$(_copilot_model_for_claude "$opus_raw" "$catalog")" \
    --arg sonnet "$(_copilot_model_for_claude "$sonnet_raw" "$catalog")" \
    --arg haiku "$(_copilot_model_for_claude "$haiku_raw" "$catalog")" \
    '{main:$main, fable:$fable, opus:$opus, sonnet:$sonnet, haiku:$haiku}'
}

_copilot_print_model_profile() {
  local profile="$1"
  printf '%s' "$profile" | jq -r '
    "  main   : \(.main)",
    "  fable  : \(.fable)",
    "  opus   : \(.opus)",
    "  sonnet : \(.sonnet)",
    "  haiku  : \(.haiku)"
  '
}

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
#   copilot-model --auto           # tier-aware Claude > OpenAI > grok > Gemini
#   copilot-model -l               # list available (live from proxy)
#   copilot-model -c               # print current (+ where it came from)
# Detailed listing for copilot-model. `-l` stays the bare-id, pipeable form
# (and the offline fallback); this is its long sibling. Explicit parameters are
# required: a nested function would leak globally in both Bash and zsh while
# relying on dynamic-scope locals that disappear after copilot-model returns.
# $1 = validated catalog JSON, $2 = current model, $3 = entitlement baseline.
_copilot_model_details() {
  local catalog="$1" current rows auto fast_routing fast_models baseline="${3:-}"
  local id tier price ctx out eff plans state _t mark fast
  current="$(_copilot_strip_context_hint "$2")"
  # One shim request and one jq parse for the whole table, not one per row.
  fast_routing="$(_copilot_fast_routing_json 2>/dev/null || true)"
  fast_models=''
  [ -n "$fast_routing" ] && fast_models="$(printf '%s' "$fast_routing" \
    | jq -r '.mappings | keys[]?' 2>/dev/null || true)"
  auto="$(printf '%s' "$catalog" | _copilot_auto_candidate_ids "$baseline" \
    | _copilot_pick_best_model "$catalog" 2>/dev/null || true)"
  printf '%-2s %-33s %-11s %-9s %7s %6s %-13s %-4s %-11s %s\n' \
    '' ID TIER PRICE CTX OUT EFFORT FAST PLANS STATE
  rows="$(printf '%s' "$catalog" | jq -r '
    def number_or_null:
      if type == "number" then .
      elif type == "string" and test("^[0-9]+$") then tonumber
      else null end;
    def human: number_or_null as $n
      | if $n == null then "-" elif $n >= 1000 then "\(($n/1000|floor))k" else ($n|tostring) end;
    .data[]?
    | (.capabilities.limits // {}) as $l
    | (.capabilities.supports.reasoning_effort // []) as $e
    | [ .id,
        (.model_picker_category // "-"),
        (.model_picker_price_category // "-"),
        ($l.max_context_window_tokens | human),
        ($l.max_output_tokens | human),
        (if ($e | length) == 0 then "-"
         elif ($e | length) == 1 then $e[0]
         else "\($e[0])..\($e[-1])" end),
        ((.billing.restricted_to // []) as $p
         | if ($p | length) == 0 then "all"
           elif ($p | index("free")) then "free+"
           elif ($p | index("pro")) then "pro+"
           elif ($p | index("pro_plus")) then "pro_plus+"
           elif ($p | index("business")) then "business+"
           elif ($p | index("enterprise")) then "enterprise+"
           elif ($p | index("max")) then "max"
           else ($p | join(",")) end),
        (if (.policy.state // "enabled") == "disabled" then "disabled"
         elif .model_picker_enabled == false then "nopick"
         elif .preview == true then "preview"
         else "ok" end),
        (if (.model_picker_category // "") == "powerful" then 3
         elif (.model_picker_category // "") == "versatile" then 2
         elif (.model_picker_category // "") == "lightweight" then 1
         else 0 end) ]
    | @tsv' 2>/dev/null | command sort -t"$(printf '\t')" -k9,9nr -k1,1Vr)" || {
    printf '%s\n' "copilot-model: could not render catalog metadata" >&2
    return 1
  }
  printf '%s\n' "$rows" | while IFS="$(printf '\t')" read -r id tier price ctx out eff plans state _t; do
    [ -n "$id" ] || continue
    mark=''
    [ "$id" = "$current" ] && mark='*'
    [ "$id" = "$auto" ] && mark="$mark->"
    case "$id" in
      *-fast) fast='self' ;;
      *)
        fast='-'
        printf '%s\n' "$fast_models" | command grep -qxF "$id" && fast='yes'
        ;;
    esac
    printf '%-2s %-33s %-11s %-9s %7s %6s %-13s %-4s %-11s %s\n' \
      "$mark" "$id" "$tier" "$price" "$ctx" "$out" "$eff" "$fast" "$plans" "$state"
  done
}

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

  # One catalog fetch feeds list/validation/context metadata/profile mapping.
  local catalog=''

  # List available model ids (live proxy, else a static manual-pick fallback).
  _copilot_model_list() {
    if [ -n "$catalog" ]; then
      printf '%s' "$catalog" | _copilot_catalog_ids
    else
      printf '%s\n' \
        claude-fable-5 \
        claude-opus-5 claude-opus-4-8 claude-opus-4-7 claude-opus-4-6 claude-opus-4-5 \
        claude-sonnet-5 claude-sonnet-4-6 claude-sonnet-4-5 claude-haiku-4-5 \
        gpt-6-astra \
        gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna gpt-5.5 gpt-5.4 gpt-5.3-codex \
        gpt-5.4-mini gpt-5-mini \
        grok-4.6 grok-4.5
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

  local arg="${1:-}" explain_auto=0
  # `--why` alone is a dry run; after `--auto` it explains the same decision
  # and then falls through to the normal write path.
  [ "$arg" = "--auto" ] && [ "${2:-}" = "--why" ] && explain_auto=1
  case "$arg" in
    -l|--list)
      catalog="$(_copilot_model_catalog 2>/dev/null || true)"
      if [ -n "$catalog" ] && ! printf '%s' "$catalog" | _copilot_catalog_valid; then catalog=''; fi
      _copilot_model_list
      return 0 ;;
    -L|--details)
      catalog="$(_copilot_model_catalog 2>/dev/null || true)"
      if [ -z "$catalog" ] || ! printf '%s' "$catalog" | _copilot_catalog_valid; then
        printf '%s\n' "copilot-model: --details needs a reachable proxy and jq" >&2
        return 1
      fi
      _copilot_model_details "$catalog" "$(_copilot_model_current 2>/dev/null || true)" \
        "$(_copilot_entitlement_baseline_model)" || return 1
      return 0 ;;
    --json)
      catalog="$(_copilot_model_catalog 2>/dev/null || true)"
      if [ -z "$catalog" ] || ! printf '%s' "$catalog" | _copilot_catalog_valid; then
        printf '%s\n' "copilot-model: --json needs a reachable proxy and valid JSON catalog" >&2
        return 1
      fi
      printf '%s' "$catalog" | jq . || return 1
      return 0 ;;
    --why)
      # Dry run: explain what --auto WOULD pick, write nothing.
      catalog="$(_copilot_model_catalog 2>/dev/null || true)"
      if [ -z "$catalog" ] || ! printf '%s' "$catalog" | _copilot_catalog_valid; then
        printf '%s\n' "copilot-model: --why needs a reachable proxy and valid JSON catalog" >&2
        return 1
      fi
      local _why_sel _why_pick
      _why_sel="$(printf '%s' "$catalog"         | _copilot_auto_candidate_ids "$(_copilot_entitlement_baseline_model)")"
      if [ -z "$_why_sel" ]; then
        printf '%s\n' "copilot-model: --why found no selectable chat model in the live catalog" >&2
        return 1
      fi
      printf '%s\n' "copilot-model: --auto reasoning (dry run, nothing written)" >&2
      printf '  catalog      : %s models, %s selectable\n' \
        "$(printf '%s' "$catalog" | _copilot_catalog_ids | command wc -l | command tr -d ' ')" \
        "$(printf '%s\n' "$_why_sel" | command wc -l | command tr -d ' ')" >&2
      _why_pick="$(printf '%s\n' "$_why_sel" \
        | COPILOT_MODEL_EXPLAIN=1 _copilot_pick_best_model "$catalog")" || {
        printf '%s\n' "copilot-model: --why could not pick a model" >&2
        return 1
      }
      [ -n "$_why_pick" ] || {
        printf '%s\n' "copilot-model: --why could not pick a model" >&2
        return 1
      }
      printf '  -> %s\n' "$(_copilot_model_for_claude "$_why_pick" "$catalog")" >&2
      return 0 ;;
    -c|--current)
      if [ "$target" = "local" ]; then
        local current_profile
        printf 'model profile (project: %s)\n' "$settings"
        current_profile="$(jq -n --argjson env "$(jq '.env // {}' "$settings")" '{
          main: ($env.ANTHROPIC_MODEL // "(unset)"),
          fable: ($env.ANTHROPIC_DEFAULT_FABLE_MODEL // $env.ANTHROPIC_MODEL // "(unset)"),
          opus: ($env.ANTHROPIC_DEFAULT_OPUS_MODEL // $env.ANTHROPIC_MODEL // "(unset)"),
          sonnet: ($env.ANTHROPIC_DEFAULT_SONNET_MODEL // $env.ANTHROPIC_MODEL // "(unset)"),
          haiku: ($env.ANTHROPIC_DEFAULT_HAIKU_MODEL // $env.ANTHROPIC_MODEL // "(unset)")
        }')"
        _copilot_print_model_profile "$current_profile"
        printf '  compact: %s\n' "$(jq -r '.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW // "unverified"' "$settings")"
      else
        catalog="$(_copilot_model_catalog 2>/dev/null || true)"
        printf 'model profile (global main: %s)\n' "$statef"
        _copilot_print_model_profile "$(_copilot_model_profile_json "$(_copilot_model_current)" "$catalog")"
        local current_compact=''
        current_compact="$(_copilot_claude_compact_window "$(_copilot_model_current)" "$catalog" 2>/dev/null || true)"
        printf '  compact: %s\n' "${current_compact:-unverified}"
      fi
      return 0 ;;
    -h|--help)
      printf '%s\n' "Usage: copilot-model [<model-id>|-l|-L|-c|--auto|--why|--json]"
      printf '%s\n' "  -l      bare served ids (pipeable; static fallback when offline)"
      printf '%s\n' "  -L      the same list with tier/price/context/plan metadata"
      printf '%s\n' "  --json  raw /v1/models from the proxy"
      printf '%s\n' "  --why   explain what --auto would pick, without writing"
      printf '%s\n' "  --auto  pick best from the live served list, ranked by capability tier"
      printf '%s\n' "          (powerful > versatile > lightweight, newest generation first),"
      printf '%s\n' "          vendor order Claude > OpenAI > grok > Gemini. A curated"
      printf '%s\n' "          per-vendor allowlist overrides the tier ranking."
      printf '%s\n' "  Writes ./.claude/settings.local.json when copilot-here is on,"
      printf '%s\n' "  else the global state file used by claude-copilot / copilot-run."
      return 0 ;;
  esac

  if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' "copilot-model: jq is required" >&2; return 1
  fi

  catalog="$(_copilot_model_catalog 2>/dev/null || true)"
  local models want resolved selectable
  models="$(_copilot_model_list 2>/dev/null)"

  # --auto requires the live catalog. Never silently choose a static Claude id
  # while the proxy is down: that recreates the stale model_not_supported pin.
  # Use when a sticky pin (e.g. gemini from a Claude-less geo day) is stale, or
  # when Anthropic is filtered out and you want the best Codex/GPT instead.
  if [ "$arg" = "--auto" ] || [ "$arg" = "-a" ]; then
    if [ -z "$catalog" ] || ! printf '%s' "$catalog" | _copilot_catalog_valid; then
      printf '%s\n' "copilot-model: --auto needs a reachable proxy and valid /v1/models catalog" >&2
      return 1
    fi
    # Only the AUTOMATIC pick is filtered — a disabled / picker-hidden /
    # embeddings id must never be persisted into a pin the gateway then
    # rejects. `-l`, `-L`, `--json` and naming a model by hand still see
    # everything. Mirrors Get-CopilotSelectableModelIds on the Windows side.
    selectable="$(printf '%s' "$catalog"       | _copilot_auto_candidate_ids "$(_copilot_entitlement_baseline_model)")"
    if [ -z "$selectable" ]; then
      printf '%s\n' "copilot-model: --auto found no selectable chat model in the live catalog" >&2
      return 1
    fi
    if [ "$explain_auto" -eq 1 ]; then
      printf '%s\n' "copilot-model: --auto reasoning" >&2
      printf '  catalog      : %s models, %s selectable\n' \
        "$(printf '%s' "$catalog" | _copilot_catalog_ids | command wc -l | command tr -d ' ')" \
        "$(printf '%s\n' "$selectable" | command wc -l | command tr -d ' ')" >&2
      resolved="$(printf '%s\n' "$selectable" \
        | COPILOT_MODEL_EXPLAIN=1 _copilot_pick_best_model "$catalog")"
    else
      resolved="$(printf '%s\n' "$selectable" | _copilot_pick_best_model "$catalog")"
    fi
    [ -n "$resolved" ] || {
      printf '%s\n' "copilot-model: --auto could not pick a model" >&2
      return 1
    }
    resolved="$(_copilot_model_for_claude "$resolved" "$catalog")"
    case "$resolved" in
      claude-*) printf '%s\n' "copilot-model: --auto → $resolved  (Claude preferred)" >&2 ;;
      gpt-*|*codex*|o[0-9]*) printf '%s\n' "copilot-model: --auto → $resolved  (no Claude; capability-ranked OpenAI)" >&2 ;;
      grok-*) printf '%s\n' "copilot-model: --auto → $resolved  (no Claude/OpenAI; best grok)" >&2 ;;
      gemini-*) printf '%s\n' "copilot-model: --auto → $resolved  (no Claude/OpenAI/grok; best Gemini)" >&2 ;;
      *) printf '%s\n' "copilot-model: --auto → $resolved" >&2 ;;
    esac
    # $resolved already set — fall through to the write path below
  # No arg + fzf available → interactive pick.
  elif [ -z "$arg" ]; then
    if ! command -v fzf >/dev/null 2>&1; then
      printf '%s\n' "copilot-model: pass a model id (fzf not found). Try: copilot-model -l" >&2
      return 1
    fi
    local cur; cur="$(_copilot_model_current)"
    want="$(printf '%s\n' "$models" | command fzf --prompt="model> " --height=40% --reverse \
      --header="current: $cur  |  tip: copilot-model --auto")" || { printf '%s\n' "cancelled"; return 0; }
    [ -n "$want" ] || { printf '%s\n' "cancelled"; return 0; }
    resolved="$(_copilot_model_for_claude "$want" "$catalog")"
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
    if [ -n "$suffix" ]; then
      resolved="$resolved$suffix"
    else
      resolved="$(_copilot_model_for_claude "$resolved" "$catalog")"
    fi
  fi

  # --auto already set $resolved above; the empty/fuzzy branches set it too.
  # Guard: if somehow still empty, bail.
  if [ -z "${resolved:-}" ]; then
    printf '%s\n' "copilot-model: no model resolved" >&2
    return 1
  fi

  local old; old="$(_copilot_model_current)"
  if [ "$old" = "$resolved" ] && [ "$target" = "state" ]; then
    printf '%s\n' "copilot-model: already using $resolved (no change)"
    return 0
  fi

  if [ "$target" = "local" ]; then
    local tmp profile compact='' compact_rc=0 old_raw new_raw
    tmp="$(mktemp "${TMPDIR:-/tmp}/copilot-model.XXXXXX")" || return 1
    profile="$(_copilot_model_profile_json "$resolved" "$catalog")" || { command rm -f -- "$tmp"; return 1; }
    compact="$(_copilot_claude_compact_window "$resolved" "$catalog")" || compact_rc=$?
    if [ "$compact_rc" -eq 3 ]; then
      command rm -f -- "$tmp"
      printf '%s\n' "copilot-model: $(_copilot_strip_context_hint "$resolved") has a prompt ceiling below Claude Code's 100000-token minimum" >&2
      return 1
    fi
    old_raw="$(_copilot_strip_context_hint "$old")"
    new_raw="$(_copilot_strip_context_hint "$resolved")"
    if jq --argjson p "$profile" --arg compact "$compact" --arg old_raw "$old_raw" --arg new_raw "$new_raw" '
         .env.ANTHROPIC_MODEL = $p.main
         | .env.ANTHROPIC_DEFAULT_FABLE_MODEL = $p.fable
         | .env.ANTHROPIC_DEFAULT_OPUS_MODEL = $p.opus
         | .env.ANTHROPIC_DEFAULT_SONNET_MODEL = $p.sonnet
         | .env.ANTHROPIC_DEFAULT_HAIKU_MODEL = $p.haiku
         | .env.ANTHROPIC_SMALL_FAST_MODEL = $p.haiku
         | if $compact != "" then .env.CLAUDE_CODE_AUTO_COMPACT_WINDOW = $compact
           elif $old_raw != $new_raw then del(.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW)
           else . end' \
         "$settings" >"$tmp"; then
      command mv -- "$tmp" "$settings"
      if [ "$old" = "$resolved" ]; then
        printf '%s\n' "copilot-model: refreshed role profile for $resolved  (project: $settings)"
      else
        printf '%s\n' "copilot-model: $old -> $resolved  (project: $settings)"
      fi
      _copilot_print_model_profile "$profile"
      if [ -n "$compact" ]; then
        printf '%s\n' "  compact: $compact tokens (live max prompt)"
      else
        printf '%s\n' "  ⚠ compact: metadata unavailable; existing same-model value was preserved when possible"
      fi
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
    _copilot_print_model_profile "$(_copilot_model_profile_json "$resolved" "$catalog")"
    printf '%s\n' "  applies to the next claude-copilot / copilot-run / copilot-here on"
  fi
}
