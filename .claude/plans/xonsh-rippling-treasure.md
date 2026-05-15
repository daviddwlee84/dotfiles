# Xonsh as Experimental Tertiary Shell

## Context

User 想試 [Xonsh](https://github.com/xonsh/xonsh) (v0.23.6, 2026-05；Python-superset shell)，希望比「`uv tool install` 一次性」多一點點，但**不**要把現有 zsh/bash 生態整個移植過去。範圍：

- ✅ 透過 dotfiles 安裝（chezmoi apply 會自動上）
- ✅ 一份最小可用 `~/.xonshrc`（prompt、PATH、vim-mode 尊重）
- ✅ 預裝幾個示範性 xontribs 當作擴展鉤子
- ✅ `~/.config/xonsh/` 留作個人擴展沙盒
- ❌ 不 `chsh`、不動 `primaryShell` schema（仍只接 `zsh|bash`）
- ❌ 不重寫 `fleet`/`mlf`/`pqsum`/`wt`/`wm`/三層 shell helper／14 個 tab completions
- ❌ 不 source `.shellrc.adhoc`/`.shellrc.secrets`（那是 POSIX）

定位：**「想用 inline Python 撈/處理資料時打 `xonsh` 進去玩，玩完離開」**——黏起來再考慮深度整合。

## Approach

### 1. 安裝 — 沿用 `python_uv_tools` role（**不**新建獨立 role）

該 role 已有 `with:` 機制可以順帶裝 xontrib（pip 包）到 xonsh 的 tool venv 裡，`xontrib load` 找得到。比新建 `dot_ansible/roles/xonsh/` 少很多樣板，跨平台一致（macOS/Linux/CentOS 都走 uv tool install）。

**修改檔案**：`dot_ansible/roles/python_uv_tools/defaults/main.yml`

加一筆（接在現有 entries 後）：

```yaml
  - name: xonsh
    binary: xonsh
    with:
      - xontrib-jedi          # Jedi-powered Python tab completion
      - xontrib-zoxide        # z/zi 跳目錄
      - xontrib-pipeliner     # 把 shell 輸出 pipe 進 Python (xonsh 賣點示範)
      - xontrib-fzf-widgets   # Ctrl+R/Ctrl+T fzf widget (用 user 已有的 fzf)
```

> **替代方案**：若 user 偏好「獨立 ansible role」，就改成 `dot_ansible/roles/xonsh/{tasks,defaults}/main.yml` 模仿 zsh role 的結構。但因 xonsh 跨平台都走 uv（不像 zsh 走 brew/apt/yum），分支冗餘多——**推薦留在 python_uv_tools**，更貼合既有 pattern。

### 2. `dot_xonshrc.tmpl` — 新檔，部署到 `~/.xonshrc`

最小但完整：

- **PATH prelude**：鏡像 `scripts/fleet/exec.py:_PATH_PRELUDE` 的順序（chezmoi → cargo → uv → ~/bin → brew → linuxbrew）保證 xonsh 看得到 user 安裝的 CLI
- **Starship prompt**：`execx($(starship init xonsh))`（starship ≥ 1.x 原生支援 xonsh，**不需** xontrib）
- **載入示範 xontribs**：`xontrib load jedi zoxide pipeliner fzf-widgets`
- **Vim mode gate**（依 CLAUDE.md「`enableVimMode` 管 shell 模態」）：
  ```jinja
  {{ if .enableVimMode -}}
  $VI_MODE = True
  $XONSH_AUTOSUGGEST_REMOVAL_KEYBINDS = True
  {{- end }}
  ```
- **可選擴展鉤子**：
  ```python
  # 載入 user 的擴充 (~/.config/xonsh/rc.xsh)
  $XONSHRC.append($HOME + '/.config/xonsh/rc.xsh')
  # Local-only overrides (untracked, never committed)
  import os
  if os.path.exists($HOME + '/.xonshrc.local'):
      $XONSHRC.append($HOME + '/.xonshrc.local')
  ```

> `~/.xonshrc.local` 故意**不**自動產生（mirror `.shellrc.secrets` 規則），避免空 stub footgun。

### 3. `dot_config/xonsh/rc.xsh.tmpl` — 新檔，個人擴展沙盒

預載一兩個 Python-flavor 範例，讓 user 看「在 xonsh 裡能做什麼」：

```python
# 範例 1: 一個用 Python 寫的 shell function (xonsh 的核心賣點)
def _largest_files(args, stdin=None):
    """Show N largest files in current dir (default 10).
    Usage: largest [N]"""
    n = int(args[0]) if args else 10
    import os
    files = [(f, os.path.getsize(f)) for f in os.listdir('.') if os.path.isfile(f)]
    for f, s in sorted(files, key=lambda x: -x[1])[:n]:
        print(f"{s:>12}  {f}")
aliases['largest'] = _largest_files

# 範例 2: 把 shell 結果直接喂進 Python
# 例如: lines = $(ls).splitlines(); [l for l in lines if 'foo' in l]
```

附加 `dot_config/xonsh/README.md`（**短**）：說明這 dir 的角色＝個人擴展，主 `.xonshrc` 不要動。

### 4. 文檔

- **新檔** `docs/shells/xonsh.md`：
  - 一段「為什麼 xonsh 在這個 repo 是次要 shell」（既有生態不移植，請留在 zsh/bash 為主）
  - 啟動方式（直接打 `xonsh`，或 `xonsh -c '...'`）
  - 預裝 xontribs 清單 + 各自一行說明
  - 擴展指南：去 `~/.config/xonsh/rc.xsh` 加你的東西
  - 「不會發生什麼」：不 chsh、不接 atuin/ble.sh、不接 fleet helpers
- **更新** `mkdocs.yml`：在 `docs/shells/` 區段 nav 加一行
- **更新** `README.md`：在 What You Get 加一行（xonsh as optional tertiary shell）

### 5. 不動的地方（明確列出避免誤改）

- `dot_zshrc.tmpl` / `dot_bashrc.tmpl`：no change
- `.chezmoi.toml.tmpl`：`primaryShell` schema 不動（保持 `zsh|bash`）
- `scripts/init/dotfiles_init.py`：no new prompts/bundles
- `scripts/generate_completions.sh`：不加 xonsh tab-completion 生成
- `dot_config/{shell,zsh,bash}/`：完全不碰
- `CLAUDE.md` 的 cross-file rules table：不加新 row（xonsh 改動本身不會牽動其他 surface，未來若 user 想擴展再加）

## Files to modify

| Path | Action |
|---|---|
| `dot_ansible/roles/python_uv_tools/defaults/main.yml` | edit — append xonsh entry |
| `dot_xonshrc.tmpl` | **create** |
| `dot_config/xonsh/rc.xsh.tmpl` | **create** |
| `dot_config/xonsh/README.md` | **create** |
| `docs/shells/xonsh.md` | **create** |
| `mkdocs.yml` | edit — add nav entry |
| `README.md` | edit — one-line mention |

## Reference: existing patterns to mirror

- **uv tool install with `with:` extras**: `dot_ansible/roles/python_uv_tools/defaults/main.yml` (e.g. `sqlit-tui[ssh]` entry with `with: [psycopg2-binary]`)
- **chezmoi template prompt for opt-in features**: `.chezmoi.toml.tmpl` `enableVimMode` flag usage
- **PATH prelude order**: `scripts/fleet/exec.py:_PATH_PRELUDE` (chezmoi → cargo → uv → ~/bin → brew → linuxbrew)
- **Three-tier docs** (`*.md`/`*.zh-TW.md`): `docs/shells/bash.md` 結構可參考（但 zh-TW 翻譯這次先不做，user 可後補）

## Verification

執行順序 = 從便宜到貴：

1. **Template 渲染** (offline, 秒級):
   ```sh
   chezmoi execute-template < dot_xonshrc.tmpl
   chezmoi execute-template < dot_config/xonsh/rc.xsh.tmpl
   ```
2. **MkDocs strict build**:
   ```sh
   uv run mkdocs build --strict
   ```
3. **Ansible check-mode**:
   ```sh
   cd dot_ansible && ansible-playbook -i inventories/local.yml playbooks/$(uname | tr '[:upper:]' '[:lower:]').yml --tags python_uv_tools --check
   ```
4. **真實安裝** (`chezmoi apply` 或 `just upgrade-uv` 之類):
   - `which xonsh` → 應指向 `~/.local/bin/xonsh`
   - `xonsh --version` → ≥ 0.23.x
5. **Smoke test**:
   ```sh
   xonsh -c 'print(1+1); echo hello; print($(ls).splitlines()[:3])'
   ```
   應依序看到 `2`、`hello`、目前目錄前 3 個 entry 的 Python list
6. **Xontrib 載入**:
   ```sh
   xonsh -c 'xontrib load jedi zoxide pipeliner fzf-widgets; print("OK")'
   ```
7. **互動體驗** (人工)：
   - 進 `xonsh`，prompt 應由 starship 渲染、跟你在 zsh 看到的視覺一致
   - 按 Tab 補檔名/Python 物件（jedi）
   - 打 `z somewhere`（zoxide）
   - 若 `enableVimMode=true`：應該看到 vi-mode 指示

## Out of scope (留給未來 / user 想擴時自己加)

- xonsh atuin 整合（atuin 沒官方 xontrib；要的話 user 自己在 `~/.config/xonsh/rc.xsh` 寫 hook）
- 把 `fleet`/`mlf`/`pqsum` 包成 xonsh alias
- xonsh as login shell (`chsh`)
- zh-TW 翻譯版 `docs/shells/xonsh.zh-TW.md`
- 加入 `scripts/upgrade_tools.sh` 的特殊 category（已自動由 generic `uv` upgrade 涵蓋，無需特例）
