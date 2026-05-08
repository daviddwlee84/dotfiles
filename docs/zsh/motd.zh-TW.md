# SSH 登入橫幅 (MOTD)

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

一段簡短的登入 shell hook，當你 SSH 進入受管主機時印出主機名橫幅與選用的系統資訊。本機終端機保持安靜——這個橫幅純粹是為了**機群識別 (fleet identification)**：當你 `ssh` 進入由 [`just fleet-apply`](../this_repo/fleet-apply.md) 管理的十台機器之一時，橫幅能立即回答「我現在在哪一台？」。

來源：[`dot_zlogin.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_zlogin.tmpl) → `~/.zlogin`。

## 三種樣式，於 `chezmoi init` 時選擇

chezmoi 提示 `motdStyle` 決定本機使用哪種樣式。預設為 `figlet`；可在 init 時透過提示切換，或於執行期透過 `~/.zshrc.adhoc` 中的 `MOTD_STYLE` 為個別機器覆寫。

| 樣式 | 行數 | 延遲 | 內容 | 適用於 |
|-------|-------|---------|----------|---------|
| `figlet`（預設） | ~6 | ~5 ms | figlet 主機名 + 1 行中繼資料（profile/OS/uptime/IP） | 24 列的行動 SSH ✅ |
| `fastfetch-slim` | ~10–13 | ~80 ms | figlet 主機名 + 不含 logo 的 fastfetch（Title/OS/Kernel/Uptime/CPU/Memory/Disk） | 半螢幕 tmux 分割 ✅ |
| `fastfetch-full` | ~22+ | ~150 ms | 完整發行版 logo + fastfetch 所知的所有欄位（GPU、套件、主題、顯示器……） | 全螢幕桌面終端機 |

### `figlet` 樣式（預設）

```
   _   _      _    ___  _
  | | | |__ _| |__|__ \| |__
  | |_| / _` | '_ \ / // '_ \
   \___/\__,_|_.__//_(_)_.__/

profile=ubuntu_server  os=Linux 6.5.0-21-generic  up=4 days  via=192.168.1.42
```

青色 figlet + 暗色中繼資料行。使用字型 `figlet -f small`。

### `fastfetch-slim` 樣式

```
   _   _      _    ___  _
  | | | |__ _| |__|__ \| |__
  | |_| / _` | '_ \ / // '_ \
   \___/\__,_|_.__//_(_)_.__/

user@hub3
OS: Ubuntu 24.04.1 LTS x86_64
Kernel: Linux 6.8.0-45-generic
Uptime: 12 days, 3 hours
CPU: Intel i7-12700H (20)
Memory: 8.42 GiB / 32.00 GiB (26%)
Disk (/): 41 GiB / 200 GiB (20%)
```

略過 logo（figlet 已經給了你大型主機名）並略過慢速探測（Packages、GPU、displays）。結構：`Title:OS:Kernel:Uptime:CPU:Memory:Disk`。

### `fastfetch-full` 樣式

```
            .-/+oossssoo+/-.               user@desktop
        `:+ssssssssssssssssss+:`           ----------
      -+ssssssssssssssssssyyssss+-         OS: Ubuntu 24.04.1 LTS x86_64
   .ossssssssssssssssssdMMMNysssso.        Host: ThinkPad P14s Gen 4
  /ssssssssssshdmmNNmmyNMMMMhssssss/       Kernel: Linux 6.8.0-45
 +ssssssssshmydMMMMMMMNddddyssssssss+      Uptime: 12 days, 3 hours
... (完整發行版 logo + ~20 行資訊，包含 GPU、displays、theme、packages) ...
```

經典的 neofetch 風格截圖。用在你真心想炫耀的機器上。

## 觸發條件

橫幅僅在**全部四個**閘門通過時才會觸發——與樣式無關：

| # | 閘門 | 原因 |
|---|------|-----|
| 1 | `[ -n "$SSH_CONNECTION" ]` | 在主控台／本機／`tmux new` 時為空 |
| 2 | `[ -t 1 ]` | stdout 必須是 TTY → 抑制 `ssh host 'cmd'`、`scp`、`rsync`、`fleet-apply` 的 SSH 探測 |
| 3 | `[ -z "$TMUX" ]` | 每個 SSH 連線只印一次，而非每個 tmux pane 都印 |
| 4 | `[ "${MOTD_DISABLE:-0}" != "1" ]` | 個別連線可選擇停用 |

zsh 僅針對**登入 shell (login shell)** 載入 `.zlogin`，因此新的 tmux pane（預設設定下）以及非互動式的 `zsh -c` 呼叫根本不會執行此腳本。閘門 2 與 3 是雙重保險，用來防範強制讓 pane 內成為登入 shell 的 tmux 設定。

## 使用的工具

`figlet` 永遠會被使用（每種樣式皆以 figlet 主機名開頭，唯獨 `fastfetch-full` 改用 fastfetch 自身的 logo）。

`fastfetch` 是現已停止維護的 `neofetch` 之現代 Rust 替代品——由 `fastfetch-slim` 與 `fastfetch-full` 樣式使用。若 `fastfetch` 未安裝（例如在 ansible 執行前的首次開機 SSH，或 GitHub `.deb` 退路失敗的 `noRoot` Ubuntu 22.04 主機），slim/full 樣式會自動**退回**到 `figlet` 樣式——絕不會出錯。

伴隨工具 `toilet`（彩色／Unicode 的 figlet 超集）與 `lolcat`（彩虹顏色濾鏡）由 `devtools` 安裝，但 **MOTD 本身不使用它們**——它們是通用 CLI，可隨意 pipe 串接：

```sh
echo "deploy ok" | toilet -f mono12 --metal
echo "RAINBOW" | figlet | lolcat
```

MOTD 僅使用 ANSI escape（青色 + 暗色），因此在不穩的 SSH 上能維持一致行為，且絕不依賴外部顏色濾鏡的存在。

## 切換樣式

三條路徑，依「持久度／重量級」遞增排列：

### 1. 單次連線（無持久化）

直接在 SSH 指令前加上前綴：

```sh
MOTD_STYLE=fastfetch-full ssh host       # 單次
MOTD_DISABLE=1 ssh host                  # 此次連線靜音
```

磁碟上不會有任何變更。適合「就這一次讓我看完整資訊」的情境。

### 2. 持久化的執行期覆寫（無需 `chezmoi apply`）

加入 `~/.zshrc.adhoc`（由 [`dot_zshrc.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_zshrc.tmpl) 自動建立，**不受 chezmoi 管理**）：

