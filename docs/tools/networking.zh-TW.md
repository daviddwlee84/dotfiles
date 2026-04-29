# 網路 CLI 工具

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

選用角色 (role)（`installNetworkingTools`）。透過 `chezmoi init --force` 並啟用提示來安裝。

## 工具列表

| 工具 | 二進位 | 用途 | 執行時需要 sudo？ |
|------|--------|---------|-------------------|
| [nmap](https://nmap.org/) | `nmap` | 連接埠 (port) 掃描、主機 (host) 探索、OS 偵測、服務 (service) 列舉 | 部分功能（OS 偵測、SYN 掃描）需要 |
| [arp-scan](https://github.com/royhills/arp-scan) | `arp-scan` | 快速第二層 (Layer 2) 主機探索，附 OUI 廠商查詢 | 是（raw socket） |
| [mtr](https://www.bitwizard.nl/mtr/) | `mtr` | 即時結合 ping ＋ traceroute | 部分模式需要 |
| [iperf3](https://iperf.fr/) | `iperf3` | 兩台主機之間的網路頻寬／吞吐量測試 | 否 |
| [doggo](https://github.com/mr-karan/doggo) | `doggo` | 現代 DNS 查詢工具（取代 dig／nslookup），支援 DoH/DoT/DoQ | 否 |
| [HTTPie](https://httpie.io/) | `http` / `https` | 現代 HTTP 客戶端 (client)，比 curl 更適合 API 測試 | 否 |
| [gping](https://github.com/orf/gping) | `gping` | 帶即時圖表的 ping | 否 |
| [trippy](https://github.com/fujiapple852/trippy) | `trip` | 現代 TUI traceroute，視覺化豐富 | 是（raw socket） |
| [bandwhich](https://github.com/imsnif/bandwhich) | `bandwhich` | 終端機 (terminal) 上每個行程 (process)／連線的頻寬使用率 | 是（封包擷取 (packet capture)） |
| [Ookla Speedtest](https://www.speedtest.net/apps/cli) | `speedtest` | 官方 Ookla 網路速度測試 | 否 |
| [RustScan](https://github.com/RustScan/RustScan) | `rustscan` | 快速連接埠掃描器，把結果餵進 nmap | 否 |

## Shell 別名 (alias)

定義於 `~/.config/zsh/tools/50_networking.zsh`：

| Alias | 命令 | 說明 |
|-------|---------|-------------|
| `ports` | `lsof -i -P -n \| grep LISTEN` | 顯示所有監聽 (listening) 中的連接埠 |
| `myip` | `curl -s https://ifconfig.me` | 顯示對外 IP 位址 |
| `localip` | 平台感知 | 顯示本機 LAN IP 位址 |
| `arpscan` | `sudo arp-scan -l` | 掃描本地網路 (Layer 2) |
| `pingsweep` | `nmap -sn <subnet>/24` | 對本地 /24 子網路做 ping sweep（函式） |
| `dns` | `doggo` | DNS 查詢捷徑 |
| `bw-net` | `sudo bandwhich` | 頻寬監測（避免與 `bw` ＝ Bitwarden 衝突） |
| `portscan` | `rustscan` | 快速 port 掃描捷徑 |

## 常見用法

### 我的網路上有什麼？

```bash
# Layer 2 ARP 掃描（最可靠，會顯示 MAC + 廠商）
arpscan

# Ping sweep (Layer 3)
pingsweep

# 完整掃描含 OS 偵測
sudo nmap -sV -O 192.168.1.0/24

# 互動式選擇器，包含開啟的 port、MAC／廠商、主機名稱、延遲
# （自動偵測 sudo；無 sudo 時退回到不需 sudo 的探索方式）
lanscan            # 跑一次完整掃描存到 ~/.cache/tv/
tv lan-devices     # 模糊搜尋裝置；參見 docs/tools/tv.md
```

### Port 掃描

```bash
# 快速 port 掃描（rustscan 比單跑 nmap 快約 10 倍）
portscan -a 192.168.1.100

# 用 nmap 指定特定 port
nmap -p 22,80,443,8080 192.168.1.100

# 服務版本偵測
nmap -sV -p 22,80 192.168.1.100
```

### DNS 查詢

```bash
# 基本查詢
dns example.com

# 指定記錄類型
dns example.com MX
dns example.com AAAA

# 使用 DNS-over-HTTPS
dns example.com --class IN --type A @https://cloudflare-dns.com/dns-query

# 使用 DNS-over-TLS
dns example.com @tls://1.1.1.1
```

### 診斷

```bash
# 即時 traceroute
mtr google.com

# 圖形化 ping（同時比較多個 host）
gping google.com cloudflare.com 1.1.1.1

# 視覺化豐富的 TUI traceroute
trip google.com

# 看看本機正在監聽什麼
ports
```

### 頻寬測試

```bash
# 對外網路速度測試
speedtest

# LAN 吞吐量（兩端都要 iperf3）
# 在伺服器端：iperf3 -s
# 在用戶端：  iperf3 -c <server-ip>

# 監看每個行程的頻寬使用量
bw-net
```

### HTTP 測試

```bash
# GET 請求 (httpie)
http httpbin.org/get

# POST 帶 JSON
http POST httpbin.org/post name=test value=123

# 帶標頭 (header)
http GET api.example.com Authorization:"Bearer token123"
```

## 平台備註

- **macOS**：所有工具透過 Homebrew 安裝。`tcpdump` 為系統內建。
- **Linux（有 sudo）**：`nmap`、`arp-scan`、`mtr`、`iperf3`、`httpie`、`tcpdump` 透過 apt 安裝。其餘從 GitHub releases 下載到 `~/.local/bin`。
- **Linux（noRoot）**：apt 工具略過；`trippy` 系統層級安裝略過。GitHub 二進位工具仍可使用，但 `arp-scan`、`bandwhich`、`trippy` 在執行時仍需 sudo 才能存取 raw socket。
