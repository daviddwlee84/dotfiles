# Plan: IP Geo / VPN-check shell functions

## Context

The existing `myip` alias (`curl -s https://ifconfig.me`) returns only a raw IP —
good for scripting but useless for verifying whether a VPN is actually routing
traffic through the intended exit node. `ipinfo.io` returns structured JSON
(ip / city / region / country / org) in a single call, making it the right tool for
a one-glance VPN check. This plan adds `ipgeo` + `vpncheck` to the existing
networking helper file and documents them.

## Service comparison (reference, not written to any file)

| `curl` target | Output | Best for |
|---|---|---|
| `ifconfig.me` | raw IP | scripting (`myip` alias) |
| `ipinfo.io` | JSON: ip, city, region, country, org | VPN verification ← **use this** |
| `ipinfo.io/ip` | raw IP | same as ifconfig.me |
| `ip.me` | raw IP | bare alternative |
| `icanhazip.com` | raw IP | Cloudflare-backed alternative |
| `checkip.amazonaws.com` | raw IP | AWS-backed alternative |

`ipinfo.io` wins for VPN checking because it bundles geo + ISP in one call
with no extra flags. The others all require a second call or an API endpoint
suffix to get geo info. Keep `myip → ifconfig.me` as-is (plain IP,
scriptable, zero-JSON-parsing).

## Changes

### 1. `dot_config/shell/50_networking.sh`

Append under the `# --- IP address helpers ---` section (after line 15),
**before** the `# --- nmap shortcuts ---` block:

```sh
# ipinfo.io returns JSON (ip/city/region/country/org) in one call; better than
# ifconfig.me for VPN exit-node checks where you need the ISP/country at a glance.
ipgeo() {
  if command -v jq &>/dev/null; then
    curl -s https://ipinfo.io | jq -r '"IP:      \(.ip)\nCity:    \(.city)\nRegion:  \(.region)\nCountry: \(.country)\nOrg:     \(.org)"'
  else
    curl -s https://ipinfo.io
  fi
}
alias vpncheck='ipgeo'
```

No tool guard needed — only `curl` (already a baseline assumption in this
file) and optionally `jq` (graceful fallback to raw JSON).

### 2. `docs/shells/aliases.md`

In the **Networking** table (around line 543), add two rows after the
existing `myip` row:

```
| `ipgeo` | function | `dot_config/shell/50_networking.sh` | Public IP + city / country / ISP via ipinfo.io; jq-pretty if available, raw JSON fallback |
| `vpncheck` | alias | `dot_config/shell/50_networking.sh` | Alias for `ipgeo` — one-glance check that VPN exit node is the expected country/ISP |
```

No other files need updating (this is a pure-curl function with no new
install dependency, so `docs/this_repo/tool-managers.md` is unaffected).

## Verification

```sh
# After chezmoi apply (or `source ~/.config/shell/50_networking.sh`):
ipgeo          # should print IP / City / Region / Country / Org
vpncheck       # same output (alias)

# With VPN on vs off — Country and Org should differ
# Without jq:  PATH_OVERRIDE=$(which jq) unset jq; ipgeo  # raw JSON
```
