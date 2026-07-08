# ~/.config/shell/59_cref.sh
# Source: dot_config/shell/59_cref.sh (managed by chezmoi)
#
# `cref` — copy a Cursor / Claude-Code-style file reference (@path:line) to the
# clipboard. The shell twin of the Neovim <leader>y copy-reference maps
# (docs/neovim/copy-reference.md). POSIX, sourced by both zsh and bash.
#
#   cref FILE                 -> @relpath
#   cref FILE:12              -> @relpath:12
#   cref FILE:12-40           -> @relpath:12-40
#   cref FILE 12 40           -> @relpath:12-40      (line info as positionals)
#   cref FILE:12:5            -> @relpath:12         (grep/rg :col[:text] dropped)
#   rg -n foo | cref          -> ref from the first ripgrep/grep match line
#
# Path flavor: default = git-root-relative (falls back to cwd/~/absolute the way
# nvim's `:~:.` does); -a/--absolute = machine-absolute; -c/--cwd = relative to
# $PWD. Reuses the same python path math as `abspath` (58_abspath.sh).
#
# Copies via the `x` clipboard CLI (OSC 52, SSH-safe) by default; -n/--no-copy
# prints only. stdout stays pipe-clean (just the @ref); the "Copied …" toast and
# all diagnostics go to stderr — same contract as `abspath` / `tpath`.

_cref_usage() {
    printf '%s\n' \
        "Usage: cref [-a|--absolute] [-c|--cwd] [-L|--no-line] [-n|--no-copy] [--] FILE[:LINE[-LINE]] [LINE [ENDLINE]]" \
        "  Build a @file:line reference (a Claude/Cursor file-mention) and copy it." \
        "  Default path is relative to the git root; falls back to cwd/~ then absolute." \
        "  -a  machine-absolute path" \
        "  -c  path relative to the current directory" \
        "  -L  drop the line suffix (bare @path)" \
        "  -n  print only, do not copy to the clipboard" \
        "  With no FILE, reads one line from stdin (grep/ripgrep FILE:LINE:… format)." \
        "Examples:" \
        "  cref src/app.py:42          # copies @src/app.py:42" \
        "  cref -a src/app.py:10-20    # @/abs/src/app.py:10-20" \
        "  rg -n TODO | cref           # ref from ripgrep's first match"
}

cref() {
    _cref_flavor=git
    _cref_noline=0
    _cref_nocopy=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -a|--absolute) _cref_flavor=abs; shift ;;
            -c|--cwd)      _cref_flavor=cwd; shift ;;
            -L|--no-line)  _cref_noline=1;   shift ;;
            -n|--no-copy)  _cref_nocopy=1;   shift ;;
            -h|--help)     _cref_usage
                           unset _cref_flavor _cref_noline _cref_nocopy; return 0 ;;
            --)            shift; break ;;
            -*)            printf 'cref: unknown option: %s\n' "$1" >&2
                           _cref_usage >&2
                           unset _cref_flavor _cref_noline _cref_nocopy; return 2 ;;
            *)             break ;;
        esac
    done

    if ! command -v python3 >/dev/null 2>&1; then
        printf 'cref: python3 required for path handling\n' >&2
        unset _cref_flavor _cref_noline _cref_nocopy; return 127
    fi

    # No FILE arg -> read one line from stdin (grep/ripgrep/quickfix FILE:LINE:…).
    # A bare interactive `cref` (stdin is a TTY) prints usage instead of hanging.
    if [ "$#" -eq 0 ]; then
        if [ -t 0 ]; then
            _cref_usage >&2
            unset _cref_flavor _cref_noline _cref_nocopy; return 2
        fi
        IFS= read -r _cref_line || _cref_line=""
        if [ -z "$_cref_line" ]; then
            printf 'cref: empty input\n' >&2
            unset _cref_flavor _cref_noline _cref_nocopy _cref_line; return 2
        fi
        set -- "$_cref_line"
        unset _cref_line
    fi

    _cref_root="$(git rev-parse --show-toplevel 2>/dev/null)" || _cref_root=""

    _cref_ref="$(
        CREF_FLAVOR="$_cref_flavor" CREF_ROOT="$_cref_root" CREF_BASE="$PWD" \
        CREF_NOLINE="$_cref_noline" python3 - "$@" <<'PY'
