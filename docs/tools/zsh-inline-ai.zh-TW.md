# aisuggest — prompt 時自然語言轉 shell 殘影

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

在 zsh prompt 輸入自然語言 (natural language) 描述 → 按下觸發鍵 → 殘影 (ghost text) 顯示建議的指令 → Tab 或 → 接受，繼續打字則取消。靈感來自 [`kylesnowschwartz/zsh-ai-cmd`](https://github.com/kylesnowschwartz/zsh-ai-cmd) (MIT)；以我們自己的命名從零重新實作，因此會走既有的 [`_aiagent_invoke`](aicapture.md) 層 (claude → opencode → codex → cursor-agent 自動偵測，無需 API key)。

這是 [`aicapture`](aicapture.md) 在 **prompt 時** 的對應版本。兩種不同的使用情境：

| | `aicapture` (`aifix` / `aiexplain`) | `aisuggest` |
|---|---|---|
| 觸發 | 指令執行後；輸入 `aifix` | 輸入時；按下 `Alt+;` |
| 輸入 | 過往區塊在 tmux 上擷取的輸出 | 目前 `BUFFER` 文字（自然語言） |
| 輸出 | 多段診斷 (Markdown) | 一行 shell 指令（殘影 → 緩衝區） |
| UI | 在下一個 prompt 串流到 stdout | ZLE postdisplay + region_highlight |

## 快速開始

```sh
# 輸入描述，按 Alt+; 取得建議
find files larger than 100 MB
# (Alt+;)
find files larger than 100 MB  ⇥  find . -size +100M       ← 殘影以 fg=8 顯示
# (Tab)
find . -size +100M                                          ← 緩衝區被替換；按 Enter
```

如果建議剛好是你目前已輸入內容的*延伸* (extension)（例如 `git log --` → `git log --oneline -20`），殘影只會顯示*後綴* (suffix) 且沒有 `⇥` 指示符，所以你可以繼續輸入符合的字元，建議仍會持續存在。

## 設定

| 環境變數 | 預設值 | 備註 |
|---|---|---|
| `AISUGGEST_KEY` | `^[;` (Alt+;) | zsh keybind 表記法。可在 `~/.zshrc.adhoc` 中覆寫。Ctrl+Z 刻意不使用（保留 SIGTSTP）；在 `;` 不好按的鍵盤排列上，`^[/` (Alt+/) 是不錯的替代方案。 |
| `AISUGGEST_AGENT` | 空字串（自動偵測） | 固定為 `claude` / `opencode` / `codex` / `cursor-agent` 可跳過自動偵測。 |
| `AISUGGEST_MODEL` | 空字串（每個 agent 預設） | 為空時，會 fallback 到 `04_ai_capture.zsh` 的 `AICAP_<AGENT>_MODEL`。 |
| `AISUGGEST_HIGHLIGHT` | `fg=8` | 殘影的 zsh `region_highlight` 樣式。 |
| `AISUGGEST_PROMPT_OVERRIDE` | 空字串 | 完全替換內建系統 prompt。進階使用者旋鈕。 |
| `AISUGGEST_DEBUG` | `0` | `1` 啟用除錯 (debug) 記錄。 |
| `AISUGGEST_LOG` | `/tmp/aisuggest.log` | 除錯記錄的路徑。 |

請在 `~/.zshrc.adhoc`（未追蹤）或 `~/.config/zsh/secrets.zsh` 中覆寫。不要直接編輯 `dot_config/zsh/tools/05_aisuggest.zsh`。

## ZLE widget 解剖（殘影實際上如何運作）

本節記錄了我們從上游 (upstream) 採用的設計（commit [`cda55e1`](https://github.com/kylesnowschwartz/zsh-ai-cmd/commit/cda55e1)），讓未來的維護者不必重讀上游程式碼也能理解。

### 狀態機 (state machine)——Dormant ↔ Active

該 widget 有兩種狀態。五個全域變數 (global) 追蹤 Active 狀態：

| 全域變數 | 角色 |
|---|---|
| `_AISUGGEST_ACTIVE` | `0`/`1` 旗標——accept/dismiss handlers 的主要閘門 |
| `_AISUGGEST_SUGGESTION` | 完整的建議指令文字 |
| `_AISUGGEST_BUFFER_AT_SUGGESTION` | 殘影渲染時 `$BUFFER` 的快照 (snapshot) |
| `_AISUGGEST_LAST_HIGHLIGHT` | 我們附加的確切 `region_highlight` 條目（這樣在停用 (deactivate) 時只會移除這一條，而不會破壞其他外掛 (plugins) 的） |
| `_AISUGGEST_ORIG_TAB` / `_AISUGGEST_ORIG_RIGHT` | 啟動 (activate) 之前綁定的 Tab 與右方向鍵 widget，這樣停用時可以還原 |

### 觸發流程（按下 Alt+;）

1. 若 `BUFFER` 為空則放棄（沒有輸入 → 沒有東西可翻譯）。
2. 將 agent 呼叫 (`_aiagent_invoke`) 背景化，輸出寫到暫存檔。
3. 在 agent 思考時，透過 `POSTDISPLAY` 顯示 spinner 動畫。輪詢 `read -t 0.1 -k 1` 讓*任何*按鍵都能取消。
4. 收到回應時：清理 (sanitize)（移除 ANSI escape 與控制字元 (control chars)），再呼叫 `_aisuggest_show_ghost` 與 `_aisuggest_activate`。

### 顯示：POSTDISPLAY + region_highlight（**不是** BUFFER 修改）

我們使用 zsh 的 `POSTDISPLAY` 變數（顯示在游標之後的文字，永遠不是 `BUFFER` 的一部分）加上單一 `region_highlight` 條目來樣式化它的位元組。兩種顯示模式：

- **建議是緩衝區的前綴延伸 (prefix-extension)**：`POSTDISPLAY="${suggestion#$BUFFER}"`。純 inline 補完——接受時建議*擴增*緩衝區。
- **建議不同**：`POSTDISPLAY="  ⇥  ${suggestion}"`。Tab-提示指示符告訴使用者「Tab 會*替換*而非附加」。

`region_highlight` 條目涵蓋位元組索引 `[$#BUFFER, $#BUFFER + $#POSTDISPLAY)`，並原樣存於 `_AISUGGEST_LAST_HIGHLIGHT`，這樣我們可以精準地透過以下方式移除該條目——同時保留任何其他外掛的高亮：

```zsh
region_highlight=("${(@)region_highlight:#$_AISUGGEST_LAST_HIGHLIGHT}")
```

### 為何用 POSTDISPLAY（而不是附加到 BUFFER）

POSTDISPLAY 是「顯示在游標之後但不屬於可編輯緩衝區的文字」。修改 `BUFFER` 會迫使使用者若想取消建議就得手動把它編輯掉——那是錯誤的 UX。POSTDISPLAY 對於讀取 `BUFFER` 的程式碼是不可見的，且只要設 `POSTDISPLAY=""` 就能輕鬆清掉。

### 啟用：動態重新綁定 Tab 與 →

關鍵巧思。Tab 是神聖的——全域重綁為「接受建議」會永遠破壞檔名補完。所以 `_aisuggest_activate` *暫時* 借用 Tab 與右方向鍵：

```zsh
_AISUGGEST_ORIG_TAB=$(bindkey -M main '^I' | awk '{print $2}')
bindkey '^I'  _aisuggest_accept_tab
bindkey '^[[C' _aisuggest_accept_right
```

`_aisuggest_deactivate` 會還原它們。所以建議存在時 Tab → 接受，其餘時間 Tab → 補完。

### 取消：搭配聰明前綴邏輯的 `line-pre-redraw` hook

每次重繪時會觸發一個 hook。如果處於 active 且 `$BUFFER != $_AISUGGEST_BUFFER_AT_SUGGESTION`：

- **緩衝區仍是建議的前綴 (prefix)** → 重新渲染殘影並更新快照。（使用者繼續輸入符合的字元——保持建議存在。）
- **緩衝區已偏離 (diverged)** → 停用、清除 POSTDISPLAY + 高亮、還原 Tab/→。

我們在可用時透過 `add-zle-hook-widget line-pre-redraw` 註冊 hook（與 `zsh-syntax-highlighting` 與 `zsh-autosuggestions` 的 hook 串接）；否則 fallback 到直接 `zle -N zle-line-pre-redraw`。串接很重要——覆寫該 widget 會破壞語法高亮。

### Line-finish：Enter 時停用

`zle-line-finish` 在送出該行（Enter）時觸發。我們會停用以在該行執行前還原 Tab/→——否則下一行的狀態會是過期的。

## 與 provider 的整合

`_aisuggest_query` 是進入我們 agent 層的單一墊片 (shim)。它：

1. 挑選一個 agent：`${AISUGGEST_AGENT:-$(_aiagent_autodetect)}`（從 `04_ai_capture.zsh:36-45` 自動偵測——順序與 `aifix`/`aiexplain` 相同）。
2. 建立系統 prompt（除非設定了 `AISUGGEST_PROMPT_OVERRIDE`，否則使用內建的）。
3. 透過 `_aiagent_invoke` 呼叫一個*低延遲* (low-latency) 的呼叫，抑制 metadata、spinner 與美化 (`AICAP_SHOW_METADATA=0 AICAP_SPINNER=0 AICAP_PRETTIFY=0`)。
4. 後處理過濾：`head -1`（僅取一行）並用 `sed` 去除模型可能不顧系統 prompt 仍加上的開頭 `$`/`#` prompt 符號與外圍 backticks。

對 Claude 而言，理想情況下我們會使用上游風格的 flag profile (`--no-session-persistence --effort low --no-chrome --tools "" --setting-sources ""`)，將回應時間從約 5 秒降到約 1.5 秒。這是未來改進；MVP 仍倚賴 `_aiagent_invoke` 的預設 flags。

### 系統 prompt 設計

靈感來自上游的 prompt（僅規則，無 chain-of-thought，附範例）。關鍵規則：

- 一條指令，無 markdown，無散文。
- BSD vs GNU 意識（模型透過上下文獲得 PWD + OS）。
- 標準工具前加 `command` 以繞過 alias（所以 `ls -la` → `command ls -la`）。
- 範例對涵蓋：file find、grep、git、lsof、du、date、tar、ffmpeg。

可透過 `AISUGGEST_PROMPT_OVERRIDE` 覆寫整段內容。

## 與其他外掛的互動

### `zsh-autosuggestions`（POSTDISPLAY 覆寫——根因 + 修正）

兩個外掛都會寫 `POSTDISPLAY`。2026-04-27 的診斷記錄顯示我們的 widget 渲染了殘影，但等到下一次 pre-redraw 觸發時，POSTDISPLAY 已經是空的：

```
widget: rendered ghost, activated
pre_redraw: BUFFER=[show current disk space] snap=[show current disk space] POSTDISPLAY=[]
```

**根因 (root cause)**（位於 `~/.oh-my-zsh/custom/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh:220-221`）：autosuggestions 把每個非底線開頭、非 `autosuggest-*` 的 ZLE widget 都綁為「modify」widget——原始碼的註解寫著「Assume any unspecified widget might modify the buffer」。Wrapper function `_zsh_autosuggest_modify`（`src/widgets.zsh:39`）會在每次被包裝的呼叫前後做這件事：

```zsh
local orig_postdisplay="$POSTDISPLAY"   # save (我們的 widget 之前是空的)
POSTDISPLAY=                            # clear
_zsh_autosuggest_invoke_original_widget $@   # ← 執行我們的 _aisuggest_widget
# … 然後若 BUFFER 沒變 …
POSTDISPLAY="${orig_postdisplay:…}"     # 還原成空值，覆蓋掉我們的
```

按 Alt+; 不會改變 BUFFER（我們不寫入它），所以「BUFFER 未變」分支被觸發，POSTDISPLAY 被重設為（空的）widget 之前的值。

**修正。**告訴 zsh-autosuggestions 不要包裝我們的 widget，做法是在檔案 source 時把它們加入 `ZSH_AUTOSUGGEST_IGNORE_WIDGETS` 陣列：

```zsh
typeset -ga ZSH_AUTOSUGGEST_IGNORE_WIDGETS
ZSH_AUTOSUGGEST_IGNORE_WIDGETS+=(aisuggest _aisuggest_accept_tab _aisuggest_accept_right _aisuggest_pre_redraw)
```

這之所以有效，是因為 autosuggestions 的 `_zsh_autosuggest_start` 是作為 `precmd` hook 執行的，預設每個 prompt 都會重新綁定 widget——它每次重新綁定時會重讀 ignore 清單，所以在 OMZ 之後 source 的我們的檔案中附加的內容，會在下一個 prompt 生效。

**縱深防禦 (defense-in-depth)。**`_aisuggest_pre_redraw` 仍會在處於 active 時，若 POSTDISPLAY 變空就重新主張它，以防其他 POSTDISPLAY 消費者偷溜進來。便宜的保險。

我們不呼叫 `_zsh_autosuggest_disable` 的原因：`_zsh_autosuggest_disable` 自身會呼叫 `_zsh_autosuggest_clear`，而後者會把 POSTDISPLAY="" 設為空——若在錯誤的時機被觸發反而會讓問題更糟。`ZSH_AUTOSUGGEST_IGNORE_WIDGETS` 是手術級的修正。

### `zsh-vi-mode`（bindkey 抹除）

`zsh-vi-mode` 在初始化時會呼叫一個私有 function 把所有 `bindkey` 都丟掉。它提供 `zvm_after_init` hook 讓外掛重新套用自己的綁定。我們的觸發鍵在那裡重新綁定；詳見 `dot_zshrc.tmpl`。Tab/→ 的 swap-bind 是在 widget 呼叫期間（init 之後）發生的，所以不受影響。

### `zsh-syntax-highlighting`（line-pre-redraw）

每次重繪時重新繪製 `region_highlight`。因為我們使用 `add-zle-hook-widget`（串接而非覆寫），我們的 hook 會與它們的並列執行。我們的高亮條目每次重繪都會被附加在它們之後——可見且樣式正確。

## 除錯

當該 widget 行為異常時有兩個診斷介面：

### CLI（同步，不涉及 ZLE）

```sh
aisuggest "find files larger than 100 MB"           # 印出建議的指令
aisuggest --debug "find files larger than 100 MB"   # 同時把 raw / sanitized / final 印到 stderr
```

用這個來測試 `_aisuggest_query` 本身是否健康——agent 是否可達、prompt 是否被遵循、後處理過濾是否過度刪除。若 CLI 可運作但 widget 不行，bug 在 widget 特有的路徑上（subshell、spinner、POSTDISPLAY 渲染）。

### Widget 追蹤

```sh
export AISUGGEST_DEBUG=1                            # runtime 可切換，無需重啟
: > /tmp/aisuggest.log                              # truncate
# 對描述觸發 Alt+;
cat /tmp/aisuggest.log
```

每個步驟都會寫一條有標記的記錄：`widget: enter`、`widget: backgrounded pid=…`、`widget: spinner exited at i=N, reading tmpfile`、`widget: raw stdout (len=N)=[…]`、`show_ghost: POSTDISPLAY=[…]`、`activate: orig_tab=[…] autosuggest_paused=…`、`pre_redraw: BUFFER=[…] snap=[…] POSTDISPLAY=[…]`、`deactivate: called from <function>`。

常見失敗模式 → 記錄特徵：

| 症狀 | 指向它的記錄行 | 可能的修正 |
|---|---|---|
| Spinner 跑完，然後什麼都看不到 | `rendered ghost, activated` 後跟著 `pre_redraw: ... POSTDISPLAY=[]` | POSTDISPLAY 競爭——確認 `_zsh_autosuggest_disable` 已執行（activate 記錄行中應有 `autosuggest_paused=1`）；fallback 重新主張應觸發 |
| Spinner 幾乎立刻被取消 | `widget: read cancelled at i=N (key='…')` | TTY 緩衝區中有過期輸入或按鍵事件洩漏；切換取消機制 |
| Spinner 跑完，「no suggestion」訊息 | `widget: empty suggestion → 'no suggestion' branch`、`widget: raw stdout (len=0)` | Subshell-context agent 失敗——查看 `widget: raw stderr=[…]` 找底層錯誤 |
| Widget 啟用後立即停用 | `deactivate: called from _aisuggest_pre_redraw (POSTDISPLAY was [...])` | 緩衝區不匹配；檢查 `pre_redraw` 的 BUFFER vs snap |

停用除錯記錄：`export AISUGGEST_DEBUG=0`（無需重啟；`_aisuggest_log` 在呼叫時檢查 flag）。

## 疑難排解

| 症狀 | 診斷 |
|---|---|
| 觸發鍵沒反應 | 檢查 `bindkey \| grep '\^\[;'`——若不存在，`zvm_after_init` 沒有重新綁定。檢查 `zle -l \| grep aisuggest`——若不存在，檔案沒被 source（看開頭的 guard-bail：缺少 claude/opencode/codex/cursor-agent CLI，或缺少 curl/jq）。 |
| 殘影出現但 Tab 開啟補完選單而非接受 | `_aisuggest_activate` 沒能 swap-bind Tab。在 active 時檢查 `bindkey '^I'`——應顯示 `_aisuggest_accept_tab`。 |
| 殘影在編輯時不會消失 | `line-pre-redraw` hook 沒觸發。檢查 `zle -l \| grep -i pre-redraw`——若 `add-zle-hook-widget` 不可用，fallback 直接設定 `zle-line-pre-redraw`，會被其他外掛覆寫。 |
| 建議花費 >5 秒 | 預設 agent 使用 `_aiagent_invoke` 的標準 flags（claude 搭配 JSON 輸出）。固定一個更快的 agent：`export AISUGGEST_AGENT=opencode`。 |
| 挑錯了 agent | 明確設定 `AISUGGEST_AGENT`。`_aiagent_autodetect` 的順序是 claude → opencode → codex → cursor-agent；PATH 上最先出現者勝出。 |
| Job control 壞掉 (`Ctrl+Z` 不暫停) | 有人設了 `AISUGGEST_KEY=^Z`。重設為預設 `^[;`。 |
| 按 Enter，得到 `command not found: <my words>` | 殘影只是提示，不是緩衝區內容。**Tab 或 →** 才會把 `BUFFER` 替換為建議；**Enter** 會直接執行 `BUFFER`。先按 Tab，*然後* 再 Enter。 |

啟用除錯記錄：

```sh
export AISUGGEST_DEBUG=1
export AISUGGEST_LOG=~/.cache/aisuggest.log
exec zsh
# 觸發幾次建議，然後：
tail -f ~/.cache/aisuggest.log
```

## 重新研讀上游以獲取新點子

上游持續演進；我們不會自動拉取。可用以下方式重讀：

```sh
git clone --depth 1 https://github.com/kylesnowschwartz/zsh-ai-cmd /tmp/zsh-ai-cmd-study
```

更新時值得重讀的檔案：

- `zsh-ai-cmd.plugin.zsh`——widget 機制、狀態機、清理 (sanitization)。
- `prompt.zsh`——prompt 設計變動；考慮移植好的規則新增。
- `providers/claude-code.zsh`——claude CLI 的低延遲 flag profile。
- `CHANGELOG.md`——自 `cda55e1`（我們設計學習的 commit）以來的變動。

若上游加入我們想要的功能（例如透過 `zle -F` 達成非阻塞 spinner 的 async），我們會把*點子*移植到 `05_aisuggest.zsh`，而不是程式碼。

## Roadmap——值得移植的點子

於上游 commit `cda55e1` 研讀時識別出的具體改進。大致按收益對工作量排序；下次動到此檔案時挑一個來做。

### 1. 低延遲 claude flag profile *(高收益、低風險)*

目前我們的 `_aisuggest_query` 透過 `_aiagent_invoke` 呼叫，後者會呼叫 `claude -p --model "$AICAP_CLAUDE_MODEL"`（含 JSON 輸出以取得 metadata）。對於 inline 建議我們不需要 metadata，而 Claude Code 的 CLI 啟動時間主導了 1–3 秒的回應時間。上游的 [`providers/claude-code.zsh`](https://github.com/kylesnowschwartz/zsh-ai-cmd/blob/main/providers/claude-code.zsh) 使用一個精簡 profile，他們測得約快 1.5×：

```sh
claude -p --no-session-persistence --effort low \
       --disable-slash-commands --strict-mcp-config \
       --setting-sources "" --no-chrome --tools "" \
       --system-prompt "$prompt" "$user_input"
```

兩種採用方式：

- **A.** 在 `_aisuggest_query` 中加入並行的低延遲路徑：當 `agent == claude` 時，繞過 `_aiagent_invoke`，直接以上游的 flag profile + `--system-prompt` 執行。`_aiagent_invoke` 對 `aifix`/`aiexplain` 保持不變。
- **B.** 在 `04_ai_capture.zsh` 中新增 `_aiagent_invoke_fast`，分開接收系統 prompt 並對*所有* agent 使用精簡 flags（opencode `--no-system-context` 等）。抽象更乾淨；工作量較大；會動到 `aifix`/`aiexplain`。

(A) 是較安全的第一步。

### 2. `--system-prompt` 分離 *(小但更乾淨)*

目前我們把 system + context + 使用者輸入串接成一個 `prompt` 字串作為使用者訊息傳入。Claude 會遵循它，但 `--system-prompt`（[上游使用此方式](https://github.com/kylesnowschwartz/zsh-ai-cmd/blob/main/providers/claude-code.zsh)）讓模型把規則當成不可變的系統脈絡。規則遵循更嚴謹，偶爾能避免「解釋滲漏」的情況。與點子 (1) 自然成對。

### 3. 透過 `zle -F` 達成 async *(中等工作量、UX 大勝)*

目前 `_aisuggest_widget` 在 agent 呼叫期間會阻塞 prompt。POSTDISPLAY 上的 spinner 動畫*視覺上*隱藏了這點，但等待時你不能繼續輸入——任何按鍵都會取消請求。zsh 的 `zle -F <fd> <handler>` 讓你可在 FD 變為可讀時註冊 callback，這樣你就能在背景觸發 agent、立即回到 prompt，並讓建議在 FD 有資料時*非同步落地*。上游也沒這麼做，但這是自然的下一個 UX 飛躍。草稿：`mkfifo` 或 `mktemp` → fork agent → `zle -F $fd _aisuggest_on_response` → 使用者自由輸入 → callback 在回應到達時觸發 → 若緩衝區未偏離則渲染殘影。

限制：必須優雅處理「使用者在回應到達前就送出該行」——`_aisuggest_line_finish` 應殺掉 FD 監看器。

### 4. 直接 API providers（anthropic / openai / gemini）*(僅在需要時)*

我們目前*只*支援四個 CLI（`claude`、`opencode`、`codex`、`cursor-agent`）。未安裝任何一個的使用者什麼也得不到。上游透過 `curl` + `jq` 支援 anthropic / openai / gemini / deepseek / ollama / copilot 的直接 API 呼叫。若我們真要無 CLI 的 fallback，可移植 [`providers/anthropic.zsh`](https://github.com/kylesnowschwartz/zsh-ai-cmd/blob/main/providers/anthropic.zsh) 模式（單一 `curl -s` POST，用 `jq -r '.content[0].text'` 萃取）。搭配上游的 [`ZSH_AI_CMD_API_KEY_COMMAND`](https://github.com/kylesnowschwartz/zsh-ai-cmd/blob/main/README.md#custom-api-key-retrieval) 模式，使用者可從 `op`、`pass`、GNOME Keyring、AWS Secrets Manager 等取得 key——具彈性且不把 provider 知識烤進我們程式中。

待採用旗標：這是*使用者驅動*的改進——只在有人提出時做，因為它在 hot path 上加入 curl/jq 依賴與維護面。

### 5. Sanitize 回歸測試 *(便宜的保險)*

上游附帶 [`test-sanitize.sh`](https://github.com/kylesnowschwartz/zsh-ai-cmd/blob/main/test-sanitize.sh)——將精心構造的 ANSI / 控制字元 payload 餵給 `_zsh_ai_cmd_sanitize` 並斷言沒有洩漏。我們的 `_aisuggest_sanitize` 是逐字移植；一個壞的 regex 變動就可能重新引入 escape-injection。新增一個小的 `tests/aisuggest_sanitize.sh` shell 腳本，source `05_aisuggest.zsh` 並對若干 payload（CSI sequence、raw ESC、NULL byte、BEL、DEL）做斷言。30 行，<1 秒可跑完。

### 6. 每 provider 的 model 環境變數 *(與上游一致)*

目前 `AISUGGEST_MODEL` 是單一環境變數，會覆寫被挑中的 agent（我們在墊片中覆寫 `AICAP_<AGENT>_MODEL`）。上游使用 provider 特有的名稱：`ZSH_AI_CMD_ANTHROPIC_MODEL`、`ZSH_AI_CMD_OPENAI_MODEL` 等——讓使用者能為不同 provider 固定不同模型，而不需在切換 agent 時重新匯出。若我們未來在同一 session 中支援多個 agent，就改用 `AISUGGEST_<AGENT>_MODEL`（並保留 `AISUGGEST_MODEL` 作為 back-compat 的 fallback）。

### 7. 由 CHANGELOG 驅動的重新同步節奏

上游的 [`CHANGELOG.md`](https://github.com/kylesnowschwartz/zsh-ai-cmd/blob/main/CHANGELOG.md) 簡潔。每季 `git -C /tmp/zsh-ai-cmd-study log --oneline cda55e1..HEAD` + 略讀就足以挑出移植候選。若你想要按節奏執行，可以設一個 `/schedule` 提醒；否則下次動到此檔案時順手跑一下。

## 致謝 (Attribution)

UX 設計與 ZLE-widget 機制學自 [`kylesnowschwartz/zsh-ai-cmd`](https://github.com/kylesnowschwartz/zsh-ai-cmd) (MIT，作者 Kyle Snow Schwartz)。`dot_config/zsh/tools/05_aisuggest.zsh` 中的所有程式碼皆為我們自己的實作，撰寫以與本倉庫既有的 `_aiagent_invoke` 層整合。我們感謝上游的設計——若你欣賞原作，請去 star 他們的 repo。
