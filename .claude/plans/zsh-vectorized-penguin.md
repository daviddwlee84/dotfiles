# zsh Startup Optimization — Cache slow completions + dedup brew shellenv

## Context

Steady-state zsh startup is currently **~700ms**;cold start ~2.5s。前一輪 profiling (`ZSH_PROF=1 zsh` + 自訂 per-file timing) 已找出 5 個明確瓶頸:

| # | 來源 | 時間 | 主因 |
|---|---|---|---|
| P1 | `dot_config/shell/29_marimo.sh:9-13` | **282ms** | 每次 startup 跑 `_MARIMO_COMPLETE=zsh_source marimo` (Python cold start ~520ms 的子進程) |
| P2 | `dot_config/zsh/tools/32_try.zsh:12,15` | **68ms** | 每次跑 ruby ×2(找 gem dir + `try init`) |
| P3 | `dot_config/shell/27_thefuck.sh:9` | **59ms** | 每次跑 `thefuck --alias` Python 子進程 |
| P4 | `dot_config/shell/00_exports.sh.tmpl:58-64` 與 `dot_zshrc.tmpl:92-98` / `dot_bashrc.tmpl:67-71` | **~17ms ×2 shells** | brew shellenv 在 mac 上跑兩次(zsh 與 bash 都中招) |
| P5 | `~/.zcompdump-Da-Wei's Mac mini-5.9*` 5 份舊 dump | 0ms (cosmetic) | hostname 改過後留下的孤兒檔 |

**目標**:把 P1–P4 共 ~448ms 砍掉,steady-state 從 ~700ms 降到 **~250ms** (約 -64%)。

**為何用 cache 而不是 lazy-init / 移除工具**:
- marimo / thefuck / try 都還在用,使用者沒打算停用 → 不能像 nvm 那樣延遲到 `LOAD_NVM=1`
- 完成腳本只是 `eval`-able 文字,適合 file cache(對比 `_<tool>` autoload function 適合 `~/.zfunc/`)
- 既有 canonical pattern 已存在(Bitwarden, `dot_config/zsh/tools/95_bitwarden.zsh:11-17`)— 直接 mirror,不要發明新 abstraction

## Strategy: Mirror Bitwarden 的 cache 模式 + 加 mtime 失效

既有的兩種 caching pattern:

| Pattern | 例子 | 失效機制 | 適用 |
|---|---|---|---|
| **A. File cache** | `bw-update-completion` (`95_bitwarden.zsh`) | 手動 refresh | `eval`-able 完成腳本 |
| **B. `~/.zfunc/_<tool>` + version grep** | sesh / television / worktrunk | 每次 startup grep version string | autoload function |

P1–P3 都屬於 Pattern A。為了減少維護成本,我**在 Pattern A 上加一個 binary mtime check** (`[ "$_bin" -nt "$_cache" ]`),這樣:
- 99% 的 case 自動失效(`mise install ruby@3.5`、`brew upgrade thefuck`、`uv tool upgrade marimo` 都會 bump binary mtime)
- 邊角 case(gem-only 升級、cache 寫入時被中斷)用手動 `<tool>-update-completion` helper

**Cache path 慣例**(沿用 bw):
- 跨 shell: `${XDG_CACHE_HOME}/{zsh,bash}/<tool>_completion.{zsh,bash}` (兩 shell 各一份,因為 `_TOOL_COMPLETE=zsh_source` 與 `_TOOL_COMPLETE=bash_source` 輸出不同)
- zsh-only (try): `${XDG_CACHE_HOME}/zsh/try_init.zsh`

## Changes

### P1 — marimo cache (dot_config/shell/29_marimo.sh)

完整重寫(13 行 → ~25 行):

```sh
# 29_marimo.sh - marimo shell completion (cached, shared by zsh/bash)
# Run `marimo-update-completion` to force-refresh after upgrade edge cases
# (e.g. uv tool upgrade where the binary mtime check below misses).

command -v marimo >/dev/null 2>&1 || return 0

if [ -n "$ZSH_VERSION" ]; then
    _marimo_cache="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/marimo_completion.zsh"
    _marimo_shell=zsh
elif [ -n "$BASH_VERSION" ]; then
    _marimo_cache="${XDG_CACHE_HOME:-$HOME/.cache}/bash/marimo_completion.bash"
    _marimo_shell=bash
else
    return 0
fi

_marimo_bin="$(command -v marimo)"
if [ ! -f "$_marimo_cache" ] || [ "$_marimo_bin" -nt "$_marimo_cache" ]; then
    mkdir -p "$(dirname "$_marimo_cache")"
    _MARIMO_COMPLETE="${_marimo_shell}_source" marimo > "$_marimo_cache" 2>/dev/null
fi
[ -s "$_marimo_cache" ] && . "$_marimo_cache"
unset _marimo_cache _marimo_shell _marimo_bin
```

