# 51_docker_net.sh - Docker registry egress: detect, diagnose, wire up
#   (shared bash + zsh). Loads after 50_networking.sh so __net_detect_proxy exists.
#
# The problem this solves: `docker pull` is executed by the DAEMON, not the CLI.
# Neither the shell's proxy env nor ~/.docker/config.json `proxies.default`
# (which only injects env into `docker run`/`build` containers) affects a pull.
# So under the GFW there are exactly three levers, and they cover different sets:
#
#   1. registry-mirrors   ~/.config/docker/daemon.json — DOCKER HUB ONLY.
#                         Nothing for ghcr.io / gcr.io / quay.io / registry.k8s.io.
#   2. daemon proxy       daemon.json `proxies` (Engine >= 23) — covers everything,
#                         but needs a daemon RESTART, which kills running containers.
#   3. client-side fetch  skopeo copy docker://REF docker-daemon:REF — the client
#                         does the network itself, honouring the shell's proxy, and
#                         hands the result to the daemon. No restart at all.
#
# Public surface:
#   docker-net status            - one screen: install shape, daemon proxy, mirrors,
#                                  detected local proxy, transparent-proxy state
#   docker-net doctor [--deep]   - full diagnosis; --deep also probes ghcr/gcr/quay/
#                                  k8s from the DAEMON's side (slow, still read-only)
#   docker-net on [URL] [-y]     - write daemon.json `proxies` + restart the daemon
#   docker-net off [-y]          - remove it + restart
#   docker-net mirrors           - mirror health only (fast)
#   docker-net pull REF [args..] - pull with a fallback ladder (see _dnet_pull)
#
# Environment:
#   DOCKER_NET_PROXY      auto|always|never|http://host:port   (default auto)
#                         `auto` delegates to __net_detect_proxy — the same
#                         detector behind `proxy-status`, so this tool and the
#                         shell helpers can never disagree about which proxy is up.
#   DOCKER_NET_NO_PROXY   extra comma-separated no-proxy entries
#   DOCKER_NET_MIRRORS    override the mirror list used for probing
#   DOCKER_NET_PLATFORM   os/arch for the skopeo rung (e.g. linux/amd64)
#
# Full guide: docs/tools/docker-net.md

# --- small helpers -----------------------------------------------------------

_dnet_have() { command -v "$1" >/dev/null 2>&1; }

_dnet_host_of() {
  # https://docker.m.daocloud.io/  ->  docker.m.daocloud.io
  local u="${1#*://}"
  printf '%s' "${u%%/*}"
}

# Report helpers, shared by `status` and `doctor`. Colour only when stdout is a
# terminal so `docker-net doctor | tee` stays readable; printf (not $'..') keeps
# this sh-portable.
_dnet_report_init() {
  _DNET_G=''; _DNET_R=''; _DNET_Y=''; _DNET_Z=''
  if [ -t 1 ]; then
    _DNET_G="$(printf '\033[32m')"; _DNET_R="$(printf '\033[31m')"
    _DNET_Y="$(printf '\033[33m')"; _DNET_Z="$(printf '\033[0m')"
  fi
  _DNET_FAIL=0; _DNET_WARN=0
}
# 26 = len("docker.mirrors.ustc.edu.cn"), the longest label these reporters get.
_dnet_ok()   { printf '  %s✓%s %-26s %s\n' "$_DNET_G" "$_DNET_Z" "$1" "$2"; }
_dnet_bad()  { printf '  %s✗%s %-26s %s\n' "$_DNET_R" "$_DNET_Z" "$1" "$2"; _DNET_FAIL=$((_DNET_FAIL+1)); }
_dnet_note() { printf '  %s!%s %-26s %s\n' "$_DNET_Y" "$_DNET_Z" "$1" "$2"; _DNET_WARN=$((_DNET_WARN+1)); }
_dnet_skip() { printf '  · %-26s %s\n' "$1" "$2"; }
_dnet_hint() { printf '    %-26s → %s\n' "" "$1"; }

# --- proxy resolution --------------------------------------------------------

# Same shape as _copilot_resolve_http_proxy (43_copilot_proxy.sh): an explicit
# URL wins, `never` opts out, `auto` delegates to the shared detector. Prints the
# URL on stdout (empty when none). `socks://` is rejected on purpose — it is not
# a scheme Go's proxy parser or curl understands, and a daemon configured with it
# silently makes no connections at all.
_dnet_resolve_proxy() {
  local mode="${1:-${DOCKER_NET_PROXY:-auto}}"
  case "$mode" in
    never|off|0|false|no) return 0 ;;
    socks://*)
      printf 'docker-net: %s is not a valid proxy scheme — use socks5:// (or http://)\n' "$mode" >&2
      return 1 ;;
    http://*|https://*|socks5://*|socks5h://*) printf '%s' "$mode"; return 0 ;;
    always|auto|on|1|true|yes|"") ;;
    *)
      printf 'docker-net: unknown proxy mode %s (use auto|always|never|http://...)\n' "$mode" >&2
      return 1 ;;
  esac

  # Delegate to the detector behind proxy-status. The `command -v` guard mirrors
  # copilot-proxy's: file order puts 50_networking.sh first, but a user sourcing
  # this file standalone would otherwise get a confusing "command not found".
  if _dnet_have __net_detect_proxy; then
    if __net_detect_proxy 2>/dev/null \
       && [ -n "${_NET_PROXY_CACHE:-}" ] && [ "${_NET_PROXY_CACHE}" != "none" ]; then
      printf '%s' "$_NET_PROXY_CACHE"
      return 0
    fi
  fi
  return 0
}

# Prime the shared detector's cache in the CURRENT shell. _dnet_resolve_proxy is
# normally called inside $( ), and a subshell's cache writes are discarded — so
# _dnet_proxy_source would always report "unknown" without this.
_dnet_prime_proxy() {
  _dnet_have __net_detect_proxy || return 0
  __net_detect_proxy >/dev/null 2>&1 || true
  return 0
}

