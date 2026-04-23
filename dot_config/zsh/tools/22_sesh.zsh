# 22_sesh.zsh - sesh tmux session manager
# https://github.com/joshmedeski/sesh

# Check if sesh is installed
command -v sesh &>/dev/null || return 0

# Auto-generate shell completion into ~/.zfunc/ (regenerates on version change)
if [[ -d ~/.zfunc ]]; then
    local _sesh_ver="$(sesh --version 2>/dev/null)"
    if [[ ! -f ~/.zfunc/_sesh ]] || ! grep -q "${_sesh_ver}" ~/.zfunc/_sesh 2>/dev/null; then
        sesh completion zsh > ~/.zfunc/_sesh 2>/dev/null
    fi
fi

# Sesh session switcher with fzf (full-featured picker)
# Supports icons, preview, filtering by source, and session killing
function sesh-sessions() {
    {
        exec </dev/tty
        exec <&1
        local session
        session=$(sesh list --icons | fzf-tmux -p 80%,70% \
            --no-sort --ansi --border-label ' sesh ' --prompt '⚡  ' \
            --header '  ^a all ^t tmux ^g configs ^x zoxide ^d tmux kill ^f find' \
            --bind 'tab:down,btab:up' \
            --bind 'ctrl-a:change-prompt(⚡  )+reload(sesh list --icons)' \
            --bind 'ctrl-t:change-prompt(🪟  )+reload(sesh list -t --icons)' \
            --bind 'ctrl-g:change-prompt(⚙️  )+reload(sesh list -c --icons)' \
            --bind 'ctrl-x:change-prompt(📁  )+reload(sesh list -z --icons)' \
            --bind 'ctrl-f:change-prompt(🔎  )+reload(fd -H -d 2 -t d -E .Trash . ~)' \
            --bind 'ctrl-d:execute(tmux kill-session -t {2..})+change-prompt(⚡  )+reload(sesh list --icons)' \
            --preview-window 'right:55%' \
            --preview 'sesh preview {}' \
        )
        zle reset-prompt > /dev/null 2>&1 || true
        [[ -z "$session" ]] && return
        sesh connect "$session"
    }
}

# ── Internal helpers ────────────────────────────────────────────────────────
#
# All helpers below take care to avoid the lowercase `path` / `cdpath` /
# `manpath` / `fpath` zsh-tied-array trap (see
# pitfalls/zsh-tied-array-path-shadowing.md).

# Resolve the git repo root, or return non-zero if not in a repo.
function _sesh_git_root() {
    git rev-parse --show-toplevel 2>/dev/null
}

# Sanitize a string for use as a tmux session name.
# tmux forbids `.` and `:` in session names; we also strip whitespace.
function _sesh_sanitize() {
    print -r -- "${1//[.:[:space:]]/-}"
}

# Switch to or attach to a tmux session named $1 (creating it at $2 if needed).
# Inside tmux: `switch-client`. Outside tmux: `attach-session`.
function _sesh_attach_or_switch() {
    local session="$1"
    if [[ -n "$TMUX" ]]; then
        tmux switch-client -t "$session"
    else
        tmux attach-session -t "$session"
    fi
}

# Create (or no-op if exists) a detached tmux session at the given path.
# Returns 0 if the session already existed, 1 if newly created. (Caller uses
# this to decide whether to apply layout setup or just attach.)
function _sesh_ensure_session() {
    local session="$1" target="$2"
    if tmux has-session -t "=$session" 2>/dev/null; then
        return 0   # already exists
    fi
    tmux new-session -d -s "$session" -c "$target"
    return 1       # newly created
}

# Wrap a known specstory provider in `specstory run X` so the agent picks up
# auto-save markdown logging. Bare CLI names that aren't specstory providers
# (currently: opencode — see backlog/specstory-opencode-support.md) pass
# through unchanged.
#
# Update the case list when specstory adds providers (track upstream:
# specstoryai/getspecstory#146 for opencode, similar issues for others).
function _sesh_wrap_agent() {
    local agent="$1"
    case "$agent" in
        ""|"specstory")
            # No agent specified → bare `specstory run` (default = claude).
            print -r -- "specstory run"
            ;;
        claude|codex|cursor|droid|gemini)
            print -r -- "specstory run $agent"
            ;;
        *)
            # Pass-through for non-specstory providers (opencode today, more
            # later as specstory adds support).
            print -r -- "$agent"
            ;;
    esac
}

