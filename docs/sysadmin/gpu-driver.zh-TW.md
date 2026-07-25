# GPU 驅動（NVIDIA 專有）—— 版本漂移、升級與內顯

**GPU 工作站**的 sysadmin 問題：**什麼都沒改，為什麼 `nvidia-smi` 突然壞了？要怎麼阻止背景更新在訓練跑到一半時再做一次？**

本頁記錄 `nvidia-driver-drift-check` 輔助工具、`52unattended-upgrades-local` 黑名單，以及這台機器的顯示拓撲。它是 [hardware.md](hardware.md) 往上一層（到驅動）的姊妹篇，也對應 [scheduled-jobs.md](scheduled-jobs.md)（觸發那次升級的就是它）。

> 僅適用於 Linux + NVIDIA 專有驅動。Nouveau 與純 AMD 機器不受本頁任何內容影響。

## 一張表看懂故障模式

NVIDIA 專有驅動是**必須版本一致的兩半**，而執行中只有其中一半能被替換：

| | userspace（`libcuda.so`、`libnvidia-ml.so`） | kernel module（`nvidia.ko`） |
|---|---|---|
| 執行時的本體 | 磁碟上的**檔案**，各 process 各自 mmap | 載入 kernel 位址空間的**程式碼** |
| 能否多版本並存 | ✅ 可以 —— 每個 process 映射自己那份 | ❌ 不行 —— 只有一份，獨佔 PCI 裝置 |
| `apt upgrade` 做了什麼 | `unlink` + 建新檔。unlink 只刪**名字**，只要還有 process 映射著，inode 就活著 | 什麼都沒做 —— 記憶體裡那份原封不動 |
| 如何換版 | 不需任何動作，新 process 自然拿到新檔 | `rmmod`，需要 refcount **歸零** |

所以升級對**所有已在執行的 process 完全透明**，對**之後啟動的每一個 process 都是致命的**：

```
Failed to initialize NVML: Driver/library version mismatch
NVML library version: 580.173
```

CUDA 的 `cuInit` 回傳 **804**（`CUDA_ERROR_COMPAT_NOT_SUPPORTED_ON_DEVICE` —— 不是 803，803 才是 `CUDA_ERROR_SYSTEM_DRIVER_MISMATCH`）。

**唯一的修復是重新開機。** 在螢幕由同一張 GPU 驅動的機器上，沒有「重載模組」這條路 —— Xorg、gnome-shell、mutter 以及每一個 GPU 加速的應用程式都開著 `/dev/nvidia*`，`modprobe -r nvidia` 只會回 `Module nvidia is in use`，refcount 是好幾百。

### 讓人意外的不對稱性

**往回走**不需要重開機。把新 process 指向**舊的** userspace，它就會跟仍然載入著的舊模組一致：

```bash
# 暫時性、per-process，不安裝到系統
mkdir -p /tmp/nvshim && cd /tmp/nvshim
apt-get download nvidia-utils-580=<舊版本> libnvidia-compute-580=<舊版本>
for f in *.deb; do dpkg-deb -x "$f" root/; done
LD_LIBRARY_PATH=$PWD/root/usr/lib/x86_64-linux-gnu root/usr/bin/nvidia-smi
```

這能救回 `nvidia-smi`，也能讓新的 CUDA process 啟動，且完全不影響執行中的 job。但它**修不了** OpenGL/EGL/Vulkan（shim 裡沒有 `libGLX_nvidia`/`libEGL_nvidia`），而且 `nvtop` 會靜默降級成只顯示內顯。請把它當成監控用的權宜之計，不是修復 —— 每一個用它啟動的 process 都會再 pin 住一個已刪除的 inode，把「不能重開機」的窗口愈拉愈長。

> 舊版本很快就會從 archive pool 消失。當 `apt-get download <pkg>=<舊版>` 開始回 404 時，`snapshot.ubuntu.com` 是可靠的來源。
>
> **`/proc/driver/nvidia/version` 一變就要立刻拆掉 shim**，而不是「重開機之後」—— 一旦模組換新，shim 會造成反方向的不一致，而錯誤訊息長得一模一樣。

## 漂移偵測

`nvidia-driver-drift-check` 比對載入中的模組與磁碟上的 userspace，不一致時回傳非零。

```bash
nvidia-driver-drift-check          # 完整 banner + 列出重開機會殺掉哪些 process
nvidia-driver-drift-check --quiet  # 只印一行，便宜到可以掛在 shell 啟動
```

