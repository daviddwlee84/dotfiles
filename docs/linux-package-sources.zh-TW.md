# Linux Package Sources: apt vs Linuxbrew vs snap vs GitHub binaries

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

這個 repo 在 Linux 上混用了多個套件來源 (package source)。本文件解釋每個各擅長什麼、取捨在哪、以及 ansible 角色 (role) 採用的政策。

這些 package manager 是**互補的、不是替代品**。為每個工具選對來源，就是讓這套 dotfiles 在 `ubuntu_desktop`、`ubuntu_server`、`noRoot` profile 之間都能保持快速、可攜、安全的關鍵。

## 並排比較

| 面向 | apt | snap | Linuxbrew | GitHub binary |
|---|---|---|---|---|
| 版本新鮮度 | 差（LTS freeze） | 中–佳 | **佳**（接近 upstream） | 佳 |
| 需要 sudo | 是 | 是（+ snapd daemon、需要 systemd） | 安裝時需要（`chown /home/linuxbrew`） | **不需要** |
| 跨 macOS | 僅 Linux | 僅 Linux | **與 macOS Homebrew 共用 formula 名稱** | 若 upstream 有出 binary |
| Sandboxing | 無 | **AppArmor + 嚴格 interface** | 無 | 無 |
| 啟動 / 資源成本 | 最低 | 高（squashfs mount + 每個 snap 自帶 lib） | 中（bottle 帶自己的 lib path） | 最低 |
| 系統服務 / daemon | **最佳** | 可，但受限於 confinement | 差（`brew services` 在 Linux 上是實驗性） | 手動 |
| Catalog 廣度 | 最大 | 中（GUI 為主） | CLI / dev 工具強 | 一個來源一個工具 |
| 升級控制 | 隨 distro 升級 | 自動 refresh（很難乾淨地關閉） | 明確 `brew upgrade`（rolling） | 手動 / 由 ansible 驅動 |
| 磁碟佔用 | 小（共用 lib） | 大（重複 lib、保留先前版本） | 中（~/.linuxbrew 通常 10–15 GB） | 小 |
| 損壞風險 | 低（distro 維護者把關） | 中（靜默 refresh 可能改變行為） | 低（rolling、明確） | 低 |
| 在 `noRoot` 模式可用 | ❌ | ❌（snapd 需要 sudo + systemd） | ⚠️ 有不被支援的 `~/homebrew` 模式但會失去 bottle → 需要 `libevent-dev` 等 → 又繞回 sudo | ✅ |

## 依工具類型挑選

| 工具類型 | 偏好來源 | 為什麼 |
|---|---|---|
| 現代 CLI dev 工具（tmux、neovim、ripgrep、fd、zoxide、starship、eza、yazi、sesh、television） | **Linuxbrew**（有 sudo）；**GitHub binary**（在 `noRoot`） | 版本最新、與 macOS `Brewfile.darwin` 共用 formula 名稱、不必跟 confinement 摩擦 |
| 系統 daemon / 跟 kernel 或 systemd 相關的工具（Docker Engine、OpenSSH server、NetworkManager、CUDA、nvidia 驅動） | **apt** | snap sandbox 跟主機整合的 daemon 對著幹；brew 在 Linux 系統服務上沒有方案 |
| Sandboxed 或封閉原始碼 (closed-source) GUI（Slack、某些 IDE、Bitwarden Desktop） | **snap** / flatpak / 廠商 `.deb` | brew-linux 沒有 cask；apt 版本落後；snap 的自動更新 + confinement 適合 |
| 語言 runtime（Node、Python、Ruby、Rust） | **mise**（已採用） | 多版本、project-aware、user-level——這個任務任何 OS package manager 都比不過 |
| 語言生態系 CLI 工具（`uv tool`、`gem`、`cargo install`、`npm -g`） | **語言工具本身** | upstream 最新、自動解析生態系相依、安裝到 user prefix |
| 完全無 sudo 的環境 | **GitHub binary + mise + 語言工具** | 這個 repo 的 `noRoot=true` 分支 |

## Linuxbrew vs apt

**偏好 Linuxbrew 當：**

- 工具在 macOS 也安裝（與 `Brewfile.darwin` 共用心智模型）。
- apt 版本對這個 repo 的設定來說太舊（例：tmux：Ubuntu 22.04 出貨 3.2a，但我們的 popup menu 需要 ≥ 3.3——見 [tools/tmux/README.md](tools/tmux/README.md)）。
- 你想要明確、滾動式 (rolling) 升級，而不是等下一個 distro 釋出。