_dnet_proxy_source() {
  if [ -n "${_NET_PROXY_SOURCE_CACHE:-}" ]; then printf '%s' "$_NET_PROXY_SOURCE_CACHE"
  else printf 'unknown'; fi
}

# Run a command with proxy env applied to the child only. Prefers 50_networking's
# `withproxy` (one detector, one answer); falls back to an inline export so this
# file still works if sourced standalone.
_dnet_withproxy() {
  if _dnet_have withproxy; then withproxy "$@"; return $?; fi
  local p; p="$(_dnet_resolve_proxy)" || return 1
  if [ -z "$p" ]; then "$@"; return $?; fi
  command env http_proxy="$p" https_proxy="$p" HTTP_PROXY="$p" HTTPS_PROXY="$p" \
    ALL_PROXY="$p" all_proxy="$p" "$@"
}

# --- docker facts (one `docker info` per invocation) -------------------------

_dnet_info_load() {
  _DNET_SRV=''; _DNET_HTTP=''; _DNET_HTTPS=''; _DNET_NOPROXY=''
  _DNET_SECOPTS=''; _DNET_MIRRORS_RAW=''; _DNET_OS=''; _DNET_INFO_OK=0
  _dnet_have docker || return 1
  local raw
  # Go templates address the STRUCT field name, not the JSON tag: the proxy
  # fields marshal as HttpProxy/HttpsProxy (which is what `docker info --format
  # '{{json .}}' | jq` shows) but the template names are HTTPProxy/HTTPSProxy.
  # Getting this wrong fails the whole template, not just that one field.
  raw="$(command docker info --format \
    '{{.ServerVersion}}|{{.HTTPProxy}}|{{.HTTPSProxy}}|{{.NoProxy}}|{{range .SecurityOptions}}{{.}},{{end}}|{{range .RegistryConfig.Mirrors}}{{.}},{{end}}|{{.OperatingSystem}}' \
    2>/dev/null)" || return 1
  [ -n "$raw" ] || return 1
  # Split by stripping, not by IFS word-splitting: zsh does not split unquoted
  # parameter expansions, so `set -- $raw` would yield ONE field there and six in
  # bash. Sequential ${x%%|*} / ${x#*|} behaves identically in both shells.
  local r="$raw"
  _DNET_SRV="${r%%|*}";     r="${r#*|}"
  _DNET_HTTP="${r%%|*}";    r="${r#*|}"
  _DNET_HTTPS="${r%%|*}";   r="${r#*|}"
  _DNET_NOPROXY="${r%%|*}"; r="${r#*|}"
  _DNET_SECOPTS="${r%%|*}";     r="${r#*|}"
  _DNET_MIRRORS_RAW="${r%%|*}"; r="${r#*|}"
  _DNET_OS="$r"
  _DNET_INFO_OK=1
  return 0
}

# rootless | rootful | desktop | orbstack | none
#
# `docker info`'s OperatingSystem is checked FIRST because it is the only field
# that distinguishes OrbStack from Docker Desktop — both present a Linux daemon,
# both may leave their directories on disk, and a Mac with one installed and the
# other merely left over would otherwise be misreported.
_dnet_shape() {
  _dnet_have docker || { printf 'none'; return 1; }
  case "${_DNET_OS:-}" in
    *OrbStack*)       printf 'orbstack'; return 0 ;;
    *"Docker Desktop"*) printf 'desktop'; return 0 ;;
  esac
  case "${_DNET_SECOPTS:-}" in
    *name=rootless*) printf 'rootless'; return 0 ;;
  esac
  case "${DOCKER_HOST:-}" in
    *orbstack*) printf 'orbstack'; return 0 ;;
  esac
  # Fallbacks for when `docker info` itself failed.
  if [ "$(command uname -s 2>/dev/null)" = "Darwin" ]; then
    [ -d "$HOME/.orbstack" ] && { printf 'orbstack'; return 0; }
    [ -d "/Applications/Docker.app" ] && { printf 'desktop'; return 0; }
  fi
  [ "${_DNET_INFO_OK:-0}" = 1 ] && { printf 'rootful'; return 0; }
  printf 'none'; return 1
}

# Where the daemon lives relative to YOU, which is the same question as "is a
# 127.0.0.1 proxy URL usable":
#   host    same network namespace as this shell  -> 127.0.0.1 reaches your proxy
#   netns   a separate Linux netns                -> 127.0.0.1 is the DAEMON's loopback
#   vm      inside a VM (Docker Desktop/OrbStack) -> 127.0.0.1 is the VM's loopback
#   unknown not determinable here
# Getting this wrong is silent in both directions: the daemon accepts the config
# and then simply connects to nothing.
_dnet_daemon_locality() {
  case "$(_dnet_shape)" in
    desktop|orbstack) printf 'vm'; return 0 ;;
  esac
  local pid dns mns
  pid="$(_dnet_dockerd_pid)"
  if [ -n "$pid" ] && [ -r "/proc/$pid/ns/net" ] && [ -r /proc/self/ns/net ]; then
    dns="$(command readlink "/proc/$pid/ns/net" 2>/dev/null)"
    mns="$(command readlink /proc/self/ns/net 2>/dev/null)"
    [ "$dns" = "$mns" ] && { printf 'host'; return 0; }
    printf 'netns'; return 0
  fi
  printf 'unknown'; return 0
}

# One line explaining the locality, shared by status and doctor.
_dnet_locality_detail() {
  case "$1" in
    host)  printf 'host — a 127.0.0.1 proxy URL reaches your local proxy' ;;
    netns) printf "separate Linux netns — 127.0.0.1 is the daemon's own loopback, not yours" ;;
    vm)    printf "inside a VM — 127.0.0.1 is the VM's own loopback, not your Mac's" ;;
    *)     printf 'not determinable on this platform' ;;
  esac
}

# The daemon.json the ACTIVE daemon actually reads. Desktop/OrbStack read
# neither — they have their own stores, so callers must refuse to write.
_dnet_daemon_json() {
  case "$(_dnet_shape)" in
    rootless) printf '%s/docker/daemon.json' "${XDG_CONFIG_HOME:-$HOME/.config}" ;;
    rootful)  printf '/etc/docker/daemon.json' ;;
    orbstack) printf '%s/.orbstack/config/docker.json' "$HOME" ;;
    *)        return 1 ;;
  esac
}

