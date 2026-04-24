# shellcheck shell=bash
# Shared sudo session — "prompt once, reuse across the whole chezmoi apply flow".
#
# Consumed by:
#   - run_once_before_00_bootstrap.sh.tmpl
#   - .chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl
#   - .chezmoiscripts/global/run_onchange_after_30_brew_bundle.sh.tmpl
# via `{{ include "scripts/lib/sudo_shared.sh" }}` at render time. `include`
# (not `includeTemplate`) is used because this file is plain bash, not a
# chezmoi template — no `{{ … }}` tokens need re-rendering.
#
# WHY inlined instead of sourced: each run_*.sh.tmpl is rendered by chezmoi
# to a temp path and executed there; at runtime it has no reliable route back
# to the source tree, so `source` would be fragile. Inlining keeps one
# source-of-truth here while placing the code wherever it is needed.
# Bonus: `scripts/**` is listed in .chezmoiignore.tmpl so this file is never
# deployed to $HOME — its only existence at runtime is the inlined copy.
#
# Lifetime:
#   - State dir `$XDG_RUNTIME_DIR/chezmoi-sudo-$UID/` (or $TMPDIR fallback),
#     mode 0700, contains:
#       sudo.pass           0600  raw password (one line, terminating \n)
#       ansible-become.yml  0600  `ansible_become_password: "…"` for `-e @`
#       keepalive.pid       0600  detached watchdog PID
#       chezmoi.pid         0600  ancestor chezmoi PID the watchdog watches
#   - Watchdog is detached via `setsid` so a run-script EXIT does not reap it.
#     It watches the chezmoi ancestor PID and `rm -rf`s the state dir when
#     chezmoi exits. That is the effective end-of-flow cleanup — per-script
#     EXIT traps would wipe state before the NEXT run-script could reuse it.
#   - INT/TERM/HUP in any consuming script triggers `sudo_session_abort`,
#     which kills the watchdog and wipes state immediately.
#
# Public API:
#   sudo_session_init [label]   Idempotent. If state valid, re-export vars and
#                               return. Else probe passwordless sudo; if not
#                               passwordless, prompt once on /dev/tty, validate,
#                               write files, spawn watchdog. Returns non-zero if
#                               no TTY available and not passwordless.
#                               Non-interactive override: when env var
#                               CHEZMOI_SUDO_PASSWORD_FILE points to a 0600 file
#                               containing the password, the file is adopted
#                               instead of prompting (used by remote orchestrators
#                               like scripts/fleet_apply.py — see docs/this_repo/
#                               fleet-apply.md).
#   sudo_session_skip_reason    Print a one-word label the caller uses to pick
#                               a branch: "cached" | "passwordless" |
#                               "non-interactive" | "" (empty = not probed yet).
#                               Safe to call before OR after sudo_session_init.
#   sudo_session_abort          Signal handler target — kill watchdog, wipe state.
#   sudo_run <cmd...>           `sudo -S` wrapper that pipes the cached password
#                               from the state file; no password ever in argv.
#                               Falls back to plain `sudo` when passwordless.
#   sudo_session_warm_cache     Best-effort: refresh the CURRENT TTY's sudo
#                               timestamp using the cached password (for callers
#                               like `brew bundle` whose cask pkg installers
#                               invoke `sudo /usr/sbin/installer` internally).
#
# Exports on success:
#   CHEZMOI_SUDO_STATE_DIR  CHEZMOI_SUDO_PASS_FILE
#   CHEZMOI_ANSIBLE_BECOME_FILE  CHEZMOI_SUDO_KEEPALIVE_PID

_sudo_state_dir_path() {
    local base="${XDG_RUNTIME_DIR:-}"
    if [[ -n "$base" && -d "$base" ]]; then
        printf '%s/chezmoi-sudo-%s\n' "$base" "$(id -u)"
    else
        printf '%s/chezmoi-sudo-%s\n' "${TMPDIR:-/tmp}" "$(id -u)"
    fi
}

