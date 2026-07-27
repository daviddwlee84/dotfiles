# 24_herdr.sh - herdr workspace layout helpers (shared backend; bash 4+ / zsh).
# https://github.com/ogulcancelik/herdr
#
# herdr-native analogs of the sesh/tmux helpers in 22_sesh.sh. herdr's model is
# Workspace -> Tab -> Pane (tmux is Session -> Window -> Pane), and its CLI
# (`herdr workspace|tab|pane|agent …`) is the scripting surface that replaces
# `tmux new-session/split-window`.
#
# Backend that powers the user-facing commands and their aliases:
#   herdr-vibe / hvibe  — parametric multi-agent pack in a new workspace
#                         (N agent panes + lazygit tab + nvim tab)
#   herdr-code / hcode  — repo-scoped single-agent layout
#                         (nvim | agent split + btop monitor tab)
#
# REUSE: the *pure* (multiplexer-agnostic) helpers from 22_sesh.sh are reused
# verbatim — `_sesh_git_root`, `_sesh_sanitize`, `_sesh_wrap_agent` (specstory
# wrapping), `_sesh_on_exit_wrap` (shell|kill|restart post-exit behavior).
# 22_sesh.sh sorts before this file, so they are defined by the time hvibe/hcode
# run. Only the tmux calls are swapped for `herdr …` CLI calls.
#
# Bash baseline: 4+ (same array-slicing idiom as svibe; no `local -A`).

# Skip entirely if herdr isn't installed (it's a trial tool, not on every host).
command -v herdr >/dev/null 2>&1 || return 0

# ── Internal helpers ────────────────────────────────────────────────────────

# Echo the workspace_id of an existing workspace whose label == $1 (else empty).
# Used for idempotency: re-running hvibe/hcode in a repo focuses the existing
# workspace instead of stacking duplicates (mirrors svibe's has-session check).
function _herdr_ws_by_label() {
    herdr workspace list 2>/dev/null \
        | jq -r --arg l "$1" '.result.workspaces[]? | select(.label==$l) | .workspace_id' 2>/dev/null \
        | head -1
}

# Compose the shell command for one agent pane: specstory-wrap then on-exit-wrap.
# $1=agent  $2=specstory_mode(auto|never)  $3=on_exit(shell|kill|restart)
function _herdr_agent_cmd() {
    local inner
    inner=$(_sesh_wrap_agent "$1" "$2")
    _sesh_on_exit_wrap "$inner" "$3" "${1:-agent}"
}

# Create a labeled tab in workspace $1 (cwd $2, label $3) and run command $4 in
# its root pane. `tab create` returns the new pane id at .result.root_pane.
# $1=workspace_id  $2=cwd  $3=label  $4=command
function _herdr_tool_tab() {
    local pane
    pane=$(herdr tab create --workspace "$1" --cwd "$2" --label "$3" --no-focus 2>/dev/null \
        | jq -r '.result.root_pane.pane_id // empty')
    [ -n "$pane" ] && herdr pane run "$pane" "$4" >/dev/null 2>&1
}

# Absolutize + validate a `-p/--path DIR` argument in THIS shell. Echoes the
# canonical (symlink-resolved) path; on a non-directory, echoes nothing and
# returns 1 after a message on stderr.
#
# LOAD-BEARING for every `--cwd` below: herdr resolves a *relative* `--cwd`
# against the SERVER's launch directory (wherever `herdr server` was started),
# not the caller's cwd — and on a miss it silently falls back to $HOME, so
# `hhere -p ../sibling` opens a workspace at `~` with no error anywhere. tmux
# resolves `new-session -c` client-side, which is why the sesh originals
# (shere/svibe/scode) never needed this.
# See pitfalls/hhere-p-relative-path-opens-workspace-at-home.md.
#
# `CDPATH=''` + `--` + `>/dev/null` keep a CDPATH hit from silently retargeting
# the cd or echoing the resolved dir into the capture.
# $1=dir  $2=caller name (for the error message)
function _herdr_abs_dir() {
    local abs
    abs=$(CDPATH=''; cd -- "$1" >/dev/null 2>&1 && pwd -P)
    if [ -z "$abs" ]; then
        echo "${2:-herdr}: --path is not a directory: $1" >&2
        return 1
    fi
    printf '%s\n' "$abs"
}