# Build a wrapper command that controls what happens when the inner command
# exits (Ctrl+C, agent quit, crash). `--on-exit shell|kill|restart`:
#   shell   — print a hint, then drop into $SHELL so user can restart agent,
#             switch to lazygit, kill the pane manually, etc. (default)
#   kill    — let the pane close on exit (tmux default `remain-on-exit off`)
#   restart — wrap in `while true; do CMD; sleep 1; done` so the agent
#             auto-respawns. Use Ctrl+C twice quickly to break the loop and
#             land in shell.
#
# Args: $1=inner_cmd, $2=mode, $3=label_for_hint
# Stdout: the wrapped shell command (single string suitable for `tmux
# new-window … "<cmd>"`). Quoting is structured so user $SHELL is the one
# evaluating the inner command — we don't double-eval.
function _sesh_on_exit_wrap() {
    local inner="$1" mode="$2" label="${3:-agent}"
    case "$mode" in
        kill)
            print -r -- "$inner"
            ;;
        restart)
            # `|| true` so a crash exit doesn't abort the loop on `set -e` shells
            print -r -- "while true; do $inner || true; echo '[$label exited — respawning in 1s; Ctrl+C twice to break]'; sleep 1; done; exec \$SHELL -l"
            ;;
        shell|*)
            # Default. Hint message uses tmux color codes — works in all
            # terminals tmux supports.
            print -r -- "$inner; printf '\\n\\033[33m[$label exited — back in shell. Re-run with: \\033[1m%s\\033[0;33m]\\033[0m\\n' \"$inner\"; exec \$SHELL -l"
            ;;
    esac
}

# Connect to a sesh session for the current directory (creates it if missing).
# Lightweight: drops you into a plain shell at $PWD with NO startup command.
# For an editor-first session use `scode` (repo-aware, full layout) or just
# launch nvim manually inside the new session.
#
# Smart argument handling:
#   shere                              # plain shell at $PWD, no command
#   shere specstory run codex          # bare args → treated as command
#   shere -c "specstory run codex"     # explicit --command flag
#   shere -p ~/my-proj                 # explicit path, plain shell
#   shere -p ~/my-proj npm run dev     # explicit path + command
function sesh-here() {
    local cmd="" target=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--command) cmd="$2"; shift 2 ;;
            -p|--path)    target="$2"; shift 2 ;;
            -*)           echo "sesh-here: unknown flag $1" >&2; return 1 ;;
            *)            break ;;  # remaining args are the command
        esac
    done
    [[ $# -gt 0 && -z "$cmd" ]] && cmd="$*"
    target="${target:-$PWD}"
    if [[ -n "$cmd" ]]; then
        sesh connect --command "$cmd" "$target"
    else
        # Bypass sesh's default_session.startup_command (nvim) for a plain
        # shell. We create the session via tmux directly, then attach. This
        # also means the wildcard startup_command (project layout) is
        # bypassed — `shere` is intentionally lightweight; use `scode`,
        # `svibe`, or `sesh connect <path>` for layouts.
        local session
        session=$(_sesh_sanitize "$(basename "$target")")
        _sesh_ensure_session "$session" "$target"
        _sesh_attach_or_switch "$session"
    fi
}

# Connect to the current git root when available, otherwise use $PWD.
# Same smart argument handling as sesh-here.
#   sroot                              # default startup_command
#   sroot specstory run codex          # bare args → command
#   sroot -c "specstory run codex"     # explicit --command flag
function sesh-root() {
    local cmd="" root
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--command) cmd="$2"; shift 2 ;;
            -*)           shift ;;
            *)            break ;;
        esac
    done
    [[ $# -gt 0 && -z "$cmd" ]] && cmd="$*"
    root=$(git rev-parse --show-toplevel 2>/dev/null) || root=$PWD
    if [[ -n "$cmd" ]]; then
        sesh connect --command "$cmd" "$root"
    else
        sesh connect "$root"
    fi
}

alias shere='sesh-here'
alias sroot='sesh-root'
alias scode='sesh-code'
alias svibe='sesh-vibe'

# ── scode: repo-aware coding-agent layout ───────────────────────────────────
#
# Open the coding-agent layout (nvim 75% | specstory-wrapped agent 25%, btop
# window) in a session NAMED FOR THE CURRENT REPO, so different repos don't
# collide on the single `coding-agent` session name.
#
# Session naming:
#   In repo /Volumes/Data/Program/Personal/foo  → session `coding-agent/foo`
#   Same repo re-invocation                     → attach (no duplicate)
#   Different repo                              → new session `coding-agent/<other>`
#
# Outside a git repo the function refuses with a hint to use `shere` or `svibe`
# (the heavy layout doesn't make sense for ad-hoc directories).
#
# Agent wrapping: known specstory providers (claude/codex/cursor/droid/gemini)
# are auto-wrapped in `specstory run X` for markdown auto-save. Others
# (opencode today) pass through raw — see _sesh_wrap_agent + backlog entry
# `specstory-opencode-support` for the upstream tracking.
#
# Exit behavior: `--on-exit shell` (default) drops to a shell with a hint when
# the agent exits, so Ctrl+C doesn't kill the pane. Use `--on-exit kill` for
# the old behavior, or `--on-exit restart` for an auto-respawn loop.
#
# Usage:
#   scode                              # current repo, default agent (specstory → claude)
#   scode codex                        # specstory run codex
#   scode opencode                     # opencode raw (not yet a specstory provider)
#   scode --on-exit kill claude        # Ctrl+C kills the right pane
#   scode --on-exit restart codex      # codex auto-respawns on crash
#   scode -p ~/some/other/repo         # explicit repo path
#   scode --no-attach                  # create session in background, don't switch
function sesh-code() {
    local target="" agent="" no_attach=0 on_exit="shell"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--path)      target="$2"; shift 2 ;;
            -a|--agent)     agent="$2"; shift 2 ;;
            --on-exit)      on_exit="$2"; shift 2 ;;
            --no-attach)    no_attach=1; shift ;;
            -h|--help)
                cat <<'EOF'
