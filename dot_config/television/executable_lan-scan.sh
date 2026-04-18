#!/usr/bin/env bash
# lan-scan.sh - discover devices on the local subnet and probe open ports.
#
# Writes TSV rows incrementally to ~/.cache/tv/lan-devices.tsv so a
# Television channel can tail the file via `watch`. Per-host port scan
# results go to ~/.cache/tv/lan-ports/<ip>.txt.
#
# Usage:
#   lan-scan.sh discover           # layer-2/3 discovery + enrichment only
#   lan-scan.sh ports [--host IP]  # port scan all cached hosts, or one
#   lan-scan.sh all                # discover, then ports (default)
#   lan-scan.sh clean              # purge cache
#
# Sudo gating: uses `sudo -n arp-scan` when passwordless sudo is
# available; otherwise falls back to nmap -sn ping sweep + ARP cache.

set -u

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/tv"
TSV="$CACHE_DIR/lan-devices.tsv"
PORTS_DIR="$CACHE_DIR/lan-ports"
LOCK="$CACHE_DIR/lan-scan.lock"
LOG="$CACHE_DIR/lan-scan.log"

mkdir -p "$CACHE_DIR" "$PORTS_DIR"

# TSV columns: ip \t mac \t vendor \t hostname \t port_count \t top_services \t rtt_ms \t last_seen \t state
TSV_HEADER=$'ip\tmac\tvendor\thostname\tports\ttop\trtt\tseen\tstate'

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >> "$LOG"; }

# ------------------------------------------------------------------
# Platform helpers
# ------------------------------------------------------------------
is_macos() { [[ "$(uname -s)" == Darwin ]]; }

detect_subnet() {
  # Prints CIDR (e.g. 192.168.1.0/24) on stdout, "" on failure.
  local iface ip mask cidr
  if is_macos; then
    iface=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')
    [[ -z "$iface" ]] && return 1
    ip=$(ipconfig getifaddr "$iface" 2>/dev/null)
    mask=$(ifconfig "$iface" 2>/dev/null | awk '/inet / {print $4; exit}')
    # mask is hex like 0xffffff00
    if [[ "$mask" =~ ^0x ]]; then
      local m=$((mask)) bits=0 b
      for b in 0 1 2 3; do
        local octet=$(( (m >> (24 - b*8)) & 0xff ))
        while ((octet)); do bits=$((bits + (octet & 1))); octet=$((octet >> 1)); done
      done
      cidr=$bits
    fi
  else
    local line
    line=$(ip -4 route show default 2>/dev/null | awk 'NR==1{print $5}')
    iface="$line"
    [[ -z "$iface" ]] && return 1
    line=$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk 'NR==1{print $4}')
    ip="${line%/*}"
    cidr="${line#*/}"
  fi
  [[ -z "${ip:-}" || -z "${cidr:-}" ]] && return 1
  # Convert ip + cidr to network address
  local IFS=. a b c d
  read -r a b c d <<<"$ip"
  local ip_int=$(( (a<<24) | (b<<16) | (c<<8) | d ))
  local mask_int=$(( 0xFFFFFFFF << (32 - cidr) & 0xFFFFFFFF ))
  local net_int=$(( ip_int & mask_int ))
  printf '%d.%d.%d.%d/%d\n' \
    $(( (net_int>>24)&0xff )) $(( (net_int>>16)&0xff )) \
    $(( (net_int>>8)&0xff ))  $(( net_int&0xff )) "$cidr"
}

can_sudo_n() { sudo -n true 2>/dev/null; }

# ------------------------------------------------------------------
# OUI vendor lookup (fallback when arp-scan isn't used)
# ------------------------------------------------------------------
# Cache path for nmap's OUI db (macOS Homebrew vs Linux distro paths vary).
find_oui_db() {
  local p
  for p in \
    /usr/share/nmap/nmap-mac-prefixes \
    /opt/homebrew/share/nmap/nmap-mac-prefixes \
    /usr/local/share/nmap/nmap-mac-prefixes \
    /usr/share/arp-scan/ieee-oui.txt; do
    [[ -r "$p" ]] && { printf '%s\n' "$p"; return; }
  done
}
OUI_DB="$(find_oui_db || true)"

