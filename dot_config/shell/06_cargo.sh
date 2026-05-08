# 06_cargo.sh - Cargo (Rust) bin path (shared by zsh/bash via dot_config/shell/)
# cargo install places binaries in ~/.cargo/bin

# Add cargo bin to PATH if it exists
[[ -d "$HOME/.cargo/bin" ]] && export PATH="$HOME/.cargo/bin:$PATH"

# Source cargo env if exists (for non-mise Rust installations)
[[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
