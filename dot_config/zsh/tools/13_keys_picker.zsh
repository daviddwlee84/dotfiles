# 13_keys_picker.zsh - Zsh keybindings cheatsheet (fzf ZLE widget)
#
# Data source: ~/.config/docs/shells/keybindings.md (deployed by chezmoi)
#
# Alt+/  →  open picker
#   Enter      paste "# <key> → <widget>: <desc>" comment to shell buffer
#              (does NOT execute; you can read it then press Enter or cancel)
#   Ctrl+E     trigger the widget directly (zle <widget-name>)
#              — only works for widgets registered in this zsh; built-in
#                widgets (e.g. `fzf-history-widget`) WILL trigger; ones
#                annotated like "(when ghost shown)" need their precondition
#   Ctrl+L     toggle to RAW BINDKEY view (escape hatch — `bindkey -M emacs`
#              full dump for power users / debugging missing widgets)
#   Ctrl+/     toggle preview panel (live `bindkey` lookup for the row)
#
# fzf is a hard dep; if missing, the file silently returns. The picker is
# still useful as a static viewer via `bindings` (defined in dot_config/shell/).

_KEYS_DOC="${HOME}/.config/docs/shells/keybindings.md"

[[ -f "$_KEYS_DOC" ]] || return 0
command -v fzf &>/dev/null || return 0

# Parse the markdown tables into "KEY<TAB>WIDGET<TAB>DESC" lines.
# Strict format: `| \`<key>\` | \`<widget>\`(or unquoted) | <desc> |`
# Group headings (### …) and the format-contract row are filtered out.
_keys_list() {
    awk -F'|' '
        # match rows that start with optional ws, pipe, ws, backtick
        /^[[:space:]]*\|[[:space:]]*`/ {
            key=$2; widget=$3; desc=$4
            # strip leading/trailing whitespace and surrounding backticks
            for (i in arr) delete arr[i]
            n = split("key widget desc", arr, " ")
            for (i = 1; i <= n; i++) {
                v = (arr[i] == "key") ? key : (arr[i] == "widget") ? widget : desc
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
                gsub(/^`|`$/, "", v)
                if (arr[i] == "key")    key = v
                if (arr[i] == "widget") widget = v
                if (arr[i] == "desc")   desc = v
            }
            # skip header rows ("Key", "-----")
            if (key == "Key" || key ~ /^-+$/) next
            # skip the format-contract example row
            if (key == "<KEY>") next
            printf "%s\t%s\t%s\n", key, widget, desc
        }
    ' "$_KEYS_DOC"
}

# Lookup a key string in `bindkey -M emacs` output. Translates the cheatsheet
# notation (Ctrl+R, Alt+T, Tab, →, End) into the keysym zsh's bindkey uses
# (^R, \er or \M-t, ^I, ^[[C, ^[[F).
_keys_translate() {
    local k="$1"
    case "$k" in
        Tab)        printf '^I' ;;
        Enter)      printf '^M' ;;
        Esc)        printf '^[' ;;
        →)          printf '\\e[C' ;;
        ←)          printf '\\e[D' ;;
        End)        printf '\\e[F' ;;
        Home)       printf '\\e[H' ;;
        Ctrl+\[A-Z]) printf '^%s' "${k#Ctrl+}" ;;
        Ctrl+*)     printf '^%s' "${k#Ctrl+}" ;;
        Alt+*)      printf '\\e%s' "${(L)k#Alt+}" ;;
        *)          printf '%s' "$k" ;;
    esac
}

# ZLE widget body
keys-picker() {
    emulate -L zsh

    # Preview command: try to look up the live bindkey for the row's key column.
    # Falls back to "(no live binding — view-only entry)".
    local preview_cmd
    preview_cmd='
        key={1}; widget={2}; desc={3}
        echo "Key:         $key"
        echo "Widget:      $widget"
        echo "Description: $desc"
        echo
        echo "── Live bindkey lookup ──"
        case "$key" in
            "Ctrl+"*)
                ksym=$(printf "^%s" "${key#Ctrl+}")
                bindkey -M emacs "$ksym" 2>/dev/null || echo "(not bound in emacs keymap)"
                ;;
            "Alt+"*)
                rest=${key#Alt+}; rest=$(printf "%s" "$rest" | tr "[:upper:]" "[:lower:]")
                ksym=$(printf "\\e%s" "$rest")
                bindkey -M emacs "$ksym" 2>/dev/null || echo "(not bound in emacs keymap)"
                ;;
            Tab)   bindkey -M emacs "^I" 2>/dev/null ;;
            "→")   bindkey -M emacs "^[[C" 2>/dev/null ;;
            End)   bindkey -M emacs "^[[F" 2>/dev/null ;;
            *)     echo "(no live lookup for key notation: $key)" ;;
        esac
        echo
        echo "── Source files (zsh widgets defined in this repo) ──"
        if [ -d "$HOME/.config/zsh" ]; then
            grep -rn "^${widget}()\\|zle -N ${widget}\\b" "$HOME/.config/zsh" 2>/dev/null | head -5
        fi
    '

    local selected
    selected=$(
        _keys_list | fzf \
            --ansi --border \
            --prompt ' keybindings  ' \
            --header 'Enter: paste comment  Ctrl+E: trigger widget  Ctrl+L: raw bindkey  Ctrl+/: preview' \
            --delimiter=$'\t' \
            --with-nth=1,2,3 \
            --preview "$preview_cmd" \
            --preview-window='right:55%:wrap:hidden' \
            --bind='ctrl-/:toggle-preview' \
            --bind='ctrl-l:reload(bindkey -M emacs)+change-prompt(  raw bindkey -M emacs   )+change-preview-window(hidden)+clear-query' \
            --expect='ctrl-e' \
            < /dev/tty
    )
    local key_pressed=${${(f)selected}[1]}
    local row=${${(f)selected}[2]}

    zle reset-prompt >/dev/null 2>&1 || true
    [[ -z "$row" ]] && return

    # If the user dropped into the raw-bindkey view, the row format is the
    # raw `bindkey` output: `"<keysym>" <widget>` — handle that gracefully
    # by just pasting it as a comment (no `widget` column to parse).
    if [[ "$row" != *$'\t'* ]]; then
        LBUFFER="${LBUFFER}# ${row}"
        zle redisplay
        return
    fi

    local key widget desc
    key=$(printf '%s' "$row" | cut -f1)
    widget=$(printf '%s' "$row" | cut -f2)
    desc=$(printf '%s' "$row" | cut -f3)

    if [[ "$key_pressed" == "ctrl-e" ]]; then
        # Try to invoke the widget directly. Built-in widgets and our custom
        # zle -N ones both work; widgets with non-identifier names won't.
        if (( ${+widgets[$widget]} )); then
            zle "$widget"
        else
            LBUFFER="${LBUFFER}# (widget '${widget}' not registered in current zsh) ${key} → ${desc}"
            zle redisplay
        fi
        return
    fi

    # Default action: paste a shell comment so user can read & decide.
    LBUFFER="${LBUFFER}# ${key} → ${widget}: ${desc}"
    zle redisplay
}

zle -N keys-picker

# Alt+/ — `/` mnemonic for "search"; works on all keyboard layouts without
# Shift. Also rebound from `zvm_after_init` in dot_zshrc.tmpl to survive
# zsh-vi-mode's keybind wipe.
bindkey -M emacs '\e/' keys-picker
bindkey -M viins '\e/' keys-picker
bindkey -M vicmd '\e/' keys-picker