# Resolve the target herdr session for hvibe/hcode from an optional --session
# value. Echoes "<name><TAB><socket_override_or_empty>". The socket field is
# non-empty ONLY when the caller must override HERDR_SOCKET_PATH (explicit
# --session); empty means "use the ambient/default socket untouched". Returns 1
# (with a message) when an explicit --session names a session that isn't running.
#
# A herdr server hosts multiple named sessions (default + `herdr --session NAME`),
# each with its own socket. The CLI has no --session flag on subcommands; the
# only lever is the HERDR_SOCKET_PATH env var (verified). `session list --json`
# is the authoritative name -> socket_path resolver.
function _herdr_session_target() {
    local want="$1" js line running socket nm
    js=$(herdr session list --json 2>/dev/null)
    if [ -n "$want" ]; then
        line=$(printf '%s' "$js" \
            | jq -r --arg n "$want" '.sessions[] | select(.name==$n) | "\(.running)\t\(.socket_path)"' 2>/dev/null \
            | head -1)
        if [ -z "$line" ]; then
            echo "session '$want' not found. Start it with: herdr --session $want" >&2
            return 1
        fi
        running=${line%%$'\t'*}
        socket=${line#*$'\t'}
        if [ "$running" != "true" ]; then
            echo "session '$want' is not running. Start it with: herdr --session $want" >&2
            return 1
        fi
        printf '%s\t%s\n' "$want" "$socket"
        return 0
    fi
    # No explicit --session: inside herdr use the ambient session (no override);
    # outside, fall back to the default session. Only the NAME matters here (for
    # the attach path) — socket stays empty so the ambient socket is left as-is.
    if [ -n "$HERDR_SOCKET_PATH" ]; then
        nm=$(printf '%s' "$js" \
            | jq -r --arg s "$HERDR_SOCKET_PATH" '.sessions[] | select(.socket_path==$s) | .name' 2>/dev/null \
            | head -1)
        printf '%s\t\n' "${nm:-default}"
    else
        printf 'default\t\n'
    fi
}

# When hvibe/hcode run from OUTSIDE herdr, bring up a client attached to the
# session so the just-created/focused workspace is actually visible — the
# `herdr workspace focus` calls only move an ALREADY-attached client. Inside
# herdr (HERDR_ENV set) those focus calls already switched the live client, so
# there is nothing to do. Runs the client as a child (no exec), mirroring
# svibe's `tmux attach-session`. $1=session_name (default: "default").
function _herdr_attach_if_outside() {
    [ -n "$HERDR_ENV" ] && return 0
    local session="${1:-default}"
    if [ "$session" = "default" ]; then
        herdr
    else
        herdr session attach "$session"
    fi
}

# ── hvibe: parametric multi-agent pack ──────────────────────────────────────
#
# A herdr "vibe" workspace: tab "agents" with N agent panes (side-by-side
# splits by default), tab "git" (lazygit), tab "edit" (nvim). Built directly
# with herdr CLI calls so pane count stays parametric.
#
# Workspace label: `vibe/<repo-basename>` (idempotent — re-running focuses it).
# Refuses outside a git repo (pass -p DIR, or cd into a repo).
#
# Each agent pane is specstory-wrapped (known providers) and on-exit-wrapped,
# exactly like `svibe` — the wrapping helpers are shared, only the layout calls
# differ. herdr auto-detects agent state per pane, so all N agents surface
# individually in the sidebar even when they share the "agents" tab.
#
# Two modes for choosing agents (same as svibe):
#   Homogeneous (positional):  hvibe 3 codex        → 3 panes all codex
#   Heterogeneous (--agents):  hvibe --agents claude,codex,opencode
#
# --tab-per-agent puts each agent in its OWN tab (own rolled-up state dot in the
# sidebar) instead of side-by-side splits — better for many agents, since herdr
# has no even-out-splits command.
#
# Usage:
#   hvibe                                       # auto N × claude (specstory)
#   hvibe 2                                     # 2× claude
#   hvibe 3 codex                               # 3× specstory run codex
#   hvibe 2 opencode                            # 2× opencode (raw)
#   hvibe --agents claude,codex,opencode        # 3 panes, mixed
#   hvibe --tab-per-agent --agents claude,codex # one tab each
#   hvibe --no-specstory 2 claude               # raw claude, no md auto-save
#   hvibe --on-exit restart 2 codex             # auto-respawn loop
#   hvibe -p ~/repo 2 claude                    # explicit path
#   hvibe --no-attach 2 claude                  # create in background
function herdr-vibe() {
    command -v jq >/dev/null 2>&1 || { echo "hvibe: jq is required." >&2; return 1; }

    local target="" no_attach=0 on_exit="shell" specstory_mode="auto" session_arg=""
    local n_agents=0 n_agents_set=0 agent_cli="claude" agents_csv="" tab_per_agent=0
    local min_width="${HVIBE_MIN_WIDTH:-80}"
    # Stagger between pane launches so agents that share a global resource at
    # cold start (opencode's single SQLite DB + WAL pragma) don't race. Set 0
    # to launch all at once. Same rationale as svibe's SVIBE_LAUNCH_STAGGER.
    local launch_stagger="${HVIBE_LAUNCH_STAGGER:-0.25}"

    while [ $# -gt 0 ]; do
        case "$1" in
            -p|--path)       target="$2"; shift 2 ;;
            --on-exit)       on_exit="$2"; shift 2 ;;
            --agents)        agents_csv="$2"; shift 2 ;;
            --session)       session_arg="$2"; shift 2 ;;
            --min-width)     min_width="$2"; shift 2 ;;
            --tab-per-agent) tab_per_agent=1; shift ;;
            --no-specstory)  specstory_mode="never"; shift ;;
            --specstory)     specstory_mode="auto"; shift ;;
            --no-attach)     no_attach=1; shift ;;
            -h|--help)
                cat <<'EOF'
