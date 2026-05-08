#!/usr/bin/env bash
# Source emitter for the `clash` and `clash-api` tv channels.
# Usage:
#   clash-source.sh <proxies|groups|rules|summary|api>
#   clash-source.sh <api-proxies|api-groups|api-rules|api-groups-for-switch>
#
# YAML-backed modes emit rows from the resolved Clash config. Controller-backed
# modes talk to the live Clash / mihomo external-controller HTTP API.

set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
PARSE="$SELF_DIR/clash-parse.py"

mode="${1:-proxies}"

ctrl_host=""
ctrl_secret=""
auth=()
base=""

parse_available() {
  [ -x "$PARSE" ] && command -v uv >/dev/null 2>&1
}

emit_parse_prereq_row() {
  if [ ! -x "$PARSE" ]; then
    printf 'none\tclash-parse-missing\t-\t%s is not executable\t-\n' "$PARSE"
  else
    printf 'none\tuv-not-installed\t-\tRun chezmoi bootstrap to install uv\t-\n'
  fi
}

run_parse() {
  if ! parse_available; then
    emit_parse_prereq_row
    return 1
  fi
  "$PARSE" "$@" 2>/dev/null || true
}

resolve_controller() {
  if [ -n "${CLASH_CONTROLLER:-}" ]; then
    printf '%s\n%s\n' "$CLASH_CONTROLLER" "${CLASH_SECRET:-}"
    return 0
  fi

  local host="" secret=""
  if ! parse_available; then
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

prepare_controller() {
  if [ -n "$ctrl_host" ] || [ -n "$ctrl_secret" ]; then
    return 0
  fi
  {
    read -r ctrl_host || true
    read -r ctrl_secret || true
  } < <(resolve_controller)
  auth=()
  if [ -n "$ctrl_secret" ]; then
    auth=(-H "Authorization: Bearer $ctrl_secret")
  fi
  base="http://$ctrl_host"
}

api_get_json() {
  local endpoint="$1"
  local timeout="${2:-3}"
  prepare_controller
  [ -n "$ctrl_host" ] || return 1
  curl -sS --max-time "$timeout" "${auth[@]}" "$base/$endpoint" 2>/dev/null || true
}

emit_empty_yaml_row() {
  local dataset="$1"
  local path slug detail
  path="$(run_parse path | sed -n '1p')"
  [ -n "$path" ] || path="resolved YAML"

  case "$dataset" in
    proxies)
      slug="empty-proxies"
      detail="No proxies[] found in $path"
      ;;
    groups)
      slug="empty-groups"
      detail="No proxy-groups[] found in $path"
      ;;
    rules)
      slug="empty-rules"
      detail="No rules[] found in $path"
      ;;
    *)
      slug="empty-yaml"
      detail="No entries found in $path"
      ;;
  esac

  printf 'none\t%s\t-\t%s\tUse CLASH_CONFIG=/path/to/profile.yml or tv clash-api\n' "$slug" "$detail"
}

emit_api_source_row() {
  local slug="$1"
  local detail="$2"
  local extra="${3:--}"
  printf 'none\t%s\t-\t%s\t%s\n' "$slug" "$detail" "$extra"
}

json_to_rows() {
  local submode="$1"
  python3 -c '
import json
import re
import sys


def clean(value: object) -> str:
    return ("" if value is None else str(value)).replace("\t", " ").replace("\n", " ").replace("\r", " ")


def tsv(*cols: object) -> str:
    return "\t".join(clean(col) for col in cols)


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


def history_delays(item: dict) -> tuple[object, object]:
    history = item.get("history") or []
    if isinstance(history, list) and history:
        last = history[-1]
        if isinstance(last, dict):
            return last.get("delay"), last.get("meanDelay")
    return None, None


mode = sys.argv[1]
data = json.load(sys.stdin)

if mode in {"api-proxies", "api-groups", "api-groups-for-switch"}:
    proxies = data.get("proxies") or {}
    if not isinstance(proxies, dict):
        raise SystemExit(0)

    rows: list[str] = []
    for name, item in proxies.items():
        if not isinstance(item, dict):
            continue

        is_group = isinstance(item.get("all"), list)
        proxy_type = item.get("type", "?")

        if mode == "api-proxies":
            if is_group:
                continue
            alive = "alive" if item.get("alive") else "down"
            latest, mean = history_delays(item)
            extra = []
            if item.get("udp"):
                extra.append("udp")
            if latest not in (None, ""):
                extra.append(f"last={latest}ms")
            if mean not in (None, ""):
                extra.append(f"mean={mean}ms")
            rows.append(tsv("proxy", name, proxy_type, alive, " ".join(extra) if extra else "-"))
            continue

        if not is_group:
            continue

        members = [member for member in item.get("all", []) if isinstance(member, str)]
        normalized = re.sub(r"[^a-z]", "", str(proxy_type).lower())
        if mode == "api-groups-for-switch":
            if normalized not in {"selector", "urltest", "fallback", "loadbalance"}:
                continue
            rows.append(tsv("group", name, proxy_type, " | ".join(members)))
            continue

        current = item.get("now", "-")
        rows.append(tsv("group", name, proxy_type, current, f"{len(members)} members"))

    print("\n".join(rows))
    raise SystemExit(0)

if mode == "api-rules":
    rules = data.get("rules") or []
    if not isinstance(rules, list):
        raise SystemExit(0)

    rows: list[str] = []
    for idx, item in enumerate(rules, 1):
        if not isinstance(item, dict):
            continue
        rows.append(
            tsv(
                "rule",
                f"#{idx:04d}",
                rule_type(item.get("type", "?")),
                item.get("payload") or "-",
                item.get("proxy") or item.get("adapter") or item.get("outbound") or "-",
            )
        )
    print("\n".join(rows))
' "$submode"
}

