# Ubuntu 上的 AppImage 與 AppImageLauncher

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

> AppImage 是 Ubuntu 上 GUI 應用程式 (GUI app) 的**五種**封裝機制之一（其他為 `.deb`、Snap、Flatpak、從原始碼建置）。跨機制比較、各應用程式採用哪一種的清單，以及為本 repo 的 ansible 角色 (role) 新增 GUI app 時的決策樹，請見 [`docs/playbooks/linux-gui-apps.md`](../playbooks/linux-gui-apps.md)。本頁是 AppImage 專屬的深入說明。

[AppImage](https://appimage.org/) 是 Linux 的單檔應用程式格式：下載、`chmod +x`、執行。不需 root、不需安裝步驟，除了 host 上的 `libc` 與 `libfuse2` 之外不需任何相依套件 (dependency)。Cursor、Obsidian、Joplin、Bitwarden Desktop 以及許多 AI／markdown／媒體工具的 Linux 版本，都是以此格式發布。

缺點在於桌面整合 (desktop integration)：一個裸放的 `~/Applications/foo.AppImage` 不會出現在 GNOME／KDE 的應用程式啟動器 (launcher) 裡，沒有 `.desktop` 項目，也不會被 `xdg-open` 接管。這就是 **[AppImageLauncher](https://github.com/TheAssassin/AppImageLauncher)** 派上用場的地方——一個系統常駐程式 (system daemon)，會監看某個目錄裡的 AppImage 並自動整合（提取圖示、產生 `.desktop`、可選擇移到指定位置、可選擇透過 delta 更新）。

本 repo 在 `ubuntu_desktop` 機器上透過 [`gui_apps_linux`](../../dot_ansible/roles/gui_apps_linux/tasks/main.yml) Ansible 角色安裝 AppImageLauncher。本文件涵蓋*為什麼*、三種安裝路徑、以及在當前 Ubuntu 上會踩到的兩個地雷。

## 為什麼選 AppImageLauncher 而不是裸 AppImage 或 `appimaged`

| 方式 | 桌面選單？ | 自動更新？ | 不需 root？ | 備註 |
|---|---|---|---|---|
| 裸用 `chmod +x ./foo.AppImage` | 否 | 否 | 是 | 適合一次性使用；啟動器裡不會出現任何項目。 |
| [`appimaged`](https://github.com/probonopd/go-appimage) 常駐程式 | 是 | 是（透過 zsync） | 是 | 監看目錄並寫入 `.desktop` 項目。維護沒那麼活躍；無首次執行提示。 |
| **AppImageLauncher**（本 repo 採用） | 是 | 是（選擇性） | 是（Lite 版本） | 首次執行時跳出對話框問「要整合還是只執行一次？」，整合後的 AppImage 集中放在 `~/Applications/`，移除也乾淨。 |

**首次執行提示**才是真正的賣點：雙擊一個 AppImage，AppImageLauncher 會問你要把它系統層級安裝（移到 `~/Applications/`、產生 `.desktop` ＋ 圖示 ＋ MIME handler），還是只執行一次然後刪除。讓 AppImage 用起來像普通應用程式，又不會把你綁進另一個應用程式商店。

## 安裝路徑

Ansible 角色會依序嘗試以下路徑，失敗就往下走：

### 1. Ubuntu PPA（在 20.04 / 22.04 LTS 上首選）

```bash
sudo add-apt-repository ppa:appimagelauncher-team/stable
sudo apt update
sudo apt install appimagelauncher
```

封裝為 `appimagelauncher`（系統常駐程式 ＋ `.desktop` hook ＋ `ail-cli`）。透過 `/usr/share/applications/appimagelauncher.desktop` 與 `application/x-appimage` 的 XDG MIME handler 進行整合。

### 2. GitHub `.deb` 後備方案（24.04「noble」需要）

截至 2026 年，PPA [尚無 Ubuntu 24.04 的版本](https://github.com/TheAssassin/AppImageLauncher/issues)；維護工作已停滯。GitHub releases 頁面上最新的 `.deb` 仍然能在 noble 上乾淨地安裝：

```bash
ARCH=$(dpkg --print-architecture)   # amd64 / arm64
curl -fsSL "https://api.github.com/repos/TheAssassin/AppImageLauncher/releases/latest" \
  | jq -r --arg a "$ARCH" '.assets[] | select(.name | test("^appimagelauncher_.*_\($a)\\.deb$")).browser_download_url' \
  | xargs -I{} curl -fSL -o /tmp/appimagelauncher.deb {}
sudo apt install -y /tmp/appimagelauncher.deb
```

Ansible 角色透過 `ansible.builtin.uri` 對 GitHub API 發請求，再用 `ansible.builtin.apt: deb:` 自動完成這段流程。

### 3. AppImageLauncher **Lite**（不需 root，使用者層級）

Lite 是把 AppImageLauncher 自身打包成 AppImage——它會把自己整合進 `~/.config/autostart`、`~/.local/share/applications`、`~/.local/share/icons`。在無法 `sudo` 的受限機器上很有用。

```bash
mkdir -p ~/Applications
curl -fsSL "https://api.github.com/repos/TheAssassin/AppImageLauncher/releases/latest" \
  | jq -r --arg a "$(uname -m)" '.assets[] | select(.name | test("^appimagelauncher-lite-.*-\($a)\\.AppImage$")).browser_download_url' \
  | xargs -I{} curl -fSL -o ~/Applications/appimagelauncher-lite.AppImage {}
chmod +x ~/Applications/appimagelauncher-lite.AppImage
~/Applications/appimagelauncher-lite.AppImage install   # 一次性整合
```

當傳入 `gui_apps_linux_no_root=true` 時 Ansible 角色會跑這段（在 `noRoot` chezmoi profile 下由 `.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl` 自動設定）。

## `ail-cli` —— 腳本化整合

系統常駐程式提供 `ail-cli` 用於無頭 (headless) 整合。對於把 AppImage 丟進 `~/Applications/` 並希望不用雙擊就能在啟動器裡出現的供應 (provisioning) 腳本來說很實用。

```bash
ail-cli integrate ~/Applications/Cursor.AppImage
ail-cli list-integrated
ail-cli deintegrate ~/Applications/Cursor.AppImage
```

Lite 版不附帶 `ail-cli`；請使用 GUI 首次執行提示，或手動 `chmod +x` 並雙擊。

## 操作範例

### Cursor（當 `.deb` 安裝出狀況時）

[`gui_apps_linux`](../../dot_ansible/roles/gui_apps_linux/tasks/main.yml) 角色透過官方 `.deb`（從 `cursor.com/api/download?platform=linux-x64`）安裝 Cursor。如果該網址改變或回傳壞掉的套件 (package)，手動的 AppImage 流程是：

```bash
mkdir -p ~/Applications
# 從 https://cursor.com/download （「Download AppImage」連結）下載最新的 AppImage
mv ~/Downloads/Cursor-*.AppImage ~/Applications/Cursor.AppImage
chmod +x ~/Applications/Cursor.AppImage
ail-cli integrate ~/Applications/Cursor.AppImage
# （或者雙擊以觸發首次執行提示）
```

編輯器使用者設定（`settings.json`、`keybindings.json`）獨立於安裝方式之外——chezmoi 透過 [`.chezmoitemplates/editor/`](../../.chezmoitemplates/editor/) 管理它們，不論 Cursor 是來自 `.deb` 還是 AppImage。

### Zen Browser（自動安裝）

[`gui_apps_linux`](../../dot_ansible/roles/gui_apps_linux/tasks/main.yml) 角色會從 [`zen-browser/desktop`](https://github.com/zen-browser/desktop/releases) 下載最新的 `zen-<arch>.AppImage` 到固定路徑 `~/.local/opt/zen/zen.AppImage`，並寫入 `~/.local/share/applications/zen-browser.desktop` ＋ SVG 圖示。舊的 `~/Applications/zen*.AppImage` 會在固定路徑不存在時遷移一次。macOS 上的對應為 Arc（Brewfile）。

自己寫 `.desktop` 本身**不會**讓 Zen 豁免於 AppImageLauncher：AIL 也透過 `binfmt_misc` 攔截執行。因此這個 launcher 明確使用 `/usr/bin/env APPIMAGELAUNCHER_DISABLE=1 ...`，而 AppImage 又位於 daemon 不監看的 `~/.local/opt/zen/`。兩者合起來才會阻止登入時與執行時重新整合。role 同時清除舊的 `appimagekit_*Zen*.desktop`/icons，只留下穩定 ID `zen-browser.desktop`。細節：[`pitfalls/appimagelauncher-renames-managed-appimage.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/appimagelauncher-renames-managed-appimage.md)。

升級方式：以較新的 AppImage 覆寫 `~/.local/opt/zen/zen.AppImage`（保留 executable bit），再重跑 `just apply-ubuntu_desktop` 以重新確立 desktop entry 與清理舊整合檔。

### Obsidian / Bitwarden Desktop / Joplin

同樣的模式：把 AppImage 丟進 `~/Applications/`，用 `ail-cli` 或首次執行提示整合。這些應用程式會透過 AppImage delta 自我更新（AppImageLauncher 也會處理更新提示）。

## 疑難排解

### `libfuse.so.2: cannot open shared object file`

Ubuntu 22.04+ 的預設安裝中已移除 `libfuse2`。對 fuse 2 編譯的 AppImage 會以下列訊息失敗：

```plain
dlopen(): error loading libfuse.so.2
AppImages require FUSE to run.
```

修正方式：

```bash
sudo apt install libfuse2
```

Ansible 角色在 `ubuntu_desktop` 上無條件安裝 `libfuse2`，所以全新機器永遠不會被這個咬到。如果你是在角色之外做引導 (bootstrap)，請記得 24.04 上的 `libfuse2t64` 是過渡性套件——要安裝 `libfuse2`（不是 `libfuse3`）。

### AppArmor 在 24.04 上阻擋沙盒化的 AppImage

Ubuntu 24.04 啟用了 `unprivileged_userns_restriction` AppArmor profile，這會破壞 AppImage 內 Electron／Chromium 的沙盒 (sandbox)（Cursor、VSCode、Obsidian，以及任何以 Chromium 為基礎的工具）。症狀：應用程式視窗永遠不出現，記錄顯示 `SUID sandbox helper binary was found, but is not configured correctly`。

兩種修法，擇一：

1. **每個應用程式加 `--no-sandbox`**（簡單，但隔離稍弱）：

   ```bash
   ~/Applications/Cursor.AppImage --no-sandbox
   ```

   對於已整合的應用程式，編輯產生的 `~/.local/share/applications/appimagekit-<hash>-Cursor.desktop`，在 `Exec=` 那行末尾加上 `--no-sandbox`。

2. **全域允許 unprivileged userns**（隔離較好，需要 root）：

   ```bash
   sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
   # 持久化：
   echo 'kernel.apparmor_restrict_unprivileged_userns=0' | sudo tee /etc/sysctl.d/60-apparmor-namespace.conf
   ```

   這會放寬*所有* user namespace 的沙盒限制（不只 Electron），所以視為一個有意識的取捨。

### `.desktop` 項目指向舊的 AppImage hash

AppImageLauncher 把整合的 desktop 檔案命名為 `appimagekit-<hash>-<name>.desktop`，其中 `<hash>` 是由 AppImage 二進位推導而來。就地 (in-place) 更新某個 AppImage（例如透過它自己的更新器）會留下過時的 hash。修正：

```bash
ail-cli deintegrate ~/Applications/Foo.AppImage
ail-cli integrate   ~/Applications/Foo.AppImage
update-desktop-database ~/.local/share/applications
```

## 延伸閱讀

- [`dot_ansible/roles/gui_apps_linux/tasks/main.yml`](../../dot_ansible/roles/gui_apps_linux/tasks/main.yml) —— 安裝角色
- [`.chezmoitemplates/editor/`](../../.chezmoitemplates/editor/) —— 編輯器設定 overlay，會落入 Cursor／VSCode／Antigravity，與安裝方式無關
- [AppImageLauncher 上游](https://github.com/TheAssassin/AppImageLauncher)
- [AppImage 格式文件](https://docs.appimage.org/)
- [Ubuntu 24.04 AppArmor 變更](https://discourse.ubuntu.com/t/ubuntu-24-04-lts-noble-numbat-release-notes/39890#unprivileged-user-namespace-restrictions-15)
