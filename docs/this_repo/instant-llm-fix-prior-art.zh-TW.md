# 即時 LLM 修正：先例參考 (Prior Art)

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

## 為什麼有這頁

`thefuck`（nvbn，2015 年）是「我剛剛那個指令出錯了，幫我修一下」這種反射動作的元祖——一支基於規則的 Python daemon，會檢視 `$history[-1]` 並對約 200 條手寫規則（`git_push`、`no_command`、`sudo_command_not_found`…）做 pattern matching。能用，直到不能用為止：任何不在規則集 (rule set) 裡的指令都會回傳空值，而且專案已逐漸進入零星維護狀態（最後一次標籤版本 3.32 是 2024 年 1 月，issue #1466 標題就直接寫「The repo is dead」、open PR #1465 把 `imp`→`importlib` 仍未合併）。LLM 時代讓同一個反射動作換了一個架構：與其做 pattern matching，不如把上一個指令 + 它的 stderr + 可選的捲動回看 (scrollback) 全部丟給模型，讓它建議修正或解釋。我們的 `cpblock`/`cpout`/`cpcmd` + `aifix`/`aiexplain` 流水線就是這個 pattern 的其中一個實例；本頁則盤點其他實例。

## thefuck 的 LLM 後繼者

| 工具 | 語言 | 如何界定「上一個指令」 | 最近發行 | 狀態 | 備註 |
|---|---|---|---|---|---|
| `shell_gpt` (`sgpt`) | Python | Shell 整合熱鍵；從自然語言 (NL) 產生**新**指令，不會自動擷取先前的輸出 | 活躍（1.x 線，2025） | 健康 | [TheR1D/shell_gpt](https://github.com/TheR1D/shell_gpt)。`--shell` flag、`Ctrl+L` 綁定、確認/編輯/執行迴圈。比較接近 Copilot-for-shell 而非 thefuck。 |
| `aichat` | Rust | `-e` execute 模式 + `-c` code 模式；shell 整合腳本將 Alt+E 綁定到「以產生的指令取代當前緩衝區」 | 活躍，發行頻繁 | 健康 | [sigoden/aichat](https://github.com/sigoden/aichat)，bash/zsh/fish/nu/PowerShell 的整合腳本在 [scripts/shell-integration](https://github.com/sigoden/aichat/tree/main/scripts/shell-integration)。統一的 provider 層（OpenAI/Claude/Gemini/Ollama/Groq）。 |
| `ai-shell` | TS/Node | 提示 → 指令。**不**擷取先前輸出；使用者用自然語言描述意圖 | 半活躍，發行較少 | 維護中 | [BuilderIO/ai-shell](https://github.com/BuilderIO/ai-shell)。經典三按鈕 UX（執行 / 修改 / 取消）。預設只支援 OpenAI。 |
| `llm`（Simon Willison） | Python | 自己沒有 shell 整合——它是 pipe。擷取邏輯由你自己組（`<cmd> 2>&1 \| llm "explain"`） | 非常活躍（0.30 線，2026） | 健康 | [simonw/llm](https://github.com/simonw/llm)。Plugin 模型，支援多 provider 與 tools；所有東西都記錄到 SQLite 給 Datasette。是大家本來都可以拿來蓋的「低階樂高積木」。 |
| `wut` | Python | **需要 tmux 或 screen** —— 透過 `tmux capture-pane -p -S -` 抓取最後一個區塊 | v0.x，半活躍 | 健康 | [shobrook/wut](https://github.com/shobrook/wut)。哲學上最接近我們的 `aiexplain` 的雙胞胎。OpenAI/Anthropic/Ollama。`pipx install wut-cli`。[Show HN](https://news.ycombinator.com/item?id=42462764)。 |
| `tmuxai` | Go | tmux pane 觀察 —— 讀取當前 window 中每個 pane 的可見內容 | 活躍，2025 年有發行 | 健康 | [alvinunreal/tmuxai](https://github.com/alvinunreal/tmuxai)、[tmuxai.dev](https://tmuxai.dev/)。在 chat pane 中執行，於目標 pane 執行命令，並有「watch mode」自動建議。比 wut 重——它是結對程式設計 (pair-programmer) 模型，不是一次性解釋器。 |
| `butterfish` | Go | 將 shell 包成 PTY 代理 (proxy)——可看到每個按鍵與每個輸出位元組 | v0.2.15（2024 年 5 月），自此沉寂 | 低度維護 / 滑行中 | [bakks/butterfish](https://github.com/bakks/butterfish)。首字大寫的字當作 prompt 觸發。最具侵入性的架構（完整 PTY 代理），但脈絡也最豐富。作者[寫過介紹](https://pbbakkum.com/blog/20230927/)。 |
| `shell-ai`（ricklamers） | Python | 自然語言 → 指令，無擷取 | 半活躍 | 維護中 | [ricklamers/shell-ai](https://github.com/ricklamers/shell-ai)。基於 LangChain，又是另一種「描述意圖 → 建議指令」風味。 |
| `thefuck` 本尊 | Python | zsh/bash hook 從歷史紀錄讀取上一個指令 | 3.32（2024 年 1 月），issue #1466 | 飄移中 | [nvbn/thefuck](https://github.com/nvbn/thefuck)。仍可運作、仍有數百萬人安裝；規則集已經凍結。 |

「如何界定上一個指令」的拆分是這裡承重的軸。實務上有四種策略：

1. **Shell history 檔**（`thefuck`、`sgpt`）—— 只看得到指令字串，看不到輸出。對語法 typo 還行，對 runtime 錯誤無用。
2. **Shell hook 發出前/後標記** （`atuin`、OSC 133）—— 確切知道指令從哪開始、哪結束，包括 exit code。
3. **tmux/screen `capture-pane`**（`wut`、`tmuxai`、我們的 `cpblock`）—— 借用終端多工器 (multiplexer) 的 scrollback。不必動 shell 即可運作；在 tmux 之外失效。
4. **PTY 代理**（`butterfish`、Warp）—— AI shell 本身就是終端機。脈絡最多，鎖定 (lock-in) 最深。

## 終端機原生競品

| 工具 | 開源？ | 鉤子 (hook) | 狀態 |
|---|---|---|---|
| [Warp](https://www.warp.dev/) | 專有，閉源 | 原生 Electron + Rust 終端機；把每個指令視為 [block](https://docs.warp.dev/features/blocks)，輸入/輸出/exit-code 都是一級欄位 | 活躍；已完成 Series B 募資，加入完整 [agent platform](https://docs.warp.dev/agent-platform/warp-agents/interacting-with-agents/terminal-and-agent-modes) |
| [Amazon Q Developer CLI](https://docs.aws.amazon.com/amazonq/latest/qdeveloper-ug/command-line.html)（前身為 Fig） | CLI 開源，後端專有；規格 (specs) 倉庫為 [withfig/autocomplete](https://github.com/withfig/autocomplete) | 透過 `@withfig/autocomplete` specs + `q chat` 子指令做行內 ghost-text 自動完成 | Fig 已於 [2024 年 9 月 1 日](https://fig.io/blog/post/fig-is-sunsetting)結束；併入 Amazon Q。macOS 優先，Linux/Windows 路線進度延宕 |
| [Ghostty](https://ghostty.org/) shell 整合 | 開源 (MIT) | 為 bash/zsh/fish/elvish/nushell 原生發出 OSC 133——見 [DeepWiki: OSC 133 Prompt Marking](https://deepwiki.com/ghostty-org/ghostty/9.3-osc-133-prompt-marking) | 活躍，是參考實作 |
| [WezTerm](https://wezterm.org/shell-integration.html) shell 整合 | 開源 (MIT) | 原生 OSC 133，加上 OSC 7 (CWD) 與 OSC 1337 (iTerm 相容) | 活躍 |
| [Kitty](https://sw.kovidgoyal.net/kitty/shell-integration/) shell 整合 | 開源 (GPLv3) | 自家的 `KITTY_SHELL_INTEGRATION` protocol —— 發出 OSC 133 子集 + 更多 | 活躍 |
| [iTerm2](https://iterm2.com/documentation-shell-integration.html) | 僅 macOS，專有 | OSC 133 風格語意化 prompt 的最初推廣者 | 活躍 |
| Warp 的克隆，例如 [cmux](https://github.com/cmux/cmux) 等 | 多種開源嘗試 | 各異 | 太年輕，不適合倚賴 |

主軸：**Warp 是唯一一個把 AI 當作頭號賣點的**。其他每一個都是「順便發出 shell 整合標記，讓**其他**工具（tmux、Zed、VSCode、我們的 `cpblock`）在上面蓋 AI」的終端機。既然我們已經有 tmux + OSC 133，不必離開 zsh，就能拿到 Warp 90% 的「跳到 prompt」/「複製上一段輸出」/「附加到 agent」互動。

## Shell 整合層（讓上面所有東西運作的基礎）

OSC 133（[「semantic prompts」](https://gitlab.freedesktop.org/Per_Bothner/specifications/blob/master/proposals/semantic-prompts.md)）是跨終端機的 protocol，能把 scrollback 從一坨平面位元組流轉換成有結構的紀錄序列：`{prompt_start, command_start, output_start, command_finished(exit_code)}`。一旦某個 pane 被標記過後，在它之上的任何一層——終端機模擬器、多工器、外部腳本——都可以回答「給我最後一個指令區塊」，不必再用啟發式去解析 prompt。

| 層 | 角色 | 我們倉庫中的位置 |
|---|---|---|
| Shell | 在正確時刻發出 `\e]133;A/B/C/D\a` | `dot_config/zsh/tools/02_shell_integration.zsh` |
| 終端機模擬器 | 解析 OSC 133 以支援終端內跳轉（Ghostty `Ctrl+Shift+J/K`、iTerm2 `Cmd+Shift+Up/Down`） | Ghostty/iTerm2 免費送 |
| 多工器 | 對外提供 `tmux send-keys -X previous-prompt` / `next-prompt`，並在 scrollback 上附加列屬性 | tmux 3.2+ |
| 擷取工具 | `tmux capture-pane -pS -` + 列屬性感知的範圍擷取 | `dot_config/zsh/tools/03_tmux_capture.zsh`（`cpblock`/`cpout`/`cpcmd`） |
| LLM 包裝 | 拿到擷取的區塊，送往 Claude/OpenAI，並渲染修正/解釋 | `aifix` / `aiexplain` + Python TUI |

我們已經踩過的承重坑：在 `precmd` hook 中以 `printf` 發出 **A** 標記看起來是對的，但 zsh 的行編輯器 (ZLE) 會在 precmd 與 prompt 繪製之間做游標定位 (cursor-positioning)，這會與 tmux 的逐列屬性追蹤失去同步。tmux 最終會把 A 屬性掛在某個短暫的列上，然後 ZLE 在另一列重畫 prompt——所以 `previous-prompt` 在 scrollback 中找到零個 A 標記，即使 escape 位元組「有發出」（見 [`pitfalls/zsh-osc133-precmd-printf-a-not-stored.md`](../../pitfalls/zsh-osc133-precmd-printf-a-not-stored.md)）。修法——把 A 標記用 zsh 的 `%{...%}` 零寬包裝嵌入 `$PROMPT`，讓它落在空間上的 prompt 起點——和 [iTerm2 自 2016 年起一直在用的解法](https://iterm2.com/documentation-shell-integration.html)是同一個。本表中的每一層 shell 整合都默默依賴這個 workaround（或其等價 PS1 嵌入）正確；如果它不對，`tmuxai`、`wut`、我們的擷取助手以及 Warp 風格的 block 複製都會在同一處微妙地壞掉。

[`atuin`](https://github.com/atuinsh/atuin) 也屬於這一層。它本身不是 AI（18.15 加入了可選的 desktop AI，但核心是基於 SQLite 的歷史，含 cwd、exit code、duration、host）。它就是「把你的 history 檔升級為資料庫」這一塊——任何想要在意「上一條指令以外的脈絡」的工具都會想要它。積極維護中——[2026 年 4 月發行 v18.15.1](https://github.com/atuinsh/atuin/releases)，[v18.13 的開發日誌](https://blog.atuin.sh/atuin-v18-13/)宣布 PTY 代理 + AI 功能將進入規劃。

## 值得知道的鄰近設計

- **asciinema + LLM**（[asciinema/asciinema](https://github.com/asciinema/asciinema)）：`.cast` 檔是有時戳的 JSON，極易解析。多個 [asciinema.org demo](https://asciinema.org/a/592283) 展示把 cast 透過本地模型做「總結這段 session」或「重現這個 bug」。雙重優勢：cast 是文字、體積小、可 diff，且能跨人機/agent 邊界順利傳遞。代價：你只能事後拿到——對「修正剛剛那個指令」的反射動作沒幫助。
- **`script(1)` + LLM**：POSIX 在 asciinema 之前的 session 紀錄器。會擷取原始位元組，包含控制碼；用 `col -b` 去除後餵給模型即可。每台 Unix 都有，零安裝需求。1990 年代的解法，至今在氣隙 (air-gapped) 機器上仍勝過許多 2024 年的工具。
- **Shell 中的 Jupyter**：[`xonsh`](https://xon.sh/) 與 [`elvish`](https://elv.sh/) 讓你在同一個 REPL 中混用 shell 與 Python/lisp。[`nushell`](https://www.nushell.sh/) 走得更遠——每個指令都回傳結構化資料，這讓 `ls | where size > 1mb | to json | llm "which of these are logs"` 用起來很自然。nushell 原生的 LLM/MCP 橋接見 [gpt2099.nu](https://github.com/cablehead/gpt2099.nu)。代價：你得遷移 shell，這是十年量級的承諾。
- **Agent 思考面板**：[Aider issue #2742](https://github.com/Aider-AI/aider/issues/2742) 提案的內容剛好是 `wut` 已經在做的事，但放在專屬 agent UI 內。有一個專屬 tmux pane 來視覺化 agent 狀態（thinking tokens、tool calls、檔案 diff）這個 pattern，正在 Aider、Claude Code、OpenCode、Codex CLI 之間收斂。它們目前都沒有把「這是我剛剛壞掉的指令，幫我修」做成零摩擦的反射動作——你還是得貼進 agent 裡。

## 本倉庫的 aicapture 怎麼比

**我們做得好的地方**

- 一開始就建立在 OSC 133 上，所以同樣讓 `tmuxai` / `wut` / Ghostty 內建的「跳到 prompt」運作的標記，也會驅動我們的 `cpblock`/`cpout`/`cpcmd`。沒有把使用者鎖在我們的擷取層。
- 三個明確區分的範圍 (scope)（`cpcmd` = 只取指令、`cpout` = 只取輸出、`cpblock` = 兩者）。Warp 把這個叫「block copy」；`wut` 只支援合併形式。小範圍能更便宜地迭代。
- 每個範圍都支援 N-back 回看（`cpblock 3`、`cpout 2` …），所以兩個指令前的錯誤仍能取用。`wut` / `tmuxai` 只暴露「最後一個 block」。
- 修正 vs. 解釋的分流（`aifix` vs `aiexplain`）—— 多數對手把這兩件事混在一起，讓你想要可執行替代品時收到一段解釋。對應到 thefuck 使用者既有的心智模型。
- Python TUI 用於執行前的審視 (review-before-exec) —— UX 上最接近 `aichat` 的確認迴圈與 Warp 的 agent preview。
- Shell hook 不限定的擷取輸入：擷取到的 block 是文字，能與 `llm`、`sgpt`、本地 Ollama 或任何讀 stdin 的工具組合。

**對手做得更好、值得借鑑的地方**

- **sgpt / aichat**：可內嵌編輯的緩衝區。它們會就地改寫 `$BUFFER`，讓你能在 Enter 之前編輯 AI 的建議。我們是透過 stdout / TUI 把文字交還；常見情境（「`aifix` 後按 shift+enter 接受到緩衝區」）若有一個 zle widget，可以省去剪貼簿來回。
- **atuin**：失敗紀錄的持續歷史，而不只是上一個。建立一個 `fails` 子指令，去 grep 我們指令歷史中 nonzero exit code，能把 `aifix` 變成批次工具（「修今天所有失敗的 npm install」）。
- **llm (simonw)**：把所有 prompt/response 記到 SQLite + Datasette。我們把完成 (completion) 直接丟掉。在本地保留 `{captured_block, fix_suggestion, did_user_accept}` 的 SQLite，可以讓我們依自己的紀錄微調 prompt。
- **wut / tmuxai**：單一靜態二進位檔或 `pipx install`。我們的東西透過 chezmoi 出貨，意思是在還沒跑過 `chezmoi apply` 的機器上不能用。一份獨立的 `aifix` bin（Python zipapp 或 uvx-ready 進入點）能讓它可移植到臨時遠端。
- **Warp agent mode**：「把上一個錯誤作為脈絡附上」是一個熱鍵。我們的流程要 `cpblock | pbcopy` 再貼進 Claude Code。一個 `aifix --to-claude-code`，能直接開一個預先載入該 block 的 Claude Code session，可以補上這個落差（`aiblock` TUI 的「Spawn agent」action 是目前最接近的——透過貼上緩衝區，而非直接注入）。

**我們刻意不做、也不該開始做的**

- 完整 PTY 代理（Butterfish、Warp）：放棄太多可移植性。
- 原生終端機重寫：Ghostty + tmux 已涵蓋，沒必要競爭。
- 從自然語言自動完成指令（ai-shell、sgpt、aichat `-e`）：超出範圍——那是「寫指令」，我們做的是「修指令」。

## 來源

- [nvbn/thefuck](https://github.com/nvbn/thefuck)、[issue #1466 "The repo is dead"](https://github.com/nvbn/thefuck/issues/1466)
- [TheR1D/shell_gpt](https://github.com/TheR1D/shell_gpt)
- [sigoden/aichat](https://github.com/sigoden/aichat)、[shell-integration scripts](https://github.com/sigoden/aichat/tree/main/scripts/shell-integration)
- [BuilderIO/ai-shell](https://github.com/BuilderIO/ai-shell)
- [simonw/llm](https://github.com/simonw/llm)、[LLM 0.26 tools post](https://simonw.substack.com/p/large-language-models-can-run-tools)、[language-models-on-the-command-line talk](https://github.com/simonw/language-models-on-the-command-line)
- [shobrook/wut](https://github.com/shobrook/wut)、[Show HN](https://news.ycombinator.com/item?id=42462764)
- [alvinunreal/tmuxai](https://github.com/alvinunreal/tmuxai)、[tmuxai.dev](https://tmuxai.dev/)
- [bakks/butterfish](https://github.com/bakks/butterfish)、[design blog](https://pbbakkum.com/blog/20230927/)
- [ricklamers/shell-ai](https://github.com/ricklamers/shell-ai)
- [Warp docs — Warp AI](https://docs.warp.dev/features/warp-ai)、[Agent modes](https://docs.warp.dev/agent-platform/warp-agents/interacting-with-agents/terminal-and-agent-modes)、[Classic Input](https://docs.warp.dev/terminal/classic-input)
- [Fig is sunsetting](https://fig.io/blog/post/fig-is-sunsetting)、[Amazon Q Developer CLI docs](https://docs.aws.amazon.com/amazonq/latest/qdeveloper-ug/command-line.html)、[aws/amazon-q-developer-cli-autocomplete](https://github.com/aws/amazon-q-developer-cli-autocomplete)、[withfig/autocomplete](https://github.com/withfig/autocomplete)
- [OSC 133 semantic-prompts spec (freedesktop)](https://gitlab.freedesktop.org/Per_Bothner/specifications/blob/master/proposals/semantic-prompts.md)
- [Ghostty OSC 133 (DeepWiki)](https://deepwiki.com/ghostty-org/ghostty/9.3-osc-133-prompt-marking)、[Ghostty issue #5932](https://github.com/ghostty-org/ghostty/issues/5932)
- [WezTerm shell integration](https://wezterm.org/shell-integration.html)
- [iTerm2 shell integration](https://iterm2.com/documentation-shell-integration.html)
- [tmux OSC 133 issue #3064](https://github.com/tmux/tmux/issues/3064)
- [atuinsh/atuin](https://github.com/atuinsh/atuin)、[v18.13 devlog](https://blog.atuin.sh/atuin-v18-13/)、[releases](https://github.com/atuinsh/atuin/releases)
- [asciinema/asciinema](https://github.com/asciinema/asciinema)、[local LLM PoC cast](https://asciinema.org/a/592283)
- [nushell/nushell](https://github.com/nushell/nushell)、[awesome-nu](https://github.com/nushell/awesome-nu)、[gpt2099.nu](https://github.com/cablehead/gpt2099.nu)
- [Aider issue #2742 — integrate wut for tmux last-error help](https://github.com/Aider-AI/aider/issues/2742)
- 我們倉庫：[`pitfalls/zsh-osc133-precmd-printf-a-not-stored.md`](../../pitfalls/zsh-osc133-precmd-printf-a-not-stored.md)