hvibe — herdr multi-agent pack (herdr analog of svibe)

Usage:
  hvibe [--path DIR] [--on-exit MODE] [--no-specstory] [--no-attach]
        [--min-width COLS] [--tab-per-agent] [--session NAME] [N_AGENTS] [AGENT_CLI]
  hvibe [--path DIR] [--on-exit MODE] [--no-specstory] [--no-attach]
        [--min-width COLS] [--tab-per-agent] [--session NAME] --agents A1,A2,A3[,...]

Builds a new herdr workspace `vibe/<repo>`:
  tab "agents" — N agent panes (side-by-side splits; each auto-detected in
                 the sidebar). --tab-per-agent → one tab per agent instead.
  tab "git"    — lazygit (falls back to `git status`)
  tab "edit"   — nvim
Idempotent: re-running in the same repo focuses the existing workspace.
Requires:  a git repo (pass -p DIR, or cd into one).

Attach behavior: run from OUTSIDE herdr → attaches a client to the session so
the new workspace is visible; run from INSIDE herdr → just focuses it.
--no-attach builds in the background either way.
--session NAME targets a running herdr session (default: the current session
when inside herdr, else the default session). Start a session first with
`herdr --session NAME`.

Two modes for choosing agents:
  Homogeneous:    hvibe 3 codex → 3 panes all codex
  Heterogeneous:  hvibe --agents claude,codex,opencode  (list length = panes)

Agent wrapping (auto, opt out with --no-specstory):
  claude / codex / cursor / droid / gemini  → `specstory run <agent>`
  opencode (and other unknown CLIs)         → raw passthrough

--on-exit MODE (per pane, on Ctrl+C / clean exit):
  shell (default) — drop to a shell with a re-run hint
  kill            — let the pane close
  restart         — auto-respawn in a loop

--min-width COLS (default $HVIBE_MIN_WIDTH, else 80) auto-picks N when omitted:
  N = clamp(term_width / min-width, 1, 6)
$HVIBE_LAUNCH_STAGGER (seconds, default 0.25) delays each pane launch.

Examples:
  hvibe                                       # auto N × claude
  hvibe 3 codex                               # 3× codex
  hvibe --agents claude,codex,opencode        # 3 panes, mixed
  hvibe --tab-per-agent --agents claude,codex # one tab each
  hvibe --no-specstory 2 claude               # raw claude
