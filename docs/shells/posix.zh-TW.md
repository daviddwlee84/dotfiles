# POSIX、sh、bash、zsh：什麼可攜、什麼不可攜

Shell 家族的實戰指南 — POSIX 到底規範了什麼、爲什麼這個語言又醜又活得很好、
以及這個 repo 在哪些情況下刻意挑 `sh` / `bash` / `zsh`。具體 file layout
請看 [`shells/architecture.md`](architecture.md)；bash + ble.sh + OMB
init 順序請看 [`shells/bash.md`](bash.md)；alias inventory 請看
[`shells/aliases.md`](aliases.md)。

## POSIX 到底是什麼

POSIX 是一**組標準**，不是某個 shell 也不是某個 OS。最新版是
**POSIX.1-2024 / IEEE Std 1003.1-2024 / The Open Group Base
Specifications Issue 8**。包含三層：

```
POSIX
├── C / system API: fork、exec、pipe、signal、filesystem...
├── Utilities:      cp、mv、grep、sed、awk、make、find...
└── Shell language: sh 語法、pipeline、redirect、變數、
                    if / for / case...
```

平常大家說「POSIX shell」，指的幾乎都是 **Shell Command Language** 那一章 —
也就是 `/bin/sh` 方言 — 不是 bash 也不是 zsh。bash 和 zsh 都是 POSIX
**superset**：合法的 POSIX sh script 都是合法的 bash script，反之不成立。

## Shell 家族對照

| Shell | 它是什麼 | 你會在哪遇到 |
|---|---|---|
| `sh` | Bourne / POSIX-sh 規範 | `#!/bin/sh` 腳本；最低共同分母 |
| `bash` | GNU Bourne-Again Shell — sh superset，多了 array、`[[ ]]`、`pipefail`、process substitution | 多數 Linux 預設、macOS `/bin/bash`（base 是 3.2，brew 裝 5.x） |
| `zsh` | 強大的互動 shell，sh-ish 但**不是** sh | macOS Catalina 起的預設；本 repo 偏好的互動 shell |
| `dash` | Debian Almquist Shell — 小、快、嚴格 POSIX | Ubuntu `/bin/sh` 指向 |
| `ash` | Almquist 家族 — 更小 | Alpine / BusyBox 的 `/bin/sh` |
| `ksh` | Korn shell — array、`[[ ]]` 等「現代」feature 的源頭 | Solaris、AIX、部分 BSD |
| `fish` | Friendly Interactive SHell — **刻意不 POSIX** | 純互動使用 |
| `nushell` | 結構化資料 pipeline（record / list / table） | 現代資料密集任務的選項 |

shebang 的選擇 = 你在宣告 intent contract：

```sh
#!/bin/sh                  # 「我希望這在 dash、ash、bash --posix... 都能跑」
#!/usr/bin/env bash        # 「我需要 bash feature（array、pipefail、[[ ]]...）」
#!/usr/bin/env zsh         # 「我需要 zsh-only 行爲（glob qualifier、ZLE、compdef...）」
```

zsh 雖然有 `emulate sh` / `emulate ksh` 模式可以切過去，但**不要**假設 zsh
腳本能默默當 `/bin/sh` 用。最常見的兩個地雷是 word splitting（zsh 預設不
切未加引號的展開）與 `**` glob（zsh 把它當特殊字元處理，不需要
`globstar`）。

## Shell 爲什麼還活著

1. **到處都是。** Linux server、macOS、BSD、Docker image、CI runner、
   嵌入式 router、NAS、cluster login node — 都有某種 `/bin/sh`。即使 5 MB
   的 BusyBox image 也有 `ash`。Shell 是最低共同分母。
2. **它是 command glue。** Shell 不是好的通用語言，但它是把 process 串起來
   最強的語言。語法跟 Unix process model 幾乎同構：

   ```sh
   cmd arg1 arg2        # fork + exec
   cmd1 | cmd2          # pipe(2)
   cmd > out 2> err     # dup2 fd
   cmd &                # fork without wait
   wait                 # waitpid
   $?                   # exit status
   ```

3. **CI / Docker / Make / install script 跑不掉它。** 每一行
   `RUN apt-get install …`、每個 GitHub Actions 的 `run: |`、每個
   `Makefile` recipe，最後都把字串丟給 `/bin/sh -c`（或 `SHELL` 指定的）。
   你可以拿工具糊上去，但走不出來。

結論：shell 流行不是因爲語法漂亮，是因爲它站在 Unix process model 的正
中央，而且**已經裝好了**。

