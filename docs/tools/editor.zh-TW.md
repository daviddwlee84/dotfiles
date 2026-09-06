# 預設編輯器與 Micro

`preferredEditor` 與 `enableVimMode` 是獨立偏好。新舊主機預設皆為
`nvim`；shell Vim 開關不會改變此選擇，也不會設定 Claude 自己的 Vim mode。

## 選擇與切換

```text
editorcfg list
editorcfg use micro
editorcfg status
editorcfg doctor
editorcfg reset
```

可選 `nvim`、`micro`、`vim`、`nano`、`code`、`cursor`。
Micro 隨基礎 devtools 安裝，使用非 modal 的終端操作：
**Ctrl+S** 儲存、**Ctrl+Q** 關閉、**Ctrl+F** 搜尋。
見 [Micro 快捷鍵](https://github.com/micro-editor/micro/blob/master/runtime/help/defaultkeys.md)。
選擇 preset 不會安裝 GUI 軟體；`use` 遇到找不到的程式會保留原設定並報錯。

init 答案產生受管的 `~/.config/dotfiles/editor-default`。
`editorcfg use` 原子寫入 `$XDG_CONFIG_HOME/dotfiles/editor-choice`
（預設 `~/.config/dotfiles/editor-choice`），此檔案由 chezmoi 忽略。
本機選擇優先於 init；`reset` 只刪除此本機選擇。有 override 時修改 init
不會改變有效偏好。切換不需要整套 apply，下次開啟受管編輯器即讀取新值。
損壞的偏好檔會報錯，不會當成 shell 程式執行。

## EDITOR、VISUAL 與個別工具覆寫

受管 profile 將兩個環境變數都設成 executable 名稱 `dotfiles-editor`。
`VISUAL` 傳統上指全螢幕編輯器，包含 nvim，並非專指 GUI。
各工具有自己的優先序，因此相同預設比較一致。
Git 使用 `GIT_EDITOR → core.editor → VISUAL → EDITOR`；
互動式 rebase 另有 `GIT_SEQUENCE_EDITOR`／`sequence.editor`。
這些覆寫會保留，doctor 顯示 Git 的有效編輯器與設定來源。
見 [Git 文件](https://git-scm.com/docs/git-var)。

第一次 apply 後請 reload shell profile，並重新啟動繼承舊 `EDITOR=nvim` 的程式。
已繼承 `dotfiles-editor` 的程式，之後可直接使用新的 `editorcfg use` 選擇。
手動環境變數覆寫可能繞過 editorcfg；status 會指出。
既有只接受單一 executable 的 helper，對自訂 command string 仍需要 wrapper；
請使用 `editorcfg use code`，不要把 `code --wait` 直接塞入這些 helper 的 `EDITOR`。

Claude **Ctrl+G**／**Ctrl+X Ctrl+E** 開外部編輯器，儲存並關閉後帶回文字；
這不會重新綁定 Esc／Ctrl+C。
見 [Claude 文件](https://code.claude.com/docs/en/interactive-mode)。
Yazi 文字檔的受管 opener 也使用 editorcfg；目錄保留明確命名的 Neovim 入口。
直接執行 `nvim`／`v` 仍使用 Neovim。

## 可用性、等待與 fallback

每次呼叫都重新尋找 PATH 上的 executable，不接受只有 shell 才能呼叫的 alias／function；
保留工作目錄與檔案參數，等待結束，傳回原退出碼。
Code／Cursor 自動附加 `--wait`，完成時需關閉該檔案分頁。
見 [VS Code CLI](https://code.visualstudio.com/docs/configure/command-line)。

指定程式消失時依序 fallback 到 **micro → nano**。
只有 nvim／vim 偏好可再嘗試 **nvim → vim → vi**，重複候選略過。
非 modal 使用者不會默默被送入 Vim。fallback 在 stderr 說明；
全部不可用時明確失敗並提示安裝。已啟動的編輯器失敗或被取消時，
不會再自動開另一個編輯器。

GUI 與 Notepad 不列入自動 fallback。找到 executable 不代表桌面、IME、
剪貼簿與終端 handoff 都正常；doctor 不啟動程式，這些互動需在目標主機實測。
SSH／WSL 使用 CLI 實際執行處的環境與檔案。

## Neovim 快速編輯

暫存檔辨識涵蓋 `TMPDIR`、`TEMP`、`TMP`、Unix temp 前綴及已知 scratch 檔名。
Windows 會正規化斜線與大小寫，並確認目錄邊界。
quick-edit 關閉該 buffer 的 diagnostics／autoformat，保留插件與 Vim 操作。
可用 `NVIM_QUICK_EDIT=1`／`0` 強制開／關。
若覺得卡頓，請在相同 Windows terminal 比較 `nvim --clean` 與受管設定，
再判斷是否為 Neovim、LazyVim 或終端造成。

## 本機覆寫與安裝

Television 的系統文字檔編輯入口使用 `SUDO_EDITOR` 搭配 `sudoedit`，讓編輯器
保留呼叫者的 PATH、HOME 與偏好。Audit rules 目錄先用 fzf 選擇 `.rules` 檔。
自行在 sudo 內開啟 editor 的應用另有環境規則；使用者層 launcher 不應直接
以 `sudo dotfiles-editor` 呼叫。

個人 export 放在不受管的 `~/.shellrc.adhoc`（或各 shell 的 adhoc）。
`dotcfg --set preferredEditor=micro --yes` 可修改 init 預設；
editorcfg 本機選擇仍優先，直到 reset。

macOS 透過 Homebrew、Debian 透過 apt 安裝 Micro。
Linux 無 root／RedHat 若找不到 Micro，則使用驗證 checksum 的官方 release，
安裝至 `~/.local/bin`。Apply 只安裝；Homebrew 用 `just upgrade-brew`，
apt 使用平常的單套件升級，受管 Linux release 用 `just upgrade-micro`
（也納入 upgrade-all）。升級必須有自有 receipt 且 PATH 指向該 binary，
不會覆蓋套件管理器安裝的 Micro。