_dnet_dockerd_pid() {
  # The real dockerd, not the rootlesskit wrapper that spawned it.
  _dnet_have pgrep || return 1
  command pgrep -x dockerd 2>/dev/null | command head -n 1
}

# Newline-delimited mirror URLs (trailing slash stripped). Source of truth is the
# LIVE daemon, never daemon.json on disk: a file edited since the last reload
# would otherwise report mirrors that are not actually in effect.
_dnet_mirrors() {
  # Both branches must newline-TERMINATE (not just newline-separate) and strip
  # trailing slashes, so callers can pipe as well as heredoc them. `printf '%s'`
  # on a comma-separated override would leave the last entry unterminated, and a
  # `while read` loop drops that line.
  if [ -n "${DOCKER_NET_MIRRORS:-}" ]; then
    printf '%s\n' "$DOCKER_NET_MIRRORS" | command tr ', ' '\n\n' \
      | command sed -e 's#/*$##' -e '/^$/d'
    return 0
  fi
  printf '%s' "${_DNET_MIRRORS_RAW:-}" | command tr ',' '\n' \
    | command sed -e 's#/*$##' -e '/^$/d'
}

# --- probing -----------------------------------------------------------------

# Echoes "<http_code>|<seconds>|<curl_stderr>". Any HTTP status means the host
# answered — a registry's unauthenticated 401 is a SUCCESSFUL reach. Only a
# connect/TLS/DNS failure is a fault, and its curl message is what distinguishes
# "domain is gone" from "TLS reset" from "blackholed".
_dnet_probe() {
  local url="$1" via="${2:-}" out err tmp
  # BSD mktemp REQUIRES a template — bare `mktemp` is a usage error on macOS.
  # Losing $tmp is not fatal but costs the curl stderr, and with it the
  # difference between "DNS gone", "TLS reset" and "timeout".
  tmp="$(command mktemp "${TMPDIR:-/tmp}/docker-net.XXXXXX" 2>/dev/null)" || tmp=""
  if [ -n "$via" ]; then
    out="$(command curl -o /dev/null -sS -w '%{http_code}|%{time_total}' \
             --max-time 10 -x "$via" "$url" 2>"${tmp:-/dev/null}")"
  else
    out="$(command curl -o /dev/null -sS -w '%{http_code}|%{time_total}' \
             --max-time 10 --noproxy '*' "$url" 2>"${tmp:-/dev/null}")"
  fi
  err=''
  if [ -n "$tmp" ]; then
    err="$(command tr '\n' ' ' < "$tmp" 2>/dev/null)"
    command rm -f "$tmp" 2>/dev/null
  fi
  printf '%s|%s' "${out:-000|0}" "$err"
}

# Turn a probe result into a verdict word + explanation.
_dnet_classify() {
  local code="$1" err="$2"
  case "$code" in
    200|401) printf 'ok|healthy' ;;
    403)     printf 'warn|reachable but refusing (campus-only / geo-blocked)' ;;
    404)     printf 'warn|not a registry v2 endpoint' ;;
    5*)      printf 'bad|mirror broken (HTTP %s)' "$code" ;;
    000|"")
      case "$err" in
        *"Could not resolve host"*) printf 'bad|domain has no DNS record' ;;
        *SSL_ERROR_SYSCALL*|*"tlsv1 alert"*|*"SSL_connect"*) printf 'bad|TLS reset (blocked or internal-only)' ;;
        *"Operation timed out"*|*"Connection timed out"*|*"timed out"*) printf 'bad|blackholed (timeout)' ;;
        *"Connection refused"*) printf 'bad|connection refused' ;;
        *) printf 'bad|unreachable' ;;
      esac ;;
    *) printf 'warn|unexpected HTTP %s' "$code" ;;
  esac
}

_dnet_report_probe() {
  # $1 label  $2 url  $3 proxy-or-empty
  local label="$1" url="$2" via="${3:-}" res code secs err verdict kind why
  res="$(_dnet_probe "$url" "$via")"
  code="${res%%|*}"; res="${res#*|}"
  secs="${res%%|*}"; err="${res#*|}"
  verdict="$(_dnet_classify "$code" "$err")"
  kind="${verdict%%|*}"; why="${verdict#*|}"
  local detail
  detail="$(printf '%-42s %ss' "$why" "$(printf '%s' "${secs:-0}" | command cut -c1-5)")"
  case "$kind" in
    ok)   _dnet_ok   "$label" "$detail" ;;
    warn) _dnet_note "$label" "$detail" ;;
    *)    _dnet_bad  "$label" "$detail" ;;
  esac
}

# --- transparent proxy (TUN) detection ---------------------------------------

# mihomo/clash in TUN mode intercepts at L3, so the daemon egresses through the
# proxy with NO daemon.json `proxies` block at all. Without this check a user
# cannot tell whether `docker-net on` changed anything.
_dnet_tun_iface() {
  if _dnet_have ip; then
    command ip -o link show 2>/dev/null \
      | command awk -F': ' '{print $2}' \
      | command grep -Ex 'Meta|Mihomo|clash[0-9]*|utun[0-9]*|tun[0-9]+' \
      | command head -n 1
    return 0
  fi
  if _dnet_have ifconfig; then
    command ifconfig -l 2>/dev/null | command tr ' ' '\n' \
      | command grep -Ex 'utun[0-9]*' | command head -n 1
    return 0
  fi
  return 1
}

_dnet_fakeip_route() {
  # mihomo's default fake-ip range is 198.18.0.0/15 (RFC 2544 benchmark space).
  if _dnet_have ip; then
    command ip route 2>/dev/null | command grep -E '^198\.(18|19)\.' | command head -n 1
  elif _dnet_have netstat; then
    command netstat -rn 2>/dev/null | command grep -E '^198\.(18|19)' | command head -n 1
  fi
}

# --- writing daemon.json .proxies --------------------------------------------