## 關鍵語法 — 以及 POSIX 在哪邊結束

每一段都標出 POSIX-sh 寫法 vs bash/zsh 才有的延伸 — 後者在 `dash` /
`ash` 直譯器裡會直接爆。

### 變數與 quoting

```sh
name="Alice"           # POSIX。`=` 兩邊**不能**有空格。
echo "$name"           # 展開時永遠加雙引號。
echo '$HOME'           # 單引號不展開。
echo "$HOME"           # 雙引號會展開。
export PATH="$HOME/.local/bin:$PATH"
FOO=bar command arg    # 一次性的 env 注入。
```

可攜性最大的地雷是沒加引號的展開：

```sh
file="hello world.txt"
rm $file        # 錯 — 拆成 `rm hello world.txt`（兩個 arg）。
rm -- "$file"   # 對。`--` 防止以 `-` 開頭的檔名被當 option。
```

原則：**任何不是刻意要 word-split / glob 展開的 `$var`，都加雙引號**。
ShellCheck 會強制這條。

### Command substitution

```sh
today="$(date +%F)"    # 推薦 — nest 起來乾淨。
today=`date +%F`       # 老式 backtick — 別用，巢狀和 quoting 都痛苦。
```

### Exit status、`&&`、`||`

```sh
cmd && echo ok
cmd || echo fail
mkdir -p build && cd build
```

經典誤用 — 把 `&&` / `||` 當成 if/else：

```sh
cmd1 && cmd2 || cmd3   # 不是 if/else：cmd2 失敗的話 cmd3 也會跑。
```

兩個分支語意上不一樣時就用真的 `if`：

```sh
if cmd1; then cmd2; else cmd3; fi
```

### `[ ]` vs `[[ ]]`