**Saving**: 282ms (cache miss 仍付 282ms,但只在 `marimo` 升級後第一次 startup 發生)

### P2 — thefuck cache (dot_config/shell/27_thefuck.sh)

同 P1 模式:

```sh
# 27_thefuck.sh - thefuck alias (cached, shared by zsh/bash).
# Run `thefuck-update-completion` to force-refresh after upgrade.

command -v thefuck >/dev/null 2>&1 || return 0

if [ -n "$ZSH_VERSION" ]; then
    _tf_cache="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/thefuck_alias.zsh"
elif [ -n "$BASH_VERSION" ]; then
    _tf_cache="${XDG_CACHE_HOME:-$HOME/.cache}/bash/thefuck_alias.bash"
else
    return 0
fi

_tf_bin="$(command -v thefuck)"
if [ ! -f "$_tf_cache" ] || [ "$_tf_bin" -nt "$_tf_cache" ]; then
    mkdir -p "$(dirname "$_tf_cache")"
    thefuck --alias > "$_tf_cache" 2>/dev/null
fi
[ -s "$_tf_cache" ] && . "$_tf_cache"
unset _tf_cache _tf_bin
```

**Saving**: 59ms

### P3 — try cache (dot_config/zsh/tools/32_try.zsh)

只動 line 11–16(中段),保留 line 1–9 (env vars) 和 line 18–37 (try-sesh helper):

```zsh
# Cached gem-path lookup + try init output. Both ruby calls (~67ms) collapse
# to one stat. Run `try-update-completion` to force-refresh after gem upgrade.
_try_cache="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/try_init.zsh"
_try_ruby="$(command -v ruby 2>/dev/null)"
if [ -n "$_try_ruby" ] && { [ ! -f "$_try_cache" ] || [ "$_try_ruby" -nt "$_try_cache" ]; }; then
    _try_script=$(ruby -e "require 'rubygems'; puts File.join(Gem::Specification.find_by_name('try-cli').gem_dir, 'try.rb')" 2>/dev/null)
    if [ -f "$_try_script" ]; then
        mkdir -p "${_try_cache:h}"
        ruby "$_try_script" init > "$_try_cache" 2>/dev/null
    fi
    unset _try_script
fi
[ -s "$_try_cache" ] && source "$_try_cache"
unset _try_cache _try_ruby
```

**注意**:這裡用 `${_try_cache:h}` (zsh modifier) 而不是 `dirname`,因為這個檔案是 `.zsh` 已是 zsh-only — 與 bw 一致。

**Saving**: 68ms

### P4 — brew shellenv 去重 (dot_config/shell/00_exports.sh.tmpl)

刪除 macOS 那一支(lines 58-64),保留 Linux 分支(lines 65-77)— 因為:
- mac:`dot_zshrc.tmpl:92-98` 與 `dot_bashrc.tmpl:67-71` 都已在 modular layer **之前** 跑過 brew shellenv(`dot_bashrc.tmpl:65-66` 的 comment 明說 "must run before shared layer so bash-completion v2's $HOMEBREW_PREFIX detection works")
- linux:zshrc/bashrc 都沒有 linuxbrew shellenv → 必須由 `00_exports.sh` 提供

Diff 概念:

```tmpl
- {{ if eq .chezmoi.os "darwin" -}}
- # macOS: Initialize Homebrew (Apple Silicon or Intel)
- if [[ -f /opt/homebrew/bin/brew ]]; then
-     eval "$(/opt/homebrew/bin/brew shellenv)"
- elif [[ -f /usr/local/bin/brew ]]; then
-     eval "$(/usr/local/bin/brew shellenv)"
- fi
- {{ else -}}
+ # macOS Homebrew shellenv runs in dot_zshrc.tmpl / dot_bashrc.tmpl BEFORE this
+ # modular layer loads, so bash-completion v2 can see $HOMEBREW_PREFIX. We do
+ # NOT duplicate it here — that would re-run shellenv (~17ms) at no benefit.
+ {{ if eq .chezmoi.os "linux" -}}
  # Linux: Initialize Linuxbrew if installed
  ...(unchanged)
  {{ end -}}
```

