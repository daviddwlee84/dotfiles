# POSIX, sh, bash, zsh: what's portable and what's not

A field guide to the shell family — what POSIX actually standardises, why
the language survives despite its warts, and when this repo deliberately
picks `sh` vs `bash` vs `zsh`. For the concrete file layout in this repo,
see [`shells/architecture.md`](architecture.md); for bash + ble.sh + OMB
init order, see [`shells/bash.md`](bash.md); for the alias inventory, see
[`shells/aliases.md`](aliases.md).

## What POSIX actually is

POSIX is a **family of standards**, not a shell or an OS. The current
revision is **POSIX.1-2024 / IEEE Std 1003.1-2024 / The Open Group Base
Specifications Issue 8**. It covers three layers:

```
POSIX
├── C / system API: fork, exec, pipe, signal, filesystem, ...
├── Utilities:      cp, mv, grep, sed, awk, make, find, ...
└── Shell language: sh syntax, pipelines, redirection, variables,
                    if / for / case, ...
```

When people say "POSIX shell" they almost always mean the **Shell Command
Language** chapter — the `/bin/sh` dialect — not bash or zsh. Both bash
and zsh are POSIX **supersets**: every well-formed POSIX sh script is a
valid bash script, but not the other way round.

## The shell family map

| Shell | What it is | Where you meet it |
|---|---|---|
| `sh` | The Bourne / POSIX-sh contract | `#!/bin/sh` scripts; the lowest common denominator target |
| `bash` | GNU Bourne-Again Shell — sh superset with arrays, `[[ ]]`, `pipefail`, process substitution | Default on most Linux, `/bin/bash` on macOS (3.2 in base, 5.x via brew) |
| `zsh` | Powerful interactive shell, sh-ish but **not** sh | macOS default login shell since Catalina; this repo's preferred interactive shell |
| `dash` | Debian Almquist Shell — small, fast, strict POSIX | Ubuntu's `/bin/sh` symlink target |
| `ash` | Almquist family — even smaller | Alpine / BusyBox `/bin/sh` |
| `ksh` | Korn shell — original source of arrays, `[[ ]]`, many "modern" features | Solaris, AIX, some BSDs |
| `fish` | Friendly Interactive SHell — **intentionally not POSIX** | Opt-in interactive only |
| `nushell` | Structured-data pipelines (records / lists / tables) | Opt-in; modern alternative for data-heavy work |

The shebang you pick declares an intent contract:

```sh
#!/bin/sh                  # "I want this to run on dash, ash, bash --posix, ..."
#!/usr/bin/env bash        # "I need bash features (arrays, pipefail, [[ ]], ...)"
#!/usr/bin/env zsh         # "I need zsh-only behaviour (glob qualifiers, ZLE, compdef, ...)"
```