vendor_for_mac() {
  local mac="${1:-}"
  [[ -z "$mac" || -z "$OUI_DB" ]] && return
  # Normalize to uppercase, drop separators, take first 6 hex chars
  local prefix
  prefix=$(printf '%s' "$mac" | tr 'a-f' 'A-F' | tr -d ':-' | cut -c1-6)
  [[ ${#prefix} -lt 6 ]] && return
  # nmap-mac-prefixes: "001122 VendorName"; arp-scan ieee-oui.txt: "001122\tVendorName"
  awk -v p="$prefix" '
    BEGIN{IGNORECASE=0}
    $1==p { $1=""; sub(/^[ \t]+/,""); print; exit }
  ' "$OUI_DB" 2>/dev/null
}

# ------------------------------------------------------------------
# Hostname resolution (rDNS + mDNS, timeboxed)
# ------------------------------------------------------------------
resolve_hostname() {
  local ip="$1" h=""
  h=$(timeout 1 getent hosts "$ip" 2>/dev/null | awk '{print $2; exit}')
  if [[ -z "$h" ]]; then
    h=$(timeout 1 dig +short +time=1 +tries=1 -x "$ip" 2>/dev/null \
        | grep -v -E '^;|Warning|connection timed out' \
        | head -1 | sed 's/\.$//')
  fi
  if [[ -z "$h" ]] && command -v avahi-resolve >/dev/null 2>&1; then
    h=$(timeout 1 avahi-resolve -a "$ip" 2>/dev/null | awk '{print $2; exit}')
  fi
  if [[ -z "$h" ]] && is_macos && command -v dscacheutil >/dev/null 2>&1; then
    h=$(timeout 1 dscacheutil -q host -a ip_address "$ip" 2>/dev/null | awk '/^name:/ {print $2; exit}')
  fi
  # Sanitize: strip tabs/newlines that would corrupt TSV
  h=$(printf '%s' "$h" | tr -d '\t\n\r')
  printf '%s' "${h:--}"
}

# Filter junk addresses: link-local, multicast, broadcast, network, loopback.
is_usable_ip() {
  local ip="$1"
  [[ -z "$ip" ]] && return 1
  local IFS=. a b c d
  read -r a b c d <<<"$ip"
  [[ "$a" == "169" && "$b" == "254" ]] && return 1    # link-local
  (( a >= 224 && a <= 239 )) && return 1              # multicast
  (( a == 255 || a == 0 )) && return 1
  [[ "$d" == "0" || "$d" == "255" ]] && return 1      # common /24 net/bcast
  return 0
}

ping_rtt_ms() {
  local ip="$1" out
  if is_macos; then
    out=$(ping -c 1 -W 1000 "$ip" 2>/dev/null | awk -F'time=' '/time=/ {print $2; exit}')
  else
    out=$(ping -c 1 -W 1 "$ip" 2>/dev/null | awk -F'time=' '/time=/ {print $2; exit}')
  fi
  printf '%s' "${out%% *}" | awk '{printf "%.1f", $1}'
}

# ------------------------------------------------------------------
# Discovery
# ------------------------------------------------------------------
# Emits "ip\tmac" pairs, one per line. Unknown MAC emits "-".
discover_hosts() {
  local cidr="$1"

  if command -v arp-scan >/dev/null 2>&1 && can_sudo_n; then
    log "discovery: arp-scan (privileged)"
    sudo -n arp-scan --localnet --plain --quiet 2>/dev/null \
      | awk 'NF>=2 && $1 ~ /^[0-9]+\./ {
          vendor=""; for(i=3;i<=NF;i++){ vendor=vendor (i>3?" ":"") $i }
          printf "%s\t%s\t%s\n", $1, toupper($2), vendor
        }'
    return
  fi

  log "discovery: nmap -sn fallback (no sudo)"
  if command -v nmap >/dev/null 2>&1; then
    nmap -sn -n --min-parallelism 32 "$cidr" >/dev/null 2>&1
  else
    # last resort: pinger
    local IFS=. a b c d cidr_bits
    read -r a b c d <<<"${cidr%/*}"
    cidr_bits="${cidr#*/}"
    if [[ "$cidr_bits" == 24 ]]; then
      for i in $(seq 1 254); do
        ping -c 1 -W 1 "$a.$b.$c.$i" >/dev/null 2>&1 &
      done
      wait
    fi
  fi

  # Read ARP cache
  if is_macos; then
    arp -an 2>/dev/null \
      | awk '/\(([0-9]+\.){3}[0-9]+\)/ {
          gsub(/[()]/,"",$2); ip=$2; mac=toupper($4);
          if (mac != "INCOMPLETE" && mac != "(INCOMPLETE)") printf "%s\t%s\t\n", ip, mac
        }'
  else
    ip neigh show 2>/dev/null \
      | awk 'NF>=5 && $1 ~ /^[0-9]+\./ && $5 !~ /FAILED|INCOMPLETE/ {
          printf "%s\t%s\t\n", $1, toupper($5)
        }'
  fi
}

