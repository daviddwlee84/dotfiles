# sms — Huawei 路由器簡訊讀取器

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

CLI 與 TV channel，用來讀取 Huawei 4G/5G HiLink 路由器 (router) SIM 卡上的簡訊
(SMS) — 主要是為了不必開網頁 UI 也能拿到驗證碼。
`sms watch` 則加上**推播 (push)**：輪詢 (polling) 路由器，把每則新簡訊轉送到任一
[apprise](https://github.com/caronc/apprise) 目標（Telegram、ntfy、Discord、桌面通知…）。

CLI 透過 [`huawei-lte-api`](https://github.com/Salamek/huawei-lte-api)
打路由器的 XML API（`/api/sms/sms-list`、`/api/user/login` 等），
它會處理 CSRF token、SCRAM-SHA-256 登入、以及 session cookie。
這比去刮 JavaScript SPA 可靠太多。

## 安裝

由 chezmoi 自動部署：

- `~/.dotfiles/bin/sms` — CLI（uv-script；首次執行時會把依賴解到 uv 的 cache）
- `~/.config/television/cable/sms.toml` — `tv sms` channel
- `~/.config/sms/config.toml.example` — 起始設定範本

需要 `uv`（已透過 bootstrap script 安裝）。

## 首次設定

```bash
# 方式一：填好 config 檔
cp ~/.config/sms/config.toml.example ~/.config/sms/config.toml
chmod 600 ~/.config/sms/config.toml
$EDITOR ~/.config/sms/config.toml   # 設定密碼

# 方式二：讓 sms 在第一次呼叫時提示並幫你存
sms login-test
```

環境變數覆寫（優先順序高於設定檔）：

| Variable | 用途 |
|----------|---------|
| `SMS_ROUTER_HOST` | 路由器 IP / hostname（預設 `192.168.168.1`） |
| `SMS_ROUTER_USER` | 登入使用者（預設 `admin`） |
| `SMS_ROUTER_PASS` | 登入密碼 |
| `SMS_CACHE_TTL` | 收件匣快取 TTL，秒（預設 `30`，`0` 停用） |
| `SMS_NOTIFY_URLS` | `sms watch` 用的 apprise URL，以空白分隔（覆寫 `[watch]` 設定） |

## 命令

```text
sms                         # 最近一筆驗證碼 → stdout + 剪貼簿
sms code [--no-copy]        # 同上，明確指定
sms latest [-n 5]           # 最近 N 則訊息（漂亮表格）
sms list [--unread] [--json]
sms show INDEX [--json]
sms delete INDEX
sms refresh                 # 強制清快取並重新抓取
sms login-test              # 驗證帳密 / 連線
sms count [--json]          # 收件匣總數 / 上限 / 未讀（B525s 不需登入）
sms prune --keep N [--include-unread] [--yes]   # 刪除最舊、超出 N 則的訊息（預設只刪已讀）
sms watch [--interval 10] [--once] [--json] [--no-notify] [--mark-read]
sms notify-test [--latest] [--dry-run]          # 透過與 watch 相同的目標送一則測試推播
sms service install|uninstall|status            # `sms watch` 的 systemd --user unit（Linux）
```

Exit code：`0` 成功，`1` 路由器錯誤，`2` 設定/參數錯誤，`3` 找不到驗證碼。

## TV channel

```bash
tv sms
```

- `Enter` — 將訊息內容複製到剪貼簿
- `Alt+C` — 抽出並只複製驗證碼
- `Alt+R` — 清快取並重新載入
- `Alt+D` — 刪除選中的訊息（會詢問確認）
- `Ctrl+S` — 切換來源：全部 ↔ 僅未讀
- 每 5 秒自動刷新 — 等驗證碼時開著就好。

## 推播通知（`sms watch`）

HiLink 路由器沒有 webhook 或簡訊轉發功能，所以 `watch` 採「便宜的輪詢 + 推播」：

1. 每 `interval` 秒（預設 10）讀 `/api/sms/sms-count`。B525s 上這個 endpoint
   **不需登入**，所以平常輪詢不會佔用管理員 session，也不會把你踢出網頁 UI。
   （若韌體要求登入，會退回每次輪詢短暫登入。）
2. 只有在 `(LocalInbox, LocalUnread)` 改變時——或每 `full_sync` 秒保底一次——才登入、
   讀最新 50 則，並與 platformdirs state 目錄中的 `seen.json` 比對
   （Linux 為 `~/.local/state/sms/`，macOS 為 `~/Library/Application Support/sms/`）。
   訊息以 `index|phone|date` 作為 key，因為 index 會被重複使用。
3. 每則新訊息 → 一次 apprise 推播：標題 `SMS from <phone>`，偵測到驗證碼時內文前綴
   `[code 123456]`。同時印到 stdout（`--json` → JSONL），並清掉 `sms` 快取，
   讓 `sms` / `tv sms` 立刻看得到。

**第一次執行**會用目前收件匣靜默建立 state（不會一次灌出舊訊息）；
`--notify-existing-unread` 則改為推播目前的未讀訊息。比建立時間點還舊、
又從未見過的訊息（例如刪除後滑回 50 則視窗的舊訊息）會被忽略。

目標（先符合者優先）— 設定於 `~/.config/sms/config.toml`：

```toml
[watch]
notify_urls = ["tgram://<bot_token>/<chat_id>"]   # 或 ntfy://topic、discord://…
# notify_tag = "sms"     # …或使用 ~/.config/apprise/apprise.yaml 裡的 tag
```

`SMS_NOTIFY_URLS`（env）> `notify_urls` > `notify_tag`。URL 透過 `APPRISE_URLS`
環境變數交給 apprise，而非 argv，所以 token 不會出現在 `ps`。
Token 絕不進 chezmoi——只管理 `.example`。

推播失敗不會無聲無息：會記到 stderr，並附加到同一 state 目錄的 `notify.log`。
（該訊息仍會被標為已見——懷疑漏訊時查這個 log。）路由器 / 網路錯誤會以指數退避
(exponential backoff，上限 5 分鐘) 重試，而不是直接結束。

快速測試：

```bash
sms notify-test --dry-run                       # 列出 apprise 會通知哪些服務（不實際發送）
sms notify-test                                 # 固定內容的測試推播
sms notify-test --latest                        # 最新一則真實簡訊，格式與 watch 完全相同
sms watch --once --no-notify                    # 建立 state
SMS_NOTIFY_URLS='macosx://' sms watch           # 桌面橫幅，前景執行
```

Discord webhook 可直接使用：apprise 接受原生的
`https://discord.com/api/webhooks/<id>/<token>` 格式（等同 `discord://<id>/<token>`）。
請寫在 `[watch] notify_urls`，不要放在命令列——`SMS_NOTIFY_URLS=…` 前綴會留在 shell history。

## 以服務方式執行

在路由器 LAN 上一台常駐的 Linux 機器：

```bash
chezmoi apply                       # 部署 sms
$EDITOR ~/.config/sms/config.toml   # 密碼 + [watch] notify_urls
sms watch --once --no-notify        # 健全性檢查 + 建立 state
sms service install                 # 寫入 ~/.config/systemd/user/sms-watch.service 並 enable --now
journalctl --user -u sms-watch -f
sudo loginctl enable-linger "$USER" # 登出 / 重開機後仍持續執行（install 會在未開啟時提醒）
```

unit 是按需產生、而非由 chezmoi 部署，所以只會存在於選擇啟用的機器上。它會記下執行
install 時 shell 的 `PATH`（找 `uv` / `apprise` 用）。它**不會**繼承 shell 的 proxy
變數——若 apprise 需要 proxy 才能連到 Telegram 等，用 `systemctl --user edit sms-watch`
加上（`Environment=HTTPS_PROXY=…`）。對路由器的 LAN 流量一律繞過 proxy
（`trust_env=False`，與 `mi-router` / `reyee` 相同）。

macOS 上改用 tmux / pueue（或 LaunchAgent）執行 `sms watch`；`sms service` 僅支援 Linux。

## 收件匣容量 / prune

`sms count` 顯示 `LocalInbox/LocalMax`（網頁 UI 的「202/209」是*未讀/總數*，不是容量——
B525s 可存 500 則）。收件匣滿了路由器會丟棄新簡訊，所以 `watch` 在達到
`capacity_warn`（預設 95%）時推播一次警告。釋放空間：

```bash
sms prune --keep 200                 # 刪除最新 200 則以外、最舊的已讀訊息
sms prune --keep 200 --include-unread --yes
```

## 剪貼簿

`sms code` 會 pipe 到既有的 `x copy` helper（見 `dot_dotfiles/bin/executable_x`），
所以剪貼簿在 macOS（`pbcopy`）、Linux Wayland（`wl-copy`）、Linux X11
（`xclip`/`xsel`）、WSL（`clip.exe`）以及透過 SSH（OSC 52）都能一致運作。

## 快取

收件匣預設快取在 `~/.cache/sms/inbox.json`，TTL 30 秒。
這是為了避免連續呼叫 `sms` 時一直重新登入路由器（每次新登入都會讓路由器
原有的 session 失效，會把使用者踢出網頁 UI）。要繞過時用 `sms refresh`
或 `sms --no-cache <cmd>`。

## 排錯

- **`router error: ResponseErrorLoginCsrfException`** — 韌體要求新的
  SCRAM challenge。執行 `sms refresh` 然後重試。
- **`login failed: 108003 — user already logged in`** — 從網頁 UI 登出，
  或等約 5 分鐘讓路由器 session 過期。
- **連不上** — 確認你在路由器的 LAN 上（或透過 Tailscale / SSH
  port-forward 隧道進去）。API 預設不會在 WAN 暴露。
- **`sms watch` 執行中，網頁 UI 登入出現 108003** — watcher 只在收件匣變動時短暫登入，
  幾秒後重試即可；或在使用網頁 UI 時 `systemctl --user stop sms-watch`。
- **`sms watch` 沒有推播** — 查看 state 目錄中的 `notify.log`，並直接測試 URL：
  `apprise -b test '<url>'`。
- **host 錯了** — 許多 HiLink 路由器預設是 `192.168.8.1`；這台用
  `192.168.168.1`。用 `SMS_ROUTER_HOST` 覆寫。