_dnet_no_proxy_value() {
  local extra="${DOCKER_NET_NO_PROXY:-}" out mirror host
  out='localhost,127.0.0.1,::1,*.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16'
  # Mirror traffic is already inside CN — routing it back out through the proxy
  # is slower and often broken. Exempt every mirror actually in effect.
  while IFS= read -r mirror; do
    [ -n "$mirror" ] || continue
    host="$(_dnet_host_of "$mirror")"
    [ -n "$host" ] && out="$out,$host"
  done <<EOF
$(_dnet_mirrors)
EOF
  [ -n "$extra" ] && out="$out,$extra"
  printf '%s' "$out"
}

_dnet_running_containers() {
  # `grep -c .` exits 1 on an empty stream, which would make a `|| printf 0`
  # fallback print a SECOND zero. wc -l always succeeds.
  command docker ps -q 2>/dev/null | command wc -l | command tr -d ' '
}

# Ask before a restart that kills containers. Refuses rather than hangs when
# there is no TTY (fleet-exec over SSH) unless -y was passed.
_dnet_confirm_restart() {
  local assume_yes="$1" n reply
  n="$(_dnet_running_containers)"
  if [ "${n:-0}" -eq 0 ] 2>/dev/null; then
    return 0
  fi
  printf '  %s!%s %d running container(s) will be killed by the daemon restart:\n' \
    "$_DNET_Y" "$_DNET_Z" "$n"
  command docker ps --format '      {{.Names}}  ({{.Image}})' 2>/dev/null
  if [ "$assume_yes" = 1 ]; then
    printf '  proceeding (-y)\n'
    return 0
  fi
  if [ ! -t 0 ]; then
    printf 'docker-net: refusing to restart non-interactively with containers running; re-run with -y\n' >&2
    return 1
  fi
  printf '  restart anyway? [y/N] '
  read -r reply || return 1
  case "$reply" in y|Y|yes|YES) return 0 ;; *) printf '  aborted\n'; return 1 ;; esac
}

_dnet_restart_daemon() {
  local shape="$1"
  case "$shape" in
    rootless)
      _dnet_have systemctl || { printf 'docker-net: no systemctl; restart the daemon yourself\n' >&2; return 1; }
      command systemctl --user daemon-reload 2>/dev/null
      command systemctl --user restart docker ;;
    rootful)
      _dnet_have systemctl || { printf 'docker-net: no systemctl; restart the daemon yourself\n' >&2; return 1; }
      command sudo systemctl daemon-reload && command sudo systemctl restart docker ;;
    *)
      printf 'docker-net: cannot restart a %s daemon from the CLI — use its UI\n' "$shape" >&2
      return 1 ;;
  esac
}

# jq-merge a filter into the active daemon.json, creating it if absent. Extra
# args after the filter are passed to jq (use --arg, never string interpolation:
# a proxy URL or no-proxy list injected into a jq program is a parse error at
# best and a silent rewrite at worst).
_dnet_edit_daemon_json() {
  local filter="$1"; shift
  local path shape input out
  shape="$(_dnet_shape)"
  path="$(_dnet_daemon_json)" || {
    printf 'docker-net: no daemon.json for a %s install\n' "$shape" >&2; return 1; }
  case "$shape" in
    desktop|orbstack)
      printf 'docker-net: %s does not read a daemon.json this tool can edit — use its settings UI\n' "$shape" >&2
      return 1 ;;
  esac
  _dnet_have jq || { printf 'docker-net: jq is required to edit %s\n' "$path" >&2; return 1; }

  input='{}'
  [ -f "$path" ] && input="$(command cat "$path" 2>/dev/null)"
  [ -n "$input" ] || input='{}'
  out="$(printf '%s' "$input" | command jq "$@" "$filter" 2>/dev/null)" || {
    printf 'docker-net: %s is not valid JSON — fix it by hand first\n' "$path" >&2; return 1; }

  if [ "$shape" = rootful ]; then
    printf '%s\n' "$out" | command sudo tee "$path" >/dev/null || return 1
  else
    command mkdir -p "$(command dirname "$path")" 2>/dev/null
    printf '%s\n' "$out" > "$path.dnet.tmp" && command mv "$path.dnet.tmp" "$path" || return 1
  fi
  printf '%s' "$path"
}

# --- image reference parsing --------------------------------------------------

# "<registry>|<remainder>"; empty registry means Docker Hub. A first path
# component counts as a registry only if it has a dot or colon, or is localhost —
# that is Docker's own rule, and it is why `bitnami/redis` is a Hub image while
# `gcr.io/foo` is not.
_dnet_ref_split() {
  local ref="$1" first rest
  case "$ref" in
    */*) first="${ref%%/*}"; rest="${ref#*/}" ;;
    *)   printf '|%s' "$ref"; return 0 ;;
  esac
  case "$first" in
    *.*|*:*|localhost) printf '%s|%s' "$first" "$rest" ;;
    *)                 printf '|%s' "$ref" ;;
  esac
}

