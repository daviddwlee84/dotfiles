# btop

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

[btop](https://github.com/aristocratos/btop) 是一個資源監控器 (resource monitor)（CPU / 記憶體 / 網路 / 行程 / 磁碟）——bashtop 與 bpytop 的 C++ 後繼者。它在啟動時從 `~/.config/btop/` 讀取設定與主題 (theme)。

## 受管理的設定檔

本 repo 透過 `dot_config/btop/create_btop.conf.tmpl` 種下 (seed) `~/.config/btop/btop.conf`，並在 `~/.config/btop/themes/catppuccin_mocha.theme` 內附 (vendor) 一份 Catppuccin Mocha 主題。

baseline 只在 btop 的原廠設定之上覆寫少數幾個 key（讓你貼近上游、並保留自己的 `presets` / `shown_boxes`）：

| Key | 值 | 為什麼 |
|---|---|---|
| `color_theme` | `"catppuccin_mocha"` | 對齊本 repo 的 Catppuccin Mocha 標準（tmux 等）。需要內附的主題檔——見 [主題](#主題)。 |
| `proc_tree` | `True` | 以樹狀 (tree) 顯示行程——更容易看出是誰生出了 `python` / `uv` / `claude` / tmux / pueue worker。 |
| `vim_keys` | `{{ if .enableVimMode }}…{{ end }}` | `h,j,k,l,g,G` 清單導覽，受 repo 的 `enableVimMode` prompt 控制（見 [Vim 整合](../this_repo/vim-mode.md)）。 |

從 seed 保留下來的：`update_ms = 2000`、`proc_sorting = "cpu lazy"`、`presets`、`shown_boxes = "cpu mem net proc"`、`theme_background = True`。

### 為何用 seed-once (`create_`)，以及如何更新

btop **每次離開時都會重寫 `btop.conf`**（把當前整份設定序列化寫回）。若這個檔案被完全管理，每次退出都會讓它與 source 產生漂移 (drift)，`chezmoi apply` 就會跟 btop 互相打架。所以這裡使用 chezmoi 的 `create_` prefix：**在新機器上只種一次，之後就不再碰它**。之後檔案由 btop 擁有 → 零 apply 漂移。（與 `dot_config/nvim/create_lazy-lock.json`、`dot_config/marimo/create_marimo.toml.tmpl` 相同模式；見 [chezmoi prefixes](chezmoi-prefixes.md)。）

後果：

- 在**已經**有 `~/.config/btop/btop.conf` 的機器上，chezmoi **不會**覆蓋它。若要在這種機器上採用此 baseline，刪除一次再重新 apply：

  ```bash
  rm ~/.config/btop/btop.conf
  chezmoi apply
  ```

- 若要從調整過的實際設定**更新 repo 的 baseline**，`chezmoi add`（會剝掉 `create_`）與 `chezmoi re-add`（會跳過 `create_`）都不適用。改為把實際檔案複製進 source path，必要時再重新套用被 btop 重置掉的 templated 覆寫：

  ```bash
  cp ~/.config/btop/btop.conf "$(chezmoi source-path ~/.config/btop/btop.conf)"
  ```

## 主題

`color_theme = "catppuccin_mocha"` 需要 `~/.config/btop/themes/catppuccin_mocha.theme` 存在——**若檔案缺失，btop 會無聲地退回 `Default` 主題、不報任何錯**。這就是為什麼主題被內附在 repo 中（比照 `dot_config/bat/themes/`），而非執行期下載。與 bat 不同，btop 在啟動時直接讀取 `.theme` 檔——**沒有 cache 需要重建**，所以這裡刻意不設 `run_onchange` hook。

要換 flavor，把另一份 catppuccin 主題（`catppuccin_latte` / `_frappe` / `_macchiato`）丟進 `dot_config/btop/themes/`，並把 `color_theme` 指向它即可。

## 陷阱 (gotchas)

- **沒有 `proc_cmdline` 這個 key。** btop 沒有「在清單中永遠顯示完整命令列」的設定開關——`proc_cmdline` 在 1.3.x 或 1.4.x 都不存在（別相信 AI 自創出這個 key）。完整命令列會顯示在**行程詳情檢視 (process detail view)**（選取一個行程後按 `Enter`），或設定 `proc_sorting = "arguments"`。樹狀檢視（`proc_tree = True`）本身已顯示命令的層級。
- **布林值是 Python 風格的 `True` / `False`**（首字大寫）；字串值保留引號（`proc_sorting = "cpu lazy"`）。手動編輯時請比照 btop 的序列化格式。

## 安裝——以及 snap 陷阱

在 Linux 上，本 repo 透過 **apt** 安裝 btop（`dot_ansible/roles/devtools/tasks/main.yml`），並為 no-root / CentOS 主機準備 GitHub musl 靜態二進位 fallback；macOS 用 Homebrew。本 repo 從不安裝 snap 版本。

> **若 btop 一啟動就以 `Permission denied` + `IOT instruction (core dumped)` 崩潰**，你幾乎可以確定是在跑 **snap** 版的 btop。它受 AppArmor 限制 (confinement)，無法讀取你的 `~/.config/btop/themes`（snap 的 `home` interface 封鎖隱藏目錄），於是 `std::filesystem::directory_iterator` 丟出例外並 abort。目錄權限是**紅鯡魚 (red herring)**——`chown`/`chmod` 沒有用。移除或在 `PATH` 上蓋掉 snap，讓 apt / brew / `~/.local/bin` 的 btop 勝出：
>
> ```bash
> sudo snap remove btop        # 之後 /usr/bin/btop (apt) 接手
> # —— 或者，想透過套件管理器拿到最新版：
> brew install btop            # linuxbrew btop 在 PATH 勝出；無 confinement
> ```
>
> 完整記錄：[`pitfalls/btop-themes-permission-denied-core-dumped.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/btop-themes-permission-denied-core-dumped.md)。

## 另見

- [Vim 整合](../this_repo/vim-mode.md)——驅動 `vim_keys` 的 `enableVimMode` flag。
- [chezmoi prefixes](chezmoi-prefixes.md)——`create_` seed-once 語意與更新流程。
