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
- `~/.config/lazygit/config.yml` uses LazyGit's current `git.diffRenderers` syntax with `delta`, sets `os.copyToClipboardCmd` so `Ctrl+O` copies through the `x` wrapper (local `wl-copy`/`xclip`, OSC 52 over SSH — see [clipboard.md](clipboard.md)), and provides the read-only `I` local/remote-main containment report described in [lazygit](lazygit.md).
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

Since v0.64, LazyGit's diff renderer configuration uses `git.diffRenderers`
and `command`. The former `git.pagers` and `pager` fields trigger an automatic
migration that rewrites the config file on startup:

```yaml
git:
  diffRenderers:
    - colorArg: always
      command: delta --dark --paging=never --syntax-theme base16-256 -s
```

The `lazyvim_deps` role enforces LazyGit >= 0.64.0. It upgrades an old
Homebrew-managed formula directly, then falls back to the checksum-verified
official release when another install or PATH shadow still exposes an older
binary. This is a narrow minimum-version repair, not a general upgrade policy.

This keeps LazyGit aligned with the existing `delta`-first CLI setup while
preventing migration drift against the chezmoi-managed file.

## Fonts and Theme

Both `diffnav` and `gh-dash` look better with a Nerd Font because their interfaces rely on icon glyphs. This repo already manages Hack Nerd Font on desktop profiles.

The `bat` Tokyo Night warning (`[bat warning]: Unknown theme 'tokyonight_night', using default.`, printed on every `delta` render) is fixed by managing the upstream `tokyonight_night.tmTheme` file directly and compiling it into bat's cache after apply.

bat never reads `.tmTheme` at runtime — only the bincode cache under `~/.cache/bat`, which `bat cache --build` writes. That cache lives outside chezmoi's control, so `.chezmoiscripts/global/run_after_25_bat_theme.sh.tmpl` re-checks it on **every** apply (cache present? written by the current bat version? newer than the theme source?) and rebuilds only when stale. `dot_config/shell/25_bat.sh` correspondingly exports `BAT_THEME` only when the compiled cache exists, so a host without one falls back to bat's default silently instead of warning on every line. See [`pitfalls/bat-theme-cache-cleared-never-rebuilt.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/bat-theme-cache-cleared-never-rebuilt.md).

## References

- [diffnav](https://github.com/dlvhdr/diffnav)
- [gh-dash docs](https://www.gh-dash.dev/getting-started/)
- [LazyGit custom diff renderers](https://github.com/jesseduffield/lazygit/blob/master/docs/Custom_DiffRenderers.md)
- [bat](https://github.com/sharkdp/bat)
