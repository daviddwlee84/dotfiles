# Add `cref` — a shell twin of the Neovim `@file:line` copy-reference

## Context

The Neovim keymaps in [`docs/neovim/copy-reference.md`](../../docs/neovim/copy-reference.md)
(impl: `dot_config/nvim/lua/config/keymaps.lua:24-116`) let you copy a
Cursor / Claude-Code-style file mention — `@path`, `@path:12`, `@path:12-40` — to
the clipboard, in three path flavors (git-root-relative, machine-absolute, and a
cwd/`~` fallback). That only works **inside the editor**. When working in the
shell (after `rg`/`grep`, or just eyeballing a path) there's no equivalent, so you
retype `@path:line` by hand to hand an agent an exact pointer.

This adds a **new shell command `cref`** ("copy ref") that produces the same
reference shapes from the shell and copies them to the clipboard. It complements
`abspath` (`dot_config/shell/58_abspath.sh`) rather than overloading it: `abspath`
stays the pipe-clean "print absolute paths" primitive; `cref` reuses it and adds
the `@` prefix, git-root-relative default, cwd flavor, and `:line` suffix.

Decisions (confirmed with user): **new command**, named **`cref`**, **copies to
the clipboard by default** (with a `--no-copy` opt-out).

## Reference shapes (must match the Neovim feature)

`ref = "@" + <path> + <suffix>` — exactly one `@`, directly concatenated.

**Path flavor:**
- **default → git-root-relative.** root = `git rev-parse --show-toplevel`.
  Path = file relative to root, **no `./` prefix**. If the file is outside the
  root (or not in a repo), fall back the way nvim's `:~:.` does: cwd-relative if
  under `$PWD`, else `~/…` if under `$HOME`, else the absolute path.
- **`-a` / `--absolute` → machine-absolute**, logical (no symlink resolution), to
  match nvim's `expand("%:p")`.
- **`-c` / `--cwd` → relative to `$PWD`** (may contain `../`).

**Suffix (line component):**
- none → bare `@path` (the `yf`/`yF` equivalent; also forced by `-L`/`--no-line`).
- single line → `:N`.
- range → `:A-B` with `A <= B`; collapse `:A-A` → `:A`.

## New file: `dot_config/shell/59_cref.sh`

Shared POSIX tier (slot `59` is free and sits next to `58_abspath.sh`). Sourced by
both shells; no `.tmpl` needed (pure POSIX `sh`, OS specifics delegated to
`x copy`). Mirror `abspath`'s structure: `_cref_usage` + `cref` with the same
`while/case` flag loop (`--` terminator, `-*` rejection → `return 2`), the same
`command -v python3` guard, and a single inline `python3 - … <<'PY'` heredoc that
does the path math and prints the final `@ref`.

**Flags / args:**

| Flag | Effect |
|---|---|
| `-a`, `--absolute` | machine-absolute path |
| `-c`, `--cwd` | path relative to `$PWD` |
| `-L`, `--no-line` | drop any line suffix → bare `@path` |
| `-n`, `--no-copy` | print only, don't touch the clipboard (`abspath` style) |
| `-h`, `--help` | usage to stdout |
| `--` | end of flags |

