# 50_networking.sh - Networking tool aliases and helpers (shared bash + zsh).
# Moved from dot_config/zsh/tools/50_networking.zsh; the only zsh-isms were
# `print -r --` / `print -u2` / `print "..."` which all became `printf`.

# --- Listening ports (works everywhere, no extra install needed) ---
alias ports='lsof -i -P -n | grep LISTEN'

# --- IP address helpers ---
alias myip='curl -s https://ifconfig.me'
if [[ "$OSTYPE" == darwin* ]]; then
  alias localip='ipconfig getifaddr en0'
else
  alias localip='hostname -I | awk "{print \$1}"'
fi

# --- nmap shortcuts ---
if command -v nmap &>/dev/null; then
  # Quick ping sweep of local /24 subnet
  pingsweep() {
    local ip
    if [[ "$OSTYPE" == darwin* ]]; then
      ip=$(ipconfig getifaddr en0 2>/dev/null)
    else
      ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    local base="${ip%.*}.0/24"
    echo "Scanning $base ..."
    nmap -sn "$base"
  }
fi

# --- arp-scan ---
if command -v arp-scan &>/dev/null; then
  alias arpscan='sudo arp-scan -l'
fi

# --- doggo (modern DNS lookup with DoH/DoT/DoQ) ---
if command -v doggo &>/dev/null; then
  alias dns='doggo'
fi

# --- gping (graphical ping) ---
# gping is already short enough, no alias needed

# --- trippy (TUI traceroute, binary is 'trip') ---
# trip is already short enough, no alias needed

# --- bandwhich (bandwidth monitor, needs sudo for packet capture) ---
if command -v bandwhich &>/dev/null; then
  alias bw-net='sudo bandwhich'
fi

# --- rustscan (fast port scanner -> nmap) ---
if command -v rustscan &>/dev/null; then
  alias portscan='rustscan'
fi

# --- speedtest (Ookla CLI) ---
# speedtest is already short enough, no alias needed

# --- LAN device scanner (feeds `tv lan-devices`) ---
if [[ -x "$HOME/.config/television/lan-scan.sh" ]]; then
  alias lanscan="$HOME/.config/television/lan-scan.sh all"
  alias tv-lan='tv lan-devices'
fi

# --- Proxy helpers (generic) ---
# Portable proxy management: honor $LOCAL_PROXY_URL, else prefer an active
# Clash config, else auto-probe common loopback ports (Clash 7890/7891,
# ClashX 1087, Privoxy 8118, generic 8080). Detection result is cached
# per-shell in _NET_PROXY_CACHE; use `proxy-refresh` after
# starting/stopping the proxy.
#
# Environment variables honored:
#   LOCAL_PROXY_URL         HTTP/HTTPS proxy URL (e.g. http://127.0.0.1:7890).
#                           If unset, ports are auto-probed.
#   LOCAL_PROXY_SOCKS_URL   Optional separate SOCKS5 endpoint (e.g.
#                           socks5://127.0.0.1:7891). Used for ALL_PROXY /
#                           all_proxy when set; otherwise these fall back to
#                           LOCAL_PROXY_URL / the probe result. Useful when
#                           Clash is configured with split `port:` and
#                           `socks-port:` instead of `mixed-port:`.
#   LOCAL_PROXY_AUTO_ACTIVATE=1  Run `proxy-on` silently at shell startup
#                           whenever a proxy is detected. Handy on machines
#                           that always route through the local proxy.

: "${_NET_PROXY_CACHE:=}"
: "${_NET_PROXY_SOCKS_CACHE:=}"
: "${_NET_PROXY_SOURCE_CACHE:=}"
__NET_PROXY_PROBE_PORTS=(7890 7891 1087 8118 8080)
__NET_PROXY_CLASH_CONFIG_CANDIDATES=(
  "$HOME/.config/clash/config.yaml"
  "$HOME/.config/clash/config.yml"
  "$HOME/Library/Application Support/clash/config.yaml"
  "$HOME/Library/Application Support/clash/config.yml"
)

__net_clear_proxy_cache() {
  _NET_PROXY_CACHE=""
  _NET_PROXY_SOCKS_CACHE=""
  _NET_PROXY_SOURCE_CACHE=""
}

__net_set_proxy_cache() {
  _NET_PROXY_CACHE="$1"
  _NET_PROXY_SOCKS_CACHE="$2"
  _NET_PROXY_SOURCE_CACHE="$3"
}

__net_port_open() {
  nc -z -w1 127.0.0.1 "$1" 2>/dev/null
}