scode — open repo-scoped coding-agent layout

Usage: scode [--path DIR] [--agent CLI] [--on-exit MODE] [--no-attach] [AGENT]

Layout: window `editor` (nvim 75% | agent 25%) + window `monitor` (btop).
Session name: `coding-agent/<repo-basename>` (one session per repo).
Requires:     git repo (errors otherwise — use `shere` or `svibe`).

Agent wrapping (auto):
  claude / codex / cursor / droid / gemini  → `specstory run <agent>`
  opencode (and other unknown CLIs)         → raw passthrough

--on-exit MODE controls what happens when the agent exits/Ctrl+C:
  shell    (default) — drop to shell with a hint, agent re-runnable
  kill                — let the pane close (tmux default)
  restart             — auto-respawn the agent in a loop

Examples:
  scode                            # current repo, default agent
  scode codex                      # right pane: specstory run codex
  scode opencode                   # right pane: opencode (raw)
  scode --on-exit kill claude      # right pane closes when claude exits
  scode -p ~/work/foo              # explicit repo path
EOF
                return 0 ;;
            -*)             echo "scode: unknown flag $1" >&2; return 1 ;;
            *)              [[ -z "$agent" ]] && agent="$1" || true; shift ;;
        esac
    done

    case "$on_exit" in
        shell|kill|restart) ;;
        *) echo "scode: --on-exit must be one of: shell, kill, restart (got: $on_exit)" >&2; return 1 ;;
    esac

    # Resolve repo root
    local repo_root
    if [[ -n "$target" ]]; then
        repo_root=$(cd "$target" 2>/dev/null && _sesh_git_root)
    else
        repo_root=$(_sesh_git_root)
    fi
    if [[ -z "$repo_root" ]]; then
        echo "scode: not inside a git repo." >&2
        echo "       Use \`shere\` for a plain shell, or \`svibe\` for a vibe layout in any dir." >&2
        return 1
    fi

    local repo_name session
    repo_name=$(basename "$repo_root")
    session=$(_sesh_sanitize "coding-agent/${repo_name}")

    # If session already exists, just attach (idempotent — solves the
    # cross-repo collision problem the old single `coding-agent` session had).
    if tmux has-session -t "=$session" 2>/dev/null; then
        (( no_attach )) || _sesh_attach_or_switch "$session"
        return 0
    fi

    # Create session + build layout directly with tmux commands (see svibe
    # comment block for why not tmuxp).
    #
    # Window 1 "editor": nvim (left, will be 75%) | wrapped agent (right, 25%)
    # Window 2 "monitor": btop (or htop / top fallback)
    local agent_inner agent_cmd
    agent_inner=$(_sesh_wrap_agent "$agent")
    agent_cmd=$(_sesh_on_exit_wrap "$agent_inner" "$on_exit" "${agent:-agent}")

    tmux new-session -d -s "$session" -c "$repo_root" -n editor nvim
    tmux split-window -h -t "${session}:editor" -c "$repo_root" "$agent_cmd"
    # main-vertical layout, then size the LEFT pane to 75% of window width
    tmux select-layout -t "${session}:editor" main-vertical >/dev/null
    tmux resize-pane -t "${session}:editor.1" -x 75% 2>/dev/null

    # Monitor window
    local monitor_cmd
    if   command -v btop >/dev/null 2>&1; then monitor_cmd=btop
    elif command -v htop >/dev/null 2>&1; then monitor_cmd=htop
    else                                       monitor_cmd=top
    fi
    tmux new-window -t "$session" -n monitor -c "$repo_root" "$monitor_cmd"

    # Focus editor window, left (nvim) pane
    tmux select-window -t "${session}:editor"
    tmux select-pane -t "${session}:editor.1"

    (( no_attach )) || _sesh_attach_or_switch "$session"
}

