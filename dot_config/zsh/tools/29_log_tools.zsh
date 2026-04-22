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
