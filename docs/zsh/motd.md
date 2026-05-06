# SSH login banner (MOTD)

A short login-shell hook that prints a hostname banner plus optional system info when you SSH into a managed host. Local terminals stay silent — the banner exists purely for **fleet identification**: when you `ssh` to one of ten boxes managed by [`just fleet-apply`](../this_repo/fleet-apply.md), the banner answers "which box am I on?" instantly.

Source: [`dot_zlogin.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_zlogin.tmpl) → `~/.zlogin`.

## Three styles, picked at `chezmoi init`

The chezmoi prompt `motdStyle` chooses which style this host uses. Default is `figlet`; switch via the prompt at init time, or override at runtime per machine via `MOTD_STYLE` in `~/.zshrc.adhoc`.

| Style | Lines | Latency | Contains | Fits in |
|-------|-------|---------|----------|---------|
| `figlet` (default) | ~6 | ~5 ms | figlet hostname + 1-line metadata (profile/OS/uptime/IP) | 24-row mobile SSH ✅ |
| `fastfetch-slim` | ~10–13 | ~80 ms | figlet hostname + fastfetch w/o logo (Title/OS/Kernel/Uptime/CPU/Memory/Disk) | half-screen tmux split ✅ |
| `fastfetch-full` | ~22+ | ~150 ms | full distro logo + every field fastfetch knows (GPU, packages, theme, displays, …) | full-screen desktop terminal |

### `figlet` style (default)

```
   _   _      _    ___  _
  | | | |__ _| |__|__ \| |__
  | |_| / _` | '_ \ / // '_ \
   \___/\__,_|_.__//_(_)_.__/

profile=ubuntu_server  os=Linux 6.5.0-21-generic  up=4 days  via=192.168.1.42
```

Cyan figlet + dim metadata row. Uses font `figlet -f small`.

### `fastfetch-slim` style

```
   _   _      _    ___  _
  | | | |__ _| |__|__ \| |__
  | |_| / _` | '_ \ / // '_ \
   \___/\__,_|_.__//_(_)_.__/

user@hub3
OS: Ubuntu 24.04.1 LTS x86_64
Kernel: Linux 6.8.0-45-generic
Uptime: 12 days, 3 hours
CPU: Intel i7-12700H (20)
Memory: 8.42 GiB / 32.00 GiB (26%)
Disk (/): 41 GiB / 200 GiB (20%)
```

Skips logo (figlet already gave you the big hostname) and skips slow probes (Packages, GPU, displays). Structure: `Title:OS:Kernel:Uptime:CPU:Memory:Disk`.

### `fastfetch-full` style

```
            .-/+oossssoo+/-.               user@desktop
        `:+ssssssssssssssssss+:`           ----------
      -+ssssssssssssssssssyyssss+-         OS: Ubuntu 24.04.1 LTS x86_64
   .ossssssssssssssssssdMMMNysssso.        Host: ThinkPad P14s Gen 4
  /ssssssssssshdmmNNmmyNMMMMhssssss/       Kernel: Linux 6.8.0-45
 +ssssssssshmydMMMMMMMNddddyssssssss+      Uptime: 12 days, 3 hours
... (full distro logo + ~20 info rows incl. GPU, displays, theme, packages) ...
```

The classic neofetch-style screenshot. Use it on machines you genuinely want to show off.

## Trigger conditions

The banner fires only when **all four** gates pass — independent of style:

| # | Gate | Why |
|---|------|-----|
| 1 | `[ -n "$SSH_CONNECTION" ]` | Empty on console / local / `tmux new` |
| 2 | `[ -t 1 ]` | stdout must be a TTY → suppresses `ssh host 'cmd'`, `scp`, `rsync`, `fleet-apply` SSH probes |
| 3 | `[ -z "$TMUX" ]` | Print once per SSH session, not per tmux pane |
| 4 | `[ "${MOTD_DISABLE:-0}" != "1" ]` | Per-session opt-out |

zsh sources `.zlogin` only for **login shells**, so new tmux panes (default config) and non-interactive `zsh -c` invocations don't even reach the script. Gates 2 and 3 are belt-and-suspenders against tmux configs that force login shells inside panes.

## Tools used

`figlet` is always used (every style starts with the figlet hostname, except `fastfetch-full` which uses fastfetch's own logo).

`fastfetch` is the modern Rust replacement for the now-deprecated `neofetch` — used by the `fastfetch-slim` and `fastfetch-full` styles. If `fastfetch` isn't installed (e.g., first-boot SSH before ansible runs, or a `noRoot` Ubuntu 22.04 host where the GitHub `.deb` fallback failed), the slim/full styles **fall back** to the `figlet` style automatically — never errors out.

Companion tools `toilet` (color/Unicode figlet superset) and `lolcat` (rainbow color filter) are installed by `devtools` but **not used by the MOTD itself** — they're general-purpose user CLIs you can pipe to:

```sh
echo "deploy ok" | toilet -f mono12 --metal
echo "RAINBOW" | figlet | lolcat
```

The MOTD uses only ANSI escapes (cyan + dim) so it stays deterministic over flaky SSH and never depends on an external color filter being present.

## Switching styles

### At install time

When you run `chezmoi init` (or `chezmoi init --force` on an existing host), one of the prompts is:

```
SSH login banner style (figlet|fastfetch-slim|fastfetch-full)?
```

Answer once and the choice is baked into `~/.config/chezmoi/chezmoi.toml`.

The choice ripples through the chezmoi template engine into `~/.zlogin` at apply time — `{{ .motdStyle }}` resolves to your answer.

### At runtime (no re-init)

Add to `~/.zshrc.adhoc` (auto-created by [`dot_zshrc.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_zshrc.tmpl), not chezmoi-managed):

