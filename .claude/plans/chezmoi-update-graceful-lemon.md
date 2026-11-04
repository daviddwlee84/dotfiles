# 修復 chezmoi update 的 uvCacheDir 缺值錯誤

## Context

使用者執行 `chezmoi update --init`，Git 從 `1658055` 更新至 `f2ea3a4`，bootstrap 成功後遇到：

```text
chezmoi: .config/uv/uv.toml: template: dot_config/uv/uv.toml.tmpl:2:9: executing "dot_config/uv/uv.toml.tmpl" at <.uvCacheDir>: map has no entry for key "uvCacheDir"
```

已確認根因：commit `122f426f14bf31f3053ed821b26da783c5efa552`（`uv: optional per-machine cache-dir via chezmoi data uvCacheDir`）新增了 `{{- with .uvCacheDir }}`，卻將可選欄位當成必定存在的 key。chezmoi 嚴格求值會先報缺 key，`with` 無法保護缺值存取。`scripts/init/dotfiles_init.py` 和 `.chezmoi.toml.tmpl` 都沒有這個選項，因此 `--init` 不會產生它。不是下載、鏡像、sudo 或 uv 安裝失敗。

目標：沒設定自訂快取的主機繼續使用 uv 預設位置；有設定的主機保持現有行為。不增加新 prompt，也不修改任何機器的實際快取位置。

## 最小修復

1. **`dot_config/uv/uv.toml.tmpl:2`**：只將可選欄位讀取改成既有的安全查找慣例：
   ```gotemplate
   {{- with (dig "uvCacheDir" "" .) }}
   ```
   保留 `quote` 編碼與 `cache-dir` 位於所有 TOML table 之前的結構；缺值或空字串不輸出 `cache-dir`。不改動鏡像設定、初始化產生器或生成區塊。
2. **新增 `tests/unit/test_uv_config.py`**：沿用 `tests/unit/test_personal_tools.py:279-310` 的隔離空設定、`chezmoi execute-template --override-data` 與 unittest 模式；不要讀取使用者的真實 chezmoi 資料。
   - 缺少 `uvCacheDir`、空字串、自訂路徑（含空白與引號）。
   - 各案例交叉測試 `useChineseMirror=true/false`。
   - 使用 `tomllib` 確認有效 TOML、頂層 `cache-dir` 正確省略或保留原值，鏡像 table 不受影響。
   - 新增薄包裝 **`tests/unit/uv_config.bats`**，沿用 `tests/unit/personal_tools.bats:3-8` 呼叫該 unittest，讓既有 `just bats`（`bats tests/unit`）自動納入，避免回歸測試只存在卻沒被 runner 執行。
3. **`README.md:235`**：在既有 uv 設定項目簡短註明自訂 cache-dir 可選，未設定時使用 uv 預設位置，符合設定變更需同步 README 的規則。不要宣稱這是 init prompt 或保證手填 key 經 re-init 會保留。

## 驗證

已完成的唯讀驗證：
- 用 `/dev/null` 作為 chezmoi 設定，原模板重現完全相同的缺 key 錯誤。
- 僅在記憶體中替換該行，缺 key／空字串／含空白自訂路徑／鏡像開關均渲染成功，輸出通過 `tomllib`。
- 確認本機 `chezmoi v2.72.2` 與 `uv 0.9.24`；尚未修改模板，也尚未完成 uv 實際設定解析驗證。

實作後：
1. 執行 `python3 -m unittest discover -s tests/unit -p 'test_uv_config.py'`。
2. 將各種渲染結果寫至隔離暫存 `uv.toml`，執行 `uv --offline --config-file <temp>/uv.toml cache dir`；測試環境排除 `UV_CACHE_DIR`、`UV_NO_CONFIG` 等覆寫，確認應用程式真的接受設定，並驗證自訂路徑的解析結果。不安裝任何套件或使用網路。
3. `chezmoi cat ~/.config/uv/uv.toml` 驗證真實目標可渲染；檢查 `git diff --check` 與差異範圍。
4. 本次只修 source，不自動執行全域 `chezmoi apply`／安裝／提交／推送。修正可用於出錯主機後，使用者可先 `chezmoi cat ~/.config/uv/uv.toml` 確認，再執行 `chezmoi apply` 完成上次中斷的套用；重跑 `--init` 不是此錯誤的必要修復。
