# iOS 終端機（iSH、a-Shell、SSH client）

這個 repo 能不能跑在 iOS 上（不能）、什麼能跑，以及 iPad 該怎麼用才有價值。

**一句話**：iOS 無法執行任何 agentic coding CLI，而且那是結構性的，不是等誰補上的缺口。把 iSH 留作筆記同步的專用工具，終端工作交給 SSH client，agent 則用 `claude --remote-control` 從一台有真正作業系統的機器驅動。

## 判定

| 目標 | 在 iOS 上 |
|---|---|
| 用這個 repo 跑 `chezmoi apply` | ❌ 在寫下第一個檔案前就中止 |
| 本機跑 Claude Code / Codex / OpenCode | ❌ 結構性不可能 |
| `git` + SSH + 本機 Unix filesystem | ✅ iSH 今天就做得到 |
| Neovim / LazyVim | ⚠️ 開得起來；沒有 LSP、沒有 ripgrep、treesitter 要現場編譯 |
| 驅動跑在別處的 agent | ✅ `claude --remote-control` + Claude iOS app |

## 為什麼 agent CLI 跑不了 —— 三道各自獨立的牆

任何一道單獨存在都足以致命。而三道同時成立。

**1. iOS 禁止對任意 binary 做 `fork`/`exec`。** nodejs-mobile 官方文件載明 `child_process` 與 `cluster` 在 iOS 上不可用。所有 agent CLI 都透過 Bash tool 驅動工作，所以就算裝置上有一份完美的 ARM64 Node 也沒用。這是最關鍵的一道，而且它適用於**每一個** iOS app，不只 iSH。

**2. App Review Guideline 2.5.2** 禁止 app「download, install, or execute code」。該條款帶有 Notarization 標記，因此連 EU 與日本的 alternative marketplace 也受其約束。UTM 在 2024 年 6 月就是被這條擋下 —— 而且擋的是**沒有 JIT** 的版本。

**3. Claude Code 已經不再是 JavaScript。** `@anthropic-ai/claude-code@2.1.220` 的 tarball 只有約 23 KB；真正的 CLI 透過 `optionalDependencies` 以各平台原生 binary 分發，沒有 iOS slice。2.1.112（於 2026-04-17 被取代）是最後一個含 JS bundle 的版本。Codex 是 Rust binary 的 shim；Gemini CLI 要求 Node >= 20。

Apple 並未放寬 JIT。唯一的 JIT entitlement 是 BrowserEngineKit 的 `com.apple.developer.web-browser-engine.*`，僅限 Apple 核可、且只在 EU 發行的 alternative browser engine（日本自 iOS 26.2 起比照）。emulator、runtime 或 shell 這個類別根本沒有申請管道。iOS 26 與 iPadOS 26 在這件事上毫無改變；iPadOS 27 的 release note 完全沒提 JIT、virtualization 或 container。

### iSH 自身的限制是真的，但屬於次要

iSH 是 32 位元 x86（i686）+ musl 的 threaded-code interpreter。Node 在上面會以 `Illegal instruction` 死掉 —— 但要注意**機制**，因為它比指令集本身更有預測力：

iSH 的 CPUID **確實**回報 `fpu|cmov|mmx|sse2`。SIGILL 來自 `asbestos/gen.c` 裡未實作的 gadget slot 與 `emu/decode.h` 的 31 個 `UNDEFINED` 點。一個完全合法、落在宣告 baseline 之內的指令，只要對應的 host gadget 是 NULL，照樣 trap。`LOOP`（0xE0–0xE2，1978 年的指令）到 build 812 都還沒實作。

**後果**：你不能用「這個工具只用到 SSE2，所以安全」來推論。要實測，不要預測。Rust 的 `i686` target 預設假設 SSE2，所以 `ripgrep` 這類工具同樣中招。

## 這個 repo 有多少能存活

### 可移植 —— 純 config，無 binary 依賴

shell layer 比預期乾淨。四個 entrypoint（`dot_zshrc.tmpl`、`dot_bashrc.tmpl`、`dot_zshenv.tmpl`、`dot_bash_profile.tmpl`）對外部 binary **零硬性需求** —— oh-my-zsh、ble.sh、starship、atuin、zoxide、mise、direnv、fzf、tv、sesh、yazi、eza、bat、delta 與 nvim 全部由 `command -v` 或 `[ -r ]` 做存在性 gate。裸 Alpine 機器載入它們不會噴出任何一個錯誤。

