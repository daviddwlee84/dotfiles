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
#   claude-copilot [args...]   - one-off Claude Code session on the proxy
#                                (specstory-wrapped when available; zero file writes)
#   claude-copilot-once [args...] - one-shot session via the copilot-here pin
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
#                                               @jeffreycao/copilot-api@2.3.0.
#   COPILOT_PROXY_RATE   default: 15          - --rate-limit seconds; ONLY used
#                                               by the original package (the fork
#                                               has no rate limiter)
#   COPILOT_PROXY_QUIET  default: 0           - 1 = inject extra quota-saving env
#                                               (fewer background calls, but a
#                                               slightly degraded Claude Code UX)

# --- shared constants / helpers -------------------------------------------------

_copilot_port() { printf '%s' "${COPILOT_PROXY_PORT:-4141}"; }
_copilot_builtin_pkg() { printf '%s' '@jeffreycao/copilot-api@2.3.0'; }
_copilot_builtin_integrity() { printf '%s' 'sha512-4h7ysNAO8N9zJkIcOnNPio9asGTMsRkvQ70deSRBSwkBJFOZXYeoKmiHU06VSP712gVNaTrRA7abLAPkTuINqA=='; }
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
    printf '%s\n' "copilot-proxy: update requires an exact version (for example 2.3.0)." >&2; return 1; }
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
# transparently retries 403/429 (GitHub enterprise abuse throttling) BEFORE any
# body streams — so downstream agents never see "Please run /login" — and keeps
# a streamed response alive with SSE comment frames while an OpenAI reasoning
# model thinks (copilot-api withholds headers until the first token and sends no
# `ping`, so the socket is otherwise silent for minutes and gets reaped; see
# pitfalls/copilot-proxy-openai-model-silent-stall.md). Toggle with
# `copilot-proxy shim on|off`; tune via COPILOT_SHIM_{PORT,MAX,RETRIES,
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
        local status_json status_count status_claude
        status_json="$(command curl -fsS --max-time 3 "$(_copilot_base)/v1/models" 2>/dev/null || true)"
        status_count="$(printf '%s' "$status_json" | jq -r '.data | length' 2>/dev/null || printf '?')"
        status_claude="$(printf '%s' "$status_json" | jq -r '[.data[]?.id | select(startswith("claude-"))] | join(" ")' 2>/dev/null)"
        [ -n "$status_claude" ] || status_claude='none'
        printf '%s\n' "copilot-proxy: RUNNING on $(_copilot_base)"
        printf '%s\n' "  models: $status_count served; Claude: $status_claude"
        if _copilot_shim_enabled; then
          if _copilot_shim_alive; then
            printf '%s\n' "  shim:   ON, up on $(_copilot_shim_base)  → clients use this"
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
        if _copilot_shim_alive; then _ok "throttle shim" "up on $(_copilot_shim_base) → clients use this"
        else _bad "throttle shim" "enabled but DOWN"; _hint "copilot-proxy shim on"; fi
      else
        _skip "throttle shim" "off"
      fi

      printf '\n%s\n' "Models"
      local _served _n _claude _model _src _pin _profile _profile_catalog
      local _role_rows _role _role_model _role_bad
      local _http_proxy _up_direct _up_via _dir_n _dir_c _via_n _via_c
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
      if [ "$(_copilot_pkg_flavor)" = "original" ]; then
        "$(_copilot_pkg_bin)" auth
      else
        "$(_copilot_pkg_bin)" auth --provider copilot
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
      printf '%s\n' "Usage: copilot-proxy [start|stop|restart|status|stats|events|quota|bench|update|doctor|...]"
      printf '%s\n' "  stats [day|week|month] [--model ID] [--scope normal|benchmark|all] [--json]"
      printf '%s\n' "  events [day|week|month] [--model ID] [--scope ...] [--limit N] [--json]"
      printf '%s\n' "  quota [--json]       live plan/quota payload from the running fork"
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
  local env_json _kv
  env_json="$(_copilot_env_json_for_model --live "$(_copilot_default_model)")" || return 1
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
  local models preferred c
  models="$(command cat | command sed 's/\[1m\]$//' | command sort -u)"
  [ -n "$models" ] || return 1

  for preferred in \
    gpt-5.6-sol gpt-5.6-terra gpt-5.5 gpt-5.4 gpt-5.3-codex \
    gpt-5.6-luna gpt-5.4-mini gpt-5-mini
  do
    if printf '%s\n' "$models" | command grep -qxF "$preferred"; then
      printf '%s' "$preferred"
      return 0
    fi
  done
  c="$(printf '%s\n' "$models" | command grep -E '^gpt-' | command grep -viE 'mini|nano|luna' \
        | command sort | command tail -1)"
  if [ -n "$c" ]; then printf '%s' "$c"; return 0; fi
  c="$(printf '%s\n' "$models" | command grep -iE 'codex' | command sort | command tail -1)"
  if [ -n "$c" ]; then printf '%s' "$c"; return 0; fi
  c="$(printf '%s\n' "$models" | command grep -E '^gpt-' | command sort | command tail -1)"
  if [ -n "$c" ]; then printf '%s' "$c"; return 0; fi

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
  c="$(printf '%s\n' "$models" | command grep -E '^claude-' | command sort | command tail -1)"
  if [ -n "$c" ]; then printf '%s' "$c"; return 0; fi

  c="$(printf '%s\n' "$models" | command grep -E '^gemini-' | command grep -viE 'flash' \
        | command sort | command tail -1)"
  if [ -n "$c" ]; then printf '%s' "$c"; return 0; fi
  c="$(printf '%s\n' "$models" | command grep -E '^gemini-' | command sort | command tail -1)"
  if [ -n "$c" ]; then printf '%s' "$c"; return 0; fi

  printf '%s\n' "$models" | command sort | command tail -1
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
      printf '%s\n' "  Auto model: OpenAI/Codex > Claude > Gemini > other served chat models."
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
    case "$arg" in -m|--model|-m=*|--model=*) explicit_model=1 ;; esac
  done
  if [ "$explicit_model" -eq 0 ]; then
    models="$(printf '%s' "$catalog" | jq -r '
      .data[]?
      | select((.policy.state // "enabled") != "disabled")
      | select(.model_picker_enabled != false)
      | select((.capabilities.type // "chat") != "embeddings")
      | .id // empty' 2>/dev/null | command sort -u)"
    model="$(printf '%s\n' "$models" | _copilot_codex_pick_best_model)" || {
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
_copilot_here_keys='["ANTHROPIC_BASE_URL","ANTHROPIC_AUTH_TOKEN","ANTHROPIC_MODEL","ANTHROPIC_DEFAULT_FABLE_MODEL","ANTHROPIC_DEFAULT_OPUS_MODEL","ANTHROPIC_DEFAULT_SONNET_MODEL","ANTHROPIC_DEFAULT_HAIKU_MODEL","ANTHROPIC_SMALL_FAST_MODEL","CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC","CLAUDE_CODE_ATTRIBUTION_HEADER","CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION","CLAUDE_CODE_ENABLE_AWAY_SUMMARY","DISABLE_NON_ESSENTIAL_MODEL_CALLS"]'

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
  local selected="$1" catalog="${2:-}" profile
  if [ "$#" -ge 2 ]; then
    profile="$(_copilot_model_profile_json "$selected" "$catalog")" || return 1
  else
    profile="$(_copilot_model_profile_json "$selected")" || return 1
  fi
  jq -n \
    --arg base_url "$("$base_fn")" \
    --argjson profile "$profile" \
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
    } + (if $quiet == "1" then {
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
      local base_url model want_env
      want_env="$(_copilot_env_json)" || return 1
      base_url="$(printf '%s' "$want_env" | jq -r '.ANTHROPIC_BASE_URL')"
      model="$(printf '%s' "$want_env" | jq -r '.ANTHROPIC_MODEL')"
      local tmp; tmp="$(command mktemp "${TMPDIR:-/tmp}/copilot-here.XXXXXX")" || return 1
      if printf '%s' "$base" | jq --argjson want "$want_env" \
          '.env = ((.env // {}) + $want)' >"$tmp"; then
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
_copilot_here_drift() {
  local settings=".claude/settings.local.json"
  [ -f "$settings" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  # ANTHROPIC_BASE_URL is only set while the pin is ON — absent → nothing to do.
  [ -n "$(jq -r '.env.ANTHROPIC_BASE_URL // empty' "$settings" 2>/dev/null)" ] || return 1
  local want out
  want="$(_copilot_env_json)" || return 1
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

_copilot_catalog_ids() {
  if command -v jq >/dev/null 2>&1; then
    jq -r '.data[]?.id // empty' 2>/dev/null | command sort -u
  else
    command grep -o '"id":"[^"]*"' | command sed 's/"id":"//;s/"//' | command sort -u
  fi
}

_copilot_strip_context_hint() {
  printf '%s' "${1%\[1m\]}"
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
  local models preferred c
  models="$(command cat | command sed 's/\[1m\]$//' | command sort -u)"
  [ -n "$models" ] || return 1

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
  c="$(printf '%s\n' "$models" | command grep -E '^claude-' | command sort | command tail -1)"
  if [ -n "$c" ]; then printf '%s' "$c"; return 0; fi

  for preferred in \
    gpt-5.6-sol gpt-5.6-terra gpt-5.5 gpt-5.4 gpt-5.3-codex \
    gpt-5.6-luna gpt-5.4-mini gpt-5-mini
  do
    if printf '%s\n' "$models" | command grep -qxF "$preferred"; then
      printf '%s' "$preferred"
      return 0
    fi
  done

  c="$(printf '%s\n' "$models" | command grep -E '^gpt-' | command grep -viE 'mini|nano|luna' \
        | command sort | command tail -1)"
  if [ -n "$c" ]; then printf '%s' "$c"; return 0; fi
  c="$(printf '%s\n' "$models" | command grep -iE 'codex' | command sort | command tail -1)"
  if [ -n "$c" ]; then printf '%s' "$c"; return 0; fi
  c="$(printf '%s\n' "$models" | command grep -E '^gpt-' | command sort | command tail -1)"
  if [ -n "$c" ]; then printf '%s' "$c"; return 0; fi

  c="$(printf '%s\n' "$models" | command grep -E '^gemini-' | command grep -viE 'flash' \
        | command sort | command tail -1)"
  if [ -n "$c" ]; then printf '%s' "$c"; return 0; fi
  c="$(printf '%s\n' "$models" | command grep -E '^gemini-' | command sort | command tail -1)"
  if [ -n "$c" ]; then printf '%s' "$c"; return 0; fi

  printf '%s\n' "$models" | command sort | command tail -1
}

# Build the full Claude Code role profile for one selected main model. Native
# Claude profiles use the strongest served model in each Claude family. OpenAI
# profiles map quality/balanced/fast roles to Sol/Terra/Luna, with every role
# falling back to the selected main rather than an unserved hard-coded id.
_copilot_model_profile_json() {
  command -v jq >/dev/null 2>&1 || return 1
  local selected="${1:-$(_copilot_default_model)}" catalog="${2:-}" models raw main
  local fable_raw opus_raw sonnet_raw haiku_raw
  if [ "$#" -lt 2 ]; then catalog="$(_copilot_model_catalog 2>/dev/null || true)"; fi
  if [ -n "$catalog" ]; then models="$(printf '%s' "$catalog" | _copilot_catalog_ids)"; else models=''; fi
  raw="$(_copilot_strip_context_hint "$selected")"
  main="$(_copilot_model_for_claude "$selected" "$catalog")"

  case "$raw" in
    claude-*)
      fable_raw="$(_copilot_first_served "$models" claude-fable-5 2>/dev/null || true)"
      [ -n "$fable_raw" ] || fable_raw="$(printf '%s\n' "$models" | command grep '^claude-fable-' | command sort | command tail -1)"
      [ -n "$fable_raw" ] || fable_raw="$raw"

      opus_raw="$(_copilot_first_served "$models" \
        claude-opus-5 claude-opus-4-8 claude-opus-4-7 claude-opus-4-6 claude-opus-4-5 \
        2>/dev/null || true)"
      [ -n "$opus_raw" ] || opus_raw="$(printf '%s\n' "$models" | command grep '^claude-opus-' | command sort | command tail -1)"
      [ -n "$opus_raw" ] || opus_raw="$raw"

      sonnet_raw="$(_copilot_first_served "$models" \
        claude-sonnet-5 claude-sonnet-4-6 claude-sonnet-4-5 2>/dev/null || true)"
      [ -n "$sonnet_raw" ] || sonnet_raw="$(printf '%s\n' "$models" | command grep '^claude-sonnet-' | command sort | command tail -1)"
      [ -n "$sonnet_raw" ] || sonnet_raw="$raw"

      haiku_raw="$(_copilot_first_served "$models" claude-haiku-4-5 2>/dev/null || true)"
      [ -n "$haiku_raw" ] || haiku_raw="$(printf '%s\n' "$models" | command grep '^claude-haiku-' | command sort | command tail -1)"
      [ -n "$haiku_raw" ] || haiku_raw="$raw"
      ;;
    gpt-*|*codex*)
      fable_raw="$raw"; opus_raw="$raw"
      sonnet_raw="$(_copilot_first_served "$models" gpt-5.6-terra 2>/dev/null || true)"
      [ -n "$sonnet_raw" ] || sonnet_raw="$raw"
      haiku_raw="$(_copilot_first_served "$models" \
        gpt-5.6-luna gpt-5.4-mini gpt-5-mini 2>/dev/null || true)"
      [ -n "$haiku_raw" ] || haiku_raw="$raw"
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
#   copilot-model --auto           # Claude; else Sol > Terra > older flagships > Luna
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
        gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna gpt-5.5 gpt-5.4 gpt-5.3-codex \
        gpt-5.4-mini gpt-5-mini
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
    -l|--list)
      catalog="$(_copilot_model_catalog 2>/dev/null || true)"
      _copilot_model_list
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
      else
        catalog="$(_copilot_model_catalog 2>/dev/null || true)"
        printf 'model profile (global main: %s)\n' "$statef"
        _copilot_print_model_profile "$(_copilot_model_profile_json "$(_copilot_model_current)" "$catalog")"
      fi
      return 0 ;;
    -h|--help)
      printf '%s\n' "Usage: copilot-model [<model-id>|-l|-c|--auto]"
      printf '%s\n' "  --auto  pick best from live served list: Claude; else capability-ranked OpenAI"
      printf '%s\n' "          (Sol > Terra > GPT-5.5 > GPT-5.4 > GPT-5.3 Codex > Luna > mini)"
      printf '%s\n' "  Writes ./.claude/settings.local.json when copilot-here is on,"
      printf '%s\n' "  else the global state file used by claude-copilot / copilot-run."
      return 0 ;;
  esac

  if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' "copilot-model: jq is required" >&2; return 1
  fi

  catalog="$(_copilot_model_catalog 2>/dev/null || true)"
  local models want resolved
  models="$(_copilot_model_list 2>/dev/null)"

  # --auto requires the live catalog. Never silently choose a static Claude id
  # while the proxy is down: that recreates the stale model_not_supported pin.
  # Use when a sticky pin (e.g. gemini from a Claude-less geo day) is stale, or
  # when Anthropic is filtered out and you want the best Codex/GPT instead.
  if [ "$arg" = "--auto" ] || [ "$arg" = "-a" ]; then
    if [ -z "$catalog" ] || [ -z "$models" ]; then
      printf '%s\n' "copilot-model: --auto needs a reachable proxy and live /v1/models catalog" >&2
      return 1
    fi
    resolved="$(printf '%s\n' "$models" | _copilot_pick_best_model)" || {
      printf '%s\n' "copilot-model: --auto could not pick a model" >&2
      return 1
    }
    resolved="$(_copilot_model_for_claude "$resolved" "$catalog")"
    case "$resolved" in
      claude-*) printf '%s\n' "copilot-model: --auto → $resolved  (Claude preferred)" >&2 ;;
      gpt-*|*codex*|o[0-9]*) printf '%s\n' "copilot-model: --auto → $resolved  (no Claude; capability-ranked OpenAI)" >&2 ;;
      gemini-*) printf '%s\n' "copilot-model: --auto → $resolved  (no Claude/OpenAI; best Gemini)" >&2 ;;
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
    local tmp profile; tmp="$(mktemp "${TMPDIR:-/tmp}/copilot-model.XXXXXX")" || return 1
    profile="$(_copilot_model_profile_json "$resolved" "$catalog")" || { command rm -f -- "$tmp"; return 1; }
    if jq --argjson p "$profile" '
         .env.ANTHROPIC_MODEL = $p.main
         | .env.ANTHROPIC_DEFAULT_FABLE_MODEL = $p.fable
         | .env.ANTHROPIC_DEFAULT_OPUS_MODEL = $p.opus
         | .env.ANTHROPIC_DEFAULT_SONNET_MODEL = $p.sonnet
         | .env.ANTHROPIC_DEFAULT_HAIKU_MODEL = $p.haiku
         | .env.ANTHROPIC_SMALL_FAST_MODEL = $p.haiku' \
         "$settings" >"$tmp"; then
      command mv -- "$tmp" "$settings"
      if [ "$old" = "$resolved" ]; then
        printf '%s\n' "copilot-model: refreshed role profile for $resolved  (project: $settings)"
      else
        printf '%s\n' "copilot-model: $old -> $resolved  (project: $settings)"
      fi
      _copilot_print_model_profile "$profile"
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
