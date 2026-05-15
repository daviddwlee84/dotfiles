# tmux: 解決「主動關掉 session 也會 auto-restore」+ 三個右鍵選單上鍵盤

## Context

`dot_config/tmux/common.conf.tmpl:16` 設 `@continuum-restore 'on'`,tmux-continuum 每 15 分鐘存一次快照到 `~/.local/share/tmux/resurrect/last`(symlink),並在**每次 tmux server 啟動且無 session 時無條件 auto-restore**。它無法分辨「使用者主動 `kill-server` / 殺掉最後一個 session」vs「crash / reboot」。使用者選擇方案 B:**保留 auto-restore 當作 crash 保險絲,但給「真的要退出」的路徑一個明確的清理出口**。

同時,目前三組右鍵選單(pane / window-tab / status-left session)的 menu body 是 inline 在 `keybindings.conf.tmpl` 的 `MouseDown3*` 綁定裡,沒有鍵盤對應,使用者想加上 `prefix + Alt+p/w/s` 觸發。

## Decisions (使用者已確認)

- **Clean scope**: 只在「Kill all sessions (server)」+「Kill session & exit 時是最後一個 session」這兩條路徑清理 `last` symlink。`kill-pane` / `kill-window` / 一般 `kill-session`(其他 session 還在 → server 不會死 → 不會觸發 restore)維持不動。
- **鍵盤對應**: `prefix + Alt+p` (pane) / `prefix + Alt+w` (window) / `prefix + Alt+s` (status-left session menu),避開 root-table 命名空間。

## Approach

### Part A — Clean-quit 出口

**新增** 共用 helper `dot_config/tmux/executable_resurrect-forget.sh`:
```bash
#!/usr/bin/env bash
# Remove tmux-resurrect's "last" symlink so the next tmux server start does
# NOT auto-restore via tmux-continuum. Periodic save will re-create it later.
# Used by "Kill server" and "Kill session & exit (last session)" paths only.
set -euo pipefail
rm -f "${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect/last"
```

**修改** `dot_config/tmux/executable_kill-session-exit.sh` — 在 kill 之前數 session 數,如果這是最後一個就先呼叫 `resurrect-forget.sh`:
```bash
session=$(tmux display-message -p '#S')
session_count=$(tmux list-sessions -F '#S' 2>/dev/null | wc -l | tr -d ' ')
if [ "$session_count" -le 1 ]; then
  "$HOME/.config/tmux/resurrect-forget.sh"
fi
tmux detach-client -s "$session"
tmux kill-session -t "$session"
```

**新增** `dot_config/tmux/executable_kill-server-clean.sh`:
```bash
#!/usr/bin/env bash
# Clean tmux quit: clear resurrect/last so next start has nothing to auto-restore.
set -euo pipefail
"$HOME/.config/tmux/resurrect-forget.sh"
tmux kill-server
```

**修改入口點** — 把目前直接呼叫 `kill-server` 的兩個地方換成新 wrapper:
- `dot_config/tmux/keybindings.conf.tmpl:~109` 的 `MouseDown3StatusLeft` 選單裡 `"Kill all sessions" Q { confirm-before -p "..." kill-server }` → 改呼叫 `run-shell "$HOME/.config/tmux/kill-server-clean.sh"`
- `dot_config/tmux/executable_menu-session.sh:23` 的 `"Kill all sessions" Q "confirm-before -p '...' kill-server"` → 同上

`kill-session-exit.sh` 的修改自動覆蓋下列三個入口(都已經呼叫該 script,不必改):
- `keybindings.conf.tmpl` 的 `prefix + M-x` 綁定
- `MouseDown3StatusLeft` 的 "Kill session & exit" 條目
- `menu-session.sh:22` 的 "Kill session & exit" 條目

### Part B — 三個右鍵選單的鍵盤觸發

**萃取** 三個 menu body 出來成獨立 script,沿用倉庫現有的 `executable_menu-*.sh` 模式。每個 script 接受第一個參數 `mouse` / `key` 決定 `-x` / `-y` 定位(mouse 用 `M`,key 用 `P` = current pane):

- 新增 `dot_config/tmux/executable_menu-pane.sh` — 內容來自 `keybindings.conf.tmpl:23-46` 的 pane menu(13 列,Split/swap/resize/zoom/Kill pane 等)
- 新增 `dot_config/tmux/executable_menu-window.sh` — 內容來自 `keybindings.conf.tmpl:50-92` 的 window-tab menu(23 列,layout/rename/bookmark/Kill window 等;注意這個已經接近 tmux ≥ 3.3 popup 高度上限,Part B 不增加列數)
- 新增 `dot_config/tmux/executable_menu-status-left.sh` — 內容來自 `keybindings.conf.tmpl:94-110` 的 session menu(11 列,next/prev/rename/move/Kill session & exit/Kill all sessions(改用 kill-server-clean))

**改寫** `MouseDown3Pane` / `MouseDown3Status` / `MouseDown3StatusLeft` 三個綁定,讓它們 `run-shell "$HOME/.config/tmux/menu-<X>.sh mouse"`(`MouseDown3Pane` 保留外層的 `if-shell` copy-mode 偵測,只把 menu body 那一段換掉)。

