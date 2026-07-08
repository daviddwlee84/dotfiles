# GitHub CLI (`gh`) auth

[`gh`](https://cli.github.com/) 是 GitHub 官方 CLI。本 repo 透過 `devtools` ansible role 安裝,並用它做 issue/PR 工作流程、`gh-dash` extension,以及(這頁的重點)**作為 `git push`/`git fetch` over HTTPS 的 credential helper**。

這頁講兩件事:

1. 怎麼 auth `gh` 讓 HTTPS git 操作不用每次輸入 token。
2. **本 repo 的 chezmoi-managed `~/.gitconfig` 怎麼跟 `gh auth setup-git` 共存** — 對新進這個 dotfiles 的人很重要,因為背後有一個非顯而易見的 modify_ 腳本。

## 快速 auth

```bash
# 互動式: 選 https + "Login with a web browser"
gh auth login

# 被問到 "Authenticate Git with your GitHub credentials?" 時答 Yes。
# 這會幫你跑 `gh auth setup-git`,把 credential helper 寫進
# ~/.gitconfig (見下節)。
```

驗證:

```bash
gh auth status                  # token scope + 哪個帳號
git config --get-all credential."https://github.com".helper
# 預期:
#   (空行)
#   !/opt/homebrew/bin/gh auth git-credential   ← 路徑因機器而異
```

只重跑 git-credential 設定(不重新登入):

```bash
gh auth setup-git
```

移除:

```bash
gh auth logout                  # 清掉 token + helper
```

## `gh auth setup-git` 怎麼跟 chezmoi 互動

`gh auth setup-git` 會在 `~/.gitconfig` 寫入兩個 section:

```gitconfig
[credential "https://github.com"]
	helper =
	helper = !/opt/homebrew/bin/gh auth git-credential
[credential "https://gist.github.com"]
	helper =
	helper = !/opt/homebrew/bin/gh auth git-credential
```

關於這個區塊兩件不直觀的事:

1. **空的 `helper =` 那行是故意的**,不是 bug。它會把 `github.com` 任何繼承下來的 helper(例如 macOS Keychain 的 `osxkeychain`)清空,讓 `gh` 是唯一的 authority。沒有它的話,OS keychain helper 會跟 `gh` 賽跑,你 rotate token 後會看到 "Bad credentials" 錯誤。
2. **`gh` 的路徑是絕對且因機器而異**:
   - Apple Silicon homebrew: `/opt/homebrew/bin/gh`
   - Intel mac homebrew: `/usr/local/bin/gh`
   - Linuxbrew: `/home/linuxbrew/.linuxbrew/bin/gh`
   - apt / dnf / 官方 `.deb`: `/usr/bin/gh`

這個路徑是你在那台機器上跑 `gh auth setup-git` 當下被 `gh` hard-code 進去的。沒有 portable 的形式(刻意繞過 `PATH`,免得 `git` 之後撈到別的 `gh` binary)。

### 為什麼平鋪的 `~/.gitconfig` template 會壞掉

如果 `~/.gitconfig` 是普通的 chezmoi template,每次 `chezmoi apply` 就會整檔覆蓋 — 包含 `gh` 剛剛寫進去的 `[credential "..."]`。下一次 `git push` 不是:

- 沒有 helper → 互動式重新問帳密,就是
- Ping-pong: 你再跑 `gh auth setup-git`,下一次 `chezmoi apply` 又把它清掉。

這正是 chezmoi 的 `modify_` prefix 為了解決的「外部工具改寫被管檔案」場景。

### 本 repo 實際做法

`~/.gitconfig` 由 [`modify_dot_gitconfig.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/modify_dot_gitconfig.tmpl) 管理,這是個 `modify_`-prefixed 的 bash 腳本,每次 `chezmoi apply` 都會跑。腳本做的事:

1. 從 stdin 讀目前的 `~/.gitconfig`(chezmoi `modify_` 約定)。
2. 輸出 chezmoi-managed baseline — `[user]`、`[http]`、`[filter "lfs"]`、`[init]`、`[core]`、可選的 `[delta]` 區塊,以及 `[include] path = ~/.gitconfig.local`。
3. **原樣**重新輸出 live 檔裡找到的 `[credential "<URL>"]` 區塊,包含 gh 注入的絕對路徑。

效果: 每台機器跑一次 `gh auth setup-git`,之後 `chezmoi apply` 永遠保留 helper — 沒有 ping-pong、不用 per-machine template 分支、不用 commit 機器特定的路徑。

`modify_` prefix 的說明在 [chezmoi prefixes](chezmoi-prefixes.md)。這個檔案的 case study 也在那邊提到。

## per-machine git config 可以放的三個地方

| 位置 | 由誰管 | 何時用 |
|---|---|---|
| chezmoi baseline (`modify_dot_gitconfig.tmpl`) | 本 repo | 跨機器共享的設定(`user.email`、`init.defaultBranch`、`core.pager = delta`、…)。改 template 然後 `chezmoi apply`。 |
| `~/.gitconfig` 內的 `[credential "<URL>"]` | `gh auth setup-git` | 透過 gh 的 HTTPS auth。每台機器跑一次 `gh auth login`;chezmoi 會保留。**不要手改這些區塊** — 讓 gh 自己管。 |
| `~/.gitconfig.local` | 你自己手動 | chezmoi 沒辦法預測的 per-machine override:`http.proxy`、`safe.directory`、工作帳號 email override、為了切多身份用的 `[includeIf "gitdir:..."]`、為了走公司 mirror 用的 `[url "..."]` rewrite 等等。從 baseline 透過 `[include]` 載入。chezmoi 會 ignore 這檔。 |

三層由左到右合成(同一個 key 後者勝),跟本 repo 其他地方的 `~/.zshrc` → `~/.zshrc.local` → `~/.zshrc.adhoc` 模式一致。

## modify_ 腳本**不**保留的東西

`modify_dot_gitconfig.tmpl` 裡的 awk filter **只**匹配 `^[credential "<URL>"]`(帶引號 URL scope)。live `~/.gitconfig` 裡其他東西在下次 apply 都會被 baseline 取代。特別是:

- 裸 `[credential]`(沒 URL scope)**不**保留。
- 你手改進 `~/.gitconfig` 的 `[user]`、`[core]`、`[alias]` 等等**會被靜默覆蓋**。請改用 `~/.gitconfig.local`。
- `[credential.helper]` 這種 flat key 形式(沒 section header)**不**保留。請用 URL-scoped section 形式,這也是 `gh auth setup-git` 寫的格式。

如果你需要保留別種 section(例如某個工具寫的 `[includeIf "gitdir:~/work/"]`),awk 規則是唯一要擴的地方 — 看腳本就懂 pattern。

## Troubleshooting

**`fatal: could not read Username for 'https://github.com': terminal prompts disabled`** 在 CI / 非互動式 shell 跑 `chezmoi apply` 之後出現:

- 檢查 credential 區塊有沒有保留: `git config --get-all credential."https://github.com".helper` 應該印兩行(空行 + `!.../gh auth git-credential`)。
- 如果第二行沒有,代表這台機器從沒跑過 `gh auth setup-git`。跑 `gh auth login`(或如果 token 已存在,跑 `gh auth setup-git`)。
- 如果兩行都在但 git 還是會問,可能 `gh` 自己沒 auth: `gh auth status` 應該印綠勾,不是 "not logged in"。

**`gh auth status` 印有 token 但 `git push` 還是會問**:

- helper 那行的絕對路徑指向不存在的 `gh` binary(你用 Migration Assistant 從一台 mac 搬到另一台,或重灌 Linuxbrew)。重跑 `gh auth setup-git` refresh 路徑;chezmoi 會保留新的。

**`chezmoi diff ~/.gitconfig` 在每次 `gh` 操作後都顯示有 churn**:

- 預期是空的。如果不是,awk filter 大概沒認出 gh 寫的 section header(舊/新版 `gh` 可能用不同的 scope URL)。把 live 檔跟 rendered output 並排看: `chezmoi cat ~/.gitconfig | diff - ~/.gitconfig`。如果 diff 在 `[credential "<URL>"]` 區塊內,代表腳本有 bug — 開 issue。

## 尋找並 clone 你的 repos

`gh repo list` 非互動且只列 30 筆。要依名稱 + 描述模糊瀏覽**全部** repos — 預覽 README，然後 clone／開啟／複製 — 本 repo 提供兩個孿生介面：

- **`ghrepo`**（shell 函式，`dot_config/shell/41_github.sh`）— 以 fzf 包裝 `gh repo list --limit 4000`，並用 `gh repo view` 預覽 README：
  - `Enter` → clone 到 `${GHREPO_ROOT:-$PWD}/<repo>` 並 **cd 進去**
  - `Alt-O` → 在 github.com 開啟 · `Ctrl-Y` → 複製 repo URL
- **`tv github-repos`**（Television 頻道）— 同樣的瀏覽／開啟／複製。tv 動作無法 `cd` 你的 shell（子行程），因此 `Alt+C` 只 clone 到啟動 cwd 而不 cd；clone 後要工作請用 `ghrepo`。

GitLab 有完全對應的孿生 — **`glrepo`** + **`tv gitlab-repos`**（透過 `glab repo list --mine`）。自架 GitLab：`export GITLAB_HOST=git.example.com`。

repo 清單會**快取**在 `~/.cache/tv/`（stale-while-revalidate；`GHREPO_CACHE_TTL` 預設 1 小時）：首次抓取 300+ repos 約需 ~15 秒，之後每次啟動都瞬間開啟並在背景重新驗證。在 `ghrepo`/`glrepo` 中按 `Ctrl-R`（或 tv 頻道的 `Alt+R`）可強制即時刷新。快取由共用 helper `~/.config/television/g{h,l}-repos-source.sh` 產生，函式與頻道共用。

設定 `GHREPO_ROOT` / `GLREPO_ROOT` 可 clone 到固定的 repo root 而非當前目錄 — 便於搭配 [try-cli](https://github.com/tobi/try) 的 graduate 流程（`TRY_PROJECTS`）。

## 相關

- [chezmoi prefixes](chezmoi-prefixes.md) — 本 repo 裡 `modify_` / `create_` / `_remove` 的語意
- [Agent overlays](agent-overlays.md) — 同一個 modify_ 模式套在 Claude / OpenCode / Codex / Cursor configs
- [git diff workflow](git_diff_workflow.md) — 本 repo 怎麼用 `gh pr diff`、delta、`gh-dash` 等
