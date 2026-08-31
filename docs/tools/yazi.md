# Yazi File Manager

Yazi is the terminal file manager used by the shell `y` helper and the Herdr
`prefix+Y` launcher. `y` changes the parent shell to the directory where Yazi
exits; the Herdr popup is intentionally disposable and leaves the agent pane's
cwd unchanged.

## Git status signs

The managed [`git.yazi`](https://github.com/yazi-rs/plugins/tree/main/git.yazi)
fetcher appends colored signs to files and directories for untracked, unstaged,
staged, added, deleted, updated, and ignored states. Directory signs bubble up
from changed descendants, so a dirty subtree is visible before entering it.

The current pinned plugin requires Yazi **26.8.15+**. Its setup is guarded:

- compatible versions delegate through `git-guard.yazi` to the real plugin;
- older or incomplete installations show a warning and use Yazi's `noop`
  fetcher, so browsing remains responsive;
- upgrade the matched pair with `brew upgrade yazi` on macOS, the normal
  Linux package upgrade path, then run `ya pkg install` if needed.

Plugin revisions live in `~/.config/yazi/package.toml`. Upgrade them explicitly
with `just upgrade-yazi-plugins`; `chezmoi apply` only installs the committed
revisions and repairs missing plugin directories.

## Herdr launcher

`prefix+Y` opens Yazi at the focused pane's cwd in a 90% × 85% session-modal
popup. Press `q` to close it and return to the unchanged pane layout. Because a
popup is a child process, its final browsing directory is not propagated back
to the source shell; use the shell `y` helper when that is the desired outcome.