import os, re, sys

flavor = os.environ.get("CREF_FLAVOR", "git")
root   = os.environ.get("CREF_ROOT", "")
base   = os.environ.get("CREF_BASE") or os.getcwd()
home   = os.path.expanduser("~")
noline = os.environ.get("CREF_NOLINE") == "1"

argv = [a for a in sys.argv[1:] if a != ""]
if not argv:
    sys.stderr.write("cref: no file given\n")
    sys.exit(2)

token = argv[0]
extra = argv[1:]

# Peel a trailing :LINE[-LINE] off the token, dropping any grep/rg :col[:text].
# Non-greedy file part lets a colon inside the path survive (a:b.py:10 -> a:b.py).
a = b = None
file = token
m = re.match(r'^(?P<file>.*?):(?P<a>\d+)(?:-(?P<b>\d+))?(?::\d+)?(?::.*)?$', token)
if m:
    file = m.group("file")
    a = int(m.group("a"))
    b = int(m.group("b")) if m.group("b") else None

# Line info can instead come from trailing positionals: `cref FILE 12 40`.
if a is None and extra:
    joined = "-".join(extra[:2]) if len(extra) >= 2 else extra[0]
    me = re.match(r'^(\d+)(?:-(\d+))?$', joined)
    if me:
        a = int(me.group(1))
        b = int(me.group(2)) if me.group(2) else None

suffix = ""
if not noline and a is not None:
    if b is not None and b != a:
        lo, hi = (a, b) if a <= b else (b, a)
        suffix = ":%d-%d" % (lo, hi)
    else:
        suffix = ":%d" % a

# Absolutize the file logically against $PWD (matches abspath default / nvim :p).
absf = file if os.path.isabs(file) else os.path.join(base, file)
absf = os.path.normpath(absf)

def abbrev_home(p):
    if p == home:
        return "~"
    if p.startswith(home + os.sep):
        return "~" + p[len(home):]
    return p

if flavor == "abs":
    path = absf
elif flavor == "cwd":
    path = os.path.relpath(absf, base)
else:  # git-root, with nvim-style :~:. fallback (cwd -> ~ -> absolute)
    path = None
    if root:
        # Resolve both sides so they share a symlink space (git toplevel is
        # already realpath'd); makes the relative form work even across symlinks.
        rrel = os.path.relpath(os.path.realpath(absf), os.path.realpath(root))
        if not rrel.startswith(".."):
            path = rrel
    if path is None:
        crel = os.path.relpath(absf, base)
        path = crel if not crel.startswith("..") else abbrev_home(absf)

sys.stdout.write("@" + path + suffix)
PY
    )"
    _cref_rc=$?
    if [ "$_cref_rc" -ne 0 ]; then
        unset _cref_flavor _cref_noline _cref_nocopy _cref_root _cref_ref _cref_rc
        return "$_cref_rc"
    fi

    if [ "$_cref_nocopy" -eq 0 ]; then
        if command -v x >/dev/null 2>&1; then
            if printf '%s' "$_cref_ref" | x copy >/dev/null; then
                printf 'Copied %s\n' "$_cref_ref" >&2
            else
                printf 'cref: clipboard copy failed; ref on stdout\n' >&2
            fi
        else
            printf 'cref: x CLI not found; ref on stdout (pipe it to a clipboard tool)\n' >&2
        fi
    fi
    printf '%s\n' "$_cref_ref"

    unset _cref_flavor _cref_noline _cref_nocopy _cref_root _cref_ref _cref_rc
}
