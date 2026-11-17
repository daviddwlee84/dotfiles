# SpecStory config template 更新

## Context 背景

- `~/.specstory/cli/config.toml` 落後的主因**不是 template 沒更新**，而是它是 `create_` 檔：只 seed 一次，之後 chezmoi 不再動它。
  - Source template 已經有 `antigravity_cmd`、`[redaction]`，codex 也拿掉了 `model_reasoning_effort="high"`。
  - 那個 `high` 是最初 commit `59a22aa3`（"Add SpecStory user-level config for YOLO mode"）帶進來的，後來的 template 已清掉，但本機 deployed 檔一直沒 re-seed。
- SpecStory 2.17.0 目前支援的 `*_cmd` key（從 binary 取出）：antigravity, claude, codex, copilot, copilotide, cursor, cursorcloud, cursoride, deepseek, droid, gemini, grok, muse, opencode, pi, qwen, shell。Template 只寫了 6 個。
- 順便修一個 bug：`gemini_cmd = "gemini --sandbox=none"` 根本不是 bypass——真正的 approval bypass 是 `--yolo`。

決策（已確認）：Claude 維持 `--dangerously-skip-permissions`；Codex 改用單一 `--dangerously-bypass-approvals-and-sandbox`，保留 `model_reasoning_summary="detailed"`。

## Changes 變更

### 1. `private_dot_specstory/private_cli/create_config.toml` — `[providers]`
依 provider 字母順序，每個都附一行註解說明 flag：

| key | value | 依據 |
|---|---|---|
| `antigravity_cmd` | `agy --dangerously-skip-permissions`（不變） | `agy --help` |
| `claude_cmd` | `claude --dangerously-skip-permissions`（不變） | 使用者決定 |
| `codex_cmd` | `codex --dangerously-bypass-approvals-and-sandbox -c model_reasoning_summary="detailed"` | `codex --help` |
| `copilot_cmd` | `copilot --yolo`（新增；本機未安裝，註明待驗證） | Copilot CLI `--yolo`/`--allow-all` |
| `cursor_cmd` | `cursor-agent --force`（不變） | `cursor-agent --help` |
| `droid_cmd` | `droid --yolo`（不變） | — |
| `gemini_cmd` | `gemini --yolo`（**修正**） | `gemini --help` |
| `opencode_cmd` | `opencode --auto`（新增） | `opencode --help`：auto-approve not-denied |
| `pi_cmd` | `pi`（新增；pi 沒有 permission 系統，寫出來只為完整/文件化） | `pi --help` |
| `qwen_cmd` | `qwen --yolo`（新增；gemini fork，未安裝，註明待驗證） | — |

- `deepseek` / `grok` / `muse`：不確定 bypass flag 且本機未安裝 → 以**註解**列出 `# deepseek_cmd = "deepseek"` 等，標註「flag unverified」，不猜。
- `copilotide` / `cursoride` / `cursorcloud`：IDE/cloud provider，`run` 不 launch 本地 CLI → 不寫。
- 保留現有的「always name the provider」註解。
- 實作時先 `specstory check copilot`/`qwen`（help 或 docs）快速確認 flag；查不到就降級為註解。

### 2. 本機 deployed 檔 re-seed（`~/.specstory/cli/config.toml`）
`create_` 不會自動更新。做法：用新 template 覆蓋 deployed，但**保留**它的 `[resume]` block（specstory runtime state：`view_mode`/`last_agent`）。即 `chezmoi cat` 新內容 + append 原 `[resume]`。

### 3. Docs 同步
- `docs/tools/specstory.md` + `docs/tools/specstory.zh-TW.md`：§ Managed Defaults provider 清單、§ Safety Tradeoff；把 Codex 0.156 那段改寫成「existing hosts 要手動 re-seed」的通用說明（加上 gemini `--sandbox=none` → `--yolo` 修正）。
- `README.md:258` 那行描述更新（提到涵蓋更多 provider）。
- 檢查 `dot_config/shell/43_copilot_proxy.sh` / `copilot-session.py` 是否 parse `codex_cmd` 內容並假設 `--ask-for-approval`（若有，跟著調整/測試）。

## Verification 驗證

1. `python3 -c 'import tomllib;tomllib.load(open(...))'` 驗 TOML。
2. 用 app 驗：`specstory check`（確認 config 被讀、無 error）；對已安裝的 provider 用 fake-argv 方式或 `specstory run <p> --help` 確認指令被接受：codex、gemini、opencode、pi 各自 `<cmd> --help` 不報 unknown flag。
3. `grep -rn "ask-for-approval\|codex_cmd" dot_config/shell tests/` → 若有相依，跑 `bats tests/unit/copilot_proxy.bats` 與 `uv run pytest tests/unit/test_copilot_session.py`。
4. `just docs-build`。
5. `chezmoi diff ~/.specstory/cli/config.toml` 應只剩 `[resume]` 差異（create_ 不會覆寫）。
