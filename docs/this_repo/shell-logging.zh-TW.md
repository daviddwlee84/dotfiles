# Shell 日誌輸出（`scripts/lib/log_shared.sh`）

repo 內所有 shell 腳本共用的一套 console 輸出詞彙：`info` / `success` / `warn` / `error` / `die` / `skip`，加上區段標題與輕量的 pass/fail 計數器。

---

## 為什麼需要它

在這個檔案出現之前，13 個腳本各自手刻同一段色碼區塊與 helper 三件組 —— 而且分成四種互不相容的寫法：

| 寫法 | 出現在 |
|---|---|
| `echo -e "${BLUE}[INFO]${NC} $1"` | `run_once_before_00_bootstrap`、`run_after_25_bat_theme`… |
| `printf '%b\n' "${_C_BLU}[INFO]${_C_RST} $*"` | `scripts/upgrade_tools.sh` |
| `printf '%s\n' "${_C_BLU}[INFO]${_C_RST} $*"` | `scripts/pre-commit-doctor.sh` |
| `printf "${CYAN}[INFO]${RESET}  %s\n" "$*"` | `scripts/import_ssh_to_bw.sh` |

`'\033'`（需要 `%b`）與 `$'\033'`（真正的 ESC 字元）混用；`success` 在兩個檔案印 `[OK]`、其餘印 `[SUCCESS]`；只有三個檔案用 `[[ -t 1 ]]` 判斷是否上色，另外十個無條件上色；[`NO_COLOR`](https://no-color.org) 則完全沒人理會。

## 為什麼不用現成的 library

現成選項是存在的 —— [bashlog](https://github.com/Zordrak/bashlog)、[ShLog](https://www.jsware.io/shlog/)、[lobash](https://github.com/adoyle-h/lobash) —— 而且 `gum log` 早就由 `devtools` role 裝在每一台機器上。但有兩個硬限制把它們全部排除：

1. **`run_once_before_00_bootstrap.sh.tmpl` 跑在什麼都還沒安裝之前。** 它不能依賴 `gum`，也不能依賴任何需要先 `curl` 下載的 library。
2. **chezmoi 會把每個 `run_*.sh.tmpl` render 到暫存路徑再執行。** 執行當下腳本沒有可靠的路徑回到 source tree，`source` 無從解析。

與 [`scripts/lib/sudo_shared.sh`](sudo-session.md) 同樣的推理，也是同樣的解法。

---

## 如何引用

兩種機制，依「腳本執行時是否有穩定路徑回到 source tree」來選。

### Inline —— chezmoi run-script

```bash
# 設定要放在 include 之前。
LOG_STREAM=stdout
{{ include "scripts/lib/log_shared.sh" }}
```

用 `include` 而非 `includeTemplate` —— 這個檔案是純 bash，沒有 `{{ … }}` token 需要再次 render。

!!! warning "改動 lib 會重新觸發所有 inline 它的 `run_onchange_after_*`"
    inline 進去的副本屬於消費端腳本的內容，改了就會改變其 hash。下一次 `chezmoi apply` 時，這代表每一台主機都要重跑完整 ansible、完整 `brew bundle`、yazi 外掛重新檢查等等。要改就一次改完。

### Source —— `scripts/*.sh`

```bash
_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/log_shared.sh
# shellcheck disable=SC1091
source "$_REPO_ROOT/scripts/lib/log_shared.sh"
```

這些腳本只會從 repo checkout 執行，所以路徑是穩定的。

### 哪些**不能**用

任何會被部署到 `$HOME` 的檔案。`scripts/**` 列在 `.chezmoiignore.tmpl`，所以這個檔案永遠不會落到目標機器上 —— 執行期唯一存在的副本就是 inline 進去的那份，以及從 checkout `source` 的那份。`dot_config/television/executable_azure-rotate-ip.sh` 保留自己那兩行 `die`/`warn` 正是因為這個原因。

---

## API

### 訊息行

全部接受多個參數，以單一空白接合。

| 呼叫 | 標籤 | 顏色 | 輸出串流 |
|---|---|---|---|
| `info "msg"` | `[INFO]` | 藍 | stdout |
| `success "msg"` | `[SUCCESS]` | 綠 | stdout |
| `warn "msg"` | `[WARN]` | 黃 | stdout |
| `error "msg"` | `[ERROR]` | 紅 | stderr（見 `LOG_STREAM`） |
| `skip "msg"` | `[SKIP]` | 灰 | stdout |
| `die "msg"` | `[ERROR]` | 紅 | stderr，然後 `exit 1` |

`die` 固定 exit 1。有明確 exit code 契約的腳本 —— `pre-commit-doctor.sh` 用 0/1/2/3 —— 自己呼叫 `error` 再 `exit N`。

### 結構

| 呼叫 | 效果 |
|---|---|
| `step "Heading"` | 空行 + 粗體標題 |
| `hr` | 灰色分隔線 |
| `dim "msg"` | 無標籤的灰字（提示、指令回顯） |

### 驗證模式

給一次性的「這東西到底有沒有生效」檢查腳本用：

```bash
step "Checking the deploy"
[[ -f /etc/foo.conf ]] && ok "config present" || bad "config missing"
[[ -x /usr/bin/foo ]]  && ok "binary present" || bad "binary missing"
log_summary            # "2 passed, 0 failed"；有失敗則回傳 1
```

| 呼叫 | 效果 |
|---|---|
| `ok "msg"` | 綠色 `✔`，pass 計數 +1 |
| `bad "msg"` | 紅色 `✘`，fail 計數 +1 |
| `log_summary` | 印出 `N passed, M failed`；`M > 0` 時回傳 1 |
| `log_fail_count` | 印出目前的 fail 數 |
| `log_reset_counters` | 兩個計數器歸零 |

!!! note "這不是測試框架"
    要 commit 進 repo、可重複執行的測試請寫在 `tests/unit/*.bats`（`just bats`）—— 見 [Testing](testing.md)。驗證模式是給那種用完即丟、但仍需要正確 exit code 的 post-apply 檢查腳本。

### 調色盤

`_C_RED` `_C_GRN` `_C_YLW` `_C_BLU` `_C_CYN` `_C_MAG` `_C_DIM` `_C_BLD` `_C_RST`，可直接使用。它們存的是真正的 ESC 字元，所以在 `printf '%s'`、`printf '%b'`、`echo -e` 底下都安全。全部在載入時初始化為空字串，因此就算從沒呼叫 `log_init`，`set -u` 的腳本也不會炸。

---

## 設定

這些要在 include/source **之前**設定，或者設定完再手動重跑 `log_init`。

| 變數 | 預設 | 效果 |
|---|---|---|
| `LOG_PREFIX` | `''` | 把 `[INFO]`/`[WARN]`/… 標籤換成單一固定標籤，例如 `[raycast-sync]`。顏色仍隨嚴重度變化。 |
| `LOG_STREAM` | `split` | `split` → `error`/`die`/`bad` 走 stderr，其餘走 stdout。`stdout` → 全部走 stdout。 |
| `NO_COLOR` | 未設 | 有設且非空 → 關閉顏色。 |
| `CLICOLOR_FORCE` | 未設 | 非空且不是 `0` → 即使輸出被導管也強制上色。 |

`LOG_PREFIX` 與 `LOG_STREAM` 是在呼叫當下讀取的，所以寫在 source 之後也有效。調色盤則在載入時計算 —— 之後才改 `NO_COLOR` 需要重跑 `log_init`。

兩個顏色變數都沒設時，只有在 stdout 是 TTY 且 `TERM` 不是 `dumb` 的情況下才上色。

### `CLICOLOR_FORCE` 刻意壓過 `NO_COLOR`

本 repo 的 yazi piper 規則會設 `CLICOLOR_FORCE` 把顏色推進 pipe（見 [yazi 預覽](../tools/yazi-previews.md) 裡的 glow 契約）。使用者環境中順帶存在的 `NO_COLOR` 不該把它擋掉。

### 為什麼每個 chezmoi run-script 都設 `LOG_STREAM=stdout`

`scripts/fleet/apply.py::_classify_drift()` 在 local-host 路徑上吃的是**真正的 stderr 行**，而且只要有一行它不認得，就判定「不是純粹的 drift」—— 該主機於是被回報成 `failed` 而非 `drift`。遷移前那 13 個腳本的警告全部印在 stdout，所以對這個 classifier 是隱形的。把它們改走 stderr 會讓原本無害的 `drift` 悄悄變成 `failed`。見 [fleet-apply](fleet-apply.md) 的不變式。

同樣的理由，`warn` 即使在 `split` 模式下也留在 stdout —— 這符合那 13 個腳本原本的行為，也避免 `just upgrade-all 2>/dev/null` 把 `upgrade_tools.sh` 的 47 個警告全部吃掉。

---

## 實作迴避掉的陷阱

其中三個光看程式碼是看不出來的，都由 `tests/unit/log_shared.bats` 覆蓋。

- **`set -e` 底下的 `(( x++ ))`。** 後置遞增的求值結果是**舊值**，所以第一次計數（0 → 1）會回傳 exit status 1，直接殺掉呼叫端。lib 全程使用 `x=$(( x + 1 ))`。
- **不能有 top-level `return`。** 這個檔案在九個消費端是被 *inline* 的、不是被 source 的。用 `return 0` 做重複載入防護會讓那些腳本以 `return: can only 'return' from a function or sourced script` 中止。
- **每個輸出函式裡的 `local IFS=' '`。** `import_ssh_to_bw.sh` 會重設 `IFS` 來切分記錄；沒有這個保護的話，標籤與訊息之間會被黏上一個 ASCII unit separator。
- **`set -u` 安全性。** 調色盤變數與計數器在檔案層級就初始化，不是只在 `log_init` 裡。

## 維護

- `scripts/lib/*.sh` 有納入 pre-commit 的 **shellcheck** hook（severity=warning）。但**沒有**納入 **shfmt** hook —— 加進去會把 `sudo_shared.sh` 整份 4-space 縮排重排。`scripts/lib/` 裡的新程式碼請自行維持 shfmt 相容（`shfmt -i 2 -ci -bn`）。
- 新增消費端時，要同時加進 `tests/unit/log_shared.bats` 的 wiring-guard 測試，以及 `CLAUDE.md` 的 `scripts/lib/log_shared.sh` 那一列。只要有消費端掉了 include/source 行、或又長回自己的 helper 副本，該測試就會明確失敗。