```sh
export MOTD_STYLE=fastfetch-slim   # one of: figlet | fastfetch-slim | fastfetch-full
```

`MOTD_STYLE` overrides `{{ .motdStyle }}` for that machine without touching chezmoi state. Useful when fleet defaults are wrong for one box, or when you want to A/B test styles for a few sessions.

You can even pin it per session: `MOTD_STYLE=fastfetch-full ssh laptop`.

## Opt out completely

```sh
export MOTD_DISABLE=1   # in ~/.zshrc.adhoc
```

Or per session: `MOTD_DISABLE=1 ssh host`.

## First boot (before fastfetch is installed)

Chezmoi deploys `~/.zlogin` before the ansible `devtools` role runs. If you SSH in during that window with `motdStyle=fastfetch-slim`:

- `command -v fastfetch` returns false
- Falls back to `figlet` style (figlet hostname + metadata line)
- Still exits cleanly

After ansible finishes, the next SSH login uses fastfetch.

## Customization

### Change the figlet font

Edit `~/.zlogin` directly (or, for fleet rollout, `dot_zlogin.tmpl`):

```sh
# Inside _motd_print_figlet_banner():
figlet -w "$_motd_cols" -f banner -- "$_motd_host"   # blocky
figlet -w "$_motd_cols" -f slant  -- "$_motd_host"   # italic
figlet -w "$_motd_cols" -f standard -- "$_motd_host" # tall default
```

Fonts live under `/usr/share/figlet/` (Linux) or `$(brew --prefix figlet)/share/figlet/fonts/` (macOS). The `small` default fits ~20-char hostnames inside a 24-row mobile SSH window.

### Change `fastfetch-slim` fields

Inside `dot_zlogin.tmpl`, the slim case calls:

```sh
fastfetch --logo none -s Title:OS:Kernel:Uptime:CPU:Memory:Disk
```

`-s`/`--structure` takes any colon-separated list of `fastfetch --list-modules` modules. Common additions: `LocalIP`, `PublicIP` (slow), `LoadAvg`, `Battery`, `Locale`, `Shell`, `Packages`. Each adds ~5-30 ms.

### Customize `fastfetch-full` config

`fastfetch --gen-config-force` writes `~/.config/fastfetch/config.jsonc` with the default config — edit it to add/remove modules, swap logos, change colors. Chezmoi doesn't manage that file, so tweaks survive `chezmoi apply`. See <https://github.com/fastfetch-cli/fastfetch/wiki/Configuration> for the schema.

### Show FQDN instead of short hostname

```sh
_motd_host="$(hostname -f 2>/dev/null || hostname)"
```

### Skip the metadata line on `figlet` style

Delete `_motd_print_metadata_line` from the `figlet|*)` case in `dot_zlogin.tmpl`.

## Why not `/etc/motd` or PAM `motd.dynamic`?

System MOTD lives in `/etc/motd` and `/etc/update-motd.d/*` and applies to **every** user. This banner is per-user, lives in the dotfiles repo, and respects user opt-out — no root needed, no impact on other accounts. Ubuntu's default MOTD (the load-average / "X updates can be installed" / Canonical news lines) **stacks above** our banner in the SSH boot order:

```
SSH connect → PAM auth → pam_motd prints /etc/motd + update-motd.d/*
                                           ↓
                          shell starts → zsh → .zshenv → .zshrc → .zlogin (us)
                                                                       ↓
                                                                   prompt
```

To silence Ubuntu's stuff:

```sh
touch ~/.hushlogin   # per-user; silences pam_motd for you only
sudo chmod -x /etc/update-motd.d/50-motd-news   # system-wide; kills Canonical news
```

## Related

- [`dot_zlogin.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_zlogin.tmpl) — the source template
- [`dot_ansible/roles/devtools/tasks/main.yml`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_ansible/roles/devtools/tasks/main.yml) — installs `figlet`, `toilet`, `lolcat`, `fastfetch` (apt + brew, with GitHub `.deb` fallback for older Ubuntu)
- [`.chezmoi.toml.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/.chezmoi.toml.tmpl) — declares the `motdStyle` prompt
- [`dot_zshrc.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_zshrc.tmpl) — auto-creates `~/.zshrc.adhoc` (where `MOTD_STYLE=...` and `MOTD_DISABLE=1` live)
- [Fleet apply](../this_repo/fleet-apply.md) — the multi-host workflow this banner is most useful for
- [fastfetch upstream](https://github.com/fastfetch-cli/fastfetch)
