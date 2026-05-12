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

## 選擇正確的目錄

寫新工具，或為既有工具的狀態重新安頓家時，用這份對照表。前四列屬於 XDG 規格 (specification)；後兩列是程式離開規格範圍後常用的位置。

| 資料類型 | 放哪 | 預設路徑 | 備註 |
|---|---|---|---|
| 重要設定（使用者需備份） | `XDG_CONFIG_HOME` | `~/.config/mytool/` | 可編輯、宣告式 — `config.toml`、`keymap.json`。重裝後仍應保留；可放進 dotfiles repo 提交。 |
| 重要資料（使用者需備份） | `XDG_DATA_HOME` | `~/.local/share/mytool/` | App 產生但不可替代：筆記資料庫、plugin 倉庫、下載的模型、生成的資產。 |
| 持久狀態 (state)（機器本地、不可攜） | `XDG_STATE_HOME` | `~/.local/state/mytool/` | History、undo tree、last-opened files、游標位置、log 檔。弄丟會煩，但會自動重建。 |
| 可重建的 cache | `XDG_CACHE_HOME` | `~/.cache/mytool/` | 編譯產物、下載的二進位、縮圖 tile。可隨時清除。 |
| 每個 session 的 runtime 檔 | `XDG_RUNTIME_DIR` | `/run/user/$UID/mytool/` | Unix socket、lock 檔、named pipe。Mode `0700`、tmpfs、登出即刪。**僅限 Linux** — macOS 不設定此變數，需 fallback 到 `$TMPDIR`。 |
| 一次性暫存 (ephemeral scratch) | `$TMPDIR`（或 `/tmp`） | `/tmp`（Linux）、`/var/folders/.../T/`（macOS） | 行程作用域的中介檔。**非 XDG 規範** — 屬於 POSIX/FHS。重開機後或被 `systemd-tmpfiles` / `tmpwatch` 清除。若 `$TMPDIR` 有設定，永遠優先用它；`mktemp -d -p "${TMPDIR:-/tmp}"`。 |

**決策原則（依序套用）：**

1. **「使用者弄丟了會難過嗎？」** — 會 → `CONFIG_HOME` 或 `DATA_HOME`；不會 → 進入下層分類。
2. **「是使用者親手寫的嗎？」** — 是 → `CONFIG_HOME`；不是、但 app 產生且不可替代 → `DATA_HOME`。
3. **「我能從原始碼/網路重生嗎？」** — 能 → `CACHE_HOME`；不能、且跨次執行保留會比較好 → `STATE_HOME`。
4. **「需要其他 process 找得到的 Unix socket / lock 嗎？」** — `RUNTIME_DIR`（Linux）/ `$TMPDIR`（macOS）。用穩定名稱（`$XDG_RUNTIME_DIR/mytool.sock`）讓對端找得到。
5. **「只在這次行程執行內有效嗎？」** — `mktemp -d -p "${TMPDIR:-/tmp}" mytool.XXXXXX` 並 `trap 'rm -rf "$tmp"' EXIT`。

**常見陷阱 (gotcha)：**

- `XDG_RUNTIME_DIR` 在 macOS 預設**不會**設定（沒有 systemd-logind）。硬寫此變數的工具會壞掉；跨平台慣用法是 `${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}`。
- Linux 上的 `/tmp` 不一定是 tmpfs（取決於 distro 與 `systemd-tmpfiles`）。不要假設它撐得過重開機；也不要假設它撐不過。
- XDG 規格**完全沒有**提到 `/tmp` — 那是 POSIX/FHS 的範疇。別把兩件事混在一起。
- `XDG_STATE_HOME` 是 spec **v0.8（2021）** 才加入的；較舊的工具早於此規格出現，常把 state 倒在 `XDG_DATA_HOME` 或 `~/.local/share/` 中 — 是歷史包袱，不是要去上游「修」的 bug。
- macOS 的 `~/Library/Application Support/` 是 `XDG_DATA_HOME` 的平台原生 (platform-native) 對應；許多跨平台 app 偵測到 Darwin 後改用它。這是預期行為，不算 regression。

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
