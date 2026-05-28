#!/usr/bin/env bash
# wifi-scan.sh - snapshot nearby Wi-Fi networks into a TSV for `tv wifi-scan`.
#
# Writes ~/.cache/tv/wifi-scan.tsv (one row per SSID seen) so a Television
# channel can fuzzy-search the RF neighbourhood: band, channel, width, RSSI,
# noise, SNR, security, and flags (current / DFS). Helps pick a clean,
# non-DFS channel. See docs/playbooks/wifi-latency-spikes.md.
#
# Usage:
#   wifi-scan.sh scan     # rescan now, rewrite the TSV (default)
#   wifi-scan.sh clean    # purge the cache
#
# macOS: parses `system_profiler SPAirPortDataType -json`.
# Linux: best-effort via `nmcli` (no noise/SNR columns).

set -u

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/tv"
TSV="$CACHE_DIR/wifi-scan.tsv"
# Columns: ssid \t band \t channel \t width \t rssi \t noise \t snr \t security \t flags
TSV_HEADER=$'ssid\tband\tchannel\twidth\trssi\tnoise\tsnr\tsecurity\tflags'

mkdir -p "$CACHE_DIR"

is_macos() { [[ "$(uname -s)" == Darwin ]]; }

scan_macos() {
    system_profiler SPAirPortDataType -json 2>/dev/null | python3 -c '
import sys, json, re

def parse_chan(s):
    # "36 (5GHz, 80MHz)" -> (36, "5GHz", "80MHz")
    m = re.match(r"\s*(\d+)\s*\(([^,]+),\s*([^)]+)\)", s or "")
    if not m:
        return (s or "?", "?", "?")
    return (m.group(1), m.group(2).strip(), m.group(3).strip())

def parse_sn(s):
    # "-27 dBm / -93 dBm" -> (-27, -93)
    nums = re.findall(r"-?\d+", s or "")
    return (nums[0] if len(nums) > 0 else "", nums[1] if len(nums) > 1 else "")

def is_dfs(band, ch):
    try:
        c = int(ch)
    except ValueError:
        return False
    return band.startswith("5") and (52 <= c <= 64 or 100 <= c <= 144)

def emit(net, current):
    name = net.get("_name", "?") or "?"
    ch, band, width = parse_chan(net.get("spairport_network_channel", ""))
    rssi, noise = parse_sn(net.get("spairport_signal_noise", ""))
    if not (ch.isdigit() or rssi):  # skip non-RF interfaces (e.g. AWDL)
        return
    sec = (net.get("spairport_security_mode", "") or "").replace("spairport_security_mode_", "") or "?"
    snr = ""
    try:
        snr = str(int(rssi) - int(noise))
    except ValueError:
        pass
    flags = []
    if current:
        flags.append("current")
    if is_dfs(band, ch):
        flags.append("DFS")
    print("\t".join([name, band, ch, width, rssi, noise, snr, sec, ",".join(flags) or "-"]))

d = json.load(sys.stdin)
for it in d.get("SPAirPortDataType", [{}])[0].get("spairport_airport_interfaces", []):
    cur = it.get("spairport_current_network_information")
    if cur:
        emit(cur, True)
    for o in it.get("spairport_airport_other_local_wireless_networks", []) or []:
        emit(o, False)
'
}

scan_linux() {
    command -v nmcli >/dev/null 2>&1 || return 1
    nmcli -t -f IN-USE,SSID,CHAN,FREQ,SIGNAL,SECURITY dev wifi list 2>/dev/null | python3 -c '
import sys
def band_of(freq):
    try: f = int(freq)
    except ValueError: return "?"
    return "5GHz" if f >= 5000 else "2GHz"
def is_dfs(band, ch):
    try: c = int(ch)
    except ValueError: return False
    return band.startswith("5") and (52 <= c <= 64 or 100 <= c <= 144)
for line in sys.stdin:
    # nmcli -t escapes ":" inside fields as "\:"; split on unescaped ":"
    parts = []
    buf = ""; esc = False
    for ch in line.rstrip("\n"):
        if esc: buf += ch; esc = False
        elif ch == "\\": esc = True
        elif ch == ":": parts.append(buf); buf = ""
        else: buf += ch
    parts.append(buf)
    if len(parts) < 6: continue
    inuse, ssid, chan, freq, signal, sec = parts[:6]
    band = band_of(freq)
    # nmcli SIGNAL is 0-100%; approximate dBm = signal/2 - 100
    try: rssi = str(int(int(signal)/2 - 100))
    except ValueError: rssi = ""
    flags = []
    if inuse.strip() == "*": flags.append("current")
    if is_dfs(band, chan): flags.append("DFS")
    print("\t".join([ssid or "?", band, chan, "?", rssi, "", "", sec or "?", ",".join(flags) or "-"]))
'
}

cmd_scan() {
    local rows
    if is_macos; then
        rows="$(scan_macos)"
    else
        rows="$(scan_linux)"
    fi
    {
        printf '%s\n' "$TSV_HEADER"
        printf '%s\n' "$rows" | sed '/^$/d'
    } > "$TSV"
    local n
    n=$(($(wc -l < "$TSV") - 1))
    printf 'wifi-scan: %d networks -> %s\n' "$n" "$TSV"
}

cmd_clean() { rm -f "$TSV"; echo "wifi-scan: cleared $TSV"; }

case "${1:-scan}" in
    scan) cmd_scan ;;
    clean) cmd_clean ;;
    *) echo "usage: wifi-scan.sh [scan|clean]" >&2; exit 2 ;;
esac