__net_find_clash_config() {
  local candidate
  for candidate in "${__NET_PROXY_CLASH_CONFIG_CANDIDATES[@]}"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

__net_yaml_scalar() {
  local key="$1"
  local config_path="$2"
  awk -v key="$key" '
    {
      line = $0
      sub(/\r$/, "", line)
      if (line ~ /^[[:space:]]*#/) {
        next
      }
      sub(/[[:space:]]+#.*/, "", line)
      if (line ~ "^[[:space:]]*" key ":[[:space:]]*") {
        sub("^[[:space:]]*" key ":[[:space:]]*", "", line)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        gsub(/^["'"'"']|["'"'"']$/, "", line)
        print line
        exit
      }
    }
  ' "$config_path"
}

__net_detect_clash_proxy() {
  local config_path mixed_port http_port socks_port socks_url=""
  config_path="$(__net_find_clash_config)" || return 1

  mixed_port="$(__net_yaml_scalar "mixed-port" "$config_path")"
  if [[ -n "$mixed_port" ]] && __net_port_open "$mixed_port"; then
    __net_set_proxy_cache \
      "http://127.0.0.1:$mixed_port" \
      "socks5://127.0.0.1:$mixed_port" \
      "clash config"
    return 0
  fi

  http_port="$(__net_yaml_scalar "port" "$config_path")"
  socks_port="$(__net_yaml_scalar "socks-port" "$config_path")"
  if [[ -n "$http_port" ]] && __net_port_open "$http_port"; then
    if [[ -n "$socks_port" ]] && __net_port_open "$socks_port"; then
      socks_url="socks5://127.0.0.1:$socks_port"
    fi
    __net_set_proxy_cache \
      "http://127.0.0.1:$http_port" \
      "$socks_url" \
      "clash config"
    return 0
  fi

  return 1
}

__net_detect_proxy() {
  if [[ -n "$LOCAL_PROXY_URL" ]]; then
    __net_set_proxy_cache \
      "$LOCAL_PROXY_URL" \
      "$LOCAL_PROXY_SOCKS_URL" \
      "LOCAL_PROXY_URL env"
    return 0
  fi
  if __net_detect_clash_proxy; then
    return 0
  fi
  if [[ -n "$_NET_PROXY_CACHE" ]]; then
    [[ "$_NET_PROXY_CACHE" == "none" ]] && return 1
    return 0
  fi
  local port
  for port in "${__NET_PROXY_PROBE_PORTS[@]}"; do
    if __net_port_open "$port"; then
      __net_set_proxy_cache "http://127.0.0.1:$port" "" "probe"
      return 0
    fi
  done
  __net_set_proxy_cache "none" "" "probe"
  return 1
}

# Resolve the URL that should be used for ALL_PROXY / all_proxy.
# Falls back to the HTTP proxy when no SOCKS-specific URL is set (works for
# mixed-port Clash configs where one port serves both HTTP and SOCKS).
__net_all_proxy_url() {
  if [[ -n "$LOCAL_PROXY_SOCKS_URL" ]]; then
    printf '%s\n' "$LOCAL_PROXY_SOCKS_URL"
  elif [[ -n "$_NET_PROXY_SOCKS_CACHE" ]]; then
    printf '%s\n' "$_NET_PROXY_SOCKS_CACHE"
  else
    printf '%s\n' "$_NET_PROXY_CACHE"
  fi
}

# Run one command with proxy env applied to the child process only.
withproxy() {
  __net_detect_proxy
  if [[ "$_NET_PROXY_CACHE" == "none" ]]; then
    "$@"
    return
  fi
  local all_url
  all_url="$(__net_all_proxy_url)"
  http_proxy="$_NET_PROXY_CACHE" \
  https_proxy="$_NET_PROXY_CACHE" \
  HTTP_PROXY="$_NET_PROXY_CACHE" \
  HTTPS_PROXY="$_NET_PROXY_CACHE" \
  ALL_PROXY="$all_url" \
  all_proxy="$all_url" \
    "$@"
}

# Run direct first; on non-zero exit, retry via proxy if one is available.
try_direct_then_proxy() {
  "$@" && return 0
  local rc=$?
  __net_detect_proxy
  if [[ "$_NET_PROXY_CACHE" == "none" ]]; then
    return $rc
  fi
  printf '%s\n' "[retry via proxy $_NET_PROXY_CACHE]" >&2
  withproxy "$@"
}

# Export proxy env vars to the current shell (all downstream commands inherit).
# If $1 is "-q", suppress the success message (used by auto-activate).
proxy-on() {
  local quiet=0
  [[ "$1" == "-q" ]] && quiet=1
  __net_detect_proxy
  if [[ "$_NET_PROXY_CACHE" == "none" ]]; then
    (( quiet )) || printf '%s\n' "proxy-on: no proxy detected (set \$LOCAL_PROXY_URL or start your proxy, then \`proxy-refresh\`)" >&2
    return 1
  fi
  local all_url
  all_url="$(__net_all_proxy_url)"
  export http_proxy="$_NET_PROXY_CACHE" \
         https_proxy="$_NET_PROXY_CACHE" \
         HTTP_PROXY="$_NET_PROXY_CACHE" \
         HTTPS_PROXY="$_NET_PROXY_CACHE" \
         ALL_PROXY="$all_url" \
         all_proxy="$all_url"
  if (( ! quiet )); then
    if [[ "$all_url" == "$_NET_PROXY_CACHE" ]]; then
      printf '%s\n' "proxy ON  ->  $_NET_PROXY_CACHE"
    else
      printf '%s\n' "proxy ON  ->  http/https=$_NET_PROXY_CACHE  all/socks=$all_url"
    fi
  fi
}

# Unset all proxy env vars from the current shell.
proxy-off() {
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy NO_PROXY no_proxy
  __net_clear_proxy_cache
  printf '%s\n' "proxy OFF"
}

# Report current proxy state: active / available / unavailable.
proxy-status() {
  __net_detect_proxy
  local shell_active=""
  if [[ -n "$http_proxy$https_proxy$ALL_PROXY" ]]; then
    shell_active="yes"
  fi
  local source="${_NET_PROXY_SOURCE_CACHE:-probe}"

  if [[ "$_NET_PROXY_CACHE" == "none" ]]; then
    printf '%s\n' "proxy: unavailable (no \$LOCAL_PROXY_URL; no loopback port from ${__NET_PROXY_PROBE_PORTS[*]} reachable)"
    [[ -n "$shell_active" ]] && printf '%s\n' "  note: shell env still has proxy vars set -- run \`proxy-off\` to clear"
    return 1
  fi

  local state="available"
  [[ -n "$shell_active" ]] && state="active   "
  local hint="(not exported; use \`withproxy\`, \`try_direct_then_proxy\`, or \`proxy-on\`)"
  [[ -n "$shell_active" ]] && hint="(exported in current shell)"
  local all_url all_source
  all_url="$(__net_all_proxy_url)"
  all_source="$source"
  [[ -n "$LOCAL_PROXY_SOCKS_URL" ]] && all_source="LOCAL_PROXY_SOCKS_URL env"

  printf '%s\n' "proxy: $state http=$_NET_PROXY_CACHE  source=$source  $hint"
  if [[ -n "$all_url" && "$all_url" != "$_NET_PROXY_CACHE" ]]; then
    printf '%s\n' "  socks=$all_url  source=$all_source"
  fi
}

# Validate that the detected proxy can actually reach the public internet.
# ICMP ping does not honor proxy env vars, so use Google's HTTP 204 endpoint.
proxy-test() {
  local url="${1:-https://www.google.com/generate_204}"
  if ! command -v curl >/dev/null 2>&1; then
    printf '%s\n' "proxy-test: curl not found" >&2
    return 127
  fi

  __net_detect_proxy
  if [[ "$_NET_PROXY_CACHE" == "none" ]]; then
    printf '%s\n' "proxy-test: no proxy detected (set \$LOCAL_PROXY_URL or start your proxy, then \`proxy-refresh\`)" >&2
    return 1
  fi

  local all_url
  all_url="$(__net_all_proxy_url)"
  printf '%s\n' "proxy-test: http=$_NET_PROXY_CACHE  all=$all_url  url=$url"
  withproxy curl -sS -o /dev/null \
    -w 'proxy-test: http=%{http_code} remote=%{remote_ip} total=%{time_total}s\n' \
    --max-time 10 "$url"
}

# Clear the cached detection and re-probe; call after toggling your proxy.
proxy-refresh() {
  __net_clear_proxy_cache
  __net_detect_proxy
  proxy-status
}

# Optional auto-activation: when $LOCAL_PROXY_AUTO_ACTIVATE=1 is set before
# this file is sourced, silently call `proxy-on` if a proxy is detected.
# Set the env var in a machine-local shell file (or ~/.zshenv / ~/.profile) on
# machines that should always route through the loopback proxy.
if [[ "$LOCAL_PROXY_AUTO_ACTIVATE" == "1" ]]; then
  proxy-on -q
fi

# --- Rootless Docker socket ---
# Point the Docker CLI at the user-scoped socket when rootless Docker is
# installed. Without this, `docker` defaults to /var/run/docker.sock (the
# rootful path) and fails with "Cannot connect to the Docker daemon".
# Guarded on socket existence so this is a no-op on:
#   - macOS (OrbStack / Docker Desktop publish their own sockets, don't need this)
#   - Linux boxes still running rootful Docker (the rootful socket is under /var/run)
# Respect a pre-existing $DOCKER_HOST so a user-set value wins.
# See docs/tools/container-config-map.md for the full install-variant map.
if [[ "$(uname -s)" == "Linux" && -z "$DOCKER_HOST" ]]; then
  _net_xdg_runtime="${XDG_RUNTIME_DIR:-/run/user/$UID}"
  if [[ -S "${_net_xdg_runtime}/docker.sock" ]]; then
    export DOCKER_HOST="unix://${_net_xdg_runtime}/docker.sock"
  fi
  unset _net_xdg_runtime
fi