```sh
export MOTD_STYLE=fastfetch-slim   # 三選一：figlet | fastfetch-slim | fastfetch-full
```

`MOTD_STYLE` 環境變數會勝過烤進 `~/.zlogin` 的 `{{ .motdStyle }}`。無需重新渲染、無需重新 init——可跨重開機與 SSH 重連保留。這是「這一台想用與機群預設不同的樣式」的標準路徑。

### 3. 編輯 chezmoi 來源（整個機群／權威預設值）

這條路徑會修改 `~/.zlogin` 中實際烤入的值。有兩種等效的更新來源方式：

```sh
chezmoi init --force                            # 重新執行所有提示（較重；要重新回答全部）
# 或
$EDITOR ~/.config/chezmoi/chezmoi.toml          # 直接只編輯 motdStyle 那一行
```

> **⚠️ 陷阱**：單獨編輯 `~/.config/chezmoi/chezmoi.toml` **不會有任何作用**。該檔案僅為來源資料——`~/.zlogin` 是**生成的產物 (generated artifact)**，只在 `chezmoi apply` 期間才會更新。所以你必須接著執行：
>
> ```sh
> chezmoi apply ~/.zlogin
> ```
>
> 確認生效：
>
> ```sh
> grep '_motd_style=' ~/.zlogin
> # 預期：_motd_style="${MOTD_STYLE:-fastfetch-slim}"
> ```

chezmoi 心智模型：`chezmoi.toml`（來源）→ `dot_zlogin.tmpl`（模板）→ `~/.zlogin`（目標，僅由 apply 重新生成）。上面的路徑 2 之所以無需 apply，正是因為它在執行期讀取環境變數，完全繞過了這個流程。

## 完全停用

```sh
export MOTD_DISABLE=1   # 寫在 ~/.zshrc.adhoc
```

或單次連線：`MOTD_DISABLE=1 ssh host`。

## 首次開機（fastfetch 尚未安裝前）

chezmoi 會在 ansible `devtools` role 執行前就先佈署 `~/.zlogin`。若你在這段空窗期以 `motdStyle=fastfetch-slim` SSH 進去：

