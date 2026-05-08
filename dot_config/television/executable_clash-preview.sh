#!/usr/bin/env bash
# Preview script for the `clash` and `clash-api` tv channels.
# Usage: clash-preview.sh <view> <kind> <name>
#
# Views:
#   main      YAML-backed detail view for `tv clash`
#   api-main  controller-backed detail view for `tv clash-api`
#   latency   Clash API /proxies/:name/delay, falling back to TCP + ping
#   meta      YAML-backed context view for `tv clash`
#   api-meta  controller-backed context view for `tv clash-api`

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
    bat --color=always --paging=never -l markdown --style=plain
  else
    cat
  fi
}

pretty_json() {
  if command -v jq >/dev/null 2>&1; then
    jq . 2>/dev/null || cat
  else
    python3 -m json.tool 2>/dev/null || cat
  fi
}

_controller() {
  if [ -n "${CLASH_CONTROLLER:-}" ]; then
    printf '%s\n%s\n' "$CLASH_CONTROLLER" "${CLASH_SECRET:-}"
    return 0
  fi

  local host="" secret=""
  if [ ! -x "$PARSE" ]; then
    if curl -sS --max-time 1 "http://127.0.0.1:9090/version" >/dev/null 2>&1; then
      printf '%s\n\n' "127.0.0.1:9090"
    else
      printf '\n\n'
    fi
    return 0
  fi
  if ! command -v uv >/dev/null 2>&1; then
    if curl -sS --max-time 1 "http://127.0.0.1:9090/version" >/dev/null 2>&1; then
      printf '%s\n\n' "127.0.0.1:9090"
    else
      printf '\n\n'
    fi
    return 0
  fi

  {
    read -r host || true
    read -r secret || true
  } < <("$PARSE" controller 2>/dev/null || printf '\n\n')

  if [ -n "$host" ]; then
    local auth=()
    [ -n "$secret" ] && auth=(-H "Authorization: Bearer $secret")
    if curl -sS --max-time 1 "${auth[@]}" "http://$host/version" >/dev/null 2>&1; then
      printf '%s\n%s\n' "$host" "$secret"
      return 0
    fi
  fi

  if curl -sS --max-time 1 "http://127.0.0.1:9090/version" >/dev/null 2>&1; then
    printf '%s\n\n' "127.0.0.1:9090"
  else
    printf '%s\n%s\n' "$host" "$secret"
  fi
}

_urlencode() {
  python3 -c 'import sys, urllib.parse as u; print(u.quote(sys.argv[1], safe=""))' "$1" 2>/dev/null \
    || printf '%s' "$1"
}

_api_request() {
  local endpoint="$1"
  local timeout="${2:-3}"
  local ctrl_host ctrl_secret
  local auth=()

  {
    read -r ctrl_host
    read -r ctrl_secret
  } < <(_controller)

  [ -n "${ctrl_host:-}" ] || return 1
  [ -n "${ctrl_secret:-}" ] && auth=(-H "Authorization: Bearer $ctrl_secret")
  curl -sS --max-time "$timeout" "${auth[@]}" "http://$ctrl_host/$endpoint" 2>/dev/null || true
}

_show_api_main() {
  local api_kind="$1"
  local api_name="$2"
  local resp encoded

  case "$api_kind" in
    proxy | group)
      encoded="$(_urlencode "$api_name")"
      resp="$(_api_request "proxies/$encoded" 4)"
      if [ -n "$resp" ]; then
        printf '%s' "$resp" | pretty_json | show_json
      else
        echo "(no response)"
      fi
      ;;

    rule)
      resp="$(_api_request "rules" 4)"
      if [ -z "$resp" ]; then
        echo "(no response)"
        return 0
      fi
      printf '%s' "$resp" | python3 -c '
import json
import sys

name = sys.argv[1]
try:
    index = int(name.lstrip("#")) - 1
except ValueError:
    index = -1

data = json.load(sys.stdin)
rules = data.get("rules") or []
if 0 <= index < len(rules):
    print(json.dumps(rules[index], ensure_ascii=False, indent=2))
else:
    print(json.dumps({"error": f"rule {name} not found"}, ensure_ascii=False, indent=2))
' "$api_name" | pretty_json | show_json
      ;;

    api)
      case "$api_name" in
        external-controller)
          resp="$(_api_request "version" 2)"
          ;;
        connections | traffic)
          resp="$(_api_request "connections" 3)"
          ;;
        config.*)
          resp="$(_api_request "configs" 3)"
          if [ -n "$resp" ]; then
            printf '%s' "$resp" | python3 -c '
import json
import sys

name = sys.argv[1]
key = name.split("config.", 1)[1] if name.startswith("config.") else name
data = json.load(sys.stdin)
print(json.dumps({key: data.get(key)}, ensure_ascii=False, indent=2))
' "$api_name" | pretty_json | show_json
            return 0
          fi
          ;;
        *)
          resp="$(_api_request "configs" 3)"
          ;;
      esac
      if [ -n "$resp" ]; then
        printf '%s' "$resp" | pretty_json | show_json
      else
        echo "(no response)"
      fi
      ;;

    config)
      "$PARSE" yaml --kind config --name "$api_name" 2>/dev/null | show_yaml
      ;;

    *)
      printf '# No API main view for kind=%s\n' "$api_kind"
      ;;
  esac
}

_show_api_meta() {
  local api_kind="$1"
  local api_name="$2"
  local resp encoded

  case "$api_kind" in
    proxy)
      resp="$(_api_request "proxies" 4)"
      if [ -z "$resp" ]; then
        echo "(no response)"
        return 0
      fi
      printf '%s' "$resp" | python3 -c '
