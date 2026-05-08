# Disk / filesystem 監控

Sysadmin 早晨問題：**有東西滿了嗎？什麼在吃空間？**

本頁紀錄 disk 相關 helper 與 `tv disk` channel。完整對照表見
[helpers.md](helpers.md#disk--filesystem)。

## 為什麼在意

凌晨 3 點會吵醒你的三種失敗模式：

1. **Disk full** (`No space left on device`) — `disk_full_action =
   halt` 時 auditd 會 panic kernel。多數其他 daemon 只是安靜停止接受寫入。
2. **Inode 用盡** — disk 有空間但 `touch foo` 失敗，因為 inode 表滿了。
   常見於建大量小檔的 app（mail spool、調差的 cache）。
3. **Mount 掉了 / mount option 錯了** — 路徑還在但不在你以為的地方，或
   被改成 `nosuid,nodev`（手動 remount 後的 security regression）。

Helper 涵蓋三者。

## 快速 CLI

```bash
disk-usage             # 每 mount df，色階綠/黃/紅
disk-inodes            # 每 mount inode 用量
disk-largest /var      # /var 下第一層最大子項
disk-largest /var/log --top 10  # 經典 /var/log 分流
mount-info             # active mount + /etc/fstab
disk-watch /           # 即時 root mount 用量
```

`disk-largest` 在路徑是 root-owned 時自動 `sudo -v` 提權（例如
`disk-largest /var/lib/docker`）。跟 audit helper 同一踩雷：這些是 shell
**function**，所以 `sudo disk-largest …` 不行；用 `sudo -v` 預熱
cache 一次，之後 helper 自己處理。

## 互動：`tv disk`

```bash
tv disk
```

`Ctrl+S` 切 5 個來源：每 mount df → inode → `/var /home /tmp /opt /srv`
下最大目錄 → active mount → >100M 最大檔。預覽路徑感知（dir 用 `du
--max-depth=1`、file 用 `ls -lh + file`）。`Enter` yazi 開 dir 或 less
開 file。`Alt+E` 編 `/etc/fstab`。`Alt+T` tail
`dmesg -wT --color=always` 即時抓 ENOSPC 與 I/O error。

## 每日 / 每週食譜

### 早晨掃描

```bash
disk-usage         # 有紅列嗎？跳到那個 mount
disk-inodes        # 有 mount inode > 80% 嗎？
```

兩個都綠就 5 秒搞定。`disk-usage` 出紅：

```bash
disk-largest <紅 mount> --top 20
# 然後鑽進兇手
disk-largest <紅 mount>/<最大子目錄> --top 20
```

`tv disk` 鑽入階段更快，因為路徑感知預覽省掉第二次 `disk-largest`。

### `/var/log` 滿了

```bash
disk-largest /var/log --top 20
```

常見嫌犯：

- `journal/` — `sudo journalctl --vacuum-size=200M` 設上限。
- `*.log.1.gz` 累積 — logrotate 設定錯，或 service 沒收到 reopen 信號。
- `audit/` — auditd；按 [auditd.md](auditd.md) 調 `max_log_file` /
  `num_logs`。

### Disk 有空間但 `touch foo` 失敗

inode 用盡：

```bash
disk-inodes
```

找 `IUse%` >= 95%。要找兇手（百萬小檔）：

```bash
sudo find / -xdev -type d -exec sh -c 'echo "$(ls -A "$1" 2>/dev/null | wc -l) $1"' _ {} \; 2>/dev/null \
  | sort -rn | head -20
```

（大檔系統很慢；離峰跑。）

### Mount 審計

```bash
mount-info
```

看：

- `/home` mount 沒帶 `nosuid,nodev` — 提權面。
- `/tmp` mount 沒帶 `noexec,nosuid,nodev` — 攻擊者常用 drop 點。
- `/etc/fstab` 裡**該** mount 但不在 active 清單的 — 開機 mount 失敗。

## 注意事項

- **macOS 沒有 `df -hT`** — helper template 在 Darwin 改用 `df -h`。
- **`du --max-depth=1` 是 GNU 擴展** — macOS BSD `du` 用 `-d 1`。
  Helper 用 `--max-depth=1`（可行因為本 repo 的 Brewfile 在 macOS 預設
  裝 GNU coreutils 把 `du` 蓋掉）；純 macOS 沒 coreutils 會 reject。
  解：`brew install coreutils`（用本 repo 的 Brewfile 已裝過）。
- **`disk-largest` 不跟 mount 邊界** 除非你叫它跟。預設 `du` 把 mount
  的子目錄算進 parent 的 total。要 per-filesystem 用 `du -x`。
- **`dmesg` 多數現代 kernel 需 root** (`kernel.dmesg_restrict=1`)。
  `tv disk` 的 `Alt+T` 透過 sudo 呼叫。

## 另見

- [auditd 框架](auditd.md) — `disk_full_action` 政策
- [本 repo 提供的 helper](helpers.md#disk--filesystem)
- [Cookbook recipe 12](cookbook.md#12-網路曝險--persistence每週掃一次)
  — disk + firewall + scheduled-jobs 合一週掃
