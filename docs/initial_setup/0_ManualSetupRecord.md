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

chezmoi 當入口 + ansible 管系統依賴 + mise 管 node/bun + uv 管 python

- [Homebrew Bundle, brew bundle and Brewfile — Homebrew Documentation](https://docs.brew.sh/Brew-Bundle-and-Brewfile)
- [Brew Bundle Brewfile Tips](https://gist.github.com/ChristopherA/a579274536aab36ea9966f301ff14f3f)
- [How to keep your mac software updated easily (2026)](https://gist.github.com/arturmartins/f779720379e6bd97cac4bbe1dc202c8b#file-mac-upgrade-sh)

```bash
$ mas list
1435447041  DingTalk             (8.2.5)
6447957425  Immersive Translate  (1.25.3)
 409183694  Keynote              (14.5)
 539883307  LINE                 (9.14.0)
 441258766  Magnet               (3.0.7)
1480068668  Messenger            (520.0.0)
 409203825  Numbers              (14.5)
 409201541  Pages                (14.5)
6714467650  Perplexity           (2.251216.0)
1475387142  Tailscale            (1.92.3)
 747648890  Telegram             (12.4.1)
1176074088  Termius              (9.36.2)
 425424353  The Unarchiver       (4.3.9)
 836500024  WeChat               (4.1.5)
 310633997  WhatsApp             (26.2.74)
1295203466  Windows App          (11.1.4)
1247341465  同花顺                  (5.2.2)
```

Austin (python tools)

- [P403n1x87/austin: Python frame stack sampler for CPython](https://github.com/P403n1x87/austin)
- [P403n1x87/austin-tui: The top-like text-based user interface for Austin](https://github.com/P403n1x87/austin-tui?tab=readme-ov-file)

---

Code Agents UI

- [slopus/happy: Mobile and Web client for Codex and Claude Code, with realtime voice, encryption and fully featured](https://github.com/slopus/happy)
- [btriapitsyn/openchamber: Desktop and web interface for OpenCode AI agent](https://github.com/btriapitsyn/openchamber)
  - [Happy Coder for OpenCode : r/opencodeCLI](https://www.reddit.com/r/opencodeCLI/comments/1qho03o/happy_coder_for_opencode/)
  - [OpenCode Support · Issue #265 · slopus/happy](https://github.com/slopus/happy/issues/265)
- [happier-dev/happier: Mobile, Web & Desktop client for Codex, Claude Code, OpenCode, Kimi, Augment Code, Qwen, fully end-to-end encrypted](https://github.com/happier-dev/happier)
- [NeuralNomadsAI/CodeNomad: CodeNomad: The command center that puts AI coding on steroids.](https://github.com/NeuralNomadsAI/CodeNomad)

---

- [9001/copyparty: Portable file server with accelerated resumable uploads, dedup, WebDAV, SFTP, FTP, TFTP, zeroconf, media indexer, thumbnails++ all in one file](https://github.com/9001/copyparty)
  - [introducing copyparty, the FOSS file server](https://www.youtube.com/watch?v=15_-hgsX2V0)
- [cloudflare/cloudflared: Cloudflare Tunnel client](https://github.com/cloudflare/cloudflared)
