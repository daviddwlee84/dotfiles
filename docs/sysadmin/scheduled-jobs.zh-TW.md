# 排程任務 (cron / systemd timer / at / launchd)

任何按時間執行的東西都有兩個結果：

1. **容量** — 它在排定時間競爭 CPU/IO。
2. **持久化** — 這是攻擊者**最常**藏「每 10 分鐘跑我的 reverse shell」
   payload 的地方，因為跨重開機都活著、不用碰 `/etc/sudoers` 也不用裝
   service。

本頁涵蓋盤點：誰排了什麼、何時跑、跑什麼。

## 排程機制（多來源現實）

| 機制 | 位置 | 範圍 | Linux | macOS |
|---|---|---|---|---|
| **User crontab** | `crontab -l -u <user>` | Per-user | ✓ | ✓（已不推薦；改用 launchd） |
| **System crontab** | `/etc/crontab` | Root 擁有，集中 | ✓ | ✓（少見） |
| **Drop-in cron** | `/etc/cron.d/*` | 套件安裝的 job | ✓ | 罕見 |
| **Periodic 目錄** | `/etc/cron.{hourly,daily,weekly,monthly}/` | cron 按固定週期跑的 script | ✓ | 類似 via `/etc/periodic/` |
| **anacron** | `/etc/anacrontab` | 補跑錯過的（筆電） | ✓ | — |
| **systemd timer** | `*.timer` unit、`systemctl list-timers` | System 或 user；systemd 主機推薦取代 cron | ✓ | — |
| **at job** | `atq`、`at -c <jobid>` | 一次性排程命令 | ✓ | ✓ |
| **launchd** | `/Library/Launch{Daemons,Agents}/`、`~/Library/LaunchAgents/` | macOS 原生排程 + service manager | — | ✓ |

要做 persistence-aware 掃描必須**全部**碰過。只看 `crontab -l` 在現代
Linux 機器漏 ~80% 攻擊面。

## 本 repo helper

| 函式 | 回答 |
|---|---|
| `cron-list` | 全盤點：所有 user crontab + system cron + systemd timer + launchd plist + at job |
| `cron-list --user U` | 只看 U 的 crontab |
| `cron-list --system` | `/etc/crontab` + `/etc/cron.d/` + `cron.{hourly,...}/` |
| `cron-list --timers` | systemd timer (system + user 範圍) |

`tv scheduled-jobs` 用 `Ctrl+S` 切 5 個來源：user crontab → system cron
→ systemd timer → at job → anacron (Linux) / launchd plist (macOS)。
預覽窗解碼排程、顯示觸發的 unit，systemd timer 還顯示 timer 與被啟動的
service 兩個的 `systemctl status`。

Channel 名是 `scheduled-jobs` 而非 `cron`，避免誤導 — `tv cron` 會讓人
以為只看 crontab 內容。

## 常用查詢

```bash
# 完整盤點
cron-list

# 只看某 user 排了什麼
cron-list --user alice

# 只看 systemd timer（現代主機最相關）
cron-list --timers

# 互動瀏覽（可鑽入 unit）
tv scheduled-jobs
```

## Persistence 偵測食譜

### 「過去一週有什麼新東西出現？」

開了 `installAuditd` 的話，用自訂規則 watch 排程目錄：

```bash
# 加到 /etc/audit/rules.d/50-local.rules：
-w /etc/cron.d/    -p wa -k cron
-w /etc/crontab    -p wa -k cron
-w /etc/cron.daily/ -p wa -k cron
-w /etc/cron.hourly/ -p wa -k cron
-w /var/spool/cron/ -p wa -k cron
-w /etc/systemd/system/ -p wa -k systemd-units
sudo augenrules --load

# 然後：
audit-file /etc/cron.d/
audit-file /etc/systemd/system/
```

沒 auditd 就退到 mtime：

```bash
find /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/systemd/system /var/spool/cron \
  -newer /tmp/last-checked 2>/dev/null
touch /tmp/last-checked   # 給下次用
```

### 「有不該存在的 user crontab 嗎？」

```bash
cron-list | grep -A1 '^--- '   # user header + 第一條命令
```

對照 `user-list --login`。非 login user 有 crontab 就可疑，除非明確是
service（例如 `backup` user 跑每日 job）。

### 「凌晨 3 點最會卡的 job 是什麼？」

```bash
# systemd timer 顯示下次執行
systemctl list-timers --all | sort -k1,3
# 再看它啟動什麼 unit
systemctl cat <unit>.service
```

### 「有東西在連網嗎？」

把排程盤點 + `fw-conn` 在對的時間合用：

```bash
# 排程盤點告訴你何時
cron-list

# 那時看誰連去哪
fw-conn --all
```

## 注意事項

- **`crontab -l -u <other-user>` 需要 root**。Helper 退到 `sudo -n`
  一次，被拒就跳過。
- **`/var/spool/cron/crontabs/` 是底層檔位置**（多數 distro）。
  `crontab -l` 讀它；手動編輯該檔會繞過 cron 的 safety check（別這樣做）。
- **systemd timer drift**：`OnBootSec=` / `OnUnitActiveSec=` unit 可以
  漂移數分鐘。`OnCalendar=` 是 wall-clock 錨定的。
- **launchd `KeepAlive` plist 不是排程** — 是 respawn policy，不是 timer。
  在我們 channel 出現是因為它們在同樣的 plist 目錄；它們由條件觸發
  （檔案變動、網路狀態）而非時間。
- **`atq` 顯示 job ID 不顯示命令**。用 `at -c <jobid>`（或 channel 的
  `Enter`）看實際 script。

## 另見

- [Session 與登入](sessions.md) — 有時「排程」job 只是攻擊者透過長壽
  SSH session 重新登入
- [Firewall](firewall.md) — 排程 + active connection 合起來能揭發「這個
  job 凌晨 3 點 call home」
- [auditd](auditd.md) — 擴充基準規則集 watch cron / systemd 目錄是在
  scope 內；role 預設不裝這 watch 避免噪音
- [本 repo 提供的 helper](helpers.md)
