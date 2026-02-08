# 02_legacy.zsh - Legacy tools and PATH configurations
# These are tools that existed before chezmoi management
# Kept for backwards compatibility with existing installations

# =============================================================================
# Go (Golang)
# =============================================================================
export GOPATH="${GOPATH:-$HOME/go}"
[[ -d "$GOPATH/bin" ]] && export PATH="$GOPATH/bin:$PATH"

# Homebrew Go or system Go
if [[ -d "/opt/homebrew/opt/go/bin" ]]; then
    export PATH="/opt/homebrew/opt/go/bin:$PATH"
elif [[ -d "/usr/local/go/bin" ]]; then
    export PATH="/usr/local/go/bin:$PATH"
fi

# =============================================================================
# Bun (JavaScript runtime)
# https://bun.sh/
# =============================================================================
export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
[[ -d "$BUN_INSTALL/bin" ]] && export PATH="$BUN_INSTALL/bin:$PATH"
[[ -s "$BUN_INSTALL/_bun" ]] && source "$BUN_INSTALL/_bun"

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
#       nvm is kept for backwards compatibility with existing installations.
# =============================================================================
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

# Standard nvm initialization
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

# Lazy load nvm - only load when nvm/node/npm/npx command is called
# Disabled in favor of standard initialization to support globally installed npm packages (e.g., clawdbot)
# if [[ -s "$NVM_DIR/nvm.sh" ]] && ! command -v nvm &>/dev/null; then
#     _nvm_lazy_load() {
#         unset -f nvm node npm npx _nvm_lazy_load
#         [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
#         [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
#     }
#     nvm() { _nvm_lazy_load; nvm "$@"; }
#     node() { _nvm_lazy_load; node "$@"; }
#     npm() { _nvm_lazy_load; npm "$@"; }
#     npx() { _nvm_lazy_load; npx "$@"; }
# fi

# =============================================================================
# .NET
# =============================================================================
[[ -d "$HOME/.dotnet/tools" ]] && export PATH="$HOME/.dotnet/tools:$PATH"