# ── svibe: parametric multi-agent vibe layout ───────────────────────────────
#
# A "vibe coding" session: window 1 has N agent panes (default 4), window 2
# is lazygit, window 3 is nvim. Built directly with tmux split/new-window
# commands so it stays parametric (tmuxp YAML can't express dynamic pane counts).
#
# Session naming: `vibe/<dir-basename>` — collision-safe across directories.
# Refuses outside a git repo (use `shere` for plain shells in arbitrary dirs).
#
# Each agent pane is wrapped in `specstory run X` (for known providers) and
# additionally wrapped in an exit handler controlled by `--on-exit MODE` —
# same semantics as `scode`. Default `shell` keeps the pane open with a hint
# after the agent exits, so Ctrl+C is recoverable.
#
# Usage:
#   svibe                              # 4 panes × claude (specstory-wrapped) + lazygit + nvim
#   svibe 2                            # 2 panes × claude
#   svibe 4 codex                      # 4 panes × specstory run codex
#   svibe 3 opencode                   # 3 panes × opencode (raw, not yet a specstory provider)
#   svibe --on-exit kill 4 claude      # Ctrl+C kills the pane (old behavior)
#   svibe --on-exit restart 4 codex    # codex auto-respawns on crash
#   svibe -p ~/repo 4 claude           # explicit path
#   svibe --no-attach 4 claude         # create in background
function sesh-vibe() {
    local target="" no_attach=0 on_exit="shell"
    local n_agents=4
    local agent_cli="claude"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--path)      target="$2"; shift 2 ;;
            --on-exit)      on_exit="$2"; shift 2 ;;
            --no-attach)    no_attach=1; shift ;;
            -h|--help)
                cat <<'EOF'
svibe — parametric multi-agent vibe layout

Usage: svibe [--path DIR] [--on-exit MODE] [--no-attach] [N_AGENTS] [AGENT_CLI]

Default: svibe 4 claude
  window 1 "agents" — N_AGENTS panes (tiled), each running AGENT_CLI
  window 2 "git"    — lazygit
  window 3 "edit"   — nvim

Session name: `vibe/<repo-basename>` (collision-safe per directory).
Requires:     git repo (use `shere` for plain shells elsewhere).

Agent wrapping (auto):
  claude / codex / cursor / droid / gemini  → `specstory run <agent>`
  opencode (and other unknown CLIs)         → raw passthrough

--on-exit MODE controls per-pane behavior on agent exit/Ctrl+C:
  shell    (default) — drop to shell with a hint, agent re-runnable
  kill                — let the pane close (tmux default)
  restart             — auto-respawn the agent in a loop

