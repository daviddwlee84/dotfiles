# Plan: `claude-plans-here` zsh function

## Context

Vibe coding 時 Claude Code 預設把 `/plan` 產生的計畫檔寫到 user-global 的 `plansDirectory`(例如 `~/.claude/projects/<repo>/plans/`),導致計畫散落在 home 而不是跟著 repo 走。

這個 repo 自己的 `.claude/settings.json` 已經示範了正確的做法 ——
```json
{ "plansDirectory": "./.claude/plans" }
```
讓 plan 檔留在當前 repo 的 `.claude/plans/`,可以跟 specstory transcripts、其它 agent 產物一起被 `agent-history-hygiene` skill 管理(redact + 入版控)。

需要一個 zsh function,在任何專案目錄一鍵把這份 settings.json scaffold 出來。對已存在的 settings.json(例如有 hooks / permissions / model 等其他 key),要 **jq 合併** 進 `plansDirectory` 而不是覆蓋,並且預設要互動確認。

## Approach

新增 zsh function `claude-plans-here` 到 `dot_config/zsh/10_aliases.zsh` 結尾(緊接在 `brew-mirror` 之後),沿用同檔案既有的 `emulate -L zsh` + 短旗標 + stderr 提示風格。

### 行為規格

| 情境 | 行為 |
|------|------|
| `.claude/settings.json` 不存在 | 直接 `mkdir -p .claude` + heredoc 寫入兩行 JSON,**不需 jq、不 prompt** |
| 檔案存在,interactive | jq merge `plansDirectory: "./.claude/plans"` 進去前,`read -q` 問 y/N |
| 檔案存在 + `-f` | 跳過 prompt,直接 jq merge(non-interactive 用,例如腳本/CI) |
| 檔案存在但 jq 沒裝 | 印錯誤到 stderr,`return 1`(不 fallback,不靜默覆蓋) |

JSON merge 用 `jq '. + {plansDirectory: $p}'` —— 後者覆蓋前者語意,如果 key 已存在會被改寫成 `./.claude/plans`,其他 key 全部保留。寫入用 mktemp + mv 的兩步 atomic pattern,避免 jq 失敗時把原檔截斷。

### 命名

`claude-plans-here` —— 跟 `sesh-here`(在當前目錄起 sesh)、`brew-mirror`(切 brew mirror)、`gcam-amend`(amend last commit)同一個 dash-action 風格,`cl<TAB>` 也方便 tab-completion 把 claude-* 系列一起列出來。

## Files to modify

### 1. `dot_config/zsh/10_aliases.zsh` —— 新增 function

加在檔尾(line 179 之後),約 30 行:

```zsh
# Scaffold or update project-local .claude/settings.json so Claude Code's
# /plan files land in ./.claude/plans/ (kept inside the repo) instead of
# the user-global plansDirectory. Pairs well with the agent-history-hygiene
# skill, which can then redact + commit the plan files alongside the diff.
# Usage: claude-plans-here [-f]
#   -f   non-interactive: skip the y/N prompt when settings.json exists
claude-plans-here() {
  emulate -L zsh
  local force=0
  [[ "$1" == "-f" ]] && force=1
  local target=".claude/settings.json"

  mkdir -p .claude

  if [[ ! -e "$target" ]]; then
    cat >"$target" <<'EOF'
{
  "plansDirectory": "./.claude/plans"
}
EOF
    echo "Wrote $PWD/$target"
    return 0
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "claude-plans-here: jq required to merge into existing $target" >&2
    return 1
  fi

  if (( ! force )); then
    local ans
    read -q "ans?$target exists. Merge plansDirectory into it? [y/N] " || { echo; return 1; }
    echo
  fi

  local tmp
  tmp="$(mktemp)" || return 1
  if jq --arg p "./.claude/plans" '. + {plansDirectory: $p}' "$target" >"$tmp"; then
    mv "$tmp" "$target"
    echo "Merged plansDirectory into $PWD/$target"
  else
    rm -f "$tmp"
    echo "claude-plans-here: jq failed; $target unchanged" >&2
    return 1
  fi
}
```

