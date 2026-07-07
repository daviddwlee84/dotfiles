# actionlint

> [actionlint](https://github.com/rhysd/actionlint) —— **GitHub Actions workflow 檔案**（`.github/workflows/*.yml`）的靜態檢查器。它遠不只檢查 YAML 語法:會對 `${{ }}` 運算式做型別檢查、驗證 `uses:` action 參照、runner label、`cron` 與 glob pattern,並且(它最強的功能)把每個 `run:` 區塊丟給 [ShellCheck](https://www.shellcheck.net/)、把 Python 片段丟給 [pyflakes](https://pypi.org/project/pyflakes/)。在本 repo 它同時以 on-PATH CLI 與 pre-commit hook 兩種形式提供。

## 它檢查什麼

| 類別 | 範例 |
|---|---|
| **Workflow schema** | 未知的鍵、型別錯誤、缺少必填欄位 |
| **`${{ }}` 運算式** | 未定義的 context（`github.evnt`）、型別不符、錯誤的函式呼叫 |
| **`uses:` 參照** | 格式錯誤的 action 參照、本地 action 的 input/output 不符 |
| **Runner / cron / glob** | 無效的 `runs-on` label、錯誤的 `schedule.cron`、`paths`/`branches` glob |
| **`run:` shell 腳本** | 委派給 **ShellCheck** —— 引號、未設變數、`SC2086` 等 |
| **內嵌 Python** | `shell: python` 的 `run:` 步驟 → **pyflakes** |
| **安全性** | script-injection 模式(未受信任的 `${{ }}` 被插入 shell body) |

## 本 repo 如何安裝

| OS | 機制 | 歸屬 |
|---|---|---|
| macOS | `brew install actionlint`(Homebrew-core formula) | [`devtools`](../../dot_ansible/roles/devtools/tasks/main.yml) role,與 `shellcheck` / `shfmt` 並列 |
| Linux（Debian/Ubuntu） | **Linuxbrew best-effort** —— 僅在有 `brew` 時安裝,比照 `shfmt` 的處理方式(actionlint 不在 apt) | 同一個 `devtools` role,`# --- shellcheck + shfmt ---` 段落 |

**Linux 缺口是刻意的:** 在*沒有* Linuxbrew 的 Linux 主機上,CLI 不會被安裝 —— 但下方的 pre-commit hook 仍能在該處 lint workflow,因為 `actionlint` hook 變體可透過 Go 自行建置 binary。見 [`this_repo/tool-managers.md`](../this_repo/tool-managers.md#tool-index-az) 的 A–Z row。

## ShellCheck 整合(免設定)

actionlint **會自動在 `PATH` 上偵測 `shellcheck`**,並自動對每個 `run:` 區塊執行它 —— 完全不需額外接線。本 repo 到處都已安裝 `shellcheck`(Linux 走 apt、macOS 走 brew;見 [`tool-managers.md`](../this_repo/tool-managers.md#tool-index-az) 的 shellcheck / shfmt row),所以此整合開箱即用。若 `shellcheck` 不存在,actionlint 只會略過該檢查而非報錯。

## pre-commit hook

在 [`.pre-commit-config.yaml`](../../.pre-commit-config.yaml) 中接線,與其他 linter 一起放在 `shfmt` 之後:

```yaml
  - repo: https://github.com/rhysd/actionlint
    rev: v1.7.12
    hooks:
      - id: actionlint-system
        files: '^\.github/workflows/.*\.ya?ml$'
```

- **`actionlint-system`** 重用 `devtools` role 安裝的 on-PATH binary,讓 hook 與 ad-hoc `actionlint` 執行保持同一版本(不用第二份副本、不用 Go build)。
- `files:` 把 hook 限定在 workflow 目錄 —— 永遠不會對無關的 YAML 觸發。
- `rhysd/actionlint` repo 也提供 `id: actionlint`(`language: golang`,自行建置 binary —— 在沒有 CLI 的主機上用這個)與 `id: actionlint-docker`(在容器中執行)。兩者都以相同方式自動偵測 `shellcheck`。

手動執行:

```bash
pre-commit run actionlint-system --all-files
```

## Ad-hoc 用法

```bash
actionlint                                 # lint 所有 .github/workflows/*.yml
actionlint .github/workflows/docs.yml      # lint 單一檔案
actionlint -color                          # 強制彩色輸出
actionlint -shellcheck=                    # 停用 shellcheck 整合
actionlint -version
```

### 選用設定:`.actionlintrc.yaml`

在 repo 根目錄放一個 `.actionlintrc.yaml` 來微調行為 —— 例如 self-hosted runner label、逐路徑忽略、或傳額外旗標給 shellcheck/pyflakes:

```yaml
self-hosted-runner:
  labels:
    - my-custom-runner
config-variables: null   # 允許任意 configuration variable 名稱
```

本 repo 目前不附這個檔案(對它唯一的 `docs.yml` workflow 而言預設就夠了)。

## 相關

- [pre-commit](pre-commit.md) —— 它所依附的 hook 框架。
- [`tool-managers.md` § Tool index](../this_repo/tool-managers.md#tool-index-az) —— 各 OS 的安裝機制(與 `shellcheck` / `shfmt` 共用)。
- 上游:[rhysd/actionlint](https://github.com/rhysd/actionlint) · [checks 文件](https://github.com/rhysd/actionlint/blob/main/docs/checks.md)。
