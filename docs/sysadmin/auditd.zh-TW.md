# auditd 框架 (Level 3)

`auditd` 是 **Linux Auditing System** 的 userspace component。它從 kernel
接收 audit event，寫到 disk 供之後用 `ausearch` 查詢、用 `aureport` 摘要。
規則用 `auditctl` 載入（即時）或寫到 `/etc/audit/rules.d/*.rules`（透過
`augenrules` 跨重啟生效）。

當你需要以下時這是正解：

- 涵蓋 `sudo bash` / `su -` shell **內部**跑的 command。
- 監看**特定檔案**（sudoers、sshd_config、/etc/passwd、機密）的紀錄。
- 身份切換 audit (`setuid`、`setgid`、`setresuid`)。
- 合規等級事件（CIS、PCI-DSS、STIG profile 都建在 auditd 上）。
- 在事件**前**就載入、(可選) 重開機前不可變的規則。

它**不**適合「誰跑了我的 script？」這種好奇心。忙碌機器上 execve
logging 的事件量很可觀。

## 安裝

本 repo 的可選 `auditd` ansible role 會處理 Linux profile 上的安裝 +
基準規則集。見 [docs/playbooks/auditd.md](../playbooks/auditd.md)。
要 opt-in：

```bash
chezmoi init --force                 # 對「Install auditd?」答 yes
# 或，如果已 init：
chezmoi execute-template '{{ promptBoolOnce . "installAuditd" "" false }}'
chezmoi apply
```

手動安裝（不用 role）：

```bash
# Debian / Ubuntu
sudo apt-get install -y auditd audispd-plugins
sudo systemctl enable --now auditd

# RHEL / CentOS / Rocky / Alma
sudo dnf install -y audit
sudo systemctl enable --now auditd
```

注意套件名差異：Debian → `auditd`，RHEL → `audit`（service 兩邊都叫
`auditd`）。

## 四個核心 command

| Command | 做什麼 |
|---|---|
| `auditctl` | 顯示 / 載入 / 刪除 running kernel 的規則 |
| `ausearch` | 查 disk 上的 audit log (`/var/log/audit/audit.log`) — 按 event id、key、時間、user、syscall、pid 等 |
| `aureport` | 摘要 report：auth event、executable、檔案存取、anomaly |
| `augenrules` | 把 `/etc/audit/rules.d/*.rules` 串起來用 `auditctl -R` 載入（auditd service unit 會跑） |

## 本 repo 提供的基準規則

ansible role 會放 `/etc/audit/rules.d/00-baseline.rules`，涵蓋：

- **身份變更**：監看 `/etc/passwd`、`/etc/group`、`/etc/shadow`、
  `/etc/gshadow`。Key `identity`。
- **Sudoers**：監看 `/etc/sudoers` 和 `/etc/sudoers.d/`。Key `sudoers`。
- **SSH config**：監看 `/etc/ssh/sshd_config`。Key `sshd_config`。
- **Audit config**：監看 `/etc/audit/` 自己。Key `audit_config`。
- **特權命令 exec**：記錄每個 setuid/setgid binary 的 `execve`。
  Key `privileged`。
- **時間變更**：`adjtimex`、`settimeofday`、`clock_settime`。
  Key `time-change`。
- **失敗**：production 目錄的 EACCES / EPERM 失敗開檔。Key
  `access-denied`。

可選 (預設註解掉；要的話在 `/etc/audit/rules.d/10-execve.rules` 取消註解)：

- **所有 execve syscall**（量極大）。Key `execve-all`。

Role 預設**不**啟用 `-e 2`（重開機前不可變），因為那會讓初始調整時的
ad-hoc 規則編輯卡住。確認規則穩定後用 role variable
`auditd_immutable: true` 開啟。

## 常用查詢

```bash
# 即時規則
sudo auditctl -l

# 「sudoers」watch key 的所有事件
sudo ausearch -k sudoers --interpret

# 今天有人動 /etc/passwd 嗎？
sudo ausearch -f /etc/passwd --start today --interpret

# 過去 24h 每個 setuid binary 的 execve
sudo ausearch -k privileged --start '24h ago' --interpret

# 驗證事件摘要
sudo aureport -au -i

# Executable 摘要（跑過哪些 binary）
sudo aureport -x -i | head -30

# Anomaly 事件（auditd 標記的可疑模式）
sudo aureport --anomaly -i

# 按 audit event id 看單一事件細節
sudo ausearch -a 12345 -i

# 每日摘要
sudo aureport --start today --summary -i
```

## 注意事項與運維考量

- **Execve logging 量**：開啟 per-syscall execve 規則在忙碌機器可產生
  每天數 GB。請規劃 disk + log rotation
  (`/etc/audit/auditd.conf` → `max_log_file`、`num_logs`、
  `space_left_action`)。
- **敏感 command line**：execve 紀錄含 argv。User 跑 `mysql -p
  secret123` 會把 `secret123` 寫進 `/var/log/audit/audit.log`
  (root-readable 但仍在 disk 上)。把 audit log 異地 ship 時要小心。
- **Disk-full 行為**：`space_left_action` 和 `disk_full_action` 決定
  audit log volume 滿時 auditd 怎麼做。預設視 distro；最嚴格設定是
  `halt`，會在 disk-full 時 **panic kernel** 以保 audit 完整性。請刻意
  選 trade-off。
- **規則順序很重要**：`auditctl` 按順序評估規則並在第一個 match 短路
  (`-A always,exit` vs `-A never,exit`)。新規則先在非不可變模式測試。
