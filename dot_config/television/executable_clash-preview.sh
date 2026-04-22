#!/usr/bin/env bash
# Preview script for the `clash` tv channel.
# Usage: clash-preview.sh <view> <kind> <name>
#
# view:
#   main    → YAML block of the selected entry (bat -l yaml when available)
#   latency → proxy latency via Clash API /proxies/:name/delay, falling back
#             to a direct TCP nc probe + ping when the controller is absent
#             or unreachable.
#   meta    → kind-specific neighbours / links (e.g. group members + current
#             selection via /proxies/:group, related rules, api counts).
#
# The TV channel's [preview].command calls main+latency+meta; Ctrl+F cycles.

set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
PARSE="$SELF_DIR/clash-parse.py"

view="${1:-main}"
kind="${2:-}"
name="${3:-}"

show_yaml() {
  if command -v bat >/dev/null 2>&1; then
    bat --color=always --paging=never -l yaml --style=plain
  else
    cat
  fi
}

show_json() {
  if command -v bat >/dev/null 2>&1; then
    bat --color=always --paging=never -l json --style=plain
  else
    cat
  fi
}

show_text() {
  if command -v bat >/dev/null 2>&1; then
    bat --color=always --paging=never -l yaml --style=plain
  else
    cat
  fi
}

# Resolve host + secret from config ($CLASH_CONFIG respected).
# Outputs two lines; empty on both when no config/controller.
_controller() {
  if [ ! -x "$PARSE" ]; then
    printf '\n\n'
    return 0
  fi
  if ! command -v uv >/dev/null 2>&1; then
    printf '\n\n'
    return 0
  fi
  "$PARSE" controller 2>/dev/null || printf '\n\n'
}

_urlencode() {
  # Minimal URL-encoder for proxy names (spaces, parens, slashes). Python is
  # already available via uv/bootstrap; we avoid another runtime.
  python3 -c 'import sys, urllib.parse as u; print(u.quote(sys.argv[1], safe=""))' "$1" 2>/dev/null \
    || printf '%s' "$1"
}

case "$kind" in
  none)
    cat <<EOF
No Clash config found.

Expected locations (first match wins):
  \$CLASH_CONFIG                               (explicit override)
  \$HOME/.config/clash/config.yaml
  \$HOME/.config/mihomo/config.yaml
  \$HOME/Library/Application Support/clash/config.yaml
  \$HOME/Library/Application Support/mihomo/config.yaml

Actions:
  Alt+E → open \$EDITOR on a fresh config
  Ctrl+R → reload the picker once a config exists
EOF
    exit 0
    ;;
esac

