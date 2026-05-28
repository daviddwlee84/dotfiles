# reyee — Ruijie / Reyee router inspector

Read-only CLI for poking at a Ruijie / Reyee "Shinya" router's eWeb API
without opening a browser, with **one** guarded writer (`set-channel`). Sister
tool to [`mi-router`](mi-router.md) (Xiaomi) and [`sms`](sms.md) (Huawei
HiLink).

Tested against a Reyee home router on the LuCI-based **eWeb** firmware (theme
`eweb-ehr`, `ReyeeOS 1.275.2406 / EW_3.0`, CN region). The H30M / H30S family
and similar EW_3.0 builds should work; unknown endpoints fail soft (a JSON
error payload, not a crash).

## How the API works

Auth is eWeb's **GibberishAES** handshake — which is OpenSSL **AES-256-CBC**
in the `Salted__` format (`-md md5`). The login password is AES-encrypted
under a static passphrase `k`, itself AES-decrypted from a blob baked into the
login page under the passphrase `eweb`. The ciphertext is POSTed to
`/cgi-bin/luci/api/auth`; the response returns `{sid, token, sn}` and sets a
cookie `<sn>=<sid>`.

Everything after login is a JSON-RPC POST to
`/cgi-bin/luci/api/cmd?auth=<sid>` with a body of
`{"method":"<bin>.<verb>","params":{"module":"<m>", ...}}`. The web UI derives
`<bin>` from a CLI tool name: `dev_config → devConfig`, `ac_config → acConfig`,
`dev_sta → devSta`. So "read the radios" is `dev_config get -m radio`, i.e.
`{"method":"devConfig.get","params":{"module":"radio"}}`.

In a self-organizing (mesh) network, add `"remoteIp":"<sub-ap-ip>"` to a
params object to target a sub-router instead of the one you logged into.

## Install

Deployed automatically by chezmoi:

- `~/.dotfiles/bin/reyee` — the CLI (uv-script; first run resolves deps)
- `~/.config/reyee/config.toml.example` — starter config

`uv` must be installed (it is, via the bootstrap script).

## First-time setup

```bash
cp ~/.config/reyee/config.toml.example ~/.config/reyee/config.toml
chmod 600 ~/.config/reyee/config.toml
$EDITOR ~/.config/reyee/config.toml   # set host + password

# Or let reyee prompt on first call and save for you
reyee login-test
```

Resolution order (first non-empty wins):

1. `--host` / `--password` CLI flags
2. `~/.config/reyee/config.toml`
3. `REYEE_HOST` / `REYEE_PASS` env vars
4. interactive `getpass` prompt (TTY only; offers to save)

Default: `host = 192.168.110.1`. The router is password-only (no username).

## Commands

```text
reyee info                                  # identity + per-radio summary
reyee radios                                # per-radio channel / TX power
reyee wifi                                   # configured SSIDs
reyee wifi --show-passwords                  #   …with cleartext PSKs
reyee clients                                # connected clients (band/ch/RSSI)
reyee login-test                             # verify creds, no other output
reyee raw devConfig.get --params '{"module":"radio"}'   # any JSON-RPC method
reyee raw devSta.get --params '{"module":"topology"}'   # mesh topology

# Guarded writer — dry-runs unless --yes:
reyee set-channel --band 5g --channel 36                 # dry-run
reyee set-channel --band 5g --channel 36 --yes           # apply
reyee set-channel --band 5g --channel 149 --ap 192.168.110.91 --yes  # sub-AP
reyee set-channel --band 5g --channel auto --yes         # restore auto
```

Global flags: `--host`, `--password`, `--timeout` (before or after the
subcommand).

## `set-channel` — the one writer, and why it's guarded

Every other subcommand is read-only. `set-channel` is the single exception
because changing a channel is the most common reason to reach for the CLI, but
it is also disruptive: applying a channel change **briefly drops every Wi-Fi
client on that radio**. So it:

- **dry-runs by default** — prints the current→target and the exact payload it
  *would* send, and changes nothing. Add `--yes` to actually apply.
- **minimal-diff** — reads the live `radioList`, changes only the one
  `channel` field, and writes the rest back verbatim (so it never clobbers
  bandwidth / TX power / country).
- **warns on DFS** — 5 GHz channels 52–64 / 100–144 require radar detection
  and are poor for latency-sensitive use; the tool flags them.
- **targets sub-APs** — `--ap <ip>` routes the change to a mesh node via the
  eWeb `remoteIp` mechanism (each AP holds its own channel; "以下配置只对当前设备生效").

Other writes (SSID, password, reboot, reset, band steering, …) are
intentionally **not** wired up — do those in the web UI.

## Useful raw modules

Read with `reyee raw devConfig.get --params '{"module":"<m>"}'` (or
`acConfig` / `devSta`):

| bin | module | what |
|---|---|---|
| `devConfig` | `radio` | per-radio channel / txpower / hwmode (the RF view) |
| `acConfig` | `wireless` | SSID list (⚠ includes cleartext PSK) |
| `devSta` | `user_list` | connected clients: band, channel, RSSI, rate |
| `devSta` | `topology` | mesh topology (which clients on which AP) |
| `devSta` | `neighbor` | neighbor APs the router has scanned |
| `acConfig` | `roam` | 802.11k/v roaming / band-steering policy |

## Read-only-by-design caveat

A side effect of the auth handshake: each fresh login creates a new session.
Running `reyee` repeatedly while you have the web UI open in a browser tab can
invalidate the browser's session and bounce it to the login screen.

## See also

- [`mi-router`](mi-router.md) — sister tool for Xiaomi / MiWiFi routers.
- [`sms`](sms.md) — sister tool for Huawei HiLink routers.
- [WiFi latency spikes](../playbooks/wifi-latency-spikes.md) — the playbook
  this tool was built for (diagnosing periodic latency on Wi-Fi).
- [`ping-monitor`](ping-monitor.md) — record ping + flag spikes.
