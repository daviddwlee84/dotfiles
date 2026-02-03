# dotfiles

Make development environment for every machines

Currently, I use [`chezmoi`](https://www.chezmoi.io/) as the management tool.

## Getting Started

### MacOS

```bash
brew install chezmoi age

chezmoi init git@github.com:daviddwlee84/dotfiles.git

```

### Ubuntu

---

## Alternatives

- Nix
- GNU Stow

## Todo

- oh-my-zsh
- NeoVim + LazyVim
- LazyGit, ...?
- Tmux / Zellij
- environment variables for API keys (encrypt)
- improve ~/.zshrc that check command first (if/exists guard)
- "tags" for different profile
- Compare different alternatives
- separate different function in different shell script (and source them in the rc file)

advanced

- Clash
- FRP
- ssh keys
- platform difference (cuda, mac)
- CLI tools?! -> run_once_*.sh
- Inside GFW then use different profile (sync proxy settings like for docker?!)

## Resources

- [nl-scripts/dev-bootstrap at main · daviddwlee84/nl-scripts](https://github.com/daviddwlee84/nl-scripts/tree/main/dev-bootstrap) - add `chezmoi` script
- [daviddwlee84/DevEnvPack: Bring my development environment everywhere. vim, tmux, bash, zsh, VSCode, docker, and so on.](https://github.com/daviddwlee84/DevEnvPack)

Examples

- [omerxx/dotfiles: My dotfiles synced from localhost and remote machines](https://github.com/omerxx/dotfiles)
- [logandonley/dotfiles](https://github.com/logandonley/dotfiles)
  - [The ultimate dotfiles setup](https://www.youtube.com/watch?v=-RkANM9FfTM): chezmoi + ansible
- [bartekspitza/dotfiles](https://github.com/bartekspitza/dotfiles)
  - [Solving the Dotfiles Problem (And Learning Bash)](https://www.youtube.com/watch?v=mSXOYhfDFYo)

```bash
docker run --rm -it ubuntu:latest bash
export GITHUB_USERNAME=logandonley
# NOTE: if you prefer to use the system package manager to install chezmoi, then don't use this script
apt update -y && apt install curl -y
sh -c "$(curl -fsLS get.chezmoi.io)" -- init --apply $GITHUB_USERNAME
# or wget
apt update -y && apt install wget -y
sh -c "$(wget -qO- https://get.chezmoi.io)" -- init --apply "$GITHUB_USERNAME"
```

---

- [Why I'm Ditching Nix Home Manager - And What I'm Using Instead](https://www.youtube.com/watch?v=U6reJVR3FfA) (from Nix to GNU Stow)
