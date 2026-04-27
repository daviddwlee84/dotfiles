# Custom ZLE widget's POSTDISPLAY gets silently cleared after widget exits (zsh-autosuggestions wraps everything)

**Symptoms** (grep this section):
- Custom ZLE widget calls `POSTDISPLAY="..."`, `region_highlight+=(...)`, then `zle -R` and exits — but ghost text never appears on screen
- Widget completes successfully (no errors, agent returns the right output, sanitize passes through)
- Adding `add-zle-hook-widget line-pre-redraw <hook>` to inspect state shows POSTDISPLAY is `[]` by the time the hook fires, despite the widget setting it just microseconds earlier:
  ```
  show_ghost: POSTDISPLAY=[  ⇥  command df -h] start=23 end=41 rh_count=1
  widget: rendered ghost, activated
  pre_redraw: BUFFER=[show current disk space] snap=[show current disk space] POSTDISPLAY=[]
  ```
- Calling `_zsh_autosuggest_disable` from the widget's activate handler does NOT fix it — and may make things worse, because `_zsh_autosuggest_disable` itself calls `_zsh_autosuggest_clear` which sets `POSTDISPLAY=`
- Re-asserting POSTDISPLAY from a `line-pre-redraw` hook DOES make ghost text visible, but feels like fighting symptoms rather than the cause
- Affects ANY widget name that doesn't start with `_` or `.` or `autosuggest-`

**First seen**: 2026-04-27 while implementing `dot_config/zsh/tools/05_aisuggest.zsh` (NL→shell ghost-text widget bound to Alt+;) on macOS 26.2 with the `zsh-autosuggestions` OMZ plugin loaded.
**Affects**: any custom ZLE widget that writes to `POSTDISPLAY` *and* doesn't follow the underscore-prefixed convention, on a setup with `zsh-autosuggestions` loaded.
**Status**: fixed in `dot_config/zsh/tools/05_aisuggest.zsh` (added widget names to `ZSH_AUTOSUGGEST_IGNORE_WIDGETS` at file source time).

## Symptom

