# Session 與登入 (Level 0)

這層回答：

- 誰登入了？
- 從哪裡（IP、tty）？
- 什麼時候登入 / 登出？
- 用 SSH 還是本地 tty？
- 有沒有用 `su` 或 `sudo -i` 切到別的身份？

## 資料源

| 來源 | 位置 | 內容 | 平台 |
|---|---|---|---|
| `last` | 讀 `/var/log/wtmp`（binary） | 登入/登出對、時長、來源 IP、tty | macOS + Linux |
| `lastlog` | 讀 `/var/log/lastlog` | 每個 UID 上次登入 | Linux |
| `who -a` | 讀 `/var/run/utmp` | 目前在線 session | macOS + Linux |
| `journalctl _COMM=sshd` | systemd journal | 每條 sshd 事件（驗證、accept/fail、key fingerprint、channel 開關） | Linux + systemd |
| `/var/log/auth.log` | 純文字，logrotate 輪轉 | sshd、sudo、login、cron 驗證 | Debian / Ubuntu / Raspberry Pi OS |
| `/var/log/secure` | 純文字，logrotate 輪轉 | 範圍同 auth.log | RHEL / CentOS / Rocky / Alma / Fedora |
| `/var/log/btmp` | Binary，用 `lastb` 讀 | **失敗**的登入嘗試 | Linux |

**發行版差異**：Debian 系寫 `/var/log/auth.log`；RHEL 系寫
`/var/log/secure`。systemd 機器上兩者通常都會 mirror 進 journal — 查
journal 在兩邊都可行，查檔案則需要區分 distro。

systemd journal 是結構化的：每個 entry 帶 metadata（`_PID`、`_UID`、
`_COMM`、`_SYSTEMD_UNIT` 等），journal 檔案受保護不容一般使用者篡改
（Red Hat 文件）。用 `_FIELD=value` 過濾語法可精準查詢。

## 常用查詢

```bash
# 本週所有登入（最新先）
last -F -i | head -50

# 失敗登入嘗試 (Linux)
sudo lastb -F -i | head -50

# 目前在線使用者
who -a

# 每個有登入過的帳號的上次登入 (Linux)
lastlog | awk 'NR==1 || $2 != "**Never"'

# 某 user 過去 24h 的所有 sshd 事件 (systemd)
sudo journalctl _COMM=sshd --since '24h ago' | grep " <user> "

# Auth log tail (Debian/Ubuntu)
sudo tail -F /var/log/auth.log

# Auth log tail (RHEL/CentOS)
sudo tail -F /var/log/secure
```

## 注意事項

- `last` 報告的是 **session 邊界**，不是 command。6 小時 session 可能是
  在打字，也可能是閒置的 SSH 連線。
- `wtmp` 會輪轉（logrotate 把它變成 `wtmp.1`、`wtmp.2.gz`…）。要查更早
  的：`last -f /var/log/wtmp.1`。
- 有 root 的人可以編輯/清除 `/var/log/wtmp` 和 journal。journal 的設計讓
  這件事**比較難**（cryptographic seal — `journalctl --setup-keys` /
  `--verify`）但若沒做異地 log shipping 仍非不可能。
- `who` 反映 `utmp` 的目前狀態；session 異常結束沒寫 logout record 時可能
  不一致。

## 本 repo 提供的協助

- **Shell helper**：`audit-sessions [user]` — 包裝 `last -F -i` +
  `lastlog` + 目前在線 session。定義在 `dot_config/shell/45_audit.sh.tmpl`
  (POSIX，zsh 與 bash 共用)。
- **Television channel**：`tv sessions` — 模糊瀏覽 `last`、`lastlog`、
  `journalctl _COMM=sshd`、`who -a` 的列。預覽窗顯示該 user 的細節。用
  `Ctrl+S` 切換來源。
- 完整對照表見 [本 repo 提供的 helper](helpers.md)。

## 另見

- [sudo 審計](sudo-audit.md) — user 登入**之後**做了什麼
- [auditd 框架](auditd.md) — `aureport -au` 的 kernel-level 驗證摘要
- [shells/history.md](../shells/history.md) — 為什麼 `~/.bash_history` /
  `~/.zsh_history` 不該與登入紀錄混淆
