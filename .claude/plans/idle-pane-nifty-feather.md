# herdr "review-pending" 旗標(mark-unread / ⭐ star)

## Context

**痛點**:herdr 原生把 agent 狀態偵測成 idle/working/blocked/done。模型跑完 → `done`,但你點進去瞄一眼、還不想馬上 review,herdr 就把它塌成 `idle` ✅。於是「agent 狀態已完成、但任務還沒 review」的 session 沒有任何視覺標記,容易忘記哪幾個還沒收尾。

tmux 那邊已有對應機制:`@bookmark_status` per-window user-option + status bar 的 `#{?@bookmark_status,…}` format-string 內插(`dot_config/tmux/executable_toggle-bookmark.sh` + `theme.catppuccin.conf:44-45`),右鍵選單或 `tmux_status_set bookmark ⭐` 切換。herdr **沒有 `#{@option}` 內插**,所以那條路不通 —— 但 herdr 有更貼合這個用途的原生積木。

**目標**:給 herdr pane 一個使用者可控、與 agent 偵測正交的「未讀/待 review」旗標,並提供一個可 fuzzy 的「未讀收件匣」picker,解決「忘記哪些 session 未完成」。

### 已用 live test 確認的事實(2026-07-08,本機 default session)

- `herdr pane report-metadata <pane> --source review --custom-status "⭐ REVIEW"`(**不帶 `--ttl-ms` → 永久**)之後,`herdr pane get <pane>` 的 JSON **含 top-level `custom_status: "⭐ REVIEW"`**,且同一筆的 `agent_status` 仍是 `idle`。→ **custom_status 與 agent 偵測正交,idle 轉換不會清它**;**不需要 sidecar 檔,`herdr pane list` 就是唯一真相源**。
- `herdr pane list` / `herdr agent list` **原生吐 JSON,不加 flag**;傳 `--json` 會報 `usage:` 錯(picker source 別用 `--json`)。
- 清除:`--clear-custom-status`。
- keybind 可用鍵:`prefix+m`、`prefix+i` 皆未被佔用(見 `.chezmoitemplates/herdr/config.toml` 現有綁定 + herdr 內建保留鍵);最終以 `herdr server reload-config` 的 `diagnostics` 為準。

### 已知交互 / caveat

- **`custom_status` 是單值欄位**。未來的 usage-status driver(`backlog/herdr-usage-status-driver.md`,也用 `report-metadata --custom-status` 推 "Claude X% • Codex Y%")會與本功能爭同一個可見 `custom_status`(雖然 `--source` 不同,`pane get` 只吐一個扁平值 → last-writer/優先序)。v1 無實際衝突(usage driver 未建、review 旗標是短暫的),但實作時要在 `backlog/herdr-usage-status-driver.md` 補一行註記此共用欄位。
- `[[keys.command]] type="pane"` 會開一個短暫 popup pane 跑指令再關 —— toggle 腳本 <100ms 結束,會有極短閃爍。可接受;實作時順手確認 herdr 有無無 pane 的 command type,沒有就沿用 `type="pane"`。

## 範圍(依使用者選擇)

✅ 核心:`hmark`/`hunmark` + `prefix+m` toggle
✅ `tv herdr-review` 未讀收件匣(Enter 保留 ⭐;另一鍵 focus+清 = mark-read)
❌ 背景自動標記(future,不做)

## 實作

**Marker 約定**:`custom_status = "⭐ REVIEW"`;`--source review`;過濾一律用子字串 `REVIEW`(`jq 'test("REVIEW")'`),不依賴 emoji。

### 1. 核心腳本 `dot_config/herdr/executable_review-mark.sh`(新增 → `~/.config/herdr/review-mark.sh`)

單一真相源的 mark 邏輯,鏡像 tmux 的 `executable_toggle-bookmark.sh`。用法:`review-mark.sh set|clear|toggle <pane_id> [glyph]`。
- `set`:`herdr pane report-metadata "$pane" --source review --custom-status "⭐ REVIEW"`(不帶 ttl)。
- `clear`:`… --clear-custom-status`。
- `toggle`:先 `herdr pane get "$pane" | jq -r '.result.pane.custom_status // ""'`,含 `REVIEW` → clear,否則 set。
- `set -eu`、參數校驗、`command -v herdr/jq` guard,POSIX `sh`(與 tmux 腳本同風格)。

### 2. Shell wrappers — `dot_config/shell/24_herdr.sh`(在 `herdr-root` 之後、alias 區之前)

