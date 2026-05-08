# 系統管理員：誰在這台機器上做了什麼？

只要 Linux 機器被超過一個人（或一人 + coding agent）共用，這個問題早晚會
出現：**誰跑了什麼、什麼時候跑、從哪裡跑、那筆紀錄到底可不可信？**

短答：shell history 不是 audit log。Atuin 不是 audit log。它們是 user-space
的便利工具，由跑 command 的那個 user 自己擁有與編輯。要做真正的審計，需要
一條為審計設計的資料源 — 而且最好是**事件發生之前**就先配置好。

本節是一份分層導覽，帶你看那些**為審計設計**的資料源，並介紹這個 repo 內
建的 helper 與 Television channel，把日常查詢變得低摩擦。

## 四個層級

| Level | 回答的問題 | 工具 | 可靠度 |
|---|---|---|---|
| **0. Session / 登入** | 誰登入？從哪裡？什麼時候？有 `su` 嗎？ | `last`, `lastlog`, `who`, `journalctl _COMM=sshd`, `/var/log/auth.log`, `/var/log/secure` | 高 — 由 kernel + sshd 寫入 |
| **1. sudo / 提權** | 誰提權？跑了哪條 top-level command？ | `journalctl _COMM=sudo`, `grep sudo /var/log/{auth,secure}*`, `sudoreplay` | 中 — 抓得到 `sudo` 那行，但抓不到 `sudo bash` 內部 |
| **2. Process accounting** | 有人 exec 過 `<binary>` 嗎？ | `acct` / `psacct`, `lastcomm`, `sa` | 中 — 粗粒度、無完整 argv，要事先啟用 |
| **3. Audit framework** | Policy-driven kernel event：execve、檔案監看、身份切換、sudoers 修改 | `auditd`, `auditctl`, `ausearch`, `aureport` | 高 — 前提是規則在事件**前**就設好 |

Level 3 之上還有 fleet 等級的 telemetry 產品（Falco、Tetragon、Sysdig、
Wazuh、商業 EDR）。那些不在 dotfiles repo 的範圍內，但
[Atuin vs audit](atuin-vs-audit.md) 的對照表有列出來，方便你知道天花板
在哪。

## 本節頁面

- [Session 與登入](sessions.md) — Level 0
- [sudo 審計](sudo-audit.md) — Level 1
- [Process accounting](process-accounting.md) — Level 2
- [auditd 框架](auditd.md) — Level 3
- [Firewall 與網路曝險面](firewall.md) — 什麼擋、什麼 bind、誰連著（橫跨
  四層）
- [排程任務](scheduled-jobs.md) — cron + systemd timer + at + launchd；
  persistence 偵測面
- [Disk / filesystem 監控](disk.md) — `df` / `du` / inode / mount；
  auditd disk-full 預防
- [Service health](services-health.md) — failed unit、restart loop、OOM；
  `health-check` 早晨摘要
- [Atuin vs audit](atuin-vs-audit.md) — 為什麼個人 shell history 不是
  正確工具，含完整對照表
- [**Cookbook（場景食譜）**](cookbook.md) — 實戰導覽：「有人從新 IP
  登入嗎？」、「user 回報被入侵 — 現在該做什麼？」、「不重 apply 就
  關掉吵雜規則」，加另外 7 篇
- [本 repo 提供的 helper](helpers.md) — `audit-*` shell 函式 + `tv
  sessions` / `tv sudo-history` / `tv audit-events` Television channel

## 決策流

```text
「誰登入過這台？」                       →  audit-sessions   (Level 0)
「今天 <user> 有用 sudo 嗎？」           →  audit-sudo       (Level 1)
「有人跑過 /usr/bin/<x> 嗎？」           →  audit-execve     (Level 3，需事先設規則)
「/etc/<file> 有被改嗎？」               →  audit-file       (Level 3，需 watch 規則)
「這台 server 曝什麼？」                  →  fw-listening     (firewall.md)
「這台機器排了什麼會自動執行？」          →  cron-list        (scheduled-jobs.md)
「有東西滿了 / 快滿了嗎？」               →  disk-usage       (disk.md)
「早晨快速健康檢查」                      →  health-check     (services-health.md)
「即時監控可疑活動」                      →  audit-watch
「合規 / 鑑識事件」                      →  auditd + 異地 log shipping
「我自己回想用過什麼 command」           →  atuin            (不是審計)

「直接開個 sysadmin channel」             →  tv sysadmin      (curated launcher)
```

## 本節不涵蓋

- 不是「如何規避 audit log」教學。
- 不是鑑識 / 事件處理 playbook（那些需要異地 log shipping、chain of
  custody、超出 dotfiles 範圍的工具）。
- 不是 SIEM 設計指南。

合規與鑑識等級審計請在事件發生**之前**就配置好 auditd 或其他 host-level
audit agent，把 log 異地唯讀備份，並把 user-space history（bash / zsh /
atuin）當成便利資料而非真實來源。