同樣可移植的還有：`dot_ssh/`（純文字，`Include config.d/*`）、`.chezmoiexternal.toml.tmpl`（全是 `git-repo`，與架構無關）、`modify_` overlay（POSIX sh，jq/python3 缺席時原樣 passthrough），以及 `dot_config/shell/04_ai_agents.sh`。

**但問題不在正確性，在成本。** 互動式 zsh 會 source 約 110 個檔案。在原生 Apple Silicon 上實測：`zsh -i -c exit` 需 1.89–2.12 秒，其中 907 ms 屬於模組層，83% 集中在九個會 fork 外部 binary 的檔案。在 iSH 底下這是每開一個 shell 好幾分鐘。**不要**把 shell layer 部署到這裡。

### i686-musl 上沒有的東西

`mise`（上游無 32 位元建置）、`starship` / `ripgrep` / `eza` / `atuin` / `fzf`（完全沒有 32 位元 Linux release asset），以及所有 tokio-based 的 Rust 工具（`available_parallelism()` 回 0 → 除以零 panic；`uv` 會 segfault，astral-sh/uv#2732 已 closed as not-planned）。Go binary 會踩到 iSH 有記錄的鎖死問題（ish-app/ish#1230）—— 而 `chezmoi` 本身就是 Go。

`fleet` 無法**從** iSH 執行：asyncssh 依賴 `cryptography`，而後者零個 i686 wheel。

### 安裝路徑在寫任何檔案之前就斷了

依失敗順序：

1. `bootstrap.sh` 是 bash 專用（用了 array）—— BusyBox ash 跑不動。
2. `dotfiles_init.py` 需要 Python >= 3.11；Alpine 3.14 是 3.9.5，而 uv 無法下載 managed CPython，因為 **python-build-standalone 沒有 i686-Linux target**。**硬性 blocker。**
3. `run_once_before_00_bootstrap.sh.tmpl` 在 `set -e` 下執行 `uv tool install --python 3.13 ansible-core`，因同一原因失敗 —— 於是 chezmoi 在寫下任何 dotfile 之前中止。**硬性 blocker。**
4. `.chezmoi.toml.tmpl` 用了 `promptChoiceOnce`（需 chezmoi >= 2.42）；Alpine 3.14 的 apk chezmoi 是 2.0.16。

ansible 層根本沒有機會登場：166 個 Debian / 91 個 Darwin / 20 個 RedHat 的 `os_family` 分支，Alpine **零個**，所以它是靜默 no-op 而非爆炸。

## 建議的堆疊

compute 留在 fleet。iPad 只當 control plane 加上本機檔案層。

| 角色 | 工具 | 費用 |
|---|---|---|
| Agent 工作 | `claude --remote-control NAME` + Claude iOS app | 已訂閱的話 $0 |
| 終端機 | Blink Shell（見下方注意事項） | 約 $20/年 |
| 本機 Unix + vault git | **iSH**（見下 —— 不要遷移到 a-Shell） | 免費 |
| Vault git 替代方案 | Working Copy Pro | 約 $36 買斷 |

### `claude --remote-control`

在任一 fleet host 的 tmux 裡執行，用 Claude iOS app 掃 QR。**只有 outbound HTTPS** —— 不開 inbound port、不需要 VPN。你的 filesystem、MCP server、`CLAUDE.md` 與 subagent 全部保留。

!!! danger "這個 repo 會靜默停用它"

    `dot_config/shell/43_copilot_proxy.sh` 的 `_copilot_env_json()` 會把 `ANTHROPIC_BASE_URL`（指向 Copilot shim，而非 `api.anthropic.com`）與 `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` **兩者都**寫進 project 的 `.claude/settings.local.json`。任一個都會停用 Remote Control，而舊版 CLI 會把它回報成*「not yet enabled for your account」* —— 於是你跑去 debug 訂閱狀態而不是設定檔。

    在依賴 Remote Control 之前，先 audit 每個用 `copilot-here` pin 過的 project 的 `.claude/settings.local.json`。參見 [copilot-claude-proxy](../tools/copilot-claude-proxy.md)。

### SSH client