# Hub images need the implicit `library/` made explicit before a mirror prefix:
# `nginx` is really `library/nginx`, and a mirror will 404 without it.
_dnet_hub_path() {
  case "$1" in
    */*) printf '%s' "$1" ;;
    *)   printf 'library/%s' "$1" ;;
  esac
}

# --- verbs -------------------------------------------------------------------

_dnet_status() {
  _dnet_report_init
  _dnet_prime_proxy
  _dnet_info_load || {
    printf '\ndocker-net: no reachable Docker daemon (DOCKER_HOST=%s)\n\n' "${DOCKER_HOST:-<unset>}"
    return 1; }
  local shape proxy src djson tun
  shape="$(_dnet_shape)"
  djson="$(_dnet_daemon_json 2>/dev/null)"

  printf '\ndocker-net   %s docker %s\n\n' "$shape" "${_DNET_SRV:-?}"
  _dnet_skip "socket" "${DOCKER_HOST:-<default>}"
  [ -n "$djson" ] && _dnet_skip "daemon.json" "$djson"

  if [ -n "${_DNET_HTTPS:-}${_DNET_HTTP:-}" ]; then
    _dnet_ok "daemon proxy" "https=${_DNET_HTTPS:-<none>}  http=${_DNET_HTTP:-<none>}"
    [ -n "${_DNET_NOPROXY:-}" ] && _dnet_skip "no-proxy" "$_DNET_NOPROXY"
  else
    _dnet_note "daemon proxy" "none — \`docker pull\` egresses direct unless a TUN intercepts it"
  fi

  local n=0 mirror
  while IFS= read -r mirror; do
    [ -n "$mirror" ] || continue
    n=$((n+1))
    _dnet_skip "mirror $n" "$mirror"
  done <<EOF
$(_dnet_mirrors)
EOF
  [ "$n" -eq 0 ] && _dnet_skip "mirrors" "none (Docker Hub pulls go straight to docker.io)"

  proxy="$(_dnet_resolve_proxy)" || true
  if [ -n "$proxy" ]; then
    src="$(_dnet_proxy_source)"
    _dnet_ok "local proxy" "$proxy  source=$src"
  else
    _dnet_note "local proxy" "none detected (see \`proxy-status\`)"
  fi

  # Where the daemon lives relative to you — the same question as "is a
  # 127.0.0.1 proxy URL usable". Cross-platform: on macOS the answer is always
  # "no" because the daemon is in a VM, and nothing about that is visible in
  # /proc, so a Linux-only netns check would silently say nothing there.
  local locality
  locality="$(_dnet_daemon_locality)"
  case "$locality" in
    host)    _dnet_ok   "daemon locality" "$(_dnet_locality_detail host)" ;;
    netns)   _dnet_bad  "daemon locality" "$(_dnet_locality_detail netns)"
             _dnet_hint "use this host's LAN IP: docker-net on http://<lan-ip>:<port>" ;;
    vm)      _dnet_note "daemon locality" "$(_dnet_locality_detail vm)"
             _dnet_hint "set the proxy in the $(_dnet_shape) UI, not here" ;;
    *)       _dnet_skip "daemon locality" "$(_dnet_locality_detail unknown)" ;;
  esac

  tun="$(_dnet_tun_iface 2>/dev/null)"
  if [ -n "$tun" ] && [ -n "$(_dnet_fakeip_route)" ]; then
    _dnet_ok "transparent" "TUN '$tun' up with fake-ip route — daemon egress already proxied at L3"
  fi

  _dnet_stale_config_check
  printf '\n'
  return 0
}

# Two files survive the rootful->rootless pivot and read as "proxy is configured"
# while the running daemon has none. Advisory only — never delete root-owned
# files a user may want back if they switch to rootful.
_dnet_stale_config_check() {
  [ "$(command uname -s 2>/dev/null)" = "Linux" ] || return 0
  [ "$(_dnet_shape)" = "rootless" ] || return 0
  _dnet_have systemctl || return 0
  local rootful_state
  rootful_state="$(command systemctl is-enabled docker.service 2>/dev/null)"
  case "$rootful_state" in enabled|enabled-runtime) return 0 ;; esac

  local f
  for f in /etc/systemd/system/docker.service.d/http-proxy.conf \
           /etc/systemd/system/docker.service.d/proxy.conf; do
    if [ -f "$f" ]; then
      _dnet_note "stale config" "$f targets the DISABLED rootful daemon — it does nothing"
      _dnet_hint "sudo rm $f"
    fi
  done
  if [ -f /etc/docker/daemon.json ]; then
    _dnet_note "stale config" "/etc/docker/daemon.json is read only by the disabled rootful daemon"
    _dnet_hint "the live config is $(_dnet_daemon_json)"
  fi
}

_dnet_mirrors_check() {
  # Direct only, deliberately: a mirror exists to be reached WITHOUT the proxy
  # (that is why _dnet_no_proxy_value exempts them), so a via-proxy column would
  # measure a path nothing takes in practice.
  local mirror n=0
  printf '\n%s\n' "Registry mirrors (Docker Hub only — nothing else is mirrored)"
  while IFS= read -r mirror; do
    [ -n "$mirror" ] || continue
    n=$((n+1))
    _dnet_report_probe "$(_dnet_host_of "$mirror")" "$mirror/v2/" ""
  done <<EOF
$(_dnet_mirrors)
EOF
  [ "$n" -eq 0 ] && _dnet_skip "none" "no registry-mirrors configured"
  return 0
}

_dnet_doctor() {
  local deep=0 arg
  for arg in "$@"; do
    case "$arg" in --deep|--live) deep=1 ;; esac
  done

  _dnet_report_init
  _dnet_prime_proxy
  if ! _dnet_info_load; then
    printf '\ndocker-net doctor\n\n'
    _dnet_bad "daemon" "unreachable (DOCKER_HOST=${DOCKER_HOST:-<unset>})"
    _dnet_hint "systemctl --user status docker"
    printf '\n1 failed, 0 warning(s)\n\n'
    return 1
  fi

  local shape proxy
  shape="$(_dnet_shape)"
  proxy="$(_dnet_resolve_proxy)" || true

  printf '\ndocker-net doctor   %s docker %s\n' "$shape" "${_DNET_SRV:-?}"

  printf '\n%s\n' "Install shape"
  _dnet_ok "daemon" "$shape, server $_DNET_SRV"
  _dnet_skip "socket" "${DOCKER_HOST:-<default>}"
  local djson
  djson="$(_dnet_daemon_json 2>/dev/null)"
  if [ -n "$djson" ]; then
    if [ -f "$djson" ]; then _dnet_ok "daemon.json" "$djson"
    else _dnet_skip "daemon.json" "$djson (absent — daemon defaults apply)"; fi
  fi

  printf '\n%s\n' "Daemon locality (can it reach a 127.0.0.1 proxy?)"
  local locality
  locality="$(_dnet_daemon_locality)"
  case "$locality" in
    host)
      # rootlesskit >= 2.0 passes --detach-netns, leaving dockerd itself in the
      # host netns (only containers get the slirp4netns one). Most "rootless
      # docker cannot use a 127.0.0.1 proxy" advice online predates this.
      _dnet_ok "host netns" "$(_dnet_locality_detail host)" ;;
    netns)
      _dnet_bad "detached netns" "$(_dnet_locality_detail netns)"
      _dnet_hint "docker-net on http://<host-lan-ip>:<port>" ;;
    vm)
      # macOS: Docker Desktop and OrbStack run the daemon inside a Linux VM, so
      # a loopback address means the VM, not your Mac. This is the same silent
      # failure as the detached-netns case, and /proc cannot show it.
      _dnet_note "VM-backed daemon" "$(_dnet_locality_detail vm)"
      _dnet_hint "configure the proxy in the $(_dnet_shape) UI — see docs/tools/docker-net.md" ;;
    *)
      _dnet_skip "locality" "$(_dnet_locality_detail unknown)" ;;
  esac

  printf '\n%s\n' "Stale configuration"
  local before="$_DNET_WARN"
  _dnet_stale_config_check
  [ "$_DNET_WARN" = "$before" ] && _dnet_ok "none" "no orphaned rootful proxy config"

  printf '\n%s\n' "Local proxy"
  if [ -n "$proxy" ]; then
    _dnet_ok "detected" "$proxy  source=$(_dnet_proxy_source)"
  else
    _dnet_note "detected" "none — \`proxy-status\` agrees; only mirrors and direct egress are available"
  fi
  # Malformed / half-set proxy env is a silent killer for every OTHER tool on the
  # box even when docker itself is fine, so report it here where it gets seen.
  case "${ALL_PROXY:-}${all_proxy:-}" in
    socks://*) _dnet_note "env" "ALL_PROXY uses socks:// — not a scheme Go or curl accepts; use socks5://" ;;
  esac
  if [ -n "${HTTPS_PROXY:-}" ] && [ -z "${https_proxy:-}" ]; then
    _dnet_note "env" "HTTPS_PROXY set but https_proxy is not — tools that only read lowercase go direct"
  fi

  printf '\n%s\n' "Transparent proxy (TUN)"
  local tun fakeip
  tun="$(_dnet_tun_iface 2>/dev/null)"
  fakeip="$(_dnet_fakeip_route)"
  if [ -n "$tun" ] && [ -n "$fakeip" ]; then
    _dnet_ok "$tun" "up, fake-ip route present — daemon egress is proxied at L3"
    _dnet_hint "an explicit \`docker-net on\` is optional while this holds"
  elif [ -n "$tun" ]; then
    _dnet_skip "$tun" "interface exists but no fake-ip route — probably not intercepting"
  else
    _dnet_skip "none" "no TUN interface — the daemon egresses however daemon.json says"
  fi

  _dnet_mirrors_check

  printf '\n%s\n' "Upstream registries (direct)"
  _dnet_report_probe "docker.io"       "https://registry-1.docker.io/v2/" ""
  _dnet_report_probe "ghcr.io"         "https://ghcr.io/v2/"             ""
  _dnet_report_probe "gcr.io"          "https://gcr.io/v2/"              ""
  _dnet_report_probe "quay.io"         "https://quay.io/v2/"             ""
  _dnet_report_probe "registry.k8s.io" "https://registry.k8s.io/v2/"     ""

  if [ -n "$proxy" ]; then
    printf '\n%s\n' "Upstream registries (via $proxy)"
    _dnet_report_probe "docker.io"       "https://registry-1.docker.io/v2/" "$proxy"
    _dnet_report_probe "ghcr.io"         "https://ghcr.io/v2/"             "$proxy"
    _dnet_report_probe "gcr.io"          "https://gcr.io/v2/"              "$proxy"
    _dnet_report_probe "quay.io"         "https://quay.io/v2/"             "$proxy"
    _dnet_report_probe "registry.k8s.io" "https://registry.k8s.io/v2/"     "$proxy"
  fi

  # Everything above tests the SHELL's egress. Only this tests the daemon's, and
  # the two genuinely differ (different netns, different proxy config, different
  # DNS). Pulling a tag that cannot exist reaches the registry without
  # downloading anything.
  printf '\n%s\n' "Daemon-side egress (pull a nonexistent tag; nothing is downloaded)"
  # A repo path component may not begin with an underscore, so a `__probe__`
  # name is rejected client-side as "invalid reference format" and never touches
  # the network — which would silently make this whole section a no-op.
  _dnet_daemon_probe "docker.io" "hello-world:dockernet-probe"
  if [ "$deep" = 1 ]; then
    _dnet_daemon_probe "ghcr.io"         "ghcr.io/dockernet-probe/dockernet-probe:probe"
    _dnet_daemon_probe "gcr.io"          "gcr.io/dockernet-probe/dockernet-probe:probe"
    _dnet_daemon_probe "quay.io"         "quay.io/dockernet-probe/dockernet-probe:probe"
    _dnet_daemon_probe "registry.k8s.io" "registry.k8s.io/dockernet-probe/dockernet-probe:probe"
  else
    _dnet_skip "--deep" "also probe ghcr/gcr/quay/registry.k8s.io from the daemon"
  fi

  printf '\n'
  if [ "$_DNET_FAIL" -gt 0 ]; then
    printf '%d failed, %d warning(s)\n\n' "$_DNET_FAIL" "$_DNET_WARN"
    return 1
  fi
  printf 'all checks passed (%d warning(s))\n\n' "$_DNET_WARN"
  return 0
}

_dnet_daemon_probe() {
  local label="$1" ref="$2" out
  # `timeout` execs a real binary, so `command docker` (a shell builtin prefix)
  # cannot be passed to it — let timeout do its own PATH lookup.
  if _dnet_have timeout; then
    out="$(command timeout 30 docker pull "$ref" 2>&1)"
  else
    out="$(command docker pull "$ref" 2>&1)"
  fi
  case "$out" in
    # A mirror (or registry) answered with an error status. The daemon's network
    # is FINE — the named host is what is broken. This is the single most
    # misread error under the GFW: it reads as "image does not exist" but the URL
    # inside it names the mirror that actually failed.
    *"unexpected status from HEAD request"*)
      # The URL inside this error names WHICH host answered. When that is not the
      # registry we asked for, a registry-mirror intercepted the request — and
      # the mirror, not the network, is the fault. Distinguishing those two is
      # the whole point of this probe.
      local _h _c
      _h="$(printf '%s' "$out" | command sed -n 's#.*request to https\{0,1\}://\([^/]*\)/.*#\1#p' | command head -n 1)"
      _c="$(printf '%s' "$out" | command sed -n 's#.*: \([0-9]\{3\}\) [A-Za-z].*#\1#p' | command head -n 1)"
      if [ -n "$_h" ] && [ "$_h" != "$label" ]; then
        _dnet_note "$label" "daemon egress OK, but mirror $_h answered ${_c:-an error} for the manifest"
        _dnet_hint "that host is in your registry-mirrors — see the mirrors section above"
      else
        case "$_c" in
          401|403|404) _dnet_ok "$label" "registry answered $_c — daemon egress works" ;;
          *)           _dnet_note "$label" "registry answered ${_c:-an error}" ;;
        esac
      fi ;;
    # The registry answered and said no. That is a successful round trip.
    *"manifest unknown"*|*"not found"*|*denied*|*unauthorized*|*Unauthenticated*|*"error from registry"*|*"manifest for"*|*"repository does not exist"*|*"name unknown"*)
      _dnet_ok "$label" "registry answered (auth/404) — daemon egress works" ;;
    *"no such host"*|*"i/o timeout"*|*"context deadline exceeded"*|*"connection refused"*|*"TLS handshake"*|*"EOF"*)
      _dnet_bad "$label" "network fault from the daemon: $(printf '%s' "$out" | command tail -n 1 | command cut -c1-80)" ;;
    *)
      _dnet_note "$label" "$(printf '%s' "$out" | command tail -n 1 | command cut -c1-80)" ;;
  esac
}

_dnet_on() {
  local assume_yes=0 url='' arg
  for arg in "$@"; do
    case "$arg" in
      -y|--yes) assume_yes=1 ;;
      -*) printf 'docker-net on: unknown flag %s\n' "$arg" >&2; return 2 ;;
      *) url="$arg" ;;
    esac
  done

  _dnet_report_init
  _dnet_prime_proxy
  _dnet_info_load || { printf 'docker-net: no reachable Docker daemon\n' >&2; return 1; }

  local proxy shape path noproxy
  proxy="$(_dnet_resolve_proxy "${url:-${DOCKER_NET_PROXY:-auto}}")" || return 2
  if [ -z "$proxy" ]; then
    printf 'docker-net: no proxy detected and none given\n' >&2
    # shellcheck disable=SC2016 # Backticks are literal in the diagnostic message.
    printf '  try: docker-net on http://127.0.0.1:7890   (or start your proxy and `proxy-refresh`)\n' >&2
    return 1
  fi
  shape="$(_dnet_shape)"

  # Refuse early, before computing anything or prompting about containers.
  case "$shape" in
    desktop|orbstack)
      printf 'docker-net: %s runs the daemon inside a VM — its proxy is a UI setting,\n' "$shape" >&2
      printf '  and a %s URL written here would point at the VM, not your Mac.\n' "127.0.0.1" >&2
      case "$shape" in
        orbstack) printf '  OrbStack: Settings > Network > Proxy\n' >&2 ;;
        desktop)  printf '  Docker Desktop: Settings > Resources > Proxies\n' >&2 ;;
      esac
      printf '  docs/tools/docker-net.md explains why, and what still works on macOS.\n' >&2
      return 1 ;;
  esac

  local locality
  locality="$(_dnet_daemon_locality)"
  if [ "$locality" = netns ]; then
    case "$proxy" in
      *//127.0.0.1:*|*//localhost:*|*//::1*|*//\[::1\]*)
        printf 'docker-net: the daemon is in a separate network namespace, so %s\n' "$proxy" >&2
        printf "  reaches the daemon's own loopback and connects to nothing.\n" >&2
        printf "  Pass this host's LAN IP instead: docker-net on http://<lan-ip>:<port>\n" >&2
        return 1 ;;
    esac
  fi

  noproxy="$(_dnet_no_proxy_value)"

  printf '\ndocker-net on   %s\n\n' "$proxy"
  _dnet_skip "no-proxy" "$noproxy"
  _dnet_confirm_restart "$assume_yes" || return 1

  # shellcheck disable=SC2016 # $p/$n are jq --arg bindings, not shell variables.
  path="$(_dnet_edit_daemon_json \
    '.proxies = {"http-proxy": $p, "https-proxy": $p, "no-proxy": $n}' \
    --arg p "$proxy" --arg n "$noproxy")" || return 1
  _dnet_ok "wrote" "$path"

  _dnet_restart_daemon "$shape" || return 1
  # `proxies` is NOT in the SIGHUP-reloadable set, so this had to be a restart.
  command sleep 1
  _dnet_info_load
  if [ -n "${_DNET_HTTPS:-}" ]; then
    _dnet_ok "daemon proxy" "$_DNET_HTTPS"
  else
    _dnet_bad "daemon proxy" "still empty after restart — check \`systemctl --user status docker\`"
    printf '\n'
    return 1
  fi
  printf '\n'
  return 0
}

