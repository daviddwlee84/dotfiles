# Claude Code 鍵位設定 (`~/.claude/keybindings.json`)

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

`Claude Code` 將其 TUI (terminal UI) 鍵位 (keymap) 儲存在獨立於 `~/.claude/settings.json` 的檔案中。本頁說明該檔案格式、可自訂的範圍，以及本 repo 如何透過 `modify_` 覆蓋層 (overlay) 管理它。

| 介面 | 路徑 |
|---|---|
| 即時檔案 | `~/.claude/keybindings.json` |
| 來源覆蓋層 | [`dot_claude/modify_keybindings.json`](../../dot_claude/modify_keybindings.json) |
| Schema | <https://www.schemastore.org/claude-code-keybindings.json> |
| 文件 | <https://code.claude.com/docs/en/keybindings> |

## 檔案結構

```json
{
  "$schema": "https://www.schemastore.org/claude-code-keybindings.json",
  "$docs": "https://code.claude.com/docs/en/keybindings",
  "bindings": [
    {
      "context": "Chat",
      "bindings": {
        "shift+tab": "chat:cycleMode",
        "enter": "chat:submit",
        "ctrl+j": "chat:newline",
        "...": "..."
      }
    },
    { "context": "Global", "bindings": { "...": "..." } }
  ]
}
```

