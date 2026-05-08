# Atuin vs audit

[Atuin](../tools/atuin.md) 是一個很棒的個人 shell history 工具，**不是**
server audit log。本頁存在的目的就是把這個區別講清楚，因為「我可以用
Atuin 看 server 上 user 做了什麼嗎？」這問題經常被問到。

## 為什麼 Atuin 不是 audit log

Atuin 是 **user-space 便利資料**。每個 shell user 擁有自己的 Atuin DB
(`~/.local/share/atuin/history.db`) 和 config
(`~/.config/atuin/config.toml`)。他們可以：

- 完全停用 history capture (`AUTO_SYNC=false`、`update_check = false`、
  把 shell hook 註解掉)。
- 過濾不要的命令 (`history_filter` 和 `cwd_filter`，本 repo 自己的
  [`atuin/config.toml`](../tools/atuin.md) 就排除了 `~/.ssh/` 等敏感路徑)。
- 刪除 entry (`atuin search --delete`)。
- 直接用 `sqlite3` 編輯 SQLite DB。
- 一開始就不裝 Atuin — bash / zsh 內建 history 沒它也能用。

如果有開 sync，Atuin 把 **end-to-end 加密** 的 history 上傳到 sync
server。Server operator 應該無法檢視 user 的命令歷史，因為加密金鑰不離
開使用者機器。這是隱私功能，但也代表 sync server 同樣不能當審計來源。

機器上的特權管理員可以讀其他 user 的 shell history 檔和 Atuin DB —
但那只給你 user **選擇要紀錄**的東西。它不是不可篡改的證據。

## 傳統 shell history 更不可靠

如果 Atuin 都不可信，純 `~/.bash_history` / `~/.zsh_history` 更糟。
User 可以：

- 改 `HISTFILE` (`HISTFILE=/dev/null`)。
- 停用持久化 (`set +o history`、`unset HISTFILE`)。
- 過濾 (`HISTIGNORE='*secret*'`、`HISTCONTROL=ignorespace`)。
- 開頭加空白跳過儲存 (配 `ignorespace`)。
- `history -d <n>` 刪特定 entry。
- `history -c && exit` 在寫檔前清掉記憶體。
- 兩個 session 之間用 `vim` 編輯檔案。

History 檔還可能**意外不完整**：多 session race、shell 結束時延遲
flush、disk-full 截斷、NFS 損壞。這些不是惡意 — 但代表「命令不在
history 檔裡」並不證明「命令沒被跑過」。

本 repo 的 [`docs/shells/history.md`](../shells/history.md) 文件記錄了
本 dotfiles repo 特定的 bash/zsh/atuin history 分層；要**了解** history
stack 的話那頁是起點，但要**審計** history 不是。

## 該用什麼替代

| 問題 | 正確工具 | 詳見 |
|---|---|---|
| 「誰登入了？」 | `last`、journal、auth.log/secure | [Session 與登入](sessions.md) |
| 「誰用了 sudo？」 | `journalctl _COMM=sudo`、sudoreplay | [sudo 審計](sudo-audit.md) |
| 「有人跑過 `<binary>` 嗎？」 | `lastcomm`、auditd execve 規則 | [Process accounting](process-accounting.md) / [auditd](auditd.md) |
| 「`<file>` 被改過嗎？」 | auditd watch 規則 | [auditd](auditd.md) |
| 「root shell 跑了什麼？」 | auditd execve 規則、sudoreplay | [auditd](auditd.md) / [sudo 審計](sudo-audit.md) |
| 「合規 / 鑑識」 | auditd + 遠端 log shipping + EDR | (本 repo 不涵蓋) |
| 「回想我自己跑過什麼」 | atuin | [tools/atuin.md](../tools/atuin.md) |

## 完整對照表

| 來源 | 能回答 | 審計可靠度 | 備註 |
|---|---|---|---|
| `~/.bash_history`、`~/.zsh_history` | 互動 shell 打過的部分命令 | **低** | User 可控、不完整、容易停用或編輯 |
| Atuin 本機 DB | User 的 Atuin 捕捉到的 shell history 含 metadata | 審計**低**；個人回想中等 | 比純 history 搜尋/上下文更好，但仍是 user-space 且不防篡改 |
| Atuin sync server | 加密 sync blob | **無用** for 命令檢視 | Server operator 不該看到明文 history (E2E 加密) |
| `last` / `lastlog` / `who` | 登入 session 邊界 | **高** for session | 告訴你 session，不告訴你命令 |
| sudo log (journal / auth.log / secure) | 誰跑了 sudo、top-level command 是什麼 | **中** | 抓不到 root shell 內部的命令 |
| `sudoreplay` (有設定時) | 完整 TTY 錄製的 sudo session | **高** for 打了什麼/看到什麼 | 吃 disk；會錄到 TTY 打的密碼 |
| `acct` / `psacct` / `lastcomm` | Process 執行摘要 | **中** | 粗粒度、無完整 argv、要事先啟用 |
| `auditd` | Policy-driven kernel audit event | 預設正確時**高** | Linux audit/合規最標準的答案 |
| EDR / eBPF / SIEM agent (Falco、Tetragon、Sysdig、Wazuh、商業) | 跨 fleet 的集中 security telemetry | **高**，視產品/設定 | 適合 fleet 規模；本 repo 不涵蓋 |
| 異地 log forwarder (audit-remote、syslog-ng → write-once 儲存) | 不可篡改 chain of custody | 儲存真為 write-once 時**高** | 鑑識等級證據必備 |

## TL;DR

Atuin 是讓**你**更快找到**你自己**的命令。它不是監控工具、不是 audit
log、不是證據來源。需要那些就在事件**前**配置好 auditd（或 EDR），把
log 異地唯讀備份。

完整 audit 來源導覽從 [section README](README.md) 開始。