你的 **server 端已經是對的**：`dot_config/tmux/common.conf.tmpl` 設了 `extended-keys on`、`extended-keys-format csi-u`（tmux >= 3.5）與 `terminal-features 'xterm*:extkeys'`。缺口在 client 端。

| Client | mosh | Nerd Font | CSI-u | 備註 |
|---|---|---|---|---|
| **Blink Shell** | ✅ 1.4.0 | ✅ 約 50 個 patched font，貼 URL 即裝 | ❌ hterm 引擎 | iOS 上最深的鍵盤重映射（Caps → 單按 Esc / 長按 Ctrl）。僅訂閱制 |
| Moshi | 限 Pro | ❌ 無法匯入字型 → tofu | 未知 | **herdr** 一等公民整合；$199 買斷 |
| ShadowTerm | ✅ | ✅ 宣稱支援 | — | herdr 自動偵測 + MCP；僅 17 則評分 —— 未經驗證 |
| Prompt 3 | ✅ | ❌ | — | 一次買斷，但**無法重映射外接鍵盤** |
| Secure ShellFish | ❌ | — | — | 最佳 Files 整合；tmux session 選擇器 + Handoff |
| Termius | ✅ 免費版即有 | ❌ | — | 最佳跨裝置 host 同步 |

**Claude Code 的 Shift+Enter** 需要 CSI-u（`ESC[13;2u`）；純 PTY 對 Enter 與 Shift+Enter 送出同一個 CR。Blink 沒有 CSI-u，所以要自己綁一個鍵送 hex `0A`，或改用 **Ctrl+J** 這個萬用 fallback。

值得留意的 Blink open issue：#2232（`⏺` U+23FA 屬 East-Asian-Ambiguous width，hterm 的表與 Claude Code 不一致，導致整行位移）與 #2268 / #2134（CJK IME composition 在 Claude Code 裡顯示異常）。

**mosh 在 iSH 內部是壞的**（ish-app/ish#589、#2655）—— iSH 缺完整 raw/UDP socket 支援，且 iOS 在 suspend 時回收 socket。在 iSH 裡就用純 SSH + tmux；想要真正能 roam 的 mosh 請用 Blink。

## 設定 iSH

```sh
wget -qO- https://raw.githubusercontent.com/daviddwlee84/dotfiles/main/scripts/ios/ish-bootstrap.sh | sh
```

[`scripts/ios/ish-bootstrap.sh`](../../scripts/ios/ish-bootstrap.sh) 會安裝一組刻意精簡的套件（git、openssh-client、tmux、nano、vim、curl）、seed `~/.ssh/config`，並在 `~/.profile` 加入兩個 helper。

### Mount helper

iSH 透過 `mount -t ios null <dir>` 存取 iOS Files，該指令會叫出資料夾選擇器並儲存一個 security-scoped bookmark。**這個 mount 不會在 app 重啟後保留** —— 這就是為什麼 `mount -t ios` 會在每個人的 shell history 裡累積好幾次。

```sh
ovault              # 需要時掛載，然後 cd 進 vault
ovault Jingle.AI    # ...並進入某個 repo
ovsync Jingle.AI    # add -A、commit、pull --rebase --autostash、push
```

`ovault` 同時會把該 repo 註冊到 `safe.directory`，因為 iOS 掛載的樹永遠看起來屬於別的 owner，git 會以「detected dubious ownership」拒絕。這筆設定寫進 Alpine rootfs 裡的 `~/.gitconfig`，所以會保留。

### Alpine branch：選 3.18，不是最新

App Store 版本 pin 在 **Alpine 3.14**（2023-05-01 EOL）。往前移有幫助，但不要走太遠：

| Branch | 狀態 |
|---|---|
| 3.18 | 社群公認最後一個正常的版本 |
| 3.19 | `sudo` 一啟動就 crash；`procps` 讓 `uptime` segfault |
| 3.20 | 安裝 `coreutils` 會弄壞 `/dev` |
| **edge** | **不要。** Alpine 已把 x86 baseline 提升到 SSE2 並以 `-march=pentium-m` 建置；大半 userland 在 iSH 下會變成無法執行 |

bootstrap 預設保留你目前的 branch，除非你傳 `ISH_SWITCH_BRANCH=1`。

### 在 iSH 內跑 tmux 需要一份精簡過的 config