We added a custom ZLE widget `aisuggest` that:
1. Reads `BUFFER` (user's natural-language description)
2. Calls a coding-agent CLI in the background with a spinner
3. On reply: sets `POSTDISPLAY="  ⇥  <suggested command>"` and a `region_highlight` entry styling it as `fg=8`
4. Calls `_aisuggest_activate` to swap-bind Tab and right-arrow to accept handlers
5. Returns

The user pressed Alt+;, saw the spinner animate, then saw … nothing. No ghost text, no error, no `zle -M` message. The buffer stayed exactly as typed.

Diagnostic logging at every state transition revealed:

```
[09:18:49] widget: rendered ghost, activated
[09:18:49] pre_redraw: BUFFER=[show current disk space] snap=[show current disk space] POSTDISPLAY=[]
```

POSTDISPLAY was empty by the time pre-redraw ran. Something between widget exit and the actual screen draw was clearing it.

We tried — and it failed — to "pause" `zsh-autosuggestions` while our suggestion was active by calling `_zsh_autosuggest_disable` in our activate handler. The user's log confirmed the disable ran (`autosuggest_paused=1`) but POSTDISPLAY was *still* empty at pre-redraw time. (Worse: `_zsh_autosuggest_disable` *itself* calls `_zsh_autosuggest_clear`, which sets `POSTDISPLAY=`. So calling disable from our activate path made the situation more confusing, not less.)

## Root cause

`zsh-autosuggestions` doesn't just wrap its own helper widgets. Its bind logic at `~/.oh-my-zsh/custom/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh:195-223` walks **every ZLE widget** that doesn't match its ignore patterns and binds it as a "modify" widget by default. The relevant lines:

```zsh
ignore_widgets=(
    .\*
    _\*
    ${_ZSH_AUTOSUGGEST_BUILTIN_ACTIONS/#/autosuggest-}
    $ZSH_AUTOSUGGEST_ORIGINAL_WIDGET_PREFIX\*
    $ZSH_AUTOSUGGEST_IGNORE_WIDGETS
)

for widget in ${${(f)"$(builtin zle -la)"}:#${(j:|:)~ignore_widgets}}; do
    …
    else
        # Assume any unspecified widget might modify the buffer
        _zsh_autosuggest_bind_widget $widget modify
    fi
done
```

The wrapper `_zsh_autosuggest_modify` (`~/.oh-my-zsh/custom/plugins/zsh-autosuggestions/src/widgets.zsh:39-80`) does this around every wrapped invocation:

```zsh
_zsh_autosuggest_modify() {
    local orig_buffer="$BUFFER"
    local orig_postdisplay="$POSTDISPLAY"   # ← saves (empty before our widget)
    POSTDISPLAY=                            # ← clears
    _zsh_autosuggest_invoke_original_widget $@   # ← runs OUR widget; we set POSTDISPLAY here

    # Don't fetch a new suggestion if there's more input to be read immediately
    if (( $PENDING > 0 || $KEYS_QUEUED_COUNT > 0 )); then
        POSTDISPLAY="$orig_postdisplay"     # ← restores empty value, CLOBBERING ours
        return $retval
    fi

    # Optimize if manually typing in the suggestion or if buffer hasn't changed
    if [[ "$BUFFER" = "$orig_buffer"* && "$orig_postdisplay" = "${BUFFER:$#orig_buffer}"* ]]; then
        POSTDISPLAY="${orig_postdisplay:$(($#BUFFER - $#orig_buffer))}"  # ← also clobbers
        return $retval
    fi
    …
}
```

Because our `aisuggest` widget doesn't modify `BUFFER` (it only sets `POSTDISPLAY`), the BUFFER-unchanged branch fires and POSTDISPLAY gets reset to the (empty) pre-widget value. Result: the user sees nothing.

The widget name `aisuggest` doesn't start with `_`, `.`, or `autosuggest-`, so it falls through to the "assume modify" default. **No warning, no opt-out by default — every contributor of a custom ZLE widget hits this same trap.**

## Fix

Add the widget(s) to `ZSH_AUTOSUGGEST_IGNORE_WIDGETS` at file source time, BEFORE the next prompt:

```zsh
typeset -ga ZSH_AUTOSUGGEST_IGNORE_WIDGETS
ZSH_AUTOSUGGEST_IGNORE_WIDGETS+=(aisuggest _aisuggest_accept_tab _aisuggest_accept_right _aisuggest_pre_redraw)
```

This works because zsh-autosuggestions' `_zsh_autosuggest_start` runs as a `precmd` hook and re-binds every prompt by default — it reads the ignore list fresh on each cycle, so appending after OMZ's plugin load takes effect on the next prompt without needing a full shell restart.

After the fix, the diagnostic log shows:
```
show_ghost: POSTDISPLAY=[  ⇥  command df -h] start=23 end=41 rh_count=1
activate: orig_tab=[fzf-completion] orig_right=[vi-forward-char]
widget: rendered ghost, activated
pre_redraw: BUFFER=[show current disk space] snap=[show current disk space] POSTDISPLAY=[  ⇥  command df -h]
```

POSTDISPLAY survives intact. Ghost text appears as expected. No re-assert needed.

## Why we don't use `_zsh_autosuggest_disable`

The pause-while-active idea sounds clean but is wrong:

1. `_zsh_autosuggest_disable` calls `_zsh_autosuggest_clear`, which actively sets `POSTDISPLAY=`. So invoking it from our activate handler clears the very POSTDISPLAY we just set.
2. It only stops the *fetch* of new suggestions; the wrapper machinery still runs around every widget invocation and still saves/restores POSTDISPLAY.
3. `ZSH_AUTOSUGGEST_IGNORE_WIDGETS` is the surgical fix — it removes our widget from the wrap loop entirely.

## Defense-in-depth

Even with the ignore-list fix, we keep a "POSTDISPLAY is empty but we have a suggestion → re-render" fallback in `_aisuggest_pre_redraw`. This catches the (unlikely) case where some other plugin not yet identified clobbers POSTDISPLAY. Cheap insurance, no downside.

## How to detect this trap on a future widget

Symptom: your custom widget sets `POSTDISPLAY` and exits, but nothing renders.

Quick test:
```sh
zle -lL <your-widget-name>
zle -lL azh:<your-widget-name>     # if this exists, autosuggestions wrapped you
```

Or inspect at runtime:
```sh
print -- "${ZSH_AUTOSUGGEST_IGNORE_WIDGETS[@]}"  # if your widget isn't here, it's wrapped
```

## References

- `~/.oh-my-zsh/custom/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh:195-223` — the bind loop that wraps every non-ignored widget
- `~/.oh-my-zsh/custom/plugins/zsh-autosuggestions/src/widgets.zsh:39-80` — `_zsh_autosuggest_modify` wrapper that saves/restores POSTDISPLAY
- `dot_config/zsh/tools/05_aisuggest.zsh` — our fix (the `ZSH_AUTOSUGGEST_IGNORE_WIDGETS+=(...)` line near the bottom)
- `docs/tools/zsh-inline-ai.md` → "Interaction with other plugins" section — design rationale