| | |
|---|---|
| 讀取 | `/sys/module/nvidia/version`（fallback `/proc/driver/nvidia/version`）對比 `/usr/lib/*-linux-gnu/libnvidia-ml.so.<ver>` |
| exit 0 | 一致，**或根本沒載入 NVIDIA 驅動**（所以在任何機器上無條件執行都安全） |
| exit 1 | 漂移 —— 新的 CUDA process 會失敗 |
| 消音單一漂移 | `echo "580.159.03->580.173.02" > ~/.cache/nvidia-drift-ack` —— 任一版本改變就自動恢復警告 |

**為什麼 `--quiet` 不列 process**：`fuser /dev/nvidia0` 要走遍整個 `/proc`（本機約 240 ms）。漂移在重開機前無法解除，所以每開一個 terminal 就噴 17 行 banner，只會訓練你忽略它。一行，不跑 `fuser`。

透過 `~/.config/zsh/tools/60_nvidia_drift.zsh` 掛到 shell 啟動。**不要**放 `/etc/update-motd.d/` —— 腳本寫的是 stderr，而 `run-parts` 只把 stdout 收進 `/run/motd.dynamic`，banner 根本不會出現，卻在每次登入多花 240 ms。

## 預防：讓 unattended-upgrades 別碰驅動

`/etc/apt/apt.conf.d/52unattended-upgrades-local` 把驅動整套列入黑名單。用編號較高的 drop-in，而不是改 `50unattended-upgrades` —— 後者是 conffile，每次升級都會跳出詢問。

四個很容易寫錯的語法事實：

| 規則 | 原因 |
|---|---|
| apt.conf 的 list 是**附加**，永遠不是覆蓋 | `50unattended-upgrades` 附的 `Package-Blacklist` 是空的，所以 drop-in **就是**最終清單。`#clear` 才是刪除。 |
| **開頭不要 `^`** | u-u 會把每條轉成 APT pin `'/^' + regex + '/'` → 變成 `/^^nvidia-/` |
| **結尾不要 `$`** | multiarch 名稱帶 `:i386`（如 `libnvidia-compute-580:i386`），`$` 比不到 |
| pattern 走 Python `re.match` | 只錨定開頭，**不**錨定結尾 |

驗證最終生效的清單，並用真實套件名模擬比對：

```bash
apt-config dump Unattended-Upgrade::Package-Blacklist   # 沒輸出 = 語法錯
sudo unattended-upgrade --dry-run --debug 2>&1 | grep -iE 'blacklist|nvidia'
```

> `--dry-run` 對執行中的訓練是安全的 —— 所有 commit 點都包在 `if not dry_run:` 裡，它只設 `Debug::pkgDPkgPM=1`。

**刻意不列入黑名單的**：`nvidia-settings`、`nvidia-prime`、`libnvidia-egl-wayland1` 是 Ubuntu main 的套件，版本與驅動分支無關 —— 它們該繼續拿安全更新。用大範圍的 `^nvidia-`/`^libnvidia-` 會把它們一起凍住。

**這只擋得住 unattended 路徑。** PackageKit / gnome-software **不會**讀 `Unattended-Upgrade::Package-Blacklist`；桌面更新程式若列出 nvidia 套件，請取消它，改走下面的儀式。`apt-mark hold` 兩邊都能擋，代價是連你自己有意識的升級也一起擋掉，而且每次 apt 都會印 "kept back"。

> 真要用 `apt-mark hold`，清單請用 `${binary:Package}` 而不是 `${Package}` —— 後者會丟掉 arch 限定詞，靜默地讓每個 `:i386` 套件沒被 hold 到，而那正好是驅動的一半。

## 安全升級儀式

裝了黑名單之後，驅動更新會靜默累積。每月做一次：

```bash
sudo apt update && apt list --upgradable 2>/dev/null | grep -i nvidia
fuser -v /dev/nvidia*                  # 排空：不能有使用者程序
sudo apt full-upgrade
dkms status | grep nvidia              # 必須涵蓋你接下來要開的那個 kernel
sudo reboot                            # <- 永遠被跳過的那一步
nvidia-driver-drift-check && nvidia-smi
```

第 5 步才是重點。升級在 06:02 落地、重開機兩週後才發生，就是本頁存在的原因。

> 第 3 步別寫成 `apt install --only-upgrade '~nnvidia'` —— `~n` 是**不錨定的子字串**比對，會掃進所有名稱含 "nvidia" 的套件，transaction 比看起來大得多。

