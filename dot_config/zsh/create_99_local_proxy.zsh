# ~/.config/zsh/99_local_proxy.zsh
# Create-only machine-local proxy overrides.
#
# This file is seeded once by chezmoi and then left alone. Edit it locally to
# pin proxy helper behavior without creating future chezmoi diffs.
#
# Open a new shell after editing, or run:
#   proxy-refresh
#
# Clash mixed-port example (HTTP + SOCKS on the same port):
# export LOCAL_PROXY_URL="http://127.0.0.1:7891"
# export LOCAL_PROXY_SOCKS_URL="socks5://127.0.0.1:7891"
#
# Clash split-port example:
# export LOCAL_PROXY_URL="http://127.0.0.1:7890"
# export LOCAL_PROXY_SOCKS_URL="socks5://127.0.0.1:7891"
#
# Auto-export proxy vars on shell startup:
# export LOCAL_PROXY_AUTO_ACTIVATE=1
