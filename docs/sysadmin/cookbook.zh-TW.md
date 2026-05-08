# Cookbook：場景式審計食譜

針對本 repo helper 與 TV channel 的實戰、場景優先導覽。每篇食譜回答一個
具體問題（「有人從新 IP 登入嗎？」），給你完整命令順序，並標出輸出中
要看什麼。

概念分層見 [section README](README.md)。Helper 密集對照表見
[helpers.md](helpers.md)。

## 食譜索引

- [1. 現在誰登入這台 server？](#1-現在誰登入這台-server)
- [2. 本週有人從新 IP 登入嗎？](#2-本週有人從新-ip-登入嗎)
- [3. 暴力破解 / password-spray 檢查](#3-暴力破解--password-spray-檢查)
- [4. 某使用者今天用了 sudo 嗎？做了什麼？](#4-某使用者今天用了-sudo-嗎做了什麼)
- [5. 「我懷疑有人從這台跑 nmap」 — Level 2 / Level 3](#5-我懷疑有人從這台跑-nmap--level-2--level-3)
- [6. `/etc/sudoers` 被改過嗎？什麼時候？誰改的？](#6-etcsudoers-被改過嗎什麼時候誰改的)
- [7. 事後處理：使用者回報帳號被入侵](#7-事後處理使用者回報帳號被入侵)
- [8. 每日 5 分鐘健康檢查（cron 友善）](#8-每日-5-分鐘健康檢查cron-友善)
- [9. 「root shell 做了什麼？」 — sudo log 之外](#9-root-shell-做了什麼--sudo-log-之外)
- [10. 快速關掉吵雜的 audit 規則但保留其他](#10-快速關掉吵雜的-audit-規則但保留其他)

---

## 1. 現在誰登入這台 server？

**工具**：`audit-sessions`，不需 sudo、不需 auditd。

```bash
audit-sessions
```

看第三段（`== who -a ==`）。每列都是即時 session：

```
alice    pts/0   2024-05-08 09:21 (10.0.0.42)
bob      pts/1   2024-05-08 09:45 (10.0.0.99)
```

**警訊**：
- 你不認識的 user。
- 從 public IP 連來的 `pts/N`（你的 sshd 通常該只看到內網 / VPN 段）。
- 同一 user 多個 `pts/N`（可能合法 tmux 用法 — 如果是*你自己的*帳號交叉
  比對 `tmux ls`）。

可疑就跳食譜 #7。

---

## 2. 本週有人從新 IP 登入嗎？

**工具**：人眼掃用 `audit-sessions`；互動瀏覽用 `tv sessions`。

```bash
audit-sessions | head -100 | awk '{print $1, $3}' | sort -u
```

dump `user IP` 對。對照你的「已知 IP」清單（VPN 段、家裡 IP、CI runner
IP）。

**或互動式**：

```bash
tv sessions
# 打 username，看他近期所有登入，捲動檢查 IP
```

看到非預期 IP 就跳食譜 #7。

---

## 3. 暴力破解 / password-spray 檢查

**工具**：`audit-failed-logins` (Linux only，sudo)。透過 `lastb` 讀
`/var/log/btmp`。

```bash
audit-failed-logins | head -100
```

按 IP 群組看模式：

```bash
sudo lastb -F -i | awk 'NR>1 && $3 ~ /[0-9]/ {print $3}' | sort | uniq -c | sort -rn | head -20
```

輸出是 `count IP`。單一 IP 一天超過 ~50 就值得防火牆封。對照你的 sshd
config — 已停密碼驗證 (`PasswordAuthentication no`) 的話這裡的失敗多半
是噪音；真實故事在 `journalctl _COMM=sshd | grep -i 'invalid\|preauth'`。

---

## 4. 某使用者今天用了 sudo 嗎？做了什麼？

**工具**：`audit-sudo`。systemd 主機透過 journalctl；其他用
`auth.log`/`secure` grep。

```bash
audit-sudo alice
```

輸出列像：

```
May 08 10:14:22 host sudo[12345]: alice : TTY=pts/0 ; PWD=/home/alice ; USER=root ; COMMAND=/usr/bin/apt update
May 08 10:14:55 host sudo[12399]: alice : TTY=pts/0 ; PWD=/home/alice ; USER=root ; COMMAND=/bin/bash
```

**讀法**：`<時間> <主機> sudo[PID]: <user> : TTY=<tty> ; PWD=<cwd> ;
USER=<目標> ; COMMAND=<argv0+args>`。

**`/bin/bash` 那行就是警訊** — alice 一拿到互動 root shell，sudo log
就停止記她做了什麼。跳食譜 #9 看 auditd 解。

只看失敗：

```bash
audit-sudo alice | grep -E 'FAILED|NOT in sudoers|incorrect password'
```

---

## 5. 「我懷疑有人從這台跑 nmap」 — Level 2 / Level 3

**Level 2 (process accounting，需事先啟用)**：

```bash
sudo lastcomm nmap | head -20
```

顯示 `command flags user tty seconds 開始時間`。沒有 argv（看不到他*掃了
什麼*），但能證明跑過。

**Level 3 (auditd，本 repo 的 `audit-execve`)**：

```bash
audit-execve nmap
```

每個事件含：
- `pid=NNNN` 與 `ppid=MMMM` — 用 `audit-execve` 對 parent 反查上游。
- `auid=N` — *原始*登入 UID（過 `sudo` / `su` 也保留）。用 `id <auid>`
  翻成名字找出真正起頭的人。
- 啟用 `10-execve.rules` 後（role variable `auditd_log_all_execve`）有
  完整 argv；沒啟用就只有 binary 路徑（且預設 `nmap` 不在 privileged
  rule 內 — 要的話擴 `05-privileged.rules`）。

**單台主機加 `nmap` 到 privileged rule set**：

```bash
echo '-a always,exit -F path=/usr/bin/nmap -F perm=x -F auid>=1000 -F auid!=unset -k privileged' \
  | sudo tee /etc/audit/rules.d/50-local.rules
sudo augenrules --load
audit-rules-show | grep nmap
```

`50-local.rules` 檔名不在 auditd role 管理集
(`00-baseline`、`05-privileged`、`10-execve`、`99-finalize`) 內，所以
`chezmoi apply` 不會覆寫。

---

## 6. `/etc/sudoers` 被改過嗎？什麼時候？誰改的？

**工具**：`audit-file`（需要 baseline `sudoers` watch 規則 — 本 repo
auditd role 預設就放）。

```bash
audit-file /etc/sudoers
audit-file /etc/sudoers.d/
```

每事件顯示：
- `type=PATH name=/etc/sudoers` — 被監看物件。
- `type=SYSCALL ... auid=1000 uid=0` — `auid` 是原始登入 UID（人類），
  `uid` 是執行身份（sudo 後是 root）。
- `comm=` 與 `exe=` — 做修改的程式 (`vim`、`visudo`、`sed`、`cp` ...)。

**對照 sudo log** 找包住的 sudo 呼叫：

```bash
audit-sudo | grep -i 'visudo\|sudoers'
```

合起來告訴你：*Alice 10:14 跑 `sudo visudo`，10:15 寫到 /etc/sudoers*。

---

## 7. 事後處理：使用者回報帳號被入侵

你在 host 上，user 剛跟你說「我覺得有人進了我的帳號」。**做任何破壞性
動作*之前*** 按順序跑下面這些（先別 `kill` session 或重設密碼 —
證據會掉）。

### 7a. 即時狀態快照（5 秒，零上下文流失）

```bash
who -a > /tmp/forensics-who.txt
ps -eo user,pid,ppid,tty,etime,cmd | head -200 > /tmp/forensics-ps.txt
ss -tnp 2>/dev/null > /tmp/forensics-ss.txt   # 活躍 TCP，含 PID
sudo iptables -S > /tmp/forensics-iptables.txt 2>/dev/null
date -u > /tmp/forensics-time.txt
```

### 7b. 框出登入時段

```bash
audit-sessions <user> | head -50
```

找出可疑 session：奇怪 IP、非工作時間、長時間閒置的「不是你」session。

### 7c. 他們 sudo 了什麼？

```bash
audit-sudo <user> | head -100
```

注意 `sudo bash` / `sudo -i` / `sudo su -` — 這些是提權點；那行**之後**
所有東西對 sudo log 都不可見。記下時間。

### 7d. 他們 exec 了什麼？（只 auditd）

對可疑 sudo 提權後的時段：

```bash
sudo ausearch --start '<YYYY-MM-DD HH:MM:SS>' --end '<YYYY-MM-DD HH:MM:SS>' \
  -sc execve -i | head -200
```

沒開 `auditd_log_all_execve` 時只看得到 `05-privileged.rules` 裡的
binary exec。開了就全看，慢但完整。

### 7e. 他們動了什麼？

```bash
audit-file /home/<user>/.ssh/
audit-file /etc/passwd
audit-file /etc/shadow
audit-file /etc/sudoers
```

找 `EXECVE` 事件的 `useradd`、`usermod`、`passwd`、`chsh` — 這些建立
持久化。

### 7f. SSH key 篡改（典型入侵後手法）

```bash
sudo ls -la /home/<user>/.ssh/
sudo cat /home/<user>/.ssh/authorized_keys
# 不認得的 = 攻擊者的持久化 key。

# 找全機所有 authorized_keys（含 root 管的 user）：
sudo find / -name 'authorized_keys' 2>/dev/null -exec ls -la {} \;
```

### 7g. 現在可以動手了

- 鎖帳號：`sudo passwd -l <user>`
- Kill 全部 session：`sudo pkill -KILL -u <user>`
- 換 SSH key（合法 `authorized_keys` 移開，寫新的）。
- 重開機前把 `/tmp/forensics-*.txt` 存到 host 外。

如果這是合規環境，**到此打住、叫 IR 團隊** — 任何後續動作可能破壞
chain of custody。

---

## 8. 每日 5 分鐘健康檢查（cron 友善）

早上快速檢查：昨晚有什麼怪事嗎？

```bash
#!/bin/sh
# /usr/local/bin/audit-morning-check.sh — cron @ 08:00
set -eu

echo "== 過去 24h session =="
last -F -i --since '24 hours ago' 2>/dev/null | head -20

echo
echo "== 過去 24h 失敗登入 =="
sudo lastb -F -i 2>/dev/null | awk '$0 !~ /^$/' | head -20

echo
echo "== 過去 24h sudo 事件 =="
sudo journalctl _COMM=sudo --since '24 hours ago' --no-pager | tail -20

echo
echo "== Audit 摘要 =="
sudo aureport --start '24 hours ago' --summary -i 2>/dev/null
```

加到 crontab，pipe 到 email / Slack：

```cron
0 8 * * *  /usr/local/bin/audit-morning-check.sh 2>&1 | mail -s "Audit @ $(hostname)" you@example.com
```

`audit-*` shell helper 本身需互動 TTY 才能 sudo prompt，所以 cron 用就
直接 `sudo journalctl` / `sudo aureport`（或對特定命令配 passwordless
sudo via `sudoers.d/` 片段）。

---

## 9. 「root shell 做了什麼？」 — sudo log 之外

`audit-sudo` 看到 `sudo bash`。Sudo log 從這裡變黑。怎麼辦？

**選項 A — auditd execve（`auditd_log_all_execve: true` 時的預設）**：

```bash
# 找該 bash session
sudo ausearch -k execve-all -p <bash-pid> -i

# 或按 parent PID — 找 root bash 的子程序
sudo ausearch -k execve-all --start '<時間>' -i | grep -A2 "ppid=<bash-pid>"
```

沒開 `execve-all` 就只看 `05-privileged.rules` 內的 exec
(su、passwd、mount 等)。

**選項 B — sudoreplay（事件**前**已在 sudoers 設 `Defaults
log_input,log_output` 才有）**：

```bash
sudo sudoreplay -l user=<user>
sudo sudoreplay <session-id>
```

回放整個 TTY：每個 keystroke、看到的每個畫面。注意 — 包含 TTY 打的
密碼（不該打但常常打）。

**選項 C — process accounting**：

```bash
sudo lastcomm | grep -B2 -A2 ' bash '
```

粗但 `acct`/`psacct` 裝了就能用無需事先設定。看不到 argv。

**選項 D — 太遲了**：

A/B/C 事件前都沒設好的話，從這 host 答案**不可知**。這就是為什麼
[`atuin-vs-audit.md`](atuin-vs-audit.md) 叫你*事件前*就先設好 audit。

---

## 10. 快速關掉吵雜的 audit 規則但保留其他

場景：`auditd_log_all_execve: true` 一天產 5 GB；要保留基準規則，但
*現在*殺掉 execve 洪水，不走 `chezmoi apply` 流程。

```bash
# 1. 列載入規則找出兇手
sudo auditctl -l | grep execve

# 2. 從 running kernel 刪掉 execve 規則
sudo auditctl -d always,exit -F arch=b64 -S execve,execveat -k execve-all
sudo auditctl -d always,exit -F arch=b32 -S execve,execveat -k execve-all

# 3. 確認
audit-rules-show | grep execve   # 應為空
```

這是 runtime-only 變更 — 下次重開機（或下次 `augenrules --load`）規則
還會回來，如果檔還在。要永久解：翻 role 變數重 apply：

```bash
# 在 ~/.config/dotfiles/ansible.local.yml 或用 -e：
auditd_log_all_execve: false
chezmoi apply --force
```

Role 的「Remove full execve rules when not opted in」task 會刪
`/etc/audit/rules.d/10-execve.rules`，handler 會 reload。

`auditd_immutable: true` (即 `-e 2` 已載入) 時，步驟 2 會 fail
`Operation not permitted`。鎖到下次重開機。不可變切換要算進這點。

---

## 另見

- [本 repo 提供的 helper](helpers.md) — 上述工具的密集對照表
- [auditd 框架](auditd.md) — 概念 + FAQ（含「為什麼 `/etc/audit/rules.d/`
  不用 chezmoi 管」）
- [sudo 審計](sudo-audit.md) — Level 1 深入、`sudoreplay` 設定
- [Atuin vs audit](atuin-vs-audit.md) — 為什麼個人 shell history 替代
  不了上述任何一個