zsh has `emulate sh` / `emulate ksh` modes that flip option flags toward
the older shells, but **do not** assume a zsh script silently works as
`/bin/sh`. The two most common breakages are word-splitting (zsh
doesn't split unquoted parameter expansions by default) and the `**`
glob (zsh treats it specially without `globstar`).

## Why shell survives

1. **It's everywhere.** Linux servers, macOS, BSD, Docker images, CI
   runners, embedded routers, NAS boxes, cluster login nodes — all
   ship some `/bin/sh`. Even a 5 MB BusyBox image has `ash`. Shell is
   the lowest common denominator.
2. **It's command glue.** Shell isn't a great general-purpose language;
   it's the best language *for stitching processes together*. The
   syntax is almost isomorphic to the Unix process model:

   ```sh
   cmd arg1 arg2        # fork + exec
   cmd1 | cmd2          # pipe(2)
   cmd > out 2> err     # dup2 file descriptors
   cmd &                # fork without wait
   wait                 # waitpid
   $?                   # exit status
   ```

3. **CI / Docker / Make / install scripts can't escape it.** Every
   `RUN apt-get install …` line, every `run: |` block in GitHub
   Actions, every `Makefile` recipe ultimately hands a string to
   `/bin/sh -c` (or whichever `SHELL`). You can paper over it with
   tooling, but you can't actually leave.

The lesson: shell isn't loved because the language is elegant, it's
loved because it sits at the centre of the Unix process model and is
**already installed**.

## Key syntax — and where it stops being POSIX

This is the cheat sheet I wish I'd had before writing portable installer
scripts. Each row notes the POSIX-sh form and the bash/zsh extension that
won't survive a `dash` or `ash` interpreter.

### Variables and quoting

```sh
name="Alice"           # POSIX. NO spaces around `=`.
echo "$name"           # Always quote expansions.
echo '$HOME'           # Single quotes don't expand.
echo "$HOME"           # Double quotes do.
export PATH="$HOME/.local/bin:$PATH"
FOO=bar command arg    # One-shot env override.
```

The single biggest portable-shell footgun is unquoted expansion:

```sh
file="hello world.txt"
rm $file        # WRONG — splits into `rm hello world.txt` (two args).
rm -- "$file"   # Right. Use `--` to defend against names starting with `-`.
```

Rule of thumb: **every `$var` that isn't deliberately being word-split
or glob-expanded gets double quotes**. ShellCheck enforces this.

### Command substitution

```sh
today="$(date +%F)"    # Preferred — nests cleanly.
today=`date +%F`       # Legacy backticks — avoid; nesting / quoting both painful.
```

### Exit status, `&&`, `||`

```sh
cmd && echo ok
cmd || echo fail
mkdir -p build && cd build
```

The classic mistake is treating `&&`/`||` as if/else:

```sh
cmd1 && cmd2 || cmd3   # NOT if/else: if cmd2 fails, cmd3 still runs.
```

Use a real `if` when the two branches are semantically distinct:

```sh
if cmd1; then cmd2; else cmd3; fi
```

### `[ ]` vs `[[ ]]`

```sh
[ -f "$file" ]               # POSIX. `[` is a command — spaces matter.
[[ -f "$file" && -n "$x" ]]  # bash/zsh only — safer (no word splitting,
                             # supports `&&` / `||` / `==` / `=~`).
```

`[[ ]]` is strictly nicer — but it's not POSIX. If you `#!/bin/sh`, you
get `[ ]`.

### Loops

```sh
# POSIX
for f in *.txt; do echo "$f"; done

# bash/zsh only — C-style
for ((i=0; i<10; i++)); do echo "$i"; done
```

### Reading a file line by line

```sh
while IFS= read -r line; do
  printf '%s\n' "$line"
done < input.txt
```

`IFS=` keeps leading/trailing whitespace; `-r` keeps backslashes literal.
Both flags are nearly always what you want.

### Functions

```sh
# POSIX
greet() { echo "hi $1"; }

# bash/zsh — adds the `function` keyword
function greet() { echo "hi $1"; }
```

### Redirection

```sh
cmd > out                # stdout
cmd >> out               # stdout append
cmd 2> err               # stderr
cmd > all 2>&1           # stdout + stderr — POSIX, ordering matters
cmd &> all               # bash/zsh shortcut for the above — NOT POSIX
cmd < input              # stdin
```

### Pipes and `pipefail`

```sh
grep ERROR app.log | sort | uniq -c | sort -nr
set -o pipefail          # bash/zsh only — make pipelines fail on any stage
```

`pipefail` is the single biggest reason most "portable" install scripts
quietly become bash scripts.

### Heredocs

```sh
cat > config.ini <<'EOF'      # quoted EOF: NO expansion (literal $vars)
[server]
host = $LITERAL_LEFT_ALONE
EOF

cat > config.ini <<EOF        # unquoted EOF: $vars expand
host = $HOSTNAME
EOF
```

## Pain points that bite everyone

### 1. Arrays barely exist in POSIX

Bash and zsh have arrays:

```bash
files=("a.txt" "b c.txt")
for f in "${files[@]}"; do echo "$f"; done
```

POSIX sh **doesn't**. Your only "lists" are positional parameters
(`$@`), newline-separated strings, or temporary files. This is the
single biggest reason a portable script becomes a bash script the
moment it gets non-trivial.

### 2. Quoting is unforgiving

```sh
rm -rf $dir            # Empty, spaced, glob-expanded — all dangerous.
: "${dir:?dir is required}"
rm -rf -- "$dir"       # Defended.
```

Every dotfile bootstrap on the planet has shipped a `rm -rf $UNSET/`
bug at some point. ShellCheck catches almost all of them.

### 3. `set -e` has surprising holes

```bash
set -euo pipefail              # bash; the "strict mode" canon
```

`-e` (exit on error) does **not** trigger inside `if`, `while`, `&&`,
`||`, command substitution under some shells, or commands whose return
value is being inspected. The bash manual lists the exceptions; they're
not intuitive. The robust pattern is:

```bash
set -Eeuo pipefail
trap 'printf "error at line %s\n" "$LINENO" >&2' ERR
```

`-E` makes `ERR` traps inherit into functions / subshells / command
substitutions. None of this is POSIX.

### 4. `/bin/sh` is not one shell

| OS | `/bin/sh` actually is |
|---|---|
| Ubuntu / Debian | `dash` |
| Alpine, embedded, Docker scratch images | BusyBox `ash` |
| macOS | `bash` in POSIX mode (older 3.2 base) |
| RHEL / Fedora | `bash` in POSIX mode |
| FreeBSD / NetBSD | their own `sh` |

A script that "works on `/bin/sh`" on your Mac may explode on Ubuntu
because `[[`, `source`, `arr=(a b c)`, `echo {1..10}`, `&>` are all
bash-isms that dash rejects outright. **Test on dash if you claim
portability** — `apt install dash` and run `dash ./script.sh`.

### 5. Everything is a text stream

```sh
ps aux | grep python | awk '{print $2}'
```

This is elegant until column N moves, a process name has a space, or
the locale rewrites the date column. The robust answer for structured
data is **don't parse with `awk`/`sed` — pipe to `jq` / `yq` / `dasel`
/ Python**:

```sh
curl -s "$API" | jq -r '.items[].name'
```

Nushell rethinks this from scratch (records / lists / tables flow
through the pipeline instead of bytes), but it's not the lowest common
denominator and never will be.

## Alternatives — when to leave shell

### ShellCheck — not an alternative, a prerequisite

```sh
shellcheck script.sh
```

If you're writing more than ~10 lines of shell, run ShellCheck. This
repo's pre-commit hooks include it; see [`tools/pre-commit.md`](../tools/pre-commit.md).

### Python — for anything with structure

The moment you need: real data structures, JSON / YAML / TOML parsing,
retries, logging, tests, or cross-platform path handling — switch to
Python. Shell:

```sh
for file in *.json; do
  name="$(jq -r '.name' "$file")"
  echo "$name"
done
```

vs Python:

```python
from pathlib import Path
import json

for path in Path(".").glob("*.json"):
    data = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(name := data.get("name"), str):
        print(name)
```

The Python version handles missing files, malformed JSON, and Unicode
names without surprises. This repo uses [PEP 723 inline-deps Python
scripts](../tools/agent-skills.md) (`uv run --script`) for exactly this
reason — see `scripts/dotfiles_init.py` and `scripts/redact_secrets.py`.

### `just` / `make` — for "I just want to remember the command"

If your shell scripts are mostly aliases for "run this long command",
use a task runner. This repo uses [`just`](https://github.com/casey/just):

```just
test:
    pytest -q

lint:
    ruff check .

upgrade-all:
    ./scripts/upgrade_tools.sh all
```

`make` is more universally available; `just` is more ergonomic for
modern projects.

### chezmoi / Ansible / Nix — for state, not commands

If your bootstrap script is `apt install …; mkdir …; ln -s …; systemctl
enable …`, you're reinventing configuration management. This repo uses
**chezmoi** for dotfiles + **Ansible** for system packages — see
[`this_repo/architecture.md`](../this_repo/architecture.md) for why.
Nix is the more rigorous (and more complex) option.

### fish, nushell — for interactive use only

`fish` is a great daily driver but [intentionally not
POSIX-compatible](https://fishshell.com/docs/current/language.html).
Don't write your `install.sh` in fish.

`nushell` is structured-pipeline-first; great for ad-hoc data
exploration, not the right `/bin/sh`.

## How this repo decides

| Use case | Shell choice | Why |
|---|---|---|
| `chezmoi` `run_*` scripts | **bash** template (`{{- if true -}}#!/usr/bin/env bash`) | Strict mode, `pipefail`, arrays, `[[ ]]` are worth it; chezmoi runs on machines where bash is guaranteed |
| `dot_config/shell/*.sh.tmpl` (3-tier shared layer) | **POSIX subset** | Sourced by both zsh AND bash — see [`shells/architecture.md`](architecture.md). Source-time dispatch via `$ZSH_VERSION` / `$BASH_VERSION` is OK; ZLE / `compdef` / `bind -x` are NOT |
| `dot_config/zsh/**/*.zsh` | **zsh** | ZLE widgets (aisuggest, tools picker, sesh, television), `compdef`, glob qualifiers |
| `dot_config/bash/*.bash` | **bash** | `bind -x` / `ble-bind`, OMB plugin arrays, ble.sh integration — see [`shells/bash.md`](bash.md) |
| `scripts/*.sh` (this repo's CLIs) | **bash** with strict mode | Run on the maintainer's machine; bash availability is non-negotiable |
| Interactive shell on user machines | **zsh** (default) or **bash** (opt-in) | `primaryShell` chezmoi prompt — gates `chsh` only; both shells always deploy. See [AGENTS.md](https://github.com/daviddwlee84/dotfiles/blob/main/AGENTS.md#primaryshell-choice-gates-chsh-only--both-shells-always-deploy) |

The hard repo rule (from `AGENTS.md`): if your helper is shell-agnostic,
it goes in `dot_config/shell/` as POSIX. Only put it in `dot_config/zsh/`
or `dot_config/bash/` if it genuinely needs that shell's features.

## Templates

### Portable POSIX sh

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

Notes: every expansion is quoted, `--` defends against dash-prefixed
arguments, `command -v` is the POSIX way to test for an executable
(`which` isn't standardised, `type` has shell-specific output). No
arrays, no `[[ ]]`, no `pipefail`, no `local` — runs on dash, ash,
busybox sh.

### Bash with strict mode

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

Notes: `set -Eeuo pipefail` + `trap … ERR` is the canonical bash strict
mode. `local` keeps function-scoped variables; `[[ ]]` is safer than
`[ ]`; arrays and `pipefail` are available when needed.

## Recommended boundaries

A practical heuristic when you're choosing a language for a new file:

| Length & shape | Use |
|---|---|
| ≤10 lines, command glue | POSIX `sh` |
| 10–100 lines, automation | `bash` + ShellCheck + strict mode |
| >100 lines, has data structures or error handling | Python (PEP 723 inline-deps) |
| Interactive shell config | `zsh` (or `bash` + ble.sh) |
| State management (packages, services, dotfiles) | chezmoi + Ansible, not shell |
| JSON / YAML / TOML processing | `jq` / `yq` / `dasel` / Python |

Shell is a great glue language. It is a poor general-purpose language.
Knowing the boundary — and writing the right kind of file on the right
side of it — is most of what makes a dotfiles repo maintainable.

## Further reading

- [`shells/architecture.md`](architecture.md) — the 3-tier
  `shell/zsh/bash` layout in this repo
- [`shells/bash.md`](bash.md) — bash bootstrap, ble.sh, oh-my-bash init
  order
- [`shells/aliases.md`](aliases.md) — every alias and shell function
  this repo defines, tagged by tier
- [POSIX.1-2024 Shell Command Language](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html)
  — the actual standard
- [ShellCheck wiki](https://www.shellcheck.net/wiki/) — every code it
  emits, with explanations
- [Bash Pitfalls (Greg's wiki)](https://mywiki.wooledge.org/BashPitfalls)
  — the canonical "things that look right but aren't" list