- `command -v fastfetch` 回傳 false
- 退回到 `figlet` 樣式（figlet 主機名 + 中繼資料行）
- 仍然會乾淨退出

ansible 完成之後，下次 SSH 登入就會使用 fastfetch。

## 客製化

### 變更 figlet 字型

直接編輯 `~/.zlogin`（或為了整個機群同步推送，編輯 `dot_zlogin.tmpl`）：

```sh
# 在 _motd_print_figlet_banner() 內部：
figlet -w "$_motd_cols" -f banner -- "$_motd_host"   # 方塊狀
figlet -w "$_motd_cols" -f slant  -- "$_motd_host"   # 斜體
figlet -w "$_motd_cols" -f standard -- "$_motd_host" # 高大的預設
```

字型位於 `/usr/share/figlet/`（Linux）或 `$(brew --prefix figlet)/share/figlet/fonts/`（macOS）下。`small` 預設可在 24 列的行動 SSH 視窗內容納約 20 字元的主機名。

### 變更 `fastfetch-slim` 欄位

在 `dot_zlogin.tmpl` 中，slim case 呼叫：

```sh
fastfetch --logo none -s Title:OS:Kernel:Uptime:CPU:Memory:Disk
```

`-s`／`--structure` 接受任何以冒號分隔的 `fastfetch --list-modules` 模組清單。常見追加：`LocalIP`、`PublicIP`（慢）、`LoadAvg`、`Battery`、`Locale`、`Shell`、`Packages`。每項約增加 5–30 ms。

### 客製化 `fastfetch-full` 設定

`fastfetch --gen-config-force` 會以預設設定寫入 `~/.config/fastfetch/config.jsonc`——編輯它即可新增／移除模組、更換 logo、改變顏色。chezmoi 不管理該檔案，因此調整可在 `chezmoi apply` 後保留。schema 詳見 <https://github.com/fastfetch-cli/fastfetch/wiki/Configuration>。

### 顯示完整網域名稱（FQDN）而非短主機名

```sh
_motd_host="$(hostname -f 2>/dev/null || hostname)"
```

### 跳過 `figlet` 樣式中的中繼資料行

在 `dot_zlogin.tmpl` 的 `figlet|*)` case 中刪除 `_motd_print_metadata_line`。

## 為何不用 `/etc/motd` 或 PAM `motd.dynamic`？

系統 MOTD 位於 `/etc/motd` 與 `/etc/update-motd.d/*`，會套用到**每位**使用者。本橫幅是個別使用者的、住在 dotfiles 倉庫中、且尊重使用者的 opt-out——無需 root、不影響其他帳號。Ubuntu 預設的 MOTD（負載平均／「X 個更新可安裝」／Canonical 新聞行）在 SSH 開機順序中**疊加在**我們的橫幅之上：

```
SSH connect → PAM auth → pam_motd 印出 /etc/motd + update-motd.d/*
                                            ↓
                          shell 啟動 → zsh → .zshenv → .zshrc → .zlogin（我們）
                                                                        ↓
                                                                      提示符
```

要讓 Ubuntu 那些東西安靜：

```sh
touch ~/.hushlogin   # 個別使用者；只為你靜音 pam_motd
sudo chmod -x /etc/update-motd.d/50-motd-news   # 系統層級；關閉 Canonical 新聞
```

## 相關連結

- [`dot_zlogin.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_zlogin.tmpl) — 來源模板
- [`dot_ansible/roles/devtools/tasks/main.yml`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_ansible/roles/devtools/tasks/main.yml) — 安裝 `figlet`、`toilet`、`lolcat`、`fastfetch`（apt + brew，並為較舊的 Ubuntu 提供 GitHub `.deb` 退路）
- [`.chezmoi.toml.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/.chezmoi.toml.tmpl) — 宣告 `motdStyle` 提示
- [`dot_zshrc.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_zshrc.tmpl) — 自動建立 `~/.zshrc.adhoc`（`MOTD_STYLE=...` 與 `MOTD_DISABLE=1` 寫在這裡）
- [Fleet apply](../this_repo/fleet-apply.md) — 本橫幅最派上用場的多主機工作流程
- [fastfetch upstream](https://github.com/fastfetch-cli/fastfetch)
