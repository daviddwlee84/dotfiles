# macOS swap、memory pressure 與「系統資料」膨脹

當「關於本機 > 一般 > 儲存空間」顯示出 30+ GB 你從沒手動建立的「系統資料」/
「其他」，而重開機後又馬上回收回來時，你不是在幻想——這是 macOS 動態 VM
子系統按設計運作的結果，只是運作得**有點積極**。

本頁說明背後實際發生了什麼、如何不靠猜測地診斷，以及如何在 macOS 允許的範圍內
不重開機就回收空間（限制部分見 [pitfall 頁面][pitfall]）。

[pitfall]: https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/macos-swap-files-never-shrink.md

## TL;DR

三個指令，依序執行：

```sh
mac-mem-status                         # 診斷：誰在吃 RAM 與磁碟？
mac-mem-reclaim --dry-run              # 預覽永遠安全的清理動作
mac-mem-reclaim                        # 執行安全清理
mac-mem-reclaim --include snapshots    # 加碼：也清掉 TM 本機快照
```

日常用短別名：**`mms`** = `mac-mem-status`、**`mmr`** = `mac-mem-reclaim`、
**`mmw`** = `mac-mem-watch`。Script 裡用全名（非互動 shell 不解析 alias）；
terminal 互動時用短別名。

如果做完之後 swap 還是 10+ GB、磁碟還是吃緊——**重開機**。
macOS 沒有 userspace API 可以縮小執行中系統的既有 swapfile；這不是
workaround 失效，是 OS 設計選擇（見[為什麼重開機真的就是答案](#為什麼重開機真的就是答案)）。

要在 tmux 旁邊面板裡開個 live tail 邊抓凶手：

```sh
mac-mem-watch                          # 5 秒一拍；Ctrl+C 結束
mac-mem-watch 2                        # 2 秒一拍（更靈敏，更吵）
```

要 fuzzy 挑選最重的 process（含 kill / inspect 動作），僅 macOS 主機可用：

```sh
tv mac-procs
```

四者都在本 repo 裡：
[`dot_config/shell/55_macos_mem.sh.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/shell/55_macos_mem.sh.tmpl)
+ [`dot_config/television/cable/mac-procs.toml.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/television/cable/mac-procs.toml.tmpl)。

---

## 心智模型：macOS VM 實際是怎麼運作的

### Activity Monitor / `vm_stat` 裡的五個「桶子」

| 桶子 | 是什麼 | 可以回收嗎？ |
|---|---|---|
| **Wired** | 被 kernel 釘在實體 RAM 裡——driver、kernel data structure、`kernel_task` 的 working set。**不能** page out。 | 只有殺掉要它的 process（多半就是 kernel 自己，所以：不行）。 |
| **App / Active** | 目前在用的 user process pages。 | 需要時透過 compressor 或 swap page 出去。 |
| **Inactive** | 最近用過但目前沒在用。第一個被 compress / swap 的對象。 | 是——壓力上升時自動處理。 |
| **Compressed** | 被 WKdm compressor 原地壓縮過的 app memory（沒寫到磁碟）。典型壓縮比 ~50%。 | 下次存取時 decompress。算「使用中」但很便宜。 |
| **Cached Files** | 在 RAM 裡 cache 的磁碟 pages。Activity Monitor 顯示為 "Cached Files" / `vm_stat` 顯示為 `file-backed`。 | 是——`sudo purge` 會 flush 掉。下次讀取時 lazily 重建。 |

你 Activity Monitor 截圖顯示 **6.78 GB Compressed**——那是 ~13 GB 的
app memory 壓縮前資料、住在 6.78 GB 的實體 RAM 裡。這是系統按設計運作。
Compressor 是 Mavericks (10.9, 2013) 加進來的，**取代**舊式「什麼都丟去 swap」
做為第一道防線。

### macOS 什麼時候才真的把資料寫到磁碟 swap？

只有在 compressor 跟不上時——也就是「熱」memory 多到連壓縮過的 page 都得被
驅逐。此時 macOS 才會寫到 `/System/Volumes/VM/swapfile{0..N}`（Apple Silicon /
Big Sur+）或 `/private/var/vm/swapfile{0..N}`（較舊 / 前 APFS）。

Swapfile 增長模式：

1. 第一個 swapfile **64 MB**。
2. 接下來每個翻倍：128 MB → 256 MB → 512 MB → **上限 1 GB**。
3. 按需求新增；唯一上限是**剩餘磁碟**。
4. **macOS 執行中時 swapfile 永遠不會被刪掉。** 即便你關掉所有 memory hog、
   壓力降回 0，這些檔案還是留在磁碟上吃空間。下次壓力上升時會被重複使用。
5. 重開機會刪掉所有 swapfile；首次需要時再建立一個全新的空 64 MB swapfile。

這就是「系統資料一夜暴增」抱怨的根源。你截圖的 17.59 GB swap = 17 個
1 GB swapfile + 1 個部分填滿。

### `sleepimage`：另外那 16 GB 你不知道的存在

`/private/var/vm/sleepimage` 存在是為了支援 **safe sleep**（在 Apple Silicon 的
`hibernatemode 25` 叫「hibernation」、舊 Intel 叫 "deep sleep"）。當系統進入
延長睡眠——或是電池快沒電的睡眠中——kernel 會把**整個實體 RAM 的快照寫到磁碟**，
之後就算硬斷電也能還原。

大小：**等於實體 RAM**。你 16 GB Mac mini 上就是 16 GB 躺在
`/private/var/vm/sleepimage`，就算你從不讓它 hibernate。

| Mac 類型 | 預設 `hibernatemode` | 磁碟上有 sleepimage？ | 可以安全刪嗎？ |
|---|---|---|---|
| Apple Silicon 筆電 (M1/M2/M3 MBP/MBA) | `25` (hibernate) | 有 (~RAM 大小) | **不行**——電池死光 = session 沒了 |
| Apple Silicon 桌機 (Mac mini/Studio/Pro) | `0` (no hibernate) | 沒有 | n/a |
| Intel 筆電 (2019-2020 MBP) | `3` (safe-sleep) | 有 (~RAM 大小) | **不行**——同樣風險 |
| Intel 桌機 (iMac/Mac Pro) | `0` | 沒有 | n/a |

如果你的 Activity Monitor 顯示 `Swap Used: 17 GB` 而磁碟「系統資料」比 swap 多 +16 GB，
sleepimage 就是嫌疑犯。用 `ls -lh /private/var/vm/sleepimage` 確認。
**筆電上請別動它。** 桌機接電源時，見[回收方案](#回收方案) sleepimage 段落。

### 「其他」/ Time Machine 本機快照

只要設定過 Time Machine（即便暫停），macOS 每小時就會對 `/` 拍一張本機 APFS
快照、保留 24 小時，方便你在沒有外接硬碟的情況下回滾近期變更。這些快照算在
「儲存空間圓餅圖」的「其他」區，因為它們住在獨立的 APFS snapshot list 而不在你的
home 目錄。

每張快照的*表面*大小很巨大（看起來像整顆磁碟），但*獨佔*大小很小（只算變動的
block）。用 `tmutil thinlocalsnapshots` 回收——見[回收方案](#回收方案)。

### Memory Pressure 綠色 ≠ swap 很小

這是最常見的誤解。Memory Pressure 圖表測的是 **compressor 此刻有多忙**。
經過一波重壓（多個瀏覽器 tab、大型 build、VM）後，pressure 在數秒內回到綠色——
但這波寫進去的 swap 檔案會**永久留在磁碟上**直到重開機。

這就是為什麼你 14.29 GB Used + 6.78 GB Compressed + 綠/黃 pressure 可以跟
17.59 GB swap 共存：OS 安然渡過尖峰，但磁碟配置直到重開機都不會釋放。

## 診斷食譜

本 repo 的 `mac-mem-status` 把多數整合在一頁——但想再深挖時，下面是底層指令。

### Memory 端

| 指令 | 回答什麼 |
|---|---|
| `vm_stat` | 各 page class（free / active / inactive / wired / compressor / file-backed / anonymous）的單次快照。所有計數單位是 page——乘以 `sysctl -n hw.pagesize`（Apple Silicon 16384、Intel 4096）才是 bytes。 |
| `vm_stat 5` | 每 5 秒的累計計數。`pageins` / `pageouts` / `swapins` / `swapouts` 欄位是*自開機累計*——要算「每秒」得對兩列做差。本 repo 的 `mac-mem-watch` 替你算好。 |
| `sysctl vm.swapusage` | 目前 swap total / used / free。格式：`total = 17408.00M  used = 15958.75M  free = 1449.25M  (encrypted)`。`(encrypted)` 純資訊——Apple Silicon 永遠加密 swap。 |
| `memory_pressure` | Kernel 自己的壓力通知器。預設一直跑；`memory_pressure -Q` 是新 macOS 的單次查詢版本。 |
| `top -l 1 -o mem -n 20` | 按 memory 排前 20。`mem` 欄位**含壓縮資料**（對應 Activity Monitor 的「Memory」欄）。所有 macOS 版本都不需 sudo。 |
| `ps -axm -o pid,rss,vsz,user,comm` | 較舊的純 RSS 視角。RSS **不**包含壓縮或 swap 過的 pages，會誤導——優先用 `top -o mem`。 |
| `sudo footprint -all -s --swapped --sort=swapped` | 僅 Apple Silicon。每個 process 的 **swapped + compressed** 拆解，按 swapped pages 排序。最適合「誰真的把 page 推到磁碟」的工具。`-s` 跳過 idle process。需 sudo。 |
| `sudo footprint -p <pid> --swapped` | 單 PID 詳細 memory map。檢視單一凶手時用。 |

### Swap 與磁碟端

| 指令 | 回答什麼 |
|---|---|
| `ls -lh /System/Volumes/VM/swapfile* 2>/dev/null` | Apple Silicon / 新 Intel 的 swapfile 大小。 |
| `ls -lh /private/var/vm/swapfile* 2>/dev/null` | 舊 Intel 的 swapfile 大小。（Apple Silicon 上是空的 stub。） |
| `du -ch /System/Volumes/VM/swapfile* 2>/dev/null \| tail -1` | 磁碟上 swap 總和。 |
| `ls -lh /private/var/vm/sleepimage` | sleepimage 大小——啟用 hibernation 時等於 RAM。 |
| `pmset -g \| grep hibernatemode` | 目前 hibernate 模式（0 = 無 sleepimage、3 = Intel safe-sleep、25 = Apple Silicon hibernate）。 |
| `df -Hh /` | 系統卷的剩餘磁碟。 |
| `system_profiler SPStorageDataType` | About > 儲存空間圓餅圖的 CLI 漂亮版。 |
| `tmutil listlocalsnapshots /` | / 上的 Time Machine 本機快照。 |
| `diskutil apfs listSnapshots /` | 同上，含大小。 |

### 即時活動

| 指令 | 回答什麼 |
|---|---|
| `mac-mem-watch [N]` | 每拍一行的摘要：free / compressed / swap_used / pageouts/s / swapouts/s。最適合 tmux 旁邊面板。 |
| `vm_stat 1` | 1 秒一拍的純 vm_stat。盯著 `swapouts` 欄——持續 > 0 表示有實際磁碟 swap。 |
| `sudo fs_usage -w -f filesys \| grep '/var/vm\\|/System/Volumes/VM'` | 即時 syscall trace 過濾 swap I/O。吵但確定。 |
| `latency -rt 5` *(需 root)* | Kernel latency 事件含 memory pressure stall。 |

## 回收方案

按最便宜 → 最破壞性排序。本 repo 的 `mac-mem-reclaim` 包了步驟 1–5；其餘為了完整性收錄。

### 1. 關掉明顯的凶手（免費、即時）

跑 `mac-mem-status`（或 `tv mac-procs`）。榜首幾乎永遠是：

- 開了 50+ tab 的瀏覽器（Chrome / Arc / Firefox）
- Electron app（Slack / Discord / 裝很多 extension 的 VSCode / Obsidian）
- Xcode + `SourceKitService`（長時間編輯 session 後常 leak 5-10 GB）
- 多顯示器 + 多日 uptime 後的 `WindowServer`
- 重新索引中的 `mds_stores` / `mdworker_shared`（剛裝大 app 或複製大量檔案後）

關掉再開單一 Electron app 常常釋放 1-2 GB。關掉開很多 tab 的瀏覽器可以
立刻釋放 5+ GB。

### 2. `sudo purge`（免費、即時、永遠安全）

```sh
sudo purge
```

強迫 kernel flush 磁碟 cache（"Cached Files" 桶）。典型工作站可回收 1-3 GB。
重複執行也安全。**不**動 swap 檔案、**不**殺任何 process——可以放心從 script 跑。

`mac-mem-reclaim` 預設第 1 步就是這個。

### 3. 重啟 Spotlight indexer（免費、~1 分鐘 CPU 尖峰）

```sh
sudo killall mds_stores
sudo killall mdworker_shared
```

如果 `mdworker_shared` 進你 RSS top-10，多半是卡在壞檔或巨大目錄上。
launchd 立刻重生兩者；它們會從零重啟 indexing job（CPU 尖峰 ~1 分鐘後 idle）。
通常回收 500 MB - 2 GB（如果 worker 膨脹的話）。

`mac-mem-reclaim --include spotlight`。

### 4. 修剪 Time Machine 本機快照（免費、~10 秒）

```sh
tmutil thinlocalsnapshots / 5000000000 4
```

刪除 / 上的本機 TM 快照，直到至少回收 **5 GB**（第二參數），urgency **4**
（最高——最積極的 thinning）。安全：你的*外接* TM 備份不受影響，只動磁碟上的
本機副本。視情況回收 0（無快照）到 30+ GB（重度使用、好久沒重開機）。

`mac-mem-reclaim --include snapshots`。

### 5. 停用 hibernation + 刪掉 sleepimage（~RAM 大小、**筆電有警告**）

```sh
sudo pmset -a hibernatemode 0       # 停用 hibernation
sudo rm -f /private/var/vm/sleepimage
```

回收 `~實體 RAM` GB。**桌機 (mini/Studio/Pro 接電源)**：沒有副作用——它們本來就
不用 sleepimage。**筆電**：你會失去 **safe-sleep**，意思是如果電池在睡眠中死光，
你會失去 session 與所有未存檔工作。

`mac-mem-reclaim --include sleepimage`（confirmation prompt 把關；同時帶
`--yes` 時還要 `--force` 才能跳過 prompt）。

筆電要重新啟用：`sudo pmset -a hibernatemode 3`（Intel）或
`sudo pmset -a hibernatemode 25`（Apple Silicon）。

### 6. 重啟 `WindowServer`（~500 MB - 3 GB、**會把你登出**）

```sh
sudo killall -HUP WindowServer
```

`WindowServer` 是 macOS compositor。在多顯示器 + 多視窗的 workload 下會慢慢 leak。
重啟會登出當前 GUI session——**先存好所有未存檔工作**。

`mac-mem-reclaim --include windowserver`（雙重 confirmation prompt；同時帶
`--yes` 時還要 `--force` 才能跳過）。

### 7. 重開機（大鐵鎚）

回收：

- 所有 `/System/Volumes/VM/swapfile*`（swap 段全部）
- `/private/var/vm/sleepimage`（下次睡眠時重建）
- 所有過了保留窗口的 Time Machine 本機快照
- 所有 `purge` 沒清掉的 in-memory cache
- 任何 user-process 或 kernel-extension 的 memory leak

如果做完步驟 1-6 後 `儲存空間 > 系統資料` 還是膨脹，就是這個答案。
下一節說明為什麼這不是 workaround 失效。

### 該 AVOID 的事

| 別做 | 為什麼 |
|---|---|
| `sudo nvram boot-args="vm_compressor=2"` | 舊論壇有時建議用這個「停用 compressor」。Apple Silicon 上會**搞壞整個 VM 子系統**——OS 假設 compressor 一定存在。會在開機時 hard-hang。 |
| 切換 `sudo dynamic_pager -L 0` | 老 (10.6 時代) 的強制 swapfile 清理招式。新 macOS 上要嘛沒效要嘛 hard-hang kernel——swap 子系統的清理決策已經不再經過 `dynamic_pager`。 |
| macOS 執行中時直接用 `sudo rm /System/Volumes/VM/swapfile*` 刪 swapfile | Kernel 已經透過 `mmap` 開著它們；刪掉只是 unlink directory entry，kernel 還是會繼續寫入這個現在沒名字的 inode 直到重開機。完全沒釋放磁碟，還可能搞壞被 page out 的 process。 |
| 停用 swap | macOS 在 Apple Silicon 上沒有支援的「無 swap」模式。別嘗試。 |
| App Store 的第三方「memory cleaner」app | 多數只是呼叫 `sudo purge`（你自己免費就能做），再用裝飾性圖表灌水結果。有些會積極殺 process，造成資料遺失。 |

## FAQ：「我就只是想清掉 swap 而已」

短答：**做不到，除非重開機。** 這是初次遇到 macOS swap 累積最常見的錯誤期待，
所以這裡完整列出選項矩陣：

| 方法 | 風險 | 能回收 swapfile？ | 評語 |
|---|---|---|---|
| **重開機** | 無（除了打斷工作） | ✓ 100% —— kernel 把它們全砍掉 | **唯一乾淨的方案。** |
| 關掉 memory 大戶（瀏覽器 / Electron / VM）然後等 | 無 | ✗ —— 釋放 RAM + compressor，但磁碟上的 swapfile 仍在 | 降低*未來* swap 成長，不會縮小現況 |
| `sudo killall -HUP WindowServer` | 中 —— 登出，未存檔 GUI 工作沒了 | ✗（只釋放 ~1-3 GB RAM） | 既然要登出，不如直接重開機 |
| `mac-mem-reclaim`（本 repo） | 低 —— wrap `sudo purge` + opt-in 加碼 | ✗ —— 動 cache、snapshot、sleepimage；從不動 swapfile | 回收*周邊*儲存；可以爭取時間，不會縮小 swap |
| `sudo dynamic_pager -L 0` 切換 | **高 —— 新 macOS 上 kernel hang** | ✗ | **別碰。** 老 10.6 時代招式，現在已失效。 |
| 執行中時 `sudo rm /System/Volumes/VM/swapfile*` | **高 —— process corruption** | ✗ —— kernel 還透過 `mmap` 開著；`unlink` 不會釋放磁碟 | **別碰。** 釋放 0 空間，可能搞壞被 swap 出去的 process。 |
| 完全停用 swap（無支援的 flag） | **Apple Silicon 災難級** | n/a | Apple Silicon 的 VM 子系統假設 swap 存在。別碰。 |
| App Store「memory cleaner」app | 浮動 —— 多數是 `sudo purge` 包裝 | ✗ | 騙錢。沒有任何一個能縮小 swapfile —— Apple 沒這個 API。 |

**為什麼會這樣**：macOS 把 swap 當作開機時清掉的 ephemeral state。沒有 public
kernel API 可以叫 `dynamic_pager(8)` 刪指定 swapfile、沒有 `swapoff` 對應、
沒有 sysctl 觸發收縮。對比 Linux（`swapoff -a` 把 page 遷回 RAM 然後 unlink
swap）或 Windows（registry + 重開機調整 pagefile）—— 兩者都有使用者可控的
swap 回收；macOS 刻意不做。

**實務結論**：預防 > 治療。如果你的 workload 定期累積 10+ GB swap：

1. **排程每週重開機**（例如週一早上開工前）。
2. **盯著 `mms`** —— 看到 `CRITICAL — REBOOT RECOMMENDED`，那就是 OS 告訴你
   「下次大記憶體尖峰就會搞掛某個 app」的緩衝區用完了。
3. **找出長期凶手**：用 `tv mac-procs` 觀察幾個 session。如果 Arc / Discord /
   特定 Electron app 永遠在前面，考慮原生替代品或不要同時開那麼多。

本 repo 的 `mac-mem-reclaim` 在 `disk_free < 3%` 時會拒絕執行 —— 不是因為
reclaim *危險*，而是因為會*沒用*（這個程度下 `purge` 通常只釋放 < 100 MB，
但真正的問題是只有 `reboot` 能處理的 GB 級 swap）。要硬幹用 `--force`，但
reboot 比較快。

## FAQ：「那一直開著的 Linux server 怎麼辦？」

短答：**完全不一樣 —— Linux server 一開始就沒 macOS 的問題。** Linux server
能跑超過一年不被 swap 拖垮的四個原因：

### 1. Linux swap 執行中*可以*縮回去

```sh
sudo swapoff -a && sudo swapon -a
```

這個 idiom 在 Linux 是合法的。`swapoff` 把每個被 swap 出去的 page 遷移**回
RAM**（前提：RAM 夠裝）然後 unmap swap device，接著 `swapon` 重新 attach 一個
空的。沒有資料遺失、沒有 process corruption、不需重開機。macOS *沒有*對應的
東西 —— 沒有 public API 可以把 swapfile drain 回 RAM。

### 2. Linux swap 是 fixed-size

典型安裝：安裝時設定的 swap *partition* 或 *file*（一般是 RAM 的 0.5-2x，
上限約 8-16 GB）。它**不會**像 macOS swapfile 那樣動態吃掉剩餘磁碟。
用滿了就觸發 OOM killer；swap 配置本身永遠不會膨脹。

macOS「系統卷剩下多少 GB 都能變成 swap」的 model 才是「系統資料吃光磁碟」這個
症狀的根源 —— 也就是這頁存在的理由。

### 3. Linux 暴露 `vm.swappiness`

```sh
sysctl vm.swappiness=10   # 預設 60；越低越偏好 evict cache 而非 anon page
```

Server 調校通常落在 10-30，把 anonymous（app）memory 留在 RAM 久一點，讓 file
cache 先被回收。macOS 沒有暴露這個 knob —— 它的 compressor + dynamic_pager
pipeline 對使用者不可調。

### 4. Linux 長 uptime 真正會遇到的問題*個別可處置*

| 問題 | 對策 |
|---|---|
| 特定 service memory leak | `systemctl restart <service>`（單個 service，不是整機） |
| `journald` 磁碟用量 | `journalctl --vacuum-size=500M` 或 `--vacuum-time=30d` |
| `/tmp` / `/var/tmp` 累積 | `systemd-tmpfiles --clean`（多數發行版每天自動跑） |
| Docker image / volume / build cache | `docker system prune -a --volumes` |
| Slab cache 膨脹（罕見） | `echo 2 \| sudo tee /proc/sys/vm/drop_caches` |
| Kernel 安全更新 | *唯一*真正需要重開機的東西 —— 且 RHEL / SLES / Ubuntu Pro 上可用 `kpatch` / `livepatch` 規避 |

Linux server 一年以上 uptime 很常見，因為**每種資源都有對應的回收工具**。
macOS 為了 UX 簡單把這些全砍了，代價就是「每週重開機」變成標準答案。

### 對本 repo fleet 的實務意義

[`scripts/fleet_apply.py`](https://github.com/daviddwlee84/dotfiles/blob/main/scripts/fleet_apply.py)
同時對 macOS 與 Linux 主機跑。重開機節奏不一樣：

| 主機類型 | 監控 | 膨脹時的動作 |
|---|---|---|
| macOS（Mac mini / 筆電） | `mms` 顯示 `CRITICAL` | **重開機**（沒別的辦法） |
| Linux server（IDC / NAS / VPS） | `free -h`、`vmstat 1`、`journalctl --disk-usage`、`df -h` | **針對性回收**（`swapoff -a && swapon -a` 處理 swap；`systemctl restart` 處理 leak service；`journalctl --vacuum-*` 處理 log；`docker system prune` 處理 container）。重開機只給 kernel update。 |
| Linux desktop（本 fleet 罕見） | 同 server | 同 server |

未來會做一個 `linux-mem-status` / `linux-mem-reclaim` helper，在 Linux 端鏡像
`mac-mem-*` 的 ergonomics，用相同的 diagnose / dry-run / opt-in 形狀暴露針對性
回收工具。記在 [TODO.md](https://github.com/daviddwlee84/dotfiles/blob/main/TODO.md)
P3 下。

## 為什麼重開機真的就是答案

很容易把「重開機就解決」讀成 Windows-9x 時代的認輸。不是。這是 macOS 刻意的
設計權衡：

1. **Apple 選擇了簡單而不是回收複雜度。** Linux 可以用 `swapoff` 縮小 swap
   （把 page 搬回 RAM、RAM 不夠就失敗）。Windows 可以用 reg-key + 重開機縮小
   pagefile。macOS 選的是：「我們從不費心——重開機很便宜，反正我們筆電睡眠遠多於
   重啟」。
2. **Compressor 大幅減少了 swap 的*必要性***（往往比 pre-compressor macOS 少
   3-5× swap traffic），所以「swap 檔案累積、重開機回收」這個偶發狀況很少
   被使用者注意到——除非磁碟本來就吃緊，比如你的截圖。
3. **沒有 public API 可以叫 kernel 刪 swapfile-N。** 不是 `sysctl`、不是
   `vm_pressure_monitor`、不是 Endpoint Security。Apple 的 `dynamic_pager`
   daemon 決定何時*建立* swapfile，但從不決定執行中*刪除*。

**實務意涵**：如果你的日常 / 週常 workflow 因為 swap 累積而定期吃光磁碟，
答案是**排程重開機**，不是繞著 OS 工程化。Activity Monitor 的 Memory tab 是
指示器；你 `mac-mem-status` 的 Verdict 行就是觸發點。

本 repo 推薦 workflow 的常見重開機節奏：

- **電池 daily-driver 筆電**：每週重開一次就夠——睡眠循環本來就會把 swap 維持在
  適中範圍（OS 知道可能會 hibernate 時會比較保守地用 memory）。
- **永遠開著的工作站 / Mac mini server**：每 2-4 週重開、或 `mac-mem-status`
  變紅時重開。
- **重 VM / 重 Docker 開發機**：每 1-2 週。VM + container 把 swapfile 攪動得很厲害；
  即便 compressor 維持 50% 比例，一週也會累積 10-20 GB swapfile。

## 預防與監控

### Menubar / GUI 工具（比較）

| 工具 | License | 有 menubar swap meter？ | 免費 | 備註 |
|---|---|---|---|---|
| [**Stats.app**](https://github.com/exelban/stats) | MIT | 有 | ✓ | exelban/stats。原生 Swift、活躍維護、Apple Silicon 原生。**推薦。** 安裝：`brew install --cask stats`。本 repo 的 `Brewfile.darwin.tmpl` 預設沒裝——cask 候選評估記在 [TODO.md](https://github.com/daviddwlee84/dotfiles/blob/main/TODO.md)。 |
| [iStat Menus](https://bjango.com/mac/istatmenus/) | proprietary | 有 | $ | 最精緻；買斷付費。 |
| [MenuMeters](https://github.com/yujitach/MenuMeters) | LGPL | 有 | ✓ | yujitach fork；較舊但穩。 |
| Activity Monitor (內建) | — | 沒 menubar | ✓ | Memory tab 顯示 pressure 圖 + Swap Used。 |

**為什麼推薦 Stats.app vs 其他**：MIT license（無專利綁定）、零設定 Apple
Silicon 支援、swap + pressure 在 1 行 menubar widget 都看得到、~30 MB RAM
footprint。Stats.app 唯一弱點是沒有 kernel/wired 拆解——你還是要用
`mac-mem-status` 看那個。

### CLI / TUI monitor

| 工具 | 已在本 repo？ | 顯示 swap？ | 備註 |
|---|---|---|---|
| [`btm`](https://github.com/ClementTsang/bottom) | 是——`devtools` ansible role | 是 | 最佳通用 TUI。按 `?` 看 keymap。 |
| `htop` | 是——`devtools` | macOS 預設沒 swap 欄 | 按 `F2` 啟用 swap 欄（如果可用）。 |
| `btop` | 是——`devtools` | 是 | UI 比 `btm` 重；同樣資料。 |
| Activity Monitor | 內建 | 是（Memory tab） | 真理之源；其他工具都是它的重新格式化。 |

### 不推薦

- **別停用 swap。** 即便在 64 GB Mac Pro 上，compressor 配 swap backing 比較
  有效率——見 Apple 的 `xnu` source 對 `compressor_pool_size` 的註解。
- **別在你會帶出門的筆電上停用 `sleepimage`。** 睡眠中電池死光 = session 沒了，
  沒有警告。
- **別從 launchd timer 每分鐘跑 `purge`。** 安全但會攪動磁碟 cache；你會失去
  cache 存在的效能好處。
- **別從你不在旁邊看的 script 殺 `WindowServer`。** 未存檔 GUI 工作會死。

## 陷阱與已知 gotcha

完整 case study（症狀、診斷、root cause、不該嘗試什麼）見
[`pitfalls/macos-swap-files-never-shrink.md`][pitfall]。
短版：swapfile 只在重開機時刪掉。沒有支援的 workaround。`mac-mem-reclaim`
helper 刻意不放任何「執行中時刪 swapfile」的步驟，因為所有已知做法不是靜默失敗就是
冒著 corruption 風險。

其他值得知道的 gotcha：

- **`top -o mem` 在 Apple Silicon 顯示的是 compressed-aware footprint** 在
  `mem` 欄，但欄位 header 還是寫 "MEM"，沒有任何提示包含什麼。Apple docs 沒提；
  這是經 `footprint -summary <pid>` 經驗驗證的。
- **`ps -o rss` 在 Apple Silicon 上會誤導。** RSS 是傳統 Unix 意義上的
  "resident set size"——目前在實體 RAM 裡的 page。**不**包含 compressed 或
  swapped pages。一個 100 MB RSS 的 process 後面可能藏著 2 GB 的 compressed +
  swapped 資料。要看真相用 `top -o mem` 或 `footprint -summary`。
- **`vm.swapusage` 的 `total` 會增不會減（執行中）。** `total` 欄位是已配置
  swap 的高水位、不是「目前設定值」。`used` 才是即時數字；`free = total - used`
  只告訴你已配置 swapfile 的剩餘空間。
- **`memory_pressure` 沒帶 `-Q` 會永遠跑。** 新 macOS 的 man page 加了 `-Q` 做
  單次查詢；舊版沒有。`mac-mem-status` helper 在 `-Q` 不支援時會 fallback 到
  streaming 輸出的 `head -3`。
- **`tmutil thinlocalsnapshots` 在沒設定 TM 時是 no-op。** 靜默 exit 0。不是
  錯誤——只是沒東西可修剪。
- **Apple Silicon swap 永遠加密。** swap I/O 會多一點點 CPU 成本但無法停用。
  別擔心 `vm.swapusage` 輸出裡的 `(encrypted)` 標籤。

## 參考資料

### 在本 repo

- [`dot_config/shell/55_macos_mem.sh.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/shell/55_macos_mem.sh.tmpl) — 三個 helper（`mac-mem-status` / `mac-mem-reclaim` / `mac-mem-watch`）
- [`dot_config/television/cable/mac-procs.toml.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/television/cable/mac-procs.toml.tmpl) — `tv mac-procs` 頻道
- [`pitfalls/macos-swap-files-never-shrink.md`][pitfall] — 案例研究
- [`docs/shells/aliases.zh-TW.md`](../shells/aliases.zh-TW.md) — 一行摘要表含三個 helper
- [`docs/tools/tv.zh-TW.md`](tv.zh-TW.md) — 頻道參考含 `mac-procs`

### Apple / 官方

- `man vm_stat` — page-class 定義
- `man memory_pressure` — pressure 子系統語意
- `man footprint` — Apple Silicon 每 process memory accounting（唯一暴露每 process swapped + compressed bytes 的 first-party 工具）
- `man pmset` — `hibernatemode` 值與 trade-off
- `man tmutil` — local-snapshot 子命令
- `man purge` — 磁碟 cache flush
- [Apple Developer: Memory Usage Performance Guidelines](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/ManagingMemory/Articles/AboutMemory.html) — 較舊但 wired/active/inactive model 仍正確

### 社群文章（背景閱讀）

- [Eclectic Light: Memory and swap](https://eclecticlight.co/?s=memory+swap) — howard oakley 系列，最佳非 Apple writeup
- [xnu source: `osfmk/vm/vm_compressor.c`](https://github.com/apple-oss-distributions/xnu) — WKdm compressor 實作
- xnu 的 `system_cmds` package 裡 `top` source 註解了每個欄位讀哪個 sysctl

---

**保留英文 verbatim**（不翻譯）：所有 CLI 名稱、檔案路徑、env var、JSON key、
flag、`brew`/`tmutil`/`pmset`/`sysctl`/`footprint` 等指令、`compressor` /
`compressed` / `swap` / `swapfile` / `sleepimage` / `pressure` / `wired` /
`active` / `inactive` / `cached` / `cache` / `Activity Monitor` / `WindowServer` /
`Spotlight` / `mds_stores` / `mdworker_shared` / `Time Machine` / `tab` /
`session` / `process` / `kernel` / `daemon` / `launchd` / `prompt` / `flag` /
`fallback` / `gotcha` / `case study` / `workaround` / `compressor pool size` /
`hibernate` / `safe-sleep` 等技術名詞 verbatim。
