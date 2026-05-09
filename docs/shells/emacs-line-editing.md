# Emacs-style Line Editing — origin & must-know subset

> **For non-vim users**: this repo provides a chezmoi `enableVimMode`
> prompt (default `true`). Set it to `false` and your shells (zsh +
> bash) drop modal vi editing entirely — they behave exactly the way
> this guide describes (pure emacs keymap). See
> [`docs/this_repo/vim-mode.md`](../this_repo/vim-mode.md) for the
> opt-out flow.

(stub — sections filled in by subsequent edits)

## TL;DR

The "weird" `Ctrl+A` / `Ctrl+E` / `Ctrl+W` / `Ctrl+R` shortcuts you see
everywhere — bash, zsh, `psql`, `python` REPL, `node`, `sqlite3`,
many TUI input boxes, even macOS native text fields — are all
descendants of the **Emacs editor's keymap**, propagated via GNU
**Readline** (bash's line editor) and zsh's **ZLE** (Zsh Line Editor).

It's not a POSIX standard; it's a layered convention that stuck because
it was early, simple, modeless, and well-suited to single-line command
editing. You don't need to memorize the whole table — see
[Tier 1 below](#tier-1--must-memorize-8-keys) for the 8 that pay back
their learning cost on day one.

For the **practical lookup** of every binding active in this repo
(built-in, plugin, custom widget) press `Alt+/` in any zsh prompt — see
[Zsh Keybindings & the keys-picker widget](keybindings.md).

## Why every Unix shell shares the same shortcuts

The lineage looks like this:

```
Terminal (xterm / Ghostty / Alacritty / iTerm2 / …)
         ↓ raw keystrokes / escape sequences
Shell's line editor
         ├─ bash → GNU Readline (default keymap: emacs)
         ├─ zsh  → ZLE          (default keymap: emacs)
         └─ fish → fish's own line editor (emacs-flavored defaults)
         ↓ translates keys → "widgets" (named actions)
Widget (beginning-of-line, kill-line, yank, …)
```

The **default keymap is Emacs** in all three. You can switch to vi-mode
with one line ([§ Switching modes](#switching-modes)), but very few
people do — partly because most terminals' editing tasks are short
single-line commands where modeless beats modal, partly because the
Emacs keys are already burned into muscle memory after years of using
them in REPLs, `psql`, `sqlite3`, and the macOS Cocoa text system.

It is **not POSIX**. POSIX `sh` says nothing about line editing — it's
the optional `set -o emacs` / `set -o vi` extension in the bash spec,
and a separate `bindkey` system in zsh. Why it's near-universal is
historical:

1. Early Unix shells had **no** line editing — you typed, hit Enter,
   couldn't fix typos.
2. Bill Joy's **vi** (1976) and Stallman's **Emacs** (1976) both shipped
   with their own keymap conventions for in-buffer editing.
3. Readline was extracted from the bash project in the 1980s as a
   reusable library; its author chose Emacs bindings as the default
   because Stallman's keymap was already documented and "modeless"
   (no `Esc` dance) — friendlier to novices.
4. Every CLI tool that wanted history + line editing started linking
   against Readline (or its BSD sibling `editline` / `libedit`) — psql,
   python, sqlite3, node, irb, gdb, lldb, mysql, …
5. zsh's ZLE was written from scratch but kept Readline-compatible
   keybindings on purpose (the `emacs` keymap), so users wouldn't have
   to relearn anything when switching shells.

So the convention isn't "Emacs is more popular" — it's "Readline got
there first and everything plugs into Readline". Even macOS's native
text fields support a subset (`Ctrl+A`, `Ctrl+E`, `Ctrl+K`, `Ctrl+Y`,
`Ctrl+P`, `Ctrl+N`) because Cocoa's text system was inspired by the
same convention.

## The 3-tier breakdown

Don't try to memorize 40 shortcuts. The bindings split cleanly into
**must-know / nice-to-know / look-up-when-needed**.

### Tier 1 — must memorize (8 keys)

These pay back their cost on day one. Real high-frequency.

| Key | Action | Mnemonic |
|-----|--------|----------|
| `Ctrl+A` | Beginning of line | **A**head / start |
| `Ctrl+E` | **E**nd of line | — |
| `Ctrl+U` | Kill to start of line | "U-turn" back |
| `Ctrl+K` | **K**ill to end of line | — |
| `Ctrl+W` | Kill previous **w**ord | — |
| `Ctrl+R` | **R**everse history search (fzf in this repo) | — |
| `Ctrl+L` | Clear screen (keeps current command) | **L**ight refresh |
| `Ctrl+X Ctrl+E` | Open current command in `$EDITOR` | "Edit" |

If you only ever learn these 8, you've covered ~90% of the daily wins.

### Tier 2 — nice to know

Worth a second pass once Tier 1 is muscle memory.

| Key | Action |
|-----|--------|
| `Alt+B` | Move back one **w**ord (Alt = "word-wise") |
| `Alt+F` | Move **f**orward one word |
| `Alt+D` | Kill next word (forward `Ctrl+W`) |
| `Alt+.` | Insert **last argument** of previous command |
| `Ctrl+Y` | **Y**ank (paste) last killed text |
| `Ctrl+T` | Transpose two characters (fix typo: `teh` → `the`) |
| `Ctrl+_` | Undo |
| `Ctrl+P` / `Ctrl+N` | Previous / next history entry (= ↑/↓) |

`Alt+.` alone replaces 80% of "I need the last arg again" cases —
e.g. `mkdir foo/bar/` then `cd <Alt+.>`.

### Tier 3 — look up when needed

Don't memorize. Use `Alt+/` (the [keys-picker](keybindings.md)) or
`bindings` (CLI) to grep when you need them.

| Key | Action |
|-----|--------|
| `Ctrl+X Ctrl+U` | Undo (alternate) |
| `Ctrl+X Ctrl+X` | Swap cursor and mark |
| `Ctrl+X Ctrl+R` | Re-read inputrc |
| `Alt+T` | Transpose two **w**ords |
| `Alt+U` / `Alt+L` | Upper/lower-case next word |
| `Alt+C` | Capitalize next word |
| `Alt+\\` | Delete surrounding whitespace |
| `Ctrl+V` | Verbatim insert (e.g. literal `Ctrl+J`) |

## Home / End vs Ctrl+A / Ctrl+E

On most modern keyboards `Home` and `End` work fine in bash/zsh and do
the same thing as `Ctrl+A` / `Ctrl+E`. So why bother with the Ctrl
versions?

1. **They work everywhere.** `psql`, `python`, `node`, `sqlite3`,
   `irb`, `gdb`, `lldb`, ssh-into-a-busybox-container, tmux copy-mode,
   macOS Cocoa text fields — all support `Ctrl+A`/`E` because they all
   embed Readline (or a Readline-compatible editor). `Home`/`End` need
   the terminal → app → library chain to agree on the escape sequence,
   which fails surprisingly often (tmux without `xterm-keys`, screen,
   serial consoles, recovery shells, …).
2. **Hands stay on home row.** No reach to the navigation cluster.
3. **They compose.** `Ctrl+A Ctrl+K` = "select all, cut" in one motion.
   `Home Shift+End Delete` is three keys and needs a selection model
   the shell doesn't have.
4. **SSH-friendly.** Over flaky links, single-byte `Ctrl` codes
   round-trip more reliably than multi-byte `\e[H` / `\e[F` sequences.

Same logic for `Ctrl+P` / `Ctrl+N` over `↑` / `↓` — the arrows are
multi-byte escape sequences that some environments mangle.

## Why not vi mode by default?

zsh and bash both ship `set -o vi` / `bindkey -v`. It exists, it works,
and a vocal minority swears by it. So why is `emacs` the default
everywhere?

1. **Modeless.** Single-line command editing is short. The cost of
   "am I in insert or normal mode?" plus an `Esc` round-trip per edit
   outweighs the benefit of vi's verb+motion grammar, which shines on
   multi-line buffers, not 60-char commands.
2. **Discoverability.** New users can fumble `Ctrl+A` and see something
   useful happen. `dd` in insert mode just types "dd".
3. **Historical inertia.** Readline picked emacs in the 80s; everything
   downstream inherited it.
4. **REPL ergonomics.** `python`, `node`, `psql`, etc. all ship the
   emacs keymap by default. Switching shells to vi-mode means living in
   a split-brain world.

That said — if you live in Vim and want vi-mode in zsh, this repo uses
[`zsh-vi-mode`](https://github.com/jeffreytse/zsh-vi-mode) which is far
better than the built-in `bindkey -v` (visual mode, surround, yank to
system clipboard, mode indicator). See
[`docs/shells/zsh.md`](zsh.md) for the setup. The trade-off: every new
emacs-style binding must be re-applied inside `zvm_after_init` because
zsh-vi-mode wipes the keymap on init — see the `Alt+/` rebind in
[`dot_zshrc.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_zshrc.tmpl)
for the pattern.

## Kill-ring vs system clipboard

`Ctrl+K`, `Ctrl+U`, `Ctrl+W`, `Alt+D` all "kill" text — and `Ctrl+Y`
"yanks" it back. This is **not** the system clipboard. It's an
in-process **kill-ring** (a stack of recently killed text), inherited
from Emacs.

Implications:

- Killed text does NOT go to `pbpaste` / `xclip` / `wl-paste`. You
  can't paste it into a browser.
- `Ctrl+Y` then `Alt+Y` (in some shells) cycles through older
  kill-ring entries.
- `Ctrl+W` (kill word) + `Ctrl+Y` is a fast "duplicate the last word"
  pattern — kill it, yank it back, yank it again.

If you want killed text on the system clipboard, you need a wrapper
widget. zsh-vi-mode already does this for vi-mode `y` / `d` operations
when configured; for emacs-mode this repo doesn't bridge it (left as a
[future TODO](https://github.com/daviddwlee84/dotfiles/blob/main/TODO.md)).

## For Vim users — the `Ctrl+X Ctrl+E` escape hatch

The single most useful binding for vim users stuck in an emacs-keymap
shell:

```
Ctrl+X Ctrl+E
```

Opens the **current command line** in `$EDITOR` (set to `nvim` in this
repo). Edit it as a normal file — multi-line, syntax-highlighted, full
vim motions, LSP if you've configured it. Save+quit, and the edited
buffer is executed as the next command.

Use it for:

- Long `ffmpeg` / `awk` / `jq` one-liners that need to be 5 lines.
- Pasting a multi-line snippet from somewhere and editing it before
  running.
- Composing a complex `git commit -m "$(cat <<EOF ...`.
- Editing a `for` loop that you mistyped 3 levels deep.

Set `EDITOR=nvim` in your env (this repo does, see
[`dot_config/shell/00_env.sh`](https://github.com/daviddwlee84/dotfiles/tree/main/dot_config/shell)).
With that one binding, you stop fighting the emacs keymap for anything
non-trivial.

## Where this convention shows up beyond shells

Same keys, same expectations, courtesy of Readline / libedit / native
Cocoa support:

| Tool | Notes |
|------|-------|
| `psql`, `mysql`, `sqlite3` | Full Readline |
| `python` (system), `ipython` | Readline (system) / prompt_toolkit (ipython, emacs-keymap by default) |
| `node`, `irb`, `lua` | Readline / libedit |
| `gdb`, `lldb` | Readline / libedit |
| `ssh` password prompt | Limited — `Ctrl+U` works |
| `tmux` command-prompt (`prefix + :`) | Emacs keys (settable to vi via `set -g status-keys vi`) |
| macOS native text fields | `Ctrl+A/E/K/Y/P/N/F/B/D/T` — Cocoa text system |
| Browser address bars (Chromium/Firefox on Linux+macOS) | Subset works |
| Slack/Discord input boxes | Subset works on macOS via Cocoa |

This is why learning the Tier 1 set is high-leverage — the muscle
memory transfers across dozens of tools you already use.

## Switching modes

Per-shell, in your rc file:

```sh
# bash
set -o emacs    # default
set -o vi

# zsh
bindkey -e      # emacs (default)
bindkey -v      # vi
```

Per-tool (Readline-based, in `~/.inputrc`):

```
set editing-mode emacs
# or
set editing-mode vi
```

Some tools (python's `prompt_toolkit`, ipython) have their own
`%config` switch — check tool-specific docs.

## Recommended mental model

1. **Learn Tier 1 (8 keys).** Two days of conscious use, then they're
   permanent.
2. **Set `EDITOR=nvim` and use `Ctrl+X Ctrl+E`** for anything longer
   than one line.
3. **Use `Alt+/`** ([keys-picker](keybindings.md)) when you sense
   "there's probably a binding for this" but can't remember it. Don't
   try to memorize the full table.
4. **Don't bother with vi-mode** unless you write multi-line shell
   blocks frequently AND already use vim daily. The split-brain cost
   (REPLs stay emacs) usually isn't worth it.

## Related

- [Zsh Keybindings & the keys-picker widget](keybindings.md) — every
  binding active in this repo, with the `Alt+/` picker and `bindings`
  CLI.
- [Zsh setup](zsh.md) — plugins (zsh-vi-mode, autosuggestions,
  syntax-highlighting) and load order.
- [Bash setup](bash.md) — ble.sh + oh-my-bash, why some zsh-only
  widgets don't have a bash port yet.
- GNU Readline manual:
  <https://tiswww.case.edu/php/chet/readline/rluserman.html>
- zsh ZLE manual: `man zshzle`