# ------------------------------------------------------------------
# Writing rows (atomic replacement per host)
# ------------------------------------------------------------------
upsert_row() {
  # args: ip mac vendor hostname ports top rtt state
  local ip="$1" mac="$2" vendor="$3" host="$4" ports="$5" top="$6" rtt="$7" state="$8"
  local seen
  seen=$(date +%H:%M:%S)
  local row
  row=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$ip" "${mac:--}" "${vendor:--}" "${host:--}" "${ports:--}" "${top:--}" "${rtt:--}" "$seen" "$state")
  # Replace existing row with same IP, preserve header.
  local tmp="$TSV.tmp.$$"
  {
    if [[ -f "$TSV" ]]; then
      awk -v ip="$ip" -F'\t' '$1 != ip' "$TSV"
    else
      printf '%s\n' "$TSV_HEADER"
    fi
    printf '%s\n' "$row"
  } | awk 'NR==1{print; next} {print | "sort -t. -k1,1n -k2,2n -k3,3n -k4,4n"}' > "$tmp"
  mv "$tmp" "$TSV"
}

# ------------------------------------------------------------------
# Port scanning (per host)
# ------------------------------------------------------------------
scan_ports() {
  local ip="$1" outfile="$PORTS_DIR/$ip.txt"
  local ports="" top="" count=0

  if command -v rustscan >/dev/null 2>&1; then
    # rustscan greppable-like output; -g gives "ip -> [p1,p2,...]"
    local raw
    raw=$(timeout 30 rustscan -a "$ip" -g --timeout 1500 --ulimit 5000 2>/dev/null | tail -n 1)
    # raw is "ip -> [22,80,443]" or empty
    ports=$(printf '%s' "$raw" | sed -n 's/.*\[\(.*\)\].*/\1/p')
    if [[ -n "$ports" ]]; then
      # Use nmap for service names on discovered ports only
      if command -v nmap >/dev/null 2>&1; then
        nmap -sV -Pn -p "$ports" "$ip" 2>/dev/null > "$outfile"
        top=$(awk '/^[0-9]+\/(tcp|udp)/ {split($1,a,"/"); svc=$3; printf "%s/%s,", a[1], svc}' "$outfile" \
              | sed 's/,$//' | cut -c1-60)
      else
        printf '%s\n' "$raw" > "$outfile"
        top="$ports"
      fi
      count=$(printf '%s' "$ports" | awk -F, '{print NF}')
    else
      : > "$outfile"
    fi
  elif command -v nmap >/dev/null 2>&1; then
    nmap -F -sV -Pn "$ip" 2>/dev/null > "$outfile"
    top=$(awk '/^[0-9]+\/(tcp|udp).*open/ {split($1,a,"/"); printf "%s/%s,", a[1], $3}' "$outfile" \
          | sed 's/,$//' | cut -c1-60)
    count=$(awk '/^[0-9]+\/(tcp|udp).*open/' "$outfile" | wc -l | tr -d ' ')
  fi

  printf '%s\t%s' "$count" "$top"
}

