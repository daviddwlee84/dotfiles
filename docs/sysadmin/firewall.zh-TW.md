# Firewall 與網路曝險面

每個 sysadmin 每週都會問的三個問題：

1. **什麼擋 / 放行 inbound 流量？**（firewall 規則）
2. **哪些 port 被綁了？**（listening socket — 真正的攻擊面）
3. **現在誰連著我？**（established connection）

本頁用 backend-agnostic helper 與單一 `tv firewall` channel 涵蓋這三個。

## Backend

Linux 把這塊切得很碎；本 repo helper 偵測有裝什麼就用什麼。

| Backend | Distro 預設 | 查詢 | 常見混淆 |
|---|---|---|---|
| **nftables** (`nft`) | 現代 Debian / Ubuntu / RHEL 9+ | `nft list ruleset` | 新 API 取代 iptables；`iptables-nft` 是相容 shim |
| **iptables** | 較舊 / 非 systemd Linux | `iptables -S` / `iptables -L -n -v` | 兩種 flavour：legacy 與 `iptables-nft`（底層走 nftables） |
| **ufw** | Ubuntu 桌面 / server 前端 | `ufw status verbose` | 包 iptables / nftables；高階 allow/deny 語法 |
| **firewalld** | RHEL / CentOS / Fedora 前端 | `firewall-cmd --list-all` | Zone-based；`firewall-cmd` 改即時規則 + 持久化 |
| **pf** | macOS、FreeBSD、OpenBSD | `pfctl -s rules` | macOS 有 pf 但預設停用 — 見「macOS 注意事項」 |
| **Application Firewall (ALF)** | 只 macOS | `socketfilterfw --getglobalstate` | Per-app allow/deny；layer-7，**不是** packet filter |

**硬事實**：一台機器可以**同時**有 packet filter (nftables / pf) 和
application 層級控制 (ufw / firewalld / ALF)。衝突時 packet filter
贏。debug「為什麼這個 port 連不到？」一定要查最低層。

## Listening socket ≠ firewall 規則

`fw-rules` 顯示 **kernel 會 drop 哪些封包**。`fw-listening` 顯示
**哪些 process 願意接收**。一個 port 可能 listening **且** 被 firewall
擋 — 從外面 `nmap` 會看到它是 `filtered` 不是 `closed`。兩者都要看。

| 問題 | 對的工具 |
|---|---|
| 「port 22 從網路上連得到嗎？」 | `fw-rules`（防火牆）+ 從外面 nmap |
| 「為什麼 service 抱怨 port 8080 已被佔用？」 | `fw-port 8080`（找 process） |
| 「這台曝險了什麼？」 | `fw-listening`（每個 bound socket + 擁有者 process） |
| 「現在誰連著我？」 | `fw-conn`（active 連線） |

## 本 repo helper

| 函式 | 回答 | sudo？ |
|---|---|---|
| `fw-rules` | 所有偵測到的 backend 的防火牆規則 | 是 |
| `fw-listening` | bound TCP+UDP socket + 擁有者 process | 完整 process 資訊需要 |
| `fw-conn [--all]` | Established TCP 連線（或全狀態） | process 資訊需要 |
| `fw-port <port>` | 誰在用 `<port>`？(LISTEN + ESTABLISHED) | 是 |

`tv firewall` 用 `Ctrl+S` 切 4 個來源：rules → listening → established → defaults/policy。預覽窗解析 port → service 並走 process parent tree。

## 常用查詢

```bash
# 例行檢視：rules + listener + connection 一頁看完
fw-rules | head -40
fw-listening
fw-conn

# 有東西 listen 在 8080 — 是什麼？
fw-port 8080

# 互動瀏覽
tv firewall          # Ctrl+S 切來源、Enter 看完整 context
```

## 偵測 / 強化食譜

### 「網路上實際曝什麼？」

```bash
fw-listening | grep -vE '127\.0\.0\.1|::1'
```

過濾 loopback。剩下就是真實攻擊面。每筆判斷：

- 這 port 該曝嗎？(sshd / web — 是；postgres / redis — 通常否，只走 VPN)
- Firewall 對外擋得住嗎？(`fw-rules` 確認)

### 「有人偷開 port 沒告訴我？」

開了 `installAuditd` 的話，基準規則集會 watch `/etc/ufw`、
`/etc/firewalld`、`/etc/nftables.conf`（要的話自己擴
`/etc/audit/rules.d/00-baseline.rules` — 預設沒含；見 [auditd.md](auditd.md)）。然後：

```bash
audit-file /etc/ufw/
audit-file /etc/nftables.conf
```

沒 auditd 就退到 filesystem mtime：

```bash
ls -la /etc/ufw /etc/nftables.conf /etc/firewalld 2>/dev/null
```

### 「sshd 從錯誤的網路連得到？」

```bash
fw-rules | grep -i 'dport.*22\|port.*22'
```

對照 `sshd_config` `ListenAddress` 與 `Match Address` block。
firewall 與 sshd 必須**都**同意擋；一邊擋不夠。

## macOS 注意事項

- **pf 有裝但預設停用**。`sudo pfctl -e` 啟用；`sudo pfctl -d` 停用。
  多數 macOS user 從來不碰。
- **Application Firewall (系統設定 → 網路 → 防火牆) 是 per-app 不是
  per-port**。只擋 macOS 上跑的程式的 incoming，不管 forwarding 也不管
  outbound。
- **沒有 `ss(8)`**。`fw-listening` / `fw-conn` 退到 `lsof -nP -iTCP
  -sTCP:LISTEN`。慢但可用。
- **Little Snitch / LuLu** 是熱門第三方 outbound firewall；有自己 UI，
  `pfctl` 看不到。

## 另見

- [Session 與登入](sessions.md) — Level 0；防火牆決定誰連得進來**嘗試**登入
- [本 repo 提供的 helper](helpers.md) — 完整對照表
- [Cookbook recipe 5](cookbook.md#5-我懷疑有人從這台跑-nmap--level-2--level-3) — 從這台跑 `nmap`
