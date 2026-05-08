# 15_atuin.sh — atuin (https://atuin.sh) shared init for zsh + bash.
# Loaded by both shells via load_modular_dir; shell-specific bits dispatch
# on $ZSH_VERSION / $BASH_VERSION at source time.
#
# Decisions (see TODO.md "atuin zsh asymmetry" + docs/tools/atuin.md):
#   - macOS: brew installs to /opt/homebrew/bin (already on PATH).
#   - Linux: official installer (https://setup.atuin.sh) writes to
#     ~/.atuin/bin/atuin. Ansible role atuin runs the installer with
#     ATUIN_NO_MODIFY_PATH=1 so we own the PATH wiring here.
#   - zsh: Ctrl+R stays on fzf-history-widget (muscle memory). Atuin
#     binds to Alt+R via _atuin_search_widget. Up-arrow stays on OMZ
#     history-substring-search (no atuin rebind).
#   - bash: Ctrl+R = atuin (long-standing in dot_bashrc.tmpl); Alt+R
#     also = atuin for cross-shell consistency. Up-arrow disabled
#     because ble.sh owns it.
#   - Local-only by default. Sync requires manual `atuin login -u …`
#     (see docs/tools/atuin.md → Opt-in sync).

# --- PATH wiring (Linux installer location) ----------------------------------
[ -d "$HOME/.atuin/bin" ] && export PATH="$HOME/.atuin/bin:$PATH"

# --- Presence gate -----------------------------------------------------------
command -v atuin >/dev/null 2>&1 || return 0

# --- zsh init ----------------------------------------------------------------
# We do NOT bind Ctrl+R or Up-arrow on zsh (preserve fzf + OMZ widgets).
# zsh-vi-mode wipes bindkeys on init, so dot_zshrc.tmpl's zvm_after_init
# re-sources THIS file to re-apply the Alt+R bind.
if [ -n "$ZSH_VERSION" ]; then
    if eval "$(atuin init zsh --disable-up-arrow --disable-ctrl-r)" 2>/dev/null; then
        # _atuin_search_widget is registered by `atuin init zsh`.
        # Bind Alt+R (\er) to it across all keymaps that zsh-vi-mode uses.
        if (( ${+widgets[_atuin_search_widget]} )); then
            bindkey -M emacs '\er' _atuin_search_widget
            bindkey -M viins '\er' _atuin_search_widget
            bindkey -M vicmd '\er' _atuin_search_widget
        fi
    fi
    return 0
fi

# --- bash init ---------------------------------------------------------------
# Bash atuin init lives in dot_bashrc.tmpl (load order matters: ble.sh attach
# runs after this file, and atuin's init must register hooks BEFORE attach).
# Adding Alt+R via Readline `bind` here is safe — readline binds are additive
# and survive ble-attach.
#
# atuin's bash-preexec init registers __atuin_history (the search invocation).
# Map Alt+R (\er) to it. Ctrl+R stays bound by `atuin init bash` itself.
if [ -n "$BASH_VERSION" ]; then
    # Defer until atuin has been initialised by dot_bashrc.tmpl. The function
    # __atuin_history is defined by `atuin init bash`. If it's not yet defined
    # (e.g. this file is sourced before atuin init), retry via PROMPT_COMMAND.
    _atuin_bind_alt_r() {
        if declare -F __atuin_history >/dev/null 2>&1; then
            bind -x '"\er": __atuin_history' 2>/dev/null
            # One-shot: remove ourselves from PROMPT_COMMAND.
            PROMPT_COMMAND="${PROMPT_COMMAND//_atuin_bind_alt_r;/}"
            PROMPT_COMMAND="${PROMPT_COMMAND//;_atuin_bind_alt_r/}"
            PROMPT_COMMAND="${PROMPT_COMMAND//_atuin_bind_alt_r/}"
            unset -f _atuin_bind_alt_r
        fi
    }
    if declare -F __atuin_history >/dev/null 2>&1; then
        bind -x '"\er": __atuin_history' 2>/dev/null
        unset -f _atuin_bind_alt_r
    else
        case ";${PROMPT_COMMAND:-};" in
            *";_atuin_bind_alt_r;"*) : ;;
            *) PROMPT_COMMAND="_atuin_bind_alt_r${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
        esac
    fi
fi
