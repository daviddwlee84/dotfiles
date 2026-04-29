# fzf 快速參考

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

[fzf](https://github.com/junegunn/fzf) — 命令列模糊比對 (fuzzy finder) 工具。

設定檔來源 (source)：`dot_config/zsh/tools/10_fzf.zsh`

---

## Shell 鍵位綁定 (keybindings)

| 按鍵 | 動作 (action) | 預覽 (preview) |
|-----|--------|---------|
| `Ctrl+T` | 在游標處插入模糊比對到的檔案路徑 | `bat` 語法高亮（500 行） |
| `Ctrl+R` | 模糊搜尋指令歷史 | — |
| `Alt+C` | 模糊比對目錄並 `cd` 進入 | `eza --tree`（200 行） |

---

## 環境變數 (environment variables)

```bash
# 套用到所有 fzf 呼叫的基礎選項
FZF_DEFAULT_OPTS="--height 40% --layout=reverse --border"

# 使用 fd 取代 find（遵守 .gitignore，速度更快）
FZF_DEFAULT_COMMAND="fd --hidden --strip-cwd-prefix --exclude .git"

# Ctrl+T：檔案選擇器 (picker)
FZF_CTRL_T_COMMAND="fd --hidden --strip-cwd-prefix --exclude .git"
FZF_CTRL_T_OPTS="--preview 'bat -n --color=always --line-range :500 {}'"

# Alt+C：目錄選擇器
FZF_ALT_C_COMMAND="fd --type=d --hidden --strip-cwd-prefix --exclude .git"
FZF_ALT_C_OPTS="--preview 'eza --tree --color=always {} | head -200'"
```

---

## Tab 補全預覽 (`_fzf_comprun`)

使用 fzf 驅動的 tab 補全時，預覽會依指令而變：

| 指令 | 預覽 |
|---------|---------|
| `cd` | `eza --tree --color=always`（備援：`tree -C`） |
| `export`、`unset` | `echo ${<var>}` — 顯示目前變數值 |
| `ssh` | `dig <host>` — DNS 查詢 |
| *(預設)* | `bat -n --color=always --line-range :500` |

---

## fzf-tmux 整合

`sesh-sessions` 小工具 (widget)（綁定到 `Alt+S`）使用 `fzf-tmux -p 80%,70%` 在 tmux 中開啟浮動彈出視窗 (popup)。session 選擇器的鍵位綁定請見 `docs/tools/sesh.md`。

---

## 小技巧

- **模糊語法**：以空格分隔的多個 token 視為 AND；`!` 為否定；`^` 錨定開頭；`$` 錨定結尾
  - 範例：`^foo bar !baz$` — 開頭為 "foo"、包含 "bar"、不以 "baz" 結尾
- **多選 (multi-select)**：傳入 `--multi`（或 `-m`）以啟用 `Tab`/`Shift+Tab` 進行多選
- **預覽切換**：`Ctrl+/` 切換預覽面板（內建預設值）
