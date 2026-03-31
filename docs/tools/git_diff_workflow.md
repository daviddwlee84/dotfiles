# Git Diff Workflow

This repo manages a small Git review stack instead of forcing a single tool to do everything:

- `delta` is the default pager for normal `git diff`, `git show`, and other CLI diff output.
- `diffnav` is a GitHub-style diff navigator with a file tree, useful when you want to move around larger patches quickly.
- `gh-dash` is the GitHub dashboard and review UI; its diff pager is configured to call `diffnav`.
- `lazygit` stays focused on repo operations inside LazyVim, with `delta` configured as its custom pager.

## Managed Config Files

This workflow is managed globally through these files:

- `~/.gitconfig` keeps `delta` as the default Git pager.
- `~/.config/gh-dash/config.yml` sets `pager.diff: "diffnav"`.
- `~/.config/lazygit/config.yml` uses LazyGit's current `git.pagers` syntax with `delta`.
- `~/.config/bat/themes/tokyonight_night.tmTheme` provides the shared Tokyo Night theme used by `bat` previews.

## Why Both `delta` and `diffnav`

`delta` is still the best default for everyday Git CLI output. It is fast, readable, and already fits `git diff` and LazyGit well.

`diffnav` solves a different problem: navigating large review diffs with a file tree and a GitHub-like layout. That makes it a better fit for `gh-dash` than replacing `delta` everywhere.

## `gh-dash` + `diffnav`

`gh-dash` is installed as a `gh` extension and reads the global config at `~/.config/gh-dash/config.yml`. This repo intentionally keeps that config minimal:

```yaml
pager:
  diff: "diffnav"
```

That gives `gh-dash` a better diff viewer without importing personalized sections, colors, or keybindings from other dotfiles.

Before using `gh-dash`, authenticate GitHub CLI once:

```bash
gh auth login
gh dash
```

## LazyGit + `delta`

LazyGit's current pager configuration uses `git.pagers`, not the older `git.paging` key:

```yaml
git:
  pagers:
    - colorArg: always
      pager: delta --dark --paging=never --syntax-theme base16-256 -s
```

This keeps LazyGit aligned with the existing `delta`-first CLI setup while avoiding the outdated config shape from the old issue thread.

## Fonts and Theme

Both `diffnav` and `gh-dash` look better with a Nerd Font because their interfaces rely on icon glyphs. This repo already manages Hack Nerd Font on desktop profiles.

The `bat` Tokyo Night warning is fixed by managing the upstream `tokyonight_night.tmTheme` file directly and rebuilding the bat theme cache after apply.

## References

- [diffnav](https://github.com/dlvhdr/diffnav)
- [gh-dash docs](https://www.gh-dash.dev/getting-started/)
- [LazyGit custom pagers](https://github.com/jesseduffield/lazygit/blob/master/docs/Custom_Pagers.md)
- [bat](https://github.com/sharkdp/bat)