Examples:
  svibe                            # 4× claude (default exit=shell)
  svibe 2                          # 2× claude
  svibe 4 codex                    # 4× codex
  svibe 6 opencode                 # 6× opencode (heavy — large monitor recommended)
  svibe --on-exit kill 4 claude    # Ctrl+C closes the pane
EOF
                return 0 ;;
            -*)             echo "svibe: unknown flag $1" >&2; return 1 ;;
            *)              break ;;
        esac
    done
    # Positional: [n_agents] [agent_cli]
    if [[ $# -gt 0 ]]; then
        if [[ "$1" =~ ^[0-9]+$ ]]; then
            n_agents="$1"; shift
        fi
    fi
    [[ $# -gt 0 ]] && agent_cli="$1"

    case "$on_exit" in
        shell|kill|restart) ;;
        *) echo "svibe: --on-exit must be one of: shell, kill, restart (got: $on_exit)" >&2; return 1 ;;
    esac

    if (( n_agents < 1 || n_agents > 12 )); then
        echo "svibe: n_agents=$n_agents out of range [1, 12]" >&2
        return 1
    fi

    # Resolve repo root
    local repo_root
    if [[ -n "$target" ]]; then
        repo_root=$(cd "$target" 2>/dev/null && _sesh_git_root)
    else
        repo_root=$(_sesh_git_root)
    fi
    if [[ -z "$repo_root" ]]; then
        echo "svibe: not inside a git repo." >&2
        echo "       Use \`shere\` for a plain shell in arbitrary directories." >&2
        return 1
    fi

    # Validate agent CLI exists (check the bare CLI, not the wrapped form —
    # `specstory run X` validity is `specstory`'s problem, not ours).
    if ! command -v "$agent_cli" >/dev/null 2>&1; then
        echo "svibe: agent CLI '$agent_cli' not found in PATH." >&2
        echo "       Available: $(for c in claude codex opencode cursor droid gemini; do command -v $c >/dev/null 2>&1 && echo -n "$c "; done)" >&2
        return 1
    fi

    local repo_name session
    repo_name=$(basename "$repo_root")
    session=$(_sesh_sanitize "vibe/${repo_name}")

    # Idempotent: existing session = just attach
    if tmux has-session -t "=$session" 2>/dev/null; then
        (( no_attach )) || _sesh_attach_or_switch "$session"
        return 0
    fi

    # Build the wrapped command once; reused for every pane.
    local agent_inner agent_cmd
    agent_inner=$(_sesh_wrap_agent "$agent_cli")
    agent_cmd=$(_sesh_on_exit_wrap "$agent_inner" "$on_exit" "$agent_cli")

    # ── Build the session ───────────────────────────────────────────────
    # Window 1: agents (start with first pane running the agent)
    tmux new-session -d -s "$session" -c "$repo_root" -n agents "$agent_cmd"

    # Add remaining N-1 panes; -t targets window 1
    local i
    for (( i = 2; i <= n_agents; i++ )); do
        tmux split-window -t "${session}:agents" -c "$repo_root" "$agent_cmd"
        # Re-tile after each split so layout stays balanced (avoids 1-pane-too-small fail)
        tmux select-layout -t "${session}:agents" tiled >/dev/null
    done

    # Window 2: git (lazygit if present)
    if command -v lazygit >/dev/null 2>&1; then
        tmux new-window -t "$session" -n git -c "$repo_root" lazygit
    else
        tmux new-window -t "$session" -n git -c "$repo_root" "git status; exec \$SHELL"
    fi

    # Window 3: edit (nvim)
    tmux new-window -t "$session" -n edit -c "$repo_root" nvim

    # Focus agents window, first pane
    tmux select-window -t "${session}:agents"
    tmux select-pane -t "${session}:agents.1"

    (( no_attach )) || _sesh_attach_or_switch "$session"
}

# Register as zsh widget
zle -N sesh-sessions

# Key bindings (Alt+S for session switcher, avoids conflict with Ctrl+A tmux prefix)
bindkey -M emacs '\es' sesh-sessions
bindkey -M viins '\es' sesh-sessions
bindkey -M vicmd '\es' sesh-sessions
