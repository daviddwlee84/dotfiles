## 診斷報告：idc-server104 (CentOS 7, no-sudo, slow link) chezmoi apply

### 時間花在哪

4h41m total，**4h04m (87%) 在 `Install Claude Code (Linux)` 一個 task**，靠 `curl https://claude.ai/install.sh | bash`。其餘 ~37m 為 OpenCode (16m) + 4 個 GitHub release downloads (CodexBar 8m + sidecar 4m + SpecStory 3m + td 2m)。

任何優化排序：先解決 Claude 的 4h，其他的優化都是 noise。

### 真正失敗（被 ignore 蓋掉）的 task

| # | Task | 表面錯誤 | 真實 root cause |
|---|---|---|---|
| 36 | tree-sitter-cli cargo fallback | `Unable to find libclang ... libclangAST.so.7: No such file` | CentOS 7 的 `clang-devel` 套件分裂、缺檔。bindgen 在 CentOS 7 用 yum clang 注定失敗 |
| 49 | GitHub Copilot CLI (mise npm) | `EACCES /usr/lib/node_modules/@githubnext` | `mise exec -- npm i -g` **沒有真的進 mise 隔離環境** — npm 命中了系統 `/usr/bin/node` v16，prefix 指 `/usr/lib`。同一個 bug 也擊中下面三個 |
| 51 | OpenAI Codex CLI (mise npm) | 同上 | 同 #49 |
| 53 | Gemini CLI (mise npm) | 同上 + node v16 < 20 engine reject | 同 #49 |
| 112 | OpenChamber (mise npm) | 同上 + 一堆 EBADENGINE warns | 同 #49 |
| 124 | mise rust@latest | `1.95.0-x86_64-unknown-linux-gnu ... 404` from TUNA | TUNA rustup 鏡像沒同步到 1.95.0，`rust@latest` 不該 unpinned |

### 三個非致命但值得記的觀察

1. **Linuxbrew CodexBar/td/sidecar 的 `community.general.homebrew` task** 三次都吐 `Expecting value: line 1 column 1 (char 0)` — `brew info --json=v2` 回空字串。GitHub release fallback 有兜住，但每個多花 ~1 min 加上至少一次無謂的 brew tap。表示 Linuxbrew 在這台網路上 ruby/curl 段也不健康。

2. **CodexBar / td / sidecar 是 macOS-first menubar 工具** — 在 headless CentOS 7 IDC 上裝了也用不上，即使 binary 存在也沒 GUI。建議在 profile 層 gate 掉。

3. **「ignore_errors: true」太多** — npm 4 task + cargo + rust 共 6 個 silent failure 完全沒進 PLAY RECAP 的 `failed=` count（只有 rust 1 個是 hard fail）。下次跑你只會看到 `failed=1` 然後以為其他都 OK。

### 根因為什麼 npm task 沒命中 mise node

```sh
mise exec -- npm install -g @githubnext/github-copilot-cli
```

`mise exec` 只 inject 環境變數，**不會改 npm 的 prefix**。當 mise 沒有 `node` 為 active tool 時 (`mise current node` 應該是空的)，`npm` 由 `$PATH` lookup 落到 `/usr/bin/npm`。修法是加上 `mise use -g node@lts` 在 `lazyvim_deps` role 完成後（你已經有這個 mise task），且設 `npm config set prefix ~/.local/share/npm-global`，然後 PATH 加 `~/.local/share/npm-global/bin`。

### 該記到 pitfalls/ 的兩條

- `pitfalls/centos7-clang-devel-broken-libclang.md` — bindgen-based cargo crates 在 CentOS 7 系統 clang 上必跪，要 `yum install llvm-toolset-7-clang-devel` (SCL) 或跳過。
- `pitfalls/mise-exec-npm-fallthrough-to-system.md` — `mise exec -- npm i -g` 在 mise 沒 active node 時 silently 落到 system，加上 prefix 預設 `/usr/lib` 就吃 EACCES。這個 trap 4 個 task 都中了。

### 建議下次動手順序（你說的 P? 標籤）

- `[P1][S]` Pin `rust@stable` 取代 `rust@latest` — 一行修，幾分鐘救一個 hard fail
- `[P1][M]` 修 mise npm prefix 4 task — 把 4 個 silent broken 救回來
- `[P2][S]` profile gate 掉 CodexBar/td/sidecar 在 headless Linux — 省 ~14 min download + 修不掉的 Linuxbrew 噪音
- `[P2][M]` Claude install resumable cache — 救 4h，但需要 reverse install.sh 拆出 tarball URL，偏重
- `[P3][S]` CentOS 7 detect 後 skip cargo tree-sitter fallback，改印警告
