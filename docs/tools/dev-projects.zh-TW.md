# 共用 repository 導航

`dev-projects` 直接讀 `dev repo list --json`，提供 Sidecar、Neovim 與 Television
共用的本機 repo 候選。這是 dotfiles helper，不是 dev binary 的新子指令。
需要 Python 3.11+、Git、dev；選用 Sidecar／Neovim 時才需要該工具。
沒有背景掃描或第二份 catalog。

Prototype 以 macOS/Linux 為目標。路徑含 ASCII control characters 時會拒絕，
避免破壞以行為單位的 picker；支援空格、引號與 Unicode。Sidecar 匯入另外
拒絕原生 CLI 會 trim 的頭尾空白路徑，防止登記成另一個目錄。

## 日常使用

```bash
dev-projects list --json
dev-projects open /absolute/repo --tool sidecar
dev-projects open /absolute/repo --tool nvim
```

Helper 排除 bare repo 與失效目錄，以實體路徑合併 symlink 重複項目；相同名稱
或 remote URL 的不同 clone 仍分開。開啟前重新確認候選與 Git checkout，再以
獨立 argv 傳遞路徑。不登記 Sidecar Project、不初始化 td、不建立 task 或選 agent。

Neovim 使用 `:DevRepositories`，非同步載入；載入中再呼叫一次會取消。選取後
瀏覽該 repo 的 files，不更改 editor cwd 或 restore session。原生 Projects
(`p`／`<leader>fp`)、recent files、project.nvim history 和 persistence 保留原本
用途。專用 Snacks picker 不依賴 LazyVim 的預設 picker，editor 啟動時不掃 repo。

Television 只選路徑，不自動執行動作：

```bash
repo_path="$(tv dev-repos)" && [ -n "$repo_path" ] &&
  dev-projects open "$repo_path" --tool sidecar
```

`dev repo list` 是完整 local inventory，按需呼叫即可，不要每次按鍵都重跑。
來源失敗會回報 error，不當成成功的空清單；helper 不讀 private dev cache。

## 可選 Sidecar 匯入

Sidecar 的 `--project` 可直接開尚未登記的 repo，原生 `@` 則列已配置的 Projects。
需要常駐入口時才補入：

```bash
dev-projects sidecar-import --repo /absolute/repo --json
# 檢查 add/already_present/name_conflict/unavailable 後明確套用：
dev-projects sidecar-import --repo /absolute/repo --apply --yes --json
```

省略 `--repo` 會預覽全部候選。Apply 同時需要兩個 flag，不會互動提示；agent
可先展示預覽。實體路徑已存在便 no-op，保留原生名稱；同名不同路徑回報衝突。
來源不再出現不代表刪除目的端項目，也不呼叫 `--switch`。

這是 add-only 匯入，不是完整鏡像。不需要另一份 ownership ledger；rename、
move、remove、editor session、td issue 與使用歷史不在 adapter 範圍。
Sidecar 1.14 原生 CLI 會重新序列化設定，沒有跨程序 CAS／batch transaction。
Helper 在套用前拒絕無法保留的未知 project 欄位，但仍不可與其他設定寫入者
並行。逐筆重新讀取與驗證，回報 partial／unknown，不自動重試或撤销成功項目；
JSON 排版可能隨原生 CLI 改變。

第一次以隔離設定試用：

```bash
trial_dir="$(mktemp -d)"
printf '{}\n' > "$trial_dir/config.json"
XDG_STATE_HOME="$trial_dir/state" dev-projects sidecar-import \
  --config "$trial_dir/config.json" --repo /absolute/repo --json
XDG_STATE_HOME="$trial_dir/state" dev-projects sidecar-import \
  --config "$trial_dir/config.json" --repo /absolute/repo --apply --yes --json
```

測試可用 `DEV_PROJECTS_DEV`／`DEV_PROJECTS_SIDECAR` 指定單一 executable path，
不是 shell command 字串。資料以 JSON 輸出，診斷走 stderr；exit code 見 `dev-projects --help`。

## 現有相近工具

| 工具 | 資料與責任 | 整合方式 |
|---|---|---|
| dev REPOS | repo discovery 與可選 catalog metadata | 共用本機候選 |
| Sidecar Projects | 具名 project 設定 | 明確 add-only 匯入 |
| LazyVim Projects | util.project history／選用 picker | 獨立 Dev Repositories view |
| sesh | tmux、具名設定、zoxide | 傳選定路徑；generated import fragment 留待後續 |
| Herdr／herdr-plus | live workspaces／啟動 layout | 沿用 cwd 入口，不鏡像 session |
| Television herdr-sesh | Herdr workspaces 與 zoxide | 獨立 `dev-repos` channel |
| zoxide／lazygit recents | 實際使用歷史 | 不週期灌入全部 repos |
| persistence／tmux restore／Zellij | editor／terminal session | 由原生工具 restore |
| Worktrunk／Workmux | worktree 建立、啟動、merge／remove | 每個試用只選一個 lifecycle owner |
| Ruby try-cli | scratch directory lifecycle | 與一般候選分開 |
| Yazi | 檔案導航；未配置 project-bookmark plugin | 開選定目錄 |

目前 LazyVim 啟用 util.project 並沿用較早的 fzf 預設；`projects.lua` 設定的是
另一個 Snacks Projects finder，調整它未必改變 dashboard `p`。改設定前檢查
實際 keymap；此 helper 不替換這些入口。

## Worktree 與 task 試用

[dev-cli workflow trial](https://github.com/daviddwlee84/dev-cli/tree/main/contrib/worktree-trial)
提供獨立的 Herdr/dev 與 Sidecar Go 範例、隔離設定及人工 feedback 清單，不必
事先 `dev work start`。PR 未 merge 保持 active；main ancestry、writer exit
及經確認的殘留內容才是收尾條件。Transcript 路徑不是整批丟棄授權。
這個 prototype 不正式 deprecate 現有 task 指令。

## 來源與驗證

- [Sidecar project switching](https://github.com/marcus/sidecar/blob/v1.14.0/website/docs/project-switching.md)
- [Sidecar project CLI](https://github.com/marcus/sidecar/blob/v1.14.0/internal/cli/project.go)
- [LazyVim project extra](https://www.lazyvim.org/extras/util/project)
- [sesh 2.22 import](https://github.com/joshmedeski/sesh/blob/v2.22.0/configurator/configurator.go)

執行 `python3 -m unittest discover -s tests/unit -p test_dev_projects.py`；
Neovim adapter 的 headless test 也在 `tests/unit/`。測試不開使用者 editor
session，也不匯入真實 Sidecar 設定。