_dnet_off() {
  local assume_yes=0 arg
  for arg in "$@"; do
    case "$arg" in -y|--yes) assume_yes=1 ;; esac
  done

  _dnet_report_init
  _dnet_info_load || { printf 'docker-net: no reachable Docker daemon\n' >&2; return 1; }
  local shape path
  shape="$(_dnet_shape)"

  printf '\ndocker-net off\n\n'
  _dnet_confirm_restart "$assume_yes" || return 1

  path="$(_dnet_edit_daemon_json 'del(.proxies)')" || return 1
  _dnet_ok "wrote" "$path"

  _dnet_restart_daemon "$shape" || return 1
  command sleep 1
  _dnet_info_load
  if [ -z "${_DNET_HTTPS:-}${_DNET_HTTP:-}" ]; then
    _dnet_ok "daemon proxy" "cleared"
  else
    _dnet_note "daemon proxy" "still ${_DNET_HTTPS:-$_DNET_HTTP} — something else sets it (systemd drop-in?)"
  fi
  printf '\n'
  return 0
}

# Pull with a fallback ladder. Each rung announces itself on stderr, the same way
# try_direct_then_proxy prints "[retry via proxy ...]".
_dnet_pull() {
  local ref="$1"
  [ -n "$ref" ] || { printf 'usage: docker-net pull <image-ref> [docker-pull-args...]\n' >&2; return 2; }
  shift
  _dnet_info_load || { printf 'docker-net: no reachable Docker daemon\n' >&2; return 1; }

  # Rung 1: plain pull. Mirrors apply here (Docker Hub only) and so does any
  # daemon proxy already configured.
  printf '[docker-net] rung 1: docker pull %s\n' "$ref" >&2
  if command docker pull "$@" "$ref"; then return 0; fi

  local split registry rest
  split="$(_dnet_ref_split "$ref")"
  registry="${split%%|*}"; rest="${split#*|}"

  # Rung 2: address a mirror explicitly. Docker only consults registry-mirrors
  # for Docker Hub, and only as a fallback chain it may abandon on the first
  # hard error — naming the mirror bypasses that entirely.
  if [ -z "$registry" ] || [ "$registry" = "docker.io" ]; then
    local hubpath mirror mref
    hubpath="$(_dnet_hub_path "$rest")"
    while IFS= read -r mirror; do
      [ -n "$mirror" ] || continue
      mref="$(_dnet_host_of "$mirror")/$hubpath"
      printf '[docker-net] rung 2: docker pull %s\n' "$mref" >&2
      if command docker pull "$@" "$mref"; then
        command docker tag "$mref" "$ref" && command docker rmi "$mref" >/dev/null 2>&1
        printf '[docker-net] tagged as %s\n' "$ref" >&2
        return 0
      fi
    done <<EOF
$(_dnet_mirrors)
EOF
  else
    printf '[docker-net] rung 2: skipped — registry-mirrors only covers Docker Hub, not %s\n' "$registry" >&2
  fi

  # Rung 3: let the CLIENT do the network. skopeo honours the shell's proxy env
  # and writes straight into the daemon, so this works even when the daemon has
  # no proxy at all and no restart is possible.
  if _dnet_have skopeo; then
    local os arch
    if [ -n "${DOCKER_NET_PLATFORM:-}" ]; then
      os="${DOCKER_NET_PLATFORM%%/*}"; arch="${DOCKER_NET_PLATFORM#*/}"
    fi
    printf '[docker-net] rung 3: skopeo copy docker://%s docker-daemon:%s (client-side, via proxy)\n' "$ref" "$ref" >&2
    local canonical="$ref"
    case "$canonical" in *:*) ;; *) canonical="$canonical:latest" ;; esac
    if [ -n "${os:-}" ]; then
      if _dnet_withproxy skopeo copy --retry-times 3 --override-os "$os" --override-arch "$arch" \
           "docker://$canonical" "docker-daemon:$canonical"; then return 0; fi
    else
      if _dnet_withproxy skopeo copy --retry-times 3 \
           "docker://$canonical" "docker-daemon:$canonical"; then return 0; fi
    fi
  else
    printf '[docker-net] rung 3: skipped — skopeo not installed\n' >&2
    printf '[docker-net]   install it: sudo apt install skopeo   (or: brew install skopeo)\n' >&2
  fi

  # Rung 4: out of tricks. The remaining lever needs a daemon restart.
  printf '\n[docker-net] all rungs failed for %s\n' "$ref" >&2
  printf '[docker-net]   docker-net doctor      # find out which layer is broken\n' >&2
  printf '[docker-net]   docker-net on          # give the daemon itself a proxy (restarts it)\n' >&2
  return 1
}