EOF
                return 0 ;;
            -*)              echo "hvibe: unknown flag $1" >&2; return 1 ;;
            *)               break ;;
        esac
    done

    if ! [[ "$min_width" =~ ^[0-9]+$ ]] || (( min_width < 1 )); then
        echo "hvibe: --min-width must be a positive integer (got: $min_width)" >&2
        return 1
    fi
    if ! [[ "$launch_stagger" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "hvibe: HVIBE_LAUNCH_STAGGER must be a non-negative number (got: $launch_stagger)" >&2
        return 1
    fi

    local term_width="${COLUMNS:-$(tput cols 2>/dev/null || echo 200)}"

    # Build the agents array (same two paths as svibe; mixing is rejected).
    local -a agents
    agents=()
    if [ -n "$agents_csv" ]; then
        if [ $# -gt 0 ]; then
            echo "hvibe: cannot combine --agents with positional N_AGENTS/AGENT_CLI." >&2
            return 1
        fi
        local tok
        while IFS= read -r tok; do
            tok="${tok## }"; tok="${tok%% }"
            [ -n "$tok" ] && agents+=( "$tok" )
        done < <(printf '%s\n' "$agents_csv" | tr ',' '\n')
        if [ "${#agents[@]}" -eq 0 ]; then
            echo "hvibe: --agents list is empty." >&2
            return 1
        fi
    else
        if [ $# -gt 0 ] && [[ "$1" =~ ^[0-9]+$ ]]; then
            n_agents="$1"; n_agents_set=1; shift
        fi
        [ $# -gt 0 ] && agent_cli="$1"
        # Auto-pick N from terminal width. Clamp [1,6] (lower than svibe's 12:
        # herdr right-splits nest, so many panes get cramped — use
        # --tab-per-agent for more).
        if [ "$n_agents_set" -eq 0 ]; then
            n_agents=$(( term_width / min_width ))
            (( n_agents < 1 )) && n_agents=1
            (( n_agents > 6 )) && n_agents=6
        fi
        local k
        for (( k = 0; k < n_agents; k++ )); do agents+=( "$agent_cli" ); done
    fi

    case "$on_exit" in
        shell|kill|restart) ;;
        *) echo "hvibe: --on-exit must be one of: shell, kill, restart (got: $on_exit)" >&2; return 1 ;;
    esac

    # Resolve git root (required, like svibe). `-p DIR` is absolutized first so
    # a bad path reports itself instead of masquerading as "not a git repo".
    local repo_root
    if [ -n "$target" ]; then
        target=$(_herdr_abs_dir "$target" hvibe) || return 1
        repo_root=$(cd -- "$target" >/dev/null 2>&1 && _sesh_git_root)
    else
        repo_root=$(_sesh_git_root)
    fi
    if [ -z "$repo_root" ]; then
        echo "hvibe: not inside a git repo. Pass -p DIR, or cd into a repo." >&2
        return 1
    fi

    # Fail-fast: every agent CLI must exist in PATH.
    local a missing=""
    for a in "${agents[@]}"; do
        command -v "$a" >/dev/null 2>&1 || missing="$missing $a"
    done
    if [ -n "$missing" ]; then
        echo "hvibe: agent CLI(s) not found in PATH:$missing" >&2
        echo "       Available: claude codex opencode cursor droid gemini (install as needed)." >&2
        return 1
    fi

    local repo label
    repo=$(basename "$repo_root")
    label=$(_sesh_sanitize "vibe/$repo")

    # Resolve the target herdr session (optional --session; else ambient/default).
    # A non-empty sess_sock means an explicit --session override — scope it with
    # `local -x` so child `herdr` calls see it but the user's shell is untouched.
    local sess_line sess_name sess_sock
    sess_line=$(_herdr_session_target "$session_arg") || return 1
    sess_name=${sess_line%%$'\t'*}
    sess_sock=${sess_line#*$'\t'}
    [ -n "$sess_sock" ] && local -x HERDR_SOCKET_PATH="$sess_sock"

    # Idempotent: focus an existing workspace instead of duplicating.
    local existing
    existing=$(_herdr_ws_by_label "$label")
    if [ -n "$existing" ]; then
        echo "hvibe: workspace '$label' already exists ($existing) — focusing." >&2
        if [ "$no_attach" -ne 1 ]; then
            herdr workspace focus "$existing" >/dev/null 2>&1
            _herdr_attach_if_outside "$sess_name"
        fi
        return 0
    fi

    # Create the workspace; capture the initial pane/tab (become the first agent).
    local ws_json ws p0 t0
    ws_json=$(herdr workspace create --cwd "$repo_root" --label "$label" --no-focus 2>/dev/null)
    ws=$(printf '%s' "$ws_json" | jq -r '.result.workspace.workspace_id // empty')
    p0=$(printf '%s' "$ws_json" | jq -r '.result.root_pane.pane_id // empty')
    t0=$(printf '%s' "$ws_json" | jq -r '.result.root_pane.tab_id // empty')
    if [ -z "$ws" ] || [ -z "$p0" ] || [ -z "$t0" ]; then
        echo "hvibe: failed to create workspace (is the herdr server running?)." >&2
        return 1
    fi

    local first_agent="${agents[@]:0:1}"
    if [ "$tab_per_agent" -eq 1 ]; then
        # One tab per agent. Initial tab hosts the first agent (labeled by it).
        herdr tab rename "$t0" "$first_agent" >/dev/null 2>&1
        herdr pane run "$p0" "$(_herdr_agent_cmd "$first_agent" "$specstory_mode" "$on_exit")" >/dev/null 2>&1
        for a in "${agents[@]:1}"; do
            [ "$launch_stagger" != "0" ] && sleep "$launch_stagger"
            _herdr_tool_tab "$ws" "$repo_root" "$a" "$(_herdr_agent_cmd "$a" "$specstory_mode" "$on_exit")"
        done
    else
        # Side-by-side splits in one "agents" tab. Thread `prev` so each new pane
        # splits off the previous one → predictable left-to-right columns.
        herdr tab rename "$t0" agents >/dev/null 2>&1
        herdr pane run "$p0" "$(_herdr_agent_cmd "$first_agent" "$specstory_mode" "$on_exit")" >/dev/null 2>&1
        # Even columns: herdr has no `select-layout even-horizontal`, so set each
        # split's ratio explicitly. --ratio is the fraction KEPT by the pane
        # being split (the left one); the new pane gets the rest. Splitting the
        # rightmost pane on step m (of N-1) with ratio 1/(N-m+1) leaves every
        # finalized column at 1/N width.
        local n_total="${#agents[@]}" prev="$p0" np m=1 ratio
        for a in "${agents[@]:1}"; do
            [ "$launch_stagger" != "0" ] && sleep "$launch_stagger"
            ratio=$(awk "BEGIN{printf \"%.4f\", 1/($n_total-$m+1)}")
            np=$(herdr pane split "$prev" --direction right --ratio "$ratio" --cwd "$repo_root" --no-focus 2>/dev/null \
                | jq -r '.result.pane.pane_id // empty')
            if [ -n "$np" ]; then
                herdr pane run "$np" "$(_herdr_agent_cmd "$a" "$specstory_mode" "$on_exit")" >/dev/null 2>&1
                prev="$np"
            fi
            m=$((m+1))
        done
    fi

    # git + edit tabs (same on-exit treatment as the agents).
    local git_inner git_label
    if command -v lazygit >/dev/null 2>&1; then git_inner="lazygit"; else git_inner="git status"; fi
    git_label="${git_inner%% *}"
    _herdr_tool_tab "$ws" "$repo_root" git  "$(_sesh_on_exit_wrap "$git_inner" "$on_exit" "$git_label")"
    _herdr_tool_tab "$ws" "$repo_root" edit "$(_sesh_on_exit_wrap "nvim" "$on_exit" "nvim")"

    # Focus the workspace + agents tab unless --no-attach.
    if [ "$no_attach" -ne 1 ]; then
        herdr workspace focus "$ws" >/dev/null 2>&1
        herdr tab focus "$t0" >/dev/null 2>&1
        _herdr_attach_if_outside "$sess_name"
    fi
}

# ── hcode: repo-scoped single-agent layout ──────────────────────────────────
#
# herdr analog of `scode`. Workspace `coding-agent/<repo>`:
#   tab "editor"  — nvim (left ~75%) | agent (right ~25%)
#   tab "monitor" — btop (or htop / top fallback)
# Idempotent per repo; refuses outside a git repo.
#
# Usage:
#   hcode                     # current repo, default agent (specstory → claude)
#   hcode codex               # right pane: specstory run codex
#   hcode opencode            # right pane: opencode (raw)
#   hcode --no-specstory claude
#   hcode --on-exit kill claude
#   hcode -p ~/work/foo
function herdr-code() {
    command -v jq >/dev/null 2>&1 || { echo "hcode: jq is required." >&2; return 1; }

    local target="" agent="" no_attach=0 on_exit="shell" specstory_mode="auto" session_arg=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -p|--path)      target="$2"; shift 2 ;;
            -a|--agent)     agent="$2"; shift 2 ;;
            --on-exit)      on_exit="$2"; shift 2 ;;
            --session)      session_arg="$2"; shift 2 ;;
            --no-specstory) specstory_mode="never"; shift ;;
            --specstory)    specstory_mode="auto"; shift ;;
            --no-attach)    no_attach=1; shift ;;
            --agents)
                echo "hcode: --agents is hvibe-only (hcode is single-agent)." >&2
                echo "       For multi-agent layouts: hvibe --agents '$2'" >&2
                return 1 ;;
            -h|--help)
                cat <<'EOF'
