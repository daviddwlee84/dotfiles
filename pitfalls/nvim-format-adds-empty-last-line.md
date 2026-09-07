# Markdown formatting adds an empty last line to a file without a final newline

**Symptoms**: Prettier formats the text, but saving leaves `text\n\n`; `:setlocal endofline?` reports `noendofline` even though `fixendofline` writes a final newline.
**First seen**: 2026-09
**Affects**: reproduced on macOS with Prettier 3.9.6 and Conform commit `c2526f1cde528a66e086ab1668e996d162c75f4f`; input originally lacks a final newline.
**Status**: workaround documented; no plugin patch or automatic buffer override.

## Symptom

Given the bytes `# Example\n\n* item` (no final newline), the real LazyVim
format-on-save path produces `# Example\n\n- item\n\n`. Running Prettier directly
produces `# Example\n\n- item\n` instead. Files already ending with a newline
format correctly, and redundant trailing empty lines are removed.

## Root cause

Conform's `runner.lua` stores `add_extra_newline = vim.bo[bufnr].eol` before
running the formatter. It removes the trailing empty element from the formatter's
split output only when that flag was true. For a file read as `noendofline`,
Prettier's added newline therefore becomes an actual empty buffer line. Neovim's
`fixendofline` then writes another newline after it.

## Workaround

For the affected Markdown buffer, set the standard newline convention before
formatting/saving again:

```vim
:setlocal endofline
:write
```

The tested output is then `# Example\n\n- item\n`, with no extra empty buffer
line, and repeated saves are stable.

## Prevention

- Keep standard final newlines in tracked text files; `end-of-file-fixer` enforces this at commit time.
- Check the formatter's availability and selected path with `:ConformInfo` before attributing behavior to Prettier.
- When testing the actual LazyVim save path headlessly, trigger `UIEnter` and let `VeryLazy` finish first. This installed lazy.nvim defers that event until a UI attaches; without it, saving can bypass LazyVim formatting entirely. Assert that the format-on-save handler and formatter registration exist.

## Related

- [Neovim formatting documentation](../dot_config/nvim/README.md)
- [Conform output conversion at the tested revision](https://github.com/stevearc/conform.nvim/blob/c2526f1cde528a66e086ab1668e996d162c75f4f/lua/conform/runner.lua#L418)
