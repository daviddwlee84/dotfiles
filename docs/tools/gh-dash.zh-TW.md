# gh-dash

[gh-dash](https://github.com/dlvhdr/gh-dash)（`gh dash`）是在終端機裡看 GitHub **PR**、**Issue** 和**通知**的儀表板。本 repo 由 `devtools` ansible role 以 `gh` extension 的方式安裝。`gh auth status` 通過前會跳過安裝，所以新機器請先跑 `gh auth login`。Diff 會用 [`diffnav`](git_diff_workflow.md) 開啟。

以下按鍵以 gh-dash **v4.26** 為準。在 gh-dash 裡按 `?` 可以看當前 view 的按鍵，那個畫面永遠跟已安裝的版本一致。

## 啟動方式

| 方式 | 開在 |
|---|---|
| `gh dash` | PR view（repo 裡有 `.gh-dash.yml` 時會套用） |
| `gh dash --config ~/.config/gh-dash/issues.yml` | Issue view |
| `gh dash --config ~/.config/gh-dash/notifications.yml` | 通知 view |
| Herdr `prefix + Alt + p` | PR，暫時 pane |
| Herdr `prefix + Alt + i` | Issue，暫時 pane |
| Herdr `prefix + Alt + n` | 通知，暫時 pane |

Herdr 快捷鍵跟 lazygit（`prefix + G`）一樣，會在目前 pane 的目錄開一個暫時 pane，按 `q` 就關掉。在 git repo 裡時，gh-dash 的 **smart filtering** 會讓每個分區只顯示這個 repo；按 `t` 可以關掉，看全部。這幾個鍵用 `type = "pane"` 而不是 popup，因為 popup 是 session-modal，開著時不能切換 tab。

## View 切換

總共只有三個 view。**`s` 依序切換：PR → Issue → 通知 → PR。** 每個 view 第一次進入時，各分區才會執行查詢。

## 移動（所有 view 通用）

| 鍵 | 動作 |
|---|---|
| `j` / `k`（↓/↑） | 下一列 / 上一列 |
| `g` / `G` | 第一列 / 最後一列 |
| `h` / `l`（←/→） | 上一個 / 下一個**分區**（頂端那排 tab） |
| `p` / `P` | 開關預覽 / 切換預覽位置（右 ↔ 下） |
| `Ctrl+d` / `Ctrl+u` | 預覽往下 / 往上捲 |
| `r` / `R` | 重新整理目前分區 / 整個 view |
| `o` | 用瀏覽器開 |
| `y` / `Y` | 複製編號 / 複製 URL |
| `?` | 目前 view 的說明 |
| `q` | 離開 |

## 搜尋與篩選

- **`/`**：游標移到搜尋列，裡面就是目前分區的 **GitHub 搜尋語法**。修改後按 Enter 會重新查詢。改動只在這次有效，不會寫回 config。
- **`t`**：切換 smart filtering，也就是自動加上的 `repo:<目前 repo>` 範圍。
- **`Ctrl+s`**：進入分區模式。接著 `n` 新增分區，`x` 刪除分區。

查詢用的是 GitHub 一般的搜尋語法：

| 目的 | 查詢 |
|---|---|
| 等我 review 的 PR | `is:open review-requested:@me` |
| 我開的 PR | `is:open author:@me` |
| 指派給我的 Issue | `is:open assignee:@me` |
| 某 repo 的 bug | `repo:owner/name is:open label:bug` |
| 標題全文搜尋 | `is:open "flaky test" in:title` |
| 最近更新 | `is:open updated:>2026-10-01` |

通知分區用的是另一套篩選：`is:unread|read|all|done`、`reason:author|comment|mention|review-requested|assign|subscribed|team-mention|state-change|ci-activity|participating`、`repo:owner/name`。

## 各 view 的操作

**PR**

| 鍵 | 動作 | 鍵 | 動作 |
|---|---|---|---|
| `d` | diff（用 diffnav） | `C` / `Space` | checkout |
| `v` | approve | `c` | 留言 |
| `m` | merge | `u` | 從 base branch 更新 |
| `w` | 監看 CI checks | `V` | approve 全部 workflow |
| `W` | 標為 ready for review | `e` | 展開描述 |
| `a` / `A` | 指派 / 取消指派 | `L` | 加 label |
| `x` / `X` | 關閉 / 重開 | `[` / `]` | 上一個 / 下一個 sidebar tab |

**Issue**

| 鍵 | 動作 |
|---|---|
| `c` | 留言 |
| `C` | checkout |
| `a` / `A` | 指派 / 取消指派 |
| `L` | 加 label |
| `x` / `X` | 關閉 / 重開 |

**通知**

| 鍵 | 動作 |
|---|---|
| `Enter` / `Esc` | 在 gh-dash 裡看該 PR/Issue / 回到列表 |
| `m` / `M` | 標為已讀 / 全部已讀 |
| `D` / `Alt+d` | 標為完成 / 全部完成 |
| `u` | 取消訂閱 |
| `b` | 切換書籤 |
| `S` | 依 repo 排序 |

## Discussions

gh-dash **沒有 Discussions view**。Discussion 只會以通知的形式出現在通知 view 裡（例如 `reason:mention`、`reason:subscribed`），按 `o` 會用瀏覽器開。要瀏覽 discussions：

- `x open "$(gh browse -n)/discussions"`：用瀏覽器開目前 repo 的 discussions 頁面（`gh browse` 沒有 discussions 參數）
- `gh api graphql`：寫腳本查詢

## 設定檔

| 檔案 | 用途 |
|---|---|
| `~/.config/gh-dash/config.yml` | 全域設定（SSOT）。目前只有 `pager.diff: diffnav`，所以分區用的是預設值。 |
| `~/.config/gh-dash/issues.yml` | `include: [./config.yml]` 加上 `defaults.view: issues` |
| `~/.config/gh-dash/notifications.yml` | `include: [./config.yml]` 加上 `defaults.view: notifications` |

這三個檔案都來自本 repo 的 `dot_config/gh-dash/`。gh-dash 沒有指定起始 view 的命令列參數，所以才用個別的設定檔來指定。用 `include` 時，引入方的設定優先；keybindings 會合併；分區則以定義它的那個檔案為準。

注意：`--config` 的優先度高於 repo 裡的 `.gh-dash.yml`，所以只有一般的 `gh dash`（`prefix + Alt + p`）會套用那個檔案。

要加自訂分區或快捷鍵，改 `dot_config/gh-dash/config.yml` 就好，兩個 view 檔會自動套用。自訂鍵避免蓋掉內建鍵（例如 `g` 是「第一列」）。

## 參考

- [gh-dash 文件](https://www.gh-dash.dev/)：設定、快捷鍵，以及給 IDE 自動補全用的 schema
- [git diff workflow](git_diff_workflow.md)：`diffnav` / `delta` / lazygit 怎麼搭配
- [Herdr 快捷鍵](herdr.md)