hcode — herdr single-agent coding layout (herdr analog of scode)

Usage: hcode [--path DIR] [--agent CLI] [--on-exit MODE] [--no-specstory]
             [--no-attach] [--session NAME] [AGENT]

Builds a new herdr workspace `coding-agent/<repo>`:
  tab "editor"  — nvim (left ~75%) | agent (right ~25%)
  tab "monitor" — btop (or htop / top)
Idempotent per repo; refuses outside a git repo.

Attach behavior: run from OUTSIDE herdr → attaches a client to the session;
run from INSIDE herdr → just focuses. --no-attach builds in the background.
--session NAME targets a running herdr session (default: current session when
inside herdr, else the default session; start one with `herdr --session NAME`).

Agent wrapping (auto, opt out with --no-specstory):
  claude / codex / cursor / droid / gemini  → `specstory run <agent>`
  opencode (and other unknown CLIs)         → raw passthrough

--on-exit MODE (per pane): shell (default) | kill | restart

Examples:
  hcode                     # default agent (specstory → claude)
  hcode codex               # right pane: specstory run codex
  hcode opencode            # right pane: opencode (raw)
  hcode --on-exit kill claude
EOF
                return 0 ;;
            -*)             echo "hcode: unknown flag $1" >&2; return 1 ;;
            *)              [ -z "$agent" ] && agent="$1"; shift ;;
        esac
    done

    case "$on_exit" in
        shell|kill|restart) ;;
        *) echo "hcode: --on-exit must be one of: shell, kill, restart (got: $on_exit)" >&2; return 1 ;;
    esac

    local repo_root
    if [ -n "$target" ]; then
        target=$(_herdr_abs_dir "$target" hcode) || return 1
        repo_root=$(cd -- "$target" >/dev/null 2>&1 && _sesh_git_root)
    else
        repo_root=$(_sesh_git_root)
    fi
    if [ -z "$repo_root" ]; then
        echo "hcode: not inside a git repo. Pass -p DIR, or use hvibe in any dir." >&2
        return 1
    fi

    if [ -n "$agent" ] && ! command -v "$agent" >/dev/null 2>&1; then
        echo "hcode: agent CLI '$agent' not found in PATH." >&2
        return 1
    fi

    local repo label
    repo=$(basename "$repo_root")
    label=$(_sesh_sanitize "coding-agent/$repo")

    # Resolve target herdr session (optional --session; else ambient/default).
    local sess_line sess_name sess_sock
    sess_line=$(_herdr_session_target "$session_arg") || return 1
    sess_name=${sess_line%%$'\t'*}
    sess_sock=${sess_line#*$'\t'}
    [ -n "$sess_sock" ] && local -x HERDR_SOCKET_PATH="$sess_sock"

    local existing
    existing=$(_herdr_ws_by_label "$label")
    if [ -n "$existing" ]; then
        echo "hcode: workspace '$label' already exists ($existing) — focusing." >&2
        if [ "$no_attach" -ne 1 ]; then
            herdr workspace focus "$existing" >/dev/null 2>&1
            _herdr_attach_if_outside "$sess_name"
        fi
        return 0
    fi

    local ws_json ws p0 t0
    ws_json=$(herdr workspace create --cwd "$repo_root" --label "$label" --no-focus 2>/dev/null)
    ws=$(printf '%s' "$ws_json" | jq -r '.result.workspace.workspace_id // empty')
    p0=$(printf '%s' "$ws_json" | jq -r '.result.root_pane.pane_id // empty')
    t0=$(printf '%s' "$ws_json" | jq -r '.result.root_pane.tab_id // empty')
    if [ -z "$ws" ] || [ -z "$p0" ] || [ -z "$t0" ]; then
        echo "hcode: failed to create workspace (is the herdr server running?)." >&2
        return 1
    fi

    # editor tab: nvim in the initial pane, agent split off to the right at ~25%.
    # --ratio is the fraction KEPT by the pane being split (nvim/left), so 0.75
    # leaves nvim at 75% and the new agent pane at 25%.
    herdr tab rename "$t0" editor >/dev/null 2>&1
    herdr pane run "$p0" "$(_sesh_on_exit_wrap "nvim" "$on_exit" "nvim")" >/dev/null 2>&1
    local ap
    ap=$(herdr pane split "$p0" --direction right --ratio 0.75 --cwd "$repo_root" --no-focus 2>/dev/null \
        | jq -r '.result.pane.pane_id // empty')
    [ -n "$ap" ] && herdr pane run "$ap" "$(_herdr_agent_cmd "$agent" "$specstory_mode" "$on_exit")" >/dev/null 2>&1

    # monitor tab.
    local mon
    if   command -v btop >/dev/null 2>&1; then mon=btop
    elif command -v htop >/dev/null 2>&1; then mon=htop
    else                                       mon=top
    fi
    _herdr_tool_tab "$ws" "$repo_root" monitor "$(_sesh_on_exit_wrap "$mon" "$on_exit" "$mon")"

    # Focus editor tab, nvim pane (left neighbor of the agent pane).
    if [ "$no_attach" -ne 1 ]; then
        herdr workspace focus "$ws" >/dev/null 2>&1
        herdr tab focus "$t0" >/dev/null 2>&1
        [ -n "$ap" ] && herdr pane focus --direction left --pane "$ap" >/dev/null 2>&1
        _herdr_attach_if_outside "$sess_name"
    fi
}

