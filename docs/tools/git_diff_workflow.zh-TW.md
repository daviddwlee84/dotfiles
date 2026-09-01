# Git Diff 工作流程

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

本倉庫管理一組精簡的 Git 審閱 (review) 堆疊，而不是強迫單一工具承擔所有職責：

- `delta` 是一般 `git diff`、`git show` 與其他 CLI 差異輸出的預設分頁器 (pager)。
- `diffnav` 是類似 GitHub 風格的差異導覽器 (diff navigator)，附帶檔案樹 (file tree)，當你需要在較大的 patch 之間快速移動時很有用。
- `gh-dash` 是 GitHub 儀表板 (dashboard) 與審閱介面，其差異分頁器設定為呼叫 `diffnav`。
- `lazygit` 在 LazyVim 中專注於倉庫 (repo) 操作，並把 `delta` 設為其 custom pager。

## 受管理的設定檔

此工作流程透過下列檔案進行全域管理：

- `~/.gitconfig` 將 `delta` 設為預設的 Git 分頁器。
- `~/.config/gh-dash/config.yml` 設定 `pager.diff: "diffnav"`。
- `~/.config/lazygit/config.yml` 使用 LazyGit 目前的 `git.diffRenderers` 語法搭配 `delta`，設定 `os.copyToClipboardCmd` 讓 `Ctrl+O` 透過 `x` 包裝複製（本機用 `wl-copy`/`xclip`，SSH 走 OSC 52 — 見 [clipboard.md](clipboard.md)），並提供 [lazygit](lazygit.zh-TW.md) 所述的唯讀 `I` local/remote-main containment 報告。
- `~/.config/bat/themes/tokyonight_night.tmTheme` 提供 `bat` 預覽 (preview) 共用的 Tokyo Night 主題。

## 為什麼同時使用 `delta` 和 `diffnav`

`delta` 仍然是日常 Git CLI 輸出的最佳預設選擇。它快速、易讀，且已經很適合 `git diff` 與 LazyGit。

`diffnav` 解決的是不同的問題：以檔案樹和類 GitHub 版面導覽大型審閱差異。這讓它比起在所有地方取代 `delta`，更適合用在 `gh-dash` 上。

## `gh-dash` + `diffnav`

`gh-dash` 安裝為 `gh` 的擴充套件 (extension)，並讀取位於 `~/.config/gh-dash/config.yml` 的全域設定。本倉庫刻意讓該設定保持精簡：

```yaml
pager:
  diff: "diffnav"
```

這讓 `gh-dash` 擁有更好的差異檢視器，同時不會從其他 dotfiles 匯入個人化的章節、顏色或鍵位綁定 (keybinding)。

使用 `gh-dash` 之前，先用 GitHub CLI 認證 (authenticate) 一次：

```bash
gh auth login
gh dash
```

## LazyGit + `delta`

自 v0.64 起，LazyGit 的 diff renderer 設定使用 `git.diffRenderers` 與
`command`。舊的 `git.pagers` 與 `pager` 欄位會觸發自動遷移，並在啟動時
重寫設定檔：

```yaml
git:
  diffRenderers:
    - colorArg: always
      command: delta --dark --paging=never --syntax-theme base16-256 -s
```

這使 LazyGit 與既有的「`delta` 優先」CLI 設定保持一致，也避免遷移結果與
chezmoi 管理的檔案形成 drift。

## 字型與主題

`diffnav` 與 `gh-dash` 在搭配 Nerd Font 時外觀更佳，因為它們的介面仰賴圖示字符 (icon glyph)。本倉庫已在桌面 profile 上管理 Hack Nerd Font。

`bat` 的 Tokyo Night 警告（`[bat warning]: Unknown theme 'tokyonight_night', using default.`，每次 `delta` 繪製時都會印出一行），透過直接管理上游的 `tokyonight_night.tmTheme` 檔案、並在 apply 後把它編譯進 bat 快取 (cache) 來修正。

bat 執行期並不讀取 `.tmTheme`，只讀 `~/.cache/bat` 底下由 `bat cache --build` 產生的 bincode 快取。該快取位於 chezmoi 管轄範圍之外，因此 `.chezmoiscripts/global/run_after_25_bat_theme.sh.tmpl` 會在**每次** apply 都重新檢查（快取存在嗎？是目前這個 bat 版本寫的嗎？比主題原始檔新嗎？），只有過期時才重建。對應地，`dot_config/shell/25_bat.sh` 只在編譯後的快取確實存在時才 export `BAT_THEME`，所以沒有快取的機器會靜默退回 bat 內建預設主題，而不是每一行都跳警告。詳見 [`pitfalls/bat-theme-cache-cleared-never-rebuilt.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/bat-theme-cache-cleared-never-rebuilt.md)。

## 參考資料

- [diffnav](https://github.com/dlvhdr/diffnav)
- [gh-dash docs](https://www.gh-dash.dev/getting-started/)
- [LazyGit custom diff renderers](https://github.com/jesseduffield/lazygit/blob/master/docs/Custom_DiffRenderers.md)
- [bat](https://github.com/sharkdp/bat)
