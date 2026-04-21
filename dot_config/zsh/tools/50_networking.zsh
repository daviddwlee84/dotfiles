# 50_networking.zsh - Networking tool aliases and helpers

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
# Portable proxy management: honor $LOCAL_PROXY_URL, else auto-probe common
# loopback ports (Clash 7890/7891, ClashX 1087, Privoxy 8118, generic 8080).
# Detection result is cached per-shell in _ZSH_NET_PROXY_CACHE; use
# `proxy-refresh` after starting/stopping the proxy.

: "${_ZSH_NET_PROXY_CACHE:=}"
__ZSH_NET_PROXY_PROBE_PORTS=(7890 7891 1087 8118 8080)

__zsh_net_detect_proxy() {
  [[ -n "$_ZSH_NET_PROXY_CACHE" ]] && return 0
  if [[ -n "$LOCAL_PROXY_URL" ]]; then
    _ZSH_NET_PROXY_CACHE="$LOCAL_PROXY_URL"
    return 0
  fi
  local port
  for port in "${__ZSH_NET_PROXY_PROBE_PORTS[@]}"; do
    if nc -z -w1 127.0.0.1 "$port" 2>/dev/null; then
      _ZSH_NET_PROXY_CACHE="http://127.0.0.1:$port"
      return 0
    fi
  done
  _ZSH_NET_PROXY_CACHE="none"
  return 1
}

# Run one command with proxy env applied to the child process only.
withproxy() {
  __zsh_net_detect_proxy
  if [[ "$_ZSH_NET_PROXY_CACHE" == "none" ]]; then
    "$@"
    return
  fi
  http_proxy="$_ZSH_NET_PROXY_CACHE" \
  https_proxy="$_ZSH_NET_PROXY_CACHE" \
  HTTP_PROXY="$_ZSH_NET_PROXY_CACHE" \
  HTTPS_PROXY="$_ZSH_NET_PROXY_CACHE" \
  ALL_PROXY="$_ZSH_NET_PROXY_CACHE" \
    "$@"
}

# Run direct first; on non-zero exit, retry via proxy if one is available.
try_direct_then_proxy() {
  "$@" && return 0
  local rc=$?
  __zsh_net_detect_proxy
  if [[ "$_ZSH_NET_PROXY_CACHE" == "none" ]]; then
    return $rc
  fi
  print -u2 "[retry via proxy $_ZSH_NET_PROXY_CACHE]"
  withproxy "$@"
}

# Export proxy env vars to the current shell (all downstream commands inherit).
proxy-on() {
  __zsh_net_detect_proxy
  if [[ "$_ZSH_NET_PROXY_CACHE" == "none" ]]; then
    print -u2 "proxy-on: no proxy detected (set \$LOCAL_PROXY_URL or start your proxy, then \`proxy-refresh\`)"
    return 1
  fi
  export http_proxy="$_ZSH_NET_PROXY_CACHE" \
         https_proxy="$_ZSH_NET_PROXY_CACHE" \
         HTTP_PROXY="$_ZSH_NET_PROXY_CACHE" \
         HTTPS_PROXY="$_ZSH_NET_PROXY_CACHE" \
         ALL_PROXY="$_ZSH_NET_PROXY_CACHE"
  print "proxy ON  ->  $_ZSH_NET_PROXY_CACHE"
}

# Unset all proxy env vars from the current shell.
proxy-off() {
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY no_proxy
  print "proxy OFF"
}

# Report current proxy state: active / available / unavailable.
proxy-status() {
  __zsh_net_detect_proxy
  local shell_active=""
  if [[ -n "$http_proxy$https_proxy$ALL_PROXY" ]]; then
    shell_active="yes"
  fi
  local source="probe"
  [[ -n "$LOCAL_PROXY_URL" ]] && source="LOCAL_PROXY_URL env"

  if [[ "$_ZSH_NET_PROXY_CACHE" == "none" ]]; then
    print "proxy: unavailable (no \$LOCAL_PROXY_URL; no loopback port from ${__ZSH_NET_PROXY_PROBE_PORTS[*]} reachable)"
    [[ -n "$shell_active" ]] && print "  note: shell env still has proxy vars set -- run \`proxy-off\` to clear"
    return 1
  fi

  if [[ -n "$shell_active" ]]; then
    print "proxy: active    url=$_ZSH_NET_PROXY_CACHE  source=$source  (exported in current shell)"
  else
    print "proxy: available url=$_ZSH_NET_PROXY_CACHE  source=$source  (not exported; use \`withproxy\`, \`try_direct_then_proxy\`, or \`proxy-on\`)"
  fi
}

# Clear the cached detection and re-probe; call after toggling your proxy.
proxy-refresh() {
  _ZSH_NET_PROXY_CACHE=""
  __zsh_net_detect_proxy
  proxy-status
}
