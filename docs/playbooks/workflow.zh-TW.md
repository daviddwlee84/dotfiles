# 開發工作流程 —— "Only type where you're going"

從接手專案、在 worktree 之間跳轉、到平行運行 AI coding agents 的端到端流程 —— 而且不必背 helper 函式名稱。

本文件是**索引**。深入細節請見
[`docs/tools/sesh.md`](../tools/sesh.md)（picker、layouts、sesh 設定）、
[`docs/tools/worktrunk.md`](../tools/worktrunk.md)（worktrees、平行 agent、hooks）以及
[`docs/tools/tmux/`](../tools/tmux/)（panes、popup menu、主題）。

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

---

## TL;DR —— 一個意圖一個按鍵

| Intent | Key | Where the key lives |
|---|---|---|
| 切換專案 / 開啟新專案 | `Alt+S`（在 tmux 外）或 `prefix+g`（在 tmux 內） | `smart-picker.sh` |
| 在當前專案內切換分支 (branch) | 在 picker 內 → `Ctrl+W` worktrees | `smart-picker.sh` |
| 啟動新的平行分支 + agent | `wt cc <branch> -- '<prompt>'` | [`worktrunk.md`](../tools/worktrunk.md#per-worktree-claude--opencode) |
| 偷看姊妹 worktree（不切換 session） | `wtcd`（fzf-tmux picker） | [`worktrunk.md`](../tools/worktrunk.md#the-wtcd-rationale) |
| 在當前 repo 重整 coding-agent layout | `scode`（手動覆寫） | [`sesh.md`](../tools/sesh.md) |

其他一切都由這五列說明。

---

## 那一個按鍵

- **在 tmux 外**（純 zsh prompt）：`Alt+S`
- **在 tmux 內**：`prefix + g`

兩者都會開啟同一個 fzf 彈出視窗 (popup)。相同熱鍵 (hotkey)、相同行為、相同分派 (dispatch) 邏輯。唯一差別是 tmux 外會生成一個全新的 tmux 客戶端 (client)，tmux 內則使用 `switch-client` —— 由 `sesh connect` 與 `_sesh_attach_or_switch` 透明處理。

### Picker 內的篩選模式

```
 ^a all         sesh list --icons
 ^t tmux        active tmux sessions only
 ^g configs     configured sesh sessions (from sesh.toml)
 ^x zoxide      zoxide frecency dirs  ← "type where I've been before"
 ^w worktrees   worktrees of the current repo  ← the worktrunk combo
 ^f find        fd walk from $HOME (depth 2)  ← when zoxide doesn't know yet
 ^d kill        kill the session under cursor, reload list
```

按下熱鍵 → 列表會以該來源重新載入。輸入文字以模糊篩選 (fuzzy-filter)。按 Enter 分派。

### 按下 Enter 時發生什麼 —— 智慧分派

Picker 不會問「要哪個 layout？」 —— 它根據你選的內容決定。

| Selection shape | Dispatch |
|---|---|
| 既有的 tmux session 名稱 | `sesh connect <name>` → switch/attach |
| 在 git repo 內的路徑（`.git` 目錄存在） | `scode -p <path>` → **coding-agent layout**（nvim 75% + agent 25% + btop window） |
| **不**在 git repo 內的路徑 | `sesh connect <path>` → 純 session（若路徑符合，`sesh.toml` 中的萬用 (wildcard) 模式仍勝出） |
| 已設定的 sesh session 名稱 | `sesh connect <name>` → 遵循 `startup_command` |

一句話規則：**git repo = scode layout；其他一切 = sesh 預設**。沒有第二層選單，不必記要打哪個 helper。

### 何時要覆寫智慧規則

Picker 是有主見的。若你想要別的，跳過 picker 直接呼叫 helper —— 四個都仍可用：

- `shere` —— 在 `$PWD` 的純 shell，無編輯器、無 git 要求
- `sroot` —— 遵循 `sesh.toml` 萬用模式與 `default_session.startup_command`
- `scode` —— coding-agent layout（需要 git repo）
- `svibe` —— 參數化的 multi-agent layout（需要 git repo）

完整 helper 規格請見 [`docs/tools/sesh.md`](../tools/sesh.md)。

---

## Sesh + worktrunk —— 三個正交軸

從 [`docs/tools/worktrunk.md`](../tools/worktrunk.md#mental-model) 偷來，因為這是讓整個流程豁然開朗的心智模型 (mental model)：

| Axis | Tool | Granularity | What the picker shows |
|---|---|---|---|
| **Project** | `sesh` | 每個 repo 一個 | `^t` + `^g` + `^x` 篩選器 |
| **Branch** | `wt`（worktrunk） | 專案中每個平行任務一個 | `^w` 篩選器 |
| **Pane** | `tmux` | 編輯器 / agent / logs / git | —（session 內的 layout） |

Picker = 軸 1 與軸 2 在同一個 popup 中。Worktrunk 自己的 `wt switch` / `wtcd` / `wt cc` 仍然存在 —— 當你想*建立* worktree 或*執行 hook* 時去找它們。Picker 是用於*跳轉*到既存的 worktree。

---

## 決策樹 —— 哪個工具用於哪個時刻

```
Am I starting from scratch (no session for this project yet)?
├── Project I use often           → Alt+S / prefix+g, type name, hit Enter
├── Project I haven't used before → Alt+S / prefix+g → ^f (find) → pick → Enter
└── Brand new empty dir           → cd there → shere (skips git check)

Am I already in a session for this project?
├── Want to jump to a sibling worktree  → Alt+S / prefix+g → ^w → pick
├── Want to just peek at one (no swap)  → wtcd
├── Want to spin up a fresh branch + Claude agent → wt cc <branch> -- '<prompt>'
└── Want to see all worktrees' agent progress     → wt list

Am I wrapping up?
├── Branch ready to merge       → wt merge main
├── Branch rejected / scratch   → wt remove
└── Session no longer needed    → Alt+S / prefix+g → ^t → ^d to kill
```

---

## 為何這能降低背誦負擔

之前：四個 helper 函式（`shere` / `sroot` / `scode` / `svibe`）、三個 worktrunk 命令（`wt switch` / `wt cc` / `wtcd`）、以及一個會為 zoxide 挑選的 repo 建立*錯誤* layout 的 sesh picker。要記七個名字，加上錯誤的預設值。

之後：兩個按鍵（`Alt+S` 與 `prefix+g` —— 行為相同）涵蓋每一個「我想去某處」的情境。Picker 對 git repo 自動挑選 coding-agent layout，常見情境再也不必輸入 `scode`。對於*建立*與*清理*，`wt cc` / `wtcd` / `wt merge` 仍是正確工具 —— 但對於*導航*，一個按鍵就夠。

---

## 注意事項 (Gotchas)

- **Picker 的 `^w` 只列出當前目錄所屬 repo 的 worktree。** 在任何 repo 之外會回傳空列表。這是 MVP 的刻意設計；跨專案 worktree 列舉需要已知專案清單，目前還不值得那份複雜度。
- **智慧分派使用 `.git` 目錄是否存在判斷。** 一個非 git 目錄若剛好符合某個 sesh 萬用模式（例如 `/Volumes/Data/Program/foo/bar` 沒有 `.git`），會獲得該萬用模式的 layout，而**不是** scode。如果你想要 scode，請直接呼叫 `scode -p <path>`。
- **`scode` 是從 bash picker 腳本透過 `zsh -ic` 呼叫的。** 表示每次按 picker-enter 都會啟動一個全新的 zsh 並 source 你的 zshrc 一次。夠快（約 50–150ms）但不是即時。若你看到延遲，那是 zshrc，不是 sesh。
- **在 tmux 外**，挑選任何項目都會用 `tmux attach-session` 取代你目前的 shell。Ctrl-B d 回去。沒辦法繞過這個 —— 這是 tmux 自己的設計。

---

## 交叉參考 (Cross-references)

- [`docs/tools/sesh.md`](../tools/sesh.md) —— sesh 設定、helpers、sesh.toml 萬用模式、tmuxp + tmuxinator layouts
- [`docs/tools/worktrunk.md`](../tools/worktrunk.md) —— worktree 工作流程、`wt cc` 平行 agent、hooks、`hash_port` 每個 worktree 的開發伺服器
- [`docs/tools/tmux/`](../tools/tmux/) —— tmux 設定、popup menu、OSC 52 剪貼簿、主題切換
- [`docs/shells/aliases.md`](../shells/aliases.md) —— 所有別名 (alias) 與函式都已收錄
- [`dot_config/tmux/executable_smart-picker.sh`](../../dot_config/tmux/executable_smart-picker.sh) —— picker 腳本本身（短小、註解完整）
- [`dot_config/sesh/sesh.toml`](../../dot_config/sesh/sesh.toml) —— 命名 session 與萬用模式

---

## 未來迭代（尚未啟用）

使用者會隨流程演進修訂本文件。候選項目追蹤於 [`TODO.md`](../../TODO.md) 與 [`backlog/`](../../backlog/README.md)：

- 在 `^w` 中跨專案列舉 worktree（掃描已知專案根目錄）
- 將 `projects` television 頻道作為替代入口
- Yazi 的 `Z` keymap → 將選定目錄管線傳給 smart picker
- `wt cc`-from-picker：挑選一個尚未存在的 worktree，在一次流程中提示輸入分支名稱 + agent prompt
- `specstory run` 整合到 `wt cc`（目前只有 `scode` / `svibe` 自動包裝 agent —— 詳見 [`worktrunk.md`](../tools/worktrunk.md#caveats) 中的注意事項）