iSH 硬寫 `TERM=xterm-256color`，所以這個 repo 的 `terminal-features 'xterm*:extkeys'` **會 match**，tmux 於是相信外層終端支援 extended key。它並不支援 —— hterm 對 `CSI > Pm m` 標記為「won't support」。而失敗方式比「沒反應」更糟：

- `C-1` … `C-9` 的 window 切換完全失效。
- `C-2` 與 `C-6` 仍會抵達，但以 legacy 的 `C-Space`（0x00）與 `C-^`（0x1E）形式 —— 於是它們會**觸發綁在那兩個鍵上的其他東西**，而不是安靜地什麼都不做。

若你要在 iSH 內跑 tmux，請在那邊手寫一份最小的 `~/.tmux.conf`：拿掉 `extended-keys` / `extkeys` 與 `bind -n C-1..C-9` 那一段（改用 `prefix + 1..9`），並設 `mouse off` —— iSH 覆寫了 hterm 的 touch handler，滑鼠事件根本不會進到 tty（ish-app/ish#2537、#2375、#2708）。`set-clipboard on` 保留；OSC 52 是可以動的。

### 比任何套件都重要的 iOS 端設定

- **自動鎖定 → 永不。** 鎖屏會凍結 iSH。
- 若你要跑 `sshd` 並從外部連**進**這台裝置，用**引導使用模式**鎖在 iSH。
- 透過 iFont 或 configuration profile 安裝 Nerd Font，然後設 `/proc/ish/defaults/font_family`。請選 `*Nerd Font Mono` 變體 —— 非 Mono 的 patched font advance width 不均，會讓游標與字元錯位（ish-app/ish#1483）。

### 在裝置上跑 sshd

只對一件事有用：讓你筆電上的 agent 透過 LAN 驅動 iSH 的設定，而不是你在軟鍵盤上一個字一個字打。

```sh
apk add openssh && ssh-keygen -A && passwd
sed -i 's/^#\?Port .*/Port 22000/' /etc/ssh/sshd_config
/usr/sbin/sshd
```

1024 以下的 port 不可用（app 是非特權身分）。iSH 一離開前景 session 就死；`cat /dev/location > /dev/null &` 可用背景定位延長，但耗電且不可靠（ish-app/ish#1613、#2195）。Tailscale 幫不上忙 —— iOS app 不含 CLI，`tailscale serve` 在那裡不存在。

## 刻意不做的決定

記錄下來，以免日後重新爭論。

| 不做 | 理由 |
|---|---|
| **不加 `alpine` profile** | `.profile` 表達的是使用者角色，永遠不是 OS/arch 事實 —— 就是移除 `macos_intel` 的同一條規則。而且它會暗示 ansible 有支援，但那需要新增約 166 個 apk 分支 |
| **不為 ansible 加 apk 支援** | 為一個連自家社群都建議停在 EOL branch 的 32 位元模擬器擴張分支，ROI 是負的 |
| **不另開 `dotfiles-ios` repo** | Windows 那個 companion repo 憑 298 個檔案、不同的 shell 語言、以及真正的 `windows-latest` CI gate 站得住腳。iSH 可部署的表面約 6 個檔案，而且**不可能有 CI** —— 沒有任何 runner 能模擬「iSH 上的 Alpine x86」。一個無法驗證的六檔案 repo 會腐爛 |
| **不為 `dot_config/shell/**` 加逐檔 opt-out** | 只有 iSH 會需要，而 iSH 本來就該用手抄的方式 |

以下情況值得重新評估：Apple 釋出通用型 JIT entitlement；你開始管理多個 iOS app 的設定（超過約 20 個檔案）；或出現可在 CI 執行的非 SSE2 x86 Alpine 環境。

**要避開的陷阱**：這個 repo 在 Alpine 上是**乾淨地**失敗 —— ansible 靜默 no-op，shell layer 載入不噴錯。它看起來只差一個 patch 就能動。並不是：那條路的終點是一個開 shell 要好幾分鐘、且跑不動任何 agent 的環境。

## 延伸閱讀

- [glibc 與 musl](../glibc-and-musl.zh-TW.md)
- [fleet-hosts](../tools/fleet-hosts.md) —— picker 現在會讓你降落在可續接的 tmux session，這正是行動 client 好用的關鍵
- [copilot-claude-proxy](../tools/copilot-claude-proxy.zh-TW.md)