# ------------------------------------------------------------------
# Phases
# ------------------------------------------------------------------
phase_discover() {
  local cidr
  cidr=$(detect_subnet || true)
  if [[ -z "$cidr" ]]; then
    log "subnet detection failed, falling back to 192.168.1.0/24"
    cidr="192.168.1.0/24"
  fi
  log "discovering $cidr"

  # Seed TSV with header
  printf '%s\n' "$TSV_HEADER" > "$TSV"

  # Discovery produces ip\tmac\tvendor(optional)
  local line ip mac vendor
  while IFS=$'\t' read -r ip mac vendor; do
    is_usable_ip "$ip" || continue
    [[ -z "$vendor" ]] && vendor=$(vendor_for_mac "$mac")
    upsert_row "$ip" "$mac" "$vendor" "" "" "" "" "discovered"
  done < <(discover_hosts "$cidr")

  # Serial enrichment: hostname + rtt. Shared TSV writes would race under
  # parallelism, and typical LANs have few enough hosts that serial is fine.
  local host rtt cur c_mac c_vendor c_ports c_top
  while IFS= read -r ip; do
    host=$(resolve_hostname "$ip")
    rtt=$(ping_rtt_ms "$ip")
    cur=$(awk -v ip="$ip" -F'\t' '$1==ip {print; exit}' "$TSV")
    IFS=$'\t' read -r _ c_mac c_vendor _ c_ports c_top _ _ _ <<<"$cur"
    upsert_row "$ip" "$c_mac" "$c_vendor" "$host" "$c_ports" "$c_top" "$rtt" "discovered"
  done < <(awk -F'\t' 'NR>1 {print $1}' "$TSV")
  log "discovery complete: $(awk 'NR>1' "$TSV" | wc -l | tr -d ' ') hosts"
}

phase_ports() {
  local only_host="${1:-}"
  local ips
  if [[ -n "$only_host" ]]; then
    ips="$only_host"
  else
    ips=$(awk -F'\t' 'NR>1 {print $1}' "$TSV")
  fi
  log "port-scanning $(printf '%s\n' "$ips" | wc -l | tr -d ' ') host(s)"

  # Serial port scan; rustscan is already fast internally and shared-TSV
  # writes would race under parallelism.
  local cur c_mac c_vendor c_host c_rtt pt count top
  for ip in $ips; do
    cur=$(awk -v ip="$ip" -F'\t' '$1==ip {print; exit}' "$TSV")
    [[ -z "$cur" ]] && continue
    IFS=$'\t' read -r _ c_mac c_vendor c_host _ _ c_rtt _ _ <<<"$cur"
    upsert_row "$ip" "$c_mac" "$c_vendor" "$c_host" "..." "scanning..." "$c_rtt" "scanning"
    pt=$(scan_ports "$ip")
    count="${pt%%$'\t'*}"; top="${pt#*$'\t'}"
    upsert_row "$ip" "$c_mac" "$c_vendor" "$c_host" "$count" "$top" "$c_rtt" "scanned"
  done
  log "port scan complete"
}

# ------------------------------------------------------------------
# Entry point with lock
# ------------------------------------------------------------------
cmd="${1:-all}"; shift || true

# Parse --host for ports subcommand
host_arg=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) host_arg="$2"; shift 2 ;;
    *) shift ;;
  esac
done

case "$cmd" in
  clean)
    rm -rf "$TSV" "$PORTS_DIR" "$LOG"
    mkdir -p "$PORTS_DIR"
    echo "Cache cleared: $CACHE_DIR"
    ;;
  discover|ports|all)
    # flock-style mutex via mkdir (portable, no flock needed on macOS)
    if ! mkdir "$LOCK" 2>/dev/null; then
      echo "Another scan is in progress (lock: $LOCK)" >&2
      exit 1
    fi
    trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM
    case "$cmd" in
      discover) phase_discover ;;
      ports)    phase_ports "$host_arg" ;;
      all)      phase_discover; phase_ports ;;
    esac
    ;;
  *)
    echo "Usage: $0 {discover|ports [--host IP]|all|clean}" >&2
    exit 2
    ;;
esac