## 長時間執行的 GPU 工作

從終端機模擬器啟動的多日訓練，活在**那個終端機的 cgroup** 裡（`/user.slice/.../app-gnome-alacritty-<pid>.scope`）。關掉視窗或登出就沒了 —— `nohup` 只擋 SIGHUP。

```bash
tmux new -s train 'bash run.sh'
# 或
systemd-run --user --scope --unit=train bash run.sh
loginctl enable-linger $USER
```

按下重開機之前，先確認代價：

```bash
fuser -v /dev/nvidia*                                    # 所有握著 GPU 的東西
nvidia-smi --query-compute-apps=pid,used_memory --format=csv
```

## 這台機器的顯示拓撲（David-Ubuntu）

| | |
|---|---|
| dGPU | `01:00.0` NVIDIA GA102 [RTX 3090] `10de:2204` —— **驅動唯一有接線的輸出**（`card1-HDMI-A-1`） |
| iGPU | `0c:00.0` AMD Raphael `1002:13c0` —— BIOS 有開，**沒接任何螢幕**，所有輸出皆 `disconnected` |
| `prime-select` | `on-demand` |
| Session | X11 |

**沒有 iGPU fallback。** 若 NVIDIA 那一套無法拉起 X，這台機器就完全沒有畫面。這正是「就地升級驅動」在這裡特別危險的原因：從升級到重開機之間，Xorg 握著約 94 個已刪除的 mapping（`libglxserver_nvidia.so.<舊>`、`libEGL_nvidia.so.<舊>`…），而**任何** X 重啟 —— 登出、切換使用者、`systemctl restart gdm3`、suspend —— 回來時都會用新的函式庫去配舊的模組，直接黑畫面。

### amdgpu 在 kernel 7.0.0-28 上是壞的（已 blacklist）

```
amdgpu: vga_switcheroo: detected switching method \_SB_.PCI0.GP17.VGA_.ATPX handle
amdgpu: ATPX version 1, functions 0x00000000
amdgpu 0000:0c:00.0: probe with driver amdgpu failed with error -22
```

ATPX 是**筆電混合顯示卡**的 ACPI 切換介面。這塊桌機主機板在桌上型晶片上暴露了它，而且 function bitmask 全為零，amdgpu 隨即以 `EINVAL` 放棄。firmware 是齊的（不是缺韌體），而 6.17.0-35-generic 對同一顆硬體 probe 正常 —— 這是 7.0 的迴歸。

更麻煩的是這個失敗是**不確定的**。當 amdgpu 半初始化成功（而非乾脆失敗）時，桌面 session 會卡在 dbus 啟動重試上超過 20 分鐘：

```
amdgpu 0000:0c:00.0: [drm] *ERROR* Not enough memory for command submission!
dbus-daemon: Failed to activate service 'org.freedesktop.Notifications': timed out
```

有一次這樣的開機花了 **57 分鐘**才進到可用的桌面。因此：

```bash
echo 'blacklist amdgpu' | sudo tee /etc/modprobe.d/blacklist-amdgpu.conf
sudo update-initramfs -u -k all
```

零成本 —— 內顯沒接螢幕，本來就沒有任何貢獻。

### 把螢幕改插到內顯會比較好嗎？

那會把桌面的 VRAM 從 3090 上釋放出來，但那是 **24576 MiB 裡的約 464 MiB（1.9%）**—— Xorg 112、gnome-remote-desktop 260、gnome-shell 24，其餘都是個位數。不會是 OOM 與否的分水嶺。

真正的理由是**隔離**：訓練 OOM 不再把桌面一起拖走、桌面合成不再搶 SM 時間，以及最關鍵的一點 —— **可以重啟 X 而不碰 GPU**，這會徹底消除上面那個黑畫面陷阱。

目前卡在 amdgpu 的 `-22` probe 失敗。等之後的 kernel 修好、或在 amdgpu 正常的 6.17.0-35 上，可以再考慮。

## 相關

- [scheduled-jobs.md](scheduled-jobs.md) —— `apt-daily-upgrade.timer`，執行 unattended-upgrades 的就是它
- [hardware.md](hardware.md) —— 機殼/主機板感測器，再往下一層
- `~/.dotfiles/bin/nvidia-driver-drift-check`
- `/etc/apt/apt.conf.d/52unattended-upgrades-local`
- `/etc/modprobe.d/blacklist-amdgpu.conf`
