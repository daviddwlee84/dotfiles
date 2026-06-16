# 硬體監控（homelab）

**實體**主機的 sysadmin 提問：**硬體健康嗎 — 風扇有轉、溫度正常、RAID
Optimal、硬碟沒在掛掉嗎？**

本頁說明 `hw-*` helper 與 `homelab_tools` ansible role（chezmoi prompt
`installHomelabTools`）。密集對照表見 [helpers.md](helpers.md#hardware)。本頁是
[disk.md](disk.md)（檔案系統層）再往下一層、貼著金屬的那層。

> 僅限 Linux + 實體機。Role 在 macOS 與 VM 內是 no-op；`hw-*` shell helper 只在
> Linux 定義。

## 三個感測器平面（陷阱所在）

伺服器感測器最令人困惑的一點是：**有三個彼此獨立的來源**，而且互相看不到對方：

| 平面 | 讀什麼 | Helper | 備註 |
|---|---|---|---|
| **BMC / IPMI** | 機箱風扇、進風/主機板溫度、PSU、System Event Log | `hw-fans` `hw-temps` `hw-sel` | 主機板管理控制器。Root only（`/dev/ipmi0`）。 |
| **lm-sensors** | 主機板 Super-I/O / PCI 溫度+風扇晶片 | `hw-sensors` | 先跑一次 `sudo sensors-detect` 啟用 kernel module。 |
| **RAID 卡（storcli）** | 控制器 ROC 晶片溫度 + enclosure 感測器 | `hw-raid` | MegaRAID/LSI 卡有自己的溫度；背板可能回報 **0 風扇 / 0 溫度感測器**。 |

**關鍵陷阱**：被動式 **SGPIO 背板**會對 RAID 卡回報 `Fans = 0`、`TSs = 0` —
這是正常的，不是故障。機箱風扇在 **BMC** 平面（`hw-fans`），不在 RAID 平面。
不要因為 `storcli /cALL/eALL show all` 顯示 0 就斷定「沒有風扇」— 要看
`ipmitool sdr type fan`。

## 快速 CLI

```bash
hw-status          # 一頁總覽：風扇 + 溫度 + RAID + SMART + SEL 錯誤
hw-fans            # 機箱風扇 RPM（BMC）
hw-temps           # BMC 溫度 + lm-sensors
hw-sensors         # 完整 lm-sensors dump
hw-raid            # MegaRAID：控制器狀態、VD/PD、ROC 溫度、enclosure
hw-smart           # 每顆硬碟的 SMART 健康判定（所有實體碟）
hw-smart /dev/sda  # 單顆裝置的完整 smartctl -a 報告
hw-sel             # BMC System Event Log（預設最後 20 筆；--all 看全部）
```

與 audit / disk helper 一樣，這些是 shell **函式**，所以 `sudo hw-fans` 不會動
（sudo 會開一個沒有你函式的新 process）。先用 `sudo -v` 暖好 sudo cache，之後
每個 helper 會自動提權。非互動式呼叫者會看到明確提示。

## 裝什麼、何時裝

`homelab_tools` role **只在偵測到對應硬體時**才裝該工具，所以沒有 RAID 卡 /
NVMe / BMC 的機器不會裝用不到的套件：

| 工具 | 套件 | 何時安裝 |
|---|---|---|
| lm-sensors | `lm-sensors` | 任何實體 Linux 主機 |
| smartmontools | `smartmontools` | 任何實體 Linux 主機 |
| ipmitool | `ipmitool` | 存在 `/dev/ipmi*` **或** DMI type 38（IPMI Device） |
| nvme-cli | `nvme-cli` | `lspci` 出現 NVMe 控制器 |
| storcli | （vendor 下載） | `lspci` 出現 RAID 控制器 |

偵測使用唯讀的 `lspci` / `dmidecode` 探測；role 的 `debug` task 會印出判定結果。

## 安裝 storcli

`storcli` **不在 distro repo** — Broadcom 以 zip 形式放在 support portal 後面。
因此 role 把它當成依 `homelab_storcli_url` role 變數開關的 best-effort 下載：

- **留空（預設）**：偵測到 RAID 控制器但缺 `storcli` 時，role 印出提示後略過
  （不失敗）。請手動安裝並放到 `PATH`（慣例是 `/usr/local/sbin/storcli`）。
- **設成可達的 tarball/zip URL**（僅 x86_64）：role 會下載、解壓、找出
  `storcli`/`storcli64` binary 並安裝到 `~/.local/bin`。

若 URL 失效，請寫進 `pitfalls/` 筆記，而不是在 role 裡硬塞脆弱的 URL。

## 每日 / 每週食譜

### 早晨硬體巡檢

```bash
hw-status
```

一頁搞定。任何紅字或非 `OK`/`Optimal` 的行 → 用對應 helper 深入
（`hw-raid`、`hw-smart /dev/sdX`、`hw-sel --all`）。

### 「硬碟是不是要掛了？」

```bash
hw-smart                 # 每顆判定；找非 PASSED 的
hw-smart /dev/sdb        # 完整屬性：reallocated / pending sector、CRC
```

Reallocated/pending sector 持續上升，或 `SMART overall-health` = `FAILED`，
就該換碟。（本頁存在的另一個理由：我們就是這樣拔掉一顆碟的 — 卸載 / fstab
那一側見 [disk.md](disk.md)。）

### 「RAID 還好嗎？」

```bash
hw-raid
```

看 `Controller Status = Optimal`、沒有 `Degraded`/`Failed` VD。`ROC
temperature` 那行是 RAID 晶片本身 — 偏溫是正常的（LSI 3108 有風流時約
55–80 °C；~95–100 °C 才是警告天花板）。ROC 持續高溫指向卡周邊風流不足，
不是資料問題。

### 「硬體有沒有記錄故障？」

```bash
hw-sel               # 最近的 BMC 事件
hw-sel --all         # 完整 System Event Log
```

PSU 掉電、ECC 錯誤、過熱跳脫、機箱開蓋都會落在這裡。

## 注意事項

- **`ns` / 「No Reading」是未插的槽位**，不是故障 — 部分插滿的機箱常見於
  `FRNT_FAN2` / `REAR_FAN2` / 備援 PSU 溫度感測器。
- **IPMI 是 root only**（`/dev/ipmi0`）— 每個 `hw-fans`/`hw-temps`/`hw-sel`
  都會提權。
- **`sensors` 空白？** 先跑一次 `sudo sensors-detect`（安全探測都回 YES），
  再 reload module 或重開機。
- **storcli 控制器索引**：helper 用 `/cALL`；多控制器主機會全部列出。單卡可
  直接 `storcli /c0 ...`。
- **Install-only**：role **不會**啟用 `smartd` / `ipmievd` 服務（本 repo 設計
  上就是 install-only）。持續監控/告警會是另一個 opt-in 的 timer。

## 另見

- [Disk / filesystem 監控](disk.md) — 金屬之上的檔案系統層
- [Service health](services-health.md) — `health-check` 早晨總覽（OS 側）
- [本 repo 提供的 helper](helpers.md#hardware) — `hw-*` 對照表
