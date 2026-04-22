# 29_log_tools.zsh - Log viewer helpers (tailspin / ccze)
#
# See docs/tools/log-tools.md for the full toolbelt rationale. These thin
# wrappers give the "bat for logs" feel without forcing users to remember
# each tool's exact flag set.

# --- catl: colorful cat for logs (tailspin in stdout mode) ---
# Usage: catl app.log | less -R
#        catl app.log err.log       (concatenates like cat, colors both)
# Requires: tspin (from the tailspin homebrew/GitHub binary, see devtools role).
if command -v tspin &>/dev/null; then
    catl() {
        # `tspin --print` reads from stdin and from positional file args,
        # and writes ANSI-colored output to stdout (no pager). That is the
        # composition-friendly mode we want for pipes.
        command tspin --print "$@"
    }
fi

# --- lessl: classic ccze + less pipeline ---
# Usage: lessl app.log
#        tail -f app.log | lessl
# Requires: ccze, less. Uses -A (raw ANSI) so `less -R` can render colors.
if command -v ccze &>/dev/null; then
    lessl() {
        if (( $# == 0 )); then
            command ccze -A | command less -RSFX
        else
            command ccze -A < "$1" | command less -RSFX
        fi
    }
fi

# --- logtail: tail -f with live tailspin highlighting ---
# Usage: logtail app.log
# Prefers `tspin --follow` (native watch mode) when available; otherwise
# falls back to `tail -F | tspin --print` so the highlighting still works on
# older tailspin builds that lack --follow.
logtail() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: logtail <file>" >&2
        return 2
    fi
    if command -v tspin &>/dev/null; then
        if command tspin --help 2>/dev/null | grep -q -- '--follow'; then
            command tspin --follow "$1"
        else
            command tail -F "$1" | command tspin --print
        fi
    else
        command tail -F "$1"
    fi
}

# --- svclog: follow a service log, cross-platform (systemd / launchd) ---
# Usage: svclog SERVICE              (system scope by default)
#        svclog --user SERVICE       (systemd user scope on Linux)
# On Linux: journalctl -fu SERVICE | tspin
# On macOS: tail -F the plist's StdoutPath | tspin, else log stream by process
svclog() {
    emulate -L zsh
    local scope=system
    if [[ "$1" == "--user" ]]; then
        scope=user
        shift
    fi
    if [[ $# -eq 0 ]]; then
        echo "Usage: svclog [--user] <service>" >&2
        return 2
    fi
    local name="$1"
    local os
    os="$(uname -s)"
    local colorize='if command -v tspin &>/dev/null; then tspin --print; else cat; fi'

    if [[ "$os" == "Linux" ]]; then
        if [[ "$scope" == user ]]; then
            journalctl --user -fu "$name" | eval "$colorize"
        else
            if sudo -n true 2>/dev/null; then
                sudo journalctl -fu "$name" | eval "$colorize"
            else
                journalctl -fu "$name" | eval "$colorize"
            fi
        fi
    elif [[ "$os" == "Darwin" ]]; then
        local dom
        if [[ "$scope" == user ]]; then
            dom="gui/${UID:-$(id -u)}"
        else
            dom="system"
        fi
        local path
        path="$(launchctl print "$dom/$name" 2>/dev/null \
            | awk -F'= ' '/^[ \t]+stdout path / || /^[ \t]+standard out path /{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')"
        if [[ -n "$path" && -f "$path" ]]; then
            tail -F "$path" | eval "$colorize"
        else
            echo "[svclog] No StdoutPath for $dom/$name — streaming via log stream..."
            log stream --predicate "process == \"$name\"" --style syslog | eval "$colorize"
        fi
    else
        echo "svclog: unsupported OS: $os" >&2
        return 1
    fi
}

# --- svcstat: show full status / launchctl print for a service ---
# Usage: svcstat SERVICE           (system scope on both OSes)
#        svcstat --user SERVICE    (systemd user scope / macOS gui domain)
svcstat() {
    emulate -L zsh
    local scope=system
    if [[ "$1" == "--user" ]]; then
        scope=user
        shift
    fi
    if [[ $# -eq 0 ]]; then
        echo "Usage: svcstat [--user] <service>" >&2
        return 2
    fi
    local name="$1"
    local os
    os="$(uname -s)"
    if [[ "$os" == "Linux" ]]; then
        if [[ "$scope" == user ]]; then
            systemctl --user status "$name" --no-pager -l
        else
            systemctl status "$name" --no-pager -l
        fi
    elif [[ "$os" == "Darwin" ]]; then
        local dom
        if [[ "$scope" == user ]]; then
            dom="gui/${UID:-$(id -u)}"
        else
            dom="system"
        fi
        launchctl print "$dom/$name" 2>/dev/null \
            || { [[ "$scope" == system ]] && sudo launchctl print "system/$name"; } \
            || echo "No launchctl print output for $dom/$name"
    else
        echo "svcstat: unsupported OS: $os" >&2
        return 1
    fi
}
