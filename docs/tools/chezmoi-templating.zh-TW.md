# chezmoi 樣板 (templating) 慣例

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

一份簡短的指南，說明在 chezmoi 樣板中該以哪一個旋鈕做條件分支 (conditional branch)：`.profile`（在 init 時詢問使用者的角色）、`.chezmoi.os` / `.chezmoi.arch`（自動偵測的事實）、`.chezmoi.hostname`（各機器覆寫）、或像 `WORK_MACHINE` 這樣的環境變數 (env var)（per-session）。

這份文件之所以存在，是因為很容易把 OS / arch 這類事實編碼成新的 `.profile` 值（我們以前對 `macos_intel` 就是這樣做的），導致八個樣板裡都散落著類似 `or (eq .profile "macos") (eq .profile "macos_intel")` 的條件式。修正方式是：讓自動可偵測的事實由 `.chezmoi.*` 提供，`.profile` 只保留給使用者真的必須告訴我們的事情。

上游參考：

- [Manage machine-to-machine differences](https://www.chezmoi.io/user-guide/manage-machine-to-machine-differences/) — 概覽與模式
- [Template variables](https://www.chezmoi.io/reference/templates/variables/) — `.chezmoi.*` 欄位完整清單
- [Init functions → promptChoiceOnce](https://www.chezmoi.io/reference/templates/init-functions/promptChoiceOnce/) — 帶驗證的一次性提示

## 決策表

挑選**最窄**且能正確表達該述詞 (predicate) 的旋鈕。

| 旋鈕 | 它回答什麼問題 | 來自何處 | 典型值 | 何時使用 |
|---|---|---|---|---|
| `.chezmoi.os` | 我在哪個 OS？ | 自動偵測（`runtime.GOOS`） | `darwin`、`linux`、`windows`、`freebsd`…… | OS-specific 路徑、套件管理器（brew vs apt）、kernel 層級功能 |
| `.chezmoi.arch` | 哪種 CPU 架構？ | 自動偵測（`runtime.GOARCH`） | `amd64`、`arm64`、`arm`、`386`…… | 二進位檔可用性（僅 Apple Silicon 的 cask、armv7l fallback） |
| `.chezmoi.kernel.osrelease` | Linux 上的發行版資訊 | `/proc/sys/kernel/osrelease` | WSL 上含 `microsoft` | 區分 WSL 與原生 Linux |
| `.chezmoi.hostname` | 哪一台機器？ | `os.Hostname()` | `work-laptop`、`rpi5`…… | 各機器覆寫（單一行為怪異的主機） |
| `.profile`（本 repo） | 使用者要扮演什麼**角色**？ | init 時的 `promptChoiceOnce` | `macos`、`ubuntu_desktop`、`ubuntu_server` | 桌面 vs 伺服器 (server)（GUI 套件、nerdfonts、alacritty）—— **無法**自動偵測 |
| `env "WORK_MACHINE"` | 這台機器目前在工作模式嗎？ | `chezmoi apply` 時的 shell 環境 | unset / `1` | per-session 切換（示意用途 —— 目前沒有樣板以此分支；遊戲類 cask 已改由 `installGamingApps` prompt 控管） |

## 規則

> 如果該述詞**可自動偵測**（OS、CPU 架構、kernel flavour、hostname），就以對應的 `.chezmoi.*` 變數做分支。
>
> 只在述詞是**無法自動偵測的使用者偏好**時，才引入新的 `.profile` 值 —— 例如「這是無人值守的 server，跳過 GUI 工具」。

反模式 (anti-pattern)：新增一個 `.profile` 值來編碼 chezmoi 已知的差異。本 repo 過去的例子是 `macos_intel`（= darwin + amd64），它逼著每一個 macOS-specific 分支都得寫成 `or (eq .profile "macos") (eq .profile "macos_intel")`，因為大多數 macOS 邏輯在兩種架構上是一樣的。修正方式是兩個便宜的內建變數：`.chezmoi.os` 用於跨 OS 分支、`.chezmoi.arch` 用於少數僅 arm64 的二進位檔。

## Cheat-sheet：常見模式

### macOS vs Linux（任何 macOS）

```go-template
{{ if eq .chezmoi.os "darwin" -}}
# 僅 macOS 的區塊
{{ else if eq .chezmoi.os "linux" -}}
# 僅 Linux 的區塊
{{ end -}}
```

### 僅 Apple Silicon（不含 Intel Mac）

```go-template
{{ if and (eq .chezmoi.os "darwin") (eq .chezmoi.arch "arm64") -}}
cask "chatgpt"  # 僅 arm64 的 release
{{ end -}}
```

如果該檔案本來就只會在 macOS 上被使用（例如 `Brewfile.darwin`），`.chezmoi.os` 那部分是多餘的 —— 單獨用 `eq .chezmoi.arch "arm64"` 就夠了。

### 僅 Intel macOS

```go-template
{{ if and (eq .chezmoi.os "darwin") (eq .chezmoi.arch "amd64") -}}
# Intel Mac 專用修正
{{ end -}}
```

或反過來寫成早退出 (early-exit) 形式：

```go-template
{{ if or (ne .chezmoi.os "darwin") (ne .chezmoi.arch "amd64") -}}
exit 0  # 不是 Intel macOS —— 沒事可做
{{ end -}}
```

### 桌面 vs server（使用者角色 —— 無法自動偵測）

```go-template
{{ if or (eq .chezmoi.os "darwin") (eq .profile "ubuntu_desktop") -}}
# 安裝 GUI 相依（Bitwarden Desktop 等）
{{ end -}}
```

從我們的角度，macOS 永遠是「桌面」，所以 OS 檢查就涵蓋了；在 Linux 上，使用者必須透過 `ubuntu_desktop` vs `ubuntu_server` 告訴我們。

### WSL

```go-template
{{ if and (eq .chezmoi.os "linux") (contains "microsoft" (lower .chezmoi.kernel.osrelease)) -}}
# WSL 專用調整
{{ end -}}
```

## 本 repo 的 profile 值

刻意保持很小（3 個值，僅使用者角色）：

| Profile | 含義 | init 時的自動推導預設值 |
|---|---|---|
| `macos` | macOS 桌面（任何架構） | 當 `.chezmoi.os == "darwin"` |
| `ubuntu_desktop` | 帶 GUI 的 Ubuntu —— 想要 `nerdfonts`、`alacritty` 等 | — |
| `ubuntu_server` | 無人值守的 Ubuntu —— 跳過 GUI 套件 | 當 `.chezmoi.os == "linux"` |

提示定義在 [`.chezmoi.toml.tmpl`](../../.chezmoi.toml.tmpl) 中，使用 `promptChoiceOnce` 並會將答案對照上面的清單做驗證。

## 從 `macos_intel` 遷移

在這次重構之前，Intel Mac 是第四個 profile（`macos_intel`）。每個跨 OS 的 macOS 分支都得寫成 `or (eq .profile "macos") (eq .profile "macos_intel")`，僅 Intel 的程式碼則只問 `eq .profile "macos_intel"`。重構之後：

- 跨 OS 的 macOS 分支 → `eq .chezmoi.os "darwin"`
- 僅 Intel 的程式碼 → `and (eq .chezmoi.os "darwin") (eq .chezmoi.arch "amd64")`
- 僅 Apple Silicon 的程式碼 → `eq .chezmoi.arch "arm64"`（在 darwin-scoped 檔案中）

**如果你既有的 `~/.config/chezmoi/chezmoi.toml` 仍是 `profile = "macos_intel"`**，請二選一：

```bash
# 選項 A：原處編輯
sed -i '' 's/"macos_intel"/"macos"/' ~/.config/chezmoi/chezmoi.toml
chezmoi apply

# 選項 B：重新跑 init 提示
chezmoi init --force
```

任一選項之後，`chezmoi apply --dry-run` 都應該不會顯示任何依賴舊 profile 值的 diff。

## 另見

- [chezmoi-prefixes.md](chezmoi-prefixes.md) — 檔名前置詞參考（`dot_`、`private_`、`create_`、`modify_`……）以及 `chezmoi add` 安全性表
- [`.chezmoi.toml.tmpl`](../../.chezmoi.toml.tmpl) — 提示定義
