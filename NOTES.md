# dotfiles

Make development environment for every machines

Currently, I use [`chezmoi`](https://www.chezmoi.io/) as the management tool.

## Getting Started

### MacOS

```bash
# TODO: eventually we don't these "manual" steps
brew install chezmoi age
uv tool install ansible-core    # Installs all ansible executables
ansible-galaxy collection install community.general  # For homebrew module

chezmoi init git@github.com:daviddwlee84/dotfiles.git

```

### Ubuntu

---

## Alternatives

- Nix
- GNU Stow

## Todo

- oh-my-zsh
- [x] NeoVim + LazyVim
- LazyGit, ...?
- Tmux / Zellij
- alacritty.toml
- environment variables for API keys (encrypt)
- improve ~/.zshrc that check command first (if/exists guard)
- "tags" for different profile
- Compare different alternatives
- separate different function in different shell script (and source them in the rc file)
- Install `just`
  - Use package manager for each platform [Packages - Just Programmer's Manual](https://just.systems/man/en/packages.html)
  - Maybe use the `https://just.systems/install.sh` installation script and set the target location to `~/.local/bin/just`?
  - If without "sudo" permission, can we install to user-space?!
- Pueue
  - Homebrew
  - linux (build from cargo / download binary + setup systemd service?)
- Mirror
  - Python
  - Ubuntu (docker)
    - [aosp-monthly | 镜像站使用帮助 | 清华大学开源软件镜像站 | Tsinghua Open Source Mirror](https://mirrors.tuna.tsinghua.edu.cn/help/aosp-monthly/) -> timeout, seems got banned?!
    - [Ubuntu - USTC Mirror Help](https://mirrors.ustc.edu.cn/help/ubuntu.html#__tabbed_1_1)

advanced

- Clash
- FRP
- ssh keys
- platform difference (cuda, mac)
- CLI tools?! -> run_once_*.sh
- Inside GFW then use different profile (sync proxy settings like for docker?!)
- Improve [`.ansible.cfg`](https://gist.github.com/wbcurry/f38bc6d8d1ee4a70ee2c)
- Agent Skills
  - Ansible
    - [sigridjineth/hello-ansible-skills: Ansible automation skills for Claude Code: playbook development, debugging, shell conversion, and interactive workflows.](https://github.com/sigridjineth/hello-ansible-skills)
- Coding Agents global config
  - Claude Code notification hook - [Hooks reference - Claude Code Docs](https://code.claude.com/docs/en/hooks#notification)
    - hooks for different matcher for notification?! (permission_prompt, idle_prompt, auth_success, elicitation_dialog)
- Install docker
  - with convenience script: `curl -fsSL https://get.docker.com -o get-docker.sh && sudo sh ./get-docker.sh --dry-run`
  - macOS maybe use OrbStack?!
  - setup for non-root user [Post-installation steps | Docker Docs](https://docs.docker.com/engine/install/linux-postinstall/)
  - use Ansible to maintain?!

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

```bash
# To test, you can run:
chezmoi state delete-bucket --bucket=scriptState  # Clear script state to re-run
chezmoi apply -v
```

```bash
# Test Claude Code notification hook
echo '{"hook_event_name":"Stop"}' | ~/.claude/hooks/notify.sh
echo '{"hook_event_name":"Notification","title":"Test Title","message":"Test message","notification_type":"info"}' | ~/.claude/hooks/notify.sh
```

---

- [Why I'm Ditching Nix Home Manager - And What I'm Using Instead](https://www.youtube.com/watch?v=U6reJVR3FfA) (from Nix to GNU Stow)

