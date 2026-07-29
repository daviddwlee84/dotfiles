# Linux GUI 應用程式 —— 打包機制、本 repo 的策略，以及如何新增

Ubuntu 對桌面應用 (desktop apps) 有**五種**打包機制 (packaging mechanisms)。它們在*二進位檔案落點*、*是否有東西讓它們保持最新*、以及*桌面整合（圖示、`.desktop`、MIME handlers）如何串接*上各有不同。

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

本文件：

1. 列出五種機制與權衡矩陣 (trade-off matrix)，
2. 盤點本 repo 的 `gui_apps_linux` ansible role 知道的每一個 GUI 應用（外加你大概透過 Ubuntu App Center 安裝的那些 snap），讓你能一眼看出每個應用走的是哪條路徑，
3. 給出將*新*應用加入該 role 的決策樹。

## TL;DR —— 五種機制，一張權衡矩陣

| Mechanism | Auto-update? | Install scope | Desktop integration | Sandbox |
|---|---|---|---|---|
| **`.deb` w/ apt-source postinst** | ✅ 透過 `apt upgrade` | 系統範圍 (`/usr/share/...`) | ✅ 內建 | ❌ |
| **`.deb` w/o apt-source postinst** | ❌ 手動重新部署 | 系統範圍 | ✅ 內建 | ❌ |
| **Snap**（Ubuntu App Center） | ✅ `snapd` 背景常駐程式 | `/snap/<app>/<rev>/` | ✅ 內建 | ✅ confined |
| **Flatpak**（Flathub） | ✅ `flatpak update` | 每使用者 `~/.var/app/...` | ✅ 內建 | ✅ confined |
| **AppImage + AppImageLauncher** | ❌ 重新下載 | 每使用者 `~/Applications/` | ✅ 透過 AIL 常駐程式 | ❌ |
| Cargo / 從原始碼編譯 | ❌ 透過 `cargo install --force` | 每使用者 `~/.cargo/bin/` | ❌ 手動寫 `.desktop` | ❌ |
| Tarball / `.tar.xz` | ❌ 純手動 | 每使用者（任何位置） | ❌ 手動 | ❌ |

**綠勾的 `.deb` 列是金標準**（前提是上游 (upstream) 有提供）。Snap 和 Flatpak 是不出 `.deb` 的廠商（或想要沙箱）的自動更新後備。AppImage 是其他人的最後一哩橋樑。

## Ubuntu 上的優先順序

上方矩陣是*每種機制做什麼*。下方列表是*當你有選擇時要挑哪一種* —— 這是當廠商以多種格式發佈時，本 repo 遵循的明確排序：

1. **`.deb` w/ auto apt-source** —— `apt upgrade` 讓它保持最新，零沙箱開銷且原生啟動速度。對於熱路徑 (hot-path) 應用（編輯器、終端機、瀏覽器、日常工具）這是正確答案。
   範例：Cursor、VSCode、Chrome、Signal、1Password、Slack。
2. **Flatpak (Flathub)** —— 乾淨的沙箱、跨發行版友善、啟動比 Snap 快、透過 `flatpak update` 自動更新。當缺 `.deb` 或廠商只在 Flathub 發佈時為對。需要限制 (confinement) 的社群打包應用的預設建議。
3. **Snap** —— 透過 `snapd` 設定即忘 (set-and-forget) 的自動更新（每天 4 次、不需使用者動作）。對於非熱路徑應用，多 1-3s 的啟動延遲看不見的場合可接受（密碼管理員、音樂播放器）。避免用於熱路徑應用；每日的啟動成本會累積。
4. **AppImage + AppImageLauncher** —— 當 1-3 都無法用時。除非套件附帶 `.zsync` 且 AppImageLauncher 的更新檢查已設定，否則不會自動更新。重新跑我們的 ansible 任務是典型的更新路徑。
5. **Cargo / 原始碼編譯 / tarball** —— 最後手段。手動全部、沒有 apt/snap/flatpak 更新路徑。只有當上游真的只發佈原始碼時才用。

