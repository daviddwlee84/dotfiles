# daviddwlee84/dotfiles

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

跨平台 (cross-platform) 開發環境設定，採用 [chezmoi](https://www.chezmoi.io/) 管理設定檔 (config files)、[ansible](https://docs.ansible.com/) 處理系統相依套件 (system dependencies)；針對 macOS 與 Ubuntu 上的 coding-agent 工作流程調校。

快速安裝路徑、支援平台表、以及「會得到什麼」清單，請參閱 [GitHub 上的 README.md](https://github.com/daviddwlee84/dotfiles/blob/main/README.md)——它是預設的第一站，刻意保留為唯一真實來源 (single source of truth)，不複製到這個站台。

## 從哪裡開始閱讀

### 想採用其中一部分功能的使用者

| 我想要… | 從這裡開始 |
|---|---|
| 把 shell 捲動歷史 (scrollback) 餵給 Claude / OpenCode / Codex | [**aicapture**](tools/aicapture.md) |
| 理解 tmux 設定（popup menu、OSC 133、copy-mode） | [tmux](tools/tmux/README.md) |
| 一眼掃過 tmux 鍵位 (keybindings) | [tmux keybindings](tools/tmux/keybindings.md) |
| 看完所有自訂的 zsh alias / function | [zsh aliases](zsh/aliases.md) |
| Sesh 工作階段 (session) 工作流程（shere / sroot / scode / svibe） | [sesh](tools/sesh.md) · [workflow playbook](playbooks/workflow.md) |
| 設定 agent CLI（claude / opencode / codex / cursor） | [agent overlays](tools/agent-overlays.md) |
| 透過 SSH 共用剪貼簿 (clipboard over SSH)（OSC 52、`x copy`、Neovim 整合） | [clipboard](tools/clipboard.md) |

### 給維護者

| 我想要… | 從這裡開始 |
|---|---|
| 理解整體架構 (architecture) | [architecture](this_repo/architecture.md) |
| 多主機部署 / `fleet-apply` | [fleet-apply](this_repo/fleet-apply.md) |
| 測試 / linting / pre-commit 的全貌 | [testing](this_repo/testing.md) · [pre-commit](tools/pre-commit.md) |
| 為什麼把 upgrade 從 install 拆出來 | [upgrades](this_repo/upgrades.md) |
| chezmoi 慣例（prefixes、templating、scripts 佈局） | [chezmoi prefixes](tools/chezmoi-prefixes.md) · [chezmoi templating](tools/chezmoi-templating.md) · [chezmoiscripts layout](this_repo/chezmoiscripts-layout.md) |
| 這個 repo 的設計空間 (design space) 研究（為什麼我們做了這些選擇） | [instant-LLM-fix prior art](this_repo/instant-llm-fix-prior-art.md) |

### Repo 維護者專屬介面

`TODO.md`、`backlog/`、`pitfalls/`、`CLAUDE.md`——這些是給 agent 看的維護介面，不是使用者文件。它們在站台中**有連結**便於探索，但檔案本身位於 repo 根目錄；參閱 [For Maintainers](for-maintainers.md)。

## 不採用整個 repo 也能試用

每個自包含 (self-contained) 的工具頁（例如 [aicapture](tools/aicapture.md)）都有「Standalone setup」段落，附上 `curl` 指令 + `~/.zshrc` 片段，你可以貼到任何 zsh 環境而不需 clone 整個 dotfiles repo。

## 站台慣例

- 所有真實來源 (source of truth) 內容都在 repo 的 [`docs/`](https://github.com/daviddwlee84/dotfiles/tree/main/docs) 之下。任何頁面的 GitHub blob URL 都可以替代這個站台。
- 每頁右上角的 `Copy to LLM` 按鈕會把當前頁面 dump 成可貼上的格式（適用於 Claude Code `claude -p` / OpenCode `opencode run` / pbcopy）。
- [llms.txt](llms.txt) / [llms-full.txt](llms-full.txt) 是站台自動產生的 manifest，方便 agent 讀取整個站台。
