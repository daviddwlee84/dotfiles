# 語言伺服器 (Language servers, LSP)

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

[Language Server Protocol](https://microsoft.github.io/language-server-protocol/) 是一個與編輯器無關 (editor-agnostic) 的協定，用於程式碼智慧 (code intelligence)：診斷 (diagnostics)、滑鼠懸停 (hover)、跳到定義 (go-to-definition)、補完 (completion)、重新命名 (rename)、格式化 (formatting)、code actions。編輯器（*client*）會透過 stdio/TCP 啟動每種語言的 *server*，向它詢問緩衝區 (buffer) 相關的問題；伺服器只專精一種語言，編輯器則保持與語言無關。會在背後讀取原始碼的 coding agents（Claude Code、Cursor、OpenCode、Codex）也越來越常借助同一批伺服器，以取得型別感知 (type-aware) 的脈絡 (context)，而不僅僅是 grep 結果。

本倉庫從**三個獨立的介面 (surfaces)** 提供 LSP。混用是常態——每個介面的覆蓋範圍不同。

## 本倉庫中三個 LSP 介面

| 介面 | 由誰管理 | 狀態存放位置 | 何時使用 |
|---|---|---|---|
| **NeoVim + Mason** | `mason.nvim` 依需求自動下載 | `~/.local/share/nvim/mason/bin/` | 僅在 `nvim` 內的編輯器智慧。多數語言的預設選擇。 |
| **Claude Code 外掛市集 (plugin marketplace)** | Claude Code，透過 `~/.claude/settings.json` 中的 `enabledPlugins` 對應 | `~/.claude/plugins/` | 為 agent 讀緩衝區增加 LSP 脈絡。獨立於 nvim 安裝。 |
| **系統套件 (ansible / brew)** | `dot_ansible/roles/devtools/`、Brewfiles | `$PATH`（例如 `/opt/homebrew/bin/`、`~/.local/bin/`） | 僅當 LSP 同時也是有用的 CLI（linter、formatter、CI 工具）時。 |

同一個伺服器可以同時透過兩個介面安裝——它們以獨立的程序 (process)、獨立的執行檔執行，不會衝突。

## 目前已安裝項目

### 透過 NeoVim (LazyVim extras)

啟用的 extras 位於 [`dot_config/nvim/lazyvim.json`](../../dot_config/nvim/lazyvim.json)。每個 `lang.*` extra 在首次使用時會透過 Mason 拉入相應的 LSP、treesitter parser、formatter 與 linter：

| Extra | 涵蓋語言 | LSPs (透過 Mason) |
|---|---|---|
| `lazyvim.plugins.extras.lang.python` | Python | `basedpyright`、`ruff` |
| `lazyvim.plugins.extras.lang.json` | JSON / JSON5 / JSONC | `jsonls`（+ SchemaStore.nvim） |
| `lazyvim.plugins.extras.lang.markdown` | Markdown | `marksman`（+ `markdownlint-cli2`） |
| `lazyvim.plugins.extras.lang.toml` | TOML | `taplo` |
| `lazyvim.plugins.extras.lang.docker` | Dockerfile、docker-compose | `dockerls`、`docker-compose-language-service` |
| `lazyvim.plugins.extras.formatting.black` | Python（僅 formatter） | 不是 LSP——`black` 透過 `conform.nvim` |

LazyVim 的核心 spec 也會自動透過 `lazydev.nvim` 接上 **`lua_ls`**（Lua language server）——不需要 extras 檔。SchemaStore.nvim 載入一次後由 JSON / YAML LSP 共用。

[`create_lazy-lock.json`](../../dot_config/nvim/create_lazy-lock.json) 中的 LSP 基礎建設外掛 (plugins)：`nvim-lspconfig`、`mason.nvim`、`mason-lspconfig.nvim`、`nvim-cmp` + `cmp-nvim-lsp`、`conform.nvim`（formatting）、`nvim-lint`（linting）、`nvim-treesitter`、`lazydev.nvim`、`SchemaStore.nvim`。

> [`dot_config/nvim/lua/exact_plugins/example.lua`](../../dot_config/nvim/lua/exact_plugins/example.lua) 是**惰性 (inert) 的**——第 3 行為 `if true then return {} end`。它是一個範本，示範如何覆寫 LSP 伺服器設定，但並未被載入。不要把它當成實際的設定來讀；真實來源是 `lazyvim.json` 加上 `lua/exact_plugins/` 底下任何非 example 的檔案。

### 透過 Claude Code 外掛

[`dot_claude/modify_settings.json.tmpl`](../../dot_claude/modify_settings.json.tmpl) 將 `enabledPlugins` overlay 進 `~/.claude/settings.json`：

```json
"enabledPlugins": {
  "pyright-lsp@claude-plugins-official": true,
  "claude-hud@claude-hud": false
}
```

- **`pyright-lsp@claude-plugins-official`**——Claude Code 用的 Python LSP，來自官方市集。
- **`claude-hud@claude-hud`**——statusline 外掛，刻意設為 `false`。停用後，它那兩個只在安裝／設定時才用得到的指令（`claude-hud:setup` / `claude-hud:configure`）就不會再出現在每個 session 的 skill 清單裡——那正是它們唯一佔用的 context。HUD 本身不受影響：`statusLine.command` 是直接 glob `~/.claude/plugins/cache/claude-hud/*/` 並執行 `dist/index.js`，完全不經過外掛載入器。更新同樣不受影響——更新是走 [`claude_hud_sync.py`](../../dot_ansible/roles/coding_agents/files/claude_hud_sync.py)（`just upgrade-plugins`），它只會動 `installed_plugins.json` 與帶版本的快取目錄。詳見 [upgrades.md](../this_repo/upgrades.md)。

> 「LSP Plugin Recommendation」彈窗——就是你開啟 `.go` 檔時會推薦 `gopls-lsp@claude-plugins-official` 的那個——是 **Claude Code 自己的**功能，不是 claude-hud 的（它的 `src/` 裡沒有任何 LSP 相關程式碼）。claude-hud 停用後它照常運作。

該 overlay 透過一個能感知 hook 的 `jq` 腳本進行深度合併（[詳見](agent-overlays.md)），所以 Claude / CodeIsland 在 runtime 加入 `hooks.*` 陣列的內容會被保留，而不會被取代。

### 透過 ansible / 系統套件

- **`taplo`**——由 [`dot_ansible/roles/devtools/tasks/main.yml`](../../dot_ansible/roles/devtools/tasks/main.yml) 安裝（系統層級 CLI：`taplo fmt`、`taplo lint`）。注意：`lazyvim.plugins.extras.lang.toml` 也會自動把它裝進 Mason。兩個執行檔，都沒問題。

Runtime 先決條件（本身不是 LSP，但多數 LSP 需要它們）：

- `node` (LTS) 與 `tree-sitter-cli`，來自 `dot_ansible/roles/lazyvim_deps/tasks/main.yml`——Mason 在安裝 Node 系列的 LSP（jsonls、dockerls、vtsls、yamlls、bashls 等）時會用到。
- 位於 [`dot_config/mise/config.toml.tmpl`](../../dot_config/mise/config.toml.tmpl) 的 mise toolchains：`node lts`、`rust latest`、`dotnet latest`、`ruby 3`。日後新增 `lang.go` / `lang.rust` extra 時不需要新的 ansible 工作——Mason 會自動接上 toolchain。

## 建議新增項目

以下是尚未啟用但對本倉庫實際使用的語言以及使用者經常編輯的語言會有明顯價值的 LSP。每一項都列出在哪裡開啟開關——想用再開，不需要預先啟用。

| 語言 | NeoVim 路徑 | Claude Code 路徑 | 備註 |
|---|---|---|---|
| **Go** | `lazyvim.plugins.extras.lang.go`（透過 Mason 安裝 gopls + goimports） | `gopls-lsp@claude-plugins-official` | 這是截圖中的彈窗。Toolchain (Go) **沒有**由 mise 預先安裝——extra 會裝 gopls，但你需要另外把 `go` 放進 `$PATH`。 |
| **YAML** | `lazyvim.plugins.extras.lang.yaml`（yamlls + SchemaStore） | n/a | 對本倉庫價值高：`dot_ansible/`、GitHub Actions、MkDocs。SchemaStore 因 JSON 已載入。 |
| **Bash** | `lazyvim.plugins.extras.lang.bash`（bashls + shellcheck + shfmt） | n/a | 對 `dot_*scripts/` 與 `.chezmoiscripts/` 價值高。pre-commit 已使用 shellcheck。 |
| **Rust** | `lazyvim.plugins.extras.lang.rust`（透過 Mason 安裝 rust-analyzer） | n/a | Rust toolchain 已透過 mise 提供。 |
| **TypeScript** | `lazyvim.plugins.extras.lang.typescript`（vtsls） | n/a | Node 已安裝；惰性的 `example.lua` 引用的是較舊的 `tsserver` 設定，請忽略它，使用現代的 extra。 |
| **Lua** | 已啟用（LazyVim 預設透過 lazydev） | n/a | 不需要動作。 |

對於 Claude Code，官方市集為每種語言提供 `*-lsp@claude-plugins-official` 外掛；可在 Claude 內以 `/plugin list` 檢視可用項目，或在打開不熟悉的檔案類型時注意 claude-hud 彈窗。只啟用你實際會在 Claude 中編輯的語言對應的外掛——每一個都會增加啟動成本。

## 新增 LSP

### 加入 NeoVim

1. 在 `nvim` 內執行 `:LazyExtras`。以 `<CR>` 切換 `lang.<language>` 那一列。LazyVim 會把變更寫入 `~/.config/nvim/lazyvim.json`。
2. `lazyvim.json` 是本倉庫中正常追蹤的檔案（沒有 `create_` / `modify_` 字首），所以要傳播到其他機器需提交 diff：執行 `chezmoi re-add ~/.config/nvim/lazyvim.json`，再 `git -C "$(chezmoi source-path)" add` + commit。
3. 重新啟動 `nvim`；首次使用該語言時 Mason 會自動安裝執行檔。`:LspInfo` 可確認伺服器已掛上。

`create_lazy-lock.json` 是**只在第一次種下** ([原因](chezmoi-prefixes.md))——`chezmoi apply` 不會更新它。新增外掛後若要刷新 lock 基準：

```bash
cp ~/.config/nvim/lazy-lock.json "$(chezmoi source-path ~/.config/nvim/lazy-lock.json)"
```

### 加入 Claude Code

編輯 [`dot_claude/modify_settings.json.tmpl`](../../dot_claude/modify_settings.json.tmpl) → 在 `overlay` heredoc 內的 `enabledPlugins` 對應中加入：

```json
"enabledPlugins": {
  "pyright-lsp@claude-plugins-official": true,
  "claude-hud@claude-hud": false,
  "gopls-lsp@claude-plugins-official": true
}
```

接著 `chezmoi apply ~/.claude/settings.json`。能感知 hook 的合併器會保留 Claude / CodeIsland 在 runtime 加進 `hooks.*` 的條目。

### 加入 ansible（系統層級 CLI）

只在你也想要該 LSP 作為 CLI 工具放在 `$PATH`（例如 pre-commit 中的 linting、CI）時才這樣做。依照既有的 `taplo` 模式新增到 `dot_ansible/roles/devtools/tasks/main.yml`。若只是 nvim 內的智慧，請優先選擇 Mason——這樣執行檔不會出現在 `$PATH`，並讓 nvim 可獨立於系統套件管理版本。

## 跨工具備註

- **Mason 的 `pyright-language-server` vs Claude 的 `pyright-lsp@claude-plugins-official`**——獨立的程序、獨立的執行檔（Mason → `~/.local/share/nvim/mason/bin/`、Claude 外掛 → `~/.claude/plugins/`）。兩個 client（nvim、Claude）各自啟動自己的伺服器；沒有共用狀態。
- **`taplo` 的 ansible 安裝 vs Mason 安裝**——情況相同。ansible 安裝的執行檔在 `$PATH` 中供 shell 使用（`taplo fmt some.toml`），Mason 的執行檔則是 nvim 的 `lspconfig` 啟動的。兩者並存是刻意為之。
- **Toolchain ≠ LSP**——`mise` 提供語言 runtime，不是 LSP。`node lts` 讓 Mason 能安裝 JS 系列的 LSP；`rust latest` 讓 `lazyvim.plugins.extras.lang.rust` 不需額外設定即可運作。

## 陷阱 (Pitfalls)（與 LSP 相鄰）

- [`pitfalls/tree-sitter-cli-empty-native-binary.md`](../../pitfalls/tree-sitter-cli-empty-native-binary.md)——npm postinstall 有時會下載到空的 `tree-sitter` 執行檔；會影響 LSP 相鄰的語法工具。整體的健康檢查涵蓋了它。
- [`pitfalls/nvim-fs-find-enoent-stale-cwd.md`](../../pitfalls/nvim-fs-find-enoent-stale-cwd.md)——Neovim 0.12 啟動時，因 plugins (avante、lualine) 以過期 cwd 呼叫 `vim.fs.find` 而崩潰。這不是 LSP 特有的問題，但代表了你在新增伺服器時會碰到的外掛生態系脆弱性。

## 驗證

```bash
# 在 nvim 內
:Mason       # 列出已安裝的伺服器及其狀態
:LspInfo     # 顯示掛在目前緩衝區的伺服器
:checkhealth lsp

# Claude Code
ls ~/.claude/plugins/                 # 已安裝的外掛樹
jq .enabledPlugins ~/.claude/settings.json

# 系統 CLI
taplo --version
shellcheck --version

# 文件（編輯本頁後）
uv run mkdocs build --strict
```

## 另見

- [agent-overlays](agent-overlays.md)——Claude Code overlay 如何合併，包括 `enabledPlugins` 與 `@claude-plugins-official` 市集。
- [chezmoi-prefixes](chezmoi-prefixes.md)——為何 `lazy-lock.json` 使用 `create_` 以及如何刷新基準。
- [agent-skills](agent-skills.md)——Claude Code 的姊妹擴充介面（skills，不是 LSPs）。