# Walk the parent chain looking for a `chezmoi` process; prints its PID, or
# empty on miss. Cross-platform: /proc on Linux, ps on macOS.
_sudo_find_chezmoi_ancestor() {
    local pid="${PPID:-0}"
    local comm=""
    local hops=0
    while [[ "$pid" -gt 1 && "$hops" -lt 20 ]]; do
        if [[ -r "/proc/$pid/comm" ]]; then
            comm="$(cat "/proc/$pid/comm" 2>/dev/null || printf '')"
        else
            comm="$(ps -o comm= -p "$pid" 2>/dev/null | awk 'NR==1{n=split($0,a,"/"); print a[n]}')"
        fi
        if [[ "$comm" == "chezmoi" ]]; then
            printf '%s\n' "$pid"
            return 0
        fi
        if [[ -r "/proc/$pid/status" ]]; then
            pid="$(awk '/^PPid:/ {print $2; exit}' "/proc/$pid/status" 2>/dev/null)"
        else
            pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
        fi
        [[ -n "$pid" && "$pid" != "0" ]] || break
        hops=$((hops + 1))
    done
    printf ''
}

_sudo_state_valid() {
    local dir="$1"
    [[ -d "$dir" && -f "$dir/sudo.pass" && -f "$dir/ansible-become.yml" && -f "$dir/keepalive.pid" ]] || return 1
    local pid
    pid="$(cat "$dir/keepalive.pid" 2>/dev/null)" || return 1
    [[ -n "$pid" ]] || return 1
    # Watchdog still alive?
    kill -0 "$pid" 2>/dev/null || return 1
    # Credentials still valid? (catches "user changed their password mid-apply").
    # SC2024: the redirect is read by the parent shell, which is fine — the
    # current user owns the 0600 file and sudo reads the password via stdin.
    # shellcheck disable=SC2024
    sudo -S -v -p '' <"$dir/sudo.pass" 2>/dev/null || return 1
    return 0
}

_sudo_spawn_watchdog() {
    local state_dir="$1"
    local watch_pid="$2"
    # setsid detaches from the controlling TTY + session so the watchdog is
    # not reaped when the invoking run-script exits normally.
    # SC2016: body is passed to the child `bash -c` where $1/$2 are its own
    # positional params, so single-quoting is intentional (no expansion here).
    # shellcheck disable=SC2016
    setsid bash -c '
        STATE_DIR="$1"
        WATCH_PID="$2"
        # WHY: the real "keep-alive" is the sudo.pass + `sudo -S` pattern —
        # we still refresh the timestamp opportunistically so short-lived
        # downstream callers may benefit. Failures (tty_tickets mismatch,
        # stale password) are swallowed; they are not cleanup triggers.
        while kill -0 "$WATCH_PID" 2>/dev/null; do
            sudo -S -v -p "" <"$STATE_DIR/sudo.pass" 2>/dev/null || true
            sleep 50
        done
        rm -rf "$STATE_DIR"
    ' _ "$state_dir" "$watch_pid" </dev/null >/dev/null 2>&1 &
    local pid=$!
    disown 2>/dev/null || true
    printf '%s\n' "$pid"
}

sudo_session_abort() {
    local dir="${CHEZMOI_SUDO_STATE_DIR:-}"
    local pid="${CHEZMOI_SUDO_KEEPALIVE_PID:-}"
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    [[ -n "$dir" && -d "$dir" ]] && rm -rf "$dir"
    return 0
}