關鍵設計點:
- `cat <<'EOF'`(quoted heredoc)— 確保 `$` 不被 shell 解釋,JSON 內容逐字寫入。
- jq path 用 `--arg p` —— 避免把字串當 jq 表達式 parse。
- `read -q` 是 zsh 內建單字元 y/N,符合 `emulate -L zsh` 環境。
- 不 pre-create `.claude/plans/` 目錄 —— Claude Code 第一次 `/plan` 時會自己建,少一個多餘動作。

### 2. `docs/zsh/aliases.md` —— 更新文件(repo 的 maintenance rule)

依照 `CLAUDE.md` 的 maintenance rule:任何 alias / function 變更要同步更新 `docs/zsh/aliases.md`。

- 在 TOC(line 10–26)插入新項:
  ```markdown
  - [Claude Code](#claude-code)
  ```
  位置:放在 `- [AI Capture]` 之後、`- [Package Managers & Runtime]` 之前。
- 在文件主體,於 "AI Capture" section(line 587–599)結束後、"Package Managers & Runtime"(line 602)之前,新增一個 section:

  ```markdown
  ---

  ## Claude Code

  > Project-local Claude Code config helpers. Requires `jq` only for the merge path.

  | Command | Type | Source File | Description |
  |---------|------|-------------|-------------|
  | `claude-plans-here [-f]` | function | `dot_config/zsh/10_aliases.zsh` | Scaffold/update `./.claude/settings.json` so `/plan` files land in `./.claude/plans/` (in-repo) instead of the user-global plansDirectory. New file: write directly. Existing file: `jq`-merge the `plansDirectory` key (preserves hooks/permissions/model). Prompts `y/N` unless `-f` is given. |
  ```

## What is intentionally NOT changed

- 不動 `dot_claude/modify_settings.json` —— 那是 user-global `~/.claude/settings.json` 的 chezmoi `modify_` overlay,跟 per-project 的 `.claude/settings.json` 是兩個不同的 surface(參見 `CLAUDE.md` → "modify_ and create_ prefix semantics" 與 `docs/tools/agent-overlays.md`)。
- 不新建 tool-specific 檔案(例如 `dot_config/zsh/tools/06_claude_project.zsh`)—— 目前只有一個 function,沿用 `brew-mirror` 級別的精簡度放在 `10_aliases.zsh`,日後若再多兩三個 claude-* helper 再拆。
- 不在 function 裡 pre-create `.claude/plans/` 或 `.gitignore` 設定 —— Claude Code 自己會建目錄,gitignore 是 per-project 決策(有些人想 commit plan 檔)。

## Verification

1. **Reload shell**:`exec zsh`(或 `source ~/.config/zsh/10_aliases.zsh`)。
2. **空目錄建立**:
   ```bash
   mkdir /tmp/cph-test && cd /tmp/cph-test
   claude-plans-here
   cat .claude/settings.json   # 預期: {"plansDirectory": "./.claude/plans"}
   ```
3. **既有檔案 + interactive prompt**:
   ```bash
   echo '{"model":"opus","permissions":{"allow":["Bash"]}}' > .claude/settings.json
   claude-plans-here            # 應該 prompt: "...exists. Merge ... [y/N] "
   # 按 y → 預期合併後三個 key 都在
   jq . .claude/settings.json
   ```
4. **`-f` 非互動**:
   ```bash
   claude-plans-here -f         # 不 prompt,直接 merge
   ```
5. **jq 缺失情境**(可略,只有沒裝 jq 的 host 才需要):temporarily rename jq → 應該印錯誤、`return 1`、原檔不變。
6. **真實 Claude Code 流程**:在 step 2 的 `/tmp/cph-test/` 跑 `claude` 進入 plan mode,確認新生成的 plan 檔出現在 `./.claude/plans/<...>.md`,不是 `~/.claude/projects/...`。
7. **文件 lint**(repo 的標準):
   ```bash
   uv run mkdocs build --strict
   ```
   驗證 `docs/zsh/aliases.md` 沒有破壞錨點或 nav。
