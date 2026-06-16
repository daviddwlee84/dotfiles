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

### User inventory helper

底層資料源 macOS (`dscl`) 與 Linux (`getent`) 不同；helper 透過 template
依 host 帶正確的命令。

| 函式 | 回答 | 包裝 | 需要 sudo？ | 平台 |
|---|---|---|---|---|
| `user-list [--login]` | 這台有哪些 user 帳號？ | `getent passwd` (Linux) / `dscl . -list /Users` (macOS) | 否 | macOS + Linux |
| `user-info <user>` | 單一 user 的完整身份 dump (id、groups、passwd、last login、sudo 事件、SSH key 數) | 組合 | 部分需 sudo | macOS + Linux |
| `user-groups <user>` | 這 user 在哪些 group？ | `id -Gn <user>` 排序 | 否 | macOS + Linux |
| `group-members <group>` | 這個 group 有誰？ | `getent group` (Linux) / `dscl . -read /Groups/<g>` (macOS) | 否 | macOS + Linux |
| `user-sudoers` | 誰能 sudo？(sudo/wheel/admin 成員 + `/etc/sudoers.d/`) | 組合 | 是（讀 `/etc/sudoers`） | macOS + Linux |
| `user-ssh-keys [user]` | 誰有 authorized_keys，含 fingerprint + comment？ | 掃 `~/.ssh/authorized_keys`；`ssh-keygen -lf -` 算 fingerprint | 其他 user 的檔需 sudo | macOS + Linux |
| `user-recent-changes [--days N]` | 近期 passwd/shadow/sudoers 修改 (auditd) | `ausearch -k identity` + `-k sudoers` | 是 | Linux + auditd |

### Firewall + 排程任務 helper

| 函式 | 回答 | 包裝 | 需要 sudo？ | 平台 |
|---|---|---|---|---|
| `fw-rules` | 所有 backend 的防火牆規則 | `nft list ruleset` / `iptables -S` / `ufw status` / `firewall-cmd --list-all` (Linux); `pfctl -s rules` + ALF (macOS) | 是 | macOS + Linux |
| `fw-listening` | bound TCP+UDP socket + 擁有者 process | `ss -tlnp` / `ss -ulnp` (Linux); `lsof -nP -iTCP -sTCP:LISTEN` 退路 | 完整 process 資訊需要 | macOS + Linux |
| `fw-conn [--all]` | Established TCP 連線 (--all 含所有狀態) | `ss -tnp state established` | process 資訊需要 | macOS + Linux |
| `fw-port <port>` | 誰在用 `<port>`？(LISTEN + ESTABLISHED + `/etc/services`) | `ss` / `lsof` filter port | 是 | macOS + Linux |
| `cron-list [--user U \| --system \| --timers]` | 所有排程任務：user crontab + system cron + systemd timer + at + launchd | 組合 | 有時需（其他 user 的 crontab） | macOS + Linux |

### 即時監控 + 早晨摘要

| 函式 | 回答 | sudo？ |
|---|---|---|
| `audit-watch [--auth\|--audit\|--all] [--no-color]` | 即時染色串流 sshd / sudo / su / auditd 事件，RED/YELLOW/CYAN 風險高亮 | 是（TTY 互動，一次 prompt） |
| `health-check [--quick\|--full] [--since W] [--no-color]` | 統一早晨摘要：host / disk / failed services / OOM / failed login / sudo / listener / audit summary，最後一行 verdict | 是（每段獨立失敗 graceful） |

### Disk + filesystem

| 函式 | 回答 | sudo？ |
|---|---|---|
| `disk-usage` | 每 mount 用量，色階（>=70% 黃、>=90% 紅） | 否 |
| `disk-largest [path] [--top N]` | `<path>` 下第一層最大子項（預設 `$HOME`）；root-owned 路徑自動提權 | 有時 |
| `disk-inodes` | 每 mount inode 用量（抓「磁碟有空間但建不了檔」） | 否 |
| `mount-info` | active mount + options + `/etc/fstab` | 否 |
| `disk-watch [mount]` | 即時 `watch -n 1` of `df -h <mount>` + 最大檔 | 否 |

### 硬體 {#hardware}

實體機硬體健康（僅 Linux；由 `homelab_tools` role 安裝，chezmoi prompt
`installHomelabTools`）。完整指南：[hardware.md](hardware.md)。

| 函式 | 回答什麼 | 包裝 | Sudo？ |
|---|---|---|---|
| `hw-status [--no-color]` | 一頁總覽：風扇 + 溫度 + RAID + 每碟 SMART + SEL 錯誤 | 複合（ipmitool / storcli / smartctl） | 是（逐段降級） |
| `hw-fans` | 機箱風扇 RPM（BMC 平面）；`ns`/No-Reading = 空槽 | `ipmitool sdr type fan` | 是 |
| `hw-temps` | 溫度：BMC + 主機板晶片 | `ipmitool sdr type temperature` + `sensors` | 是（BMC 部分） |
| `hw-sensors` | 完整 lm-sensors dump | `sensors` | 否 |
| `hw-raid` | MegaRAID 狀態、VD/PD、ROC 溫度、enclosure 感測器 | `storcli show` + `/cALL` + `/cALL/eALL show all` | 是 |
| `hw-smart [dev]` | 每碟 SMART 健康（無參數）或單碟完整 `-a` 報告；NVMe 走 `nvme smart-log` | `smartctl -H` / `smartctl -a` | 是 |
| `hw-disks` | `hw-smart` 無參數巡檢的同義詞 | 每碟 `smartctl -H` | 是 |
| `hw-sel [--all]` | BMC System Event Log（PSU / ECC / 過熱故障） | `ipmitool sel info` + `sel elist` | 是 |