- **效能**：每條啟用 syscall 規則都會在每次 match 該 syscall 時加檢查。
  10k-syscall/s 工作負載下這是可量測的。對效能敏感機器部署廣規則前先
  profile。
- **遠端轉發**：要鑑識等級的 chain of custody，把 `/var/log/audit/`
  ship 到 write-once 遠端（Wazuh、Splunk、audit-remote → 另一台
  auditd）。原則上本機 log 對 root 可變（immutable bit 拖慢但擋不住有
  決心的 root 攻擊者）。
- **macOS 沒有 auditd**：macOS Sonoma 已撤掉 BSM (`audit(4)`)。當前
  macOS audit 框架是 **Endpoint Security**（ad-hoc 查詢用
  `eslogger(1)`，production 用 EDR 產品）。本 repo helper 不涵蓋。

## 本 repo 提供的協助

- **Ansible role**：`dot_ansible/roles/auditd/`（用 `installAuditd`
  chezmoi prompt opt-in）。安裝 auditd、放基準規則集、啟用 service。
  見 [docs/playbooks/auditd.md](../playbooks/auditd.md)。
- **Shell helper**（在 `dot_config/shell/45_audit.sh.tmpl`）：
  - `audit-execve <pattern>` — `ausearch -sc execve -x <pattern> -i`
  - `audit-file <path>` — `ausearch -f <path> -i`
  - `audit-summary [--start <when>]` — 串接 `aureport` 摘要
  - `audit-rules-show` — `auditctl -l` + 持久化規則差異
- **Television channel**：`tv audit-events` (Linux only) — 模糊瀏覽
  `aureport` 摘要列，預覽顯示底層 ausearch event（`-i` interpret 過）。
  `Enter` 在 `lnav` 開完整事件。

完整對照表見 [本 repo 提供的 helper](helpers.md)。

## FAQ

### 為什麼 `/etc/audit/rules.d/` 不用 chezmoi 管（例如 `create_`）？

三個原因都不行：

1. **路徑寫死在 auditd 裡**。`auditd.service` 啟動時跑 `augenrules
   --load`，**只**讀 `/etc/audit/rules.d/*.rules`。User 路徑
   (`~/.config/audit/...`) daemon 看不到。不像 user-space 工具
   (tmux、nvim) 自己決定 config 路徑，audit 是 kernel 子系統，路徑固定。
2. **檔案必須是 `root:root` mode 0640**。chezmoi 跑在 user 權限下，
   物理上寫不到 `/etc/`。`create_` 解決不了 — 它是 chezmoi 的*部署
   語意*（種子一次），不是提權。目標必須在 chezmoi 管理的 home 裡。
3. **Audit rules 是 system-wide 的**。Kernel 一次只有一份規則集，
   影響所有 user。「per-user dotfile」模型本來就不適用。

本 repo 的分工是：

| 工具 | 範圍 | 權限 | 例子 |
|---|---|---|---|
| chezmoi | user-space (`~/.config/`、`~/.zshrc`) | user | shell aliases、tmux config |
| ansible | system-wide (`/etc/`、`apt install`、systemd) | root via `become: true` | auditd 規則、Docker daemon config、`/etc/shells` |

`auditd` role 跟 `docker`（裝 daemon + 寫 `/etc/docker/daemon.json` +
把 user 加到 docker group）和 `bash`（brew 裝 bash 5.x + 改
`/etc/shells` + `chsh`）是同一類。三者都是 install-once + idempotent
（[`docs/this_repo/upgrades.md`](../this_repo/upgrades.md) 的
install-vs-upgrade split 讓 `chezmoi apply` 不會每次重 bump），符合
「one-time setup」直覺 — 只是執行者是 ansible-with-sudo 而不是
chezmoi prefix。

### 我可以手動編輯規則檔嗎？

可以，但下次 `chezmoi apply` 會被覆蓋（role 用
`ansible.builtin.copy` force-replace）。host-specific 調整推薦：

- 新建 `/etc/audit/rules.d/50-local.rules` 檔（任何不在 role 管理集
  `00-baseline`、`05-privileged`、`10-execve`、`99-finalize` 的檔名）。
  Role 不碰其他檔名。
- 或透過
  [`docs/this_repo/ansible_customization.md`](../this_repo/ansible_customization.md)
  的標準 ansible override 路徑 per-host 覆寫 role 變數
  (`auditd_log_all_execve`、`auditd_immutable` 等)。

### 怎麼看現在實際載入了什麼？

```bash
audit-rules-show     # 本 repo helper
# 或：
sudo auditctl -l
```

如果 `chezmoi apply` 後 `auditctl -l` 顯示 `No rules`，看
`journalctl -u auditd` — role 有放檔，但 augenrules 在規則語法錯時
會安靜失敗。Handler 也會跑 `augenrules --load`，失敗會出現在 apply log。

### 為什麼我某 key 下零事件？

三個常見原因：

1. **規則沒載入** — `audit-rules-show` 確認。
2. **Watch 路徑在這台不存在** — auditctl 對 `-w /missing/path` 安靜跳過。
3. **`auditd` service 沒跑** — `systemctl is-active auditd`。

## 另見

- [sudo 審計](sudo-audit.md) — Level 1 起點；auditd 從 sudo log 結束
  的地方接手
- [Process accounting](process-accounting.md) — auditd 太重時的較輕替代
- [Atuin vs audit](atuin-vs-audit.md) — 為什麼個人 shell history 取代
  不了上述任何一個
