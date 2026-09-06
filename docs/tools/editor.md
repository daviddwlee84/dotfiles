# Default editor and Micro

`preferredEditor` chooses the external editor independently of `enableVimMode`.
Both new and existing hosts default to `nvim`. The shell Vim toggle controls shell
navigation; it does not change this preference or Claude's own editor mode.

## Choose and switch

```text
editorcfg list
editorcfg use micro
editorcfg status
editorcfg doctor
editorcfg reset
```

Presets: `nvim`, `micro`, `vim`, `nano`, `code`, `cursor`.
Micro is installed with the baseline devtools. It is a non-modal terminal editor:
**Ctrl+S** saves, **Ctrl+Q** closes, **Ctrl+F** searches. See the
[upstream key reference](https://github.com/micro-editor/micro/blob/master/runtime/help/defaultkeys.md).
Selecting a preset does not install GUI software; `use` refuses unavailable programs.

The init answer renders `~/.config/dotfiles/editor-default`. `editorcfg use`
atomically writes one preset to `$XDG_CONFIG_HOME/dotfiles/editor-choice`
(default `~/.config/dotfiles/editor-choice`), which chezmoi ignores.
Local choice wins over init; `reset` deletes only that local choice.
Changing init while a local choice exists will not change the effective preference.
No full apply is needed to switch; the next managed editor invocation reads the file.
Malformed choice files produce an error, never shell evaluation.

## EDITOR, VISUAL and application overrides

Managed profiles set both variables to the executable name `dotfiles-editor`.
`VISUAL` conventionally means a full-screen editor, including nvim, not specifically
a GUI. Tools have different precedence, so identical defaults avoid surprises.
Git uses `GIT_EDITOR → core.editor → VISUAL → EDITOR`; interactive rebase also has
`GIT_SEQUENCE_EDITOR` / `sequence.editor`.
We preserve those overrides; doctor displays the effective Git editor and config origin.
See [Git's reference](https://git-scm.com/docs/git-var).

After the first apply, reload your shell profile and restart applications that
inherited the old `EDITOR=nvim`. Already-running apps that inherited
`dotfiles-editor` pick up subsequent `editorcfg use` changes without restarting.
Manual environment overrides can bypass editorcfg; status reports them.
Existing helpers that require one executable still require a wrapper for custom
command strings. Use `editorcfg use code` instead of putting `code --wait` into
`EDITOR` for those helpers.

Claude's **Ctrl+G** / **Ctrl+X Ctrl+E** opens its external editor. Save and close to
return the text. This does not remap Esc or Ctrl+C.
[Claude documentation](https://code.claude.com/docs/en/interactive-mode).
The managed Yazi text-file opener also follows editorcfg; directory editing has
a separate, explicitly named Neovim entry. Direct `nvim` / `v` commands stay Neovim.

## Availability, waiting and fallback

The launcher resolves an external executable on PATH at every invocation, excludes
shell-only aliases/functions, preserves cwd and file arguments, waits, and returns
the editor's exit code. Code/Cursor receive `--wait`; close the file tab when done.
[VS Code CLI](https://code.visualstudio.com/docs/configure/command-line).

If the preferred executable disappears, fallback is **micro → nano**.
Only nvim/vim preferences can additionally fall back to **nvim → vim → vi**;
duplicates are skipped. Non-modal users never silently enter Vim.
A fallback emits a message to stderr. If nothing is available, the launcher fails
with an installation hint. It never retries in another editor after the selected
program has started and failed or been cancelled.

GUI editors and Notepad are not automatic fallbacks. A found executable is not proof
that a GUI session, IME, clipboard or terminal handoff works. Doctor checks availability
without launching editors; verify those interactions on the target host. SSH/WSL
use the environment and files of the machine where the CLI runs.

## Neovim quick editing

Temporary-file detection covers `TMPDIR`, `TEMP`, `TMP`, Unix temp prefixes and
known scratch names. Windows paths compare with normalized slashes and case, using
directory boundaries. Quick-edit disables buffer diagnostics and autoformat, not
plugins or Vim keys. `NVIM_QUICK_EDIT=1` / `0` explicitly override detection.
For perceived latency, compare `nvim --clean` with the managed config on the same
Windows terminal before attributing the cause to Neovim or LazyVim.

## Local overrides and installation

Managed Television actions for privileged text files use `sudoedit` with
`SUDO_EDITOR`, so the editor keeps the invoking user's PATH, HOME and preference.
The audit-rules directory action first selects a `.rules` file with fzf.
Applications that run their own editor under sudo have separate environment rules;
avoid `sudo dotfiles-editor` for the user-level launcher.

Put personal exports in the untracked `~/.shellrc.adhoc` (or per-shell adhoc).
Use `dotcfg --set preferredEditor=micro --yes` to change the init default; a local
editorcfg choice still wins until reset.

macOS installs Micro via Homebrew; Debian via apt. Linux without root / RedHat use
a checksum-verified release in `~/.local/bin` if no Micro is found.
Apply is install-only. Upgrade Homebrew with `just upgrade-brew`, apt with your
normal targeted package upgrade, and the managed Linux release with
`just upgrade-micro` (also in upgrade-all). It never overwrites a package-managed
Micro; the release installer requires its own receipt and active PATH match.
