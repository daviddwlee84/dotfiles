# Plan: `abspath` — a unified absolute-path printer (pwd-equivalent, file-aware)

## Context

`pwd` only prints the current directory and errors on a file argument. There's no
one-shot way to grab a **file's** absolute path for copying. Today `x`'s own help
even tells users to run `realpath FILE | x copy` — so this formalizes an existing
gap. We want one command that:

- with **no args** behaves like `pwd` (logical cwd), and
- with **file/dir args** prints each argument's absolute path,
- works on **macOS + Linux**, and
- pairs with the existing `x` clipboard CLI via a pipe: `abspath FILE | x copy`.

Decisions (confirmed with user):

- **Form factor**: POSIX shell function in `dot_config/shell/`, sourced by both
  shells — mirrors the closest sibling `tpath` (`63_tmux_path.sh`). Lightest option:
  one new file + one docs row, **no** completion files (shells default to file
  completion for a function's args), **no** SKILL.md/tool-managers churn (those rules
  fire only for new prompt keys or `executable_*` bin CLIs).
- **Symlinks**: **logical by default** (normalize `.`/`..` lexically, keep symlinks,
  don't require existence — matches `pwd`); `-r`/`--resolve` for canonical/physical.
- **User extras**: `-t`/`--tilde` flag to abbreviate a `$HOME`-rooted result to `~`;
  behavior toggled by flags (not separate commands).

## Key constraint (the one real trap)

Python's `os.getcwd()` returns the **physical** cwd (symlinks resolved), so
`os.path.abspath('.')` would NOT equal the shell's logical `pwd`. The logical base
**must** come from the shell's `$PWD`, passed into Python explicitly. Resolve mode
(`-r`) intentionally uses `os.path.realpath` (physical) instead.

Portability core = **python3 `os.path`**, matching the repo's established pattern
(`executable_x:file_uri_payload`, `96_ssh_setup.sh`) rather than juggling BSD-vs-GNU
`realpath`/`readlink -f` flags (the repo has zero `realpath`/`readlink -f` calls).

## File to create

`dot_config/shell/58_abspath.sh` (unused `58_` slot; sits in the 55–63 path/clipboard
cluster next to `56_clipboard_history` and `63_tmux_path`). Style mirrors
`63_tmux_path.sh` and `62_agent_wakeup.sh`: header comment block, `_underscore`
private locals, usage + errors to **stderr**, stdout kept **pipe-clean**, capture rc,
`unset`, `return $rc`.

Proposed contents:

```sh
# ~/.config/shell/58_abspath.sh
# Source: dot_config/shell/58_abspath.sh (managed by chezmoi)
#
# `abspath` — print absolute path(s), POSIX, sourced by both zsh and bash.
#   - no args  -> behaves like `pwd` (LOGICAL cwd, symlinks intact)
#   - FILE...  -> one absolute path per line
#   -r/--resolve : resolve symlinks to the physical path (requires existence)
#   -t/--tilde   : abbreviate a $HOME-rooted result to `~`
# Pairs with the `x` clipboard CLI:  abspath FILE | x copy
#
# stdout is pipe-clean (paths only); usage/errors go to stderr.
#
# Logical base MUST be the shell's $PWD, not python's os.getcwd() (which is
# physical / symlink-resolved) — otherwise no-arg output wouldn't equal `pwd`.

_abspath_usage() {
    printf '%s\n' \
        "Usage: abspath [-r|--resolve] [-t|--tilde] [--] [PATH...]" \
        "  (no PATH) print the current directory, like pwd" \
        "  PATH...   print each path's absolute form, one per line" \
        "  -r        resolve symlinks to the physical path (must exist)" \
        "  -t        abbreviate a \$HOME-rooted result to ~" \
        "Examples:" \
        "  abspath                 # == pwd" \
        "  abspath foo.py ../bar   # absolute paths" \
        "  abspath -t ~/notes.md   # ~/notes.md" \
        "  abspath foo.py | x copy"
}

abspath() {
    _ap_resolve=0
    _ap_tilde=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -r|--resolve) _ap_resolve=1; shift ;;
            -t|--tilde)   _ap_tilde=1;   shift ;;
            -h|--help)    _abspath_usage; unset _ap_resolve _ap_tilde; return 0 ;;
            --)           shift; break ;;
            -*)           printf 'abspath: unknown option: %s\n' "$1" >&2
                          _abspath_usage >&2
                          unset _ap_resolve _ap_tilde; return 2 ;;
            *)            break ;;
        esac
    done

    if ! command -v python3 >/dev/null 2>&1; then
        printf 'abspath: python3 required for path normalization\n' >&2
        unset _ap_resolve _ap_tilde; return 127
    fi

    ABSPATH_BASE="$PWD" ABSPATH_RESOLVE="$_ap_resolve" ABSPATH_TILDE="$_ap_tilde" \
        python3 - "$@" <<'PY'
import os, sys

base    = os.environ.get("ABSPATH_BASE") or os.getcwd()
resolve = os.environ.get("ABSPATH_RESOLVE") == "1"
tilde   = os.environ.get("ABSPATH_TILDE") == "1"
home    = os.path.expanduser("~")
args    = sys.argv[1:] or ["."]          # no args -> current dir, like pwd
rc = 0

def abbrev(p):
    if not tilde:
        return p
    if p == home:
        return "~"
    if p.startswith(home + os.sep):
        return "~" + p[len(home):]
    return p

for a in args:
    joined = a if os.path.isabs(a) else os.path.join(base, a)
    if resolve:
        p = os.path.realpath(joined)     # physical; follows symlinks
        if not os.path.exists(p):
            sys.stderr.write("abspath: no such file or directory: %s\n" % a)
            rc = 1
            continue
    else:
        p = os.path.normpath(joined)     # lexical; keeps symlinks, no existence req.
    print(abbrev(p))

sys.exit(rc)
PY
    _ap_rc=$?
    unset _ap_resolve _ap_tilde
    return "$_ap_rc"
}
```

Notes:
- No source-time `command -v` guard (unlike `tpath`'s tmux guard): python3 is
  effectively always present, and we want `abspath` defined everywhere — the
  dependency is checked at call time with a clear stderr error + rc 127.
- `_ap_rc` is captured before `unset` so the python exit code propagates
  (nonexistent path in `-r` mode → rc 1; used by scripts/pipes).

## Docs to update (required by the repo contract)

`docs/shells/aliases.md` — add one row for `abspath` (name / type=function /
source=`dot_config/shell/58_abspath.sh` / scope=both shells / one-line desc).
Place it in the general shell-utility section (near the clipboard/path helpers,
not the Tmux Integration block where `tpath` lives). This is the only doc the
"alias / shell function in `dot_config/{shell,zsh,bash}/`" rule mandates.

No other surfaces apply: not a package-managed tool (skip `tool-managers.md`), not
an `executable_*` bin CLI or new prompt key (skip `SKILL.md.tmpl`), and function
args get default file completion in both shells (skip the two completion files).

## Verification (end-to-end, both shells)

From the repo, apply then exercise in a real shell:

1. `chezmoi apply --include=files ~/.config/shell/58_abspath.sh` (or `just`-apply),
   then `exec zsh` and repeat under `exec bash`.
2. `shellcheck -s sh dot_config/shell/58_abspath.sh` — expect clean (POSIX only).
3. Equivalence: `abspath` and `pwd` print the **same** string (incl. inside a
   symlinked directory — verifies the `$PWD`-base fix, not python's physical cwd).
4. Files: `abspath foo.py ../bar` → two absolute, normalized lines; nonexistent
   path in default mode still prints (logical), no error.
5. `-t`: `cd ~ && abspath notes.md` → `~/notes.md`; a non-HOME path stays absolute.
6. `-r`: create `ln -s /real/dir link`; `abspath -r link` → `/real/dir`;
   `abspath -r missing` → stderr error, `echo $?` = 1.
7. Pipe integration: `abspath foo.py | x copy` then `x paste` round-trips the path.
8. Usage/errors: `abspath -h` prints usage to stdout(0); `abspath --bogus` → stderr
   usage, rc 2 — confirm stdout stays clean so pipes aren't polluted.
```
