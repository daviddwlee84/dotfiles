# 套用到新機器

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

> 將設定套用到新機器 (Ubuntu)。

安裝應用程式等。

套用：

```bash
chezmoi init git@github.com:$GITHUB_USERNAME/dotfiles.git

# 如果你使用 GitHub 且 dotfiles 倉庫名為 dotfiles，可以縮寫為：
chezmoi init --apply $GITHUB_USERNAME

# --apply 會直接套用到主機
```

每台 UNIX-based 機器都使用 Homebrew？！
<https://www.chezmoi.io/user-guide/use-scripts-to-perform-actions/>

同步 mac
<https://www.chezmoi.io/user-guide/machines/macos/>

```bash
# Ubuntu
# https://www.chezmoi.io/install/#__tabbed_5_5
sudo snap install chezmoi --classic
```
