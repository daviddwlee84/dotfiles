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
