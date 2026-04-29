# aicapture — AI 審視過往 shell 指令

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

從 tmux 的捲動歷史 (scrollback) 中捕捉 (capture) 某個過往 shell 指令的區塊 (block)，以非互動模式管線 (pipe) 傳送給 coding-agent CLI（`Claude Code` / `OpenCode` / `Codex` / `Cursor Agent`），取回修正建議或解釋。預設為諮詢模式：agent 只印出建議，不會動到任何檔案。

底層基於 [OSC 133 semantic prompts](https://gitlab.freedesktop.org/Per_Bothner/specifications/blob/master/proposals/semantic-prompts.md)——shell 發出 `A`/`C`/`D` 行屬性標記 (line-attribute markers)，tmux 將其儲存，我們的輔助腳本依其導航。關於與 `thefuck`、Warp、`wut`、`tmuxai`、`atuin` 等工具的比較背景，請見 [instant-llm-fix-prior-art.md](../this_repo/instant-llm-fix-prior-art.md)。

## 快速開始

```sh
# 任何產生有用輸出或錯誤的指令……
cargo build --release

# ……一個按鍵就能取得診斷與修正：
aifix
```

終端機輸出：

```
aifix ← block -1
⠋ claude haiku (json)…                                  # agent 思考時的 spinner
claude (claude-haiku-4-5-20251001) | in=12 out=87 cache=(r:24402,w:12487) | cost=$0.0008 3812ms

## Fix for `cargo build` error

Your `Cargo.toml` is missing the `serde` dependency. Add:

    [dependencies]
    serde = { version = "1.0", features = ["derive"] }

Then re-run `cargo build --release`.
```

回覆透過 `glow` 渲染為 Markdown（自動降級為 `bat --language=md`，若兩者皆未安裝則為純文字）。

## 指令

### Capture（不呼叫 AI）

每個指令都會將捕捉到的文字印出至 stdout（適合管線使用）**並**透過 tmux 的 OSC 52 橋接複製到系統剪貼簿 (clipboard)（在 SSH 上也能運作）。預設為 N=1（最近一筆）；傳入正整數可往回查找 N 筆。

| 指令 | 範圍 |
|---|---|
| `cpcmd [N]` | 倒數第 N 筆指令的**輸入行** (input line)（取自 zsh 歷史——在 tmux 之外也能用） |
| `cpout [N]` | 倒數第 N 筆指令的**輸出**（透過 tmux + OSC 133） |
| `cpblock [N]` | 倒數第 N 筆指令的**完整區塊**：prompt + 輸入 + 輸出（Warp 風格） |

```sh
cpblock                          # 最後一個 block → 剪貼簿 + stdout
cpblock 3                        # 倒數第 3 筆
cpout 2 | tee /tmp/snapshot.log  # 將輸出管線給檔案的同時也複製
cpcmd                            # 只取指令字串（無輸出）
```

### AI 審視

與捕捉輔助函式相同的位置參數 `[N]`，加上 flag：

| 指令 | 預設 prompt |
|---|---|
| `aifix [N]` | *"Diagnose any errors and suggest a concrete fix. Be brief and specific."* |
| `aiexplain [N]` | *"Explain what happened in plain language. Be concise."* |

兩者皆接受：

- `-a AGENT` — `claude` / `opencode` / `codex` / `cursor-agent`。預設：自動偵測 (auto-detect)（`$PATH` 上找到的第一個）。
- `-p PROMPT` — 覆寫 (override) 預設 prompt。
- `--raw` — 跳過 glow/bat 美化；印出 agent 的原始 Markdown 文字。
- `--no-meta` — 抑制 stderr 的 metadata 行（模型 / tokens / 成本 / 持續時間）。
- `-h` / `--help` — 印出完整簽章與目前的環境變數值。

```sh
aifix                               # 最後一個 block，預設 fix prompt
aifix 3 -a opencode                 # 倒數第 3 筆，強制使用 OpenCode
aifix -p "is this safe on prod?"    # 自訂 prompt
aiexplain 2 --raw                   # 不美化
aifix --no-meta | tee /tmp/ans.md   # 適合管線
```

### 互動式 TUI

```sh
aiblock
```

啟動一個 [questionary](https://github.com/tmbo/questionary) + [rich](https://github.com/Textualize/rich) TUI（[`scripts/aiblock.py`](../../scripts/aiblock.py)），引導你完成：

1. **核取方塊挑選器 (checkbox picker)**：列出最近 20 筆指令。Space 切換、Enter 確認。未選任何項目時預設為「最後一個 block」。
2. **預覽** — 每個選中的 block 顯示在自己的 rich 面板中（多選會依時間順序串接，並以 `--- Block -N ---` 分隔，讓 agent 能分辨各回合）。
3. **編輯 prompt** — 預設為 `aifix` 的 fix-prompt；可即時編輯。
4. **動作** — 選擇下列其一：
   - *Print reply here* — 在 rich 面板中渲染為 Markdown，並以 metadata 為副標題。
   - *Copy reply to clipboard* — 透過 tmux OSC 52 / `pbcopy` / `xclip` / `xsel` / `wl-copy`。
   - *Spawn new tmux window running `<agent>`* — 開啟一個新的互動 agent 工作階段，並將你選中的 block 預先載入 tmux 的 `aiblock` 貼上緩衝區 (paste-buffer)。透過 `prefix + =` 取出。

此 TUI 依賴 `uv`（PEP 723 內嵌依賴）——不需另外安裝步驟；首次執行時會填充 uv 的快取 (cache)。

## 非 tmux 替代方案

當你不在 tmux 中（VSCode 內建終端機、未掛 tmux 的純 Ghostty、快速 SSH 工作階段），`cpblock` / `aifix` / `aiexplain` / `aiblock` 看不到捲動歷史——它們仰賴 tmux 的 OSC 133 行屬性。三個 Tier 1 包裝函式涵蓋了常見情境，沒有任何魔法（沒有 shell hook、沒有 PTY proxy、沒有 `script(1)` 包裝——拒絕這些路徑的原因見 [`backlog/ai-capture-non-tmux-output.md`](../../backlog/ai-capture-non-tmux-output.md)）：

| 指令 | 內容來源 | 典型用途 |
|---|---|---|
| `aifix-stdin` | 你管線傳入的任何內容 | `tail -100 build.log \| aifix-stdin` |
| `aifix-run -- CMD [ARG...]` | 執行 `CMD`，將 stdout+stderr 同時 tee 到一個 log，然後審視 | `aifix-run -- cargo build --release` |
| `aifix-rerun` | 重新執行前一個 shell 指令（會確認） | 暫時性錯誤後執行 `aifix-rerun` |

三者皆接受與 `aifix` 相同的 flag（`-a AGENT` / `-p PROMPT` / `--raw` / `--no-meta`）。`aifix-rerun` 額外提供 `-y` 以跳過「⚠ side effects」確認。每個指令的預設 prompt 都是 `aifix` 的「diagnose + fix」；若想要解釋行為，使用 `-p "explain what happened"`。

```sh
# stdin — 與任何產出來源組合
tail -200 /var/log/nginx/error.log | aifix-stdin
curl -sS https://weird.api/thing | aifix-stdin -p "what is this JSON telling me?"
aifix-stdin < /tmp/build-fail.log

# run — 捕捉一次新的呼叫（重複執行安全，不需要既有歷史）
aifix-run -- ls /missing
aifix-run -p "is this safe on prod?" -- ansible-playbook deploy.yml

# rerun — thefuck 風格，重新執行最後一個指令。預設會確認。
mvn compile      # 失敗
aifix-rerun      # "⚠ side effects…  Proceed? [y/N]"
aifix-rerun -y   # 跳過確認
```

**`aifix-run` 的 isatty 注意事項**：tee 會讓 CMD 的 stdout 變成管線，因此 TUI 應用程式（vim、less、htop）會以降級模式渲染。請勿對互動式工具使用 `aifix-run`——事後改用 `aifix-stdin` 將其 log 檔案管線傳入即可。

**`aifix-rerun` 的副作用警告**：重新執行 `rm`、`curl -X POST`、`git push`、migrations 等是危險的。確認 prompt 之所以存在是有道理的；不要在沒看清楚將要重新執行什麼的情況下加 `-y`。

## 設定 (Configuration)

將下列任何項目放入 `~/.zshrc`、`99_local_*.zsh` 覆寫檔，或於每次工作階段時匯出：

```sh
# 每個 agent 的模型（自動偵測順序：claude → opencode → codex → cursor-agent）
export AICAP_CLAUDE_MODEL=haiku                              # 別名或完整名稱（例如 claude-sonnet-4-6）
export AICAP_OPENCODE_MODEL=github-copilot/claude-haiku-4.5  # provider/model 格式
export AICAP_CODEX_MODEL=gpt-5-mini
export AICAP_CURSOR_MODEL=                                    # 空值 = 由 cursor-agent 自行決定

# 輸出行為
export AICAP_SHOW_METADATA=1   # 0 表示靜音 stderr 的 "claude (...) | in=... cost=..." 行
export AICAP_PRETTIFY=1        # 0 表示永遠印出原始 Markdown（跳過 glow/bat）
export AICAP_SPINNER=1         # 0 表示停用 stderr spinner 動畫
```

任何時候都可以用 `aifix --help` 檢查目前的設定。

預設值針對 Haiku 等級的模型調校——快速（約 5 秒往返）且便宜（命中快取時約每次 $0.001）。若想用 Opus/Sonnet 處理較困難的診斷，可全域或每次呼叫時設定 `AICAP_CLAUDE_MODEL=sonnet`：

```sh
AICAP_CLAUDE_MODEL=sonnet aifix 3
```

## 需求

| 項目 | 用途 |
|---|---|
| `zsh` | 全部指令（cpcmd、aifix 等都是 zsh 函式） |
| `tmux 3.3+` | `cpout` / `cpblock` / `aifix` / `aiexplain` / `aiblock`（捲動歷史導航） |
| OSC 133 shell integration | `dot_config/zsh/tools/02_shell_integration.zsh` 中的掛鉤 (hook) 會發出 tmux 需要的 A/C/D 標記。安裝後執行 `exec zsh` 讓掛鉤在目前的 shell 中生效。 |
| 至少一個 coding-agent CLI | `claude`（建議）、`opencode`、`codex`，或 `cursor-agent`——透過你慣用的管道安裝 |
| `glow`（選用） | agent 回覆的 Markdown 美化 |
| `bat`（選用） | 沒有 `glow` 時的美化備援 |
| `jq`（選用） | 解析 Claude 的 `--output-format json` 以產生 metadata 行（tokens / 成本） |
| `uv`（選用） | 僅 `aiblock` TUI 需要——會延遲安裝其 Python 依賴 |

## 獨立安裝（不使用 chezmoi）

若你不想採用整個 dotfiles repo，可以抓下這四個檔案並從你的 `~/.zshrc` source 它們。除了上述列出的選用工具之外，它們是自成一體的。

```sh
REPO=https://raw.githubusercontent.com/daviddwlee84/dotfiles/main
mkdir -p ~/.config/zsh/tools

# Shell 端：OSC 133 掛鉤 + cpblock 系列 + aifix 系列
for f in 02_shell_integration.zsh 03_tmux_capture.zsh 04_ai_capture.zsh; do
  curl -fsSL "$REPO/dot_config/zsh/tools/$f" -o "$HOME/.config/zsh/tools/$f"
done

# 選用 TUI（需要 uv）
mkdir -p ~/.local/share/aicapture
curl -fsSL "$REPO/scripts/aiblock.py" -o ~/.local/share/aicapture/aiblock.py
chmod +x ~/.local/share/aicapture/aiblock.py

# 附加到 ~/.zshrc（或同等檔案）
cat >> ~/.zshrc <<'EOF'
for f in ~/.config/zsh/tools/02_shell_integration.zsh \
         ~/.config/zsh/tools/03_tmux_capture.zsh \
         ~/.config/zsh/tools/04_ai_capture.zsh; do
  [[ -r "$f" ]] && source "$f"
done
EOF

# 重新載入
exec zsh
```

`aiblock` shell 函式會透過 `chezmoi source-path` 解析 TUI 路徑；若你不在 chezmoi 上，請編輯 `04_ai_capture.zsh` 中的 `aiblock()` 函式，改指向 `~/.local/share/aicapture/aiblock.py`：

```zsh
# 將 chezmoi source-path 區塊替換為：
_AIBLOCK_SCRIPT="$HOME/.local/share/aicapture/aiblock.py"
```

### 在 GitHub 上閱讀原始碼

- [`dot_config/zsh/tools/02_shell_integration.zsh`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/zsh/tools/02_shell_integration.zsh) — OSC 133 precmd/preexec 掛鉤（A 標記透過 `%{...%}` 嵌入 `$PROMPT`——原因見 [`pitfalls/zsh-osc133-precmd-printf-a-not-stored.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/zsh-osc133-precmd-printf-a-not-stored.md)）
- [`dot_config/zsh/tools/03_tmux_capture.zsh`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/zsh/tools/03_tmux_capture.zsh) — cpout / cpcmd / cpblock + tmux copy-mode 鏈式輔助函式
- [`dot_config/zsh/tools/04_ai_capture.zsh`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/zsh/tools/04_ai_capture.zsh) — aifix / aiexplain / aiblock 包裝函式、agent 派發、spinner
- [`scripts/aiblock.py`](https://github.com/daviddwlee84/dotfiles/blob/main/scripts/aiblock.py) — Python TUI（PEP 723 內嵌依賴）

## 疑難排解

### `cpblock returned empty` / `aifix ← block -1` 然後沒任何內容

你目前的 shell 是在掛鉤安裝**之前**啟動的。發出 OSC 133 標記的 precmd/preexec 掛鉤需要透過 `add-zsh-hook` 註冊，而這只在 `02_shell_integration.zsh` 被 source 時才會發生。修正：

```sh
exec zsh                                             # 原地重新載入 shell
echo $precmd_functions | tr ' ' '\n' | grep osc133   # 驗證
# 預期：_osc133_precmd
```

如果 `exec zsh` 沒幫助，開啟一個全新的 tmux 視窗 (window)——某些終端機狀態無法乾淨地透過 `exec` 傳遞。

### `aiblock`：「Shell history is empty — no commands to pick from」

在 commit `3993b7b` 之後不應再發生。若仍發生，表示透過 `fc -ln -30` 傾印歷史的 zsh 包裝函式沒在執行。驗證：

```sh
which aiblock     # 應顯示 04_ai_capture.zsh 中的函式
type aiblock      # 應顯示 fc-dump 邏輯
```

繞過方式：TUI 也會降級為直接解析 `$HISTFILE`，所以即使包裝函式壞掉，`HISTFILE=~/.zsh_history aiblock` 也能用。

### Metadata 行顯示 `claude (?)` 而不是模型名稱

`jq` 在 Claude 的 JSON 輸出中找不到 `.modelUsage | keys | first`。可能是 `jq` 版本太舊（請安裝最新版），或 Claude CLI 改變了其 JSON 結構。在修好之前可設 `AICAP_SHOW_METADATA=0` 繞過。

### Spinner 沒出現 / 沒消失

當 stderr 不是 tty 時 spinner 會自動跳過。若你以 `2>/tmp/err` 重導或透過 `tee` 管線傳遞，就看不到——這是設計如此。

若 agent 回傳後 spinner 留下殘餘的 `⠋ ...` 行，表示 `kill $_AICAP_SPIN_PID` + `\r\e[K` 的清理沒執行（通常是子 shell 中收到訊號）。按 `Ctrl+L` 重繪，然後回報。

### tmux 捲動歷史看起來「壞掉」 / 殘影 (ghost frames)

並非 aicapture 直接的問題但相鄰——見 [`pitfalls/tmux-scrollback-tui-repaint-ghosting.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/tmux-scrollback-tui-repaint-ghosting.md) 以及 `scroll-on-clear off` + `prefix + [` 工作流程。

## 相關資源

- [`docs/tools/tmux/README.md`](tmux/README.md) — tmux 設定、OSC 133 協定深入解析、copy-mode 鍵綁定（`prefix + M-y` / `M-i` / `{` / `}` / `M-[` / `M-]`）
- [`docs/this_repo/instant-llm-fix-prior-art.md`](../this_repo/instant-llm-fix-prior-art.md) — 此層與 `thefuck`（規則式、會漂移）、`shell_gpt`/`aichat`/`ai-shell`（NL→指令，並非同一個問題）、`wut`/`tmuxai`（tmux 同類）、`butterfish`/Warp（PTY proxy）、`atuin`（歷史資料庫）以及 OSC 133 終端機（Ghostty/WezTerm/Kitty/iTerm2）的比較
- [`pitfalls/zsh-osc133-precmd-printf-a-not-stored.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/zsh-osc133-precmd-printf-a-not-stored.md) — 強迫採用 `$PROMPT` 嵌入式 A 標記繞過方案的 ZLE 計時陷阱
- [`docs/zsh/aliases.md`](../zsh/aliases.md) — 本 repo 完整的自訂別名 (alias) 索引（cpcmd/cpout/cpblock/aifix/aiexplain/aiblock 列於「Tmux Integration」與「AI Capture」）