# ── hhere: plain "open a workspace here + attach" ────────────────────────────
#
# herdr analog of `shere` (sesh-here). The lightweight counterpart to
# hvibe/hcode: create a herdr workspace at $PWD (or -p DIR), focus it, and
# attach a client when run from outside herdr. NO git requirement and NO agent
# layout — just a shell in the workspace root pane. This fills the gap where
# every other herdr entry point forces a git repo + a full agent pack; with
# tmux `tmux new-session` lands you in $PWD directly, but herdr adds a Workspace
# layer, so without this you'd launch herdr, create a space (opens at $HOME),
# then cd manually.
#
# Smart argument handling (mirrors shere):
#   hhere                          # plain shell at $PWD
#   hhere npm run dev              # bare args → run as the root-pane command
#   hhere -c "npm run dev"         # explicit --command flag
#   hhere -p ~/proj                # explicit path, plain shell
#   hhere -p ~/proj npm run dev    # explicit path + command
#
# `-p DIR` is absolutized in THIS shell before it reaches herdr — the server
# resolves a relative `--cwd` against its own launch directory and falls back to
# $HOME on a miss (silently). A non-existent DIR is a hard error.
#
# The command (if any) runs raw — no specstory/on-exit wrapping. That agent
# treatment stays with hcode/hvibe; hhere is deliberately lightweight.
#
# Idempotent per label (bare basename of the dir, matching herdr's own native
# auto-label convention). Caveat: herdr auto-relabels a workspace to the root
# pane's LIVE cwd basename after a `cd` in tab 1 (see docs/tools/herdr.md § cwd
# & workspace-naming), so the reuse is best-effort — if the label has drifted, a
# re-run creates a fresh workspace (arguably correct: you're elsewhere now).
#
# Usage:
#   hhere [--path DIR] [--command CMD] [--no-attach] [--session NAME] [CMD...]
function herdr-here() {
    command -v jq >/dev/null 2>&1 || { echo "hhere: jq is required." >&2; return 1; }

    local cmd="" target="" no_attach=0 session_arg=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -c|--command) cmd="$2"; shift 2 ;;
            -p|--path)    target="$2"; shift 2 ;;
            --session)    session_arg="$2"; shift 2 ;;
            --no-attach)  no_attach=1; shift ;;
            -h|--help)
                cat <<'EOF'
