# Pi / OMP harness combos (`pia`)

`installCodingAgents=true` 會安裝兩個 agent engine，並部署 Git 管理的
[`pi-agents`](https://github.com/daviddwlee84/pi-agents) combo manager。三個
command 各有明確 owner，升級時不會混在一起：

combo repo 是 private。新機器執行 `chezmoi apply` 前，請先準備 GitHub HTTPS
credential（例如 `gh auth login` 後再執行 `gh auth setup-git`）。

| Command | 安裝方式 | 位置 | 升級路徑 |
|---|---|---|---|
| `pi` | npm 套件 `@earendil-works/pi-coding-agent` | `~/.local/bin/pi` | `just upgrade-agents` |
| `omp` | 官方 prebuilt installer | `~/.local/bin/omp` | `just upgrade-agents` |
| `pia` | chezmoi git external | `~/.local/share/pi-agents/bin/pia` | `just upgrade-externals` |

Pi 以 `--ignore-scripts` 安裝到固定的 `~/.local` npm prefix，mise 升級
Node 後 command 不會跟著舊 Node 版本目錄消失。setup 會先以 transaction
安裝並驗證 canonical copy，再從 npm active runtime prefix 移除已棄用的
`@mariozechner/pi-coding-agent` 與重複的 maintained Pi package。如果安裝或
驗證失敗，會還原舊 `pi` command，且不會開始 cleanup。

OMP 強制使用 prebuilt binary；否則 installer 只要看到 Bun 就會改走 Bun，
而過舊的 Bun 會讓安裝在嘗試 standalone build 前就失敗。setup 會先以
read-only 方式偵測 package-managed copy，transactionally 安裝並驗證
standalone binary，最後才從 stable／active npm global 與 Bun global directory 移除
精確的 `@oh-my-pi/pi-coding-agent`，也支援自訂的
`BUN_INSTALL_GLOBAL_DIR`／`BUN_INSTALL_BIN`。下載失敗時會還原舊 `omp`
command，package 也不會被移除。

## 第一次使用

`chezmoi apply` 後開一個新 shell，再驗證並選擇 combo：

```sh
pi --version
omp --version
pia doctor
pia list --tree
pia use pi/base
pia run
```

`pia use` 只寫入目前選擇。不要在全域 export `PIA_COMBO`：該環境變數
優先級更高，會讓 `pia use` 看起來沒有作用。

## Ownership 邊界

- Chezmoi 擁有 external checkout 與 PATH wiring。
- `pi-agents` repo 內的 Git 擁有 CLI source 與 combo 定義。
- `pia` 擁有 XDG state/config 位置下的私有 runtime 設定、session 與
  handoff artifact。
- Pi、OMP 各自擁有 authentication；credentials 不進 dotfiles，也不進
  external checkout。

把 `~/.local/share/pi-agents` 當成部署 mirror。請在一般 development clone
內 author／derive combo，commit + push 後再跑 `just upgrade-externals`。
`pia` 不需要 `npm install`、`npm link` 或生成 `dist/`。

共享的 `08_pi_agents.sh` 會在 mise 與 Bun setup 後載入：受管的 Pi／OMP
binary 存在時重新前置 `~/.local/bin`，再前置 external `pia` bin。升級命令
也只呼叫 canonical exact path，不會使用 PATH 上先出現的同名 command。

## 相容性

Pi 與 `pia` 需要 Node 22.19 以上。OMP prebuilt installer 支援 macOS／Linux
的 x64、arm64。engine install tasks 會跳過已知不相容的 armv7 Node 20
路徑與 EL7 baseline。external checkout 仍可能在這些主機刷新，但在主機升級
前，`pia doctor` 會回報 Node runtime 不相容。

OMP 的 zsh／bash completion 會在 apply 時依 binary mtime 自動重建。
Authentication 與第一個真實 agent request 仍需手動 smoke test，因為需要
provider credentials。
