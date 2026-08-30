# Shell 架構

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

本頁說明本 repo 中三層 shell 設定佈局、隨 `primaryShell` prompt 一同
落地的遷移過程，以及將同樣模型擴充到 fish / PowerShell 的可行性。

關於 bash 端的實務細節（init 順序、地雷、ble.sh + OMB 整合），請見
[`bash.md`](bash.md)。跨 shell 的 alias / function 清單請見
[`aliases.md`](aliases.md)。關於 POSIX 實際標準化了什麼（以及 bash/zsh
從哪裡開始不再可攜），請見 [`posix.md`](posix.md)。

## 三層架構 (The three tiers)

```
~/.config/shell/      — POSIX 可攜；由 zsh 與 bash 共同 source
  ├── 00_exports.sh.tmpl       PATH、EDITOR、XDG dirs、Homebrew shellenv、
  │                             GFW mirror env vars、GOPATH/BUN/PNPM_HOME
  ├── 01_starship.sh           starship init <shell>，依
  │                             $ZSH_VERSION / $BASH_VERSION 分派
  ├── 02_legacy_tools.sh       Go / Bun / pnpm / Foundry / NVM / .NET PATH
  ├── 05_mise.sh               mise activate <shell>
  ├── 08_pi_agents.sh.tmpl      在 mise/Bun PATH 初始化後重新前置
  │                             canonical Pi / OMP / pia 路徑
  ├── 10_aliases.sh            v=nvim、chezmoi-cd、gcam-amend、gundo、
  │                             glop、load-nvm、brew-mirror、ghostty-ssh-
  │                             terminfo、claude-plans-here、...
  ├── 10_fzf.sh                fzf shell 整合，--zsh / --bash 分派
  │                             + apt-fzf fallback 路徑
  ├── 20_zoxide.sh             zoxide init + cd→z alias
  ├── 27_thefuck.sh            thefuck（自動偵測 shell）
  └── 30_direnv.sh             direnv hook

~/.config/zsh/        — 僅 zsh（ZLE widgets、compdef、bindkey、setopt）
  ├── 10_aliases.zsh           現在只剩 `zsh-profile` alias（其餘已移到
  │                             shell/10_aliases.sh）。
  └── tools/
      ├── 02_shell_integration.zsh   透過 add-zsh-hook 註冊 OSC 133 markers
      ├── 04_ai_capture.zsh          aifix / aiexplain / aiblock
      ├── 05_aisuggest.zsh           Inline AI ghost-text (Alt+;) ZLE widget
      ├── 11_tools_picker.zsh        Alt+T tools picker
      ├── 12_television.zsh          Alt+R/P/G/E/A/I tv channel widgets
      ├── 22_sesh.zsh                Alt+S sesh-sessions widget
      └── ... (ZLE widgets、completions)

~/.config/bash/       — 僅 bash（bind -x / ble-bind、OMB plugin arrays、
                       bash 專屬 shopts）
  ├── 01_omb_plugins.bash      `plugins=(git sudo bashmarks)`、
  │                             `aliases=(general)`、`completions=(...)`。
  │                             在 OMB 之前 source。
  ├── 02_history.bash          HISTSIZE / HISTCONTROL / shopt
  ├── 03_completion.bash       bash-completion v2，動態解析 Homebrew prefix
  ├── 04_blesh.bash            bleopt 微調（在 ble-attach 之後 source）
  ├── 05_vi_mode.bash          set -o vi（ble.sh 自動偵測並升級）— 受 chezmoi `enableVimMode` 控制（預設 true；見 [vim-mode.md](../this_repo/vim-mode.md)）
  └── 10_aliases.bash          僅 bash 的 alias（bash-profile、reload）
```

`~/.zshrc` 與 `~/.bashrc` 都會先 source `~/.config/shell/`（透過
`load_modular_dir "$XDG_CONFIG_HOME/shell" sh`），然後才載入各自
shell 專屬的目錄。env vars / PATH / 簡單 alias 有單一真實來源；任何
非 POSIX 的東西則由各自 shell 的逃生口處理。

## 為什麼是三層而非兩層

較簡單的設計可能只用 `~/.config/zsh/` 與 `~/.config/bash/` 兩層，
讓兩邊各自重複 PATH exports、alias 定義、tool init 行、GFW mirror env
vars。我們沒這麼做，原因如下：

