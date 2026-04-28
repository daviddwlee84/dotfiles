# 23_mrun.zsh — fire-and-forget into a detached tmux/zellij session
#
# Replaces the manual flow of `tmux → run command → detach`. Creates a fresh
# detached multiplexer session at $PWD, runs CMD inside it, returns
# immediately, prints an attach hint to stderr.
#
# Public API:
#   mrun [-b tmux|zellij] [-n NAME] [-d DIR] [-f|--force] [--no-detach] [--] CMD [ARGS...]
#   tmrun ...   # mrun -b tmux
#   zjrun ...   # mrun -b zellij
#
# Env: MRUN_BACKEND=tmux|zellij overrides the default (tmux).
#
# Sibling helpers: sesh-here / sesh-root / sesh-code / sesh-vibe in
# 22_sesh.zsh — those *attach you*, mrun does not.

if ! command -v tmux >/dev/null 2>&1 && ! command -v zellij >/dev/null 2>&1; then
    return 0
fi

# tmux forbids `.` and `:` in session names; we also strip whitespace.
# Inlined (not reusing _sesh_sanitize) so this file works even when sesh
# isn't installed and 22_sesh.zsh has early-returned.
function _mrun_sanitize() {
    print -r -- "${1//[.:[:space:]]/-}"
}

function _mrun_default_name() {
    # $RANDOM must be consumed in the *caller's* shell (passed as $1).
    # Reading $RANDOM inside a $(_mrun_default_name) subshell yields the same
    # value on every consecutive call because the parent's RANDOM sequence
    # never advances — the subshell forks from a frozen seed each time.
    local base seed="$1"
    base=$(_mrun_sanitize "$(basename "$PWD")")
    printf 'run-%s-%04x' "$base" "$seed"
}

# Detach a backgrounded command from the current shell. Mirrors
# scripts/lib/sudo_shared.sh:_sudo_spawn_watchdog — `setsid(1)` is the clean
# path on Linux but absent from base macOS, so fall back to nohup+disown.
# See pitfalls/sudo-shared-setsid-macos.md.
function _mrun_spawn_detached() {
    if command -v setsid >/dev/null 2>&1; then
        setsid "$@" </dev/null >/dev/null 2>&1 &
    else
        nohup "$@" </dev/null >/dev/null 2>&1 &
    fi
    disown 2>/dev/null || true
}

# Escape a string for embedding in a "..."-quoted KDL value.
# Order matters: backslashes first, then double-quotes.
function _mrun_kdl_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    print -r -- "$s"
}

function _mrun_warn_if_tui() {
    case "$1" in
        vim|nvim|emacs|less|more|man|htop|top|btop|btm|lazygit|lazydocker|tig|k9s|ranger|yazi|nnn|mc|gitui)
            echo "mrun: '$1' is interactive — you'll need to attach to use it." >&2
            ;;
    esac
}

function _mrun_tmux() {
    local session="$1" workdir="$2" force="$3" no_detach="$4"; shift 4
    if tmux has-session -t "=$session" 2>/dev/null; then
        if (( force )); then
            tmux kill-session -t "=$session" 2>/dev/null
        else
            echo "mrun: tmux session '$session' already exists. Use -f to replace, or pick a different -n NAME." >&2
            return 1
        fi
    fi
    local cmd
    cmd=$(printf '%s ' "$@")
    cmd="${cmd% }"
    tmux new-session -d -s "$session" -c "$workdir" -n run sh -c "$cmd" || return 1
    if [[ -n "$TMUX" ]]; then
        echo "mrun[tmux]: started '$session'. Attach: tmux switch-client -t $session" >&2
    else
        echo "mrun[tmux]: started '$session'. Attach: tmux attach -t $session" >&2
    fi
    if (( no_detach )); then
        if [[ -n "$TMUX" ]]; then
            tmux switch-client -t "$session"
        else
            tmux attach -t "$session"
        fi
    fi
}

