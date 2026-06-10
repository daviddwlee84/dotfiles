#!/usr/bin/env bash
# bootstrap.sh — curl|sh entry for daviddwlee84/dotfiles.
#
#   curl -fsSL https://raw.githubusercontent.com/daviddwlee84/dotfiles/main/bootstrap.sh | bash
#
# What it does, in order:
#   1. Installs `uv` (Astral's Python runtime/tool manager) if missing.
#   1b. Ensures a non-snap `~/.local/bin/chezmoi` exists and is first on PATH
#      (the snap build has a stdin/stdout `permission denied` bug that breaks
#      this repo's modify_/run_ scripts), so the TUI resolves the good binary.
#   2. Attaches /dev/tty as the FINAL `exec uv run`'s stdin so questionary
#      prompts work even though THIS script's own stdin is the curl pipe.
#      We must NOT do `exec </dev/tty` mid-script — that would repoint
#      bash's own script reader at /dev/tty and hang on the next line
#      (bash reads the script body from fd 0 in `curl | bash` mode, and
#      its read behaviour is "undefined" enough to bite on fresh users).
#      See: pitfalls/bootstrap-curl-bash-hangs-after-reattaching-tty.md.
#   3. Fetches + runs scripts/init/dotfiles_init.py from the pinned ref via
#      `uv run --script <url>` — this downloads the script, resolves its
#      PEP 723 inline deps into an ephemeral venv, and runs it. No global
#      install, no pyproject.toml to maintain.
#
# Notes:
#   - This script is kept in .chezmoiignore.tmpl so `chezmoi apply` does NOT
#     deploy it to $HOME/bootstrap.sh.
#   - Behind GFW: github.com / raw.githubusercontent.com may be blocked.
#     Set DOTFILES_RAW_URL / DOTFILES_REF to a mirror (e.g. ghproxy.com).
#     See docs/this_repo/bootstrap.md → "Behind GFW / proxy".
#   - Pass extra args through to dotfiles_init (e.g. `| bash -s -- doctor`).
#
# Verbose mode (recommended for slow networks / first-time runs):
#   curl -fsSL .../bootstrap.sh | DOTFILES_BOOTSTRAP_VERBOSE=1 bash
#   Sets `set -x`, makes uv print download/resolve progress (`--verbose`),
#   and timestamps every stage so you can see where it's stuck.

set -euo pipefail

DOTFILES_RAW_URL="${DOTFILES_RAW_URL:-https://raw.githubusercontent.com/daviddwlee84/dotfiles}"
DOTFILES_REF="${DOTFILES_REF:-main}"
SCRIPT_URL="${DOTFILES_RAW_URL}/${DOTFILES_REF}/scripts/init/dotfiles_init.py"
VERBOSE="${DOTFILES_BOOTSTRAP_VERBOSE:-0}"

log() {
    # Timestamped log line so you can spot which stage is slow.
    printf '[bootstrap %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2
}

if [ "$VERBOSE" = "1" ]; then
    set -x
    UV_RUN_FLAGS=(--verbose)
else
    UV_RUN_FLAGS=()
fi

log "starting (ref=${DOTFILES_REF}, raw=${DOTFILES_RAW_URL})"
log "PATH=${PATH}"
log "TTY: stdin=$([ -t 0 ] && echo yes || echo no), /dev/tty=$([ -r /dev/tty ] && echo readable || echo no)"

# --- 1. ensure uv ------------------------------------------------------------
if ! command -v uv >/dev/null 2>&1; then
    log "uv not found — installing from https://astral.sh/uv/install.sh"
    log "(if this hangs >30s, you're likely behind GFW; see docs/this_repo/bootstrap.md)"
    curl -fsSL https://astral.sh/uv/install.sh | sh
    # uv's installer writes to ~/.local/bin by default; add to PATH for this shell.
    export PATH="${HOME}/.local/bin:${PATH}"
    log "uv installed: $(command -v uv || echo MISSING)"
else
    log "uv already present: $(command -v uv) ($(uv --version 2>/dev/null || echo unknown))"
fi

# --- 1b. ensure a non-snap chezmoi on PATH ----------------------------------
# The TUI resolves chezmoi via PATH. The snap build has a long-standing
# stdin/stdout `permission denied` bug that breaks this repo's modify_/run_
# scripts, and is not the install the README documents. So if chezmoi is
# missing OR the one found is under /snap, install the canonical binary to
# ~/.local/bin; then put ~/.local/bin first on PATH so it always wins.
CHEZMOI_FOUND="$(command -v chezmoi 2>/dev/null || true)"
NEED_CHEZMOI=0
if [ -z "$CHEZMOI_FOUND" ]; then
    NEED_CHEZMOI=1
    log "chezmoi not found — installing to ~/.local/bin via get.chezmoi.io"
elif [ "${CHEZMOI_FOUND#/snap/}" != "$CHEZMOI_FOUND" ]; then
    NEED_CHEZMOI=1
    log "found snap chezmoi at ${CHEZMOI_FOUND} (stdin/stdout bug) — installing canonical to ~/.local/bin"
fi
if [ "$NEED_CHEZMOI" = "1" ] && [ ! -x "${HOME}/.local/bin/chezmoi" ]; then
    mkdir -p "${HOME}/.local/bin"
    if ! (curl -fsLS --retry 3 --retry-delay 5 get.chezmoi.io/lb | BINDIR="${HOME}/.local/bin" sh); then
        log "chezmoi install via get.chezmoi.io failed; the TUI will offer to install it"
    fi
fi
# Keep ~/.local/bin first so the canonical chezmoi (and uv-installed tools)
# always win over any /snap or system copy.
export PATH="${HOME}/.local/bin:${PATH}"
log "chezmoi resolved: $(command -v chezmoi || echo MISSING)"

# --- 2. decide whether to feed /dev/tty to the final exec --------------------
# `[ -t 0 ]` is false when stdin is the pipe; questionary needs a real TTY.
# We CANNOT `exec </dev/tty` here — that repoints bash's own fd 0, which
# is also where bash reads the rest of THIS script from in `curl | bash`
# mode. The next line would then block on /dev/tty waiting for keyboard
# input that never comes. Instead we attach /dev/tty as the *child*'s
# stdin on the final exec, leaving bash's own fd 0 on the curl pipe.
NEED_TTY_REDIRECT=0
if [ ! -t 0 ] && [ -r /dev/tty ]; then
    log "stdin is a pipe — will attach /dev/tty as uv run's stdin (not bash's)"
    NEED_TTY_REDIRECT=1
fi

# --- 3. run ------------------------------------------------------------------
log "fetching + running ${SCRIPT_URL}"
log "(first run resolves PEP 723 deps: questionary, rich, tyro — may take 30s-3min on slow networks)"
log "(set DOTFILES_BOOTSTRAP_VERBOSE=1 to see uv resolver progress)"
if [ "$NEED_TTY_REDIRECT" = "1" ]; then
    exec uv run "${UV_RUN_FLAGS[@]}" --script "$SCRIPT_URL" "$@" </dev/tty
else
    exec uv run "${UV_RUN_FLAGS[@]}" --script "$SCRIPT_URL" "$@"
fi
