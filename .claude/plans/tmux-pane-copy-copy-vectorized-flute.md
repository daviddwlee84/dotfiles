# Plan: vim-idiomatic mouse copy in tmux copy-mode

## Context

Today, dragging the mouse in a **local** tmux pane copies immediately on release but
leaves you sitting in copy-mode (`copy-selection`), while a **remote** pane appears to
"visual-select then press `y`". The user prefers the latter feel everywhere and asked
whether a right-click "Copy" could exist without clashing with the pane context menu.

Root cause of the local≠remote difference (for the record, **not** a bug to fix):
`dot_config/tmux/keybindings.conf.tmpl:141` binds `MouseDragEnd1Pane → copy-selection`,
which only governs tmux's **own (outer) copy-mode** — engaged only for plain local
content. A remote pane running a mouse-aware app (typically a *nested tmux* or vim) sets
`mouse_any_flag`, so tmux's default `MouseDrag1Pane` **forwards** the drag to the remote
app instead of entering its own copy-mode. The select-then-`y` behavior on remote panes
is therefore the *remote* tmux's config, not this repo's.

Goal: make the **local/outer** copy-mode behave the vim way — drag highlights only, and an
explicit action (key `y`, right-click, or double-click) does the copy **and exits**
copy-mode (no "stuck in copy-mode, must hit `q`" experience).

## Changes — all in `dot_config/tmux/keybindings.conf.tmpl`

`$copyTable` (line 9-10) is `copy-mode-vi` when `enableVimMode` is on, `copy-mode` otherwise.
All edits use `$copyTable` so they stay correct under both flag states.

### 1. Drag = select-only (line 141)

```tmux
# before
bind -T {{ $copyTable }} MouseDragEnd1Pane send-keys -X copy-selection
# after
bind -T {{ $copyTable }} MouseDragEnd1Pane send-keys -X stop-selection
```

`stop-selection` keeps the highlight active without copying, so the existing
`y` binding (line 140, `copy-selection-and-cancel`) does the copy+exit.

### 2. Double-click = select word AND copy+exit (line 142)

```tmux
# before
bind -T {{ $copyTable }} DoubleClick1Pane select-pane \; send-keys -X select-word
# after
bind -T {{ $copyTable }} DoubleClick1Pane select-pane \; send-keys -X select-word \; send-keys -X copy-selection-and-cancel
```

### 3. Right-click on an active selection = copy+exit (wrap the `MouseDown3Pane` binding, lines 24-50)

Wrap the existing `if-shell` in one outer `if-shell` that fires **only when a selection
is present in copy-mode**; otherwise the current logic (forward `send -M`, or show the
pane menu) is preserved byte-for-byte:

```tmux
bind-key -n MouseDown3Pane \
  if-shell -F -t = "#{&&:#{?#{m/r:(copy|view)-mode,#{pane_mode}},1,0},#{selection_present}}" \
    { send-keys -X copy-selection-and-cancel } \
    { if-shell -F -t = "#{||:#{mouse_any_flag},#{&&:#{pane_in_mode},#{?#{m/r:(copy|view)-mode,#{pane_mode}},0,1}}}" \
        { select-pane -t = ; send-keys -M } \
        { display-menu -O -T "..." -t = -x M -y M \
            ...existing menu body unchanged... } }
```

Why no conflict (confirmed from the code): the pane context menu only appears when **not**
in copy-mode; a selection only exists **while in** copy-mode — mutually exclusive states.
Right-click in copy-mode *without* a selection still falls through to the existing branch
(shows the menu), so that behavior is unchanged.

**Menu-body duplication rule does NOT trigger here.** `dot_config/tmux/menu-pane.sh` (the
keyboard-equivalent `prefix + M-p`) mirrors only the **menu body**, which is untouched —
we add a wrapper around it, not inside it. No edit to `menu-pane.sh`.

### "No stuck in copy-mode" guarantee

Every *copy* path uses an `-and-cancel` variant → copies and exits:
- `y` (line 140) — already `copy-selection-and-cancel`
- double-click (line 142) — adds `copy-selection-and-cancel`
- right-click on selection — `copy-selection-and-cancel`

