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

(or we can just use `chezmoi edit-config` to change the config without using chezmoi interactive prompts)

---

(After setup CLAUDE.md I mostly ask it to update, so please checkout [`.specstory/history/`](../../.specstory/history/) instead)

---

- [ohmyzsh/ohmyzsh: 🙃 A delightful community-driven (with 2,400+ contributors) framework for managing your zsh configuration. Includes 300+ optional plugins (rails, git, macOS, hub, docker, homebrew, node, php, python, etc), 140+ themes to spice up your morning, and an auto-update tool that makes it easy to keep up with the latest updates from the community.](https://github.com/ohmyzsh/ohmyzsh?tab=readme-ov-file#manual-installation)

The oh-my-zsh setup script `sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"` actually do more than what we need
That install zsh & chsh stuff should be manage by Ansible; ~/.oh-my-zsh/custom/ $ZSH_CUSTOM stuff should be managed by chezmoi (and put in different place so we can clone oh-my-zsh repo normally)

oh-my-zsh actually just initialize ~/.zshrc by the templates <https://github.com/ohmyzsh/ohmyzsh/blob/master/templates/zshrc.zsh-template>
We better make it clean <https://github.com/ohmyzsh/ohmyzsh/blob/master/templates/minimal.zshrc>

- [Use alt-f and alt-b to jump forward and backward in command line on macOS](https://gist.github.com/windsting/d21a07b236acf243c8ebbfe7302765ef)
- [macOS: alt/option key as meta · Issue #7966 · alacritty/alacritty](https://github.com/alacritty/alacritty/issues/7966)

- [交互模式 - Claude Code Docs](https://code.claude.com/docs/zh-CN/interactive-mode)
- [优化您的终端设置 - Claude Code Docs](https://code.claude.com/docs/zh-CN/terminal-config)
