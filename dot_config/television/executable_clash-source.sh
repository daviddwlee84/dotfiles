#!/usr/bin/env bash
# Source emitter for the `clash` tv channel.
# Usage: clash-source.sh <proxies|groups|rules|summary|api>
#
# Emits TSV rows with the layout:
#   kind<TAB>name<TAB>type_or_meta<TAB>server_or_target<TAB>extra
#
# kind ∈ {proxy, group, rule, config, api, none}. The channel's action
# shell dispatches on `kind`, so wrong-kind actions become 1-second toasts.
#
# The `api` source talks to the live Clash / mihomo HTTP API
# (external-controller, default 127.0.0.1:9090). If the controller is
# unreachable we still emit one informational row so the user has something
# to land on with an error hint. `secret` (bearer token) is honored when
# set in the config.

set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
PARSE="$SELF_DIR/clash-parse.py"

mode="${1:-proxies}"

if [ ! -x "$PARSE" ]; then
  printf 'none\tclash-parse-missing\t-\t%s is not executable\t-\n' "$PARSE"
  exit 0
fi

if ! command -v uv >/dev/null 2>&1; then
  printf 'none\tuv-not-installed\t-\tRun chezmoi bootstrap to install uv\t-\n'
  exit 0
fi

run_parse() {
  # stderr is dropped so uv's "Installed 1 package …" first-run chatter (and
  # any transient warnings) doesn't contaminate TSV rows. clash-parse.py
  # surfaces its own errors via synthetic `none` rows on stdout, so we never
  # lose signal that matters to the TV channel.
  "$PARSE" "$@" 2>/dev/null || true
}

case "$mode" in
  proxies | groups | rules | summary | groups-for-switch)
    run_parse "$mode"
    ;;

  api)
    # Resolve controller + secret from the config. Two lines on stdout:
    #   line 1: host:port (empty when external-controller is unset)
    #   line 2: secret (empty when unset)
    # `read -r` twice on the pipeline works on both bash + zsh.
    ctrl_host=""
    ctrl_secret=""
    {
      read -r ctrl_host || true
      read -r ctrl_secret || true
    } < <(run_parse controller)

    if [ -z "$ctrl_host" ]; then
      printf 'api\texternal-controller\tunset\t-\tSet external-controller in Clash config\t-\n'
      exit 0
    fi

    auth=()
    if [ -n "$ctrl_secret" ]; then
      auth=(-H "Authorization: Bearer $ctrl_secret")
    fi

    base="http://$ctrl_host"

    # /version → controller reachable + version info
    ver_json=$(curl -sS --max-time 2 "${auth[@]}" "$base/version" 2>/dev/null || true)
    if [ -z "$ver_json" ]; then
      printf 'api\texternal-controller\tunreachable\t%s\tcurl failed or timeout\n' "$ctrl_host"
      exit 0
    fi

    ver=$(printf '%s' "$ver_json" | awk -F'"' '/"version"/ {print $4; exit}')
    [ -z "$ver" ] && ver="?"
    meta=$(printf '%s' "$ver_json" | awk -F'"' '/"premium"/{p="premium"} /"meta"/{m="meta"} END{if(p)print p; else if(m)print m}')
    printf 'api\texternal-controller\thealthy\t%s\tversion=%s %s\n' "$ctrl_host" "$ver" "$meta"

    # /configs → current runtime config (small scalars only, filters out
    # nested dns / tun / sniffer blocks so the list stays scannable).
    cfg_json=$(curl -sS --max-time 2 "${auth[@]}" "$base/configs" 2>/dev/null || true)
    if [ -n "$cfg_json" ]; then
      printf '%s' "$cfg_json" | awk '
        BEGIN { RS=","; FS=":" }
        /^\s*"(port|socks-port|redir-port|mixed-port|tproxy-port|allow-lan|bind-address|ipv6|log-level|mode)"/ {
          gsub(/[{}]/, "")
          key=$1; sub(/^[[:space:]]+/, "", key); gsub(/"/, "", key)
          $1=""; val=$0; sub(/^:/, "", val); gsub(/"/, "", val); sub(/^[[:space:]]+/, "", val); sub(/[[:space:]]+$/, "", val)
          printf "api\tconfig.%s\tscalar\t%s\t-\n", key, val
        }
      '
    fi

    # /connections → active connection count only (not the full list — that
    # would balloon the row set on a busy client).
    conn_json=$(curl -sS --max-time 2 "${auth[@]}" "$base/connections" 2>/dev/null || true)
    if [ -n "$conn_json" ]; then
      n=$(printf '%s' "$conn_json" | awk 'match($0, /"connections":\[/) {
        rest = substr($0, RSTART + RLENGTH)
        depth = 1; count = 0; in_str = 0; esc = 0
        for (i = 1; i <= length(rest); i++) {
          c = substr(rest, i, 1)
          if (esc) { esc = 0; continue }
          if (c == "\\") { esc = 1; continue }
          if (c == "\"") { in_str = !in_str; continue }
          if (in_str) continue
          if (c == "{") { if (depth == 1) count++; depth++ }
          else if (c == "}") { depth-- }
          else if (c == "]" && depth == 1) break
        }
        print count
        exit
      }')
      [ -z "$n" ] && n=0
      printf 'api\tconnections\tcount\t%s\tactive connections\n' "$n"

      up=$(printf '%s' "$conn_json" | awk -F'[:,]' '/"uploadTotal"/ {gsub(/[^0-9]/, "", $2); print $2; exit}')
      down=$(printf '%s' "$conn_json" | awk -F'[:,]' '/"downloadTotal"/ {gsub(/[^0-9]/, "", $2); print $2; exit}')
      [ -n "$up$down" ] && printf 'api\ttraffic\ttotals\tup=%s down=%s\tbytes\n' "${up:-0}" "${down:-0}"
    fi
    ;;

  *)
    printf 'none\tunknown-mode-%s\t-\t-\tclash-source.sh called with bad arg\n' "$mode"
    exit 0
    ;;
esac