import json
import sys

name = sys.argv[1]
data = json.load(sys.stdin)
proxies = data.get("proxies") or {}
matches = []

for group_name, item in proxies.items():
    if not isinstance(item, dict):
        continue
    members = item.get("all")
    if not isinstance(members, list):
        continue
    if name in members:
        matches.append((group_name, item.get("type", "?"), item.get("now", "-")))

print(f"# Groups that reference '{name}'")
if not matches:
    print("(no proxy-group references this proxy)")
else:
    print()
    for group_name, proxy_type, current in matches:
        print(f"- {group_name} ({proxy_type}, now={current})")
' "$api_name" | show_text
      ;;

    group)
      encoded="$(_urlencode "$api_name")"
      resp="$(_api_request "proxies/$encoded" 4)"
      if [ -z "$resp" ]; then
        echo "(no response)"
        return 0
      fi
      printf '%s' "$resp" | python3 -c '
import json
import sys

data = json.load(sys.stdin)
print(f"# current: {data.get(\"now\", \"-\")}")

members = data.get("all") or []
if members:
    print("\n# members")
    for member in members:
        print(f"- {member}")

history = data.get("history") or []
if history:
    print("\n# recent history")
    for item in history[-10:]:
        if not isinstance(item, dict):
            continue
        print(
            f"- {item.get(\"time\", \"?\")}  delay={item.get(\"delay\", \"?\")}ms  "
            f"mean={item.get(\"meanDelay\", \"?\")}ms"
        )
' | show_text
      ;;

    rule)
      resp="$(_api_request "rules" 4)"
      if [ -z "$resp" ]; then
        echo "(no response)"
        return 0
      fi
      printf '%s' "$resp" | python3 -c '
import json
import re
import sys

name = sys.argv[1]
try:
    index = int(name.lstrip("#")) - 1
except ValueError:
    index = -1

data = json.load(sys.stdin)
rules = data.get("rules") or []

def rule_type(raw: object) -> str:
    if not isinstance(raw, str) or not raw:
        return "?"
    rendered = re.sub(r"([a-z0-9])([A-Z])", r"\1-\2", raw).upper()
    return (
        rendered
        .replace("IPCIDR", "IP-CIDR")
        .replace("SRCIPCIDR", "SRC-IP-CIDR")
        .replace("DSTPORT", "DST-PORT")
        .replace("SRCPORT", "SRC-PORT")
        .replace("GEOIP", "GEO-IP")
        .replace("GEOSITE", "GEO-SITE")
    )

start = max(index - 2, 0)
end = min(index + 3, len(rules))
print(f"# rules around {name}")
if not (0 <= index < len(rules)):
    print("(rule not found)")
else:
    print()
    for idx in range(start, end):
        item = rules[idx]
        if not isinstance(item, dict):
            continue
        marker = ">" if idx == index else " "
        payload = item.get("payload") or "-"
        target = item.get("proxy") or item.get("adapter") or item.get("outbound") or "-"
        print(f"{marker} #{idx + 1:04d} {rule_type(item.get(\"type\")):16} {payload} -> {target}")
' "$api_name" | show_text
      ;;

    api)
      case "$api_name" in
        external-controller)
          resp="$(_api_request "configs" 3)"
          ;;
        connections | traffic)
          resp="$(_api_request "connections" 3)"
          ;;
        *)
          resp="$(_api_request "configs" 3)"
          ;;
      esac
      if [ -n "$resp" ]; then
        printf '%s' "$resp" | pretty_json | show_json
      else
        echo "(no response)"
      fi
      ;;

    *)
      printf '# No API meta view for kind=%s\n' "$api_kind"
      ;;
  esac
}

if [ "$kind" = "none" ]; then
  cat <<EOF
No Clash data available.

YAML-backed browsing:
  tv clash
  CLASH_CONFIG=/path/to/profile.yml tv clash

Live controller browsing:
  tv clash-api
  CLASH_CONTROLLER=192.168.222.207:9090 tv clash-api
EOF
  exit 0
fi

case "$view" in
  main)
    if [ "$kind" = "api" ]; then
      _show_api_main "$kind" "$name"
    else
      "$PARSE" yaml --kind "$kind" --name "$name" 2>/dev/null | show_yaml
    fi
    ;;

  api-main)
    _show_api_main "$kind" "$name"
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
            else
              printf '%s' "$resp" | pretty_json | show_json
            fi
            exit 0
          fi
          echo "# Clash API ($ctrl_host) not reachable — falling back to TCP probe"
          echo
        fi

        server_port="$("$PARSE" server --name "$name" 2>/dev/null || true)"
        if [ -z "${server_port:-}" ]; then
          echo "No server:port for proxy '$name' (set CLASH_CONFIG for YAML-backed resolution)"
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
            printf '%s' "$resp" | pretty_json | show_json
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
    if [ "$kind" = "api" ]; then
      _show_api_meta "$kind" "$name"
      exit 0
    fi
    case "$kind" in
      proxy)
        echo "# Groups that reference '$name'"
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
        echo "# Rule $name"
        "$PARSE" rules 2>/dev/null | awk -F'\t' -v k="$name" '$2 == k'
        ;;

      config)
        "$PARSE" yaml --kind config --name "$name" 2>/dev/null | show_yaml
        ;;

      *)
        echo "# No meta view for kind=$kind"
        ;;
    esac
    ;;

  api-meta)
    _show_api_meta "$kind" "$name"
    ;;

  *)
    echo "Unknown preview view: $view" >&2
    exit 1
    ;;
esac
