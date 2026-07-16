# Ghostty & cmux

[Ghostty](https://ghostty.org/) is a fast, native terminal emulator. [cmux](https://cmux.dev/) is a lightweight macOS terminal built on Ghostty for managing AI coding agents. Both read the same config file.

## Managed config

This repo manages `~/.config/ghostty/config` (via `dot_config/ghostty/config`). cmux reads this file first (before `~/Library/Application Support/com.mitchellh.ghostty/config`).

Key settings:

- **`macos-option-as-alt = left`** — Left Option sends Meta/Esc+ so tmux `M-` keybindings work (theme switching `M-c`/`M-t`, layouts `M-1`..`M-5`, fine resize `M-h/j/k/l`). Right Option retains macOS compose behavior for accents and special characters.
- **`font-features = -calt, -liga, -dlig`** — Disables ligatures for code readability.

> **Note**: Restart Ghostty/cmux after changing the config — it is read on launch, not hot-reloaded.

Without `macos-option-as-alt`, macOS Option produces Unicode compose characters (e.g. `Option+c` → `ç`) instead of `Esc+c`, silently breaking all tmux Meta bindings. Alacritty and iTerm2 have their own equivalent settings (`window.option_as_alt` and Profiles > Keys > Left Option Key > Esc+ respectively).

## `xterm-ghostty` terminfo on remote hosts

When you SSH into a fresh remote, `$TERM=xterm-ghostty` but the remote has no matching terminfo entry. Symptoms: broken line-drawing, garbled prompts, `clear`/`tput` failures, Neovim rendering glitches. This is especially visible on the first cmux/tmux SSH into a new box.

### Option 1 — Ghostty built-in (recommended for interactive shells)

> - [Shell Integration - Features](https://ghostty.org/docs/features/shell-integration#ssh-integration)

Add to `~/.config/ghostty/config`:

```ini
shell-integration-features = ssh-env,ssh-terminfo
```

- `ssh-terminfo`: auto-installs `xterm-ghostty` on the remote the first time you `ssh` from an interactive shell with Ghostty shell integration loaded.
- `ssh-env`: forwards `COLORTERM`, `TERM_PROGRAM`, `TERM_PROGRAM_VERSION` via `SendEnv`, and falls back to `TERM=xterm-256color` where needed. The remote `sshd_config` needs a matching `AcceptEnv` line for the forwarded vars to take effect.

**Limitations**: only triggers from interactive shells with the Ghostty wrapper active. It does not cover `ssh` invoked inside tmux/cmux panes, from scripts, or from wrapper tools (`rsync`, `aws`, `gcloud`, …). For those, use the manual helper below.

### Option 2 — manual helper (works everywhere)

A zsh function `ghostty-ssh-terminfo` is defined in [`dot_config/zsh/10_aliases.zsh`](../../dot_config/zsh/10_aliases.zsh).

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