> **為什麼不"永遠用 Snap"？** Snap 看起來類似 macOS 的 Homebrew Cask，但這個比較有誤導性。Snap apps 住在 `/snap/<app>/<rev>/`，掛載為 squashfs，且每次啟動都會啟動 AppArmor 沙箱 —— Firefox snap 在 SSD 上開機要 ~2-3s，相對於 `.deb` 的 ~0.3s。沙箱也會預設打破微妙的工作流程（snap Bitwarden 沒有 `snap connect bitwarden:password-manager-service` 就讀不到 `~/.ssh`；許多 snap 看不到外接硬碟）。對於偶爾使用的應用這些成本看不見；對於日常使用（瀏覽器、IDE、終端機）則是真正的困擾。Snap *沒問題* —— 只是它不是 macOS 使用者有時從 Cask 經驗推測的萬能解。請依上述列 1-3 挑選。

## 本機 GUI 應用清單

### Ansible 管理（本 repo）

| App | Mechanism | Auto-update? | Source-of-truth | Where it lives |
|---|---|---|---|---|
| **Cursor** | `.deb`（自動加入 `/etc/apt/sources.list.d/cursor.sources`） | ✅ `apt upgrade cursor` | [`gui_apps_linux/tasks/main.yml`](../../dot_ansible/roles/gui_apps_linux/tasks/main.yml) "Install Cursor via .deb" | `/usr/share/cursor/` |
| **VSCode** | `.deb`（自動加入 `vscode.sources`） | ✅ `apt upgrade code` | 同 role | `/usr/share/code/` |
| **Google Chrome** | 來自 `dl.google.com` 的 `.deb`（postinst 自動加入 `google-chrome.list` ＋ `/usr/share/keyrings/google-chrome.gpg`）；**僅限 x86_64** —— Google 沒有發佈 arm64 的 Linux 版 | ✅ `apt upgrade google-chrome-stable` | 同 role，"Install Google Chrome via .deb" | `/opt/google/chrome/` |
| **Discord** | `flatpak`（預設、推薦）或 `.deb`（無 apt source）—— 由 `discordChannel` chezmoi prompt 挑選 | ✅ 透過 `flatpak update`（預設）/ ❌ `.deb` 為手動 | 同 role | `~/.local/share/flatpak/app/com.discordapp.Discord/`（flatpak）或 `/usr/share/discord/`（.deb） |
| **Steam** | Valve apt repo（`steam-launcher`），由 `installGamingApps=true` 與 x86_64 控制 | ✅ launcher/runtime 套件透過 apt；Steam client 啟動時自我更新 | 同 role | `/usr/lib/steam/` + `/usr/share/applications/steam.desktop` |
| **Zen Browser** | AppImage 在 `~/Applications/`，下載時叫 `zen.AppImage`，但用 glob `zen*.AppImage` **比對**（AppImageLauncher 會把整合過的改名成 `zen_<md5>.AppImage`）；從 `zen-browser/desktop` latest release 以精確名稱 `zen-<arch>.AppImage` 挑 asset | ❌ —— 先刪掉所有 `~/Applications/zen*.AppImage` **再**重跑 role（任何殘留的副本都算已安裝） | 同 role | glob 當下命中的那個；`.desktop` 每次 apply 都據此重寫。profile 在 `~/.zen/`（跨版本共用，升級不可逆） |
| **Alacritty** | `cargo install alacritty` | ❌ —— `just upgrade-cargo` | [`devtools` role](../../dot_ansible/roles/devtools/tasks/main.yml) | `~/.cargo/bin/alacritty` |
| **AppImageLauncher** | `.deb`（22.04 用 PPA、24.04 用 GitHub release） | ✅ 透過 apt | 同 role | system + `appimagelauncherd.service`（user） |
| **Bitwarden CLI** (`bw`) | 透過 mise 用 npm 安裝（由 `installBitwarden=true` 控制） | ❌ —— `just upgrade-mise` | [`bitwarden` role](../../dot_ansible/roles/bitwarden/tasks/main.yml) | `~/.local/share/mise/...` |
| **Bitwarden Desktop** | Snap (`bitwarden`) → 若 `snap` 不可用則退回 `.deb`；由 `installBitwarden=true` AND `profile=ubuntu_desktop` 控制 | ✅ 透過 `snapd` 背景重整（後備 `.deb` 則 `apt upgrade`） | 同 role | `/snap/bitwarden/current/` |

