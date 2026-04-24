#!/usr/bin/env bash
# bootstrap.sh — curl|sh entry for daviddwlee84/dotfiles.
#
#   curl -fsSL https://raw.githubusercontent.com/daviddwlee84/dotfiles/main/bootstrap.sh | bash
#
# What it does, in order:
#   1. Installs `uv` (Astral's Python runtime/tool manager) if missing.
#   2. Re-execs against /dev/tty so questionary prompts work even though stdin
#      is the curl pipe. Without this, the interactive wrapper falls back to
#      non-interactive stubs and skips every prompt.
#   3. Fetches + runs scripts/init/dotfiles_init.py from the pinned ref via
#      `uv run --script <url>` — this downloads the script, resolves its
#      PEP 723 inline deps into an ephemeral venv, and runs it. No global
#      install, no pyproject.toml to maintain.
#
# Notes:
#   - This script is kept in .chezmoiignore.tmpl so `chezmoi apply` does NOT
#     deploy it to $HOME/bootstrap.sh.
#   - Behind GFW: github.com / raw.githubusercontent.com may be blocked.
#     Set DOTFILES_RAW_URL / DOTFILES_REF to a mirror (e.g. gitee.com raw).
#   - Pass extra args through to dotfiles_init (e.g. `| bash -s -- doctor`).

set -euo pipefail

DOTFILES_RAW_URL="${DOTFILES_RAW_URL:-https://raw.githubusercontent.com/daviddwlee84/dotfiles}"
DOTFILES_REF="${DOTFILES_REF:-main}"
SCRIPT_URL="${DOTFILES_RAW_URL}/${DOTFILES_REF}/scripts/init/dotfiles_init.py"

# --- 1. ensure uv ------------------------------------------------------------
if ! command -v uv >/dev/null 2>&1; then
    echo "[bootstrap] Installing uv..."
    curl -fsSL https://astral.sh/uv/install.sh | sh
    # uv's installer writes to ~/.local/bin by default; add to PATH for this shell.
    export PATH="${HOME}/.local/bin:${PATH}"
fi

# --- 2. re-exec under /dev/tty if we were piped (curl | bash) ----------------
# `[ -t 0 ]` is false when stdin is the pipe; re-exec so questionary can read
# keystrokes. Skip when there's no controlling TTY at all (headless CI).
if [ ! -t 0 ] && [ -r /dev/tty ]; then
    exec < /dev/tty
fi

# --- 3. run ------------------------------------------------------------------
echo "[bootstrap] Running ${SCRIPT_URL}..."
exec uv run --script "$SCRIPT_URL" "$@"
