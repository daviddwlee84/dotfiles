# pqsum

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

`pqsum` 是一個 Zsh helper，把 `pueue status --json` 的輸出彙整成易讀的佇列 (queue) 指標。

- **函式 (function) 檔案**：`~/.config/zsh/tools/36_pueue.zsh`
- **依賴**：`pueue`、`jq`
- **可選增強**：`column`（用於對齊的表格輸出）
- **版本要求**：`pueue >= 4.0.0`

## 顯示內容

`pqsum` 會印出三個區段：

1. `Overall`
   - 任務總數
   - 完成進度（`done/total`、ASCII 進度條、與 `%`）
   - 已完成任務的平均耗時（僅 `Done`）
   - 預估剩餘時間（ETA）
2. `Status Breakdown`
   - 對齊表格：狀態、數量、進度
3. `Group Summary`
   - 對齊表格欄位：group、daemon、parallel、total、done、progress、bar、total_spent、avg_done、eta、statuses

## 用法

```bash
# 完整摘要
pqsum

# 單一 group 摘要（只顯示該 group）
pqsum -g default
pqsum --group synthesis

# 直接把任意 pueue status query/filter 透傳過去
pqsum status=running
pqsum "status=done order_by end desc first 20"
```

範例輸出形式：

```text
Pueue Summary
Overall
  Total tasks: 9
  Done progress: 9/9  [============]  100.0%
  Avg done duration: 1m 18s
  Est. remaining (ETA): 0s

Status Breakdown
  status  count  progress
  Done    9      100.0%

Group Summary
  group      daemon   parallel  total  done  progress  bar           total_spent  avg_done  eta  statuses
  default    Running  1         9      9     100.0%    [============] 4h 12m 8s    1m 18s   0s   Done=9
```

## 備註

- `pqsum` 會把所有參數轉送給 `pueue status --json`。
- 若缺少 `pueue` 或 `jq`，`pqsum` 會以非零 exit code 結束並印出錯誤。
- 平均耗時只計入同時具備 `Done.start` 與 `Done.end` 的任務。
- `total_spent` 是該 group 中觀察到的最早與最晚時戳之間的時段（取自任務的 `created_at` 與狀態時戳如 `enqueued_at/start/end`）。
- ETA 是粗略估計，公式為 `remaining * avg_done / max(parallel, 1)`。
- `-g/--group` 控制摘要輸出顯示哪些 group 列。
- 顏色僅在 TTY 輸出時啟用，且設定 `NO_COLOR` 時停用。
- 若找不到 `column`，`pqsum` 會 fallback 到純空白排版（仍可閱讀）。

## 相關

- [Pueue Advanced usage](https://github.com/Nukesor/pueue/wiki/Advanced-usage)
- [Pueue Configuration](https://github.com/Nukesor/pueue/wiki/Configuration)
