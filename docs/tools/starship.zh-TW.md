# Starship 提示符

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

[Starship](https://starship.rs/) 是一個用 Rust 撰寫的跨 shell 提示符 (prompt)，用來取代預設的 oh-my-zsh `robbyrussell` 主題。

- **設定檔**：`~/.config/starship.toml`（chezmoi 來源：`dot_config/starship.toml`）
- **ZSH 初始化**：`~/.config/zsh/tools/01_starship.zsh`
- **Ansible role**：`starship`（macOS 用 brew、Linux 用官方 installer、noRoot 用使用者層級的 fallback）
- **依賴 (dependency)**：Nerd Fonts（由 `nerdfonts` role 安裝 Hack Nerd Font）

## 快速開始

```bash
chezmoi apply     # 部署設定 + 透過 ansible 安裝 starship
exec zsh          # 重新載入 shell 以看到新的提示符
```

## 預設樣式 (Presets)

Starship 內建多種 preset，可以一次改變整體外觀：

```bash
# 列出所有可用的 preset
starship preset --list

# 套用某個 preset（會覆寫 starship.toml）
starship preset nerd-font-symbols -o ~/.config/starship.toml    # 完整 Nerd Font 圖示
starship preset pastel-powerline -o ~/.config/starship.toml      # Powerline 風格的區段
starship preset tokyo-night -o ~/.config/starship.toml           # 深色配色
starship preset plain-text-symbols -o ~/.config/starship.toml    # ASCII fallback（無 Nerd Fonts）
```

試完 preset 後，執行 `chezmoi apply` 即可恢復到由 chezmoi 管理的版本。

預覽所有 preset：<https://starship.rs/presets/>

## 模組 (Module) 設定

模組決定提示符上顯示哪些資訊。編輯 `dot_config/starship.toml`（或執行 `chezmoi edit ~/.config/starship.toml`）。

### 常用模組

| 模組 | 說明 | 預設值 |
|--------|-------------|---------|
| `[directory]` | 目前路徑 | 啟用，截斷至 3 層 |
| `[git_branch]` | Git 分支 (branch) 名稱 | 啟用 |
| `[git_status]` | Dirty／staged／ahead／behind 狀態 | 啟用 |
| `[python]` | Python 版本 + virtualenv | 啟用（自動偵測） |
| `[nodejs]` | Node.js 版本 | 啟用（自動偵測） |
| `[rust]` | Rust 版本 | 啟用（自動偵測） |
| `[conda]` | Conda 環境名稱 | 啟用（搭配 `CONDA_CHANGEPS1=false`） |
| `[docker_context]` | Docker context | 啟用 |
| `[cmd_duration]` | 指令執行時間 | 啟用，超過 2 秒才顯示 |
| `[character]` | 提示字元 (`❯`) | 成功時綠色，錯誤時紅色 |

### 預設停用（值得啟用的）

```toml
# 在右側顯示時鐘
[time]
disabled = false
format = "[$time]($style) "
time_format = "%H:%M"

# 顯示使用者名稱／主機名（透過 SSH 自動顯示）
[username]
show_always = false    # 僅在 SSH 時顯示

[hostname]
ssh_only = true

# Kubernetes context
[kubernetes]
disabled = false

# 記憶體用量
[memory_usage]
disabled = false
threshold = 75         # 用量 > 75% 才顯示

# 電池（筆電）
[battery]
disabled = false

# AWS／GCP／Azure profile
[aws]
[gcloud]
[azure]
```

### 指令執行時間

```toml
[cmd_duration]
min_time = 2_000           # 指令耗時 > 2 秒才顯示
format = "took [$duration]($style) "
show_milliseconds = false
```

## 提示符版面 (Layout)

### 兩行式提示符

預設設定使用 `add_newline = true`，會在每次提示符之間加上一行空白。`[line_break]` 模組將資訊與輸入行分開：

```toml
# 第 1 行顯示資訊，第 2 行為輸入游標
format = """
$username\
$hostname\
$directory\
$git_branch\
$git_status\
$python\
$nodejs\
$rust\
$conda\
$line_break\
$character"""
```

### 右側提示符

把較不重要的資訊顯示在終端機右側：

```toml
right_format = "$time$cmd_duration"
```

## 自訂模組

為專案或工作流程建立自訂模組：

```toml
# 顯示目前 tmux 工作階段名稱
[custom.tmux]
command = "tmux display-message -p '#S' 2>/dev/null"
when = "test -n \"$TMUX\""
format = "[$output]($style) "
style = "bold cyan"

# 顯示目前 pueue 中執行中的任務數
[custom.pueue]
command = "pueue status --json 2>/dev/null | jq '[.tasks[] | select(.status == \"Running\")] | length'"
when = "command -v pueue"
format = "[$output tasks]($style) "
style = "yellow"
```

## 整合說明

- **oh-my-zsh**：仍會載入以使用其外掛 (plugin)（git aliases、autosuggestions、syntax-highlighting）。只停用主題（`ZSH_THEME=""`）。
- **Conda**：在 `04_conda_mamba.zsh` 設定了 `CONDA_CHANGEPS1=false`，因此由 starship 的 `[conda]` 模組負責環境顯示。
- **tmux2k**：tmux 狀態列 (status bar) 與 starship 互不相關；無衝突 (conflict)。
- **Nerd Fonts**：Alacritty 已設定使用 Hack Nerd Font Mono。如果是在沒有 Nerd Fonts 的終端機（例如 SSH 至 ubuntu_server），請套用 `plain-text-symbols` preset。

## 建議體驗順序

1. **套用並驗證** —— `chezmoi apply && exec zsh`（5 分鐘）
2. **試試 preset** —— 找到喜歡的視覺基底（10 分鐘）
3. **微調模組** —— 加入 `cmd_duration`、`time` 等等（15 分鐘）
4. **調整版面** —— 兩行式提示符、`right_format`（按需要）
5. **自訂模組** —— 為自己的工作流程做擴充（進階）

步驟 1-2 已足夠日常使用。步驟 3-5 可以漸進式調整。

## 參考資源

- 設定文件：<https://starship.rs/config/>
- 所有 preset：<https://starship.rs/presets/>
- 所有模組：<https://starship.rs/config/#prompt>
