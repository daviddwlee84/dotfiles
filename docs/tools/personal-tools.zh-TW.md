# 個人 CLI 套件

`installPersonalTools` 是一個總開關，管理 `dev`、`translate`、`exp`、
`lazychezmoi`、`lazyclash`、`lazymlflow`、`lazypueue`，以及新增的
`lazyansible`、`lazycrontab`、`lazyfind`、`lazypkg`、`lazymermaid`、`lazyset`，共十三個獨立 CLI。
完整配置 `personal-mac`／`work-mac`／`server-linux` 預設開啟；
`cloud-vm`／`minimal` 與 Docker 測試配置預設關閉。

這裡只安裝 CLI，不安裝 Mihomo core、MLflow server、Pueue daemon、cron jobs、mpm backend、credentials
或 agent skill。Dotfiles 內建的 `fleet`、`mlf` 等腳本維持原本管理方式。

## 啟用與舊機遷移

```sh
dotcfg --set installPersonalTools=true --yes --no-apply
# 檢查配置後，再依正常流程 apply。
```

設成 `false` 只停止管理安裝，不卸載已有程式、不停服務，也不關閉既有的
capability-based shell／proxy 整合。沒有首次呼叫安裝機制；shell startup、
completion、picker、背景服務檢查只使用已安裝的程式。

舊機缺少新 key 時保留舊選擇：macOS 的 dev／translate 仍由 Brew 安裝；Linux
這兩者與兩平台 lazyclash 仍在 extra runtimes 啟用時使用 Go。其他套件成員不會
自動加入。舊機用 `dotcfg --yes --set ...` 改其他項目時，必須一併明確選擇新 key。

## 安裝來源與擁有權

