# 把圖片貼進遠端 coding agent（透過 SSH）

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：逸出序列
    (escape sequence)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `clipboard`、`daemon`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

**狀態：僅調研 — 尚未採用任何方案。** 本文件盤點如何把**本機**剪貼簿裡的**圖片**（截圖）送進一個透過 SSH 跑在**遠端**機器上的 coding agent（Claude Code，以及 Neovim 相關工作流）。它是 [`clipboard.md`](./clipboard.md) 的「圖片版續集」：OSC 52 解決了遠端剪貼簿同步的**文字**那一半，但它**無法載送圖片或檔案 (file) payload**，所以需要另一套機制。

等我們真的選定並接進 dotfiles 後，本文件會從「盤點」升級成「這是怎麼串接的」（並補上 `.zh-TW.md` 鏡像，與 `docs/tools/` 其他文件一致——你現在讀的就是）。

## 核心限制

| | 資料在哪 | 今天怎麼跨 SSH |
|---|---|---|
| yank 的**文字** | 遠端 app → 本機剪貼簿 | **OSC 52** — 逸出序列沿 TTY 往上送回本機終端機（見 [`clipboard.md`](./clipboard.md)） |
| 截圖**圖片** | **本機**剪貼簿 → 遠端 agent | ❌ 沒有內建機制——OSC 52 只能載文字；圖片 bytes 根本沒離開你的筆電 |

這個不對稱就是問題全貌。裝著截圖的剪貼簿在你的**本機**；需要「看到」圖片的 agent 跑在**遠端**。OSC 52 方向相反（遠端→本機），而且只載 base64 文字。所以下面每個方案骨子裡都是同一招：**把本機的圖片 bytes 落成遠端檔案系統上的一個檔案，再把那個路徑交給 agent**（agent 透過自己的 Read 工具從路徑讀圖）。它們的差別只在於 bytes **怎麼傳**、以及這趟來回**自動化到什麼程度**。

> **那 terminal 圖片協議（kitty graphics / sixel / iTerm2 inline）為什麼不行？** 那些是**輸出 (output)** 協議——讓遠端程式把圖**畫**進你的終端機。它們不提供遠端程式去**擷取**你本機剪貼簿裡圖片的手段。一樣是方向反了。（我們已為顯示面開了 `allow-passthrough on`；那對輸入毫無幫助。）

## 方案分類

### 0. 基準線 — 手動落檔 + 路徑引用（零工具）

把截圖存到遠端看得到的地方，然後在 agent prompt 裡引用路徑。

```bash
scp ~/shot.png remote:/tmp/            # 或拖進 sshfs / VS Code 掛載
# 然後在遠端的 Claude Code 裡：
#   @/tmp/shot.png   這個 layout 哪裡有問題？
```

- **優點：** 到處都能用，無 daemon、無 tunnel，撐得過 tmux/mosh。這是永遠可用的退路。
- **缺點：** 每次都要手動；打斷心流。下面所有方案都只是這條基準線的自動化。

### 1. 網路 daemon + SSH reverse tunnel（Zeitler 家族）

對**純 terminal / tmux** 工作流最對味。一個小 daemon 跑在你**本機**讀本機剪貼簿；**遠端**那側透過 SSH **反向** tunnel（`RemoteForward`）連到它，把 bytes 寫成暫存檔。我們本來就維護長期 SSH 設定，加一行 `RemoteForward` 成本很低。

#### 1a. `claude-ssh-image-skill` — ccimgd + ccimg + `/paste-image` skill

