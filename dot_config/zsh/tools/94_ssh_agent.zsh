# 94_ssh_agent.zsh - SSH agent with Bitwarden-first fallback to ssh-agent
#
# Priority order:
#   1. Bitwarden SSH agent (desktop app socket)
#   2. Existing SSH_AUTH_SOCK (e.g. forwarded agent, systemd, gnome-keyring)
#   3. Persistent ssh-agent (spawned once per user, reused across shells)
#
# The fallback ssh-agent uses a fixed socket path so multiple shells share
# one agent instead of spawning a new one each time.

# Probe timeout (seconds) — keeps shell startup fast even when an agent
# socket exists but the daemon behind it is hung or locked.
_SSH_AGENT_PROBE_TIMEOUT=2

# Wrapper: ssh-add -l with a timeout to avoid hanging on unresponsive sockets.
# Returns the same exit codes as ssh-add -l (0, 1, 2) plus 124 for timeout.
_ssh_add_probe() {
    if command -v timeout &>/dev/null; then
        timeout "$_SSH_AGENT_PROBE_TIMEOUT" ssh-add -l "$@" 2>&1
    else
        # No timeout command (rare) — run directly and hope for the best
        ssh-add -l "$@" 2>&1
    fi
}

# ---------------------------------------------------------------------------
# 1. Try Bitwarden SSH agent
# ---------------------------------------------------------------------------
_try_bitwarden_agent() {
    typeset -a _bw_candidates

    if [[ "$OSTYPE" == darwin* ]]; then
        _bw_candidates=(
            "$HOME/Library/Application Support/Bitwarden/.bitwarden-ssh-agent.sock"
            "$HOME/Library/Containers/com.bitwarden.desktop/Data/.bitwarden-ssh-agent.sock"
            "$HOME/.bitwarden-ssh-agent.sock"
        )
    else
        _bw_candidates=(
            "$HOME/.bitwarden-ssh-agent.sock"
            "$HOME/snap/bitwarden/current/.bitwarden-ssh-agent.sock"
            "$HOME/.var/app/com.bitwarden.desktop/data/.bitwarden-ssh-agent.sock"
        )
    fi

    for _sock in "${_bw_candidates[@]}"; do
        if [[ -S "$_sock" ]]; then
            # Socket file exists — verify the agent actually responds
            local _out
            _out="$(SSH_AUTH_SOCK="$_sock" _ssh_add_probe)"
            local rc=$?
            # rc=0: keys listed  → usable
            # rc=1 + "no identities": agent ok, no keys loaded → usable
            # rc=1 + "refused": Bitwarden locked/agent disabled → skip
            # rc=2: agent unreachable → skip
            # rc=124: timed out → skip
            if (( rc == 0 )); then
                export SSH_AUTH_SOCK="$_sock"
                return 0
            elif (( rc == 1 )) && [[ "$_out" != *"refused"* ]]; then
                export SSH_AUTH_SOCK="$_sock"
                return 0
            fi
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# 2. Check if the current SSH_AUTH_SOCK is already usable
# ---------------------------------------------------------------------------
_existing_agent_works() {
    [[ -n "$SSH_AUTH_SOCK" && -S "$SSH_AUTH_SOCK" ]] || return 1
    local _out
    _out="$(_ssh_add_probe)"
    local rc=$?
    # Accept rc=0 (keys) or rc=1 without "refused" (empty but alive)
    if (( rc == 0 )); then
        return 0
    elif (( rc == 1 )) && [[ "$_out" != *"refused"* ]]; then
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# 3. Fallback: persistent ssh-agent with a well-known socket
# ---------------------------------------------------------------------------
_fallback_ssh_agent() {
    local agent_dir="${XDG_RUNTIME_DIR:-$HOME/.cache}/ssh-agent"
    local agent_sock="$agent_dir/agent.sock"
    local agent_pid_file="$agent_dir/agent.pid"

    # Reuse existing persistent agent if it's alive
    if [[ -S "$agent_sock" ]]; then
        export SSH_AUTH_SOCK="$agent_sock"
        if [[ -f "$agent_pid_file" ]]; then
            export SSH_AGENT_PID="$(< "$agent_pid_file")"
        fi
        # Verify it actually works
        _ssh_add_probe &>/dev/null
        local rc=$?
        if (( rc == 0 || rc == 1 )); then
            _maybe_add_keys
            return 0
        fi
        # Stale socket — clean up and respawn below
        rm -f "$agent_sock" "$agent_pid_file"
    fi

    # Spawn a new agent with a fixed socket path
    mkdir -p "$agent_dir"
    chmod 700 "$agent_dir"
    eval "$(ssh-agent -a "$agent_sock" 2>/dev/null)" &>/dev/null
    if [[ -n "$SSH_AGENT_PID" ]]; then
        echo "$SSH_AGENT_PID" > "$agent_pid_file"
        export SSH_AUTH_SOCK="$agent_sock"
        _maybe_add_keys
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Auto-add keys that exist on disk (only when agent has no identities)
# ---------------------------------------------------------------------------
_maybe_add_keys() {
    # Only add if agent is empty
    ssh-add -l &>/dev/null
    (( $? == 1 )) || return 0  # rc=1 means "agent ok, no identities"

    # Common private key names (add more as needed)
    local -a key_names=(id_ed25519 id_rsa id_ecdsa jingle)
    for k in "${key_names[@]}"; do
        local kf="$HOME/.ssh/$k"
        [[ -f "$kf" ]] && SSH_ASKPASS_REQUIRE=never ssh-add -q "$kf" 2>/dev/null
    done
}

# ---------------------------------------------------------------------------
# Main: try each strategy in order
# ---------------------------------------------------------------------------
_try_bitwarden_agent || _existing_agent_works || _fallback_ssh_agent

# Clean up helper functions (they pollute the namespace)
unfunction _try_bitwarden_agent _existing_agent_works _fallback_ssh_agent _maybe_add_keys _ssh_add_probe 2>/dev/null
unset _SSH_AGENT_PROBE_TIMEOUT
