# Tunnel 工具（ngrok / cloudflared）

將本機 port 或服務暴露到網際網路——適用於 webhook 測試、分享開發伺服器、SSH 反向隧道，以及 Cloudflare 原生存取策略。

選用角色（`installTunnelTools`）。在 `chezmoi init --force` 時啟用，或在 `~/.config/chezmoi/chezmoi.toml` 中設定 `installTunnelTools = true`。

## 工具

| 工具 | 用途 | 需要帳號？ | 免費方案 |
|------|------|-----------|----------|
| [ngrok](https://ngrok.com/) | HTTP/TCP/TLS 隧道、流量檢視 UI | 是（有免費方案） | 1 個 agent、1 個 endpoint、隨機子網域 |
| [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) | Cloudflare Tunnel — 生產等級，不需要 port forwarding | 是（Cloudflare 帳號，免費） | 無限命名隧道，透過 Cloudflare DNS 自訂網域 |

## 安裝

由 `networking_tools` Ansible role 在 `tunnel_tools` tag 下管理。

| 平台 | ngrok | cloudflared |
|------|-------|-------------|
| macOS | `brew install ngrok/ngrok/ngrok` | `brew install cloudflared` |
| Linux（Debian/Ubuntu） | apt 官方倉庫 → tgz fallback | GitHub releases `.deb` → 二進位 fallback |
| Linux（CentOS/RHEL） | equinox.io tgz → `~/.local/bin` | GitHub releases `.rpm` |

---

## ngrok

### 初始設定

```bash
# 認證（一次性，token 儲存於 ~/.config/ngrok/ngrok.yml）
ngrok config add-authtoken <YOUR_TOKEN>
```

在 <https://dashboard.ngrok.com/get-started/your-authtoken> 取得 token。

### 暴露本機 HTTP 伺服器

```bash
# 將 localhost:3000 轉發到隨機的 ngrok HTTPS URL
ngrok http 3000

# 固定子網域（付費方案）
ngrok http --domain=myapp.ngrok.app 3000

# 指定 Host header（適用於 vhost）
ngrok http --host-header=rewrite 3000
```

### 暴露 TCP / 原始 port

```bash
# SSH（適合讓 NAT 後的機器可從外部連入）
ngrok tcp 22

# 任何 TCP 服務
ngrok tcp 5432
```

### 流量檢視

隧道啟動時，ngrok 在 `http://127.0.0.1:4040` 提供本機網頁檢視器：

```bash
# 在瀏覽器開啟檢視器
open http://127.0.0.1:4040

# 透過 API 列出活躍隧道
curl -s http://127.0.0.1:4041/api/tunnels | jq
```

### 重播請求

在網頁檢視器中（或透過 `ngrok replay`）可以重播任何捕獲的請求——適合在不重新觸發上游服務的情況下偵錯 webhook handler。

### 設定檔中的命名隧道

`~/.config/ngrok/ngrok.yml`：

```yaml
version: "3"
agent:
  authtoken: <YOUR_TOKEN>
tunnels:
  dev-server:
    proto: http
    addr: 3000
  api:
    proto: http
    addr: 8080
    host_header: rewrite
```

```bash
# 啟動特定命名隧道
ngrok start dev-server

# 啟動設定檔中所有隧道
ngrok start --all
```

---

## cloudflared

### 快速隧道（不需設定）

```bash
# 立即暴露 port 3000 — 產生隨機 trycloudflare.com URL，不需帳號
cloudflared tunnel --url http://localhost:3000
```

這是與他人分享本機伺服器最快的方式。

### 命名隧道（永久，自訂網域）

```bash
# 透過 Cloudflare 認證（開啟瀏覽器）
cloudflared tunnel login

# 建立命名隧道
cloudflared tunnel create my-tunnel

# 建立指向隧道的 DNS 記錄
cloudflared tunnel route dns my-tunnel dev.example.com

# 執行隧道
cloudflared tunnel run my-tunnel
```

設定檔 `~/.cloudflared/config.yml`：

```yaml
tunnel: <TUNNEL_ID>
credentials-file: /Users/you/.cloudflared/<TUNNEL_ID>.json

ingress:
  - hostname: dev.example.com
    service: http://localhost:3000
  - hostname: api.example.com
    service: http://localhost:8080
  - service: http_status:404
```

```bash
cloudflared tunnel run
```

### 透過 Cloudflare Access 的 SSH 存取

Cloudflare Access 讓你無需開放任何 port 即可暴露 SSH——客戶端透過 Cloudflare 的網路連接。

**伺服器端**（要暴露的機器）：

```bash
# 建立隧道並設定 SSH ingress（hostname: ssh.example.com → localhost:22）
cloudflared tunnel run
```

**客戶端**：

```bash
# 加入 ~/.ssh/config
# Host ssh.example.com
#   ProxyCommand cloudflared access ssh --hostname %h
```

```bash
ssh user@ssh.example.com
```

### 作為系統服務執行

```bash
# 安裝為 launchd（macOS）或 systemd（Linux）服務
sudo cloudflared service install

# 檢查狀態
sudo launchctl list | grep cloudflared   # macOS
sudo systemctl status cloudflared        # Linux
```

---

## 比較

| 功能 | ngrok | cloudflared |
|------|-------|-------------|
| 快速分享（不需設定） | `ngrok http 3000` | `cloudflared tunnel --url localhost:3000` |
| 自訂網域（免費） | 付費 | 是（透過 Cloudflare DNS） |
| 流量檢視 UI | 是（`localhost:4040`） | 無內建 |
| 重播請求 | 是 | 否 |
| 生產等級 | 有限 | 是（跑 Cloudflare CDN） |
| TCP 隧道 | 是 | 是（Spectrum，付費） |
| SSH proxy | 是（TCP 隧道） | 是（Cloudflare Access，免費） |
| 需要開放 port | 否 | 否 |
| 自架選項 | ngrok Agent SDK | 是（Cloudflare WARP） |

---

## 常見開發模式

### Webhook 測試

```bash
# 啟動本機 handler
python -m http.server 8080

# 暴露並將 HTTPS URL 填入 webhook 供應商的設定頁面
ngrok http 8080
# 或
cloudflared tunnel --url http://localhost:8080
```

### 與隊友分享本機開發伺服器

```bash
# 使用 cloudflared 一行搞定（對方不需帳號或安裝任何東西）
cloudflared tunnel --url http://localhost:3000
```

### 遠端 SSH 連入 NAT 後的機器

```bash
# 在遠端機器（伺服器）上
ngrok tcp 22
# 記下轉發位址，例如 0.tcp.ngrok.io:12345

# 從你的筆電
ssh -p 12345 user@0.tcp.ngrok.io
```

### 透過隧道使用 VS Code Remote

```bash
# 在遠端機器
code tunnel          # 使用 Microsoft 的隧道（不需要 ngrok/cloudflared）

# 替代方案：暴露 SSH port 並使用 Remote-SSH 擴充套件
ngrok tcp 22
# 在 ~/.ssh/config 加入：  Host ngrok-remote \n  HostName 0.tcp.ngrok.io \n  Port 12345
```

### 自動化中的環境變數

```bash
# 從本機 API 取得 ngrok 公開 URL（適用於腳本）
NGROK_URL=$(curl -s http://127.0.0.1:4041/api/tunnels | jq -r '.tunnels[0].public_url')
echo "Webhook URL: $NGROK_URL"
```