Only the bare drag-release is `stop-selection` (highlight, no copy) by design; exit it via
`y` / right-click / `Escape` / `q`.

## Docs to update (same commit — CLAUDE.md keybinding cross-file rule)

- `docs/tools/tmux/` — find the copy-mode / mouse section (grep for `MouseDragEnd1Pane`,
  `copy-selection`, `DoubleClick`) and update the described behavior: drag = select-only,
  `y`/right-click/double-click = copy+exit.
- `docs/shells/keybindings.md` — update if it documents tmux copy-mode mouse behavior.
- Refresh the inline help comment block at lines 131-135 if it implies drag auto-copies.
- No new alias/function, so no `docs/shells/aliases.md` row. `enableVimMode` catalog
  (`docs/this_repo/vim-mode.md`) already lists `keybindings.conf.tmpl`; no new file to add.

## Remote / SSH considerations (this config also runs on remote boxes)

This same config is deployed to remote machines, so the edits must give a good experience
when tmux is running **on the remote** and reached via an SSH terminal (directly, or as a
nested tmux under a local tmux).

- **Clipboard reaches the local machine, unchanged by this work.** The copy actions
  (`copy-selection-and-cancel`) honor `set-clipboard on` and emit **OSC 52**, which the
  repo already wires up: `common.conf.tmpl:155` (`set -g set-clipboard on`),
  `:163-165` (`terminal-features …:clipboard` for `xterm*`/`ghostty*`/`alacritty*`), and
  `allow-passthrough on` so OSC 52 propagates **up through an outer/local tmux** when this
  is the nested remote tmux. No new clipboard plumbing is needed — we reuse it.
- **`stop-selection` is internal-only** (no escape sequences) → fully transparent over SSH.
- **Mouse events** (drag / double-click / right-click) are reported by the *local* terminal
  to the remote tmux over the SSH tty; `mouse on` (`common.conf.tmpl:65`) already enables
  reporting. No change.
- **Pre-existing caveat (call out, do not fix here):** OSC 52 clipboard only works if the
  connecting terminal's `TERM` matches the `terminal-features` clipboard allowlist
  (`xterm*`/`ghostty*`/`alacritty*`). SSHing from a terminal advertising a different `TERM`
  (e.g. bare `screen`/`tmux-256color` with no clipboard feature) means the *copy still
  lands in the tmux paste buffer* (paste within tmux works) but won't reach the OS
  clipboard — same as today. Widening that allowlist is out of scope.

## Verification (Hard rule: validate config with the app, not just syntax)

1. Render and parse-check the template into a throwaway tmux server:
   ```bash
   chezmoi cat ~/.config/tmux/keybindings.conf > /tmp/kb.conf
   tmux -L cfgtest -f /dev/null start-server \; source-file /tmp/kb.conf \; kill-server
   ```
   (must exit 0 with no parse error from the nested `if-shell`/`display-menu` braces).
2. `chezmoi apply` on the local box, then `tmux source-file ~/.config/tmux/tmux.conf`
   (or `tmux kill-server` + reattach).
3. Manual smoke in a local pane:
   - drag-select → text highlights, nothing copied yet, still in copy-mode;
   - press `y` → clipboard has it (verify via paste / `tmux show-buffer`), back to normal mode;
   - re-select, **right-click** → copies + exits;
   - **double-click** a word → word copied + exits;
   - right-click with **no** selection (enter copy-mode via `prefix [`, no select) → pane
     menu still appears;
   - right-click in **normal** mode → pane menu appears (unchanged).
4. Confirm `enableVimMode=false` path still parses (bindings target `copy-mode` table).
5. **SSH/remote smoke:** `chezmoi apply` on a remote box, SSH in from a clipboard-capable
   terminal (ghostty/alacritty/xterm), repeat the drag→`y` / double-click / right-click
   tests in a remote pane, and confirm the text lands in the **local** OS clipboard
   (paste outside the terminal). Repeat once nested under a local tmux to confirm OSC 52
   passthrough still reaches the local clipboard.
6. `uv run mkdocs build --strict` if any `docs/**` file changed.