case "$view" in
  main)
    "$PARSE" yaml --kind "$kind" --name "$name" 2>/dev/null | show_yaml
    ;;

  latency)
    case "$kind" in
      proxy)
        {
          read -r ctrl_host
          read -r ctrl_secret
        } < <(_controller)

        if [ -n "${ctrl_host:-}" ]; then
          base="http://$ctrl_host"
          auth=()
          [ -n "${ctrl_secret:-}" ] && auth=(-H "Authorization: Bearer $ctrl_secret")

          if curl -sS --max-time 1 "${auth[@]}" "$base/version" >/dev/null 2>&1; then
            encoded=$(_urlencode "$name")
            echo "# Clash API latency"
            echo "# GET $base/proxies/$encoded/delay?timeout=5000&url=http://www.gstatic.com/generate_204"
            echo
            resp=$(curl -sS --max-time 6 "${auth[@]}" \
              "$base/proxies/$encoded/delay?timeout=5000&url=http://www.gstatic.com/generate_204" \
              2>/dev/null || true)
            if [ -z "$resp" ]; then
              echo "(empty response)"
            elif command -v jq >/dev/null 2>&1; then
              printf '%s' "$resp" | jq . 2>/dev/null || printf '%s\n' "$resp"
            else
              printf '%s\n' "$resp"
            fi
            exit 0
          fi
          echo "# Clash API ($ctrl_host) not reachable — falling back to TCP probe"
          echo
        fi

        server_port="$("$PARSE" server --name "$name" 2>/dev/null || true)"
        if [ -z "${server_port:-}" ]; then
          echo "No server:port for proxy '$name' (is this proxy synthetic / provider-sourced?)"
          exit 0
        fi
        server="${server_port%:*}"
        port="${server_port##*:}"

        echo "# Direct TCP probe: $server:$port"
        if command -v nc >/dev/null 2>&1; then
          if nc -z -w3 "$server" "$port" 2>/dev/null; then
            echo "TCP connect OK (nc -z -w3)"
          else
            echo "TCP connect failed"
          fi
        else
          echo "(nc not installed — skipping TCP probe)"
        fi

        echo
        echo "# ping $server (3 packets, 2s timeout)"
        if command -v ping >/dev/null 2>&1; then
          if [ "$(uname -s)" = "Darwin" ]; then
            ping -c 3 -W 2000 "$server" 2>&1 | tail -n 6
          else
            ping -c 3 -W 2 "$server" 2>&1 | tail -n 6
          fi
        else
          echo "(ping not installed)"
        fi
        ;;

      group)
        {
          read -r ctrl_host
          read -r ctrl_secret
        } < <(_controller)

        if [ -n "${ctrl_host:-}" ]; then
          base="http://$ctrl_host"
          auth=()
          [ -n "${ctrl_secret:-}" ] && auth=(-H "Authorization: Bearer $ctrl_secret")
          encoded=$(_urlencode "$name")
          echo "# GET $base/proxies/$encoded"
          echo
          resp=$(curl -sS --max-time 3 "${auth[@]}" "$base/proxies/$encoded" 2>/dev/null || true)
          if [ -n "$resp" ]; then
            if command -v jq >/dev/null 2>&1; then
              printf '%s' "$resp" | jq . 2>/dev/null | show_json
              exit 0
            fi
            printf '%s\n' "$resp" | show_json
            exit 0
          fi
          echo "(no response — controller unreachable or group not loaded)"
        else
          echo "No external-controller configured; showing static YAML instead."
          echo
          "$PARSE" yaml --kind group --name "$name" 2>/dev/null | show_yaml
        fi
        ;;

      *)
        echo "# Latency view not available for kind=$kind"
        ;;
    esac
    ;;

  meta)
    case "$kind" in
      proxy)
        echo "# Groups that reference '$name'"
        # groups-for-switch emits 4 cols: group \t name \t type \t a | b | c
        # (pipe-separated member list). Only print rows where `name` appears
        # in the member list, so the preview is context-relevant instead of
        # listing every group.
        matches=$("$PARSE" groups-for-switch 2>/dev/null | awk -F'\t' -v n="$name" '
          $1 == "group" {
            count = split($4, arr, / \| /)
            for (i = 1; i <= count; i++) if (arr[i] == n) {
              printf "- %s  (%s)\n", $2, $3
              break
            }
          }
        ')
        if [ -z "$matches" ]; then
          echo "(no proxy-group references this proxy)"
        else
          printf '%s\n' "$matches"
        fi
        ;;

      group)
        "$PARSE" yaml --kind group --name "$name" 2>/dev/null | show_yaml
        ;;

      rule)
        idx="${name#\#}"
        echo "# Rule $name"
        "$PARSE" rules 2>/dev/null | awk -F'\t' -v k="$name" '$2 == k'
        ;;

      config)
        "$PARSE" yaml --kind config --name "$name" 2>/dev/null | show_yaml
        ;;

      api)
        {
          read -r ctrl_host
          read -r ctrl_secret
        } < <(_controller)
        if [ -z "${ctrl_host:-}" ]; then
          echo "No external-controller configured."
          exit 0
        fi
        base="http://$ctrl_host"
        auth=()
        [ -n "${ctrl_secret:-}" ] && auth=(-H "Authorization: Bearer $ctrl_secret")
        echo "# $base/configs"
        resp=$(curl -sS --max-time 2 "${auth[@]}" "$base/configs" 2>/dev/null || true)
        if [ -n "$resp" ] && command -v jq >/dev/null 2>&1; then
          printf '%s' "$resp" | jq . 2>/dev/null | show_json
        elif [ -n "$resp" ]; then
          printf '%s\n' "$resp"
        else
          echo "(no response)"
        fi
        ;;

      *)
        echo "# No meta view for kind=$kind"
        ;;
    esac
    ;;

  *)
    echo "Unknown preview view: $view" >&2
    exit 1
    ;;
esac
