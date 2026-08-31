# Yazi 檔案管理員

Yazi 是 shell `y` helper 與 Herdr `prefix+Y` launcher 使用的終端檔案管理員。
`y` 會在離開 Yazi 後把父 shell 切到最後瀏覽的目錄；Herdr popup 則是刻意設計成
一次性工具，不會改變 agent pane 的 cwd。

## Git 狀態標記

受管的 [`git.yazi`](https://github.com/yazi-rs/plugins/tree/main/git.yazi)
fetcher 會在檔案與目錄後方顯示彩色標記，涵蓋 untracked、unstaged、staged、
added、deleted、updated 與 ignored。目錄會向上彙總子孫的變更，因此還沒進入
dirty subtree 前就看得出來。

目前釘選的 plugin 需要 Yazi **26.8.15+**。設定有相容性保護：

- 相容版本由 `git-guard.yazi` 委派給真正的 plugin；
- 舊版或安裝不完整時會顯示警告並改用 Yazi 的 `noop` fetcher，瀏覽不會卡住；
- macOS 以 `brew upgrade yazi`、Linux 以原本的套件升級路徑更新配對的
  `yazi`／`ya`，必要時再執行 `ya pkg install`。

Plugin revision 記在 `~/.config/yazi/package.toml`。以
`just upgrade-yazi-plugins` 明確升級；`chezmoi apply` 只安裝已 commit 的 revision，
並修復消失的 plugin 目錄。

## Herdr launcher

`prefix+Y` 會在聚焦 pane 的 cwd 開一個 90% × 85% 的 session-modal popup。
按 `q` 關閉後回到完全不變的 pane layout。Popup 是子行程，因此最後瀏覽的目錄不會
回傳給來源 shell；需要離開後跟著切目錄時請使用 shell `y` helper。
