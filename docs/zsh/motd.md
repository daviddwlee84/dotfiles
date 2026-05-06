# SSH login banner (MOTD)

A short login-shell hook that prints a big `figlet`-style hostname banner plus a one-line metadata row when you SSH into a managed host. Local terminals stay silent — the banner exists purely for **fleet identification**: when you `ssh` to one of ten boxes managed by [`just fleet-apply`](../this_repo/fleet-apply.md), the banner answers "which box am I on?" instantly.

Source: [`dot_zlogin.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_zlogin.tmpl) → `~/.zlogin`.

## What it looks like

```
   _   _      _    ___  _
  | | | |__ _| |__|__ \| |__
  | |_| / _` | '_ \ / // '_ \
   \___/\__,_|_.__//_(_)_.__/

profile=ubuntu_server  os=Linux 6.5.0-21-generic  up=4 days  via=192.168.1.42
```

(font: `figlet -f small`. Cyan banner, dim metadata row.)

## Trigger conditions

The banner fires only when **all four** gates pass:

| # | Gate | Why |
|---|------|-----|
| 1 | `[ -n "$SSH_CONNECTION" ]` | The core trigger — empty on console / local / `tmux new` |
| 2 | `[ -t 1 ]` | stdout must be a TTY → suppresses `ssh host 'cmd'`, `scp`, `rsync`, and the chezmoi `fleet-apply` SSH probes |
| 3 | `[ -z "$TMUX" ]` | Print once per SSH session, not per tmux pane |
| 4 | `[ "${MOTD_DISABLE:-0}" != "1" ]` | Taste-based runtime opt-out |

zsh sources `.zlogin` only for **login shells**. New tmux panes (default config) and non-interactive `zsh -c` invocations don't even reach the script — gate 2 + 3 are belt-and-suspenders against tmux configs that force login shells.

## Tools used

`figlet` is installed by the ansible `devtools` role (apt + brew). The companion utilities `toilet` (color/Unicode figlet superset) and `lolcat` (rainbow color filter) are installed too but **not used by the MOTD itself** — they're general-purpose user CLIs you can pipe to:

```sh
echo "deploy ok" | toilet -f mono12 --metal
fortune | cowsay | lolcat        # if you also install cowsay/fortune
```

The MOTD uses only ANSI escapes (cyan + dim) so it stays deterministic over flaky SSH and never depends on a separate color filter being installed.

## Opt out

Add to `~/.zshrc.adhoc` (auto-created by [`dot_zshrc.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_zshrc.tmpl)):

```sh
export MOTD_DISABLE=1
```

This survives `chezmoi apply` because `~/.zshrc.adhoc` is not chezmoi-managed.

## First boot (before figlet is installed)

Chezmoi deploys `~/.zlogin` before the ansible `devtools` role runs. If you SSH in during that window:

- `command -v figlet` returns false
- Falls back to plain `== <hostname> ==`
- Metadata line still prints

After ansible finishes, the next SSH login uses figlet.

## Customization

### Change the figlet font

Edit `~/.zlogin` (or the source `dot_zlogin.tmpl` if you want the change to roll through chezmoi to all your machines):

```sh
figlet -w "$_motd_cols" -f banner -- "$_motd_host"     # blocky banner font
figlet -w "$_motd_cols" -f slant -- "$_motd_host"      # italic slant
figlet -w "$_motd_cols" -f standard -- "$_motd_host"   # default (taller)
```

`figlet -f` followed by Tab in a shell with `figlet` installed lists all available fonts under `/usr/share/figlet/` (Linux) or `$(brew --prefix figlet)/share/figlet/fonts/` (macOS). The `small` default is chosen because it fits inside a ~24-row mobile SSH window without wrapping for hostnames up to ~20 chars.

### Show FQDN instead of short hostname

```sh
_motd_host="$(hostname -f 2>/dev/null || hostname)"
```

Caveat: long FQDNs may wrap even with `-f small`; consider `-f mini` if so.

### Skip the metadata row

Delete the second `printf` block (`profile=… os=… up=… via=…`).

### Use `toilet` for color gradients

`toilet` is a figlet superset with built-in gradients. Replace the figlet block with:

```sh
toilet -w "$_motd_cols" -f small --gay -- "$_motd_host"
```

Tradeoff: `--gay`/`--metal` palettes are pretty over a clean SSH session but can look mangled on terminals without 256-color support. The current ANSI-cyan default is more conservative.

## Why not `/etc/motd` or PAM `motd.dynamic`?

System MOTD lives in `/etc/motd` or `/etc/update-motd.d/*` and applies to **every** user. This banner is per-user, lives in the dotfiles repo, and respects user opt-out — no root needed, no impact on other accounts. Ubuntu's default MOTD news / advertisements remain a separate concern (silence them via `touch ~/.hushlogin` or `chmod -x /etc/update-motd.d/50-motd-news`).

## Related

- [`dot_zlogin.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_zlogin.tmpl) — the source template
- [`dot_ansible/roles/devtools/tasks/main.yml`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_ansible/roles/devtools/tasks/main.yml) — installs `figlet`, `toilet`, `lolcat`
- [`dot_zshrc.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_zshrc.tmpl) — auto-creates `~/.zshrc.adhoc` (where `MOTD_DISABLE=1` lives)
- [Fleet apply](../this_repo/fleet-apply.md) — the multi-host workflow this banner is most useful for
