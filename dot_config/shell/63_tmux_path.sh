# ~/.config/shell/63_tmux_path.sh
# Source: dot_config/shell/63_tmux_path.sh (managed by chezmoi)
#
# `tpath` — print + copy the CURRENT tmux pane's address, POSIX, sourced by
# both zsh and bash. Copies the readable target `session:window.pane` (e.g.
# `main:2.1`) to the system clipboard via tmux's OSC 52 bridge, and prints
# `target` / `pane_id` / `cwd` to stdout for reference.
#
# Why: when a human and an AI agent share a tmux session, you need a quick way
# to grab the pane you're looking at — to reconnect later, or to tell the agent
# "operate on THIS pane" (`tmux capture-pane -pt <target>` /
# `tmux send-keys -t <target> ...`). The stable `pane_id` (%N, survives
# window/pane reordering) and cwd are printed alongside so you can paste the
# richer form into an agent chat when the readable target isn't enough.
#
# GUI/keyboard equivalents (same "Copy pane path" action):
#   - right-click a pane → "Copy pane path"   (MouseDown3Pane menu)
#   - prefix + M-p → "Copy pane path"          (menu-pane.sh)
#   - prefix + P                               (direct keybinding)
# All defined in dot_config/tmux/keybindings.conf.tmpl + menu-pane.sh.
#
# stdout is kept pipe-clean (`tpath | head -1` yields the target line); the
# "copied" confirmation goes to stderr.

# Skip silently if tmux isn't on PATH (cron, headless SSH, fresh box).
command -v tmux >/dev/null 2>&1 || return 0

# tpath — copy current pane's session:window.pane to clipboard, print details.
tpath() {
    if [ -z "${TMUX:-}" ]; then
        printf 'tpath: not inside a tmux session\n' >&2
        return 1
    fi

    _tpath_target=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}')
    _tpath_id=$(tmux display-message -p '#{pane_id}')
    _tpath_cwd=$(tmux display-message -p '#{pane_current_path}')

    # Copy ONLY the readable target. `set-buffer -w` loads tmux's paste buffer
    # AND forwards via OSC 52 (needs `set-clipboard on` in common.conf) — works
    # over SSH without shelling out to pbcopy/xclip on the remote host.
    tmux set-buffer -w "$_tpath_target"

    printf 'target : %s\n' "$_tpath_target"
    printf 'pane_id: %s\n' "$_tpath_id"
    printf 'cwd    : %s\n' "$_tpath_cwd"
    printf 'Copied pane path: %s\n' "$_tpath_target" >&2

    unset _tpath_target _tpath_id _tpath_cwd
}
