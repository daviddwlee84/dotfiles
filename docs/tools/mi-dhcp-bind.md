# mi-dhcp-bind — MiWiFi static DHCP reservations (writer)

Opt-in **write** companion to [`mi-router`](mi-router.md). `mi-router` is
read-only by design; when you actually need to pin a device to a fixed LAN IP
(a static DHCP reservation), this tool does it via the MiWiFi web API — without
opening the router UI.

Kept as a **separate** binary on purpose so `mi-router`'s read-only guarantee
stays intact.

Tested against Xiaomi AX9000 (`RA70`), MiWiFi firmware `1.0.168`.

## Install

Deployed by chezmoi to `~/.dotfiles/bin/mi-dhcp-bind` (uv-script; first run
resolves deps into uv's cache). Shares `mi-router`'s credentials — no separate
config. Resolution order (first non-empty wins):

1. `--host` / `--username` / `--password`
2. `~/.config/mi-router/config.toml`
3. `MI_ROUTER_HOST` / `MI_ROUTER_USER` / `MI_ROUTER_PASS`
4. interactive prompt (TTY only)

## Commands

```text
mi-dhcp-bind list                                   # current reservations (read-only)
mi-dhcp-bind bind                                   # interactive: pick "this machine" or a client
mi-dhcp-bind bind --self --yes                      # pin THIS host (autodetected MAC + LAN IP)
mi-dhcp-bind bind AA:BB:CC:DD:EE:FF 192.168.31.50 --name nas --yes
mi-dhcp-bind unbind AA:BB:CC:DD:EE:FF --yes         # remove a reservation
```

`--self` autodetects the NIC used to reach the router (its MAC + current IP) and
labels the reservation with the hostname. With no MAC/IP and no `--self`, a TTY
run drops into an interactive picker that offers **"this machine"** plus the
router's online clients.

**Safety:** writes require `--yes` (or an interactive `[y/N]` confirm), and
`--dry-run` prints the exact POST without sending. Every successful write reads
the reservation list back so you can see the result.

## API used

| Endpoint | Method | Body | Purpose |
|---|---|---|---|
| `xqnetwork/mac_bind` | POST | `data=[{"mac","ip","name"}]` (JSON array, url-enc) | add / replace a reservation |
| `xqnetwork/mac_unbind` | POST | `mac=<MAC>` | remove a reservation |
| `xqnetwork/macbind_info` | GET | — | read reservations (the `list` array) |

The newer firmware wraps the binding in a `data=` JSON **array** — a plain
`mac=&ip=` body is rejected with `参数错误` (code 1523). Auth is the same SHA1
challenge handshake as `mi-router` (`sha1(nonce + sha1(password + key))`);
MiWiFi occasionally rejects rapid re-logins with `Invalid nonce` (code 1582), so
the tool retries with a short backoff.

## See also

- [`mi-router`](mi-router.md) — the read-only inspector this extends (its "Write
  endpoints — intentionally NOT supported" list is what `mi-dhcp-bind` opts into).
- A fresh login invalidates the router's web session (kicks an open browser tab
  back to the login screen) — same caveat as `mi-router`; don't run it in a tight
  loop while using the web UI.
