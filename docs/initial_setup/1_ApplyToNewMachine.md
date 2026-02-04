# Apply To New Machine

> Apply settings to new machine (Ubuntu)

Install Apps etc.

Apply

```bash
chezmoi init git@github.com:$GITHUB_USERNAME/dotfiles.git

# If you use GitHub and your dotfiles repo is called dotfiles then this can be shortened to:
chezmoi init --apply $GITHUB_USERNAME

# --apply will directly apply to the host machine
```

Use Homebrew for every UNIX-based machine?!
<https://www.chezmoi.io/user-guide/use-scripts-to-perform-actions/>

Sync mac
<https://www.chezmoi.io/user-guide/machines/macos/>

```bash
# Ubuntu
# https://www.chezmoi.io/install/#__tabbed_5_5
sudo snap install chezmoi --classic
```
