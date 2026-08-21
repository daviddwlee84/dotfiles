# `.chezmoiscripts/` 佈局

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

這個 repo 把自動執行的腳本 (script) 組織進 `.chezmoiscripts/` 下的雙桶 (two-bucket) 佈局，目錄名稱中編碼了**範圍 (scope)**（也就是當腳本變更時，哪些機器應該重新執行）：

```
.chezmoiscripts/
├── global/   # Runs on every machine that consumes this repo
│   ├── run_onchange_after_20_ansible_roles.sh.tmpl
│   ├── run_onchange_after_25_bat_theme.sh.tmpl
│   ├── run_onchange_after_30_brew_bundle.sh.tmpl
│   ├── run_onchange_after_32_raycast_config.sh.tmpl
│   └── run_onchange_after_40_install_global_skills.sh.tmpl
└── repo/     # Runs only when the chezmoi source dir IS this repo working tree
    └── run_onchange_after_45_bootstrap_skills.sh.tmpl
```

加上四個刻意留在 repo 根目錄的 `run_*before_*` 腳本 — 見下方[「什麼還留在 repo 根目錄」](#whats-still-at-the-repo-root-and-why)。

## 什麼還留在 repo 根目錄（以及為什麼）

四個 `run_*before_*` 腳本刻意留在 repo 根目錄：

| 腳本 | 階段 | 為什麼沒搬 |
|---|---|---|
| `run_once_before_00_bootstrap.sh.tmpl` | once, before | sudo 會話 (session) 初始化 + 語系修正；`run_once_*` 在 chezmoi 狀態中以路徑作為 key，搬動會強制每台機器重新執行 |
| `run_before_01_backup_dotfiles.sh.tmpl` | every, before | 在 chezmoi 覆寫前備份 dotfile。透過 `backupMode` 提供三種模式：`smart`（預設；用 `chezmoi status` 只備份 apply 會修改/刪除的檔案 — 乾淨主機不產生備份）、`full`（寫死的 allowlist，onboarding 模式）、`off`。透過 `just list-backups` / `just diff-backup <TS>` 檢視。 |
| `run_once_before_02_fix_intel_homebrew.sh.tmpl` | once, before | Intel Mac brew prefix 遷移；和 `00` 一樣的 `run_once_*` 狀態追蹤考量 |
| `run_once_before_50_opencode_migrate.sh.tmpl` | once, before | 一次性的 opencode CLI 設定遷移；如果路徑改變會重新執行 |

`run_once_*` 腳本在 `chezmoi state` 中是**以路徑追蹤狀態**的（`scriptState` bucket 的 key 是包含腳本來源路徑的雜湊 (hash)）。搬動它們會在每台既有機器上重新執行那些「只跑一次」的邏輯，或需要在每個主機上協調進行 `chezmoi state delete-bucket --bucket=scriptState` 的手術。先前搬走的 `run_onchange_after_*` 腳本有相同性質，但它們的重跑成本可接受（idempotent ansible / brew bundle）；對 `run_once_before_*` 來說成本更高也更難預測（`00_bootstrap` 會重裝基礎套件、`50_opencode_migrate` 會重新套用一次性的遷移）。

加上沒有範圍歧義要解：這四個都是 global。促使 `_after_` 腳本搬移的 `global/` vs `repo/` 拆分在 `_before_` 這邊不存在，所以目錄不會攜帶任何資訊。

如果未來某個 `run_*before_*` 腳本真的需要 `repo/` 範圍（例如必須在 chezmoi apply 之前執行的專案 skill bootstrap），重新檢視這個決定 — 那時 bucket 才開始攜帶範圍資訊，搬動的重跑成本才值得付出。

## 為什麼要嵌套？

兩個原因：

1. **範圍是硬合約 (hard contract)** — `repo/` 腳本絕對不能在只是消費這個 repo 的機器上觸發（例如從 GitHub URL `chezmoi init` 過的遠端伺服器 (server)）。把範圍編碼在路徑中讓合約一目了然，且更難因疏忽而違反；腳本本身仍然必須以 `eq .chezmoi.sourceDir <repo-root>` 設下閘門 (gate)。
2. **Repo 根目錄整潔** — 在頂層放六個 `run_onchange_after_*.sh.tmpl` 已超過雜訊門檻。雙桶拆分讓 `ls` 看 repo 根目錄仍可掃讀，同時不會失去用數字前綴控制每個桶內執行順序的能力。

## 為什麼這樣行得通（chezmoi 的行為）

`.chezmoiscripts/` 接受子目錄。這不是任何公開「特性 (feature)」的一部分，但行為已在 chezmoi 的 issue 中被確認：

- [twpayne/chezmoi#2013 — `.chezmoiscripts` sub directories](https://github.com/twpayne/chezmoi/issues/2013)
- [twpayne/chezmoi#3246 — ASCII ordering in subdirectories](https://github.com/twpayne/chezmoi/issues/3246)

維護者本人的 dotfiles 也使用相同模式：
[twpayne/dotfiles](https://github.com/twpayne/dotfiles)。

### 套用順序

在 `before_` / `after_` 各個階段內，chezmoi 會以**完整路徑**的 ASCII 順序（區分大小寫）排序腳本。對我們的佈局來說：

```
.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl
.chezmoiscripts/global/run_onchange_after_25_bat_theme.sh.tmpl
.chezmoiscripts/global/run_onchange_after_30_brew_bundle.sh.tmpl
.chezmoiscripts/global/run_onchange_after_32_raycast_config.sh.tmpl
.chezmoiscripts/global/run_onchange_after_40_install_global_skills.sh.tmpl
.chezmoiscripts/repo/run_onchange_after_45_bootstrap_skills.sh.tmpl
```

ASCII 上 `g` < `r`，所以 `global/` 永遠排在 `repo/` 前面。在每個桶內由數字前綴接手 (`20 < 25 < 30 < …`)。整體順序與扁平佈局產生的順序相同 — 是刻意設計的 — 所以這次重構是純結構變更，沒有行為差異。

如果之後在 `global/` 下加入 `darwin/` / `linux/` 子目錄，那些嵌套腳本仍以完整路徑排序；把 `global/run_onchange_after_20_*` 與 `global/darwin/run_onchange_after_30_*` 混在一起會字典序排成：

```
global/darwin/run_onchange_after_30_…    # `d` < `r`, so subdir wins!
global/run_onchange_after_20_…
```

這是個陷阱：**在 `global/` 下加子目錄會重新排列現有腳本**，因為目錄名稱在字典序上是和檔名比對的。如果/當我們加入 OS 子目錄時，要規劃好改名讓順序是刻意的（例如把 OS 目錄前綴成 `_darwin/` `_linux/`，在字典序上把它們推到頂層檔案之後）。

## 什麼放哪裡

- **`global/`** — 任何必須在每台消費這個 repo 的機器上收斂狀態的東西。例子：
  - Ansible role（系統套件、與 dotfile 鄰近的工具）
  - Brewfile 同步
  - bat 主題重建
  - Raycast 設定匯入（以 `syncRaycast` opt-in 為閘門）
  - 全域 skill 還原（`~/.agents/.skill-lock.json` → `~/.agents/skills/`），以及
    binary-matched Herdr skill 同步（`herdr --skill`）

- **`repo/`** — 只有在本機原始碼目錄*就是*本 repo 工作目錄（不是 deploy-from-GitHub 的消費者）時才合理的東西。今天就只有專案範圍的 skill bootstrap（`./skills-lock.json` → `./.agents/skills/`）；腳本第一個動作是檢查 `[[ "$(cd ~/.local/share/chezmoi && pwd)" == "$source_dir" ]]`，否則退出 0。

如果你新增的腳本應該**只在 Apple Silicon** 或**只在有 sudo** 時執行 — 那仍是範圍，但屬於不同軸（OS / 能力），目前的雙桶佈局沒有為它劃出位置。三種選項：

1. 放進對應的範圍桶，並在腳本內以 chezmoi 模板守衛 (`{{ if eq .chezmoi.os "darwin" }}exit 0{{ end }}`) 設閘門。這是我們目前的作法；當 OS-only 腳本 ≤ 2 個時可行。
2. 一旦 OS-only 腳本達到約 3 個以上，就加入 `global/darwin/` 與 `global/linux/` 子目錄。先重新評估上面那個字典序排列的陷阱。
3. 在 `backlog/chezmoiscripts-namespace-refactor.md` 中記錄替代佈局，並全面重新檢視這個結構決定。

## 交叉參照

- 決策記錄：[`backlog/chezmoiscripts-namespace-refactor.md`](../../backlog/chezmoiscripts-namespace-refactor.md)
- 自動執行腳本表：[`docs/this_repo/architecture.md`](architecture.md)
- chezmoi 文件：[`.chezmoiscripts/`](https://www.chezmoi.io/reference/special-directories/chezmoiscripts/)、
  [Application order](https://www.chezmoi.io/reference/application-order/)
