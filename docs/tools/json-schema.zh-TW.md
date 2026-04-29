# 本 repo 中的 JSON Schema

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

[JSON Schema](https://json-schema.org/) 是描述 JSON 文件形狀的開放標準。當設定檔宣告 `$schema` 時，具備 JSON 語言支援的編輯器（VS Code、Cursor、JetBrains、Neovim 的 `jsonls`、Sublime LSP）會自動接上自動完成、hover 文件、紅色波浪線驗證 (validation) —— 不需要任何額外設定，也不需要 per-project 設定。本頁說明這個慣例目前在本 repo 中如何使用，以及若我們將來想自行撰寫結構描述 (schema) 時該怎麼做。

## TL;DR

| 概念 | URI / 位置 | 出現之處 |
|---|---|---|
| JSON Schema 標準 | <https://json-schema.org/>（目前 draft：2020-12） | `$schema` 宣稱遵守的文法 |
| 社群結構描述登錄處 | <https://www.schemastore.org/json/> | 編輯器會自動以檔名比對至此 |
| `$schema` 欄位（instance 端） | 寫在*設定檔*內 —— 指向結構描述 | 告訴編輯器「請拿這個 schema 驗證我」 |
| `$schema` 欄位（schema 端） | 寫在*結構描述文件*內 —— 指向 JSON Schema 方言 (dialect) | 告訴 JSON Schema 驗證器要用哪個方言去解析 |
| `$docs` 欄位 | 非標準 —— Claude Code 的慣例 | JSON Schema 不解釋它；純粹是給人類看的指引 |

同一個欄位名 `$schema` 會根據它出現在哪個檔案而扮演**兩種**角色。在設定檔內（例如 `~/.claude/keybindings.json`），它是「這個 instance 符合 schema X」的宣稱；在結構描述文件內，則是「我以 JSON Schema 方言 Y 撰寫」的宣稱（例如 `https://json-schema.org/draft/2020-12/schema`）。兩者很容易搞混。

## 編輯器如何發現結構描述

兩條取得路徑，依優先順序：

1. **檔案中的內嵌 `$schema`**：最高優先權。檔案宣告什麼 URI 就用什麼。編輯器會抓取該結構描述（會快取）並使用之。
2. **檔名 / glob 比對註冊的結構描述目錄 (catalog)**：SchemaStore 是事實上的登錄處 —— VS Code 內建的 `json` 擴充套件帶有它的目錄，JetBrains 與 Neovim 外掛也讀同一份。像 `package.json`、`tsconfig.json`、`.eslintrc.json` 這類檔名會自動發亮，因為 SchemaStore 把 glob 對映到結構描述 URI。

對於不在 SchemaStore（或命名不依慣例）的檔案，內嵌 `$schema` 是唯一實際可行的路徑。所以才有「在檔案開頭寫上 `$schema`」這個慣例。

## 本 repo 中既有的用法

| 檔案 | 結構描述 URI | 來源 | 理由 |
|---|---|---|---|
| `~/.config/opencode/opencode.json` | `https://opencode.ai/config.json` | 上游 OpenCode | 由原廠託管；OpenCode 自己的伺服器提供 schema。在 [`agents/opencode.overlay.json`](../../.chezmoitemplates/agents/opencode.overlay.json) 中釘住 (pin)。 |
| `~/.config/opencode/tui.json` | `https://opencode.ai/tui.json` | 上游 OpenCode | 同樣模式 —— TUI 子集另有獨立 schema。在 [`agents/opencode.tui.overlay.json`](../../.chezmoitemplates/agents/opencode.tui.overlay.json) 中釘住。 |
| `~/.claude/keybindings.json` | `https://www.schemastore.org/claude-code-keybindings.json` | SchemaStore | 由社群維護；SchemaStore 是知名設定格式 schema 的標準歸宿。透過 [`dot_claude/modify_keybindings.json`](../../dot_claude/modify_keybindings.json) 釘住 —— 詳見 [Claude Code keybindings](claude-code-keybindings.md)。 |

兩種風味，兩個教訓：

- **不屬於我們的檔案，原廠託管才是正確預設值。** OpenCode 擁有格式 → OpenCode 託管 schema → 我們只要指過去就好。
- **當上游工具懶得自己發布 schema 時，SchemaStore 是正確預設值。** SchemaStore 的 PR 通常一週內就會被合併，並會固定到特定路徑；一旦合併，全世界每個編輯器都會知道它。

## 自行撰寫結構描述（如果哪天有需要）

如果我們新增一個*我們自己*擁有的 JSON 設定檔 —— 例如假設的 `~/.config/dotfiles/preferences.json`，或某個腳本輸出的 JSON 形狀 —— 而我們希望編輯器能驗證它，工作流如下：

### 1. 撰寫結構描述文件

結構描述本身就是一個描述形狀的 JSON 檔：

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://daviddwlee84.github.io/dotfiles/_schemas/preferences.schema.json",
  "title": "dotfiles preferences",
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "theme": {
      "type": "string",
      "enum": ["light", "dark", "auto"],
      "default": "auto",
      "description": "UI colour scheme. `auto` follows the system."
    },
    "shortcuts": {
      "type": "object",
      "additionalProperties": { "type": "string" },
      "description": "Map of action-name → key combo."
    }
  },
  "required": ["theme"]
}
```

頂層欄位：

- `$schema`（這裡是方言，而非 instance reference）—— 釘到一個 JSON Schema draft。`2020-12` 是目前版本。
- `$id` —— schema 將要存放的標準 URI。**它必須與實際被服務的位置一致**，否則用 `$id` 解析 `$ref` 的驗證器會 404。
- `title`、`type`、`properties`、`required`、`additionalProperties`、`enum`、`default`、`description` —— 實際的形狀文法。

### 2. 把它放在穩定的地方託管

三個合理的選擇，依工作量 + 影響範圍由小到大：

| 託管處 | URI 形狀 | 何時使用 |
|---|---|---|
| Raw GitHub | `https://raw.githubusercontent.com/<owner>/<repo>/main/path/foo.schema.json` | 最快。GitHub 會積極快取；沒有基於 ETag 的重新驗證。個人使用沒問題。 |
| MkDocs 站點 | `https://daviddwlee84.github.io/dotfiles/_schemas/foo.schema.json` | 已透過 `.github/workflows/docs.yml` 在 push-to-main 時部署。把檔案放到 `docs/_schemas/` 下，再以已發布的 URL 引用。穩定、與站點一同版本化、`mkdocs serve` 時會 hot-reload。 |
| SchemaStore PR | `https://www.schemastore.org/foo.json` | 如果格式可以跨專案重用。對 [SchemaStore/schemastore](https://github.com/SchemaStore/schemastore) 提交 PR。一旦合併，全世界每個編輯器都會用檔名自動發現它。 |

對 repo 內部的設定，MkDocs 選項是最甜蜜點 —— 已經是我們維運中的基礎建設、已經在 CDN 上、版本節奏與設定本身一致。

使用方式：把 schema 放到 `docs/_schemas/` 下（這是個 MkDocs 會原樣部署的目錄，因為我們設定了 `not_in_nav: |\n  /_snippets/`，而 `_schemas/` 字首不會比對到任何 nav glob），然後從設定檔引用 `https://daviddwlee84.github.io/dotfiles/_schemas/<name>.schema.json`。註解：`docs/_snippets/` 已經為 `pymdownx.snippets` 而存在；如果哪天我們開始託管 schema，請依此模式建立兄弟目錄 `docs/_schemas/`，並確認它能通過 strict build。

### 3. 從 instance 端引用它

設定檔最上方：

```json
{
  "$schema": "https://daviddwlee84.github.io/dotfiles/_schemas/preferences.schema.json",
  "theme": "dark"
}
```

VS Code / Cursor 在下次開啟檔案時會抓取並快取 schema；自動完成 + 驗證會立刻發亮。

### 4. 迭代

Schema 對 append-only 友善：新增帶有 `default` 的選擇性欄位是向後相容的。移除或收緊欄位（例如把 `enum` 變窄）則是破壞性變更 —— 跟任何 API 一樣適用 Hyrum's Law。

## `$docs` 擴展

某些工具（Claude Code 的 `keybindings.json` 是其中之一）會在 `$schema` 旁邊放上 `$docs` URI。這**不是** JSON Schema 的一部分，驗證器會忽略它。它純粹是給人類看的指引 —— 「給機器看的 schema 在這、給人看的散文文件在那」。如果我們自己撰寫 schema，可以採用相同慣例；編輯器不會抱怨（大多數 schema 預設容忍未宣告的 `$` 字首頂層欄位，只要 schema 沒有在 root 宣告 `additionalProperties: false`）。

如果想要嚴格一點，請在 schema 中明確宣告 `$docs`：

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://daviddwlee84.github.io/dotfiles/_schemas/preferences.schema.json",
  "type": "object",
  "properties": {
    "$schema": { "type": "string", "format": "uri" },
    "$docs": { "type": "string", "format": "uri", "description": "Human-readable documentation URL." },
    "theme": { "type": "string", "enum": ["light", "dark", "auto"] }
  },
  "additionalProperties": false
}
```

這樣既能記錄此欄位，又能避免 `additionalProperties: false` 把它擋掉。

## 另見

- [json-schema.org → Getting started](https://json-schema.org/learn/getting-started-step-by-step) — 官方逐步教學。
- [SchemaStore catalog](https://www.schemastore.org/json/) — 撰寫新 schema 之前先看看現有覆蓋範圍。
- [SchemaStore contributing guide](https://github.com/SchemaStore/schemastore/blob/master/CONTRIBUTING.md) — 社群 schema 提交規則。
- [`docs/tools/claude-code-keybindings.md`](claude-code-keybindings.md) — repo 中具體案例：SchemaStore 託管的 Claude Code keybindings schema 如何透過 `modify_keybindings.json` 覆蓋層被引用。
- [`docs/tools/agent-overlays.md`](agent-overlays.md) — 兄弟篇：OpenCode 原廠託管的 schema 如何透過 `modify_opencode.json.tmpl` 與 `modify_tui.json.tmpl` 覆蓋層釘住。
