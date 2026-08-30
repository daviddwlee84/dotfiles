# Zsh 補全最佳實踐

本 dotfiles 專案中 zsh 自動補全 (tab completion) 的組織方式。

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

## 架構 (Architecture)

```
compinit runs once (inside oh-my-zsh.sh)
        │
        ├── ~/.zfunc/                          ← user-generated completions (NOT tracked by chezmoi)
        ├── ~/.oh-my-zsh/custom/plugins/       ← community completions (184 files, cloned by ansible)
        │     └── zsh-completions/src/
        ├── ~/.docker/completions/             ← Docker-shipped completions
        ├── $(brew --prefix)/share/zsh/        ← Homebrew-managed completions (via `brew completions link`)
        │     └── site-functions/
        └── $ZSH/completions/                  ← oh-my-zsh built-in completions
```

所有 `fpath` 的新增都在 `dot_zshrc.tmpl` 中、且**位於** `source "$ZSH/oh-my-zsh.sh"` 之**前**，因此 `compinit` 只會執行一次並載入所有項目。

## 補全分類 (Completion Categories)

工具可分為四大類：

### A. 自我產生 (`tool completion zsh > ~/.zfunc/_tool`)

大多數現代 CLI 工具能夠輸出自己的補全腳本 (script)。安裝後執行一次，版本升級後重新執行。

| Tool | Command |
|------|---------|
| `uv` | `uv generate-shell-completion zsh` |
| `mise` | `mise completion zsh` |
| `chezmoi` | `chezmoi completion zsh` |
| `just` | `just --completions zsh` |
| `bat` | `bat --completion zsh` |
| `delta` | `delta --generate-completion zsh` |
| `starship` | `starship completions zsh` |
| `rg` | `rg --generate complete-zsh` |
| `fd` | `fd --gen-completions zsh` |
| `zellij` | `zellij setup --generate-completion zsh` |
| `sesh` | `sesh completion zsh` |
| `pueue` | `pueue completions zsh` |
| `docker` | `docker completion zsh` |
| `gh` | `gh completion -s zsh` |
| `opencode` | `opencode completion zsh` |
| `omp` | `omp completions zsh` |
| `translate` | `translate completion zsh` |
| `dev` | `dev completion zsh` |
| `bw` | `bw completion --shell zsh` |

Fresh apply 若尚未重載 PATH，bulk generator 也會探測
`~/.local/bin/<tool>`；因此剛安裝的 OMP 不需要第二次開 shell／apply 就能
生成 completion。

**使用模式：**

```bash
# 產生一次（或升級後）
mkdir -p ~/.zfunc
uv generate-shell-completion zsh > ~/.zfunc/_uv
mise completion zsh > ~/.zfunc/_mise
```

### B. 預先打包（無需動作）

補全隨套件 (package) 一起出貨，或經由 `zsh-completions` 社群外掛 (plugin) 提供。

| Tool | Source |
|------|--------|
| `eza` | Homebrew formula 將 `_eza` 安裝到 site-functions |
| `git` | oh-my-zsh `git` plugin |
| `yazi` | release 資產中包含 `_yazi`（zsh-completions 也有） |
| `lazygit` | 不支援補全；不需要（TUI app） |
| `btop` | 不支援補全；不需要（TUI app） |
| 其他眾多工具 | `zsh-completions` plugin 涵蓋 184 個工具 |

### C. 啟動時 eval/source（shell 整合）

這些工具在更廣泛的 shell 整合中注入補全。已在 `dot_config/zsh/tools/` 中處理。

| Tool | Where | How |
|------|-------|-----|
| `fzf` | `tools/10_fzf.zsh` | `source <(fzf --zsh)` |
| `zoxide` | `tools/20_zoxide.zsh` | `eval "$(zoxide init zsh)"` |
| `thefuck` | `tools/25_thefuck.zsh` | `eval $(thefuck --alias)` |
| `direnv` | `tools/30_direnv.zsh` | `eval "$(direnv hook zsh)"` |
| `marimo` | `tools/29_marimo.zsh` | `eval "$(_MARIMO_COMPLETE=zsh_source marimo)"` |

### D. 不支援補全

`claude`、`gemini`、`btop`、`lazygit` —— 沒有可用的產生命令。

### E. 透過 `shtab` / `tyro` 的 Python 工具

Python CLI 框架 (framework) 可以產生補全：

