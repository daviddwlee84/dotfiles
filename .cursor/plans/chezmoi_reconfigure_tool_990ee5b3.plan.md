---
name: chezmoi reconfigure tool
overview: 在 SSOT 腳本 scripts/init/dotfiles_init.py 加一個 reconfigure 子命令，讓已初始化的機器能用既有 TUI（預填目前 chezmoi.toml 的實際值）重設，並透過 chezmoi init --apply --prompt 真正生效；順手修掉現有 init re-init 分支漏掉 --prompt 的 bug，並加上 just recipe、shell alias、文件更正。
todos:
  - id: read-config
    content: 在 dotfiles_init.py 加 read_current_config()（tomllib 讀 CHEZMOI_CONFIG 的 [data]）
    status: completed
  - id: argv-prompt
    content: build_chezmoi_argv 加 prompt 參數注入 --prompt；修正 run_init re-init 分支：source_exists 時 prompt=True 並以目前 config 值當 overrides
    status: completed
  - id: reconfigure-cmd
    content: 新增 ReconfigureCmd / run_reconfigure（含 --set 解析+驗證、互動預填、非互動全旗標展開）並接上 main()/Command
    status: completed
  - id: just-recipe
    content: justfile 新增 reconfigure recipe
    status: completed
  - id: shell-alias
    content: dot_config/shell/99_chezmoi_reload.sh 新增 czcfg 函式（經 chezmoi source-path 定位腳本）
    status: completed
  - id: docs
    content: 更新 docs/shells/aliases.md、scripts/init/README.md（更正 re-init 語意+新增 reconfigure）、README.md，並新增 promptOnce stale-value pitfall
    status: completed
  - id: verify
    content: gen --check、reconfigure --dry-run、execute-template --init --prompt 對照、--set --yes --no-apply 驗證
    status: completed
isProject: false
---

## 背景與關鍵事實（已實測）

- `PROMPTS`（`scripts/init/dotfiles_init.py`）已是 single source of truth；`init` 子命令也已有 `source_exists` 的 re-init 分支。
- **但 re-init 改不動設定**：`.chezmoi.toml.tmpl` 用 `promptBoolOnce`，當 `~/.config/chezmoi/chezmoi.toml` 的 `[data]` 已有值就直接回傳舊值。實測（`chezmoi execute-template --init`）：已存 `installLlmTools=true`，傳 `--promptBool "...=false"` 仍輸出 `true`。
- 解法：`chezmoi init` 加 `--prompt`（v2.69.3 已支援 `--prompt` / `--promptBool` / `--promptChoice`）。加上 `--prompt` 後，所有 `prompt*Once` 會重新觸發，再用完整旗標集非互動地餵入新值。
- 因此 `build_chezmoi_argv` 目前少送 `--prompt`，而 `scripts/init/README.md` 的「Re-init semantics」段落（聲稱 explicit flags take precedence）是錯的。

## 設計

新增 `reconfigure` 子命令（互動 TUI 預填目前值）＋ `--set key=value`（非互動單鍵改值）＋ `--yes/--dry-run/--no-apply`。所有行為仍由 `PROMPTS` 驅動，無新增設定面。

### 1) `scripts/init/dotfiles_init.py`

- 新增讀目前設定的 helper：用 stdlib `tomllib`（requires-python >=3.11 已滿足）讀 `CHEZMOI_CONFIG` 的 `[data]` 表，回傳 `{key: 現值}`。找不到檔案則視為未初始化。

```python
import tomllib
def read_current_config() -> dict[str, object]:
    if not CHEZMOI_CONFIG.exists():
        return {}
    return tomllib.loads(CHEZMOI_CONFIG.read_text()).get("data", {})
```

