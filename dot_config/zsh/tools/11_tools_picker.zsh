# 11_tools_picker.zsh - Interactive CLI tools picker (fzf ZLE widget)
# Reads ~/.config/docs/tools/cli-tools.md for the tool list (deployed by chezmoi).
#
# Alt+T  →  open picker
#   Enter      paste invocation to shell buffer (you still press Enter to run)
#   Ctrl+E     execute the tool directly (good for TUI apps: btop, lazygit, etc.)
#   Ctrl+/     toggle preview panel (shows tldr or --help)
#
# The invocation for tools that need arguments has a trailing space,
# so pressing Enter pastes e.g. "rg " — cursor lands after the space,
# ready for you to type your arguments.

_TOOLS_DOC="${HOME}/.config/docs/tools/cli-tools.md"

# Bail silently if the data file hasn't been deployed yet or fzf is missing
[[ -f "$_TOOLS_DOC" ]] || return 0
command -v fzf &>/dev/null || return 0

# Parse the markdown tables into "INVOCATION<TAB>DESCRIPTION" lines.
# Tab separator preserves the trailing space in invocations like "rg ".
_tools_list() {
    awk -F'|' '/^[[:space:]]*\|[[:space:]]*`/ {
      inv=$3; sub(/^[[:space:]]*`/,"",inv); sub(/`[[:space:]]*$/,"",inv)
      desc=$4; sub(/^[[:space:]]*/,"",desc); sub(/[[:space:]]*$/,"",desc)
      printf "%s\t%s\n", inv, desc
    }' "$_TOOLS_DOC"
}

# ZLE widget: opens fzf picker, pastes selected invocation to the shell command line.
tools-picker() {
    {
        exec </dev/tty
        exec <&1

        local selected
        selected=$(
            _tools_list | fzf \
                --ansi \
                --border \
                --prompt ' tools  ' \
                --header 'Enter: paste  Ctrl+E: execute  Ctrl+/: preview' \
                --delimiter=$'\t' \
                --with-nth=1,2 \
                --preview 'tool=$(printf "%s" {1} | awk "{print \$1}" | sed "s/ *$//"); (command -v tldr >/dev/null 2>&1 && tldr "$tool" 2>/dev/null) || "$tool" --help 2>&1 | head -50' \
                --preview-window='right:55%:wrap:hidden' \
                --bind='ctrl-/:toggle-preview' \
                --bind='ctrl-e:execute(eval $(printf "%s" {1} | awk "{print \$1}"))+abort'
        )

        zle reset-prompt >/dev/null 2>&1 || true
        [[ -z "$selected" ]] && return

        # Extract the invocation (field 1 before the tab), preserving trailing space
        local invocation
        invocation=$(printf '%s' "$selected" | cut -f1)

        # Paste to shell command line buffer without executing
        LBUFFER="${LBUFFER}${invocation}"
        zle redisplay
    }
}

zle -N tools-picker

# Alt+T (mnemonic: Tools)
# Alt+S = sesh-sessions, Alt+C = fzf cd — Alt+T is free
bindkey -M emacs '\et' tools-picker
bindkey -M viins '\et' tools-picker
bindkey -M vicmd '\et' tools-picker
