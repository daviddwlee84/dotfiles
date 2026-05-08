# 本 repo 提供的 helper

本 dotfiles repo 提供的 audit 相關 helper 對照表。完整論述見上一層
[section README](README.md)；本頁是密集查表。

## Shell 函式

定義於
[`dot_config/shell/45_audit.sh.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/shell/45_audit.sh.tmpl)。
POSIX 形式，zsh 與 bash 共用。少數 zsh-only 便利處用 source-time 偵測。

| 函式 | 回答 | 包裝 | 需要 sudo？ | 平台 |
|---|---|---|---|---|
| `audit-sessions [user]` | 誰登入？什麼時候？從哪裡？ | `last -F -i` + `lastlog` (Linux) + `who -a` | 否 (`lastb` 才需要) | macOS + Linux |
| `audit-failed-logins` | 失敗登入嘗試 | `lastb -F -i` | 是 | Linux |
| `audit-sudo [user]` | 誰用了 sudo、top-level command 是什麼？ | `journalctl _COMM=sudo` (systemd) 或 `grep sudo /var/log/auth.log\|/var/log/secure` | 通常是 | Linux (systemd 最佳) |
| `audit-execve <pattern>` | 有人 exec `<pattern>` 嗎？ | `ausearch -sc execve -x <pattern> -i` | 是 | Linux + auditd |
| `audit-file <path>` | 誰動過這個檔？ | `ausearch -f <path> -i` | 是（也需 watch 規則） | Linux + auditd |
| `audit-summary [--start <when>]` | 每日安全摘要 | `aureport --summary -i` + `aureport -au -i` + `aureport -x -i` | 是 | Linux + auditd |
| `audit-rules-show` | 目前載入的 vs 持久化規則 | `auditctl -l` + `cat /etc/audit/rules.d/*.rules` | 是 | Linux + auditd |

所有 helper 接受 `--help` 顯示用法，且在 pipe 到 `head` 等時 exit 0
(避免 SIGPIPE 噪音)。

### Sudo 提權模型

當 helper 需要 root 時 (例如 `/var/log/secure` 是 mode 0640 root:adm)：

1. 測試底層來源是否目前 user 可讀。
2. 可讀 → 不提權直接跑。
3. 不可讀 AND 在互動 TTY AND 不是 root → 呼叫一次 `sudo -v` (單次 TTY
   prompt)，然後 via `sudo` 跑底層命令。
4. 不在 TTY (例如從 cron / pipeline 呼叫) → exit 1 並印明確 stderr 提示。

在 sudo cache 視窗內 (預設 ~5 分鐘，由 sudoers 的
`Defaults timestamp_timeout` 控制)，後續 helper 呼叫安靜執行。這借用
sudo 自己的 credential cache；helper **不**整合本 repo 的
[`scripts/lib/sudo_shared.sh`](../this_repo/sudo-session.md) — 那個 helper
是 run-script 範圍且不部署到 `~/`。

## Television channel

定義於
[`dot_config/television/cable/`](https://github.com/daviddwlee84/dotfiles/tree/main/dot_config/television/cable)。
從任何地方 `tv <name>` 啟動，或用 `Alt+T` tools picker 啟動。

| Channel | 來源 (`Ctrl+S` 切換) | 預覽 (`Ctrl+F` 切換) | Enter | 平台 |
|---|---|---|---|---|
| `tv sessions` | 1) `last -F -i`  2) `lastlog` (Linux)  3) `journalctl _COMM=sshd -n 2000` (systemd)  4) `who -a` | 該 user 細節：`id <u>`、`lastlog -u <u>`、近期 sshd event | 在 `lnav` 鑽入 `journalctl _COMM=sshd \| grep <user>` | macOS + Linux |
| `tv sudo-history` | 1) `journalctl _COMM=sudo -n 2000`  2) `grep -E 'sudo(\\\|:)' /var/log/auth.log /var/log/secure`  3) `sudoreplay -l` (有設定時) | Event metadata；sudoreplay 列：session info | sudoreplay 列 → `sudoreplay <id>`；其他 → lnav 開 event | Linux only |
| `tv audit-events` | 1) `aureport --summary -i`  2) `ausearch -k <baseline-key> --interpret -ts recent` for identity / privileged / sudoers / sshd_config  3) `aureport -au -i` 和 `aureport -x -i` | 選中列的 `ausearch -i -a <eventid>` | `lnav` 開完整 event；`Alt+E` 用 `$EDITOR` 開 `/etc/audit/rules.d/` | Linux + auditd |

與本 repo 其他 channel 共用的 binding：

- `Ctrl+S` — 切換來源
- `Ctrl+F` — 切換預覽
- `Ctrl+Y` — 複製目前列到剪貼簿（OSC 52 over SSH）
- `Alt+T` — 用 `tspin` 即時 tail-follow 底層 log
- `Alt+E` — 在 `$EDITOR` 開相關 config

## 跨檔維護

依本 repo 的
[AGENTS.md「Custom aliases & shell functions」規則](https://github.com/daviddwlee84/dotfiles/blob/main/AGENTS.md)，
上述每個函式在 [`docs/shells/aliases.md`](../shells/aliases.md) 也有對應
列。新增或改名 `audit-*` helper 時請同步更新本頁**和**那張表。

## 本 repo 刻意**不**提供

- **無 audit helper 的 tmux popup menu entry。** 頂層 menu 有 ~14 列上限
  (見 [tmux 不變式](../this_repo/architecture.md))；audit channel 可從
  既有的 `Alt+T` tools picker 與直接 `tv <name>` 呼叫到。要專屬 menu，
  自然位置是新 submenu `~/.config/tmux/menu-audit.sh` 而非頂層 menu。
- **不裝 `sudoreplay`、不改 sudoers。** Sudo I/O 捕捉是政策決定（會存
  keystroke 含 TTY 打的密碼）。在 [sudo-audit.md](sudo-audit.md) 文件
  化但不自動設定。
- **無遠端 log shipping 設定** (rsyslog → SIEM、audit-remote、vector
  pipeline)。dotfiles repo 範圍外；[auditd.md](auditd.md) 的「注意事項」
  解釋原因。
- **無 EDR 安裝** (Falco、Tetragon、Wazuh agent)。同理。
- **無 `acct` / `psacct` 自動化。** 手動安裝 recipe 見
  [process-accounting.md](process-accounting.md)；它能回答的大多是
  auditd 更好回答的子集。