1. **漂移 (Drift)。** 在兩個檔案中的 alias / env vars 隨時間會逐漸
   分歧。共享層直接消除了約 600 LOC POSIX 內容的整個漂移面。
2. **工具 init wrappers。** `eval "$(starship init zsh)"` 與
   `eval "$(starship init bash)"` 只差一個 flag。一個會偵測 shell
   的 wrapper 多一個 `if` 即可；兩個並行檔案則是雙倍維護成本。
3. **未來新 shell。** 加入 fish / PowerShell 代表 env 層每多一個
   shell 就要重寫一次。如果 env 已經住在共享 POSIX 層，fish 只需
   要翻譯一次（因為 fish 不是 POSIX）；但若 env 原本就在 zsh/bash
   重複，fish 就會變成「第三棵」並行樹。詳見下方
   [未來 shell 擴充](#future-shell-extension)。

代價是紀律：放在 `dot_config/shell/` 的東西**必須**是 POSIX 可攜的。
不能用 `setopt`、`read -q`、`${var:t}`、glob qualifiers、zsh-vi-mode
hooks、`bind -x`。
[`CLAUDE.md` 的三層規則](../../CLAUDE.md#custom-aliases--shell-functions--docsshellsaliasesmd)
明文規範了這一點——撰寫新 helper 的 agent 必須先選對層級。

## 遷移說明（給既有 zsh 使用者）

`primaryShell` prompt 與 bash bootstrap 是分七個 commits 落地的：

1. `init: add primaryShell prompt for zsh/bash login-shell choice`
2. `ansible: gate zsh chsh on primaryShell + add bash role for chsh-to-bash`
3. `shell: extract POSIX layer to dot_config/shell/ for zsh/bash sharing`
4. `bash: ship dot_bashrc.tmpl + dot_bash_profile.tmpl + dot_config/bash/`
5. `bash: add oh-my-bash + ble.sh externals and plugin glue`
6. `docs: cross-file updates for primaryShell + bash bootstrap`
7. `bash: install gawk unconditionally — ble.sh Makefile hard-requires it`

對於先前是純 zsh 設定、由 `chezmoi apply` 管理的既有主機而言，拉取
這些 commits 後執行 `chezmoi apply` 將會：

- **將 7 個檔案搬移**出 `~/.config/zsh/` 進到 `~/.config/shell/`
  （00_exports、02_legacy_tools、01_starship、05_mise、20_zoxide、
  27_thefuck、30_direnv、10_fzf）。舊路徑列在
  [`.chezmoiremove`](../../.chezmoiremove) 中，所以 chezmoi 會在 apply
  時刪除孤兒檔案（否則新舊都會被 source，PATH 會重複）。
- **將 `~/.config/zsh/10_aliases.zsh` 精簡**到只剩 `zsh-profile`
  alias。其餘全部移到 `~/.config/shell/10_aliases.sh`。
- **部署 `~/.bashrc` + `~/.bash_profile`**，即使是 zsh-primary 主機
  也一樣。既有的系統 `~/.bashrc`（Ubuntu / Debian skel）會透過
  chezmoi 的 `backupMode`（預設為 `smart`）備份。Apply 完成後，
  若 `~/.bashrc.adhoc` 不存在會自動建立——對應於 `~/.zshrc.adhoc`。
  **既有的 `~/.bash_aliases` 會被保留**：新的 bashrc 在 step 11
  明確 source 它，所以使用者多年累積在那裡的 alias 仍會繼續運作。
- 只在尚未使用 zsh 時**執行 `chsh`** 切換到 zsh（預設
  `primaryShell=zsh`）。已經在 zsh 上的使用者不受影響。

Apply 後驗證：zsh `precmd_functions` 陣列逐字節相同，所有 PATH 條目
均保留，所有 hooks（starship/mise/direnv/zvm/omz/zsh-autosuggestions/
zsh-syntax-highlighting）皆完好。

## 系統 bashrc 中保留與替換的部分

Debian / Ubuntu 上的 `/etc/skel/.bashrc`：

| 區塊                                            | 處置        | 原因 |
| ---------------------------------------------- | ----------- | --- |
| `[[ $- != *i* ]] && return` 早退守衛           | 保留        | dot_bashrc.tmpl step 1 用相同模式 |
| `shopt -s checkwinsize histappend cmdhist`     | 保留        | 無害且實用（02_history.bash） |
| `shopt -s globstar`（skel 中註解掉）            | 啟用        | `**` 遞迴 glob，實用的預設 |
| `HISTSIZE=1000` / `HISTFILESIZE=2000`          | 替換        | 我們設定 10000/20000；OMB 之後再設為無上限 |
| `HISTCONTROL=ignoreboth`                       | 保留        | 標準合理預設 |
| `debian_chroot` PS1 片段                        | 替換        | prompt 由 starship 接管 |
| `ls --color=auto` / `grep --color=auto` aliases | 替換        | 由 eza / bat 接手 |
| `~/.bash_aliases` source                       | 保留        | dot_bashrc.tmpl step 11 |
| bash-completion v2 source                      | 保留        | dot_config/bash/03_completion.bash |

RHEL 系（CentOS / Rocky / Alma）的 `/etc/bashrc` 由 dot_bashrc.tmpl
的 step 2 明確 source，保留保護性的 `rm -i` / `cp -i` aliases、
Modules 系統的 init，以及該發行版的 umask 預設。RHEL 特有的
`~/.bashrc.d/*` 迴圈慣例（類似 Debian 的 `~/.bash_aliases`）也由
step 11 保留——使用者放進該目錄的東西仍會繼續運作。

RHEL 系 `/etc/skel/.bashrc` 內容比 Debian 少：

| 區塊                                                          | 處置         | 原因 |
| ------------------------------------------------------------- | ------------ | --- |
| `if [ -f /etc/bashrc ]; then . /etc/bashrc; fi`               | 保留         | dot_bashrc.tmpl step 2 |
| `PATH="$HOME/.local/bin:$HOME/bin:$PATH"`                     | 保留         | dot_config/shell/00_exports.sh.tmpl 內有相同 export |
| `for rc in ~/.bashrc.d/*; do . "$rc"; done`                   | 保留         | dot_bashrc.tmpl step 11 |
| （skel 中無 PS1、無 alias、無 shopts）                          | 不適用       | RHEL 把 prompt + alias 留給 /etc/bashrc 與使用者 dotfiles |

## 未來 shell 擴充 (Future shell extension)

`primaryShell` prompt 目前是 `["zsh", "bash"]`。擴充到 fish /
PowerShell 是可行的，但每個都有自己的成本。

### fish 3.x

**可行性：中等工作量，多半是機械式工作。**

- 工具 init wrappers：starship / zoxide / mise / direnv / atuin 全都
  有 `init fish`（或 `mise activate fish`）flag。一行小事。
- Env exports：fish 不使用 `export VAR=val` 語法，需要轉成
  `set -gx VAR val`。目前的 `00_exports.sh.tmpl` 大約 30 LOC 的
  機械轉換。
- Aliases：fish 語法是 `alias v 'nvim'`（注意空格與單引號）。約
  10 LOC 的轉換。
- Functions：fish 用 `function name; ...; end`。目前的
  `~/.config/shell/10_aliases.sh` 有 8 個 function。每個都需要
  重寫成 fish 版本。有些（`gundo`、`gcam-amend`）很簡單；有些
  （`claude-plans-here`、`ghostty-ssh-terminfo`）則相當有份量。
- Plugin manager：oh-my-fish (OMF) 是常見選擇。和 OMZ/OMB git
  alias 的對等程度約 80%——已經夠接近。
- vi-mode：fish 內建 `fish_vi_key_bindings`（比 zsh-vi-mode 與
  ble.sh 的都好）。需要連接的事更少。
- Autosuggestions / syntax highlighting：fish 內建這兩者。不需要
  ble.sh 等價的相依。

共享 POSIX 層無法被 fish source（語法不同），所以 fish 需要一棵
平行的 `dot_config/fish/conf.d/` 樹。建議：

```
~/.config/fish/conf.d/
  ├── 00_exports.fish        從 shell/00_exports.sh.tmpl 翻譯而來
  ├── 01_starship.fish       starship init fish | source
  ├── 10_aliases.fish        從 shell/10_aliases.sh 翻譯而來
  ├── 20_zoxide.fish         zoxide init fish | source
  └── ...
```

預估：約 400 LOC 的翻譯 + 一個 fish ansible role（chsh 邏輯與 bash
role 相同）+ 一個新的 prompt 值。大概是一個專注下午的工作量。
目前在 [`TODO.md`](../../TODO.md) 中標為 `[P3/L]`。

### PowerShell Core 7+ (`pwsh`)

**可行性：較高工作量，相異程度更大。**

- Profile 位置：在 Linux/macOS 上是
  `~/.config/powershell/Microsoft.PowerShell_profile.ps1`；和 bash/zsh
  的 `.rc` 模型差異很大。
- 工具 init：starship / zoxide / mise 都有 `init powershell` flag
  （mise 用 `mise activate pwsh`）。atuin 透過社群 plugin 支援 pwsh。
  fzf 需要 PSFzf module。
- Env exports：`$env:VAR = "value"`（沒有 `export`）。
- Aliases：`Set-Alias v nvim`（不是 shell function 風格；pwsh alias
  不能接受參數——若需要參數則改寫成 function）。
- Functions：完全不同的語法（`function Verb-Noun
  { param([string]$Name) ... }`）。
- vi-mode：PSReadLine 提供（`Set-PSReadLineOption -EditMode Vi`）。
- Autosuggest / syntax highlight：PSReadLine 兩者都有（相當於
  ble.sh）。
- Plugin 生態：oh-my-posh 是常見的 prompt（支援 bash / zsh / pwsh
  ——與 starship 競爭），但 pwsh 專屬的 plugin 住在 PowerShell
  Gallery（`Install-Module`）。

共享 POSIX 層完全無法重用。PowerShell pipelines 是物件流而非文字
流；alias / function 需要根本不同的心智模型。

預估：約 1-2 天可做出鏡射 bash UX 的可用 profile（starship + zoxide
+ PSReadLine vi-mode + 一小組 alias），加上一個新的 ansible role
來安裝 pwsh（Ubuntu 上的 apt deb、macOS 上的 brew cask、若我們將
來支援 Windows 則用 scoop）。目前在 [`TODO.md`](../../TODO.md) 中
標為 `[P?/L]`。

### nushell、elvish、xonsh

比 fish 更為相異（nushell 是結構化資料優先；elvish 有自己的
scripting 語言；xonsh 是 Python 優先）。在可預見的未來都不在範圍內。
若使用者選用其中之一，他們應將 `primaryShell=zsh`（或 `bash`）作為
chsh 管理的登入 shell，並從 `~/.zshrc.adhoc` 或透過 wrapper 終端機
profile 啟動其替代 shell。

## 為什麼我們沒有先做 fish / PowerShell

三個原因（依優先順序）：

1. **Bash 是普世的**：每個 Linux 發行版與 macOS 都附帶。加入 bash
   帶來「對於難以安裝 zsh 的主機（鎖定的企業環境、最小化容器、
   recovery shell）有更好的支援」，這正是當初提出的需求。
2. **POSIX 共享層回報豐厚**：約 600 LOC 的 zsh 程式碼變成約 600 LOC
   與 bash 共享的 POSIX 程式碼。fish / PowerShell 版本各自會是第三
   棵 / 第四棵類似規模的樹。bash 進來之後，邊際效益遞減。
3. **沒有具體使用者訊號**：目前還沒人要求 fish 或 PowerShell。我們
   把它們加到 backlog，分別標為 `[P3/L]` 和 `[P?/L]`；等到第一個
   具體需求出現再實作。

## 延伸閱讀

- [`bash.md`](bash.md)——bash 端實務指南（init 順序、地雷、
  純 bash fallback）
- [`aliases.md`](aliases.md)——三層的 alias / function 清單
- [`CLAUDE.md` → "primaryShell choice gates chsh only"](../../CLAUDE.md#primaryshell-choice-gates-chsh-only--both-shells-always-deploy)
  ——agent 新增 shell helper 時的硬性不變式
- [`TODO.md`](../../TODO.md)——延後處理的 bash UX 缺口（aisuggest /
  tv / sesh ZLE → ble-bind ports）以及未來 shell 項目
