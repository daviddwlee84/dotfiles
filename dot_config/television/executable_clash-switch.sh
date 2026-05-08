#!/usr/bin/env bash
# Switch a Clash / mihomo proxy group to the selected proxy.
# Usage: clash-switch.sh <api|yaml> <kind> <proxy-name>

set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$SELF_DIR/clash-source.sh"
PARSE="$SELF_DIR/clash-parse.py"

mode="${1:-api}"
kind="${2:-}"
name="${3:-}"

if [ "$kind" != "proxy" ]; then
  printf 'Alt+S requires a proxy row (got kind=%s)\n' "$kind"
  sleep 1
  exit 0
fi

if [ -z "$name" ]; then
  echo 'proxy name is empty'
  sleep 1
  exit 0
fi

if ! command -v fzf >/dev/null 2>&1; then
  echo 'fzf not on PATH - install via devtools ansible role'
  sleep 1
  exit 0
fi

{
  read -r host || true
  read -r secret || true
} < <("$SOURCE" controller 2>/dev/null)

if [ -z "${host:-}" ]; then
  echo 'external-controller not set'
  sleep 1
  exit 0
fi

auth=()
[ -n "${secret:-}" ] && auth=(-H "Authorization: Bearer $secret")

if ! curl -sS --max-time 2 "${auth[@]}" "http://$host/version" >/dev/null 2>&1; then
  printf 'Controller %s unreachable\n' "$host"
  sleep 1
  exit 0
fi

case "$mode" in
  api)
    groups_cmd=("$SOURCE" api-groups-for-switch)
    ;;
  yaml)
    groups_cmd=("$PARSE" groups-for-switch)
    ;;
  *)
    printf 'unknown switch mode: %s\n' "$mode"
    sleep 1
    exit 0
    ;;
esac

pick=$("${groups_cmd[@]}" 2>/dev/null \
  | awk -F'\t' -v n="$name" '
      $1 == "group" {
        count = split($4, arr, / \| /)
        for (i = 1; i <= count; i++) if (arr[i] == n) { printf "%s\t%s\n", $2, $3; next }
      }
    ' \
  | fzf --with-nth=1 --delimiter='\t' --prompt='Switch group> ' --height=40% --reverse)

if [ -z "${pick:-}" ]; then
  echo 'aborted'
  sleep 1
  exit 0
fi

group=$(printf '%s' "$pick" | awk -F'\t' '{print $1}')
encoded_group=$(python3 -c 'import sys, urllib.parse as u; print(u.quote(sys.argv[1], safe=""))' "$group")
payload=$(python3 -c 'import sys,json; print(json.dumps({"name": sys.argv[1]}))' "$name")
out="${TMPDIR:-/tmp}/clash-switch.out"

rc=$(curl -sS -o "$out" -w '%{http_code}' --max-time 4 -X PUT \
  "${auth[@]}" -H 'Content-Type: application/json' \
  -d "$payload" \
  "http://$host/proxies/$encoded_group" 2>/dev/null || true)

case "$rc" in
  2*) printf 'Switched %s -> %s\n' "$group" "$name" ;;
  *)  printf 'Switch failed (HTTP %s):\n%s\n' "$rc" "$(cat "$out" 2>/dev/null)" ;;
esac

sleep 1