**Saving**: ~17ms × 2 shells = ~34ms (mac only;Linux 沒影響)

### P5 — 清掉舊 zcompdump (cosmetic, manual)

只刪 hostname 帶 smart quote `'` 的舊版:

```sh
rm -f ~/.zcompdump-"Da-Wei's Mac mini"-* \
      ~/.zcompdump-"Da-Wei's Mac mini-5.9.Da-Weis-Mac-mini.local."*
```

**保留** 當前 hostname `Da-Weis-Mac-mini` 的 dump(zsh 會自動用)。

不寫進 chezmoi script — 純一次性手動 cleanup。

### P6 — 新增三個 refresh helpers

#### `dot_config/shell/10_aliases.sh` — 加在 `bw-update-completion` (line 79) 之後:

```sh
# --- marimo / thefuck completion regen ----------------------------------------
# Same caching strategy as bw-update-completion (above). Mtime check on the
# binary catches `uv tool upgrade marimo` / `brew upgrade thefuck` automatically;
# these helpers exist for edge cases (in-place upgrade where mtime doesn't bump,
# corrupted cache, manual debugging).
function marimo-update-completion {
    command -v marimo >/dev/null 2>&1 || { echo "marimo not installed" >&2; return 1; }
    if [ -n "$ZSH_VERSION" ]; then
        mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/zsh" &&
            _MARIMO_COMPLETE=zsh_source marimo >"${XDG_CACHE_HOME:-$HOME/.cache}/zsh/marimo_completion.zsh" 2>/dev/null &&
            echo "marimo completion cache updated (zsh)"
    elif [ -n "$BASH_VERSION" ]; then
        mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/bash" &&
            _MARIMO_COMPLETE=bash_source marimo >"${XDG_CACHE_HOME:-$HOME/.cache}/bash/marimo_completion.bash" 2>/dev/null &&
            echo "marimo completion cache updated (bash)"
    fi
}

function thefuck-update-completion {
    command -v thefuck >/dev/null 2>&1 || { echo "thefuck not installed" >&2; return 1; }
    if [ -n "$ZSH_VERSION" ]; then
        mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/zsh" &&
            thefuck --alias >"${XDG_CACHE_HOME:-$HOME/.cache}/zsh/thefuck_alias.zsh" 2>/dev/null &&
            echo "thefuck alias cache updated (zsh)"
    elif [ -n "$BASH_VERSION" ]; then
        mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/bash" &&
            thefuck --alias >"${XDG_CACHE_HOME:-$HOME/.cache}/bash/thefuck_alias.bash" 2>/dev/null &&
            echo "thefuck alias cache updated (bash)"
    fi
}
```

**重要**:用 `function name { … }` 語法而不是 POSIX `name() { … }` — 遵守 `pitfalls/zsh-parse-error-on-resource-after-bw-completion-aliased-name.md` 的教訓(避免被自身輸出的 alias 蓋掉導致 re-source 解析失敗)。

#### `dot_config/zsh/10_aliases.zsh` — 加 try helper (zsh-only):

```zsh
# Force-refresh try-cli init cache (zsh-only). Mtime check on `ruby` binary
# auto-invalidates on mise version switch; run this manually after a gem-only
# upgrade (gem update try-cli) or if the cache file got corrupted.
function try-update-completion {
    command -v ruby >/dev/null 2>&1 || { echo "ruby not installed" >&2; return 1; }
    local _script
    _script=$(ruby -e "require 'rubygems'; puts File.join(Gem::Specification.find_by_name('try-cli').gem_dir, 'try.rb')" 2>/dev/null)
    [[ -f "$_script" ]] || { echo "try-cli gem not found" >&2; return 1; }
    local _cache="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/try_init.zsh"
    mkdir -p "${_cache:h}"
    ruby "$_script" init >"$_cache" 2>/dev/null &&
        echo "try-cli init cache updated"
}
```