### 手動管理（你自己安裝、ansible 之外）

| App | Mechanism | Auto-update? | How it got there | How to upgrade |
|---|---|---|---|---|
| **Spotify** | Snap（發佈者 `Spotify**`） | ✅ 背景 | Ubuntu App Center | `snap refresh spotify` |
| **Firefox** | Snap（自 Ubuntu 22.04 起 canonical 預設） | ✅ 背景 | OS 預先安裝 | `snap refresh firefox` |
| **btop** | Snap（kz6fittycent） | ✅ 背景 | 手動 | `snap refresh btop` |
| **Frpc Desktop** | AppImage 在 `~/Applications/Frpc-Desktop-1.2.1.AppImage` | ❌ —— 手動重新下載 | 手動丟入 | 覆寫該檔案 |
| **Clash for Windows** | tarball 在 `~/Documents/ClashForWindows/` ⚠️ | ❌ **上游已棄用** | 2025 手動解壓 | **遷移** —— 見下方 |

> **Clash for Windows 已死。** 原作者 (Fndroid) 於 **2023-11** 公開停止維護，GitHub repo 已封存。沒有新版本、沒有 CVE 修補。請遷移到任一個有維護的 fork：
>
> - [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev) —— 活躍 fork、出 .deb + AppImage
> - [Clash Nyanpasu](https://github.com/libnyanpasu/clash-nyanpasu) —— 基於 Tauri 的 GUI、AppImage + .deb
> - [Mihomo Party](https://github.com/mihomo-party-org/mihomo-party) —— CFW UX 的接班人、AppImage + .deb
>
> 三者都發佈 `.deb` 套件 —— 依下方 [`.deb` 模式](#concrete-patterns) 將新應用加入 `gui_apps_linux`，並在新應用串接好之後刪除 `~/Documents/ClashForWindows/`。

## 為何 `.deb` 自動更新有效（apt-source postinst 技巧）

當 `dpkg -i cursor_<v>_amd64.deb` 跑時，Cursor 的套件包含一個 `DEBIAN/postinst` 腳本，成功時會寫入：

- `/etc/apt/sources.list.d/cursor.sources` —— 指向 `https://downloads.cursor.com/aptrepo`
- `/usr/share/keyrings/anysphere.gpg` —— 簽署金鑰

之後，`apt update` 會在拉取 Ubuntu 自己的索引同時拉取 Cursor 的 release index，而 `apt upgrade cursor`（或一般的 `apt upgrade` / `just upgrade-system`）會像對待其他 apt 套件一樣處理它。使用者再也不必回去 cursor.com。

你可以對任何已安裝的 `.deb` 驗證這點：

```sh
dpkg -L cursor | grep -E 'sources|keyring'
# /etc/apt/sources.list.d/cursor.sources
# /usr/share/keyrings/anysphere.gpg
```

VSCode、Chrome、Signal、1Password、Slack、Microsoft Edge、Brave 全都遵循這個模式。**Discord 不遵循** —— 見下一節。

## Discord 自動更新 —— 為何那個截圖一直出現

Discord 的 `.deb` **沒有**附帶會加入 apt source 的 postinst：

```sh
dpkg -L discord | grep -E 'sources|keyring'
# (empty)
```

因此 `apt upgrade` 永遠不知道有新的 Discord 版本。Discord 的 in-app 更新器偵測到版本不符，但在 Linux 上它無法實際呼叫 `dpkg`（沒 root） —— 於是它彈出*"Must be your lucky day, there's a new update!"* 的對話框，附帶一個只會打開廠商下載頁的 "Download" 按鈕。然後你必須手動 `dpkg -i` 新的 `.deb`。

三條出路：

1. **按需重新跑 ansible 任務**：`chezmoi apply`（該 role 每次 apply 都會透過 Discord 的 API 重新抓最新 `.deb` URL）。我們對 Cursor 也這麼做，所以一致。
2. **改用 Flatpak**：`flatpak install flathub com.discordapp.Discord`。Flatpak 透過 `flatpak update` 自動更新。會失去一些原生整合（透過 XDG portal 的通知、透過 PipeWire 的螢幕分享），但升級故事乾淨。
3. **改用 Vesktop / WebCord**（自帶自動更新的社群 Discord 客戶端）。會偏離官方 Discord；除非你已經在跑 modded Discord，否則不推薦。

**本 repo 預設選項 2（Flatpak）** —— 由 `discordChannel` chezmoi prompt 控制（`flatpak | deb | none`，預設 `flatpak`）。該 role 的 flatpak 路徑：

1. 若缺則 apt 安裝 `flatpak` 套件（一次性、需要 sudo）
2. 在使用者層級加入 Flathub remote（無需 sudo）
3. 在使用者層級安裝 `com.discordapp.Discord`（無需 sudo）

要在既有機器上從 `.deb` 切換到 `flatpak`：在 `~/.config/chezmoi/chezmoi.toml` 設定 `discordChannel = "flatpak"` 並執行 `chezmoi apply --tags gui_apps`。兩種安裝可短暫共存（不同 `.desktop` 條目）；驗證 Flatpak 版本後，`sudo apt remove discord` 清掉舊的 `.deb`。

## Steam —— 為何用 Valve 的 apt repo，而非 Flatpak/Snap

Steam 由 `installGamingApps=true` 控制，目前只在 x86_64 的 Ubuntu Desktop 上
安裝。Valve 在 `https://repo.steampowered.com/steam/` 提供官方 apt 倉庫；該 role
從 `archive/stable/steam.gpg` 安裝簽章金鑰、啟用 `i386`、以 deb822 格式加入倉庫，
然後安裝 `steam-launcher`。

`i386` 架構是刻意的：Steam 的 launcher 與許多遊戲仍需要 32-bit runtime 函式庫。
不要在 role 裡硬寫舊指南裡的 Mesa 套件名（例如 `libgl1-mesa-glx`）；Ubuntu 24.04
已不再出貨該套件。讓 `steam-launcher` 自己拉取當前的 dependencies 與 recommends。

Flathub 的 `com.valvesoftware.Steam` 存在，但它是社群封裝、且明確不是 Valve 支援的
路徑；它也需要額外的檔案系統 override 才能存取非預設磁碟上的函式庫。若本 repo 日後
新增 `steamChannel` prompt，仍應以 Valve apt 為預設。

## Snap (Ubuntu App Center) —— 實際發生什麼

Ubuntu App Center 是 `snapd` 的 GTK 前端 —— Canonical 的通用套件管理員，從 Snap Store 出貨 `.snap` 封存檔。當你從 App Center 安裝 **Bitwarden** 或 **Spotify** 時：

- `.snap` 檔案被解壓到 `/snap/<app>/<rev>/`（有版本、唯讀）
- 符號連結 `/snap/<app>/current` 永遠指向當前 rev
- `/snap/bin/<app>` 的包裝腳本是 `$PATH` 真正抓到的東西
- 一個使用者 systemd 服務 `snapd.refresh.service` 每天 ~4 次檢查更新並在背景套用
- 桌面整合 (`/var/lib/snapd/desktop/applications/<app>.desktop`) 自動產生；snap-store 常駐程式在重整時更新這些

這表示 **Bitwarden Desktop 與 Spotify 會自我保持最新、無需手動動作** —— 跟 `apt upgrade` 不會自動跑、但 apt-source `.deb` 透過你既有的 `just upgrade-system` 節奏保持最新一樣，snap 透過 `snapd` 的*永遠開著*重整常駐程式保持最新。不同典範、相同結果。

要查看：`snap list`、`snap info <app>`、`snap refresh --list`（待更新）、`snap refresh <app>`（強制立即重整）、`snap revert <app>`（回滾到前一個 rev —— 有版本的 `/snap/<app>/<rev>/` 配置的好處）。

> 注意：snap 在限制沙箱中執行，可能打破進階使用者的工作流程（例如預設無法存取 `~/.ssh`）。多數桌面應用沒問題；CLI 工具有時不行。當 `.deb` 或 apt 兩個選項都存在時，優先選那個。

## AppImage + AppImageLauncher —— 萬用備胎

當上游只發佈 AppImage（Zen Browser、Cursor 的舊 AppImage、許多獨立工具）時，我們的慣例是：

1. **下載用穩定檔名，但永遠不要*依賴*它**：檔案寫成 `~/Applications/<app>.AppImage`（無版本或雜湊），但安裝 guard 要用 **glob**（`<app>*.AppImage`），不是那個確切路徑。AppImageLauncher 會把整合過的 AppImage 改名成 `<app>_<md5>.AppImage`，所以確切路徑的 guard 會讓每次 apply 都重新下載幾百 MB。像 `zen-x86_64_fe71259e...AppImage` 這種也會一直累積 —— glob 命中超過一個時要警告，而不是默默挑一個。
2. **執行位元 (executable bit)**：在 ansible 任務中用 `mode: '0755'`。
3. **AppImageLauncher 整合**：`appimagelauncherd.service`（使用者 systemd unit、由我們的 role 設定）監看 `~/Applications/`。新的 AppImage 會觸發首次執行對話框：*"Integrate or Run once?"* —— integrate 會擷取圖示、在 `~/.local/share/applications/` 下產生 `.desktop` 條目，並**把檔案改成 AppImageLauncher 的標準檔名**。自己寫 `.desktop` **並不能**讓我們豁免：AIL 是透過 `binfmt_misc` 掛在「執行」這件事本身上，任何啟動方式都會先經過它。`ask_to_move = false` 只壓掉對話框、壓不掉搬移（實測過 —— 見下方 pitfall），把檔案移出 `~/Applications` 也只是把改名換成「要不要搬進去」的提示。
4. **每次 apply 都要重新確立桌面整合**，不是只在下載時做。把當前的 AppImage 路徑解析成一個 fact，每次都據此重寫 `.desktop`，這樣改名會自動自癒，而不是留下一個懸空的 `TryExec=` —— 啟動器對此是**隱藏**條目而不是報錯。如果你也要刪掉 AIL 那份 `appimagekit_*.desktop` 以維持單一權威，記得它和 `ail-cli deintegrate` 都要加 `failed_when: false`：AppImageLauncher **Lite**（noRoot）下沒有 `ail-cli`。[`pitfalls/appimagelauncher-renames-managed-appimage.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/appimagelauncher-renames-managed-appimage.md)
5. **桌面整合任務要 gate 在 `is not skipped`**，不能只用 `is succeeded`。被 `when:` 跳過的任務一樣通過 `is succeeded`，所以下載失敗／被跳過時，後續任務仍會照寫圖示與 `.desktop`，而其 `TryExec=` 指向不存在的檔案 —— 結果是啟動器把該條目**隱藏**而不是報錯，apply log 裡還是 `failed=0`。同時要為下載配一個明確的「沒有符合的 asset」`debug` 警告；`rescue:` 區塊接不住 no-op。完整記錄：[`pitfalls/ansible-folded-scalar-regex-empty-url-silent-skip.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/ansible-folded-scalar-regex-empty-url-silent-skip.md)

對於我們管理的 AppImage，我們在同一個 ansible 任務中自己寫 `.desktop` 條目，讓 app **立刻**可被搜尋、不必等第一次啟動 —— 見 Zen Browser。這換來的是即時可用，以及一個穩定的 `.desktop` id 給 `linux_app_register --desktop=` 用；它**不會**阻止 AppImageLauncher 之後整合並改名，所以 role 每次 apply 都會重新確立那個條目。對於你手動丟入的 AppImage（Frpc Desktop），讓對話框處理。

要檢查常駐程式：`systemctl --user status appimagelauncherd`。手動整合：`ail-cli integrate ~/Applications/foo.AppImage`。

## 將新 GUI 應用加入 `gui_apps_linux`

```
Does upstream publish a .deb?
├─ YES → Does the .deb add an apt source (check `dpkg -L <pkg> | grep sources` after install)?
│        ├─ YES → use the .deb. Ansible installs once, apt keeps current. ★ best path
│        └─ NO  → use the .deb anyway, BUT add a refresh hook to
│                 `scripts/upgrade_tools.sh` so `just upgrade-system`
│                 re-fetches latest. (Discord pattern.)
│
├─ NO ── Does upstream publish on Snap or Flatpak with FIRST-PARTY support?
│        ├─ Official Snap → use snap (community.general.snap module).
│        │                 Cleanest auto-update on Ubuntu, but confined.
│        ├─ Official Flathub → use flatpak (community.general.flatpak module).
│        │                    Cross-distro friendly, also confined.
│        └─ Community-only → skip; AppImage probably more reliable.
│
└─ Only AppImage / tarball?
   ├─ AppImage → drop in ~/Applications/ as <app>.AppImage. AIL integrates.
   └─ tarball  → ~/Applications/<app>/ + wrapper script + manual .desktop.
                 ⚠️ Last resort — no auto-update path, manual everything.
```

### 具體模式 (Concrete patterns)

**`.deb` 模式** —— 見 [`gui_apps_linux/tasks/main.yml`](../../dot_ansible/roles/gui_apps_linux/tasks/main.yml) 中的 "Install Cursor via .deb"。兩步：

1. `ansible.builtin.uri` —— 抓廠商 API 解析最新 `.deb` URL（回傳 JSON、解析 `debUrl` 或類似欄位）。
2. `ansible.builtin.get_url` —— 下載 `.deb`，加上 `force: true`（覆寫先前 apply 留下的過時檔案）+ `until: cursor_dl is succeeded` + `retries: 4` + `delay: 5`（GFW 區 CDN 掉包）。
3. `ansible.builtin.apt: deb=<path>` —— 安裝。若廠商有出 apt source，postinst 會處理。
4. 將整個區塊用 `rescue:` 包起來，印出手動後備 URL。

**AppImage 模式** —— 見同檔的 "Install Zen Browser AppImage"。三步：

1. `ansible.builtin.uri` —— GitHub releases API（或廠商等價物）解析資產 URL。
2. 用 `selectattr('name', 'match', '^<prefix>-<arch>\\.AppImage$')` 過濾器挑出 `target_architecture` 對應的資產（已由 [`linux.yml`](../../dot_ansible/playbooks/linux.yml) 中的 `Set target_architecture from dpkg` 任務正規化為 `x86_64` / `aarch64`）。
3. `ansible.builtin.get_url` 到 `~/Applications/<app>.AppImage`，使用 `mode: '0755'` 與穩定檔名。
4. 用 `ansible.builtin.copy` 加 `content:` 字面值在 `~/.local/share/applications/` 下寫一個 `.desktop` 條目 —— 該檔案會透過 `update-desktop-database` 合併進系統選單。

**Snap 模式** —— 本 repo 還沒有。範本：

```yaml
- name: Install Bitwarden Desktop via Snap
  community.general.snap:
    name: bitwarden
    state: present
    classic: false   # most apps are confined; set true only when vendor docs say so
  become: true
```

**Flatpak 模式** —— 還沒有。範本：

```yaml
- name: Install Discord via Flatpak (instead of .deb)
  community.general.flatpak:
    name: com.discordapp.Discord
    state: present
    remote: flathub  # add `community.general.flatpak_remote` first if missing
    method: user     # per-user install; `system` requires root
```

永遠加上一個 `rescue:` 區塊，將使用者指向手動後備 URL（cursor.com / discord.com / GitHub release page），這樣失敗的自動安裝不會是死路一條。

## 交叉參考 (Cross-references)

- [`docs/tools/appimage.md`](../tools/appimage.md) —— AppImageLauncher 安裝路徑、`ail-cli`、Ubuntu 24.04 上的 libfuse2 / AppArmor 陷阱。
- [`docs/this_repo/upgrades.md`](../this_repo/upgrades.md) —— install-vs-upgrade 拆分：為何 `chezmoi apply` 不升級版本、`just upgrade-*` 涵蓋什麼、每個套件管理員位於何處。
- [`dot_ansible/roles/gui_apps_linux/tasks/main.yml`](../../dot_ansible/roles/gui_apps_linux/tasks/main.yml) —— 真正的 ansible role，新增應用時可複製其中模式。
