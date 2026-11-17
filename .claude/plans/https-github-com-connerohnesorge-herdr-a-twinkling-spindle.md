# herdr-agent-queue 評估 + 納管計畫

## Context 背景

使用者臨時裝了 `connerohnesorge/herdr-agent-queue`（Codex 式 prompt queue：agent turn 結束才送出下一則），並手動在 live `~/.config/herdr/config.toml` 加了 `prefix+shift+q` 綁定。想知道是否值得長期保留，以及 herdr 狀態抖動會不會讓 prompt 提前送出。

## 評估結論 Verdict

**可以留，但當成 trial 等級。** 程式碼只有一個 ~200 行 Python 檔（MIT、1 star、2026-09-29 單日寫完後沒再更新），讀完沒有可疑行為：只呼叫 `herdr` CLI、在 `~/.local/state/herdr/plugins/conner.agent-queue/` 存 JSON。

### 提前送出的風險（你擔心的那點）

- 送出條件 = herdr 回報 `done`/`idle`，**沒有 debounce**；只有 lock + `herdr agent prompt --wait --until working`，防的是「同一 turn 送兩則」，不防誤判。
- 本機 Claude 的 herdr integration hook（`~/.claude/hooks/herdr-agent-state.sh`）**只回報 session，不回報狀態**，所以 Claude 的狀態仍來自 screen heuristics（title + OSC progress）→ 抖動是真實可能。
- 實際傷害偏小：Claude Code 本來就能在工作中收輸入，提前送出 ≈ 一則 mid-turn 插話，而不是遺失。
- **更常見的踩雷點是按 Esc 中斷**：中斷後狀態變 `idle`，queue 會立刻送出下一則 — 想糾正 agent 時要先 `:clear`。
- 其他限制：只能單行、關掉的 pane 不會清 queue 檔、skill 補全只支援 Claude。
- 目前 plugin log（`herdr plugin log list --plugin conner.agent-queue`）沒有任何 `submitted to` 紀錄，只有開關 popup 與 event，所以還沒實際觀察到誤送。

### 必須處理的問題

**你的快捷鍵下次 `chezmoi apply` 就會被刪掉。** `dot_config/herdr/modify_config.toml.tmpl` 對 `[keys]` 是整張表 template wins，`chezmoi diff` 已經顯示會移除那段 `[[keys.command]]`。另外 plugin 本身是手動安裝的，其他機器不會有。

## 實作計畫（若決定保留）

比照 herdr-plus 已有的模式：

1. **快捷鍵** → 加到 `.chezmoitemplates/herdr/config.toml` 的 herdr-plus 區塊附近（約 L407 起），`prefix+shift+q` → `plugin_action` `conner.agent-queue.open`，註解寫明需要該 plugin、未安裝時按鍵無效。已確認 template 內沒有 `shift+q` 衝突。
2. **安裝** → `dot_ansible/roles/devtools/tasks/main.yml` 在 herdr-plus 區塊（約 L4875–4930）後面加相同結構的 check/install/rescue：`herdr plugin list --json | grep conner.agent-queue` → `herdr plugin install connerohnesorge/herdr-agent-queue --yes`（不需 Go；需要 `python3`）。非致命、idempotent。
3. **tool catalog** → `dot_config/docs/tools/tool-catalog.toml` 新增 `[[tool]]`，再跑 `just gen-tool-index`（CLAUDE.md 規則）。
4. **文件** → `docs/tools/herdr.md` + `herdr.zh-TW.md`：新增 plugin 小節（用途、`prefix+Q`、Esc 中斷會觸發送出、Claude 狀態靠 heuristics 的提醒、log/state 路徑），並在 keybinding 表加一列。
5. **agent skill** → 視需要在 `dot_agents/skills/chezmoi-dotfiles/SKILL.md.tmpl` 的 herdr 段落提一句。
6. （選用）`backlog/` 記一筆：若之後遇到誤送，可考慮 fork 加 debounce（例如狀態穩定 N 秒再送）或向上游提出。

## Verification 驗證

- `chezmoi diff ~/.config/herdr/config.toml` → 不再顯示刪除綁定；`chezmoi apply` 後 `herdr server reload-config`，在 Claude pane 按 `prefix+Q` 能開 popup。
- Ansible：`ansible-playbook … --tags devtools --check`（或窄範圍執行），確認已安裝時 skip。
- 文件：`just docs-build`；catalog：`uv run pytest tests/unit/test_tool_catalog.py`。
- 實測：在 working 中的 Claude pane queue 一則，看 log 出現 `submitted to …` 且時機在 turn 結束後。
