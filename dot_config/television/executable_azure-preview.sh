#!/usr/bin/env bash
# Preview script for the `azure` tv channel.
# Usage: azure-preview.sh <view> <kind> <name> <resource_group>
#
# view: main | alt
#   main → az <kind> show -o yaml  (pretty-printed via bat when available)
#   alt  → az <kind> show -o json  (copy-paste friendly)
#
# kind ∈ {rg, vm, pip, nic, nsg, res, login}
#
# The channel's [preview].command calls both entry points; Ctrl+F cycles
# between them.

set -eu

view="${1:-main}"
kind="${2:-}"
name="${3:-}"
rg="${4:-}"

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

# Early-exit on the synthetic login row so we don't issue az calls that will
# just fail again.
if [ "$kind" = "login" ]; then
  cat <<'EOF'
Not logged in to Azure.

  Press Enter to run:    az login
  Or from a terminal:    az login --use-device-code

Once authenticated, press Ctrl+R in this channel to reload.
EOF
  exit 0
fi

# Resolve the az-show invocation per kind. Emits JSON via `-o json`; the YAML
# view runs the same invocation with `-o yaml`. The `res` kind uses
# `az resource list`'s first match to derive the id.
run_show() {
  out_fmt="$1"
  case "$kind" in
    rg)
      az group show -n "$name" -o "$out_fmt" 2>&1
      ;;
    vm)
      az vm show -d -g "$rg" -n "$name" -o "$out_fmt" 2>&1
      ;;
    pip)
      az network public-ip show -g "$rg" -n "$name" -o "$out_fmt" 2>&1
      ;;
    nic)
      az network nic show -g "$rg" -n "$name" -o "$out_fmt" 2>&1
      ;;
    nsg)
      az network nsg show -g "$rg" -n "$name" -o "$out_fmt" 2>&1
      ;;
    res)
      id=$(az resource list -g "$rg" --name "$name" --query '[0].id' -o tsv 2>/dev/null)
      if [ -z "$id" ]; then
        printf 'could not resolve resource id for %s/%s\n' "$rg" "$name"
        return 0
      fi
      az resource show --ids "$id" -o "$out_fmt" 2>&1
      ;;
    *)
      printf 'no preview for kind=%s\n' "$kind"
      ;;
  esac
}

case "$view" in
  main)
    run_show yaml | show_yaml
    ;;
  alt)
    run_show json | show_json
    ;;
  *)
    printf 'unknown view: %s\n' "$view"
    ;;
esac