- **[tyro](https://brentyi.github.io/tyro/tab_completion/)**：`python my_cli.py --tyro-write-completion zsh ~/.zfunc/_my_cli`
- **[shtab](https://github.com/iterative/shtab)**：`shtab --shell=zsh my_module.parser > ~/.zfunc/_my_tool`
- **argcomplete**：`register-python-argcomplete tool_name`（使用 eval，屬於 C 類）
- **click**（mlflow、litellm 等使用）：`_TOOL_COMPLETE=zsh_source tool > ~/.zfunc/_tool`

## 為何 `~/.zfunc/` **不**由 chezmoi 追蹤

**決定：`~/.zfunc/` 不納入版本控制。** 理由：

1. **補全與工具版本相依。** 由 `uv 0.6` 產生的補全腳本可能不符合 `uv 0.7`。追蹤過時檔案會造成隱微的損壞。
2. **不是所有使用者都安裝相同工具。** 若沒安裝 pueue，`_pueue` 補全檔案毫無用處（且會丟出警告）。
3. **重新產生很簡單。** 每個工具只需要一行命令。
4. **Brew 安裝的工具自動管理其補全**，透過 site-functions。在 `~/.zfunc/` 中重複會造成衝突。

### 我們**有**追蹤的內容

- `dot_zshrc.tmpl` 中的 `fpath+=~/.zfunc`（確保此目錄在搜尋路徑中）
- 由 ansible 複製 (clone) 的 `zsh-completions` 外掛（社群補全）
- `~/.docker/completions` 的 fpath 條目
- `dot_config/zsh/tools/` 中工具特定的 `eval`/`source` 整合

## 全新安裝後產生補全

在新機器上執行 `chezmoi apply` 後，多數補全已可透過 `zsh-completions` 外掛和 Homebrew site-functions 運作。對於想要**更豐富/更新版補全**的工具，可將其產生到 `~/.zfunc/`：

```bash
mkdir -p ~/.zfunc

# 核心工具（永遠安裝）
chezmoi completion zsh > ~/.zfunc/_chezmoi
mise completion zsh > ~/.zfunc/_mise
uv generate-shell-completion zsh > ~/.zfunc/_uv
just --completions zsh > ~/.zfunc/_just
starship completions zsh > ~/.zfunc/_starship

# 開發工具（若已安裝）
command -v gh    && gh completion -s zsh > ~/.zfunc/_gh
command -v docker && docker completion zsh > ~/.zfunc/_docker
command -v rg    && rg --generate complete-zsh > ~/.zfunc/_rg
command -v fd    && fd --gen-completions zsh > ~/.zfunc/_fd
command -v bat   && bat --completion zsh > ~/.zfunc/_bat
command -v delta && delta --generate-completion zsh > ~/.zfunc/_delta
command -v zellij && zellij setup --generate-completion zsh > ~/.zfunc/_zellij
command -v sesh  && sesh completion zsh > ~/.zfunc/_sesh
command -v pueue && pueue completions zsh > ~/.zfunc/_pueue

# Coding agents（若已安裝）
command -v opencode && opencode completion zsh > ~/.zfunc/_opencode
command -v omp   && omp completions zsh > ~/.zfunc/_omp
command -v bw    && bw completion --shell zsh > ~/.zfunc/_bw

# 強制重建補全快取
rm -f ~/.zcompdump && compinit
```

> **小提示：** 你可以將其儲存為 `~/.local/bin/` 中的腳本，或將其作為函式 (function) 加入 `~/.zshrc.adhoc`。

## 優先順序 / 覆寫順序

當同一個 `_tool` 檔案存在於多個 fpath 目錄中時，**第一個符合者勝出**：

```
1. ~/.zfunc/                                    (最高 - 你的覆寫)
2. ~/.oh-my-zsh/custom/plugins/zsh-completions/src/
3. ~/.docker/completions/
4. $(brew --prefix)/share/zsh/site-functions/   (Homebrew-managed)
5. /usr/share/zsh/*/functions/                  (system, lowest)
```

目前 `dot_zshrc.tmpl` 的順序：

```zsh
fpath+=~/.zfunc                     # appended (lowest of custom)
fpath=(zsh-completions/src $fpath)  # prepended (higher than ~/.zfunc)
fpath=(~/.docker/completions $fpath) # prepended (highest of custom)
```

若你希望 `~/.zfunc/` 覆寫社群補全，改為前置 (prepend)：

```zsh
fpath=(~/.zfunc $fpath)  # prepend instead of append
```

## FAQ

**Q：對於 `zsh-completions` 已涵蓋的工具，我還應該產生補全嗎？**
A：只有當你想要最新版本時。社群外掛可能落後。對於快速演進的工具（uv、mise），自行產生是值得的。

**Q：解除安裝某工具後，補全檔案丟出錯誤，該怎麼辦？**
A：移除該檔案：`rm ~/.zfunc/_toolname`。fpath 中過時的 `_tool` 檔案除非有語法錯誤，否則無害（會被靜默忽略）。

**Q：我該如何除錯補全問題？**
A：執行 `echo $fpath | tr ' ' '\n'` 查看所有 fpath 條目。使用 `which _toolname` 查看正在使用哪個補全檔案。透過 `rm -f ~/.zcompdump && compinit` 強制重建。
