# sudo 審計 (Level 1)

這層回答：

- 誰用了 `sudo`？
- 跑了哪條 top-level command？
- 驗證成功還是失敗？
- （啟用 `log_input,log_output` 之後）他們在 root shell 裡實際打了什麼？

## sudo 預設記什麼

每次 `sudo` 都會寫一筆 syslog 事件，至少包含：

- 呼叫者 (`USER=...`)
- 目標 user (`TARGET=...`，通常是 `root`)
- TTY
- 呼叫當下的 CWD
- 傳給 `sudo` 的 command line
- 驗證成功或失敗

落點視 distro：

| Distro | Sink | 查詢 |
|---|---|---|
| Debian / Ubuntu (systemd) | journal + `/var/log/auth.log` | `sudo journalctl _COMM=sudo` 或 `sudo grep sudo /var/log/auth.log` |
| RHEL / CentOS / Rocky / Alma | journal + `/var/log/secure` | `sudo journalctl _COMM=sudo` 或 `sudo grep sudo /var/log/secure` |
| macOS | unified log | `log show --predicate 'process == "sudo"' --last 1d` |

## 「sudo bash」問題

這是核心限制：

```bash
sudo vim /etc/ssh/sshd_config       # <- 記錄：完整 command line
sudo bash                            # <- 記錄："bash"
sudo su -                            # <- 記錄："su -"
sudo -i                              # <- 記錄："-i"
```

一旦使用者拿到 root shell，**他在那個 shell 裡打的所有東西對 sudo log
都不可見**。shell 自己的 history 或許會抓到，但 root 的
`~/.bash_history` 可由 root 編輯，所以也不能當證據。

要補這個缺口，需要：

1. **`sudoreplay`** — 見下。記錄 root session 的鍵盤輸入 + 輸出。
2. **auditd execve 規則** — 見 [auditd 框架](auditd.md)。記錄每個
   `execve()` syscall，包含 root shell 內部的。
3. **禁止 shell 提權** — 收緊 sudoers，只允許白名單命令
   (`Cmnd_Alias`)，禁掉 `bash` / `su` / 編輯器逃脫。最強硬但最徹底。

## sudoreplay（在它能用時）

`sudoreplay` 記錄每個符合 `log_input` / `log_output` sudoers 規則的
sudo 呼叫的**終端 session**（stdin + stdout + 時序）。要全域啟用：

```sudoers
# /etc/sudoers.d/00-logging  (用 `sudo visudo -f`)
Defaults log_input, log_output
Defaults iolog_dir=/var/log/sudo-io
```

啟用後 sudo 會寫到 `/var/log/sudo-io/<user>/<seq>/`。列出 session：

```bash
sudo sudoreplay -l
sudo sudoreplay -l user=alice
```

回放：

```bash
sudo sudoreplay <session-id>
```

注意：

- 會記錄所有東西，**包含在 TTY 打的密碼**（user 跑 `passwd`、`mysql -p`
  等等）。這些東西現在會躺在 `/var/log/sudo-io/` 裡。請限制存取
  (預設 mode `0700` 沒問題)，並評估你真的想在會在鍵盤打祕密的機器上開
  這個嗎。
- root 互動 session 的 disk 用量成長很快。
- 過不了 `sudo bash` → `su otheruser`（第二跳完全繞過 sudo）。要全覆蓋
  仍需要 auditd。

## 常用查詢

```bash
# 今天所有 sudo 事件 (systemd)
sudo journalctl _COMM=sudo --since today

# 過去 7 天某 user 的 sudo 事件
sudo journalctl _COMM=sudo --since '7 days ago' | grep ' alice : '

# 失敗的 sudo 嘗試（驗證失敗或不在 sudoers）
sudo journalctl _COMM=sudo | grep -E 'FAILED|NOT in sudoers'

# 同上，非 systemd Debian
sudo grep sudo /var/log/auth.log /var/log/auth.log.1

# 同上，RHEL
sudo grep sudo /var/log/secure /var/log/secure-*

# 列出可回放 session（需先啟用 log_input）
sudo sudoreplay -l
```

## 本 repo 提供的協助

- **Shell helper**：`audit-sudo [user]` — 包裝 journal / auth.log /
  secure 查詢並自動偵測正確 sink。定義在
  `dot_config/shell/45_audit.sh.tmpl`。
- **Television channel**：`tv sudo-history` (Linux only) — 模糊瀏覽
  sudo 事件。來源輪轉包含 journalctl、純文字 `auth.log` / `secure`
  grep、和有開 `sudoreplay -l` 時的可回放 session。sudoreplay 列預覽
  顯示 session metadata；`Enter` 呼叫 `sudoreplay <id>`。
- 兩個 helper 都會在底層 sink 是 root-only 時用 `sudo -v` 提權。TTY
  prompt 每個 shell 只問一次；之後在 sudo cache 視窗內的呼叫安靜執行。

## 另見

- [Process accounting](process-accounting.md) — 另一條粗粒度 exec log，
  **看得到** `sudo bash` 內部的 command（但無完整 argv）
- [auditd 框架](auditd.md) — 「root shell 跑了什麼？」唯一通用答案
