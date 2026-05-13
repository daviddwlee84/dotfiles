# mi-router — MiWiFi (Xiaomi) router inspector

Read-only CLI for poking at a Xiaomi / MiWiFi router's stock web API without
opening a browser. Sister tool to [`sms`](sms.md) (which does the same job
for Huawei HiLink routers).

The CLI hits the LuCI/MiWiFi JSON API under `/cgi-bin/luci/;stok=<token>/api/`
after performing the router's standard SHA1 challenge handshake
(`sha1(nonce + sha1(password + key))`). No third-party SDK exists; the auth
flow is implemented inline.

Tested against Xiaomi AX9000 (hardware ID `RA70`), MiWiFi firmware `1.0.168`
(CN region). Likely works on most MiWiFi 3.x firmwares — endpoints
deviating per model fall through gracefully (the script reports `endpoint
not registered` instead of crashing).

## Install

Deployed automatically by chezmoi:

- `~/.dotfiles/bin/mi-router` — the CLI (uv-script; first run resolves deps
  into uv's cache)
- `~/.config/mi-router/config.toml.example` — starter config

`uv` must be installed (it is, via the bootstrap script).

## First-time setup

```bash
# Either: populate the config file
cp ~/.config/mi-router/config.toml.example ~/.config/mi-router/config.toml
chmod 600 ~/.config/mi-router/config.toml
$EDITOR ~/.config/mi-router/config.toml   # set host + password

# Or: let mi-router prompt on first call and save for you
mi-router login-test
```

Resolution order (first non-empty wins):

1. `--host` / `--username` / `--password` CLI flags
2. `~/.config/mi-router/config.toml`
3. `MI_ROUTER_HOST` / `MI_ROUTER_USER` / `MI_ROUTER_PASS` env vars
4. Interactive `getpass` prompt (TTY only; offers to save to config)

Defaults: `host = 192.168.31.1`, `user = admin`.

## Commands

```text
mi-router info                              # router identity, FW, LAN/WAN
mi-router wifi                              # all radios
mi-router wifi --show-passwords             #   …with cleartext PSKs
mi-router devices                           # online clients (default)
mi-router devices --no-online-only          #   include offline
mi-router mdns                              # discovery toggles + caveats
mi-router all                               # info + wifi + devices + mdns
mi-router login-test                        # verify creds, no other output
mi-router raw xqnetwork/wifi_detail_all     # any MiWiFi API endpoint (GET)
```

Global flags: `--host`, `--username`, `--password`, `--timeout`. They work
either before or after the subcommand.

## What `mi-router mdns` reports

The MiWiFi web UI exposes very few discovery-related toggles. The two it
does:

- **`miotrelay` (畅快连)** — multicast/IoT discovery relay across radios.
  Leave **on** if you care about mDNS-style cross-band discovery.
- **`miscan` (AIoT Smart Antenna Auto-Scan)** — auto-discovers
  unprovisioned Mi smart devices on 5G for the Mi Home onboarding flow.

What is **not** exposed by the stock UI on this firmware: AP/client
isolation, IGMP snooping, multicast-to-unicast / multicast rate, generic
mDNS reflector, per-SSID firewall rules. To inspect or change those you'd
need SSH access (disabled by default on stock firmware) or to flash
OpenWrt / a dev firmware.

For the full mDNS troubleshooting workflow — including the `dns-sd` and
`tcpdump` recipes — see [`playbooks/mdns-diagnostics.md`](../playbooks/mdns-diagnostics.md).

## Read-only by design

No POST-bearing endpoints are wired up. The `raw` subcommand is also
GET-only. This is deliberate: for the inspector use case, the cost of an
accidental toggle (kicking your IoT devices off the network, breaking
mesh, locking yourself out) outweighs the convenience. If you need to flip
something, do it in the web UI.

A side effect of the auth handshake worth knowing: each fresh login
invalidates the router's existing web session, which kicks an open
browser tab back to the login screen. Don't run `mi-router` repeatedly in
a tight loop while you're using the web UI in another tab.

## Endpoints used

For reference / extending via `mi-router raw`:

| Endpoint | Subcommand | Purpose |
|---|---|---|
| `xqsystem/login` | (auth) | SHA1 challenge login |
| `xqsystem/fac_info` | `info` | Firmware version, SSH/Telnet status |
| `misystem/router_name` | `info` | Router display name |
| `misystem/topo_graph` | `info` | Hardware ID, mode |
| `xqnetwork/lan_info` | `info` | LAN IP / mask / MAC |
| `xqnetwork/wan_info` | `info` | WAN IP, type, gateway, DNS |
| `xqnetwork/wifi_detail_all` | `wifi` | Per-radio config (SSID, ch, BW, enc, AX) |
| `misystem/devicelist` | `devices` | Connected clients |
| `xqnetwork/get_miotrelay_switch` | `mdns` | "畅快连" relay state |
| `xqnetwork/get_miscan_switch` | `mdns` | AIoT 5G scan state |

There are dozens more endpoints (`misystem/qos_info`, `xqsystem/upnp`,
`xqnetwork/wifi_macfilter_info`, `xqnetwork/mode`, …) — explore via `raw`.

## Troubleshooting

- **`login failed: {'code': 401, ...}`** — wrong password. Re-prompt by
  deleting the cached value: `$EDITOR ~/.config/mi-router/config.toml`.
- **`could not parse login key/mac from router page`** — your firmware's
  login page differs from the regex assumptions. Open
  `http://<router>/cgi-bin/luci/web` in a browser, view source, look for
  the `key:` and `mac:` JS literals, and patch `KEY_RE` / `MAC_RE` in the
  script.
- **`endpoint not registered (404)`** — the endpoint doesn't exist on this
  firmware. The script returns a JSON `_error` payload instead of crashing
  so you can keep exploring.
- **Web UI keeps logging me out** — see "Read-only by design" above; each
  `mi-router` call is a fresh login.

## See also

- [`sms`](sms.md) — sister tool for Huawei HiLink routers.
- [`playbooks/mdns-diagnostics.md`](../playbooks/mdns-diagnostics.md) — when
  and how to use `mi-router mdns` inside a wider Bonjour/mDNS investigation.
