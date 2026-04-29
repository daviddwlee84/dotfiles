# direnv

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

`direnv` 會在你進入或離開目錄時，依專案載入對應的環境變數
(environment variable)。在這個 repo 裡它從 Zsh 初始化，提示符 (prompt) 顯示則交給 Starship 處理。

- **Helper 檔案**：`~/.config/direnv/direnvrc`（chezmoi source：`dot_config/direnv/direnvrc`）
- **Zsh 初始化**：`~/.config/zsh/tools/30_direnv.zsh`
- **Prompt**：`~/.config/starship.toml`，透過 Starship 的 `[python]` 模組

## Python `.venv` helper

這個 repo 提供 `layout_python_venv [venv_dir=.venv]`。

- 啟用一個既有的 virtual environment 目錄
- 不會自動建立 `.venv`
- 將啟用動作委派給 `layout python3`
- 監看 venv marker 檔，因此之後建立 `.venv` 時，下一次 prompt 會觸發重新載入

## 建議的 `.envrc`

```sh
layout_python_venv
dotenv_if_exists
```

接著在每個專案 allow 一次：

```bash
direnv allow
```

需要的話可以指定非預設的 virtual environment 目錄：

```sh
layout_python_venv venv
dotenv_if_exists
```

## 行為備註

- 日常使用上等價：`VIRTUAL_ENV`、`PATH`、與 `PYTHONHOME` 的處理由 direnv 內建的 `layout python3` 提供
- 不完全等同於 `source .venv/bin/activate`：沒有 `deactivate()` shell 函式，也不會直接改寫 `PS1`
- Prompt 顯示仍可運作，因為 Starship 會讀取 `VIRTUAL_ENV` 並顯示啟用中的環境名稱
- 離開該目錄時會自動還原先前的環境

## 參考資料

- [Python · direnv Wiki](https://github.com/direnv/direnv/wiki/Python)
- [Activate python venv by default? · Issue #1264](https://github.com/direnv/direnv/issues/1264)
- [PS1 · direnv Wiki](https://github.com/direnv/direnv/wiki/PS1)