emit_api_summary() {
  local ver_json cfg_json conn_json meta_lines version meta

  prepare_controller
  if [ -z "$ctrl_host" ]; then
    printf 'api\texternal-controller\tunset\t-\tSet CLASH_CONTROLLER or external-controller\t-\n'
    return 0
  fi

  ver_json="$(api_get_json version 2)"
  if [ -z "$ver_json" ]; then
    printf 'api\texternal-controller\tunreachable\t%s\tcurl failed or timeout\n' "$ctrl_host"
    return 0
  fi

  meta_lines="$(printf '%s' "$ver_json" | python3 -c '
import json
import sys

data = json.load(sys.stdin)
tags = []
if data.get("premium"):
    tags.append("premium")
if data.get("meta"):
    tags.append("meta")
print(data.get("version", "?"))
print(" ".join(tags) if tags else "-")
')"
  version="$(printf '%s\n' "$meta_lines" | sed -n '1p')"
  meta="$(printf '%s\n' "$meta_lines" | sed -n '2p')"
  if [ "$meta" = "-" ]; then
    printf 'api\texternal-controller\thealthy\t%s\tversion=%s\n' "$ctrl_host" "$version"
  else
    printf 'api\texternal-controller\thealthy\t%s\tversion=%s %s\n' "$ctrl_host" "$version" "$meta"
  fi

  cfg_json="$(api_get_json configs 2)"
  if [ -n "$cfg_json" ]; then
    printf '%s' "$cfg_json" | python3 -c '
import json
import sys


def render(value: object) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


data = json.load(sys.stdin)
for key in (
    "port",
    "socks-port",
    "redir-port",
    "mixed-port",
    "tproxy-port",
    "allow-lan",
    "bind-address",
    "ipv6",
    "log-level",
    "mode",
):
    if key in data:
        print(f"api\tconfig.{key}\tscalar\t{render(data[key])}\t-")
'
  fi

  conn_json="$(api_get_json connections 2)"
  if [ -n "$conn_json" ]; then
    printf '%s' "$conn_json" | python3 -c '
import json
import sys

data = json.load(sys.stdin)
connections = data.get("connections") or []
if isinstance(connections, list):
    print(f"api\tconnections\tcount\t{len(connections)}\tactive connections")
upload = data.get("uploadTotal")
download = data.get("downloadTotal")
if upload is not None or download is not None:
    print(f"api\ttraffic\ttotals\tup={upload or 0} down={download or 0}\tbytes")
'
  fi
}

run_api_rows() {
  local submode="$1"
  local endpoint="$2"
  local label="$3"
  local json rows

  prepare_controller
  if [ -z "$ctrl_host" ]; then
    emit_api_source_row "external-controller-unset" "Set CLASH_CONTROLLER or external-controller" "-"
    return 0
  fi

  json="$(api_get_json "$endpoint" 4)"
  if [ -z "$json" ]; then
    emit_api_source_row "api-unreachable" "Controller $ctrl_host did not answer $endpoint" "-"
    return 0
  fi

  rows="$(printf '%s' "$json" | json_to_rows "$submode" || true)"
  if [ -n "$rows" ]; then
    printf '%s\n' "$rows"
    return 0
  fi

  emit_api_source_row "empty-${label}" "Controller returned no ${label}" "Try tv clash or check the controller"
}

case "$mode" in
  proxies | groups | rules)
    if ! parse_available; then
      emit_parse_prereq_row
      exit 0
    fi
    out="$(run_parse "$mode")"
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
    else
      emit_empty_yaml_row "$mode"
    fi
    ;;

  summary | groups-for-switch | controller)
    if [ "$mode" = "controller" ]; then
      resolve_controller
      exit 0
    fi
    if ! parse_available; then
      emit_parse_prereq_row
      exit 0
    fi
    run_parse "$mode"
    ;;

  api)
    emit_api_summary
    ;;

  api-proxies)
    run_api_rows "api-proxies" "proxies" "proxies"
    ;;

  api-groups)
    run_api_rows "api-groups" "proxies" "groups"
    ;;

  api-rules)
    run_api_rows "api-rules" "rules" "rules"
    ;;

  api-groups-for-switch)
    run_api_rows "api-groups-for-switch" "proxies" "switchable groups"
    ;;

  *)
    printf 'none\tunknown-mode-%s\t-\t-\tclash-source.sh called with bad arg\n' "$mode"
    exit 0
    ;;
esac
