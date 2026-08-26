# Agent 完成音效（`agentSounds`、peon-ping、OpenPeon/CESP）

coding agent 做完事情時怎麼通知你：桌面橫幅、遊戲角色語音、兩個都要、或什麼都不要。
用 `agentSounds` 這個 chezmoi prompt 逐台機器決定。

> **TL;DR** —— `agentSounds` **只控制掛不掛 hook**。`peon` CLI 只要是有裝 coding
> agents 的桌面機都會裝，所以你隨時可以玩，不用重跑 `chezmoi init`。peon 自己的設定
> （音量、音效包、通知樣式）**刻意不給 chezmoi 管** —— 隨便調，永遠不會產生 drift。

## 生態系（三個名字很像的東西）

| | 實際上是什麼 |
|---|---|
| **[OpenPeon](https://openpeon.com/)** | 一個開放**標準** —— CESP（*Coding Event Sound Pack Specification*）—— **以及**社群**註冊表**（約 349 個包）。一個 pack = `openpeon.json` manifest + 音檔，發佈在 GitHub。 |
| **[peon-ping](https://github.com/PeonPing/peon-ping)** | 實作 CESP 的其中一個**播放器/客戶端**（MIT）。把 hook adapter 裝進各家 agent、從註冊表下載 pack、播放它們。還有別的 CESP 播放器（例如 Claudette）。 |
| **[game-sounds](https://github.com/Citedy/game-sounds)** | 跟 CESP 無關 —— 自帶 63 個 pack 的 Claude Code plugin。這裡沒用。 |

類比：OpenPeon 是格式 + 索引，peon-ping 是客戶端。「peon」這名字來自 Warcraft III
的工兵（"Work complete!"）。

這裡的預設 pack 是 **[`sc2_scv`](https://openpeon.com/packs/sc2_scv)** ——
StarCraft II Terran 的 **SCV**（Space Construction Vehicle），44 條語音涵蓋全部 7 個
CESP category。它的 `task.complete` 是 **"Job's finished!"**。

## 四個層級

| `agentSounds` | 掛什麼 | 你會得到 |
|---|---|---|
| `none` | 什麼都不掛 | 安靜 |
| `notify`（預設） | `notify.sh` → apprise → `terminal-notifier` | macOS 橫幅 |
| `peon` | peon-ping 的 9 個 hook 事件 | SCV 語音 + peon 自己的 overlay 橫幅 |
| `both` | 以上兩者 | 橫幅 + 語音 + peon overlay（會有兩個橫幅，見下） |

只在桌面 profile 提供；`ubuntu_server` / `centos_server` 直接寫死 `none`
（沒有音效裝置、也沒有通知 daemon）。`minimal` bundle 強制 `none`。

**`both` 會有兩個橫幅**是預期行為 —— apprise 畫一個、peon 畫一個。嫌吵的話不用改
層級，直接在 runtime 關掉 peon 的視覺就好：`peon notifications off`（聲音照常）。

## chezmoi 管什麼、刻意不管什麼

這個切分就是整個設計的重點。

| chezmoi 管 | 你自己在 runtime 決定 |
|---|---|
| **有哪些 hook** —— [`dot_claude/modify_settings.json.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_claude/modify_settings.json.tmpl) | 音量、使用中的 pack、通知樣式、靜音狀態 —— 全在 `~/.openpeon/config.json` |
| 安裝 binary + 首次 seed 音效包（ansible `coding_agents` role） | 所有 `peon` CLI 摸得到的東西 |

`~/.openpeon/` **永遠不會**被加進 chezmoi source tree。所以下面這些都安全、而且
**零** `chezmoi diff`：

```sh
peon volume 0.3
peon packs use --install glados     # 整個換掉 SCV
peon notifications standard         # 用系統通知取代 overlay
peon toggle                         # 靜音/解除
peon preview task.complete          # 聽目前 pack 的「完成」語音
peon packs list --registry          # 瀏覽全部約 349 個 pack
```

ansible 的 seed task 用 `creates:` 卡在 `~/.openpeon/config.json`，所以只在新機器跑
**一次**、之後永不再跑 —— 你後來換的 pack 會一直留著。

## 為什麼我們永遠不跑 `peon-ping-setup`

`brew install peon-ping` 只給你 binary。`peon-ping-setup` 是另一個步驟，它會把 hook
寫進 `~/.claude/settings.json`。我們自己接線、永遠不跑 setup —— 跟這個 repo 對
workmux `wm setup` 的既有規則一樣。

理由**不是**怕衝突。hook merger 是**加法式**的，本來就會保留安裝器寫的東西
（CodeIsland、workmux、herdr 的 hook 今天就是這樣共存的）。真正的理由是：

- **可重現** —— 安裝器寫的 hook 只存在於你記得跑過的那台。用宣告的方式，每台機器
  `chezmoi apply` 就有。
- **可 gate** —— 安裝器不知道 `agentSounds`，也不知道你的 profile。
- **波及範圍** —— `peon-ping-setup` 會讀 `$XDG_CONFIG_HOME`，因此**會逃出**你假造的
  `$HOME`，即使你以為已經隔離了，它照樣會寫進你真正的 `~/.config/opencode/`。見
  [`pitfalls/peon-ping-setup-escapes-home.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/peon-ping-setup-escapes-home.md)。

`peon` CLI 本身完全獨立 —— 它會自己建一個 tool-agnostic 的根目錄 `~/.openpeon`
（packs + config），完全不需要安裝器會建的那整棵 `~/.claude/hooks/peon-ping/`；
`libexec/peon.sh` 靠 packs-anchored fallback 自己找得到。

## 各 agent 的涵蓋方式 —— 刻意分成兩種機制

| Agent | 做法 | 為什麼 |
|---|---|---|
| **Claude Code** | hook 條目寫進 hook-aware merger | 它是 Pattern B「混合檔」—— 見 [agent-overlays.md](agent-overlays.md) |
| **OpenCode** | ansible 從 peon-ping 的 `libexec` 建 symlink | OpenCode 用 plugin 不是 hook。上游本來就是用 symlink 出貨，所以用連結（而不是複製一份）才能跟著升級 |
| **Codex** | peon hook 寫進 `~/.codex/hooks.json` 的 hook-aware merger | 與 Herdr 0.8.0 integration v7、CodeIsland 等外部條目加法共存 |
| **Cursor** | 交給 peon-ping 自己的 adapter | `~/.cursor/hooks.json`，同上 |

Cursor 的 `hooks.json` 仍刻意不被 chezmoi 管；Codex 不同：
[`dot_codex/modify_hooks.json.tmpl`](../../dot_codex/modify_hooks.json.tmpl)
會只辨認並替換 peon 自己的 command fingerprint，完整保留 Herdr、CodeIsland、
Superset 與其他外部 hook。

舊版 peon adapter 也可能把 `[[hooks.<Event>]]` 寫進
`~/.codex/config.toml`。Codex 會同時載入 TOML inline hooks 與 `hooks.json`，但同一層
兩種表示法會印出警告且可能重複觸發。`modify_config.toml.tmpl` 因此只剪除 command
指向 peon adapter 的舊 inline 條目，保留 `[hooks.state]` 與所有非 peon hook；實際
lifecycle hooks 統一由 `hooks.json` merger 管理。

## 唯一一處我們會「減」的地方

merger 的規則是「絕不移除 hook 條目」—— 這正是外部工具能共存的原因。只有一個例外：
**我們自己**宣告的條目，會在目前層級關掉它時被移除。

沒有這個的話 `agentSounds` 會變成單向棘輪 —— 從 `notify` 換到 `none` 時，已經裝好的
`notify.sh` 會永遠留著，於是 `none` 對一台原本有聲音的機器根本不會變安靜。prune 清單
只由我們自己的指令指紋組成，所以不論哪個層級，CodeIsland / workmux / herdr 的條目都
絕不可能被動到。

## 驗證

```sh
peon status                     # 目前 pack、音量、靜音狀態
peon preview task.complete      # 應該說 "Job's finished!"
jq '.hooks | keys' ~/.claude/settings.json
peon volume 0.4 && chezmoi diff # 必須是空的 —— 證明 config 沒被管
```

**上面四行全過也不代表真的會發出聲音**。這組指令曾經在一台完全沒聲音的機器上全部通過
（→ [`peon-hooks-wired-but-no-sound`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/peon-hooks-wired-but-no-sound.md)）：
`peon status` 只看 `~/.openpeon`；`preview` 根本繞過 hook；而 settings 裡的 key 可以
存在、hook 指向的檔案卻不存在 —— 因為 hook 自己的 `[ -x … ] || true` 保護會把「播放器
不存在」變成一次**成功**的 no-op，Claude 於是回報 `completed successfully`。

真正要檢查的是那個 staging symlink，以及用 Claude Code 的方式實際觸發一次：

```sh
ls -la ~/.claude/hooks/peon-ping/peon.sh    # symlink -> <brew prefix>/libexec/peon.sh
echo '{"hook_event_name":"Stop","session_id":"probe","cwd":"'"$PWD"'"}' \
  | "$HOME/.claude/hooks/peon-ping/peon.sh"
jq '.last_played' ~/.openpeon/.state.json   # -> {"task.complete": "sounds/JobsFinished.mp3"}
```

`.last_played` 是唯一能被機器檢查、證明聲音真的送出去的證據。

各層級的 hook 接線有 `tests/unit/agent_overlays.bats` 覆蓋。

## 兩個看起來壞了、其實是正常的行為

**你正在看終端機時不會跳 banner —— 這是刻意的。** peon 用 focus 來 gate overlay
（`peon.sh` 裡的 `notify … gate` / `suppressed` 分支）：聲音一定會播，但終端機在最前景時
就不跳橫幅，因為你本來就看得到結果。切到別的 app 再讓它跑完就會看到。可以用
`peon debug on` 確認 —— 有跳時 log 是 `dispatch event=Stop focused=false`，被擋掉時是
`suppressed event=Stop focused=true`。

**`peon notifications test` 印出「sending test notification」然後什麼都沒發生。**
上游 bug，在 2.35.1 上驗證過 —— 不影響真正的通知。這個子指令跑的是
`PEON_TEST=1 send_notification …`，而 `PEON_TEST=1` 會讓 `find_bundled_script`
跳過 Cellar/sibling 的 fallback（這個 flag 本來是給上游自己的「script 不存在」測試用的）。
我們的 `PEON_DIR` 是 `~/.openpeon`，底下沒有 `scripts/`，所以查找失敗，`send_notification`
直接走到 `[ -z "$notify_script" ] && return 0` —— 一次安靜的成功。連 debug log 都不會寫，
這是跟「真的壞掉」最快的區分方式。要測就用一次真正的、非前景的 turn。

另外，`Notification` 事件只對 peon 認得的訊息類型發通知（`idle_prompt`、
`elicitation_dialog`）；其他都會記
`route category=none suppressed=True reason=unknown_notification`。
`permission_prompt` 刻意只改 tab 標題 —— 它的聲音來自另一個 `PermissionRequest` 事件。

## 之後要改層級

`agentSounds` 是 `promptChoiceOnce` —— 只在你的 chezmoi config 裡沒有它時才會問。
要在既有機器上改：

```sh
just reconfigure --set agentSounds=peon --yes
chezmoi apply
```

> **舊 profile 陷阱。** 如果某台機器的 config 還帶著已退役的 `macos_intel` profile，
> 它不會符合桌面 gate，於是 `agentSounds` 會被寫成 `none`（其他所有桌面限定的 prompt
> 也一樣）。`just reconfigure` 會偵測到這個退役值並重新挑 profile —— 桌面 Mac 莫名其妙
> 拿到 `none` 時，先跑這個再去 debug 別的。

## 參見

- [agent-overlays.md](agent-overlays.md) —— hook-aware merger 與 CodeIsland 共存設計
- [workmux.md](workmux.md) —— 這裡比照的 `wm setup` 規則
- [tool-managers.md](../this_repo/tool-managers.md) —— peon-ping 怎麼裝