頂層的 `$schema` 與 `$docs` 字串是給編輯器整合用的（自動補完、滑鼠懸停文件查找）。它們**不會被 Claude Code 本身使用**——但將它們釘在來源覆蓋層中可讓每台機器都能引用到相同的標準 URL。`$schema` 是 [JSON Schema](https://json-schema.org/) 的標準慣例；`$docs` 則是 Claude Code 特有的擴充，JSON Schema 驗證器會忽略它。關於此機制的一般入門——包括如何為我們自己的某個設定編寫 schema——請參閱 [本 repo 中的 JSON Schema](json-schema.md)。

`bindings` 是一個以 context 為鍵的陣列。每個項目的 `bindings` 物件將鍵字串（`shift+tab`、`meta+p`，序列則用 `ctrl+x ctrl+e`）對應到動作名稱（`chat:cycleMode`、`chat:submit`，⋯）。

### 可用的 context

讀自使用者 2026-04 時的即時檔案：`Global`、`Chat`、`Autocomplete`、`Settings`、`Doctor`、`Confirmation`、`Tabs`、`Transcript`、`HistorySearch`、`Task`、`ThemePicker`、`Scroll`、`Help`、`Attachments`、`Footer`、`MessageSelector`、`DiffDialog`、`ModelPicker`、`Select`、`Plugin`。檢查您自己的副本以取得完整的預設集合：

```bash
jq '.bindings[] | .context' ~/.claude/keybindings.json
```

## `chat:cycleMode` 的限制

權限模式 (permission mode)（`default`、`acceptEdits`、`plan`、`bypassPermissions`、`auto`、`dontAsk`）只能透過**單一**動作 `chat:cycleMode` 切換——預設綁定到 `shift+tab`。**沒有**任何已記載的動作可以**直接**跳到特定模式（沒有 `chat:setMode`、沒有 `chat:enterPlan` 等）。已對照 `code.claude.com/docs/en/keybindings` 於 2026-04-27 確認。

實務上的影響：

- 您無法將單一鍵綁定到「進入 plan 模式」——唯一路徑是 `Shift+Tab` `Shift+Tab` ⋯ 走完整個循環。
- 循環順序為 `default → acceptEdits → plan → bypassPermissions`（若您的 build 啟用了 `auto` 也可能包含）；若要從 `acceptEdits`（您通常在 `ExitPlanMode` 之後會落到的狀態，見下文）到達 `bypassPermissions`，需按 `Shift+Tab` 兩次。
- 加一個重複的綁定（例如將更易按的鍵對應到 `chat:cycleMode`）並無法縮短路徑——它只是讓您有兩種方式去推進同一個循環。仍需循環。

如果/當 `Claude Code` 增加每個模式的動作時，依照下文的合併指引將新動作併入 [`dot_claude/modify_keybindings.json`](../../dot_claude/modify_keybindings.json)。

### 相關 pitfalls

- [`pitfalls/claude-code-permission-mode-resets-after-interactive-prompt.md`](../../pitfalls/claude-code-permission-mode-resets-after-interactive-prompt.md) — 在 `AskUserQuestion`、CodeIsland 彈出視窗、遠端控制 inject 與 `ExitPlanMode` 之後，模式會無聲重置。無論 `permissions.defaultMode` 為何，皆會落在 `acceptEdits`。
- [`pitfalls/codeisland-auto-approves-permissionrequest.md`](../../pitfalls/codeisland-auto-approves-permissionrequest.md) — 在 macOS 上安裝 CodeIsland HUD 後，`ExitPlanMode`（以及其他權限請求）會被無聲蓋章核准，伴隨 `⎿ Allowed by PermissionRequest hook` / `⏺ Plan approved.`。上述的 `chat:cycleMode` 復原路徑就是其可見的後果之一。

## `modify_` 覆蓋層的運作方式

[`dot_claude/modify_keybindings.json`](../../dot_claude/modify_keybindings.json) 是一個小型的 shell 腳本（鏡映 [`dot_claude/modify_settings.json`](../../dot_claude/modify_settings.json) 的結構）。有兩條執行路徑：

1. **Bootstrap（stdin 為空——即時檔案尚未存在）**：產出僅包含 `$schema` + `$docs` 的最小 stub。任何不在檔案中的綁定，Claude Code 會回退至內建預設值。
2. **穩態（即時檔案已存在）**：將即時 JSON 餵入 `jq '. * $overlay'`，對即時樹進行深度合併。即時的 `.bindings` 陣列會被原樣保留，因為覆蓋層沒有 `.bindings` 鍵，而 `jq` 的 `*` 運算子只會替換符合覆蓋層鍵路徑的陣列。

本機驗證：

```bash
# Bootstrap 路徑
echo '' | "$(chezmoi source-path ~/.claude/keybindings.json)"

# 穩態路徑
cat ~/.claude/keybindings.json | "$(chezmoi source-path ~/.claude/keybindings.json)" | jq '."$schema", (.bindings | length)'
```

透過 chezmoi 套用 / 檢視：

```bash
chezmoi diff ~/.claude/keybindings.json   # 應該只有 $schema/$docs 行不同
chezmoi apply ~/.claude/keybindings.json  # 第二次執行為 idempotent
```

### 加入個人綁定覆寫（未來）

目前覆蓋層**並未**附帶綁定覆寫。原因：`jq '. * $overlay'` 在符合鍵路徑時會整個替換陣列——如果我們在覆蓋層中為某個 context 放入 `bindings: [...]` 條目，所有其他 context 都會存活下來（因為合併的鍵在頂層為 `$schema`/`$docs`/`bindings`，而 `bindings` 在兩邊都存在），但合併會替換**整個** `bindings` 陣列，把 Claude Code 出貨的所有預設都覆蓋掉。

要安全地加入覆寫，請延伸該腳本的 jq 過濾器，依 `.context` 合併 `bindings`。一個草稿（尚未實作）：

```jq
. as $base
| ($overlay | del(.bindings)) as $non_bindings_overlay
| ($overlay.bindings // []) as $overlay_bindings
| ($base * $non_bindings_overlay) as $merged
| $merged
| .bindings = (
    ($merged.bindings // []) as $live_bindings
    | reduce $overlay_bindings[] as $entry (
        $live_bindings;
        # 若 $live 中存在該 context，深度合併 .bindings；否則附加。
        if any(.[]; .context == $entry.context) then
          map(if .context == $entry.context
              then .bindings = (.bindings + $entry.bindings)
              else . end)
        else . + [$entry] end
      )
  )
```

不要憑空寫這段過濾器——等到有具體值得跨機器釘住的綁定時再實作，並在 `tests/unit/agent_overlays.bats` 中與既有的 Claude settings 合併器測試一起新增 `bats` 測試。

## 另見

- [`dot_claude/modify_settings.json`](../../dot_claude/modify_settings.json) — `settings.json` 的姊妹覆蓋層。其中具有 hook 感知的合併器模式，是本覆蓋層未來陣列合併工作的參考。
- [`docs/tools/agent-overlays.md`](agent-overlays.md) — 本 repo 中編碼代理 (coding agent) CLI 覆蓋層的整體設計（Claude / OpenCode / Codex / Cursor）。
- [`docs/tools/chezmoi-prefixes.md`](chezmoi-prefixes.md) — `modify_` 與 `create_` 的語意以及在這裡選擇 `modify_` 的理由。
