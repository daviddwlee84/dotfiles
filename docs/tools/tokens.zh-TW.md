# tokens（tokens.ci）

[tokens](https://github.com/missuo/tokens)（MIT 授權，是
[tokscale](https://github.com/junhoyeo/tokscale) 的 fork）會讀取各 coding agent 的本機
session 紀錄——Claude Code、Codex、Cursor、Gemini、OpenCode、Antigravity、Trae、Warp 等——
並統計 token 用量與花費。你主動開啟時，它也會把用量上傳到
[tokens.ci](https://tokens.ci) 排行榜。

## 本 repo 如何安裝

安裝邏輯在
[`dot_ansible/roles/coding_agents/tasks/main.yml`](../../dot_ansible/roles/coding_agents/tasks/main.yml)
的 `# === tokens (tokens.ci) ===` 區塊，**只安裝執行檔**。開啟 `installCodingAgents` 時才會執行。

| 平台 | 方式 | 結果 |
|---|---|---|
| macOS | `brew install owo-network/brew/tokens`（因為 Homebrew 6 的 trust 機制，會先 trust 這個 tap） | brew prefix 下的 `tokens` |
| Linux x86_64 / aarch64 | 最新 GitHub release 的 `tokens-<tag>-<arch>-unknown-linux-gnu.tar.gz` | `~/.local/bin/tokens` |

`-gnu` 版本只需要 `GLIBC_2.28`（和 Linuxbrew 的下限相同），所有支援的發行版都能執行。
上游沒有替 tarball 提供 `.sha256` 檔，所以下載時沒有 checksum 可以驗證。

升級：macOS 用 `just upgrade-brew`，Linux 用 `just upgrade-agents`。Linux 會以
`TOKENS_NO_SERVICE=1 TOKENS_INSTALL_DIR=~/.local/bin` 執行官方 installer。

### Linux 一行安裝指令為什麼失敗

```console
$ curl -fsSL https://tokens.ci/install.sh | sh
sh: 17: set: Illegal option -o pipefail
```

`install.sh` 是 bash script，但官方文件把它 pipe 給 `sh`；在 Debian/Ubuntu 上 `sh` 是 dash。
改成 pipe 給 `bash`：

```bash
curl -fsSL https://tokens.ci/install.sh | TOKENS_NO_SERVICE=1 bash
```

不加 `TOKENS_NO_SERVICE=1` 的話，installer 還會寫入 `~/.config/systemd/user/tokens.service`，
但不會啟用這個 service。

## 手動開啟：登入與背景上傳

role **不會**登入，也不會啟動背景上傳。`tokens serve` 會把你的用量上傳到公開排行榜，
所以不應該在每台 fleet 主機上自動啟動。

```bash
tokens login          # 一次性的瀏覽器驗證（或：tokens login --token …）
tokens status         # 驗證、裝置與背景 service 的狀態
tokens submit         # 上傳一次
```

定期上傳（預設每 30 分鐘，可用 `TOKENS_SUBMIT_INTERVAL` 調整）：

- **macOS**：`brew services start tokens`（log 位於 `$(brew --prefix)/var/log/tokens.log`）
- **Linux**：建立 `~/.config/systemd/user/tokens.service`，設定
  `ExecStart=%h/.local/bin/tokens serve`（或執行 installer 時不加 `TOKENS_NO_SERVICE`），
  再執行 `systemctl --user enable --now tokens`。若要在沒有登入時持續執行，
  另外執行 `sudo loginctl enable-linger "$USER"`。

刪除所有已上傳的資料：`tokens delete-submitted-data`。