**新增** 三個 prefix keybinding 在 `keybindings.conf.tmpl`(放在現有 menu 區塊附近):
```tmux
bind -T prefix M-p run-shell "$HOME/.config/tmux/menu-pane.sh key"
bind -T prefix M-w run-shell "$HOME/.config/tmux/menu-window.sh key"
bind -T prefix M-s run-shell "$HOME/.config/tmux/menu-status-left.sh key"
```

**Pitfall 風險**: tmux popup 在內容超過終端高度時會「整個靜默不顯示」(已記錄在 CLAUDE.md "Tmux popup menu" 規則 + `pitfalls/tmux-display-menu-silent-fail.md`)。window-tab menu 已經 23 列,鍵盤觸發在小終端機上會看不到。可接受:這個 plan 不擴增任何列數,只是改變觸發方式;mouse 觸發本來在小終端也會 silent fail,並無 regression。文件提醒在 cheatsheet 加註。

## Files to modify / create

**新增** (4 個 helper script + 3 個 menu script,共 7 個):
- `dot_config/tmux/executable_resurrect-forget.sh`
- `dot_config/tmux/executable_kill-server-clean.sh`
- `dot_config/tmux/executable_menu-pane.sh`
- `dot_config/tmux/executable_menu-window.sh`
- `dot_config/tmux/executable_menu-status-left.sh`

**修改**:
- `dot_config/tmux/executable_kill-session-exit.sh` — last-session 偵測 + 呼叫 resurrect-forget
- `dot_config/tmux/keybindings.conf.tmpl` — 三個 MouseDown3* 改用 run-shell 委派;新增 prefix M-p/w/s 三個綁定;MouseDown3StatusLeft 的 "Kill all sessions" 改用 kill-server-clean
- `dot_config/tmux/executable_menu-session.sh` — "Kill all sessions" entry 改用 kill-server-clean

## Cross-file maintenance (per CLAUDE.md)

- `docs/shells/keybindings.md` — 加 `prefix + M-p` / `prefix + M-w` / `prefix + M-s` 三列(每列含 trigger / scope / 對應 mouse event / 一行描述)。同時補上 `kill-server-clean.sh` / `resurrect-forget.sh` 的行為說明。
- `dot_config/tmux/cheatsheet.md` — 在 menu / kill 區塊加上新的鍵與行為註記(含 popup-too-tall 提醒)。
- `docs/tools/tmux/` (`README.md` 或對應頁)— 加一段「Continuum auto-restore 與 clean quit」說明,點出 `last` symlink 機制、哪兩個入口會清掉、何時不會(crash / reboot / 一般 kill-session 仍會 restore)。
- `pitfalls/tmux-continuum-restores-on-intentional-quit.md`(新增)— 紀錄這個 trap 的症狀(主動關掉也會 restore)+ 根因(continuum 無法分辨意圖)+ 解法(雙路徑清理 `last` symlink)+ 為什麼不全面關掉 auto-restore(crash 救援)。
- 不需要動 `CLAUDE.md` 的 Hard rules — 沒有新的跨檔不變式;沒有觸碰 workmux 6 檔。

## Verification

1. `chezmoi apply --dry-run` — 確認新 script 的 executable_ 前綴生效,沒有 template 錯誤。
2. `chezmoi apply` 後 `tmux source-file ~/.config/tmux/tmux.conf` — syntax check(per CLAUDE.md「validate app configs with the app」hard rule)。
3. **滑鼠右鍵 regression test**: 對 pane / window-tab / status-left session 各右鍵一次,確認選單還是出來且內容跟改動前一致。
4. **鍵盤觸發**: `prefix + M-p` / `M-w` / `M-s` 各按一次,確認三個選單出現在 pane 中央。
5. **Clean-quit 行為驗證** (在乾淨環境):
   - 建立兩個 session(`tmux new -s a`, `tmux new -s b`),在 `a` 跑 `prefix + M-x` confirm Y;檢查 `ls -la ~/.local/share/tmux/resurrect/last` — **應該還在**(因為 `b` 還活著)。
   - 然後在 `b` 跑 `prefix + M-x` confirm Y;檢查 `last` — **應該被刪除**(最後一個 session)。
   - `tmux new -s c`, 從 status-left menu 選 "Kill all sessions" confirm Y;檢查 `last` — **應該被刪除**。
   - 上述每次清理後 `tmux` 重新進入,確認**沒有 auto-restore**(該是空的)。
6. **Crash 救援仍存在**: 跑一陣子讓 continuum 至少存一次(15min,或手動 `prefix + Ctrl-s`),`pkill -9 tmux: server` 模擬 crash,重新 `tmux` — 應該照舊 auto-restore。
7. **小終端 popup-fit**: 把終端機高度縮到 ~15 列,試 `prefix + M-w`(window menu 23 列),確認知道會看不到(預期 silent fail,在 cheatsheet / pitfall 有紀錄)。

## Out of scope

- 不關掉 `@continuum-restore 'on'`(這是方案 A,使用者沒選)。
- 不修改 `kill-pane` / `kill-window` / 一般 `kill-session`(維持「只有真的退出才清」的最小擾動)。
- 不刪除 `~/.local/share/tmux/resurrect/` 底下歷史檔案(只動 `last` symlink,讓 crash recovery 還能用 manual restore `prefix + Ctrl-r` 撈回)。
- 不改 `@continuum-save-interval`。
