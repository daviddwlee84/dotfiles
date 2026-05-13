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
mi-router endpoints                         # curated catalog of GET endpoints
mi-router endpoints --check                 #   …live-probe each one
mi-router login-test                        # verify creds, no other output
mi-router raw xqnetwork/wifi_detail_all     # any MiWiFi GET endpoint
```

Global flags: `--host`, `--username`, `--password`, `--timeout`. They work
either before or after the subcommand. `endpoints` (without `--check`) is
the only subcommand that does **not** require credentials — it prints a
static catalog without touching the router.

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

## Endpoints used / available

The hard-coded subcommands cover what most people want, but there are dozens
more GET endpoints worth knowing. Run `mi-router endpoints` for a live
table; this is the same catalog formatted for reading:

**System / firmware** (always-safe GET):

| Endpoint | Subcommand | Purpose |
|---|---|---|
| `xqsystem/login` | (auth) | SHA1 challenge login (POST, internal) |
| `xqsystem/fac_info` | `info` | Firmware version, SSH/Telnet, factory SSIDs |
| `xqsystem/country_code` |  | Regulatory region |
| `xqsystem/get_languages` |  | Available UI languages |
| `xqsystem/check_rom_update` |  | Firmware-update check (no upgrade triggered) |
| `xqsystem/upnp` |  | UPnP daemon state + active port mappings |
| `misystem/router_name` | `info` | Router display name + locale |
| `misystem/topo_graph` | `info` | Hardware ID, mode, mesh topology |
| `misystem/newstatus` |  | Aggregated dashboard data (HW + counts) |
| `misystem/status` |  | Per-device traffic stats (up/down speed) |
| `misystem/sys_time` |  | Router clock + timezone |
| `misystem/messages` |  | System notifications inbox |
| `misystem/r_ip_conflict` |  | IP conflict detection state |
| `misystem/web_access_info` |  | Remote web-access (WAN admin) status |

**Network — LAN / WAN**:

| Endpoint | Subcommand | Purpose |
|---|---|---|
| `xqnetwork/lan_info` | `info` | LAN IP / mask / MAC / uptime |
| `xqnetwork/lan_dhcp` |  | LAN DHCP pool + lease config |
| `xqnetwork/wan_info` | `info` | WAN config + status + DNS |
| `xqnetwork/pppoe_status` |  | WAN protocol detail (DHCP/PPPoE/static) |
| `xqnetwork/mode` |  | Router mode (`0` = router) |
| `xqnetwork/macbind_info` |  | MAC ↔ IP bindings + device list |
| `xqnetwork/portforward` |  | Port-forwarding rules |
| `xqnetwork/get_lanaggregation_switch` |  | LAN aggregation (link bonding) state |
| `xqnetdetect/nettb` |  | Network detect status |

**Wi-Fi**:

| Endpoint | Subcommand | Purpose |
|---|---|---|
| `xqnetwork/wifi_detail_all` | `wifi` | Per-radio config (SSID, ch, BW, enc, AX) |
| `xqnetwork/wifi_macfilter_info` |  | MAC filter list + currently-connected wifi clients |
| `xqnetwork/get_miotrelay_switch` | `mdns` | "畅快连" multicast relay state |
| `xqnetwork/get_miscan_switch` | `mdns` | AIoT 5G unprovisioned-device scan state |
| `xqnetwork/get_son_backhaul_mode` |  | Mesh backhaul mode |
| `misns/wifi_share_info` |  | Mi shared-WiFi feature ⚠ **may include cleartext SSID/PSK** |

**Devices & QoS**:

| Endpoint | Subcommand | Purpose |
|---|---|---|
| `misystem/devicelist` | `devices` | All known clients (online + offline) |
| `misystem/qos_info` |  | QoS state + per-client priorities |

### Write endpoints (POST) — intentionally NOT supported

The `raw` subcommand only does GET. These all exist on the router but the
CLI won't reach them; flip them in the web UI if you need to:

- `xqsystem/{reboot, reset, shutdown, set_country_code, set_language, set_mac_filter, set_name_password}`
- `xqnetwork/{set_wifi, set_all_wifi, set_wifi_ax, set_wifi_macfilter, set_wifi_txbf, set_wifi_txpwr, set_lan_aggregation, set_lan_dhcp, set_lan_ip, set_management_ip, set_son_backhaul_mode}`
- `xqnetwork/{miotrelay_switch, miscan_switch, add_mesh_node, scan_mesh_node, edit_device, mac_bind, mac_unbind, manually_add}`
- `misystem/{set_router_name, set_band, web_access_opt}`

### Discovered-but-unstable endpoints

Some endpoints exist in the routing table but only return useful data with
specific parameters or app state:

- `misystem/qos_{guest,xq}` → `code:1523` (参数错误 / "missing parameter")
- `misystem/qos_{limits,mode,offlimit}` → `code:1607` (QoS must be on)
- `xqnetwork/get_addnode_status` → 500 (only valid during mesh-add flow)
- `xqdatacenter/request` → 500 (needs JSON body)
- `misystem/active`, `xqnetdetect/netupspeed` → 502 (probably need params)

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