明確啟用後，macOS 使用[既有 personal tap](https://github.com/daviddwlee84/homebrew-tap)
的 formula；Linux amd64／arm64 下載固定版本、驗證 checksum 的 GitHub release，
放在 `~/.local/bin`。這十三件 binary 安裝不需要 Go 或 sudo，也不連帶打開 Rust／Bun／Ruby。
未支援的 OS／CPU 會明確報錯，不默默編譯或安裝 SDK。

單一 registry 是 `dot_ansible/roles/personal_tools/files/tools.json`，記錄 package、
binary、版本與 archive/checksum 名稱；Ansible role 與 upgrade 共用同一個 helper。
Apply 只補裝缺少工具，不自動升級已有 binary。Linux 已有的 source-owned 程式
保留原管理方式；legacy Go 安裝使用 registry 的明確 `legacy_pin`，保留 XDG cache
與缺少 Go 時略過的行為。這次 source packaging 基線同步提高 release 與既有
legacy pin，但 apply 不會升級已安裝的 binary。

Receipt 位於 `${XDG_DATA_HOME:-~/.local/share}/dotfiles/personal-tools/`，用來記錄
安裝來源；目前版本仍以實際 binary 為準，因為原生 updater 可能已更新它。
未知的同名程式保留並回報 unmanaged。套件管理器擁有的檔案交回原 manager。

macOS 把已驗證的 legacy `~/.local/bin` Go 程式轉到 Brew 時，先確認新 Brew
binary 可用，再將舊副本保存到 receipt 目錄的 `backups/`。未知 local build 或
安裝途中被其他工作修改的程式不會移除。手動還原前先看 receipt，避免 PATH
同時存在兩個會互相遮蔽的版本。

## 新增 lazy 工具與執行前置條件

六個新增工具都使用與既有套件相同的 binary 安裝管道，不需 Go SDK。
初次安裝版本與獨立 runtime 前置條件：

| 工具 | Binary 基線 | 執行前置條件 |
| --- | --- | --- |
| [lazyansible](https://github.com/daviddwlee84/lazyansible/releases/tag/v0.1.1) | `v0.1.1` | 個人 fork；使用既有 Ansible，uv runtime setup 另行操作。 |
| [lazycrontab](https://github.com/daviddwlee84/lazycrontab/releases/tag/v0.1.3) | `v0.1.3` | 目標端 cron 工具、遠端 SSH；apply 不建立 job。 |
| [lazyfind](https://github.com/daviddwlee84/lazyfind/releases/tag/v0.1.3) | `v0.1.3` | 目標端 fd／rg；rga 及 converters、zoxide 可選。 |
| [lazypkg](https://github.com/daviddwlee84/lazypkg/releases/tag/v0.1.4) | `v0.1.4` | mpm 8.0.1 與原生 manager；缺少時另走 lazypkg 的 Setup review。 |
| [lazymermaid](https://github.com/daviddwlee84/lazymermaid/releases/tag/v0.1.1) | `v0.1.1` | Explorer／handbook 可獨立使用；Neovim、termaid、Node／Mermaid runtime 依需求另裝。 |
| [lazyset](https://github.com/daviddwlee84/lazyset/releases/tag/v0.1.2) | `v0.1.2` | 子 TUI 需各自安裝；遠端主機使用系統 OpenSSH。 |

lazyansible 是個人 fork，不是 kocierik upstream 套件。同名 upstream 程式會
保留並回報 unmanaged，切換前先處理其 owner。所有 backends、套件操作與 host
註冊都是明確操作，dotfiles apply 不會代為執行。

新增工具以 `upgrade --check`／`upgrade --yes` 管理已驗證的 Homebrew 安裝；
lazypkg 使用 `self upgrade`，因為 `lazypkg upgrade PACKAGE` 是升級所選套件。
`lazyansible runtime upgrade` 同樣只升級 Ansible。整套工具用
`just upgrade-personal`，也涵蓋 Linux 的驗證 binary 更新。既有已辨識 source
安裝保留其 owner；binary 發布不會覆蓋未知 local build，apply 也不會自動升級。

這六件的 release matrix 是 macOS／Linux amd64／arm64。Windows dotfiles 有自己的
registry，本次不會自動將六件加入 Windows 安裝。

## 升級與 completion

```sh
just upgrade-personal
scripts/upgrade_tools.sh personal --dry-run
scripts/generate_completions.sh --tool lazymlflow --force
```

只升級選定、已安裝且能辨識 owner 的工具；Brew、managed release、Go source
各守其來源。未安裝、未選取或未知來源不補裝；source 升級需要現有 Go，不會自行
安裝 SDK。成功後只刷新該工具的 Bash／Zsh completion。下載、checksum、版本驗證
失敗時保留舊 binary，不改走另一個安裝管道。

`just upgrade-go` 改為非 personal Go 工具（目前 Linux gopls）。Personal formula
不放通用 Brewfile，避免 `upgrade-brew` 的 `brew bundle` 補回被刪除的工具；一般
`brew upgrade` 仍可更新已安裝 formula，安裝開關不是版本凍結開關。

## 發行與維護

各應用 repo 發佈自己的 binary；tap 定時或手動讀取 stable public release，驗證
完整產物與 checksum 後更新有變動的 formula。不完整或不一致的 release 保留舊
formula。這樣不必替每個應用 repo 都配置 tap-write token。

Binary 套件只包含執行所需檔案。Source packaging 版本另提供有 checksum 的
source archive，並從 Go module 下載排除開發對話／計畫、保留編譯所需檔案。
這些排除不會縮小完整 Git clone，也不會刪除已公開的歷史。

工具新增／移除時，同步 registry、兩語言 tool inventory、upgrade 文件、completion
與 chezmoi agent skill。只有刻意提高新機基線時才改 pin；一般升級跟隨現有 owner
的 latest stable release；legacy source 工具依 Go `@latest` 的版本選擇規則。

## 驗證

```sh
bats tests/unit/personal_tools.bats tests/unit/lazyclash_setup.bats
just gen-prompts --check
just ansible-syntax-check
just docs-build
```

`Personal tools` GitHub workflow 會在相關程式變更時執行 fixtures。手動 dispatch
的 `live_install` 選項會在拋棄式 Linux/macOS runner 透過真實 Ansible role
安裝十三件 binary 套件，驗證 receipt 與兩種 shell completion，再確認第二次 apply
沒有變更。這個驗收腳本拒絕在工作站或 self-hosted runner 執行。

Fixtures 驗證選擇與舊機遷移、owner、失敗保留、原子替換／回復及 Ansible check
mode，不執行全機安裝。英文版另列完整 repository／binary 名稱與用途。
