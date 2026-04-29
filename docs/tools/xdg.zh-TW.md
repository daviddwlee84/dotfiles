# XDG Base Directory Specification

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

本 repo 中的多數設定 (config) 都放在 `~/.config/`、`~/.local/share/`、`~/.local/state/` 或 `~/.cache/` 下，而不是 `$HOME` 中的 dot-files。這個佈局遵循 [XDG Base Directory Specification](https://specifications.freedesktop.org/basedir/latest/)。

## 核心環境變數

| 變數 | 預設值 | 用途 |
|----------|---------|---------|
| `XDG_CONFIG_HOME` | `~/.config` | 使用者設定檔 |
| `XDG_DATA_HOME` | `~/.local/share` | 使用者應用程式資料 |
| `XDG_STATE_HOME` | `~/.local/state` | 使用者狀態（log、history、undo） |
| `XDG_CACHE_HOME` | `~/.cache` | 使用者非必要的快取資料 |
| `XDG_RUNTIME_DIR` | （登入時設定） | 每個 session 的執行期檔案（socket 等） |

## 為什麼重要

- **乾淨的 `$HOME`**：舊有「每個 app 都倒一個 `~/.foo` dotfile」的模式很快就吵雜不堪。
- **可預測的工具**：備份、同步、dotfile 管理工具（如 chezmoi）都受惠於單一已知的目錄樹。
- **易於清除**：清掉 `~/.cache/foo` 不會動到設定；清掉 `~/.local/state/foo` 不會弄丟設定值。

## 各工具狀態（在本 repo 中）

| 工具 | XDG 原生支援？ | 我們放在哪 |
|------|-------------|------------------|
| tmux | 是（3.1+） | `~/.config/tmux/tmux.conf`（外加 `~/.tmux.conf` shim） |
| Neovim | 是 | `~/.config/nvim/` |
| Zellij | 是 | `~/.config/zellij/` |
| Starship | 是 | `~/.config/starship.toml` |
| Alacritty | 是 | `~/.config/alacritty/` |
| Ghostty | 是 | `~/.config/ghostty/` |
| Yazi | 是 | `~/.config/yazi/` |
| bat | 是 | `~/.config/bat/` |
| direnv | 是 | `~/.config/direnv/` |
| gh | 是 | `~/.config/gh/` |
| gh-dash | 是 | `~/.config/gh-dash/` |
| LazyGit | 是 | `~/.config/lazygit/` |
| Sesh | 是 | `~/.config/sesh/` |
| uv | 是 | `~/.config/uv/` |
| Bun | 是 | `~/.config/.bunfig.toml` |
| Homebrew Bundle | N/A | `~/.config/homebrew/`（我們的慣例） |
| Claude Code | 否 | `~/.claude/` |
| SSH | 否 | `~/.ssh/`（規格未涵蓋） |
| Git | 部分 | `~/.gitconfig`（repo 也使用 `~/.config/git/hooks/`） |
| npm | 是 | `~/.npmrc`（透過 `$HOME`；雖有 XDG 支援，但多數工具仍寫到 `~/.npmrc`） |
| Cargo | 部分 | `~/.cargo/config.toml`（遵守 `CARGO_HOME`，並非直接遵守 XDG） |

標示「否」或「部分」的工具會保留 `$HOME` 的舊路徑，原因是上游尚未遷移，或工具早於規格出現；我們跟著工具實際讀取的位置走。

## 本 repo 如何處理

- chezmoi 來源路徑如 `dot_config/<tool>/...` 在 apply 時會對應到 `~/.config/<tool>/...`。這是我們採納 XDG 的主要途徑。
- 舊路徑（例如 `~/.tmux.conf`、`~/.gitconfig`）在工具仍預期的情況下保留為 shim 或頂層檔案，通常從中 source 真正放在 XDG 位置的設定。
- 對於 state/data/cache：我們很少 commit 這些 — 它們是執行期生成的，刻意排除在 repo 之外。

## 延伸閱讀

- [freedesktop.org spec](https://specifications.freedesktop.org/basedir/latest/)
- [Arch Wiki — XDG Base Directory](https://wiki.archlinux.org/title/XDG_Base_Directory) — 一份持續更新的清單，列出哪些工具原生遵守此規格、哪些需要繞道。
