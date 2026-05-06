# 02_history.bash - bash-specific history settings.
# Sourced from dot_bashrc.tmpl via load_modular_dir "$BASH_CONFIG_DIR" bash.

# Larger history than the Ubuntu skel default (1000/2000).
HISTSIZE=10000
HISTFILESIZE=20000

# ignoreboth = ignoredups + ignorespace
#   - duplicates of the immediately previous line are dropped
#   - lines starting with a space are dropped (good for one-shot
#     commands you don't want recorded, e.g. typing a token)
HISTCONTROL=ignoreboth

# Append to history file rather than overwrite on shell exit.
# Combined with PROMPT_COMMAND below (or ble.sh's own history sync),
# multiple bash sessions share history without clobbering each other.
shopt -s histappend

# Save multi-line commands as one history entry (preserves the original
# typed form for editing with up-arrow + e).
shopt -s cmdhist

# Update LINES/COLUMNS after each command — fixes redraw bugs after
# terminal resize (preserved from Ubuntu skel).
shopt -s checkwinsize

# ** matches recursive subdirs in pathname expansion (preserved from
# Ubuntu skel where it's commented out by default).
shopt -s globstar 2>/dev/null || true
