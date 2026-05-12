# ~/.config/shell/61_tmux_summary.sh
# Source: dot_config/shell/61_tmux_summary.sh (managed by chezmoi)
#
# `tsum` — AI-powered overview of every tmux session. Thin POSIX wrapper
# around ~/.config/tmux/tmux-session-summary.py (the core script does the
# capture, LLM call, 10-min caching, and rendering).
#
# Why a wrapper at all (not just an alias):
#   - `-i` / `--interactive` adds an fzf picker on top of the script's
#     `picker` mode and calls `tmux switch-client -t <sess>` on Enter.
#     fzf piping is awkward to express as an alias.
#   - The wrapper does an early-return-silent dance when tmux isn't on PATH
#     (cron, fresh boxes pre-ansible) so calling code can be unconditional.
#
# See:
#   - dot_config/tmux/executable_tmux-session-summary.py (the core)
#   - docs/shells/aliases.md (`tsum` row)
#   - dot_config/zsh/tools/04_ai_capture.zsh (shares AICAP_* env vars)
#   - dot_config/shell/60_tmux_status.sh (this file's slot-61 neighbour)

# Skip silently if tmux isn't installed — POSIX-shared file, may be sourced
# inside cron / Docker / headless SSH long before ansible bootstrapped tmux.
command -v tmux >/dev/null 2>&1 || return 0

tsum() {
    _tsum_script="$HOME/.config/tmux/tmux-session-summary.py"
    if [ ! -x "$_tsum_script" ]; then
        printf 'tsum: %s missing or not executable. Run `chezmoi apply` first.\n' "$_tsum_script" >&2
        return 1
    fi

    _tsum_interactive=0
    _tsum_forward=""

    # POSIX-portable arg parse — `getopts` can't do long flags, so do it by
    # hand. Everything except `-i`/`--interactive` is forwarded as-is to the
    # Python script (which has its own argparse).
    while [ $# -gt 0 ]; do
        case "$1" in
            -i|--interactive)
                _tsum_interactive=1
                ;;
            -h|--help)
                cat >&2 <<'EOF'
tsum — AI-summarize every tmux session

USAGE
    tsum [list]                 print one-block-per-session summary (default)
    tsum picker                 print TSV (session<TAB>line) for fzf piping
    tsum -i | --interactive     fzf picker; Enter switches client to that session
    tsum -d | --deep            include visible area (20-100 lines) of each
                                session's active pane in the LLM prompt
    tsum --shallow              force metadata-only (overrides TSUM_DEEP_DEFAULT=1)
    tsum --sort closability     order keep → check → safe (default: alphabetical)
    tsum --only safe|check|keep filter to one closability tier
    tsum -r | --refresh         bypass the prompt-hash cache and force a fresh LLM call
    tsum --dry-run              print what would be sent to the LLM (no API call)
    tsum --no-cache             don't read or write the cache

EXAMPLES
    tsum --sort closability     active work surfaces first, idle stuff last
    tsum --only safe            "what can I close right now?"
    tsum picker --only safe -i  fzf-pick a safe-to-close session to switch to

ENV
    AICAP_AGENT, AICAP_*_MODEL  pin / override the agent (shared with aifix/aiblock)
    TSUM_DEEP_DEFAULT=1         make --deep implicit (override per-call with --shallow)
    TSUM_MIN_REFRESH_INTERVAL   seconds, default 120. Even when the prompt
                                hash differs from the cached one, reuse the
                                old summary if the previous LLM call was
                                within this window (protects against high-
                                volatility deep-mode panes like htop/watch).
                                Identical prompts always hit, regardless of
                                age. Set to 0 to disable throttling.
                                TSUM_CACHE_TTL accepted as fallback alias.
    TSUM_TIMEOUT                seconds, default 60
    TSUM_TMUX_BIN               full path to tmux binary, default "tmux" (use this
                                when multiple tmux binaries are on PATH and the
                                server you care about runs from a specific one,
                                e.g. TSUM_TMUX_BIN=/bin/tmux)

CACHE
    $XDG_CACHE_HOME/tmux-session-summary/<hostname>-<mode>.json
    (cache key is sha256(build_prompt)[:16] — identical prompts hit forever;
     differing prompts trigger a fresh LLM call unless throttled by
     TSUM_MIN_REFRESH_INTERVAL)
EOF
                return 0
                ;;
            *)
                # Quote each forwarded arg with single quotes; embedded single
                # quotes get the '\'' dance so eval-time re-parsing is exact.
                _tsum_forward="$_tsum_forward '$(printf %s "$1" | sed "s/'/'\\\\''/g")'"
                ;;
        esac
        shift
    done

    if [ "$_tsum_interactive" -eq 0 ]; then
        # Plain mode — let the script render to stdout/stderr directly.
        eval "\"\$_tsum_script\" $_tsum_forward"
        return $?
    fi

    # Interactive: picker | fzf, switch on Enter.
    if ! command -v fzf >/dev/null 2>&1; then
        printf 'tsum: -i needs fzf on PATH; falling back to plain output.\n' >&2
        eval "\"\$_tsum_script\" $_tsum_forward"
        return $?
    fi

    # Force `picker` mode regardless of what got forwarded (silently strip
    # `list`/`picker` from the forwarded args by re-running with picker as
    # the explicit first arg).
    _tsum_selected=$(
        eval "\"\$_tsum_script\" picker $_tsum_forward" \
            | fzf --ansi \
                  --delimiter='	' \
                  --with-nth=2 \
                  --preview='printf "%s\n" {2}' \
                  --preview-window='down:3:wrap' \
                  --prompt='session> ' \
                  --header='Enter: switch  /  Esc: cancel' \
                  --no-multi
    )

    [ -z "$_tsum_selected" ] && return 0

    # First TAB-delimited field is the session name.
    _tsum_target="${_tsum_selected%%	*}"

    # Honour TSUM_TMUX_BIN — see dot_config/tmux/executable_tmux-session-summary.py
    # for the version-mismatch rationale. switch-client / attach-session MUST
    # use the same binary that owns the running server.
    _tsum_tmux_bin="${TSUM_TMUX_BIN:-tmux}"
    if [ -z "${TMUX:-}" ]; then
        # Outside tmux: attach to the chosen session instead of switch-client.
        "$_tsum_tmux_bin" attach-session -t "$_tsum_target"
    else
        "$_tsum_tmux_bin" switch-client -t "$_tsum_target"
    fi
}
