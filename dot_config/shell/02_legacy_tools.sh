# 02_legacy_tools.sh - Legacy tools and PATH configurations (POSIX subset).
# Sourced by both ~/.zshrc and ~/.bashrc via load_modular_dir
# "$XDG_CONFIG_HOME/shell" sh. Tools that existed before chezmoi management;
# kept for backwards compatibility with existing installations.

# =============================================================================
# Go (Golang) — keep HOME tidy: no ~/go. GOPATH → XDG data, go install → ~/.local/bin.
# XDG_DATA_HOME is exported by the rc files before this module (defensive fallback
# kept per repo convention). ~/.local/bin is already on PATH via 00_exports.sh.tmpl,
# so GOBIN targets need no extra PATH entry. GOCACHE stays macOS-native (~/Library).
# =============================================================================
export GOPATH="${GOPATH:-${XDG_DATA_HOME:-$HOME/.local/share}/go}"
export GOBIN="${GOBIN:-$HOME/.local/bin}"

# Homebrew Go (Apple Silicon, then Intel), falling back to a manual /usr/local/go
# install only when neither brew Go exists. Order matters: the Intel brew path
# (/usr/local/opt/go/bin) MUST come before the manual /usr/local/go fallback, or
# a stale hand-installed Go (e.g. an old go1.15 from a 2020 .pkg) shadows brew's
# current Go on Intel Macs. See memory: homebrew-aliyun-autoupdate-hang.
if [[ -d "/opt/homebrew/opt/go/bin" ]]; then
    export PATH="/opt/homebrew/opt/go/bin:$PATH"
elif [[ -d "/usr/local/opt/go/bin" ]]; then
    export PATH="/usr/local/opt/go/bin:$PATH"
elif [[ -d "/usr/local/go/bin" ]]; then
    export PATH="/usr/local/go/bin:$PATH"
fi

# =============================================================================
# Bun (JavaScript runtime)
# https://bun.sh/
# =============================================================================
export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
[[ -d "$BUN_INSTALL/bin" ]] && export PATH="$BUN_INSTALL/bin:$PATH"
# bun's ~/.bun/_bun is a ZSH-only completion file (uses zsh glob qualifiers
# like `(N)` and the `_alternative` builtin) that errors loudly when sourced
# in bash. Gate to zsh; bash gets bun completion via bash-completion v2 if
# bun installed it under $HB_PREFIX/etc/bash_completion.d/ instead.
if [ -n "$ZSH_VERSION" ] && [ -s "$BUN_INSTALL/_bun" ]; then
    source "$BUN_INSTALL/_bun"
fi

# =============================================================================
# pnpm (package manager)
# https://pnpm.io/
# =============================================================================
if [[ "$OSTYPE" == darwin* ]]; then
    export PNPM_HOME="${PNPM_HOME:-$HOME/Library/pnpm}"
else
    export PNPM_HOME="${PNPM_HOME:-$HOME/.local/share/pnpm}"
fi
[[ -d "$PNPM_HOME" ]] && export PATH="$PNPM_HOME:$PATH"

# =============================================================================
# Foundry (Ethereum development toolkit)
# https://getfoundry.sh/
# =============================================================================
[[ -d "$HOME/.foundry/bin" ]] && export PATH="$HOME/.foundry/bin:$PATH"

# =============================================================================
# NVM (Node Version Manager) - Legacy
# https://github.com/nvm-sh/nvm
# NOTE: mise (05_mise.zsh) is preferred for Node.js management.
#       nvm is skipped by default. Use `LOAD_NVM=1 zsh` or add to ~/.zshrc.adhoc.
# =============================================================================
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

if [[ -n "$LOAD_NVM" ]]; then
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
fi

# =============================================================================
# .NET
# =============================================================================
[[ -d "$HOME/.dotnet/tools" ]] && export PATH="$HOME/.dotnet/tools:$PATH"
