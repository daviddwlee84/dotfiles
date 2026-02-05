# 33_toolkami.zsh - toolkami configuration (MCP server tool)
# https://github.com/aperoc/toolkami

[[ -f "$HOME/.local/toolkami.rb" ]] || return 0

eval "$(ruby ~/.local/toolkami.rb init)"