**留在 apt 當：**

- 工具是系統 daemon、或需要 PAM / systemd / `/etc/shells` 整合（例：`zsh`、`openssh-server`、`docker.io`）。
- 機器磁碟受限——apt 共用系統 lib，brew 帶自己的整套。
- 無人值守安全更新比版本新鮮度更重要。

## Linuxbrew vs snap

兩者涵蓋不同範圍。如果被迫選一邊：

- **CLI 工具 → Linuxbrew。** Snap-confined 的 CLI 經常因 AppArmor interface 規則而讀取 `~/.config`、`~/.ssh`、`/tmp` 或其他 dotfile 出問題。啟動慢（squashfs mount + confinement 強制執行）對於頻繁呼叫的工具也很明顯。
- **GUI 應用程式 → snap。** 適合 confinement 模型；對不需深入存取檔案系統的互動式應用程式來說，自動更新很順。

## Repo 政策

總結 ansible 角色如何選擇工具安裝路徑：

```
macOS:
  Homebrew (CLI + cask), mas for App Store, mise for language runtimes.

Linux with sudo (ubuntu_desktop, ubuntu_server):
  a) CLI dev tools      → apt baseline; Linuxbrew upgrade when available
                          (or when apt version fails our minimum)
  b) System daemons     → apt
  c) Sandboxed GUI      → snap or flatpak or vendor .deb
                          (dotfiles role does not manage these beyond what
                          Brewfile.linux and explicit snap tasks touch)
  d) Language tooling   → mise / uv / cargo / gem / npm

Linux noRoot (ubuntu_server + noRoot=true):
  GitHub release binaries → ~/.local/bin (prefer musl over gnu)
  AppImage (extracted)    → ~/.local/share/<tool>/
  mise + language tools   → ~/.local/bin, ~/.local/share
```

### GitHub binary asset 選擇政策

當工具從 GitHub release 安裝時（不論作為系統層級來源或 user-level `noRoot` fallback），ansible role 依以下順序選擇：

1. **優先 `unknown-linux-musl`**（armhf 用 `musleabihf`）asset，當 upstream 有出。Musl binary 靜態連結 (statically linked) libc，因此能在 kernel 能 boot 的任何 glibc 版本上跑。
2. **只有在沒有 musl asset 時用 `unknown-linux-gnu`**，並在 role 中以註解明確說明 fallback 理由。Gnu binary 繼承 upstream CI 用的 glibc 版本，現代 `ubuntu-latest` runner 已經比 Ubuntu 22.04 LTS 出貨的還新。
3. **若該架構沒有安全的 musl asset，偏好 Linuxbrew**（若主機上有）。Homebrew bottle 追蹤的 glibc baseline 比隨機 upstream CI image 還舊，所以 `brew install <tool>` 通常比最新的 gnu release binary 安全。
4. **若 Linuxbrew 也沒有，就用明確的 `debug:` 訊息跳過**而不是靜默安裝可能在使用者 libc 上跑不起來的 binary。跳過訊息應點名工具、架構、並告訴使用者要不要安裝 Linuxbrew，要不要等 upstream 出 musl build。

### 範例：Ubuntu 22.04 上的 glibc 相容性

Ubuntu 22.04 LTS 出貨 **glibc 2.35**。一些 Rust / Go 工具現在產生的 `unknown-linux-gnu` release tarball 連結 glibc 2.38 或 2.39，因為它們的 CI 跑在 `ubuntu-latest`（Ubuntu 24.04）或 Debian 13。本 repo 中出現過具體的例子：

```
❯ tv sesh
tv: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.39' not found (required by tv)
```

`devtools` role 過去盲目抓 `tv-<version>-<arch>-unknown-linux-gnu.tar.gz` 在新裝的 Jammy box 上就失敗。修法——以及在 repo 中所有類似情況沿用的模式——是：

- **television** — upstream 沒出 musl asset → 有 Linuxbrew 時 brew-install，否則用指向 `GLIBC_2.X` 錯誤的 debug 訊息跳過。
- **yazi、fd** — upstream 有出 musl asset → sudo 與 noRoot 路徑都改用 `unknown-linux-musl.{deb,zip,tar.gz}`。
- **git-delta、eza** — upstream 只在 x86_64 出 musl → x86_64 用 musl；aarch64 走「brew or skip」路徑。
- **trippy** — 每個支援架構都有 musl target → 系統層級路徑與使用者 fallback 都對齊到 `*-unknown-linux-musl`。