[AlexZeitler/claude-ssh-image-skill](https://github.com/AlexZeitler/claude-ssh-image-skill) · MIT · Go（靜態 binary）· **對原始問題最直接的答案。**

架構（base64-over-TCP，不用 scp）：

```
/paste-image（遠端 Claude skill）
  └─ Bash: ccimg（遠端 client）
       └─ TCP 127.0.0.1:9998  ──(SSH -R 反向 tunnel)──▶  ccimgd（本機 daemon）
                                                            └─ 讀本機剪貼簿
                                                               (wl-paste / xclip / pngpaste)
       ◀── JSON { ok, image: <base64 PNG> } ─────────────────
  └─ ccimg 寫出 /tmp/…png，印出路徑
  └─ Claude 的 Read 工具載入該路徑 → 圖片進入 session
```

安裝（README 原文照抄）：

```bash
# 建置兩個 binary（需要 Go）
git clone https://github.com/AlexZeitler/claude-ssh-image-skill.git
cd claude-ssh-image-skill && ./build.sh

# 本機 daemon — Linux
cp daemon/ccimgd-linux-amd64 ~/.local/bin/ccimgd
cp daemon/ccimgd.service ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now ccimgd
# 本機 daemon — macOS
brew install pngpaste
cp daemon/ccimgd-darwin-arm64 /usr/local/bin/ccimgd
cp daemon/com.ccimgd.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.ccimgd.plist

# 遠端：client binary + skill
scp client/ccimg-linux-amd64 remote:~/.local/bin/ccimg
scp skill/paste-image.md      remote:~/.claude/commands/paste-image.md
```

反向 tunnel（寫進 `~/.ssh/config` 讓它自動）：

```ssh-config
Host remote-server
    RemoteForward 9998 localhost:9998
```

……或臨時：`ssh -R 9998:localhost:9998 remote-server`。把 `"Bash(ccimg)"` 加進遠端 `~/.claude/settings.json` 的 `permissions.allow` 就能免確認執行 client。用法：本機複製一張圖，然後在遠端 Claude session 執行 `/paste-image`。

- **剪貼簿後端：** Wayland `wl-paste`、X11 `xclip`、macOS `pngpaste`（自動偵測）。
- **對我們的契合度：** ★ terminal/tmux 最佳解。Port **9998** 刻意跟 sshimg.nvim 的 9999 錯開，好讓兩個 daemon 並存。
- **代價：** 反向 tunnel 要一直開著；本機 daemon 要在跑；只吃 PNG。

#### 1b. `sshimg.nvim` — imgd + Neovim plugin（scp 傳輸）

[AlexZeitler/sshimg.nvim](https://github.com/AlexZeitler/sshimg.nvim) · MIT · Python daemon + Lua plugin。同一作者，目標換成 **Neovim** 而非 Claude，傳輸也不同：走 **scp** 而非 base64-over-TCP。

```
截圖（本機）→ imgd daemon → SSH 反向 tunnel → scp → 遠端 Neovim
```

```bash
# 本機 daemon
cp daemon/imgd.py ~/.local/bin/imgd && chmod +x ~/.local/bin/imgd
cp daemon/imgd.service ~/.config/systemd/user/imgd.service
systemctl --user enable --now imgd
ssh -R 9999:localhost:9999 yourserver      # 反向 tunnel（port 9999）
```

```lua
-- lazy.nvim
{ "AlexZeitler/sshimg.nvim", opts = {
    port = 9999, host = "127.0.0.1",
    -- <leader>pa → 存進 ./assets/ ; <leader>pp → 存在目前檔案旁
} }
```

在遠端的 Markdown buffer 按 `<leader>pa` / `<leader>pp` → plugin 把本機剪貼簿圖片 scp 過去，並在游標處插入 `![](assets/2026-…​.png)`。

- **依賴：** 本機 = `wl-paste` + `scp` + Python 3（依 README 僅 Wayland）；遠端 = Neovim + Python 3。
- **對我們的契合度：** ★ 補足我們的 Neovim-over-SSH 設定（見 [`clipboard.md`](./clipboard.md) §3「編輯器 — Neovim」的 SSH 條件式 OSC 52 provider）。它會把真檔案寫進 repo 樹裡，這正是之後讀那份 Markdown 的 agent 想要的。缺點：如文件所述只支援 Wayland 剪貼簿讀取；開箱沒有 macOS/X11 路徑。

> **背景文章**（把 1a+1b 串起來）：[Paste clipboard images into Claude Code over SSH](https://alexanderzeitler.com/articles/paste-clipboard-images-into-claude-code-over-ssh/)。

### 2. GUI 編輯器橋接 — 讓編輯器掌管剪貼簿

如果 agent 是從 **VS Code Remote-SSH** 驅動，貼圖問題直接消失：VS Code 跑在**本機**、掌管本機剪貼簿，所以正常的 `Ctrl/Cmd+V` 貼進 Claude Code 擴充的輸入框，圖片就會透過編輯器的遠端通道帶過去——不用 daemon、不用 tunnel。

- **官方：** [Claude Code VS Code 擴充](https://code.claude.com/docs/en/vs-code) 走 Remote-SSH。除了兩個擴充之外零設定；還附帶圖形化 diff / plan review。
- **社群 CLI-in-terminal 變體**（當你在 VS Code 內建終端機裡跑 Claude *CLI* 而非用擴充時）：例如 [marcucio/claude-image-paste](https://github.com/marcucio/claude-image-paste) 讀本機剪貼簿、透過 Remote-SSH 檔案系統上傳、貼出對應的遠端路徑。Marketplace 上還有幾個做同樣把戲的（`claude-remote-image-paste`、`claude-paste-image`）。
- **對我們的契合度：** ★ 雙軌工作流裡 **VS Code 那側**的最佳解。對純 tmux SSH session 毫無作用。

### 3. 本機剪貼簿 → 路徑注入器（與終端機無關）

這類工具以熱鍵擷取或讀取本機剪貼簿，落成檔案，再把**檔案路徑打字**進目前 focus 的終端機。因為它們注入的是*文字*（一段路徑），所以跟任何鍵盤輸入一樣能越過 SSH。

| 工具 | 平台 | 機制 | 備註 |
|---|---|---|---|
| [Invoke](https://getinvoke.dev/learn/screenshot-paste-claude-code-terminal/) | 跨平台 | 熱鍵截圖 → `~/.screenshots/…` → 貼出路徑 | 付費（約 $49 一次性）；零 SSH 設定；但路徑是**本機**的——只有在終端機 app 能把它對映到遠端可見路徑（掛載）、或你接受本機擷取流程時才有用 |
| [Clipport](https://github.com/arihantsethia/clipport) | macOS + iTerm2 | `clipportd` daemon 透過既有 SSH 連線上傳剪貼簿圖片、插入**遠端**路徑 | 單鍵；iTerm2 貼上熱鍵 → helper；僅 macOS/iTerm2，專有協議（非 OSC 52） |

- **對我們的契合度：** 視情況。**若**你統一到 macOS + iTerm2，Clipport 的單鍵 UX 最俐落（我們沒有——跨 macOS + Linux 用 Ghostty/Alacritty）。

### 4. 雲端 — 直接繞開 SSH

[Claude Code on the web](https://code.claude.com/docs/en/claude-code-on-the-web) 把 agent 跑在 Anthropic 的 sandbox；你直接把圖貼進瀏覽器（本機剪貼簿，流程裡沒有 SSH）。

- **對我們的契合度：** 只有在程式碼能放進 Anthropic 雲端時。對任意遠端機器 / 私有基礎設施不是通用解。

## 對比矩陣

| 方案 | 目標 | 本機依賴 | 遠端依賴 | 傳輸 | 需 tunnel？ | 平台 | 契合度 |
|---|---|---|---|---|---|---|---|
| 0 · 手動 `scp` + `@path` | 任何 agent | — | — | scp/掛載 | 否 | 全部 | 退路 |
| 1a · claude-ssh-image-skill | **Claude Code CLI** | ccimgd + wl-paste/xclip/pngpaste | ccimg + skill | base64/TCP :9998 | **反向** | Wayland/X11/macOS | ★ terminal |
| 1b · sshimg.nvim | **Neovim** | imgd + wl-paste + scp + py3 | nvim + py3 | scp :9999 | **反向** | Wayland（依文件） | ★ nvim |
| 2 · VS Code Remote-SSH | Claude 擴充 / CLI | VS Code | Remote-SSH server | 編輯器通道 | 否 | 全部 | ★ VS Code |
| 3 · Invoke / Clipport | 任何終端 agent | daemon | — | 路徑注入 / 上傳 | 否 | Invoke: 全部 · Clipport: mac+iTerm2 | 視情況 |
| 4 · Claude Code web | web agent | 瀏覽器 | —（雲端） | HTTPS | 否 | 全部 | 僅雲端 |

## 對*本*設定的契合評估（供之後決策）

- **我們是雙軌**（機主 tmux/terminal 與 VS Code/Neovim *都*用），所以答案很可能是**兩個互補選擇**、而非一個：terminal/tmux Claude 用 **1a**，編輯器那側用 **2**（VS Code）或 **1b**（Neovim）。1a 與 1b 天生可並存（port 9998 vs 9999）。
- **反向 tunnel 是反覆成本。** 我們本來就精修 `~/.ssh/config`；每台機器一行 `RemoteForward` 就是整個家族 1 方案的入場費。值得決定是否跨主機統一一個 port（例如 9998）。
- **剪貼簿後端分散：** 我們的機器橫跨 macOS、Wayland、X11。1a 三者都自動偵測；1b 依文件僅 Wayland——若機主要走 Neovim 路徑且在 macOS/X11 上，這是個要衡量的缺口。
- **既有基礎設施幫的是顯示面**（`allow-passthrough on`、`set-clipboard on`），與*輸入*正交；這些都不需改動。
- **建置 / 信任：** 家族 1 都是小型 MIT Go/Python，會從原始碼自建、以**使用者**層級的 systemd/launchd service 跑，讀剪貼簿並在 localhost 監聽——信任面跟 `x` CLI 相同。不需 root。
- **安全備註：** 一個隨叫隨應地把你剪貼簿圖片吐出來的 localhost daemon，任何能打到遠端那個被 forward 的 port 的東西都碰得到——也就是 tunnel 開著時、在那台機器上有帳號的任何人。單人機可接受；共用主機要三思。

## 採用前的未決問題

1. 一個工具還是兩個（terminal + 編輯器）？反向 tunnel 的 port 要不要統一？
2. 透過 ansible `devtools` role 打包（自建 Go binary + 裝 user service），還是內附預建 binary？
3. 若要 1b，Neovim 路徑的 macOS/X11 故事怎麼辦（上游僅 Wayland）——打 patch，還是限縮成只用 Claude-CLI（1a）？
4. 把反向 tunnel 的 `RemoteForward` 包進受管的 SSH 設定，還是留成各主機本地？

## 外部參考

- [claude-ssh-image-skill (ccimgd/ccimg)](https://github.com/AlexZeitler/claude-ssh-image-skill) · MIT
- [sshimg.nvim](https://github.com/AlexZeitler/sshimg.nvim) · MIT
- [文章：Paste clipboard images into Claude Code over SSH](https://alexanderzeitler.com/articles/paste-clipboard-images-into-claude-code-over-ssh/)
- [文章：Introducing sshimg.nvim](https://alexanderzeitler.com/articles/introducing-sshimg-nvim-paste-images-into-remote-neovim-over-ssh/)
- [Clipport](https://github.com/arihantsethia/clipport) · [說明文](https://arihantsethia.com/clipport-paste-across-remote-terminals/)
- [Invoke — 把截圖貼進終端機](https://getinvoke.dev/learn/screenshot-paste-claude-code-terminal/)
- [Claude Code in VS Code](https://code.claude.com/docs/en/vs-code) · [Claude Code on the web](https://code.claude.com/docs/en/claude-code-on-the-web)

## 相關文件

- [`clipboard.md`](./clipboard.md) — OSC 52 文字剪貼簿同步（文字那一半；說明為何圖片無法搭 OSC 52）
- [`tmux/README.md`](./tmux/README.md) — `allow-passthrough` / 終端機圖片顯示面
- [`aicapture.md`](./aicapture.md) — *文字* scrollback → agent 的擷取層（相鄰的「餵 context 給 agent」工具）
