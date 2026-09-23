# Ghostty & cmux

Ghostty's Kitty graphics support also makes it suitable for
[terminal-browser](browser-tools.md), including inside Herdr. Playwright CLI's
headless mode works independently of terminal graphics.

[Ghostty](https://ghostty.org/) is a fast, native terminal emulator. [cmux](https://cmux.dev/) is a lightweight macOS terminal built on Ghostty for managing AI coding agents. Both read the same config file.

## Installation and profiles

- **macOS:** `cask "ghostty"` is in the GUI Brewfile under `installBrewApps`.
- **Linux desktop:** `gui_apps_linux` installs missing Ghostty on x64/arm64.
  It prefers an existing apt candidate (Ubuntu 26.04+ ships one), uses the
  upstream-listed `mkasberg/ghostty-ubuntu` PPA on Ubuntu 24.04, and otherwise
  falls back to the upstream-listed classic Snap. The PPA is a community build;
  Noble's GTK baseline is supported up to Ghostty 1.3.1. No Ubuntu PPA is added
  to Debian. Snap is the compatibility fallback for older GTK, not the first
  choice for a daily-use terminal.
- **Server:** GUI tag selection does not install Ghostty. Run it on the client
  and connect over SSH.
- **noRoot / 32-bit:** automatic Linux installation is skipped with a hint;
  existing manually installed binaries are preserved. No default terminal is
  changed, and Alacritty continues to be available.

Apply is install-only. macOS upgrades use `just upgrade-brew`; apt installations
follow explicit system package maintenance, and Snap follows its normal refresh
schedule. There is no extra Ghostty updater. Package sources:
[Ghostty installation guide](https://ghostty.org/docs/install/binary),
[Ubuntu PPA](https://github.com/mkasberg/ghostty-ubuntu),
[classic Snap](https://snapcraft.io/ghostty).

## Alacritty comparison

| Setting | Ghostty decision |
| --- | --- |
| Hack Nerd Font Mono, 14pt | Shared; bold/italic variants selected from the family automatically |
| 10px window padding | Shared numeric X/Y value of 10; actual scaling follows each terminal |
| 0.7 opacity + blur | Keep Ghostty's opaque default for readability; optional recipe below |
| Shift/Ctrl+Enter, Ctrl+digits | Use native negotiated Kitty/xterm extended keys; do not force Alacritty's byte strings |
| Ctrl+/ | Native legacy encoding already supplies `0x1f`; modern apps can negotiate an unambiguous key |
| `TERM=xterm-256color` | Keep native `xterm-ghostty`, with SSH terminfo support |
| Option as Alt | Keep Ghostty's existing left-only policy; Right Option remains available for compose |
| Linux Ctrl+Shift+T / N | Keep Ghostty's native tab / window actions; Alacritty maps both to windows because it has no tabs |

Ghostty's legacy modified-Enter encoding can be xterm `CSI 27;…~`, while Kitty
mode uses CSI-u. Applications/multiplexers negotiate and decode these protocols;
the bytes need not be identical to Alacritty's explicit overrides. Existing tmux
root bindings still consume Ctrl+digits for window selection.

For the Alacritty transparency look, the equivalent optional settings are:

```ini
background-opacity = 0.7
background-blur = true
```

Blur depends on the compositor (macOS / supported Linux compositors such as
KWin); it is not guaranteed under GNOME. This file also affects cmux. See the
[Ghostty option reference](https://ghostty.org/docs/config/reference).

## Managed config

This repo manages `~/.config/ghostty/config` (via `dot_config/ghostty/config`). cmux reads this file first (before `~/Library/Application Support/com.mitchellh.ghostty/config`).

Key settings:

- **`font-family = Hack Nerd Font Mono`, `font-size = 14`, `window-padding-x/y = 10`** — aligns typography and spacing with Alacritty.
- **`shell-integration-features = ssh-env,ssh-terminfo`** — enables the interactive SSH helpers described below while retaining the other default features.

- **`macos-option-as-alt = left`** — Left Option sends Meta/Esc+ so tmux `M-` keybindings work (theme switching `M-c`/`M-t`, layouts `M-1`..`M-5`, fine resize `M-h/j/k/l`). Right Option retains macOS compose behavior for accents and special characters.
- **`font-feature = -calt, -liga, -dlig`** — Disables ligatures for code readability. The key is singular; `font-features` fails Ghostty validation with `unknown field`.

Validate the managed source with `ghostty +validate-config --config-file=dot_config/ghostty/config`, and the installed config with `ghostty +validate-config`. Ghostty can reload configuration with `Cmd+Shift+,` on macOS; restart cmux to pick up changes to the shared file.

Without `macos-option-as-alt`, macOS Option produces Unicode compose characters (e.g. `Option+c` → `ç`) instead of `Esc+c`, silently breaking all tmux Meta bindings. Alacritty and iTerm2 have their own equivalent settings (`window.option_as_alt` and Profiles > Keys > Left Option Key > Esc+ respectively).

## `xterm-ghostty` terminfo on remote hosts

When you SSH into a fresh remote, `$TERM=xterm-ghostty` but the remote has no matching terminfo entry. Symptoms: broken line-drawing, garbled prompts, `clear`/`tput` failures, Neovim rendering glitches. This is especially visible on the first cmux/tmux SSH into a new box.

### Option 1 — Ghostty built-in (recommended for interactive shells)

> - [Shell Integration - Features](https://ghostty.org/docs/features/shell-integration#ssh-integration)

Already enabled in the managed `~/.config/ghostty/config`:

```ini
shell-integration-features = ssh-env,ssh-terminfo
```

- `ssh-terminfo`: auto-installs `xterm-ghostty` on the remote the first time you `ssh` from an interactive shell with Ghostty shell integration loaded.
- `ssh-env`: forwards `COLORTERM`, `TERM_PROGRAM`, `TERM_PROGRAM_VERSION` via `SendEnv`, and falls back to `TERM=xterm-256color` where needed. The remote `sshd_config` needs a matching `AcceptEnv` line for the forwarded vars to take effect.

**Limitations**: only triggers from interactive shells with the Ghostty wrapper active. It does not cover `ssh` invoked inside tmux/cmux panes, from scripts, or from wrapper tools (`rsync`, `aws`, `gcloud`, …). For those, use the manual helper below.

### Option 2 — manual helper (works everywhere)

A shared-shell function `ghostty-ssh-terminfo` is defined in [`dot_config/shell/10_aliases.sh`](../../dot_config/shell/10_aliases.sh).

```bash
ghostty-ssh-terminfo <ssh-host>
```

What it does:

- Validates local `infocmp` and the `xterm-ghostty` entry exist.
- Pipes `infocmp -x xterm-ghostty` into a **single** SSH call (no double password/MFA prompt).
- On the remote: probes for `tic`, creates `~/.terminfo`, and runs `TERMINFO="$HOME/.terminfo" tic -x -` — so no root/sudo needed.
- Suppresses only the harmless `older tic versions may treat the description field as an alias` warning (emitted by ncurses < 6.3). Real errors still surface and set a non-zero exit.

Example:

```bash
# First time connecting a new box from cmux/tmux
ghostty-ssh-terminfo remote
# → Installed xterm-ghostty terminfo on remote (in ~/.terminfo)

# Verify
ssh remote 'infocmp xterm-ghostty >/dev/null && echo ok'
```

### Snap `nvtop` on a remote host

The Snap build of `nvtop` changes `HOME` to `~/snap/nvtop/<revision>`, so it
cannot find the Ghostty entry installed in the user's `~/.terminfo`. It then
reports `Error opening terminal: xterm-ghostty`, even though `infocmp` succeeds
outside the Snap. The shared-shell `nvtop` function copies that entry to
`~/snap/nvtop/common/.terminfo` and sets `TERMINFO` for the Snap invocation.
The `common` directory survives Snap revisions. Other terminal types and native
`nvtop` use their normal configuration. Open a new shell after applying this
change, or source `~/.config/shell/10_aliases.sh` in the current shell.

### Smoke-test against `localhost`

Yes — if `sshd` is running locally you can validate the function without touching a real remote:

```bash
# Enable sshd (Linux)
sudo systemctl start ssh
# or macOS: System Settings → General → Sharing → Remote Login

ghostty-ssh-terminfo localhost
```

Caveats:

- `localhost` already has your own `$HOME`, so this effectively writes to the *same* `~/.terminfo` your local shell reads. Useful as a wiring/error-path smoke test, not as a representative "fresh remote" check.
- If you already have the entry locally (which you do, otherwise `infocmp -x xterm-ghostty` would fail), the install is a no-op overwrite — still exercises the full pipeline end-to-end.
- For a cleaner test, point at a container or a VM where `xterm-ghostty` is definitely missing.

## Why the warning appears (and can't be fully fixed client-side)

The `|`-separated long description in Ghostty's terminfo is interpreted as an extra alias by `tic` / ncurses prior to 6.3. The entry still installs correctly; the warning is cosmetic. The only real fix is upgrading ncurses on the remote.

## Image preview (yazi)

Ghostty and cmux speak the **Kitty graphics protocol**, so [yazi](yazi-previews.md) renders **crisp
inline images** (not chafa ascii-art) for png / jpg / pdf / video previews — no config needed, yazi
auto-detects the terminal.

Gotcha: a very large image (a wide plot, a hi-DPI screenshot) can show **`Image size exceeds limit`**
in the preview pane. That's yazi's image *decode* bound, **not** a Ghostty/cmux cap — this repo raises
`[tasks] image_bound` in `dot_config/yazi/yazi.toml`; run `yazi --clear-cache` and restart yazi to pick
it up. Detail + the terminal support matrix:
[yazi-previews.md → Large images](yazi-previews.md#image-size-limit) /
[which terminal gets crisp images](yazi-previews.md#which-terminal-gets-crisp-images-vs-ascii-art).
Inside tmux, image passthrough needs `allow-passthrough on` (set in `dot_config/tmux/common.conf.tmpl`).

## See also

- [tmux](tmux.md) — tmux config and keybindings (cmux runs on top of tmux).
- [sesh](../sesh.md) — session picker used in the tmux setup.
