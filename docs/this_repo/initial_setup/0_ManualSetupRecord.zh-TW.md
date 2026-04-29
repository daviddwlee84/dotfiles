# 手動設定紀錄

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

> 紀錄我如何在新機器 (macOS) 上一步一步設定這個專案。

安裝 Chezmoi

```bash
brew install chezmoi age
```

取得 LazyVim 作為我們的初始設定

- [LazyVim/LazyVim: Neovim config for the lazy](https://github.com/lazyvim/lazyvim/)

```
# 安裝 Neovim
brew install neovim

# 安裝必要工具（ripgrep 用於搜尋、fd 用於檔案查找、lazygit）
brew install ripgrep fd jesseduffield/lazygit/lazygit

# https://github.com/LazyVim/starter
git clone https://github.com/LazyVim/starter ~/.config/nvim
rm -rf ~/.config/nvim/.git
```

以預先建立的 dotfiles 倉庫（已用 README.md 與一些註記初始化）來初始化 Chezmoi

```bash
chezmoi init
chezmoi cd
git remote add origin git@github.com:$GITHUB_USERNAME/dotfiles.git
git pull origin main
# git branch --set-upstream-to=origin/main main
```

加入 LazyVim 設定

```bash
chezmoi add ~/.config/nvim
git add -A
git commit -m "Add initial nvim/lazyvim starter configs"
```

加入 [`.chezmoiignore`](https://www.chezmoi.io/reference/special-files/chezmoiignore/)

```
EDITOR=nvim chezmoi edit
```

加入 `.chezmoi.toml.tmpl`（[`.chezmoi.<format>.tmpl - chezmoi`](https://www.chezmoi.io/reference/special-files/chezmoi-format-tmpl/)）

這會在使用者呼叫 `chezmoi init` 時提示其進行設定，並會相應地更新 `~/.config/chezmoi/chezmoi.toml` 檔案。

（或我們也可以直接使用 `chezmoi edit-config`，不透過 chezmoi 互動式提示來更動設定）

---

（在設定 CLAUDE.md 之後我大多請它更新，所以請改去看 [`.specstory/history/`](../../../.specstory/history/)）

---

- [ohmyzsh/ohmyzsh: 🙃 A delightful community-driven (with 2,400+ contributors) framework for managing your zsh configuration. Includes 300+ optional plugins (rails, git, macOS, hub, docker, homebrew, node, php, python, etc), 140+ themes to spice up your morning, and an auto-update tool that makes it easy to keep up with the latest updates from the community.](https://github.com/ohmyzsh/ohmyzsh?tab=readme-ov-file#manual-installation)

oh-my-zsh 的安裝腳本 `sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"` 實際上做了超出我們需求的事。
其中安裝 zsh 與 chsh 的部分應由 Ansible 管理；`~/.oh-my-zsh/custom/` 與 `$ZSH_CUSTOM` 相關內容應由 chezmoi 管理（並放在不同位置，這樣我們可以正常 clone oh-my-zsh 倉庫）。

oh-my-zsh 實際上只是用範本初始化 `~/.zshrc` <https://github.com/ohmyzsh/ohmyzsh/blob/master/templates/zshrc.zsh-template>
我們最好讓它乾淨一點 <https://github.com/ohmyzsh/ohmyzsh/blob/master/templates/minimal.zshrc>

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