sudo_session_init() {
    local label="${1:-chezmoi}"
    local dir
    dir="$(_sudo_state_dir_path)"

    # Idempotent reuse: another run-script in the same flow set this up.
    if _sudo_state_valid "$dir"; then
        export CHEZMOI_SUDO_STATE_DIR="$dir"
        export CHEZMOI_SUDO_PASS_FILE="$dir/sudo.pass"
        export CHEZMOI_ANSIBLE_BECOME_FILE="$dir/ansible-become.yml"
        CHEZMOI_SUDO_KEEPALIVE_PID="$(cat "$dir/keepalive.pid" 2>/dev/null || printf '')"
        export CHEZMOI_SUDO_KEEPALIVE_PID
        trap 'sudo_session_abort' INT TERM HUP
        return 0
    fi

    # Truly passwordless? No file, no watchdog, no prompt.
    if sudo -n true 2>/dev/null; then
        return 0
    fi

    # Non-interactive password injection (used by remote orchestrators like
    # scripts/fleet_apply.py over SSH). When CHEZMOI_SUDO_PASSWORD_FILE points
    # to a 0600 file containing the password (one line), adopt it instead of
    # prompting on /dev/tty. The file is moved into the shared state dir and
    # the env-supplied path is unset so subsequent run-scripts use the cached
    # state-dir copy via the normal idempotent path.
    if [[ -r "${CHEZMOI_SUDO_PASSWORD_FILE:-/nonexistent}" ]]; then
        local injected_pw=""
        injected_pw="$(cat "$CHEZMOI_SUDO_PASSWORD_FILE" 2>/dev/null || printf '')"
        # Strip a single trailing newline if present.
        injected_pw="${injected_pw%$'\n'}"
        if [[ -n "$injected_pw" ]] && printf '%s\n' "$injected_pw" | sudo -S -v -p '' 2>/dev/null; then
            [[ -d "$dir" ]] && rm -rf "$dir"
            (umask 077 && mkdir -p "$dir") || { unset injected_pw; return 1; }
            chmod 700 "$dir" 2>/dev/null || true
            local pf="$dir/sudo.pass" bf="$dir/ansible-become.yml"
            (umask 177 && : > "$pf" && : > "$bf") || { unset injected_pw; rm -rf "$dir"; return 1; }
            chmod 600 "$pf" "$bf" 2>/dev/null || true
            printf '%s\n' "$injected_pw" > "$pf"
            local esc="${injected_pw//\\/\\\\}"
            esc="${esc//\"/\\\"}"
            printf 'ansible_become_password: "%s"\n' "$esc" > "$bf"
            unset injected_pw esc
            local wpid
            wpid="$(_sudo_find_chezmoi_ancestor)"
            [[ -z "$wpid" ]] && wpid="$PPID"
            printf '%s\n' "$wpid" > "$dir/chezmoi.pid"
            chmod 600 "$dir/chezmoi.pid" 2>/dev/null || true
            local kpid
            kpid="$(_sudo_spawn_watchdog "$dir" "$wpid")"
            printf '%s\n' "$kpid" > "$dir/keepalive.pid"
            chmod 600 "$dir/keepalive.pid" 2>/dev/null || true
            export CHEZMOI_SUDO_STATE_DIR="$dir"
            export CHEZMOI_SUDO_PASS_FILE="$pf"
            export CHEZMOI_ANSIBLE_BECOME_FILE="$bf"
            export CHEZMOI_SUDO_KEEPALIVE_PID="$kpid"
            unset CHEZMOI_SUDO_PASSWORD_FILE
            trap 'sudo_session_abort' INT TERM HUP
            return 0
        fi
        unset injected_pw
        printf '[%s] CHEZMOI_SUDO_PASSWORD_FILE rejected by sudo — aborting.\n' "$label" >&2
        return 1
    fi

    # Not passwordless and no TTY: caller must fall through to its manual path.
    if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
        return 1
    fi

    # Stale dir from a crashed previous flow? Wipe before re-init.
    [[ -d "$dir" ]] && rm -rf "$dir"
    (umask 077 && mkdir -p "$dir") || return 1
    chmod 700 "$dir" 2>/dev/null || true

    local pass_file="$dir/sudo.pass"
    local become_file="$dir/ansible-become.yml"
    (umask 177 && : > "$pass_file" && : > "$become_file") || { rm -rf "$dir"; return 1; }
    chmod 600 "$pass_file" "$become_file" 2>/dev/null || true

    printf '[%s] sudo password for %s (entered once, reused for this chezmoi apply): ' "$label" "$USER" > /dev/tty
    local pw=""
    IFS= read -rs pw < /dev/tty
    echo > /dev/tty

    # Validate. `-S` reads stdin; `-v` updates the timestamp without running a
    # command; `-p ''` suppresses the prompt (we already printed our own).
    if ! printf '%s\n' "$pw" | sudo -S -v -p '' 2>/dev/null; then
        unset pw
        rm -rf "$dir"
        printf '[%s] sudo password rejected — aborting.\n' "$label" > /dev/tty
        return 1
    fi

    printf '%s\n' "$pw" > "$pass_file"
    # YAML double-quoted: escape backslash THEN double-quote so we don't
    # double-escape a backslash we just inserted.
    local escaped="${pw//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    printf 'ansible_become_password: "%s"\n' "$escaped" > "$become_file"
    unset pw escaped

    local watch_pid
    watch_pid="$(_sudo_find_chezmoi_ancestor)"
    [[ -z "$watch_pid" ]] && watch_pid="$PPID"
    printf '%s\n' "$watch_pid" > "$dir/chezmoi.pid"
    chmod 600 "$dir/chezmoi.pid" 2>/dev/null || true

    local keepalive_pid
    keepalive_pid="$(_sudo_spawn_watchdog "$dir" "$watch_pid")"
    printf '%s\n' "$keepalive_pid" > "$dir/keepalive.pid"
    chmod 600 "$dir/keepalive.pid" 2>/dev/null || true

    export CHEZMOI_SUDO_STATE_DIR="$dir"
    export CHEZMOI_SUDO_PASS_FILE="$pass_file"
    export CHEZMOI_ANSIBLE_BECOME_FILE="$become_file"
    export CHEZMOI_SUDO_KEEPALIVE_PID="$keepalive_pid"
    trap 'sudo_session_abort' INT TERM HUP
    return 0
}

