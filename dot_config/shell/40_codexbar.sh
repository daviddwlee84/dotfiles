# 40_codexbar.sh - CodexBar CLI aliases (AI usage tracker; shared by zsh/bash)

# Check if codexbar is installed
command -v codexbar &>/dev/null || return 0

# Usage aliases. `--source auto` (the default) resolves per-provider and is
# correct on both OSes: on Linux the browser-backed modes are unsupported, so
# auto falls through to local files / provider CLI / OAuth on its own. Only
# pass `--source cli` when you specifically want the provider-CLI path.
alias cbu="codexbar usage --provider claude"
alias cbc="codexbar cost --provider claude"
alias cbca="codexbar cost"