function _mrun_zellij() {
    local session="$1" workdir="$2" force="$3" no_detach="$4"; shift 4
    if zellij list-sessions --no-formatting --short 2>/dev/null | grep -qx "$session"; then
        if (( force )); then
            zellij delete-session --force "$session" >/dev/null 2>&1
        else
            echo "mrun: zellij session '$session' already exists. Use -f to replace, or pick a different -n NAME." >&2
            return 1
        fi
    fi

    local cmd esc_cmd esc_dir layout
    cmd=$(printf '%s ' "$@")
    cmd="${cmd% }"
    esc_cmd=$(_mrun_kdl_escape "$cmd")
    esc_dir=$(_mrun_kdl_escape "$workdir")

    layout=$(mktemp "${TMPDIR:-/tmp}/mrun-layout-XXXXXX") || return 1
    cat >"$layout" <<EOF
layout {
    tab name="run" {
        pane cwd="$esc_dir" {
            command "sh"
            args "-c" "$esc_cmd"
        }
    }
}
EOF
    # Layout file is intentionally NOT deleted: zellij re-reads it on session
    # resurrection. ~200B leak per invocation; /tmp GC handles it.

    if [[ -n "$ZELLIJ" ]]; then
        echo "mrun[zellij]: warning — already inside zellij session '$ZELLIJ'." >&2
        echo "             New session '$session' runs in parallel; detach (Ctrl+o d) before attaching." >&2
    fi

    if (( no_detach )); then
        zellij --layout "$layout" attach --create "$session"
    else
        _mrun_spawn_detached zellij --layout "$layout" attach --create "$session"
        echo "mrun[zellij]: started '$session'. Attach: zellij attach $session" >&2
    fi
}

function mrun() {
    local backend="${MRUN_BACKEND:-tmux}" name="" workdir="$PWD"
    local force=0 no_detach=0
    while (( $# > 0 )); do
        case "$1" in
            -b|--backend)   backend="$2"; shift 2 ;;
            -n|--name)      name="$2"; shift 2 ;;
            -d|--dir)       workdir="$2"; shift 2 ;;
            -f|--force)     force=1; shift ;;
            --no-detach)    no_detach=1; shift ;;
            --)             shift; break ;;
            -h|--help)
                cat <<'EOF' >&2
mrun — fire a command into a detached tmux/zellij session

Usage:
  mrun [-b tmux|zellij] [-n NAME] [-d DIR] [-f] [--no-detach] [--] CMD [ARGS...]
  tmrun ...   # forces -b tmux
  zjrun ...   # forces -b zellij

Options:
  -b BACKEND    tmux (default) or zellij. Override default via $MRUN_BACKEND.
  -n NAME       session name (default: run-<dir>-<rand>).
  -d DIR        working directory for the inner command (default: $PWD).
  -f, --force   kill an existing session of the same name before creating.
  --no-detach   attach immediately after creating (debug aid).
  --            explicit end of mrun flags; everything after is the command.

For an interactive shell session at $PWD use shere (sesh-here) instead.
Note: with default tmux config, sessions vanish when CMD exits — that's the
point of fire-and-forget. Use `--no-detach` or `tmux set -g remain-on-exit on`
to debug a command that exits unexpectedly.
EOF
                return 0 ;;
            -*) echo "mrun: unknown flag '$1' (try --help)" >&2; return 2 ;;
            *)  break ;;
        esac
    done

    if (( $# == 0 )); then
        echo "mrun: no command given. Try: mrun -- echo hi" >&2
        echo "      For an interactive shell session use 'shere' instead." >&2
        return 2
    fi

    if [[ -z "$name" ]]; then
        # Bind to a local *first* so $RANDOM is read in this shell. Inlining
        # `$((RANDOM…))` directly inside `$(_mrun_default_name …)` evaluates
        # the arithmetic inside the command-substitution subshell, where the
        # parent's RANDOM sequence never advances → identical seeds.
        local _seed=$((RANDOM % 65536))
        name=$(_mrun_default_name "$_seed")
    fi
    name=$(_mrun_sanitize "$name")

    _mrun_warn_if_tui "$1"

    case "$backend" in
        tmux)
            command -v tmux >/dev/null 2>&1 \
                || { echo "mrun: tmux not installed." >&2; return 1; }
            _mrun_tmux "$name" "$workdir" "$force" "$no_detach" "$@"
            ;;
        zellij)
            command -v zellij >/dev/null 2>&1 \
                || { echo "mrun: zellij not installed." >&2; return 1; }
            _mrun_zellij "$name" "$workdir" "$force" "$no_detach" "$@"
            ;;
        *)
            echo "mrun: unknown backend '$backend' (expected tmux or zellij)." >&2
            return 2
            ;;
    esac
}

function tmrun() { mrun -b tmux   "$@"; }
function zjrun() { mrun -b zellij "$@"; }
