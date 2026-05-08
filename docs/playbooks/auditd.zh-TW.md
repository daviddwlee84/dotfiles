# auditd ansible role（可選）

`dot_ansible/roles/auditd/` role 在支援的 Linux profile 上安裝並設定
Linux Audit framework。透過 `installAuditd` chezmoi prompt **opt-in**
(預設 `false`)；macOS 主機無條件跳過 (macOS 沒有 auditd)。

概念背景 — 什麼是 auditd、怎麼查詢、它涵蓋了 sudo log 沒涵蓋的什麼 —
見 [docs/sysadmin/auditd.md](../sysadmin/auditd.md)。

## 啟用

```bash
chezmoi init --force          # 對「Install Linux audit framework」答 yes
chezmoi apply
```

或非互動設 prompt：

```bash
chezmoi execute-template '{{ promptBoolOnce . "installAuditd" "" true }}' >/dev/null
chezmoi apply
```

`scripts/init/dotfiles_init.py` 的 `server-linux` bundle 已預設
`installAuditd: True`，所以 `dotfiles_init.py --bundle server-linux`
直接拿到。

## 安裝什麼

| Distro | 套件 | Service |
|---|---|---|
| Debian / Ubuntu | `auditd`、`audispd-plugins` | `auditd.service` |
| RHEL / CentOS / Rocky / Alma | `audit` | `auditd.service` |

## 放到 `/etc/audit/rules.d/` 的內容

| 檔案 | 來源 | 用途 |
|---|---|---|
| `00-baseline.rules` | `roles/auditd/files/00-baseline.rules` | identity / sudoers / sshd_config / audit_config / time-change / access-denied watch 規則 |
| `05-privileged.rules` | `roles/auditd/files/05-privileged.rules` | `sudo`、`su`、`passwd`、`chsh`、`mount`、`usermod` 等 per-binary execve 規則 |
| `10-execve.rules` (opt-in) | `roles/auditd/files/10-execve.rules` | **所有** execve syscall。僅當 `auditd_log_all_execve: true` |
| `99-finalize.rules` (opt-in) | inline 產生 | `-e 2` 不可變 lock。僅當 `auditd_immutable: true` |

放完檔案後 role 透過 handler 觸發 `augenrules --load`，所以變更不需重開機
就生效（除非已 opt-in 不可變模式）。

## `/etc/audit/auditd.conf` 調整的內容

| Knob | 預設 | 為什麼 |
|---|---|---|
| `max_log_file` | `50` (MB) | 50 MB 輪轉，`audit.log` 仍可 grep |
| `num_logs` | `8` | 保留約 400 MB 歷史 |
| `space_left` | `200` (MB) | `/var/log/audit/` 剩 < 200 MB 時警告 |
| `space_left_action` | `syslog` | 空間不足不要 halt（較安全的預設） |
| `disk_full_action` | `syslog` | 同上；最嚴格 (`halt`) 會 panic kernel |

五個都可透過 role variable 調整 — 見
`dot_ansible/roles/auditd/defaults/main.yml`。

## Role variable

```yaml
auditd_immutable: false             # 設 true 加 `-e 2` finalize 規則
auditd_log_all_execve: false        # 設 true 啟用全 execve syscall logging
auditd_max_log_file_mb: 50
auditd_num_logs: 8
auditd_space_left_mb: 200
auditd_space_left_action: "syslog"  # syslog | email | exec | suspend | single | halt
auditd_disk_full_action: "syslog"
```

要每台 host 覆寫，放檔到 `~/.config/dotfiles/ansible.local.yml` (本 repo
標準 ansible override 路徑 — 見
[docs/this_repo/ansible_customization.md](../this_repo/ansible_customization.md))，
或 ansible CLI 帶：

```bash
ansible-playbook -e auditd_log_all_execve=true ...
```

## 驗證

`chezmoi apply` 成功後：

```bash
# Service 已 active
systemctl is-active auditd

# 規則已載入
sudo auditctl -l | head

# 基準規則 key 可查
sudo ausearch -k sudoers --start '5 minutes ago' -i || echo '(尚無事件)'

# 用本 repo helper（見 docs/sysadmin/helpers.md）
audit-rules-show
audit-summary
```

## 注意事項

- **`auditd_immutable: true` 鎖定後再跑**：之後規則編輯到下次重開機才會
  載入。Role 仍會放新規則檔，所以變更跨重開機保留 — 但 running kernel
  繼續用舊規則集。不可變切換要謹慎規劃。
- **Disk 使用**：即使沒開 `auditd_log_all_execve`，忙碌多 user 主機的
  基準規則集每天可產生 100+ MB 到 `/var/log/audit/`。監控
  `/var/log/audit/audit.log` 大小，需要更長保留就把 `max_log_file` /
  `num_logs` 調高。
- **與 sudo I/O 捕捉合用**：本 role **不**改 sudoers。要 root session
  完整 TTY 錄製，另外 `visudo` 加 `Defaults log_input, log_output`
  (見 [docs/sysadmin/sudo-audit.md](../sysadmin/sudo-audit.md) — `sudoreplay`
  那節解釋 trade-off，包含會錄到 TTY 打的密碼)。
- **Container / WSL 主機**：auditd 需要 `CAP_AUDIT_WRITE` 和
  `CONFIG_AUDIT=y` 的 kernel。WSL 2 kernel 通常有；rootless container
  通常沒有。Role 的「Skip auditd role on non-Linux」guard **不**偵測
  「Linux 但 auditd 不相容」 — 安裝會成功但 service 可能起不來。有
  問題看 `journalctl -u auditd`。
- **macOS / FreeBSD**：不支援。Role 第一個 task 在非 Linux 上 end play。
  macOS 用 Endpoint Security (`eslogger(1)` / EDR)；天花板討論見
  [docs/sysadmin/atuin-vs-audit.md](../sysadmin/atuin-vs-audit.md)。

## 另見

- [docs/sysadmin/auditd.md](../sysadmin/auditd.md) — 概念 + 查詢參考
- [docs/sysadmin/helpers.md](../sysadmin/helpers.md) — 消費本 role 安裝
  的規則的 `audit-*` shell helper 和 `tv audit-events` channel
- [docs/this_repo/ansible_customization.md](../this_repo/ansible_customization.md)
  — 如何 per-host 覆寫 role variable
