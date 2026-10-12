# sms — Huawei router SMS reader

CLI and TV channel for reading SMS from a Huawei 4G/5G HiLink router's SIM
card — primarily to grab verification codes without opening the web UI.
`sms watch` adds **push**: it polls the router and forwards each new SMS
to any [apprise](https://github.com/caronc/apprise) target (Telegram, ntfy,
Discord, desktop…).

Sister tools: [`mi-router`](mi-router.md) (Xiaomi / MiWiFi) and
[`reyee`](reyee.md) (Ruijie / Reyee). They stay separate — each vendor's auth
and API are unrelated — but share conventions: standalone uv-script,
`~/.config/<tool>/config.toml` (0600) + env overrides + TTY prompt-and-save,
and LAN requests that ignore ambient proxy env.

The CLI hits the router's XML API (`/api/sms/sms-list`, `/api/user/login`,
etc.) via [`huawei-lte-api`](https://github.com/Salamek/huawei-lte-api),
which handles CSRF tokens, SCRAM-SHA-256 login, and session cookies. This
is far more reliable than scraping the JavaScript SPA.

## Install

Deployed automatically by chezmoi:

- `~/.dotfiles/bin/sms` — the CLI (uv-script; first run resolves deps into uv's cache)
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
| `SMS_NOTIFY_URLS` | Space-separated apprise URLs for `sms watch` (overrides `[watch]` config) |

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
sms count [--json]          # inbox total / max / unread (no login needed on B525s)
sms prune --keep N [--include-unread] [--yes]   # delete oldest beyond N (read-only by default)
sms watch [--interval 10] [--once] [--json] [--no-notify] [--mark-read]
sms notify-test [--latest] [--dry-run]          # one test push via the same targets as watch
sms service install|uninstall|status            # systemd --user unit for `sms watch` (Linux)
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

## Push notifications (`sms watch`)

HiLink routers have no webhook / SMS-forwarding hook, so `watch` is a cheap
poll + push:

1. Every `interval` seconds (default 10) it reads `/api/sms/sms-count`.
   On the B525s this endpoint answers **without login**, so steady-state
   polling holds no admin session and never kicks you out of the web UI.
   (If a firmware demands login, it falls back to a short login per poll.)
2. Only when `(LocalInbox, LocalUnread)` changes — or every `full_sync`
   seconds as a safety net — it logs in, reads the newest 50 messages, and
   diffs them against `seen.json` in the platformdirs state dir
   (`~/.local/state/sms/` on Linux, `~/Library/Application Support/sms/` on macOS).
   Messages are keyed by `index|phone|date`, since indexes get reused.
3. Each new message → one apprise push: title `SMS from <phone>`, body
   prefixed with `[code 123456]` when a verification code is detected. It
   is also printed on stdout (`--json` → JSONL) and the `sms` cache is
   busted so `sms` / `tv sms` see it immediately.

The **first run** silently seeds the state from the current inbox (no flood
of old messages); `--notify-existing-unread` pushes the current unread ones
instead. A never-seen message older than the seed point (e.g. an old one
sliding back into the 50-message window after deletions) is ignored.

Targets (first match wins) — configure in `~/.config/sms/config.toml`:

```toml
[watch]
notify_urls = ["tgram://<bot_token>/<chat_id>"]   # or ntfy://topic, discord://…
# notify_tag = "sms"     # …or a tag from ~/.config/apprise/apprise.yaml
```

`SMS_NOTIFY_URLS` (env) > `notify_urls` > `notify_tag`. URLs are handed to
apprise via `APPRISE_URLS` env, not argv, so tokens don't show in `ps`.
Tokens never go into chezmoi — only the `.example` is managed.

A failed push is never silent: it's logged to stderr and appended to
`notify.log` in the same state dir. (The message is still marked seen —
check that log if you suspect a miss.) Router/network errors back off
exponentially (cap 5 min) instead of exiting.

Quick test:

```bash
sms notify-test --dry-run                       # which services apprise would hit (sends nothing)
sms notify-test                                 # canned test push
sms notify-test --latest                        # newest real SMS, formatted exactly like watch
sms watch --once --no-notify                    # seed state
SMS_NOTIFY_URLS='macosx://' sms watch           # desktop banners, foreground
```

Discord webhooks work as-is: apprise accepts the native
`https://discord.com/api/webhooks/<id>/<token>` form (= `discord://<id>/<token>`).
Put it in `[watch] notify_urls` rather than on the command line — an
`SMS_NOTIFY_URLS=…` prefix lands in shell history.

## Running as a service

On an always-on Linux box on the router's LAN:

```bash
chezmoi apply                       # deploys sms
$EDITOR ~/.config/sms/config.toml   # password + [watch] notify_urls
sms watch --once --no-notify        # sanity check + seed
sms service install                 # writes ~/.config/systemd/user/sms-watch.service, enable --now
journalctl --user -u sms-watch -f
sudo loginctl enable-linger "$USER" # survive logout/reboot (install warns if off)
```

The unit is generated on demand rather than deployed by chezmoi, so it only
exists on the host that opts in. It captures the installing shell's `PATH`
(for `uv` / `apprise`). It does **not** inherit shell proxy vars — if apprise
needs a proxy to reach Telegram etc., add it with
`systemctl --user edit sms-watch` (`Environment=HTTPS_PROXY=…`). LAN traffic
to the router always bypasses proxies (`trust_env=False`, same as
`mi-router` / `reyee`).

On macOS, run `sms watch` under tmux/pueue (or a LaunchAgent) instead;
`sms service` is Linux-only.

## Inbox capacity / prune

`sms count` shows `LocalInbox/LocalMax` (the web UI's "202/209" is
*unread/total*, not capacity — the B525s holds 500). When the inbox fills,
the router drops new SMS, so `watch` pushes a one-time alert at
`capacity_warn` (default 95%). Free space with:

```bash
sms prune --keep 200                 # oldest read messages beyond the newest 200
sms prune --keep 200 --include-unread --yes
```

## Clipboard

`sms code` pipes through the existing `x copy` helper (see `dot_dotfiles/bin/executable_x`)
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
- **Web UI login fails with 108003 while `sms watch` runs** — the watcher
  only logs in briefly when the inbox changes, so retry in a few seconds; or
  `systemctl --user stop sms-watch` while you use the web UI.
- **Sporadic `RemoteDisconnected` in `sms watch`** — the router's httpd closes
  keep-alive sockets early. Polling uses one plain GET with `Connection: close`
  and a single failure is retried silently after 2 s; only consecutive failures
  are logged and backed off.
- **`sms watch` pushes nothing** — check `notify.log` in the state dir and
  test the URL directly: `apprise -b test '<url>'`.
- **Wrong host** — many HiLink routers default to `192.168.8.1`; this one
  uses `192.168.168.1`. Override with `SMS_ROUTER_HOST`.