sudo_run() {
    if [[ -z "${CHEZMOI_SUDO_PASS_FILE:-}" ]]; then
        # Passwordless sudo or session not initialized — use sudo directly.
        sudo "$@"
        return $?
    fi
    # `sudo -S -p ''` reads password from stdin and prints nothing for the
    # prompt. `--` marks end of sudo options so the user cmd/flags are safe.
    # SC2024: redirect is done by the parent shell (reading its own 0600
    # file); sudo only sees the password on stdin, never in argv.
    # shellcheck disable=SC2024
    sudo -S -p '' -- "$@" <"$CHEZMOI_SUDO_PASS_FILE"
}

sudo_session_warm_cache() {
    # Refresh the CURRENT TTY's sudo timestamp with the cached password.
    # Use before a child tool (e.g. `brew bundle` -> cask pkg installer)
    # that spawns `sudo` internally and relies on timestamp cache rather
    # than accepting a piped password.
    [[ -z "${CHEZMOI_SUDO_PASS_FILE:-}" ]] && return 0
    # shellcheck disable=SC2024
    sudo -S -v -p '' <"$CHEZMOI_SUDO_PASS_FILE" 2>/dev/null || return 1
    return 0
}

sudo_session_skip_reason() {
    # Classify the current sudo state so callers can pick a branch without
    # reimplementing the probe themselves:
    #
    #   "cached"           sudo_session_init already prompted (or reused a
    #                      sibling script's prompt); the caller should pipe the
    #                      password via sudo_run / use $CHEZMOI_ANSIBLE_BECOME_FILE.
    #   "passwordless"     sudo works without any password at all; the caller
    #                      can invoke plain `sudo` and must not pre-auth.
    #   "non-interactive"  no cached password, no passwordless sudo, no TTY:
    #                      the caller must skip sudo-dependent steps entirely
    #                      and print a manual-command hint.
    #   ""  (empty)        interactive TTY present but sudo_session_init has
    #                      not been called yet. The caller should call
    #                      sudo_session_init before proceeding. Returned so
    #                      defensive callers can detect "probe too early".
    #
    # This function performs at most one cheap `sudo -n true` probe and no
    # prompts of its own.
    if [[ -n "${CHEZMOI_SUDO_PASS_FILE:-}" && -f "${CHEZMOI_SUDO_PASS_FILE:-}" ]]; then
        printf 'cached\n'
        return 0
    fi
    if sudo -n true 2>/dev/null; then
        printf 'passwordless\n'
        return 0
    fi
    if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
        printf 'non-interactive\n'
        return 0
    fi
    printf ''
}