- `build_chezmoi_argv(...)` 新增參數 `prompt: bool = False`；為真時在 `init` 後插入 `--prompt`。
- `run_init` 的 re-init 分支修正：`source_exists` 時 `prompt=True`，並把 `overrides` 以目前 config 值為底（避免重跑 init 把沒動到的選項重設成 bundle/預設值的 footgun）。
- 新增 `@dataclass ReconfigureCmd`（tyro 子命令 `reconfigure`）：欄位 `set: tuple[str, ...]`、`yes`、`dry_run`、`no_apply`。
- 新增 `run_reconfigure(cmd)` 流程：
  1. `detect()`；若非 `source_exists` → 紅字提示「尚未初始化，請先跑 init」回傳 2。
  2. `current = read_current_config()`；若目前 `profile` 不在合法 choices（例如這台機器殘留的 `macos_intel`）→ 退回 OS 自動偵測值並提醒。
  3. 解析 `--set`：驗證 key 屬於 `PROMPTS`、依 kind 轉型（bool 接受 true/false/1/0/yes/no；choice 驗證在 `choices` 內），疊到 `current` 上。
  4. 互動 vs 非互動：
     - 有 `--set` 且 `--yes`（或無 TTY）→ 跳過 TUI，answers 由「current＋set」對**所有 applicable prompt**展開（因 `--prompt` 會強制全部重問，旗標必須覆蓋全部）。
     - 否則 → 用 `ask_basics/ask_features/ask_choices`，傳 `overrides=current`（這些函式本就 `overrides.get(key, default)`，即可預勾目前值）。
  5. `build_chezmoi_argv(answers, repo=None, prompt=True, apply=not no_apply)`；`confirm_plan`（非 `--yes` 時）；`run_chezmoi`；`print_recap`。
- `main()` / `Command` Union 加上 `reconfigure`。

### 2) `justfile`

於 `bootstrap-local` 附近新增：

```make
# Reconfigure an already-initialized machine (seeds the TUI from current
# chezmoi.toml values, then `chezmoi init --apply --prompt`). Non-interactive:
#   just reconfigure -- --set installLlmTools=true --set motdStyle=figlet --yes
reconfigure *ARGS:
    uv run --script scripts/init/dotfiles_init.py reconfigure {{ARGS}}
```

### 3) shell alias（`dot_config/shell/99_chezmoi_reload.sh`，與 `cas`/`cau` 並列）

scripts 不會被部署，故透過 `chezmoi source-path` 定位：

```sh
# czcfg - reconfigure dotfiles prompts (seeded from current values), then apply.
czcfg() {
    local src; src="$(chezmoi source-path 2>/dev/null)" || return 1
    uv run --script "${src}/scripts/init/dotfiles_init.py" reconfigure "$@"
}
```

### 4) 文件（依 AGENTS.md 跨檔規則同 commit 更新）

- `docs/shells/aliases.md`「Dotfiles management」段：在 `cas`/`cau` 旁加 `czcfg` 一列。
- `scripts/init/README.md`：更正「Re-init semantics」（要 `--prompt` 才會覆蓋既有值），新增「Reconfigure」段（`reconfigure` 子命令 + `--set` 用法）。
- `README.md`：在初始化相關段落補一行「重設已初始化機器：`just reconfigure` / `czcfg`」。
- 把現有 `pitfalls/chezmoi-init-prompt-flag-mismatch.md` 之外、這次新確認的「`promptBoolOnce` 既有值贏、re-init 必須 `--prompt`」記成一則 pitfall（依 project-knowledge-harness 規則，以症狀命名，如 `pitfalls/chezmoi-reinit-promptonce-keeps-stale-value.md`）。

## 驗證

- `just gen-prompts -- --check`（確保沒動到生成區塊仍乾淨）。
- `uv run --script scripts/init/dotfiles_init.py reconfigure --dry-run`：確認 argv 含 `--prompt` 且涵蓋所有 applicable 旗標。
- 唯讀驗證一筆：`chezmoi execute-template --init --prompt --promptBool "...=false"` 應輸出 `false`（旗標贏），對照目前無 `--prompt` 會輸出舊值。
- `just reconfigure -- --set <bool key>=<反向值> --yes --no-apply` 跑通且 confirm/recap 正確（`--no-apply` 不動真實狀態）。

## 不在此次範圍

- 不改 `.chezmoi.toml.tmpl` 的生成區塊（`gen` 仍是唯一寫入者）。
- 不新增任何設定項（純 UI/流程層）。
- Windows / fleet 廣播重設（fleet 仍各機自跑）。