```sh
[ -f "$file" ]               # POSIX。`[` 是個 command — 空格必要。
[[ -f "$file" && -n "$x" ]]  # bash/zsh only — 更安全（不做 word split，
                             # 支援 `&&` / `||` / `==` / `=~`）。
```

`[[ ]]` 嚴格地比較好用 — 但不是 POSIX。`#!/bin/sh` 就只能用 `[ ]`。

### Loop

```sh
# POSIX
for f in *.txt; do echo "$f"; done

# bash/zsh only — C-style
for ((i=0; i<10; i++)); do echo "$i"; done
```

### 一行一行讀檔案

```sh
while IFS= read -r line; do
  printf '%s\n' "$line"
done < input.txt
```

`IFS=` 保留前後空白；`-r` 保留 backslash 不被特殊處理。這兩個 flag 幾乎
永遠是你要的。

### Function

```sh
# POSIX
greet() { echo "hi $1"; }

# bash/zsh — 多了 `function` 關鍵字
function greet() { echo "hi $1"; }
```

### Redirection

```sh
cmd > out                # stdout
cmd >> out               # stdout append
cmd 2> err               # stderr
cmd > all 2>&1           # stdout + stderr — POSIX，順序很重要
cmd &> all               # bash/zsh 簡寫 — 不是 POSIX
cmd < input              # stdin
```

### Pipe 與 `pipefail`

```sh
grep ERROR app.log | sort | uniq -c | sort -nr
set -o pipefail          # bash/zsh only — 任一段失敗就整條失敗
```

`pipefail` 是大部分「可攜」install script 默默變成 bash script 的最大
原因。

### Heredoc

```sh
cat > config.ini <<'EOF'      # 引號 EOF：**不**展開（保留字面 $var）
[server]
host = $LITERAL_LEFT_ALONE
EOF

cat > config.ini <<EOF        # 沒引號 EOF：$var 會展開
host = $HOSTNAME
EOF
```

## 大家都會踩的痛點

### 1. POSIX 幾乎沒有 array

bash 和 zsh 有 array：

```bash
files=("a.txt" "b c.txt")
for f in "${files[@]}"; do echo "$f"; done
```

POSIX sh **沒有**。你能用的「list」只有 positional parameter（`$@`）、
換行分隔字串、或暫存檔。這是可攜 script 一旦稍微複雜就秒變 bash script
的最大原因。

### 2. Quoting 不寬容

```sh
rm -rf $dir            # 空字串、有空格、被 glob 展開 — 全都危險。
: "${dir:?dir is required}"
rm -rf -- "$dir"       # 防禦版本。
```

地球上每個 dotfile bootstrap 都至少出過一次 `rm -rf $UNSET/` bug。
ShellCheck 抓得住幾乎全部。

### 3. `set -e` 有反直覺的破洞

```bash
set -euo pipefail              # bash；典型 strict mode
```

`-e`（出錯就退）在這幾種情境**不會**觸發：`if`、`while`、`&&`、`||`、
某些 shell 的 command substitution、被檢查 return value 的命令。bash
manual 列得出例外清單 — 但反直覺。穩健寫法：

```bash
set -Eeuo pipefail
trap 'printf "error at line %s\n" "$LINENO" >&2' ERR
```

`-E` 讓 `ERR` trap 可以繼承到 function / subshell / command
substitution。以上全部不是 POSIX。

### 4. `/bin/sh` 不是同一個 shell

| OS | `/bin/sh` 實際是 |
|---|---|
| Ubuntu / Debian | `dash` |
| Alpine、嵌入式、Docker scratch | BusyBox `ash` |
| macOS | `bash` POSIX 模式（base 是舊的 3.2） |
| RHEL / Fedora | `bash` POSIX 模式 |
| FreeBSD / NetBSD | 自家 `sh` |

在 Mac 「跑得起來」的腳本到 Ubuntu 可能直接爆，因爲 `[[`、`source`、
`arr=(a b c)`、`echo {1..10}`、`&>` 全是 dash 不認的 bash-ism。**宣稱
可攜的話就用 dash 測** — `apt install dash` 然後 `dash ./script.sh`。

### 5. 全部都是文字流

```sh
ps aux | grep python | awk '{print $2}'
```

很優雅 — 直到第 N 欄位移、process name 有空格、locale 改了日期欄位
格式。處理結構化資料的正解是**不要用 `awk`/`sed` 硬切 — pipe 給 `jq` /
`yq` / `dasel` / Python**：

```sh
curl -s "$API" | jq -r '.items[].name'
```

Nushell 從根本重新設計（pipeline 流的是 record / list / table 而不是
bytes），但它不會、也永遠不會是最低共同分母。

## Alternative — 什麼時候該離開 shell

### ShellCheck — 不是替代，是必裝

```sh
shellcheck script.sh
```

如果 shell 寫超過大概 10 行就跑 ShellCheck。這個 repo 的 pre-commit
hook 有它；參考 [`tools/pre-commit.md`](../tools/pre-commit.md)。

### Python — 任何有結構的東西

需要：真正的資料結構、JSON / YAML / TOML 解析、retry、logging、test、
跨平台路徑處理 — 切到 Python。Shell 版：

```sh
for file in *.json; do
  name="$(jq -r '.name' "$file")"
  echo "$name"
done
```

vs Python：

```python
from pathlib import Path
import json

for path in Path(".").glob("*.json"):
    data = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(name := data.get("name"), str):
        print(name)
```

Python 版處理得了缺檔、JSON 壞掉、Unicode 名字而不會出意外。本 repo
的 [PEP 723 inline-deps Python script](../tools/agent-skills.md)（`uv
run --script`）就是爲此而生 — 看 `scripts/dotfiles_init.py` 和
`scripts/redact_secrets.py`。

### `just` / `make` — 「我只是想記住那條長命令」

如果 shell script 大多只是「跑這條長命令」的 alias，用 task runner。
本 repo 用 [`just`](https://github.com/casey/just)：

```just
test:
    pytest -q

lint:
    ruff check .

upgrade-all:
    ./scripts/upgrade_tools.sh all
```

`make` 通用性最高；`just` 對現代專案語法更舒服。

### chezmoi / Ansible / Nix — 管狀態，不要管命令

如果你的 bootstrap script 是 `apt install …; mkdir …; ln -s …;
systemctl enable …`，你在重發明 configuration management。本 repo 用
**chezmoi** 管 dotfile + **Ansible** 管系統套件 — 看
[`this_repo/architecture.md`](../this_repo/architecture.md) 解釋為何如此。
Nix 是更嚴謹（也更複雜）的選項。

### fish、nushell — 純互動使用

`fish` 是很好的日用 shell 但[刻意不 POSIX
相容](https://fishshell.com/docs/current/language.html)。**不要**拿
fish 寫 `install.sh`。

`nushell` 結構化 pipeline 優先；做臨時資料探索很棒，不適合當 `/bin/sh`。

## 本 repo 怎麼選

| 場景 | Shell 選擇 | 原因 |
|---|---|---|
| `chezmoi` `run_*` 腳本 | **bash** template | 嚴格模式、`pipefail`、array、`[[ ]]` 都值得；chezmoi 跑的環境保證有 bash |
| `dot_config/shell/*.sh.tmpl`（3-tier 共用層） | **POSIX 子集** | zsh 和 bash 都 source — 看 [`shells/architecture.md`](architecture.md)。Source 時用 `$ZSH_VERSION` / `$BASH_VERSION` 分派可以；ZLE / `compdef` / `bind -x` 不行 |
| `dot_config/zsh/**/*.zsh` | **zsh** | ZLE widget（aisuggest、tools picker、sesh、television）、`compdef`、glob qualifier |
| `dot_config/bash/*.bash` | **bash** | `bind -x` / `ble-bind`、OMB plugin array、ble.sh 整合 — 看 [`shells/bash.md`](bash.md) |
| `scripts/*.sh`（本 repo CLI） | **bash** + 嚴格模式 | 跑在 maintainer 的機器；bash 必備 |
| user 機器的互動 shell | **zsh**（預設）或 **bash**（opt-in） | `primaryShell` chezmoi prompt — 只控制 `chsh`，兩個 shell 都會部署。看 [AGENTS.md](https://github.com/daviddwlee84/dotfiles/blob/main/AGENTS.md#primaryshell-choice-gates-chsh-only--both-shells-always-deploy) |

`AGENTS.md` 的硬規則：shell-agnostic 的 helper 放 `dot_config/shell/`
（POSIX）。只有真的需要那個 shell 的 feature 才放 `dot_config/zsh/` 或
`dot_config/bash/`。

## Template

### 可攜 POSIX sh

```sh
#!/bin/sh
set -eu

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

main() {
  command_exists git || die "git is required"
  repo_dir="${1:-}"
  [ -n "$repo_dir" ] || die "usage: $0 REPO_DIR"
  mkdir -p -- "$repo_dir"
  cd -- "$repo_dir"
  printf 'working in %s\n' "$PWD"
}

main "$@"
```

要點：每個展開都加引號、`--` 防 dash-prefix 名字、`command -v` 是 POSIX
測試 executable 的方式（`which` 沒被標準化、`type` 各 shell 輸出不同）。
沒有 array、`[[ ]]`、`pipefail`、`local` — 在 dash、ash、busybox sh 都跑。

### Bash + 嚴格模式

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

trap 'die "failed at line $LINENO"' ERR

main() {
  local repo_dir="${1:-}"
  [[ -n "$repo_dir" ]] || die "usage: $0 REPO_DIR"
  mkdir -p -- "$repo_dir"
  cd -- "$repo_dir"
  printf 'working in %s\n' "$PWD"
}

main "$@"
```

要點：`set -Eeuo pipefail` + `trap … ERR` 是 bash 嚴格模式的典型寫法。
`local` 維持函式作用域；`[[ ]]` 比 `[ ]` 安全；array 與 `pipefail` 隨需
取用。

## 推薦的分界線

選新檔案要用什麼語言時的實戰啟發：

| 長度與形狀 | 用什麼 |
|---|---|
| ≤10 行、command glue | POSIX `sh` |
| 10–100 行、自動化 | `bash` + ShellCheck + 嚴格模式 |
| >100 行、有資料結構或錯誤處理 | Python（PEP 723 inline-deps） |
| 互動 shell config | `zsh`（或 `bash` + ble.sh） |
| 狀態管理（套件、服務、dotfile） | chezmoi + Ansible，不要 shell |
| JSON / YAML / TOML 處理 | `jq` / `yq` / `dasel` / Python |

Shell 是好膠水；不是好通用語言。知道分界線在哪裏 — 並把對的檔案寫在分界
線正確的那一邊 — 就佔了 dotfile repo 可維護性的大部分。

## 延伸閱讀

- [`shells/architecture.md`](architecture.md) — 本 repo 的 3-tier
  `shell/zsh/bash` 佈局
- [`shells/bash.md`](bash.md) — bash bootstrap、ble.sh、oh-my-bash init
  順序
- [`shells/aliases.md`](aliases.md) — 本 repo 定義的所有 alias 與 shell
  function，按 tier 標籤
- [POSIX.1-2024 Shell Command Language](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html)
  — 真正的標準
- [ShellCheck wiki](https://www.shellcheck.net/wiki/) — 每個 code 都有
  解釋
- [Bash Pitfalls (Greg's wiki)](https://mywiki.wooledge.org/BashPitfalls)
  — 「看起來對但其實錯」的經典清單
