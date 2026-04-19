# sms — Huawei router SMS reader

CLI and TV channel for reading SMS from a Huawei 4G/5G HiLink router's SIM
card — primarily to grab verification codes without opening the web UI.

The CLI hits the router's XML API (`/api/sms/sms-list`, `/api/user/login`,
etc.) via [`huawei-lte-api`](https://github.com/Salamek/huawei-lte-api),
which handles CSRF tokens, SCRAM-SHA-256 login, and session cookies. This
is far more reliable than scraping the JavaScript SPA.

## Install

Deployed automatically by chezmoi:

- `~/bin/sms` — the CLI (uv-script; first run resolves deps into uv's cache)
- `~/.config/television/cable/sms.toml` — the `tv sms` channel
- `~/.config/sms/config.toml.example` — starter config

`uv` must be installed (it is, via the bootstrap script).

## First-time setup

```bash
# Either: populate the config file
cp ~/.config/sms/config.toml.example ~/.config/sms/config.toml
chmod 600 ~/.config/sms/config.toml
$EDITOR ~/.config/sms/config.toml   # set password

# Or: let sms prompt on first call and save for you
sms login-test
```

Env overrides (take precedence over the file):

| Variable | Purpose |
|----------|---------|
| `SMS_ROUTER_HOST` | Router IP/hostname (default `192.168.168.1`) |
| `SMS_ROUTER_USER` | Login user (default `admin`) |
| `SMS_ROUTER_PASS` | Login password |
| `SMS_CACHE_TTL` | Inbox cache TTL in seconds (default `30`, `0` disables) |

## Commands

```text
sms                         # latest verification code → stdout + clipboard
sms code [--no-copy]        # same, explicit
sms latest [-n 5]           # N most recent messages (pretty table)
sms list [--unread] [--json]
sms show INDEX [--json]
sms delete INDEX
sms refresh                 # force cache bust + refetch
sms login-test              # verify credentials/connectivity
```

Exit codes: `0` ok, `1` router error, `2` bad config/args, `3` no code found.

## TV channel

```bash
tv sms
```

- `Enter` — copy message body to clipboard
- `Alt+C` — extract and copy just the verification code
- `Alt+R` — refresh cache and reload
- `Alt+D` — delete selected message (with confirm)
- `Ctrl+S` — cycle source: all ↔ unread only
- Auto-refreshes every 5 s — leave it open while waiting for a code to arrive.

## Clipboard

`sms code` pipes through the existing `x copy` helper (see `bin/executable_x`)
so clipboard works uniformly on macOS (`pbcopy`), Linux Wayland (`wl-copy`),
Linux X11 (`xclip`/`xsel`), WSL (`clip.exe`), and over SSH (OSC 52).

## Cache

Inbox is cached at `~/.cache/sms/inbox.json` for 30 s by default. This keeps
back-to-back `sms` calls from re-logging-in to the router (each fresh login
invalidates the router's existing session, which would kick the user out of
the web UI). Use `sms refresh` or `sms --no-cache <cmd>` to bypass.

## Troubleshooting

- **`router error: ResponseErrorLoginCsrfException`** — firmware wants a
  fresh SCRAM challenge. Run `sms refresh` then retry.
- **`login failed: 108003 — user already logged in`** — log out of the web
  UI, or wait ~5 min for the router session to expire.
- **Unreachable** — confirm you're on the router's LAN (or tunnelled via
  Tailscale/SSH port-forward). The API is not exposed on WAN by default.
- **Wrong host** — many HiLink routers default to `192.168.8.1`; this one
  uses `192.168.168.1`. Override with `SMS_ROUTER_HOST`.