這呼應一般「install 與 upgrade 拆開是有意為之」的理念，見 [CLAUDE.md → Hard repo invariants](../CLAUDE.md#install-vs-upgrade-is-split-on-purpose)：`chezmoi apply` 永遠不該因為安裝了跑不起來的 binary 而驚嚇 (surprise) 一台正在運行的機器。

如果在 apply 完這個 repo **之後**碰到 `GLIBC_2.X not found`（例：musl 切換之前裝下的舊 binary、或之後加入卻偷溜回 gnu 的工具），請看症狀優先 (symptom-first) 的恢復條目 [ansible_customization.md → `GLIBC_2.XX not found`](this_repo/ansible_customization.md#glibc_2xx-not-found-when-running-an-installed-cli-ubuntu-2204--older-distros)。

### 範例：tmux

一個上述政策派得上用場的具體案例：

1. apt 在 Ubuntu 22.04 上裝 tmux 3.2a。
2. 設定用了 `display-menu -x R -y P`，但 3.2a 會靜默抑制（man page 寫著：_"If the menu is too large to fit on the terminal, it is not displayed."_）。
3. devtools role 跑版本檢查並升級：
   - 有 Linuxbrew → `brew install tmux`（3.5a+）。
   - 否則在 x86_64 → 下載 [`nelsonenzo/tmux-appimage`](https://github.com/nelsonenzo/tmux-appimage)，解壓（不需 FUSE），把 shim 放到 `~/.local/bin/tmux`。
   - 否則（非 x86_64 + 無 brew）→ 印警告；使用者必須從原始碼編譯或啟用 Linuxbrew。

每當 apt 出貨的工具對 dotfiles 設定來說太舊時，都套用這個模式。

## 為什麼不「全部都用 Linuxbrew」？

- **磁碟：** `/home/linuxbrew` 10–15 GB 對 VM / server 來說不算小。
- **系統服務：** brew 沒辦法乾淨地取代 `systemctl` 管理的套件。
- **首次開機成本：** 每次 Linux 部署都要付 brew-install 時間，即使 90% 的工具用 apt 還更快。
- **二等公民平台：** Homebrew 自己的文件把 Linux 當「best-effort」；Linux-only bottle 有時落後 macOS。`brew services` 是實驗性。
- **比起 apt 沒有 sandbox 好處** — 兩者都以使用者（或 root）身分跑，有完整檔案系統存取。

## 為什麼不「全部都用 snap」？

- **CLI 工具在 confinement 下吃苦頭** — 嚴格限制 (strictly-confined) 的 btop snap 一啟動就崩潰，因為 AppArmor 擋住了 `~/.config/btop/themes` 的讀取（見 [tools/btop.zh-TW.md](tools/btop.zh-TW.md)）。Classic snap 雖然逃出 sandbox，但下面其他缺點一個不少。
- **Refresh 驚喜** — snap 預設按你不完全控制的節奏自動 refresh；CI 或部署腳本若依賴特定 CLI 版本可能一夜之間壞掉。
- **啟動慢** — 對每個 shell session 呼叫多次的工具（shell prompt、completion script）影響顯著。
- **Server profile 避開 snapd** — `ubuntu_server` 刻意把 snapd 排除在外。

## 這個 repo 的 snap 使用現況

現況：**只剩一個 role 透過 snap 安裝東西** —— Bitwarden Desktop
（`dot_ansible/roles/bitwarden/tasks/main.yml`，由 `installBitwarden` prompt
控管，snap 優先、廠商 `.deb` fallback）。這是刻意的：封閉原始碼的 GUI
應用程式正是 snap 的自動更新 + confinement 模型最適合的類別（見上方依工具
類型挑選的表格）。其他一切都不走 snap。

### 為什麼 Neovim role 移除了 snap 路徑（2026-06）

2026 年 6 月之前，neovim role 有一個中間層：apt 太舊 + PATH 上有 `snap`
→ `snap install nvim --classic`。它被移除了（apt 太舊現在直接走 GitHub
release tarball → `/opt/nvim` + `/usr/local/bin/nvim` symlink），因為這個
snap 層和 repo 自己的規則互相矛盾：

1. **自動 refresh 違反 [install/upgrade 拆分原則](https://github.com/daviddwlee84/dotfiles/blob/main/CLAUDE.md#install-vs-upgrade-is-split-on-purpose)。**
   Snap 按 snapd 的排程自我更新——nvim 可能一夜之間換版本，繞過明確的
   `just upgrade-*` 路徑。Repo 裡沒有任何其他工具會隱式升級。
2. **政策矛盾。** 本頁明明寫著 server profile 把 snapd 排除在外、CLI
   工具路由到 Linuxbrew / GitHub binary——但一台原廠 `ubuntu_server`
   devbox（apt nvim 太舊 + snapd 預裝）卻落在 snap 層。
3. **`~/snap` 弄髒 home** —— 觸發這次檢討的症狀：`$HOME` 裡突然冒出
   `~/snap/nvim` 目錄（見下方）。
4. **前科紀錄。** 這個 repo 已被 CLI 工具的 snap 版本燙過兩次：chezmoi
   snap 的 stdin/stdout bug（`scripts/init/dotfiles_init.py` 會主動偵測並
   避開）、以及 btop snap 的 AppArmor 崩潰
   （[pitfalls/btop-themes-permission-denied-core-dumped.md](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/btop-themes-permission-denied-core-dumped.md)）。
5. `nvim` snap 是社群發佈的（一位 Canonical 員工），不是 Neovim 官方
   專案的產物；GitHub tarball 才是 upstream 自己的 release。

Tarball 層早就久經考驗——它本來就是「沒有 snap 可用」的 fallback 和
noRoot 使用者層級路徑——所以這次變更只是刪掉中間層，沒有引入任何新機制。

### 值得留存的 snap 知識

- **`~/snap/<name>/` 是 snapd 的 per-user 資料目錄**，snap 第一次執行時
  自動建立。結構：`~/snap/<name>/<revision>/`（該 app 的版本化
  `$HOME`）、`current` symlink、`common/`（跨 revision 的資料）。它*不是*
  安裝目錄——binary 住在 `/snap/` 底下——所以看到它不代表東西裝錯位置。
  它出了名地無視 XDG 慣例（upstream bug 從 2016 年開到現在；有一個實驗性
  `hidden-snap-folder` 選項可移到 `~/.snap`，但從未成為預設）。
- **`classic` vs 嚴格 confinement**：strict snap 跑在 AppArmor 裡，只開放
  白名單 interface（這就是 dotfile 讀取會壞的原因——`home` interface 擋掉
  `~/.config` 之類的隱藏目錄）。`--classic` snap 不受限制地執行，像一般
  套件——nvim snap 是 classic，所以它的問題從來不是 sandbox，而是
  refresh / 弄髒 home / 發佈者歸屬。
- **可以 hold refresh，但不是我們的政策**：`sudo snap refresh --hold`
  （snapd ≥ 2.58）無限期凍結所有更新，`--hold=72h` 可以針對單一 snap 限時
  hold。Repo 偏好不依賴每台主機的 snapd 狀態——不准動的工具改由 apt /
  tarball 提供。
- **磁碟 / 清理**：snapd 會保留先前 revision（`refresh.retain`，預設
  2–3 個），所以再小的 CLI 也要花 2 倍 squashfs 空間，外加每個一個 loop
  mount。

### 清理之前裝過 snap nvim 的主機

變更之前部署的主機照常運作（role 的版本檢查會通過，所以什麼都不動），
要手動收斂的話：

```bash
sudo snap remove nvim          # binary + /snap/nvim revisions
rm -rf ~/snap/nvim             # per-user 資料目錄（安全：nvim 狀態其實住在 ~/.config/nvim 等處）
# 然後重新 apply，讓 role 安裝 tarball 層：
chezmoi apply    # 或：just fleet-apply <host>
```

只刪**該 app 的**目錄，不要刪整個 `~/snap`——在 `ubuntu_desktop` 主機上
`~/snap` 可能存著其他 snap 的真實使用者資料（例如預裝的 Firefox snap 把
整個 profile 放在那裡）。

## 相關文件

- [glibc-and-musl.zh-TW.md](glibc-and-musl.zh-TW.md) — GitHub binary 報 `GLIBC_2.X not found` 時，musl 替換 vs Linuxbrew vs distrobox vs OS 升級的決策樹
- [this_repo/ansible_customization.md](this_repo/ansible_customization.md) — 如何執行與自訂 ansible role
- [tools/tmux/README.md](tools/tmux/README.md) — tmux ≥ 3.3 需求與 fallback 安裝
- [this_repo/architecture.md](this_repo/architecture.md) — 「Ansible vs Homebrew」段落、依 tag 的工具拆分
