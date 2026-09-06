# mole — macOS 清理、磁碟分析、開發產物清除

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

[tw93/Mole](https://github.com/tw93/Mole)（`mole`，短入口 `mo`）是 macOS 的維護
CLI：清快取、連同殘留檔一起解除安裝 (uninstall) app、瀏覽磁碟用量，以及本 repo
真正在意的那一項——把每個 checkout 裡的開發建置產物 (build artifact)
（`node_modules`、`target`、`.venv`、`build`、`dist`）回收掉。

- **安裝**：只有 macOS，homebrew-core 的 `mole` formula
  （`dot_config/homebrew/Brewfile.tmpl`），由 `installMole` prompt 控制。
- **Linux 沒有** — 見下方「為什麼只有 macOS」。
- **受管設定檔**：`~/.config/mole/whitelist` 與 `~/.config/mole/purge_paths`，
  由 chezmoi 種下一次（`create_` prefix）。
- **Shell helper**：`dot_config/shell/33_mole.sh` → `moa`、`moclean`、`mowl`。
- **補全 (completion)**：zsh + bash，由 `scripts/generate_completions.sh` 產生。

---

## 日常指令

```bash
mo                       # 互動選單
mo purge                 # 清掉舊的專案建置產物（對開發者最有用的一項）
mo purge --dry-run       # 先預覽
mo analyze ~/Documents   # 視覺化磁碟瀏覽器，限定在某個路徑
mo status                # 即時 CPU / GPU / 記憶體 / 磁碟 / 網路儀表板
mo clean --dry-run       # 預覽快取清理
mo history               # 之前幾次跑刪了什麼
```

### 本 repo 額外提供的 helper

| 函式 | 作用 |
|---|---|
| `moa [dir]` | `mo analyze` 限定在 `dir`（預設：目前目錄）。單獨的 `mo analyze` 會掃整個 `$HOME`，通常不是你要的。 |
| `moclean [args…]` | 先跑 `mo clean --dry-run` 印出計畫，再問你要不要真的執行。`mo clean` 本身不會問就直接刪。 |
| `mowl` | 印出兩個受管設定檔實際生效的條目，以及編輯 / 重新取基準 (re-baseline) 的指令。 |

它們放在 `dot_config/shell/33_mole.sh`，`PATH` 上沒有 `mole` 時會自動停用，所以
在 Linux 上這個 fragment 是空操作 (no-op)。`mo` 是上游自己的短入口——這裡不會用
alias 蓋掉它。

---

## 兩個受管設定檔

兩個都是 chezmoi 的 `create_` 種子檔：chezmoi 只寫一次，之後永不再碰，因為 mole
會透過 `mo clean --whitelist` 與 `mo purge --paths` 自己改寫它們。要把本機的修改
帶回 repo，直接用 `cp`——`chezmoi add` 會把 `create_` prefix 拿掉，
`chezmoi re-add` 則會靜默跳過：

```bash
cp ~/.config/mole/whitelist "$(chezmoi source-path ~/.config/mole/whitelist)"
```

### `whitelist` — 是「取代」不是「附加」

!!! danger "這個檔案只要存在，mole 內建的預設白名單就整組失效"
    從 mole V1.7.5 起，存在的 `~/.config/mole/whitelist` 會被當成**完整的**保護
    清單。`DEFAULT_WHITELIST_PATTERNS` 整組被丟掉；只有
    `SAFETY_WHITELIST_PATTERNS`（Spotlight、FontRegistry、CloudKit、Poetry
    virtualenvs、Finder metadata）仍會無條件合併。上游自己在
    `lib/core/base.sh:188-192` 記錄了這個造成的回歸 (regression)。

所以種子檔在加任何東西之前，先把上游自己的預設值逐條重列一次。**從第一個區塊刪
掉一行，就是靜默拿掉一項保護**，不會 fall back 回預設。`tests/unit/mole.bats`
鎖住了這份清單，避免有人不小心把區塊修掉。

在上游預設之上，種子檔另外保護本 repo 自己的 bootstrap 面：

| 路徑 | 理由 |
|---|---|
| `~/.cache/uv/*` | uv 是這裡每一支 PEP723 script（`fleet`、`tsnet`、`mlf`、`yth`、`ytmv`、`pqsum`、`dotfiles_init`）以及呼叫它們的 `just` recipe 的 bootstrap。mole 在 `lib/clean/dev.sh` 裡就是拿 `~/.cache/uv` 開刀；快取被清空會讓下一次 `chezmoi apply` 變成整包重下載。 |
| `~/.bun/install/cache/*` | 每次呼叫 copilot-proxy，bun 都要跑 `copilot-throttle-shim.js`。 |
| `~/.local/share/mise/*` | mise 在這底下放的是真正的 runtime 安裝，不只是快取下載。 |

格式：一行一個絕對路徑或 glob、`#` 註解、`~` 與 `$HOME` 會展開、不可含 `..` 或
`//`。

### `purge_paths` — 這是唯一能指定 mole 掃哪裡的方法

`mo purge` **沒有路徑參數**。唯一能選擇掃描範圍的地方就是這個檔案，而且只要它有
條目，就會完全取代 mole 的自動探索 (auto-discovery)（`lib/clean/project.sh`）。

反正自動探索也找不到這台機器的主 checkout：它是 glob `$HOME/*/`（深度 1）再用
`maxdepth 2` 探測專案指標檔，所以 `~/Documents/Program/<repo>` 剛好深了一層而偵測
不到。因此種子檔列出：

- `~/Documents/Program` — 主 checkout 根目錄
- `~/Worktrees` — `worktrunk` / `dev-cli` 停放 git worktree 的地方，每一個都帶著
  自己的 `node_modules` / `target` / `.venv`

要加更多就用 `mo purge --paths`，再用上面的 `cp` 指令重新取基準。

---

## 升級

mole 是 Homebrew formula，`just upgrade-brew` 已經涵蓋，所以刻意沒有
`just upgrade-mole` 這個 recipe。

!!! warning "Homebrew 安裝下絕對不要跑 `mo update`"
    mole 自帶更新器，會往 `/usr/local/bin` 寫，跟 Homebrew 擁有的 symlink 打架。
    `mo update` 只適用於 `install.sh` 那條安裝管道。

---

## 為什麼只有 macOS

Mole 不是「跨平台但沒在別的系統上測過」的工具；它從頭到尾就建在 macOS 的系統介面上。

| | 狀態 |
|---|---|
| **macOS** | 完整支援。homebrew-core formula、GPL-3.0-or-later、大約每週一版。注意 homebrew-core **只提供 arm64 bottle**——Intel Mac 會從原始碼建置（build 依賴：`go`），第一次 apply 會多花一兩分鐘。 |
| **Linux** | 不支援，也不是可以移植的等級。`install.sh` 在 `$OSTYPE` 不是 `darwin*` 時直接拒絕執行（"This tool is designed for macOS only"）。`cmd/analyze` 全部是 `//go:build darwin`，`!darwin` 只留一個 stub，印出 "analyze is only supported on macOS" 然後 exit 1。約 46k 行的 shell 裡引用 `Library/Caches` 335 次、`com.apple` 282 次、`mdfind` 74 次，還有 `defaults`、`osascript`、`tmutil`、`launchctl`、`diskutil`。 |
| **Windows** | [`windows` 分支](https://github.com/tw93/Mole/tree/windows)有一份原生 PowerShell 移植版，但**這裡不採用**。上游自己的 README 開頭就掛警告，說 Windows 版「is currently not mature… please do not use this tool」。它停在 1.30.0，而 main 已經 1.53.0；scoop / winget / chocolatey manifest 全部未發佈且指向某個 contributor 的 fork；安裝方式是 `git clone` 那個分支，`mo update` 的實作就是 `git pull`。 |

跨 repo 的決策紀錄——包含要滿足什麼條件才會重新考慮 Windows 分支——放在
superproject 的 `docs/mole-macos-only.md`。

---

## 相關

- [btop](btop.md) — 跨平台的即時監控；`mo status` 只在 macOS 上跟它重疊。
- [macOS swap & memory](macos-swap.md) — 記憶體壓力診斷。
- [chezmoi prefixes](chezmoi-prefixes.md) — 為什麼這兩個檔用 `create_`。
- `mo touchid` 可以設定用 Touch ID 跑 `sudo`。它刻意**沒有**接進本 repo 的 apply
  流程——它會改 `/etc/pam.d/sudo_local`，那不在 chezmoi 的管轄範圍。想要就自己手動跑。