### P7 — Cross-file maintenance updates (per CLAUDE.md)

- **`docs/shells/aliases.md`**: 加 3 列(marimo-update-completion / thefuck-update-completion / try-update-completion),格式對齊既有 bw-update-completion 列。
- **`docs/zsh/zsh-completions.md`**: 在 Section C "Eval/source at startup" 段註明 marimo / thefuck / try 已升級為 cached(指向 P6 的 update helpers)。
- **`pitfalls/`**: 不開新檔(目前沒踩坑)。如果未來 cache invalidation 出問題再寫。

## Defect / Regression 分析

| 風險 | 機率 | 影響 | 緩解 |
|---|---|---|---|
| **Cache miss 仍付全價** | 100% (第一次 / upgrade 後) | startup 慢 ~280–390ms 一次 | 接受 — 攤提下來幾乎無感;不是優化目標 |
| **Binary mtime 沒 bump 的升級** | 低(uv tool / brew 升級會 bump) | 完成過時(顯示舊 subcommand) | 手動 `<tool>-update-completion` |
| **Cache 寫入被中斷(kill -9 中途)** | 極低 | `eval` 部分內容,可能語法錯誤 | `[ -s ]` 檢查非空;若仍出錯可手動 rm cache 觸發重生。**未加 atomic mktemp+mv** — 既有 bw 模式也沒加,維持一致性,複雜度收益不對等 |
| **多 shell 同時啟動 race condition** | 中(開新 tmux 視窗常觸發) | 兩個 `> cache` 互相 truncate,可能寫一半 | 同上 — 既有 bw 也有此問題,實務上沒人回報 |
| **`-nt` POSIX 兼容性** | 0% (bash + zsh 都支援) | — | 已在 `99_chezmoi_reload.sh` 用過 |
| **`try init` 輸出 bake env vars** | 未驗證 | 若 `TRY_PATH` 改變但 cache 未刷新 → wrong path | **必驗證**:`cat $XDG_CACHE_HOME/zsh/try_init.zsh` 看是否含字面值的 `TRY_PATH=…`;若有,在 cache 上方加 `export TRY_PATH=…` 重 export 或記到 pitfalls/。 |
| **brew shellenv 去重後 mac 缺 PATH** | 0% | — | mac 的 zshrc/bashrc 已在 modular layer 前跑 brew shellenv;`00_exports.sh` 跑時 PATH 已含 brew |
| **brew shellenv 去重影響 Linux** | 0% | — | Linux 分支保留;zshrc/bashrc 沒 linuxbrew 區塊 |
| **chezmoi-apply reload hint 不知道 cache 該失效** | 低 | 用戶在 chezmoi 改 `29_marimo.sh` 後,cache 還是舊內容 | 不影響 — cache 內容是 marimo binary 輸出的,跟 `29_marimo.sh` 內容無關;binary mtime check 才是關鍵 |
| **舊 zcompdump 刪錯 active 的** | 低 | 下次 startup 自動重建,慢 ~30ms 一次 | 只刪 smart-quote hostname 那幾份,active 是 `Da-Weis-Mac-mini-5.9` 不會中招 |
| **Helper function 被自己產生的 alias 蓋掉(zsh re-source)** | 已知 (見 pitfalls/) | re-source `~/.zshrc` parse error | 用 `function name { … }` 語法繞過 alias expansion |
| **bash `~/.cache/bash/` 目錄沒被既有清理機制掃** | 低 | 目錄殘留 stale completion | bw 已在用 `~/.cache/bash/`,無新增風險 |

## 不做的事

- **不**改 `~/.zshrc` brew shellenv 與 oh-my-zsh load 順序(目前順序確實會讓 brew 提供的 `/opt/homebrew/share/zsh/site-functions` 沒進 compinit fpath,但這是另一個獨立議題,不在這次優化範圍)
- **不**碰 oh-my-zsh 本身的 552ms(plugin load 不在這次目標,要動就是換掉 OMZ)
- **不**為 marimo/thefuck/try 加 atomic write(mktemp+mv)— 與 bw 既有風格保持一致
- **不**新增 cache invalidation script 到 `.chezmoiscripts/`(binary mtime check 已涵蓋 99% case)

## Verification

執行順序:

1. **Apply changes**:
   ```sh
   chezmoi apply -v
   ```
   應該看到 5 個 dotfiles 被 update(29_marimo.sh, 27_thefuck.sh, 32_try.zsh, 00_exports.sh, 10_aliases.sh, 10_aliases.zsh)

2. **Sanity check syntax** — 開新 shell 看不會 error:
   ```sh
   zsh -i -c 'echo OK; type marimo-update-completion thefuck-update-completion try-update-completion'
   bash -i -c 'echo OK; type marimo-update-completion thefuck-update-completion'
   ```

3. **Cache hit timing** — 跑 5 次取 steady-state:
   ```sh
   rm -f ~/.cache/zsh/{marimo_completion,thefuck_alias,try_init}.zsh
   for i in 1 2 3 4 5; do /usr/bin/time -p zsh -i -c exit 2>&1 | grep real; done
   # First: cache miss, ~700ms
   # Run 2-5: cache hit, expect ~250-300ms (target -64%)
   ```

4. **Per-file timing 對比**:
   ```sh
   ZSH_PROF=1 zsh -i -c exit 2>&1 | head -10
   ```
   `load_modular_dir` 的 self time 應該從 ~1310ms 降到 ~250ms。

5. **驗證 try cache 無 baked env**:
   ```sh
   grep -E 'TRY_PATH=|TRY_PROJECTS=' ~/.cache/zsh/try_init.zsh && echo "BAKED" || echo "REFERENCED ONLY"
   ```
   如果是 `BAKED`,需要在 `32_try.zsh` 的 source 之前重 export(plan 已在 P3 保留 line 7-9 的 export,所以即使 baked 也是用最新值)。

6. **驗證 cache invalidation**:
   ```sh
   touch -d '+1 hour' "$(command -v marimo)"  # 模擬 marimo 升級
   zsh -i -c exit  # 應該觸發 cache 重建
   ls -la ~/.cache/zsh/marimo_completion.zsh  # mtime 是現在
   ```

7. **驗證手動 helper**:
   ```sh
   zsh -i -c 'marimo-update-completion'  # → "marimo completion cache updated (zsh)"
   bash -i -c 'thefuck-update-completion'  # → "thefuck alias cache updated (bash)"
   zsh -i -c 'try-update-completion'  # → "try-cli init cache updated"
   ```

8. **驗證 brew dedup 沒拆 mac PATH**:
   ```sh
   zsh -i -c 'echo $HOMEBREW_PREFIX; which brew'
   bash -i -c 'echo $HOMEBREW_PREFIX; which brew'
   ```

9. **驗證 docs build**:
   ```sh
   uv run mkdocs build --strict
   ```

## Critical Files

| File | Action |
|---|---|
| `dot_config/shell/29_marimo.sh` | **Rewrite**(P1) |
| `dot_config/shell/27_thefuck.sh` | **Rewrite**(P2) |
| `dot_config/zsh/tools/32_try.zsh` | **Edit middle**(P3,line 11-16) |
| `dot_config/shell/00_exports.sh.tmpl` | **Edit**(P4,刪 mac brew shellenv 區塊) |
| `dot_config/shell/10_aliases.sh` | **Append**(P6,加 marimo/thefuck helpers) |
| `dot_config/zsh/10_aliases.zsh` | **Append**(P6,加 try helper) |
| `docs/shells/aliases.md` | **Edit**(P7,加 3 列) |
| `docs/zsh/zsh-completions.md` | **Edit**(P7,Section C 註記 cached) |
| `~/.zcompdump-Da-Wei's Mac mini-*` | **Delete**(P5,手動) |

**不動但需確認**:
- `dot_zshrc.tmpl:92-98` (mac brew shellenv) — 保留
- `dot_bashrc.tmpl:67-71` (mac brew shellenv) — 保留
- `dot_config/zsh/tools/95_bitwarden.zsh` — canonical 範本,不動
- `dot_config/zsh/tools/22_sesh.zsh` / `12_television.zsh` / `37_worktrunk.zsh` — Pattern B,不在本次範圍

## Expected Result

| 指標 | Before | After (cache hit) |
|---|---|---|
| Steady-state startup | ~700ms | **~250ms** (-64%) |
| Cold start | ~2.5s | ~2.0s (-20%, 受限於 OMZ load) |
| Cache miss penalty | n/a | +~390ms one-time after each tool upgrade |
