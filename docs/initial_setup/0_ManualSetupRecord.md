# Manual Setup Record

> Record how I setup this project on a new machine (macOS) step by step.

Install Chezmoi

```bash
brew install chezmoi age
```

Get LazyVim as our first settings

- [LazyVim/LazyVim: Neovim config for the lazy](https://github.com/lazyvim/lazyvim/)

```
# Install Neovim
brew install neovim

# Install essential tools (ripgrep for search, fd for file finding, lazygit)
brew install ripgrep fd jesseduffield/lazygit/lazygit

# https://github.com/LazyVim/starter
git clone https://github.com/LazyVim/starter ~/.config/nvim
rm -rf ~/.config/nvim/.git
```

Initialize Chezmoi with pre-created dotfiles repo (initialized with README.md with some notes)

```bash
chezmoi init
chezmoi cd
git remote add origin git@github.com:$GITHUB_USERNAME/dotfiles.git
git pull origin main
# git branch --set-upstream-to=origin/main main
```

Add LazyVim configs

```bash
chezmoi add ~/.config/nvim
git add -A
git commit -m "Add initial nvim/lazyvim starter configs"
```

Add [`.chezmoiignore`](https://www.chezmoi.io/reference/special-files/chezmoiignore/)

```
EDITOR=nvim chezmoi edit
```

Add `.chezmoi.toml.tmpl` ([`.chezmoi.<format>.tmpl - chezmoi`](https://www.chezmoi.io/reference/special-files/chezmoi-format-tmpl/))

This will prompt user to setup when they call `chezmoi init`
And will update the `~/.config/chezmoi/chezmoi.toml` file accordingly.
