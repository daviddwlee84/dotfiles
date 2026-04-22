#!/usr/bin/env bash
# Source emitter for the `azure` tv channel.
# Usage: azure-source.sh <rgs|vms|pips|nics|all>
#
# Emits TSV rows with the layout:
#   kind<TAB>name<TAB>resource_group<TAB>location<TAB>extra
#
# kind ∈ {rg, vm, pip, nic, nsg, res, login}
# The channel's action shell dispatches on `kind`, so every source sticks to
# this schema — including the synthetic "login" row emitted when the user
# isn't logged in.

set -eu

kind="${1:-vms}"

# Absent az or not-logged-in → single synthetic row that drives the user to
# Enter → az login (handled by [actions.show] in azure.toml).
if ! command -v az >/dev/null 2>&1; then
  printf 'login\taz-not-installed\t-\t-\tInstall az (ansible iac_tools tag)\n'
  exit 0
fi

if ! az account show >/dev/null 2>&1; then
  printf 'login\tnot-logged-in\t-\t-\tPress Enter to run az login\n'
  exit 0
fi

case "$kind" in
  rgs)
    # Resource groups. `extra` is intentionally "-" for a uniform schema.
    az group list \
      --query '[].[name, location]' \
      -o tsv 2>/dev/null \
      | awk -F'\t' 'NF{printf "rg\t%s\t-\t%s\t-\n", $1, $2}'
    ;;

  vms)
    # `az vm list -d` fetches power state in the same round-trip (avoids
    # an N+1 `az vm get-instance-view` per row). The `-d` flag also yields
    # publicIps / privateIps, but we keep the row narrow.
    az vm list -d \
      --query '[].[name, resourceGroup, location, powerState]' \
      -o tsv 2>/dev/null \
      | awk -F'\t' 'NF{printf "vm\t%s\t%s\t%s\t%s\n", $1, $2, $3, $4}'
    ;;

  pips)
    # Public IPs. `extra` combines ipAddress + FQDN so the display line is
    # useful even without opening preview.
    az network public-ip list \
      --query '[].[name, resourceGroup, location, ipAddress, dnsSettings.fqdn]' \
      -o tsv 2>/dev/null \
      | awk -F'\t' 'NF{
          ip=($4==""?"-":$4);
          fqdn=($5==""?"":" "$5);
          printf "pip\t%s\t%s\t%s\t%s%s\n", $1, $2, $3, ip, fqdn
        }'
    ;;

  nics)
    # Union of NICs + NSGs — two `az` calls, tagged by kind. NSGs are
    # scoped per-RG the same way NICs are; grouping them here keeps the
    # number of Ctrl+S cycles small.
    az network nic list \
      --query '[].[name, resourceGroup, location, ipConfigurations[0].privateIPAddress]' \
      -o tsv 2>/dev/null \
      | awk -F'\t' 'NF{
          ip=($4==""?"-":$4);
          printf "nic\t%s\t%s\t%s\t%s\n", $1, $2, $3, ip
        }'
    az network nsg list \
      --query '[].[name, resourceGroup, location, length(securityRules)]' \
      -o tsv 2>/dev/null \
      | awk -F'\t' 'NF{
          n=($4==""?"0":$4);
          printf "nsg\t%s\t%s\t%s\trules=%s\n", $1, $2, $3, n
        }'
    ;;

  all)
    # Generic fallback — one row per resource. Useful when you know a name
    # but don't remember its type. `extra` carries the ARM type string.
    az resource list \
      --query '[].[name, resourceGroup, location, type]' \
      -o tsv 2>/dev/null \
      | awk -F'\t' 'NF{
          loc=($3==""?"-":$3);
          printf "res\t%s\t%s\t%s\t%s\n", $1, $2, loc, $4
        }'
    ;;

  *)
    printf 'login\tunknown-source-%s\t-\t-\tazure-source.sh called with bad arg\n' "$kind"
    exit 0
    ;;
esac
