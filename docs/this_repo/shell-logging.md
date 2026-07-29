# Shell logging (`scripts/lib/log_shared.sh`)

One console-logging vocabulary for every shell script in this repo: `info` / `success` / `warn` / `error` / `die` / `skip`, plus section headings and a lightweight pass/fail counter.

---

## Why it exists

Before this file, 13 scripts each hand-rolled the same colour block and helper trio — in four mutually incompatible dialects:

| Dialect | Where |
|---|---|
| `echo -e "${BLUE}[INFO]${NC} $1"` | `run_once_before_00_bootstrap`, `run_after_25_bat_theme`, … |
| `printf '%b\n' "${_C_BLU}[INFO]${_C_RST} $*"` | `scripts/upgrade_tools.sh` |
| `printf '%s\n' "${_C_BLU}[INFO]${_C_RST} $*"` | `scripts/pre-commit-doctor.sh` |
| `printf "${CYAN}[INFO]${RESET}  %s\n" "$*"` | `scripts/import_ssh_to_bw.sh` |

`'\033'` (needs `%b`) and `$'\033'` (a real ESC) were mixed freely, `success` printed `[OK]` in two files and `[SUCCESS]` in the rest, colour was gated on `[[ -t 1 ]]` in three files and unconditional in the other ten, and [`NO_COLOR`](https://no-color.org) was honoured nowhere.

## Why not an off-the-shelf library

Real options exist — [bashlog](https://github.com/Zordrak/bashlog), [ShLog](https://www.jsware.io/shlog/), [lobash](https://github.com/adoyle-h/lobash) — and `gum log` is already installed on every machine by the `devtools` role. Two constraints rule all of them out:

1. **`run_once_before_00_bootstrap.sh.tmpl` runs before anything is installed.** It cannot depend on `gum`, or on a library it would have to `curl` down first.
2. **chezmoi renders every `run_*.sh.tmpl` to a temp path and executes it there.** At runtime the script has no reliable route back to the source tree, so `source` has nothing to resolve against.

Same reasoning as [`scripts/lib/sudo_shared.sh`](sudo-session.md), and the same solution.

---

## Consuming it

Two mechanisms, picked by whether the script has a stable path back to the source tree at runtime.

### Inlined — chezmoi run-scripts

```bash
# Set configuration BEFORE the include line.
LOG_STREAM=stdout
{{ include "scripts/lib/log_shared.sh" }}
```

`include`, not `includeTemplate` — the file is plain bash with no `{{ … }}` tokens to re-render.

!!! warning "Editing the lib re-triggers every `run_onchange_after_*` that inlines it"
    The inlined copy is part of the consuming script's bytes, so its hash changes. On the next `chezmoi apply` that means a full ansible re-run, a full `brew bundle`, a yazi plugin re-check, and so on across every host. Batch edits to this file.

### Sourced — `scripts/*.sh`

```bash
_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/log_shared.sh
# shellcheck disable=SC1091
source "$_REPO_ROOT/scripts/lib/log_shared.sh"
```

These only ever run from the repo checkout, so the path is stable.

### What can *not* consume it

Anything deployed to `$HOME`. `scripts/**` is listed in `.chezmoiignore.tmpl`, so this file never lands on a target machine — the only runtime copies are the inlined ones and a `source` from the checkout. `dot_config/television/executable_azure-rotate-ip.sh` keeps its own two-line `die`/`warn` pair for exactly this reason.

---

## API

### Message lines

All accept multiple arguments, joined with a single space.

| Call | Tag | Colour | Stream |
|---|---|---|---|
| `info "msg"` | `[INFO]` | blue | stdout |
| `success "msg"` | `[SUCCESS]` | green | stdout |
| `warn "msg"` | `[WARN]` | yellow | stdout |
| `error "msg"` | `[ERROR]` | red | stderr (see `LOG_STREAM`) |
| `skip "msg"` | `[SKIP]` | dim | stdout |
| `die "msg"` | `[ERROR]` | red | stderr, then `exit 1` |

`die` is always exit 1. Scripts with a documented exit-code contract — `pre-commit-doctor.sh` uses 0/1/2/3 — call `error` then `exit N` themselves.

### Structure

| Call | Effect |
|---|---|
| `step "Heading"` | blank line + bold heading |
| `hr` | dim horizontal rule |
| `dim "msg"` | unlabelled dim text (hints, echoed commands) |

### Verification mode

For one-shot "did this actually work" check scripts:

```bash
step "Checking the deploy"
[[ -f /etc/foo.conf ]] && ok "config present" || bad "config missing"
[[ -x /usr/bin/foo ]]  && ok "binary present" || bad "binary missing"
log_summary            # "2 passed, 0 failed"; returns 1 if anything failed
```

| Call | Effect |
|---|---|
| `ok "msg"` | `✔` green, bumps the pass counter |
| `bad "msg"` | `✘` red, bumps the fail counter |
| `log_summary` | prints `N passed, M failed`; returns 1 when `M > 0` |
| `log_fail_count` | echoes the current fail count |
| `log_reset_counters` | zeroes both counters |

!!! note "This is not a test framework"
    Committed, re-runnable tests belong in `tests/unit/*.bats` (`just bats`) — see [Testing](testing.md). Verification mode is for throwaway post-apply sanity scripts that still need a non-zero exit code.

### Palette

`_C_RED` `_C_GRN` `_C_YLW` `_C_BLU` `_C_CYN` `_C_MAG` `_C_DIM` `_C_BLD` `_C_RST`, exported for direct use. They hold real ESC characters, so they are safe with `printf '%s'`, `printf '%b'`, and `echo -e` alike. All are initialised empty at load, so a `set -u` script is safe even if `log_init` never runs.

---

## Configuration

Set these **before** the include/source line, or set them and re-run `log_init` by hand.

| Variable | Default | Effect |
|---|---|---|
| `LOG_PREFIX` | `''` | Replaces the `[INFO]`/`[WARN]`/… tag with one fixed label, e.g. `[raycast-sync]`. Colour still varies by severity. |
| `LOG_STREAM` | `split` | `split` → `error`/`die`/`bad` on stderr, everything else stdout. `stdout` → everything on stdout. |
| `NO_COLOR` | unset | Present and non-empty → colour off. |
| `CLICOLOR_FORCE` | unset | Non-empty and not `0` → colour on even when piped. |

`LOG_PREFIX` and `LOG_STREAM` are read at call time, so setting them after the source line also works. The palette is computed at load time — changing `NO_COLOR` afterwards needs a `log_init` re-run.

With neither colour variable set, colour is on iff stdout is a TTY and `TERM` is not `dumb`.

### `CLICOLOR_FORCE` deliberately beats `NO_COLOR`

This repo's yazi piper rules set `CLICOLOR_FORCE` to push colour through a pipe (see the glow contract in [yazi previews](../tools/yazi-previews.md)). An ambient `NO_COLOR` in the user's environment must not defeat that.

### Why every chezmoi run-script sets `LOG_STREAM=stdout`

`scripts/fleet/apply.py::_classify_drift()` is fed **real stderr lines** on the local-host path, and treats any line it does not recognise as "not pure drift" — the host is then reported `failed` instead of `drift`. All 13 pre-migration scripts printed their warnings on stdout, so they were invisible to that classifier. Routing them to stderr would silently turn benign `drift` results into `failed` ones. See the [fleet-apply](fleet-apply.md) invariants.

For the same reason `warn` stays on stdout even in `split` mode — that matches what all 13 scripts did before, and keeps `just upgrade-all 2>/dev/null` from swallowing 47 warnings in `upgrade_tools.sh`.

---

## Traps the implementation avoids

Three of these are invisible on inspection and are covered by `tests/unit/log_shared.bats`.

- **`(( x++ ))` under `set -e`.** The post-increment evaluates to the *old* value, so the very first counter bump (0 → 1) returns exit status 1 and kills the caller. The lib uses `x=$(( x + 1 ))` throughout.
- **No top-level `return`.** The file is *inlined*, not sourced, in nine of its consumers. A `return 0` double-inclusion guard would abort those scripts with `return: can only 'return' from a function or sourced script`.
- **`local IFS=' '` in every emitter.** `import_ssh_to_bw.sh` reassigns `IFS` for record splitting; without the pin, the tag and message get glued together with an ASCII unit separator.
- **`set -u` safety.** Palette variables and counters are initialised at file scope, not only inside `log_init`.

## Maintaining it

- `scripts/lib/*.sh` is covered by the pre-commit **shellcheck** hook (severity=warning). It is *not* covered by the **shfmt** hook — adding it there would reformat `sudo_shared.sh`'s entire 4-space indentation. Keep new code in `scripts/lib/` shfmt-compatible by hand (`shfmt -i 2 -ci -bn`).
- Adding a consumer means adding it to the wiring-guard test in `tests/unit/log_shared.bats` and to the `scripts/lib/log_shared.sh` row of `CLAUDE.md`. The test fails loudly if a consumer drops the include/source line or grows a private copy of the helpers back.
