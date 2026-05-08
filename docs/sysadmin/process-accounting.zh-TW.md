# Process accounting (Level 2)

這層回答：

- 這台機器上有人 exec 過 `<binary>` 嗎？
- 大概什麼時候、哪個 user、哪個 tty？
- 每個 process 燒了多少 CPU / IO（用於計費型摘要）？

它**夾在** sudo log（只看 top-level 呼叫）和 auditd（什麼都看，含完整
context）之間。Process accounting 比較舊、比較簡單、比較輕 — 但有已知
缺口，鑑識用途上 auditd 才是正解。

## 工具

| Command | 來源 | 顯示 |
|---|---|---|
| `lastcomm` | `/var/log/account/pacct` (binary) | 每 process 一列：command、flags、user、tty、runtime |
| `sa` | 同上 | 按 command 或 user 聚合摘要 |
| `accton on \| off \| <file>` | 開關 | 啟動/停止 accounting；切換輸出檔 |
| `dump-acct <file>` | (psacct only) | 把 binary 檔 dump 成文字 |

## 安裝 + 啟用

```bash
# Debian / Ubuntu / Raspberry Pi OS
sudo apt-get install -y acct
sudo systemctl enable --now acct.service

# RHEL / CentOS / Rocky / Alma
sudo dnf install -y psacct
sudo systemctl enable --now psacct.service

# macOS (BSD-style)
sudo accton /var/account/acct
# 用 sudo lastcomm 讀
```

啟用後 kernel 對每個結束的 process 寫一筆到 `/var/log/account/pacct`
(Linux) 或 `/var/account/acct` (BSD/macOS)。

## 常用查詢

```bash
# 今天所有 process
sudo lastcomm | head -50

# 有人跑過 nmap 嗎？
sudo lastcomm nmap

# alice 跑了什麼？
sudo lastcomm --user alice | head -50

# tty pts/3 上跑了什麼？
sudo lastcomm --tty pts/3 | head -50

# 聚合：哪些 command 燒了 CPU？
sudo sa | head -20

# 每 user 摘要
sudo sa -m | head -20

# 重置計數 / 切換檔案
sudo accton off
sudo mv /var/log/account/pacct /var/log/account/pacct.$(date +%F)
sudo accton on
```

## 已知限制

- **無完整 argv**：`lastcomm` 顯示 *command name*（argv[0] 的 basename），
  不是完整參數向量。`lastcomm wget` 告訴你有人跑 wget，但不告訴你哪個
  URL。鑑識價值有限。
- **截斷**：command name 會截斷（Linux `comm` 欄位通常 16 字元）。
- **短命 process 灌爆 log**：忙碌的 build 或 shell-loop 機器每分鐘產生
  數千筆記錄。請規劃輪轉 (`logrotate`) 否則 `/var/log` 會爆。
- **結束時才記錄**：`lastcomm` 列的是已**終止**的 process。長跑 daemon
  不會出現直到它死掉。
- **靜態連結 / 改名 binary 即可規避**：有心的 user 把 `bash` 複製到
  `/tmp/innocent` 跑那個。auditd 的 execve logging 記 inode，緩解
  此問題。
- **無檔案存取追蹤**：process accounting 告訴你誰跑 `cat`，不告訴你
  cat 了哪個檔。

## 何時偏好 process accounting 而非 auditd

- auditd 不可行的機器上做輕量內省（資源受限的嵌入式、無 `audit` 套件
  的 distro）。
- 「誰跑了 `<貴 command>` 燒 CPU？」這類計費型問題。`sa -u` 是專門設計
  的。
- 不在意 argv 的「這個 binary 到底有沒有在這台機器跑過？」快速 sanity
  檢查。

其他情況直接跳 [auditd](auditd.md)。

## 本 repo 提供的協助

本 repo **不**提供 process accounting 專用 helper 或 TV channel —
`lastcomm <name>` 本身就夠短，且上述缺口讓它不適合當主要工具。
`dot_config/shell/45_audit.sh.tmpl` 的 `audit-execve` helper 包裝 auditd
等價功能，啟用 auditd 後嚴格更有用。

要在某台機器上跑 process accounting，請用上面的 distro 命令手動安裝。
可選的 `auditd` ansible role
（[docs/playbooks/auditd.md](../playbooks/auditd.md)）**不**安裝
`acct`/`psacct` — 它們回答的問題不同。