hhere — open a plain herdr workspace here + attach (herdr analog of shere)

Usage: hhere [--path DIR] [--command CMD] [--no-attach] [--session NAME] [CMD...]

Creates a herdr workspace at DIR (default $PWD), focuses it, and — when run
from OUTSIDE herdr — attaches a client so it is visible. No git repo required
and no agent layout: just a shell in the workspace root pane. For agent
layouts use hcode (single-agent) or hvibe (multi-agent).

Smart argument handling:
  hhere                        # plain shell at $PWD
  hhere npm run dev            # bare args → run as the root-pane command
  hhere -c "npm run dev"       # explicit --command flag
  hhere -p ~/proj              # explicit path, plain shell
  hhere -p ../sibling          # relative paths resolve against YOUR shell
  hhere -p ~/proj npm run dev  # explicit path + command

--path DIR is resolved (and symlink-canonicalized) here, in your shell, before
it reaches herdr — a DIR that does not exist is a hard error, not a silent
workspace at $HOME.

Idempotent: re-running in the same dir focuses the existing workspace.
--session NAME targets a running herdr session (default: current session when
inside herdr, else the default session; start one with `herdr --session NAME`).
--no-attach builds in the background.
EOF
                return 0 ;;
            -*)           echo "hhere: unknown flag $1" >&2; return 1 ;;
            *)            break ;;  # remaining args are the command
        esac
    done
    [ $# -gt 0 ] && [ -z "$cmd" ] && cmd="$*"
    target="${target:-$PWD}"

    # ABSOLUTIZE — load-bearing, do NOT pass `$target` through verbatim; herdr
    # resolves a relative `--cwd` server-side and falls back to $HOME on a miss.
    # See _herdr_abs_dir above.
    target=$(_herdr_abs_dir "$target" hhere) || return 1

    local label
    label=$(_sesh_sanitize "$(basename "$target")")

    # Resolve the target herdr session (optional --session; else ambient/default).
    local sess_line sess_name sess_sock
    sess_line=$(_herdr_session_target "$session_arg") || return 1
    sess_name=${sess_line%%$'\t'*}
    sess_sock=${sess_line#*$'\t'}
    [ -n "$sess_sock" ] && local -x HERDR_SOCKET_PATH="$sess_sock"

    # Idempotent: focus an existing workspace instead of duplicating.
    local existing
    existing=$(_herdr_ws_by_label "$label")
    if [ -n "$existing" ]; then
        echo "hhere: workspace '$label' already exists ($existing) — focusing." >&2
        if [ "$no_attach" -ne 1 ]; then
            herdr workspace focus "$existing" >/dev/null 2>&1
            _herdr_attach_if_outside "$sess_name"
        fi
        return 0
    fi

    local ws_json ws p0
    ws_json=$(herdr workspace create --cwd "$target" --label "$label" --no-focus 2>/dev/null)
    ws=$(printf '%s' "$ws_json" | jq -r '.result.workspace.workspace_id // empty')
    p0=$(printf '%s' "$ws_json" | jq -r '.result.root_pane.pane_id // empty')
    if [ -z "$ws" ] || [ -z "$p0" ]; then
        echo "hhere: failed to create workspace (is the herdr server running?)." >&2
        return 1
    fi

    # Optional command in the root pane (raw — no specstory/on-exit wrapping).
    [ -n "$cmd" ] && herdr pane run "$p0" "$cmd" >/dev/null 2>&1

    if [ "$no_attach" -ne 1 ]; then
        herdr workspace focus "$ws" >/dev/null 2>&1
        _herdr_attach_if_outside "$sess_name"
    fi
}

# ── hroot: like hhere but at the git-root ────────────────────────────────────
#
# herdr analog of `sroot` (sesh-root). Same as hhere except the target resolves
# to the current git top-level (falls back to $PWD outside a repo). Thin wrapper
# over herdr-here so there is one code path; -p is not accepted (the root IS the
# path), everything else (-c / bare command / --session / --no-attach) passes
# through.
#
# Usage:
#   hroot                          # plain shell at git-root (else $PWD)
#   hroot npm run dev              # + run a command
#   hroot -c "npm run dev"         # explicit --command flag
function herdr-root() {
    case "$1" in
        -h|--help)
            cat <<'EOF'
hroot — open a plain herdr workspace at the git-root + attach (analog of sroot)

Usage: hroot [--command CMD] [--no-attach] [--session NAME] [CMD...]

Like hhere, but the workspace opens at the current git top-level (falls back to
$PWD outside a repo). All flags except --path pass through to hhere.

  hroot                # plain shell at git-root (else $PWD)
  hroot npm run dev    # + run a command
EOF
            return 0 ;;
        -p|--path)
            echo "hroot: --path is not accepted (root is derived from git). Use hhere -p DIR." >&2
            return 1 ;;
    esac
    local root
    root=$(git rev-parse --show-toplevel 2>/dev/null) || root=$PWD
    herdr-here -p "$root" "$@"
}

