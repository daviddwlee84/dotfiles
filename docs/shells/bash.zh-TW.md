# Bash 啟動設定

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

Bash 被支援作為 zsh 之外的另一個主要登入 shell (login shell) 選項。
此選擇於 `chezmoi init` 階段透過 `primaryShell` 提示決定（預設為
`zsh`），且僅用於決定 `chsh` 切換到哪一個 shell——`~/.zshrc` 與
`~/.bashrc` 在每台主機上都會並行佈署，因此臨時開啟的 `bash`（或
`zsh`）連線仍會載入相同的環境變數與提示字元 (prompt)。

bash 端的目標是達到與 zsh 的 **使用者體驗對等 (UX parity)**，作法是堆疊
[oh-my-bash](https://github.com/ohmybash/oh-my-bash)（提供熟悉的
plugin 與 git 別名）以及 [ble.sh](https://github.com/akinomyoga/ble.sh)
（提供自動建議 (autosuggestions)、語法高亮 (syntax highlighting)、進階
vi-mode）。兩者皆透過 `.chezmoiexternal.toml.tmpl` 以 git clone 方式
管理；ble.sh 的執行時期產物由
`.chezmoiscripts/global/run_onchange_after_26_install_blesh.sh.tmpl` 編譯。

## 選擇 bash 作為主要 shell

```bash
chezmoi init https://github.com/daviddwlee84/dotfiles.git --apply
# 回答：Primary interactive shell (zsh|bash) → bash
```

或用於 Docker 測試建置：

```bash
docker build --build-arg CHEZMOI_PRIMARY_SHELL=bash -t dotfiles-bash .
docker run -it dotfiles-bash
```

要將既有主機切換過來：

```bash
chezmoi init                        # 重新提示並編輯 ~/.config/chezmoi/chezmoi.toml
# （或手動編輯該檔：primaryShell = "bash"）
chezmoi apply                       # ansible bash role 接手執行 chsh
```

## 在 bash 上你會得到什麼

| 功能                                    | Bash 端                                | Zsh 端                              |
| --------------------------------------- | -------------------------------------- | ----------------------------------- |
| starship 提示字元                       | ✓（共用 `dot_config/shell/01_starship.sh`） | ✓ |
| 共用 env / PATH / GFW 鏡像              | ✓（`dot_config/shell/00_exports.sh.tmpl`）  | ✓ |
| zoxide / mise / direnv / thefuck        | ✓                                      | ✓ |
| fzf shell 整合                          | ✓（`fzf --bash`）                       | ✓（`fzf --zsh`） |
| atuin 歷史                              | ✓（搭配 `--disable-up-arrow`）          | ✓ |
| oh-my-bash `git` plugin（gst/ga/...）   | ✓                                      | ✓ 透過 OMZ git plugin |
| 自動建議（ghost text）                  | ✓ 透過 ble.sh                           | ✓ 透過 zsh-autosuggestions |
| 語法高亮（即時）                        | ✓ 透過 ble.sh                           | ✓ 透過 zsh-syntax-highlighting |
| Vi-mode                                 | ✓ readline + ble.sh*                   | ✓ zsh-vi-mode* |
| `aisuggest` widget（Alt+;）             | ⚠ 僅 CLI 形式；widget 移植延後          | ✓ |
| tmux capture / AI capture 函式          | ⚠ 子集（CLI 形式），無 ZLE widget       | ✓ |
| Television channel widgets（Alt+R/P/G/E/A/I） | ✗（僅 CLI `tv <channel>`）        | ✓ |
| `tools-picker`（Alt+T）                 | ✗（僅 CLI `tools-picker`）              | ✓ |
| `sesh-sessions`（Alt+S）                | ⚠ 僅 CLI `sesh-connect`                 | ✓ |
| OSC 133 shell-integration markers       | ✗（延後）                               | ✓ |

延後欄位中僅 zsh 才有的項目，皆已於 `TODO.md` 中以 `[P3]` 追蹤；
ble.sh 的 `ble-bind` API 多數能承載這些功能，但每一項都需各自移植。

\* Vi-mode（兩欄）受 chezmoi `enableVimMode` prompt 控制（預設
`true`）。設為 `false` 時，bash 的 `set -o vi` 會替換為 no-op、
ble.sh 的 vi_imap/vi_nmap 綁定改用預設（emacs）keymap、
zsh-vi-mode 不再載入。完整清單見 [`docs/this_repo/vim-mode.md`](../this_repo/vim-mode.md)。

## 初始化順序（具關鍵相依性）

`dot_bashrc.tmpl` 的 12 步驟初始化流程已記錄於檔案開頭的註解中。
關鍵不變條件：

1. **ble.sh 必須以 `--attach=none` 在 bash-preexec 之前載入。** Starship
   會內部安裝 bash-preexec；若 ble.sh 在它之後載入，ble.sh 自身的
   preexec 堆疊會壞掉。參考：
   [ble.sh wiki § A1 Initialization](https://github.com/akinomyoga/ble.sh/wiki/Manual-§A1-Initialization)。
2. **`ble-attach` 必須在最末端執行**——在 starship、atuin、OMB 以及
   各模組層全部註冊完 precmd / preexec hook 之後。如此 ble.sh 才能
   乾淨地接管整個堆疊。
3. **`atuin init bash --disable-up-arrow`**——ble.sh 擁有上方向鍵的
   歷史導覽控制權。若不加此 flag，atuin 的 TUI 會搶走上方向鍵，
   ble.sh 的歷史走訪就壞了。`Ctrl+R` 仍會開啟 atuin 的 TUI（不衝突）。
4. **`OSH_THEME=""`**——starship 擁有 prompt。OMB 內建主題會與 starship
   競爭並產生雙重 prompt。
5. **OMB plugins 必須排除 `autosuggestions`、`syntax-highlighting`、
   `history-substring-search`**——ble.sh 提供更佳的原生版本；雙重初始化
   會導致閃爍與重複補完。這些排除設定編碼於
   `dot_config/bash/01_omb_plugins.bash`。

## 與系統內建 bashrc / bash_profile 的衝突處理

我們**不**保留 `/etc/skel/.bashrc` 中的這些項目：

- `debian_chroot` 的 PS1 片段 / `PS1='\u@\h:\w\$'`——由 starship 取代。
- `HISTSIZE=1000` / `HISTFILESIZE=2000`——我們設為 10000 / 20000。
- 透過 `dircolors` 設定的彩色 `ls` / `grep` 別名——我們改用 eza / bat。

我們**會**保留以下項目（刻意為之，位於 `dot_config/bash/02_history.bash`）：

- `shopt -s checkwinsize`（每個指令後更新 LINES/COLUMNS）。
- `shopt -s globstar`（`**` 遞迴 glob）。
- `shopt -s histappend cmdhist`（多 shell 歷史同步）。
- `[[ $- != *i* ]] && return` 對非互動式 shell 的早退守門
  （位於 `dot_bashrc.tmpl` 第 1 步）。

在 RHEL 系列上（`/etc/bashrc` 內含 `rm -i` 別名 + Modules system 初始化
+ 防護性 umask），我們會在第 2 步明確 source 它。Debian / Ubuntu
沒有 `/etc/bashrc`，因此該 source 在那邊是 no-op。

## macOS 安裝 bash 5.x

macOS 系統內建的 bash 為 3.2.57（GPLv3 授權考量）。oh-my-bash plugins
需要 bash 4.4+，而 ble.sh 需要 bash 4.0+。bash ansible role 會偵測
`os_family == "Darwin" && primary_shell == "bash"` 並執行：

1. `brew install bash`（5.x current）。
2. 將 `/opt/homebrew/bin/bash` 附加到 `/etc/shells`（具冪等的 grep
   守門）以讓 `chsh` 接受該路徑。
3. `chsh -s /opt/homebrew/bin/bash`。

zsh 為主的 mac 使用者**完全不會**碰到上述流程：不會多裝 brew formula、
不會編輯 `/etc/shells`、不會執行 `chsh`。此 gate 是刻意設計——
只有在明確選擇 bash 時才需要它。

## 純 bash 後備方案（無 ble.sh / 無 OMB）

`dot_bashrc.tmpl` 對每個 ble.sh 與 OMB 區塊都做了存在性 (presence) 守門：

```bash
[ -r "$HOME/.local/share/blesh/ble.sh" ] && source ble.sh --attach=none
...
[ -r "$HOME/.oh-my-bash/oh-my-bash.sh" ] && source $OSH/oh-my-bash.sh
...
[[ -n $BLE_VERSION ]] && ble-attach
```

因此當外部相依尚未 clone 完成、ble.sh 的 `make install` 失敗、或使用者
手動刪除了 `~/.local/share/blesh/` 的主機，仍會獲得可運作的 starship
prompt + 共用層 + bash-completion v2 + bash 專屬設定。
`run_onchange_after_26_install_blesh.sh.tmpl` 也會優雅地處理「未安裝
make」的情境（警告並 exit 0，而不是讓整個 chezmoi apply 失敗）。

## 已知陷阱

- **第三方 `bash-preexec` 安裝在 `~/.bash-preexec.sh` 並先於 ble.sh
  載入，會破壞 ble.sh 的 preexec 堆疊。** 我們不安裝它；若使用者透過
  其他途徑放入了它，症狀為 starship 的 `cmd_duration` 不更新，以及
  ble.sh 綁定的 preexec hook 不觸發。修復：移除 `~/.bash-preexec.sh`。
- **`atuin` 未加 `--disable-up-arrow`** 會在上方向鍵蓋掉 ble.sh 的歷史
  走訪。bashrc 會自動帶入此 flag，但若你在 `~/.bashrc.adhoc` 裡手動
  加了 `eval "$(atuin init bash)"` 而未帶 flag，就會看到此症狀。
  修復：移除手動 init 或補上 flag。
- **`~/.inputrc` 中自訂的 `bind -x` 呼叫，在 ble.sh attach 之後會被
  ble-bind 蓋過。** 請改以 `ble-bind -m default_keymap -f ...` 在
  `~/.bashrc.adhoc` 中（在 `ble-attach` 之後 source）記錄自訂鍵繫結。
- **macOS Terminal.app 以 login shell 啟動 bash** 但不會 source
  `~/.bashrc`。`dot_bash_profile.tmpl` 處理了這點：在最後 source
  `~/.bashrc`。如果你跳過了 `chezmoi apply` 或手動移除了
  `~/.bash_profile`，login shell 會落入沒有 starship 的裸 bash。
- **`set -v`（verbose 模式）會把 ble.sh 內部 eval wrapper 洩漏到每個
  prompt。** 你會看到 `{ _ble_edit_exec_gexec__save_lastarg "$@"; } 4>&1
  5>&2 &>/dev/null` 在每個命令後印出，且你輸入的命令被印兩次。觸發點
  通常是貼上/source 一段腳本啟用了 `set -v` 但沒搭配 `set +v` 復原。
  快速修法：執行 `set +v`（不需開新 terminal）。完整診斷見
  [`pitfalls/blesh-set-v-leaks-gexec-wrapper.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/blesh-set-v-leaks-gexec-wrapper.md)。

## Adhoc 收尾檔（`~/.bashrc.adhoc`）

為 `~/.zshrc.adhoc` 的姊妹檔。首次 apply 時自動建立，git ignore
（於 `.chezmoiignore.tmpl` 中標記為 `.bashrc.adhoc`），並在
`dot_bashrc.tmpl` 的最末端、**`ble-attach` 之後** source，
因此其中的 `ble-bind` 呼叫能生效。

可用於：

- 機器特定的 PATH 增補
- 快速試驗新的別名 / 函式
- 自訂 ble.sh 鍵繫結（`ble-bind -x ...`）
- 各主機專屬的 `bleopt` 覆寫（例如於慢速遠端機器上以
  `bleopt complete_auto_complete=` 關閉自動建議）

## 相關文件

- [docs/shells/architecture.md](architecture.md)——3 層 shell 佈局
  的設計理由（`dot_config/shell/` vs `dot_config/zsh/` vs
  `dot_config/bash/`）、既有 zsh 使用者的遷移敘事、未來 shell
  擴充可行性（fish、PowerShell）。
- [docs/shells/aliases.md](aliases.md)——共用別名 / 函式清單
  （列出每項在哪些 shell 中可用）。
- [docs/shells/history.md](history.md)——bash/zsh 原生歷史檔、
  環境變數（`HISTSIZE`、`HISTFILESIZE`、`HISTCONTROL`）、`shopt`、
  ble.sh 互動、伺服器上多使用者稽核、atuin 的定位。
- [docs/zsh/motd.md](../zsh/motd.md)——SSH 登入橫幅樣式
  （figlet / fastfetch-slim / fastfetch-full）；於兩個 shell 之間共用。
