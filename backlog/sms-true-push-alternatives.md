# SMS true-push alternatives (SmsForwarder, gammu-smsd)

**Status**: P3 (deferred — current polling is good enough)
**Effort**: M (Android route) / L (USB-modem route)
**Related**: `TODO.md` · `dot_dotfiles/bin/executable_sms` · [`docs/tools/sms.md`](../docs/tools/sms.md)

## Context

2026-10, while building `sms watch` for the Huawei B525s-65a (192.168.168.1). The
question was: can we get **real push** (event on receive) instead of polling?

## Investigation

### The HiLink router can't push

- `huawei-lte-api` is a request/response client over the router's XML API — no
  WebSocket, long-poll, or callback endpoint exists.
- The router's own web UI polls too. Its gzipped `js/main.js` + `js/sms.js` call
  `api/monitoring/check-notifications` / `api/sms/sms-count` from `setInterval(…,
  g_feature.update_interval)`, and `/config/global/config.xml` sets
  `<update_interval>6000</update_interval>` (6 s). There's no `WebSocket` /
  `EventSource` anywhere in the JS.
- The "轉發 / forward" in the SMS UI is a manual per-message button, not
  auto-forwarding. `/api/sms/config` needs login (100003).
- Rooting the B525 (telnet/ADB exploits) to run a hook on-device: possible in
  principle, but fragile and not worth the risk on the house router.

**Shipped instead**: `sms watch` makes one anonymous `GET /api/sms/sms-count`
every 10 s (can be lowered to 3–5 s) and logs in only when the counters change.
That's the same mechanism as the official UI, at ≤ 10 s latency.

### Option A — Android phone + SmsForwarder

<https://github.com/pppscn/SmsForwarder> (BSD-2-Clause, actively maintained,
~870 commits; v3.x targets Android 4.4–13).

- **Truly event-driven**: Android delivers an `SMS_RECEIVED` broadcast to the
  app, so there's no polling at all.
- It forwards SMS, incoming calls, and app notifications by rules (sender or
  content match) to: webhook, Telegram bot, email (SMTP), Bark, DingTalk, WeCom,
  Feishu, Server酱, PushPlus, SMS. Discord isn't native, but works via the generic
  **webhook** channel (POST JSON `{"content": "…"}` to the Discord webhook URL).
- Extras: remote control (send/query SMS, calls, contacts, battery), an HTTP
  server (AndServer) for active queries, frpc for NAT traversal, automation tasks.
- Caveats:
  - It needs a spare always-on Android phone with **the SIM in it**.
  - Chinese ROMs need battery-optimization / auto-start whitelisting, or the app
    gets killed.
  - It reports its version to Umeng analytics on launch.
  - Its README disclaims "for testing/learning, not commercial use".

### Option B — USB LTE dongle + gammu-smsd

<https://wammu.eu/smsd/> · docs <https://docs.gammu.org/smsd/> (Gammu 1.45.0,
2026-09; actively maintained).

- The daemon talks AT commands to a serial modem and stores messages in a
  backend: `FILES`, `SQL` (MySQL/PostgreSQL native; SQLite via ODBC/libdbi), or
  `NULL`. Kalkun is a web UI over the SQL backend.
- **`RunOnReceive = /path/script.sh`** runs a hook per received message. It gets
  message IDs as args plus env vars:
  - `SMS_MESSAGES`, `DECODED_PARTS`, `PHONE_ID`
  - `SMS_1_NUMBER`, `SMS_1_TEXT`, `SMS_1_CLASS`, `SMS_1_TIMESTAMP`, `SMS_1_DATETIME`
  - For multipart text use `DECODED_n_TEXT`, not `SMS_1_TEXT`.
  - On POSIX it **blocks** the daemon until the script exits, so keep the hook
    fast (e.g. `apprise … &`).
- Caveat: smsd itself still **scans the modem periodically** (CommTimeout-based
  loop, LoopSleep 1 s). It's just local and cheap, and the hook makes it
  push-shaped downstream. ModemManager (`mmcli`, D-Bus `Messaging.Added`) is the
  other Linux route and can react to the modem's unsolicited `+CMTI`.
- Caveat: the **B525 can't be driven this way**. It's a standalone router, not a
  USB serial modem. This route needs a separate dongle (e.g. a Huawei E3372 in
  stick/serial mode, not HiLink) **and a SIM in it**.

## Decision

Stay with `sms watch` polling. Both alternatives need the SIM moved out of the
router, but this SIM is the router's data SIM, and this number is the one
services text.

## When to revisit

- A second SIM / number dedicated to receiving codes appears → Option A
  (cheapest: an old Android phone + SmsForwarder → Discord webhook).
- A Linux box already has an LTE dongle → Option B with
  `RunOnReceive` → `apprise`.
- Sub-second latency becomes a real requirement (it isn't — codes are valid for minutes).
