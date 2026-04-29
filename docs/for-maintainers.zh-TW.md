# For Maintainers

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

這個 repo 有三個給 agent 看的介面 (agent-facing surfaces)，本站台**只引用，不發布為正式文件**——這是依照使用者的指示「reference yes, copy no」。它們都位於 repo 根目錄，可以直接在 GitHub 上閱讀。

## Agent contract

`CLAUDE.md`（別名：`AGENTS.md`、`GEMINI.md`——三者皆為同一檔案的 symlink）是給 agent 看的契約 (contract)：跨檔案維護規則 (cross-file maintenance rules)、repo 不變式 (hard invariants)、chezmoi 慣例。Coding agent 在這個 repo 進行修改前**必須**先讀過這個檔案。

→ [**CLAUDE.md**](https://github.com/daviddwlee84/dotfiles/blob/main/CLAUDE.md)

使用者自己保留的旁註 (out-of-band notes)（通常是進行中的想法 (work-in-progress thoughts)，不是長期文件）：

→ [NOTES.md](https://github.com/daviddwlee84/dotfiles/blob/main/NOTES.md)

## TODO index

`TODO.md` 是唯一的長期 backlog 索引。每一列帶有優先級標籤 (priority tag)（`P1` / `P2` / `P3` / `P?`）以及工作量標籤 (effort tag)（`S` / `M` / `L` / `XL`）。帶有 `→ [research](backlog/<slug>.md)` 連結的列有對應的設計筆記 / 調查報告。

→ [**TODO.md**](https://github.com/daviddwlee84/dotfiles/blob/main/TODO.md)

## Backlog (research / design notes)

`backlog/` 存放各主題的研究筆記，適用於：需要評估後才能決定是否實作的項目、有多個選項要比較的項目、或是暫停中的疑難排解 (paused troubleshooting)。每筆 entry 都依照 Context / Investigation / Options / Decision / References 範本。

→ [**backlog/** directory](https://github.com/daviddwlee84/dotfiles/tree/main/backlog) · [backlog/README.md](https://github.com/daviddwlee84/dotfiles/blob/main/backlog/README.md) · 完整索引在下方

與本站台所述的 aicapture 工作相關的範例：

- [`ai-capture-non-tmux-output`](https://github.com/daviddwlee84/dotfiles/blob/main/backlog/ai-capture-non-tmux-output.md) — 為什麼出貨 Tier 1 卻擱置 Tier 2（透明 tee）並排除 Tier 3（PTY proxy / `script(1)`）
- [`tmux-window-status-indicators`](https://github.com/daviddwlee84/dotfiles/blob/main/backlog/tmux-window-status-indicators.md) — option C（hook-based 語意狀態 (semantic state)）擱置
- [`starship-context-modules`](https://github.com/daviddwlee84/dotfiles/blob/main/backlog/starship-context-modules.md) — 已準備好啟用 status / cmd_duration / shlvl / container

## Pitfalls (symptoms-first knowledge base)

`pitfalls/` 是一個方便 grep 的「過去陷阱」目錄——每個 entry 以**症狀 (symptom)** 為標題，不是 root cause；保留逐字 (verbatim) 錯誤訊息，這樣未來碰到相同錯誤的 agent 可以立刻找到 workaround。

→ [**pitfalls/** directory](https://github.com/daviddwlee84/dotfiles/tree/main/pitfalls) · [pitfalls/README.md](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/README.md)

被本站台公開文件引用的範例：

- [`tmux-scrollback-tui-repaint-ghosting`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/tmux-scrollback-tui-repaint-ghosting.md) — 為什麼 Claude Code / OpenCode 的 scrollback 有時看起來有殘影
- [`zsh-osc133-precmd-printf-a-not-stored`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/zsh-osc133-precmd-printf-a-not-stored.md) — `%{...%}` 包覆 OSC 133 A marker 背後的 ZLE 時序陷阱 (ZLE timing trap)
- [`tmux-display-menu-silent-fail`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/tmux-display-menu-silent-fail.md) — menu 高度不合導致靜默失敗 (silent fail) 的除錯故事

## The project-knowledge-harness skill

TODO / backlog / pitfalls 三者統一由 `project-knowledge-harness` agent skill 管理。何時用哪個、命名慣例、以及「升格成 Hard invariant」(graduates to Hard invariant) 規則，都涵蓋在 [`CLAUDE.md`](https://github.com/daviddwlee84/dotfiles/blob/main/CLAUDE.md) → 「Long-term backlog + past pitfalls」段落中。

---

為什麼這些不是站台內容：

- **TODO.md / backlog/ / pitfalls/** 是*動態*的——隨著使用者提出新想法、debug 新陷阱，commit 一條條地變化。把它們複製進站台會在「渲染後的頁面」與「GitHub 上活的原始檔」之間造成漂移 (drift)。一個只引用的頁面（也就是這頁）讓真實來源 (single source of truth) 留在 repo 根目錄。
- **CLAUDE.md** 是給 agent 操作用的文字 (agent-operational text)，不是給終端使用者看的文件。它刻意為「即將修改這個 repo 的 coding agent」而寫。沒有列在主 nav 中，但在這裡連結出來以保持透明。
