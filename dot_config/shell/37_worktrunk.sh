# 37_worktrunk.sh - Worktrunk (`wt`) shell integration (shared bash + zsh).
# https://worktrunk.dev — github.com/max-sixty/worktrunk
#
# Backend half of the split: shell-init wrapper (so `wt switch` can change
# the parent shell's $PWD) + the `wtcd` fzf picker. Zsh-only half lives in
# dot_config/zsh/tools/37_worktrunk.zsh (clap-based completion generation
# into ~/.zfunc/_wt).
#
# Companion config: ~/.config/worktrunk/config.toml (managed by chezmoi at
# dot_config/worktrunk/config.toml). Aliases like `wt sw` / `wt cc` live
# THERE, not here — keep this file focused on shell-level integration only.

# Skip silently if not installed (Linux ansible install can fail offline)
command -v wt &>/dev/null || return 0

# ── Shell integration: cd-wrapping `wt` function ───────────────────────────
#
# `wt switch` needs to change the parent shell's $PWD, which a normal binary
# can't do. Worktrunk solves this by writing a directive file that a wrapper
# shell function reads and `cd`s to. We eval that wrapper at shell startup
# rather than running `wt config shell install` (which edits ~/.zshrc with a
# block chezmoi would fight over).
#
# Same pattern as starship / zoxide / direnv elsewhere. The `2>/dev/null`
# swallows the error if wt doesn't support the requested shell (e.g. bash
# wrapper not yet implemented in upstream) — the binary itself still works,
# users just lose the cd-on-switch wrapper.
if [ -n "$ZSH_VERSION" ]; then
    eval "$(wt config shell init zsh 2>/dev/null)"
elif [ -n "$BASH_VERSION" ]; then
    eval "$(wt config shell init bash 2>/dev/null)"
fi

# ── Tiny shell-side conveniences (NOT duplicating wt's own aliases) ────────
#
# `wt`'s own aliases (sw / ls / rm / cc / oc) are defined in
# ~/.config/worktrunk/config.toml so they work from any shell + the
# interactive picker. Anything below is shell niceness that wt's alias
# system can't express.

# `wtcd` — jump to a worktree path WITHOUT switching tmux/sesh session.
# Useful when you want to peek at sibling worktree files (open in nvim split,
# scp, etc.) without disturbing the current pane's session context.
function wtcd() {
    local target
    target=$(wt list --format=json 2>/dev/null \
        | jq -r '.worktrees[].path' \
        | fzf-tmux -p 60%,40% --prompt='wt cd ❯ ' --header='Pick a worktree to cd into') \
        || return
    [ -n "$target" ] && cd -- "$target"
}
