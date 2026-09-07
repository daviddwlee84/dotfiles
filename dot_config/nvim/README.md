# 💤 LazyVim

A starter template for [LazyVim](https://github.com/LazyVim/LazyVim).
Refer to the [documentation](https://lazyvim.github.io/installation) to get started.

## Prettier installation and selection

`lua/plugins/mason.lua` adds Prettier to LazyVim's Mason `ensure_installed` list.
When Neovim loads Mason, it installs Prettier if missing, without upgrading an
existing installation. This supplies a shared formatter for standalone Markdown
files and projects without their own copy.

Conform searches upwards from the file for `node_modules/.bin/prettier` first,
then searches Neovim's `PATH`. Mason prepends its `bin` directory to that PATH,
so its copy normally takes precedence over an npm-global copy. Use `:ConformInfo`
in the relevant buffer to inspect the selected executable. If Prettier is
unavailable, Conform skips it; the other configured tools have their own
conditions and do not provide equivalent Prettier formatting. LSP fallback
requires an attached server that supports formatting.

Project-local, Mason, and npm-global installations run the same Prettier tool.
Output depends on the version, configuration, and plugins, not the installation
location alone. For shared projects, use `npm install --save-dev --save-exact prettier`
and commit the dependency and lockfile so the editor and CI use the same version.
See the [Prettier installation guide](https://prettier.io/docs/install).

For a manual Mason install or retry, run `:MasonInstall prettier`. To upgrade its
copy explicitly, run `:MasonUpdate`, wait for the registry update, then run
`:MasonInstall prettier`. `:MasonUpdate` alone refreshes the registry, not installed
tools; `just upgrade-plugins` updates Neovim plugins, not Mason's tool versions.

## Markdown: final newline versus an empty last line

Keep Markdown format-on-save enabled with the standard final newline. A newline
terminates the last line; it does not create an additional empty buffer line in
Neovim.

| File contents (`\n` means a newline) | What Neovim shows |
| --- | --- |
| `text` | One line, without a final newline |
| `text\n` | One line, with a final newline |
| `text\n\n` | Two lines: `text` followed by an empty line |

The `~` markers below the buffer indicate space beyond the file, not empty lines
in the file. Ending with `text\n` is already enough for appending `next\n` to
produce a Git diff containing only `+next`, without changing the previous line
or showing `No newline at end of file`.

The configured LazyVim Markdown formatter chain includes `prettier`,
`markdownlint-cli2`, and `markdown-toc`. Use `:ConformInfo` in a Markdown buffer to
check which formatters are available; a configured name does not mean its CLI
is installed, and the latter two formatters run only when their conditions are
met. When available, Prettier removes extra empty lines at EOF and keeps a single
final newline. This matches this repository's pre-commit `end-of-file-fixer`
hook. No custom formatter is needed for clean appended-line diffs. See
[Prettier's empty-line behavior](https://prettier.io/docs/rationale.html#empty-lines).

The separate `trailing-whitespace` hook uses
`args: [--markdown-linebreak-ext=md]`. It preserves two trailing spaces on
nonblank Markdown lines for hard line breaks; it does not preserve extra empty
lines at EOF. See the [hook documentation](https://github.com/pre-commit/pre-commit-hooks#trailing-whitespace).

Inspect the current buffer's options with:

```vim
:setlocal endofline? fixendofline?
```

`endofline` records whether the file had a final newline when read. With the
default `fixendofline` enabled in ordinary nonbinary buffers, Neovim restores a
missing final newline when writing, even if the option still says `noendofline`.
Reload the saved file to check its updated value. Neither option requests an
extra empty line; see `:help 'endofline'` and `:help 'fixendofline'`.

Conform versions that convert output using the original `endofline` flag can
retain an extra empty line when Prettier adds a newline to a `noendofline` file.
For that case, run `:setlocal endofline` before formatting/saving again. Files
already ending in a newline do not need this. See the
[tested version and workaround](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/nvim-format-adds-empty-last-line.md).