_dnet_usage() {
  command cat <<'EOF'
Usage: docker-net [status|doctor [--deep]|on [URL] [-y]|off [-y]|mirrors|pull REF [args...]]

  status              install shape, daemon proxy, mirrors, detected local proxy
  doctor [--deep]     full diagnosis; --deep also probes ghcr/gcr/quay/k8s from
                      the daemon's side (slower, still downloads nothing)
  on [URL] [-y]       write daemon.json `proxies` and RESTART the daemon.
                      URL defaults to whatever proxy-status detects.
  off [-y]            remove it and restart
  mirrors             mirror health only (fast)
  pull REF [args...]  pull with a fallback ladder:
                        1. docker pull            (mirrors apply, Docker Hub only)
                        2. explicit mirror prefix + retag   (Docker Hub only)
                        3. skopeo copy via the shell's proxy (no daemon restart)

  DOCKER_NET_PROXY    auto|always|never|http://host:port   (default auto)
  DOCKER_NET_NO_PROXY extra comma-separated no-proxy entries
  DOCKER_NET_MIRRORS  override the mirror list used for probing
  DOCKER_NET_PLATFORM os/arch for the skopeo rung (e.g. linux/amd64)

Why a daemon restart: `docker pull` runs in the daemon, so only daemon.json
`proxies` affects it — and unlike `registry-mirrors` that key is not
SIGHUP-reloadable. Docs: docs/tools/docker-net.md
EOF
}

docker-net() {
  local action="${1:-status}"
  [ $# -gt 0 ] && shift
  case "$action" in
    status)          _dnet_status "$@" ;;
    doctor|test)     _dnet_doctor "$@" ;;
    on|enable)       _dnet_on "$@" ;;
    off|disable)     _dnet_off "$@" ;;
    mirrors)
      _dnet_report_init
      if _dnet_info_load; then _dnet_mirrors_check; printf '\n'
      else printf 'docker-net: no reachable Docker daemon\n' >&2; return 1; fi ;;
    pull)            _dnet_pull "$@" ;;
    -h|--help|help)  _dnet_usage ;;
    *)               printf 'docker-net: unknown action %s\n\n' "$action" >&2; _dnet_usage; return 2 ;;
  esac
}