**Positional / input modes** (the shell's answer to "cursor line"):
- `cref FILE` → `@relpath`
- `cref FILE:12` / `cref FILE:12-40` → `@relpath:12` / `@relpath:12-40`
- `cref FILE:12:5` (ripgrep/grep `:col[:text]`) → column & trailing text stripped → `@relpath:12`
- `cref FILE 12` / `cref FILE 12 40` → line info as trailing positionals
- **stdin**: no FILE arg + stdin not a TTY → read the first line and parse it as a
  `FILE:LINE[:COL[:text]]` token. Enables `rg -n foo | head -1 | cref` and
  `… | fzf | cref`. (Bare `cref` with a TTY and no arg → usage, `return 2`.)

**Flow inside `cref`:**
1. Parse flags; collect FILE token (from positional or stdin) + optional line args.
2. `root=$(git rev-parse --show-toplevel 2>/dev/null)` (may be empty; house idiom
   from `dot_config/shell/24_herdr.sh:669`).
3. Hand `(file-token, flavor, root, base=$PWD, home=$HOME, no_line)` to the python
   heredoc, which: regex-splits the token into `file` + `a[-b]` (dropping any
   `:col[:text]`); absolutizes `file` against `$PWD` (reusing the same
   `os.path.join`+`normpath` logic as `abspath`); applies the flavor
   (`os.path.relpath` for git-root/cwd, with the `..`-escape → cwd/`~`/abs
   fallback chain for git-root); assembles the suffix with the `A==B` collapse;
   prints `@<path><suffix>`.
   - *Symlink note:* for the **git-root** flavor, compute the relative segment
     with `os.path.realpath` on **both** file and root so the two live in the same
     symlink space (git's toplevel is already resolved). This makes the relative
     form succeed even when you `cd` through a symlink — a deliberate, documented
     improvement over nvim's lexical `vim.fs.relpath`. `-a` stays logical.
4. Shell captures the `@ref`. Unless `--no-copy`: `printf '%s' "$ref" | x copy`
   (no trailing newline, so it pastes cleanly into an agent). Always `printf
   '%s\n' "$ref"` to **stdout** (pipe-clean, visible), and a `Copied @…` toast to
   **stderr** — matching `tpath` (`dot_config/shell/63_tmux_path.sh:44-47`) and
   nvim's `vim.notify("Copied " .. ref)`.

**Reuse (no new deps):**
- `x copy` (`dot_dotfiles/bin/executable_x`, `copy_backend()` cascade → OSC 52,
  SSH-safe) — the canonical clipboard sink. Never shell out to `pbcopy` directly.
- `python3 os.path.relpath` / `os.path.normpath` — same pattern as
  `58_abspath.sh:51-84`; BSD `realpath` lacks `--relative-to`, so python is the
  house tool for path math (also `dot_config/shell/96_ssh_setup.sh:115`).
- `git rev-parse --show-toplevel` — inline, per the repo idiom (no shared helper).
- No tab-completion needed: like `abspath` (a function, not an `executable_*`
  CLI), the first positional is a path, so the shells' default file completion
  applies. CLAUDE.md's heavy two-shell completion rule targets `executable_*`
  CLIs only.

## Docs to update (required mirrors)

- **`docs/shells/aliases.md`** — add a `cref` row in the **Shell Utilities** table,
  right after the `abspath` row (`:736`). Columns `Command | Type | Source File |
  Description`; escape `|` as `\|` (e.g. the `… \| x copy` note). This is the one
  mandatory mirror for a new shell function (CLAUDE.md cross-file rule).
- **`docs/neovim/copy-reference.md`** (+ its **`.zh-TW.md`** sibling) — add a short
  "Shell twin: `cref`" note cross-linking to the aliases row, since both produce
  the identical reference shape. Keep the bilingual pair in sync.
- No `mkdocs.yml` nav change (no new doc file). No CLAUDE.md change (not a new CLI
  or prompt key).

## Non-goals (keep scope tight)

- No fzf/`tv` file picker when run with no args (stdin covers the pipe case; a
  picker can be a later enhancement).
- No `executable_*` CLI, no custom completions, no `.tmpl` templating.
- Not changing `abspath` (only reusing its logic).

## Verification (end-to-end, both shells)

The source file is plain POSIX `sh`, so test it directly without a full apply:

```sh
# from the repo root
for sh in bash zsh; do
  $sh -c '
    . dot_config/shell/59_cref.sh
    cref dot_config/shell/58_abspath.sh:30-88   # -> @dot_config/shell/58_abspath.sh:30-88
    cref -a README.md                            # -> @/abs/…/README.md
    ( cd dot_config && cref -c shell/59_cref.sh )# -> @shell/59_cref.sh
    cref README.md:10:5                          # -> @README.md:10  (col stripped)
    printf "src/x.py:42:3:match\n" | cref        # -> @src/x.py:42   (stdin/rg format)
    cref README.md:10-10                          # -> @README.md:10  (collapse)
    cref -n --no-line README.md:99               # print only, bare @README.md
  '
done
```

- Confirm each shape matches the nvim output for the same file/lines.
- Clipboard round-trip: `cref README.md:10 && x paste` → `@README.md:10` (no
  trailing newline). Verify over SSH too (OSC 52 path).
- File outside the repo: `cref ~/somefile` from inside the repo → `@~/somefile`
  fallback; a path under `$PWD` but outside git → cwd-relative.
- `--no-copy` writes nothing to the clipboard (paste shows the prior value).
- After editing docs: `uv run mkdocs build --strict` — expect only the ~12
  pre-existing baseline warnings (see memory `mkdocs-strict-preexisting-warnings`),
  no new ones referencing `aliases.md` / `copy-reference.md`.
- `chezmoi diff` shows only the new `59_cref.sh` + doc edits; `chezmoi apply` then
  a fresh shell (or `cas`) makes `cref` available.