# ── Review-pending flag (mark-unread / ⭐) ───────────────────────────────────
# hmark/hunmark toggle a per-pane "I still need to review this" flag via herdr's
# `review` metadata token — ORTHOGONAL to agent state, so peeking into a done pane
# (which flips it to idle) does NOT clear the flag. The mark logic lives in
# ~/.config/herdr/review-mark.sh (dot_config/herdr/executable_review-mark.sh);
# these are thin CLI wrappers defaulting the pane to the ambient HERDR_PANE_ID.
# The prefix+m keybind and the `tv herdr-review` inbox share that same script.
_herdr_review_script="${XDG_CONFIG_HOME:-$HOME/.config}/herdr/review-mark.sh"

# hmark [PANE] — flag a pane for later review (default: current pane).
function herdr-mark() {
    case "${1:-}" in
        -h|--help)
            cat <<'EOF'
hmark — flag a herdr pane as "review-pending" (⭐), analog of tmux bookmark

Usage: hmark [PANE_ID]

With no PANE_ID, flags the CURRENT pane (ambient $HERDR_PANE_ID). The flag is a
herdr metadata token (`review`), orthogonal to agent state — it survives the pane
going idle when you peek in. Clear with `hunmark`, toggle with prefix+m, list
flagged panes with `tv herdr-review` (prefix+i inside herdr).
EOF
            return 0 ;;
    esac
    local pane="${1:-${HERDR_PANE_ID:-}}"
    [ -n "$pane" ] || { echo "hmark: no pane id (not inside herdr?). Pass one: hmark w1:p1" >&2; return 1; }
    "$_herdr_review_script" set "$pane"
}

# hunmark [PANE] — clear the review flag (default: current pane).
function herdr-unmark() {
    case "${1:-}" in
        -h|--help)
            cat <<'EOF'
hunmark — clear a herdr pane's "review-pending" (⭐) flag

Usage: hunmark [PANE_ID]

With no PANE_ID, clears the CURRENT pane (ambient $HERDR_PANE_ID).
EOF
            return 0 ;;
    esac
    local pane="${1:-${HERDR_PANE_ID:-}}"
    [ -n "$pane" ] || { echo "hunmark: no pane id (not inside herdr?). Pass one: hunmark w1:p1" >&2; return 1; }
    "$_herdr_review_script" clear "$pane"
}

# ── Aliases ─────────────────────────────────────────────────────────────────
alias hvibe='herdr-vibe'
alias hcode='herdr-code'
alias hhere='herdr-here'
alias hroot='herdr-root'
alias hmark='herdr-mark'
alias hunmark='herdr-unmark'
