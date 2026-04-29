# sms — Huawei 路由器簡訊讀取器

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

CLI 與 TV channel，用來讀取 Huawei 4G/5G HiLink 路由器 (router) SIM 卡上的簡訊
(SMS) — 主要是為了不必開網頁 UI 也能拿到驗證碼。

CLI 透過 [`huawei-lte-api`](https://github.com/Salamek/huawei-lte-api)
打路由器的 XML API（`/api/sms/sms-list`、`/api/user/login` 等），
它會處理 CSRF token、SCRAM-SHA-256 登入、以及 session cookie。
這比去刮 JavaScript SPA 可靠太多。

## 安裝

由 chezmoi 自動部署：

- `~/bin/sms` — CLI（uv-script；首次執行時會把依賴解到 uv 的 cache）
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

## 剪貼簿

`sms code` 會 pipe 到既有的 `x copy` helper（見 `bin/executable_x`），
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
- **host 錯了** — 許多 HiLink 路由器預設是 `192.168.8.1`；這台用
  `192.168.168.1`。用 `SMS_ROUTER_HOST` 覆寫。