- `herdr-mark` / `herdr-unmark` 函式:讀 ambient `HERDR_PANE_ID`(此檔目前只用 `HERDR_ENV`/`HERDR_SOCKET_PATH`,`HERDR_PANE_ID` 是新依賴),可選位置參數覆寫 pane id;委派給 `~/.config/herdr/review-mark.sh set|clear`。沿用既有骨架:`command -v jq` guard、`-h|--help` heredoc、`-*) unknown flag`。不在 herdr 內(`HERDR_PANE_ID` 空)時報明確錯誤。
- alias 區(現 673–678)加 `alias hmark='herdr-mark'` / `alias hunmark='herdr-unmark'`。
- **Shared tier 限制**:此檔兩個 shell 都 source,禁用 zsh-only 語法(維持既有 POSIX 風格)。

### 3. Keybind — `.chezmoitemplates/herdr/config.toml`

新增兩個 `[[keys.command]]`(`type="pane"`,用 `$HERDR_ACTIVE_PANE_ID` —— 注意 keybind 環境是 `HERDR_ACTIVE_PANE_ID`,與 ambient `HERDR_PANE_ID` 不同名):
- `prefix+m` → `~/.config/herdr/review-mark.sh toggle "$HERDR_ACTIVE_PANE_ID"`(toggle 未讀旗標)。
- `prefix+i` → `tv herdr-review`(未讀收件匣),沿用現有 `prefix+T`/`prefix+a` 的 tv command-pane 慣例。

### 4. tv channel `dot_config/television/cable/herdr-review.toml`(新增)

鏡像 `herdr-agent-panes.toml` 骨架:
- `[metadata]` requirements `["herdr","jq"]`。
- `[source].command`:`herdr pane list 2>/dev/null | jq -r '.result.panes[]? | select(.custom_status? | test("REVIEW")) | "\(.pane_id)\t\(.workspace_id)\t\(.tab_id)\t\(.custom_status)\t\(.foreground_cwd // .cwd)"'`(TSV)。
- `[preview]`:`herdr pane read "{split:\t:0}" --source visible --lines 80`(同 agent-panes)。
- `[keybindings]`:`enter = "actions:focus"`(**只 focus,保留 ⭐**);`alt-c = ["actions:focus_clear","reload_source"]`(focus + 清 = mark-read);`ctrl-y = "actions:copy_id"`。
- `[actions.focus]`:`herdr workspace focus "$ws"; herdr tab focus "$tab"`(herdr 無 focus-pane-by-id,沿用 agent-panes 的 workspace+tab focus)。
- `[actions.focus_clear]`:同上再 `~/.config/herdr/review-mark.sh clear "$pane"`。

### 5. 文件(cross-file 規則)

- `docs/shells/aliases.md` § Session Management(~458,herdr 列在 469–472 後):加 `hmark`/`hunmark` 兩列。
- `docs/tools/herdr.md`:keybind 表(84–108)加 `prefix+m`/`prefix+i`;Television 段(148–155)加 `herdr-review` bullet;**修正** feasibility 列(75)與 Gaps bullet(250)—— review/unread 現在**有** analog(`report-metadata --custom-status`,與 agent 偵測正交、`pane get` 可查回),純裝飾書籤仍是 gap。`## AI usage / quota status`(244)可交叉連到本功能共用 `custom_status`。
- `docs/tools/herdr.zh-TW.md`:對應鏡像(同 line 區間)。
- `backlog/herdr-usage-status-driver.md`:補一行「custom_status 為單值、與 review 旗標共用」的註記。
- **不需要**:新 mkdocs nav(herdr.md 已在 `mkdocs.yml:265`);SKILL.md.tmpl(Television 段自我發現,無新 prompt key);shell completion(是函式/alias,非 `executable_*` binary)。

## Verification

1. `herdr server reload-config` → `diagnostics` 為空 + `status:"applied"`(keybind 解析無衝突;確認 `prefix+m`/`prefix+i` 不撞內建)。
2. Live(在一個 idle pane 內):`hmark` → `herdr pane get <pane> | jq .result.pane.custom_status` 顯示 `⭐ REVIEW`,且 `agent_status` 不變;肉眼確認 herdr sidebar/pane border 出現 ⭐(`show_agent_labels_on_pane_borders` 已開)。觸發一次 working→idle 再驗旗標仍在。`hunmark` → 欄位消失。
3. `prefix+m` 兩次 → 視覺上 mark/unmark 切換(接受極短 popup 閃爍)。
4. `tv herdr-review` → 只列出被標記的 pane;`Enter` focus 過去且 ⭐ 保留;`alt-c` focus 後 ⭐ 清除且清單刷新。
5. 兩個 shell 各 source 一次(`zsh -ic 'type herdr-mark'` / `bash -ic 'type herdr-mark'`)確認 POSIX-safe、無 zsh-only 語法報錯。
6. `uv run mkdocs build --strict` 通過。
