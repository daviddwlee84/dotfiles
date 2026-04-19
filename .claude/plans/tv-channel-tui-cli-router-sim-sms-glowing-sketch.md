# Huawei Router SMS CLI + TV channel

## Context

Need to remotely read SMS (especially SMS verification codes) from a Huawei 4G/5G
mobile router's SIM card. Router: `http://192.168.168.1/` (login `admin` /
`keith123`). The web UI is a JavaScript SPA (`smsinbox.html`) so direct HTML
scraping is fragile.

Goal: a small CLI (`x`-style) that prints/copies the latest verification code in
one keystroke, plus an interactive TV channel for browsing the inbox. Add a
short-lived cache so repeated calls don't re-login and re-hammer the router.

## Approach

Use the **Huawei HiLink API** directly instead of scraping the SPA. All Huawei
4G/5G CPEs (HiLink firmware) expose an XML API at `/api/...` that the SPA
itself calls. The `huawei-lte-api` Python package handles the tricky parts
(CSRF tokens, SCRAM-SHA-256 login used by newer firmware, session cookies).

- Docs: the library has `Client.sms.get_sms_list(...)` returning inbox entries
  with `Phone`, `Content`, `Date`, `Index`, `Smstat` (read/unread).
- Much more reliable than Playwright/Selenium; no JS engine needed.

### Deliverables

1. `bin/executable_sms` — uv-script Python CLI (single file, `#!/usr/bin/env -S uv run --script`).
2. `dot_config/television/cable/sms.toml` — TV channel that shells out to `sms`.
3. `README.md` + `docs/zsh/aliases.md` updates (per CLAUDE.md rules).

Deploy style mirrors `bin/executable_x` — chezmoi drops it at `~/bin/x`, so this
lands at `~/bin/sms` (already on PATH per existing zsh setup).

### CLI surface

```
sms                         # default: latest unread verification code (stdout) + clipboard
sms code [--copy/--no-copy] # latest verification code, auto-extract digits
sms latest [-n N]           # N most recent SMS, human-readable
sms list [--unread] [--json]
sms show INDEX              # full body of one message
sms delete INDEX
sms refresh                 # force cache bust
sms login-test              # verify credentials/connectivity
sms help
```

Exit codes: 0 ok, 1 router error, 2 bad args, 3 no code found.

### Credentials & config

Precedence (first hit wins):
1. `SMS_ROUTER_HOST` / `SMS_ROUTER_USER` / `SMS_ROUTER_PASS` env vars.
2. `~/.config/sms/config.toml` (`chmod 600`) — `host`, `user`, `password`.
3. Prompt interactively on first run; offer to save.

Defaults: `host = "192.168.168.1"`, `user = "admin"`. Password never defaulted.
The user's actual password does **not** get committed — the tool creates
`~/.config/sms/config.toml` locally on first run. Provide `dot_config/sms/config.toml.example` in the repo.

### Caching

- Cache file: `~/.cache/sms/inbox.json` (+ `.meta` with timestamp, count).
- TTL: 30 s by default, overridable via `SMS_CACHE_TTL` (seconds, `0` disables).
- Rationale: verification-code flows fire several calls back-to-back; cache
  avoids re-login churn (Huawei session tokens are short-lived and a fresh
  login invalidates prior sessions, which would kick the user out of the web UI).
- `sms refresh` / `--no-cache` bypass.
- Session reuse: keep the `huawei-lte-api` `Connection` alive across a single
  process; persist the session cookie + token to `~/.cache/sms/session.json`
  with a 5 min TTL so successive CLI invocations skip the SCRAM round-trip.

### Verification-code extraction

Regex `(?<!\d)(\d{4,8})(?!\d)` applied to the newest inbox entry (by `Date`
desc). Heuristics:
- Prefer SMS whose body matches `/verification|驗證|验证|code|OTP|one-time/i`.
- Fall back to newest numeric-only run if no keyword matches.
- On `sms code`, pipe to `x copy` when available (reuse existing
  `bin/executable_x`) — this automatically handles macOS/Linux/WSL clipboards.

### uv-script header

```python
#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "huawei-lte-api>=1.10",
#   "rich>=13",         # pretty table for `sms list`
#   "platformdirs>=4",  # XDG cache/config paths
# ]
# ///
```

No `requirements.txt` / venv needed — `uv` resolves on first run and caches.

### TV channel (`sms.toml`)

- Source: `sms list --json | jq -r '.[] | [.index, (.smstat|tostring), .phone, .date, (.content|gsub("\n";" ")|.[0:120])] | @tsv'`
- Display: `{split:\t:1}  {split:\t:2}  {split:\t:3}  {split:\t:4}`
- Preview: `sms show {split:\t:0}`
- Keybindings (Alt+ namespace, per CLAUDE.md tmux/TV conflict rules):
  - `Enter` — copy body to clipboard
  - `Alt+C` — copy verification code only
  - `Alt+R` — `sms refresh` + reload
  - `Alt+D` — `sms delete` + reload (with confirm)
  - `Alt+U` — toggle unread filter (source cycle)
- `watch = 5.0` so the inbox updates while waiting for a code.

## Files to create / modify

- **new** `bin/executable_sms` — the CLI (uv script, ~250 lines).
- **new** `dot_config/television/cable/sms.toml` — TV channel.
- **new** `dot_config/sms/config.toml.tmpl` — chezmoi template with sensible
  defaults; password pulled from chezmoi prompt or left blank.
- **new** `docs/tools/sms.md` — usage, config, clipboard integration, troubleshooting.
- **edit** `README.md` — add `sms` under "What You Get > Tools".
- **edit** `docs/zsh/aliases.md` — add the `sms` shortcut row (treat the bin
  script like custom commands; optionally alias `smscode='sms code'`).
- **edit** `CLAUDE.md` — no change needed (existing patterns cover it).

## Reuse

- `bin/executable_x` — pipe text into `x copy` for clipboard writes (WSL / macOS / Linux / OSC52 all handled).
- XDG paths — use `platformdirs.user_cache_dir("sms")` / `user_config_dir("sms")` to stay consistent with the rest of the repo.
- Bitwarden CLI is available (`bw`); as a follow-up we could optionally resolve the password via `bw get password huawei-router` if `SMS_ROUTER_PASS_BW_ITEM` is set. Out of scope for v1 to keep dependencies thin.

## Verification

1. `chezmoi apply` → `~/bin/sms` is executable, `~/.config/sms/config.toml.example` exists.
2. On the router's network: `sms login-test` → prints `ok (model=..., firmware=...)`.
3. `sms list -n 5` → shows the 5 most recent messages in a rich table.
4. Send yourself a test SMS with a 6-digit code → `sms code` prints it and clipboard contains just the digits (paste to verify).
5. `sms refresh && sms list` → confirms cache-bypass path.
6. `tv sms` → TV channel opens, arrow keys scroll, preview shows full body, `Alt+C` copies code.
7. Offline behaviour: unplug from router LAN → `sms list` shows cached result while TTL valid, then errors cleanly with "router unreachable".

## Security notes

- Config file written `0600`; cache/session files written `0600`.
- Never log the password. `sms login-test -v` masks it.
- `.gitignore` / chezmoi ignore already covers `~/.config/sms/config.toml`
  because it's created at runtime, not tracked — only the `.example` template
  lives in the repo.