### 套件安裝歷史

| 函式 | 回答 | sudo？ |
|---|---|---|
| `pkg-recent [--days N]` | 近期 install/upgrade/remove 套件（apt / dnf / pacman / brew / npm-g / pip --user） | dnf 需要；其他讀 user-readable log |

## Sudo 與 shell function 的踩雷

這些是 shell **function** 不是執行檔。`sudo audit-foo` 會 `command not
found`，因為 sudo 開新 process 不會繼承你 shell 的 function。

你**自己**呼叫時 helper 透明處理：

1. 先試 `sudo -n`（cache 還在或 NOPASSWD 時免費）。
2. 失敗且在 TTY，呼叫 `sudo -v` 一次，然後 `sudo <底層命令>`。
3. 不在 TTY (cron、pipe) 時印：
   `audit: needs root. Run \`sudo -v\` once in this shell first, then
   re-run this helper.`

所以任何彆扭 shell setup 下的可用 pattern：

```bash
sudo -v                # 每個 terminal 預熱 cache 一次
audit-failed-logins    # 過
audit-summary          # 過（cache 還在）
```

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

**快速 launcher**：`tv sysadmin` 開一個 meta-channel，列下面的 sysadmin
channel — triage 時不用滑過 30 個 productivity channel。也包含同工作流
相關的鄰近 channel：**`services`**（完整 systemd/launchd 瀏覽器含 log
預覽 + lifecycle 動作；補完只看失敗的 `services-health`）與 **`logs`**
（通用 log 瀏覽器含 tailspin/lnav）。Enter 開該 channel；預覽顯示底層
TOML config。

| Channel | 來源 (`Ctrl+S` 切換) | 預覽 (`Ctrl+F` 切換) | Enter | 平台 |
|---|---|---|---|---|
| `tv sessions` | 1) `last -F -i`  2) `lastlog` (Linux)  3) `journalctl _COMM=sshd -n 2000` (systemd)  4) `who -a` | 該 user 細節：`id <u>`、`lastlog -u <u>`、近期 sshd event | 在 `lnav` 鑽入 `journalctl _COMM=sshd \| grep <user>` | macOS + Linux |
| `tv sudo-history` | 1) `journalctl _COMM=sudo -n 2000`  2) `grep -E 'sudo(\\\|:)' /var/log/auth.log /var/log/secure`  3) `sudoreplay -l` (有設定時) | Event metadata；sudoreplay 列：session info | sudoreplay 列 → `sudoreplay <id>`；其他 → lnav 開 event | Linux only |
| `tv audit-events` | 1) `aureport --summary -i`  2) `ausearch -k <baseline-key> --interpret -ts recent` for identity / privileged / sudoers / sshd_config  3) `aureport -au -i` 和 `aureport -x -i` | 選中列的 `ausearch -i -a <eventid>` | `lnav` 開完整 event；`Alt+E` 用 `$EDITOR` 開 `/etc/audit/rules.d/` | Linux + auditd |
| `tv users` | 1) 全 passwd 條目  2) 可登入 user (有真 shell)  3) groups + 成員  4) sudoers (sudo/wheel/admin + `sudoers.d/`)  5) 每 home 的 authorized_keys（含 fingerprint + comment） | 單 user 身份 dump：id、groups、passwd、last login、sudo 事件、SSH key 數 | 鑽入：`lnav` 開完整身份報告；`Alt+G` 顯示 group；`Alt+E` `visudo` | macOS + Linux |
| `tv firewall` | 1) 防火牆規則 (nft / iptables / ufw / firewalld / pf / ALF)  2) listening TCP+UDP  3) established TCP  4) 預設政策 / zone | 每列：解析 port → service、走擁有者 process parent tree | 鑽入：`lnav` 開完整規則 context + `lsof -p`；`Alt+E` 編輯 firewall config；`Alt+R` reload 規則 | macOS + Linux |
| `tv scheduled-jobs` | 1) user crontab  2) system cron (`/etc/crontab` + `cron.d/` + `cron.{hourly,daily,...}/`)  3) systemd timer (system + user)  4) at job  5) anacron (Linux) / launchd plist (macOS) | 每列：解碼排程、顯示觸發 unit、timer 顯示 `systemctl status` | 鑽入：`lnav` 開 `systemctl cat` + 最近 30 條 log；`Alt+E` 編輯 crontab/unit；`Alt+T` tail 相關 log | macOS + Linux |
| `tv disk` | 1) `df -hT` 每 mount  2) `df -hi` inodes  3) `/var /home /tmp /opt /srv` 下第一層最大目錄  4) active mount + options  5) >100M 最大檔 | 路徑感知：dir 用 `du -h --max-depth=1`、file 用 `ls -lh` + `file` | `Enter` yazi 開 dir / less 開 file；`Alt+E` 編輯 `/etc/fstab`；`Alt+T` tail `dmesg -wT` | macOS + Linux |
| `tv services-health` | 1) failed unit (Linux) / errored launchctl (macOS)  2) high-restart unit (NRestarts > 3)  3) 近期 OOM kill (Linux)  4) 全 running service  5) 近期 error 級 crash | `systemctl status` + 最近 10 條 log (Linux)；`launchctl list` 細節 (macOS) | `Enter` lnav 開 journalctl；`Alt+R` 重啟（確認）；`Alt+S` 停止（確認）；`Alt+E` `systemctl edit --full` | macOS + Linux |

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
