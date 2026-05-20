# btop crashes on launch with "Permission denied" + core dump (snap confinement)

**Symptoms** (grep this section): `btop` aborts immediately on launch; zsh reports `IOT instruction (core dumped)  btop`; stderr shows `terminate called after throwing an instance of 'std::filesystem::__cxx11::filesystem_error'` then `what():  filesystem error: directory iterator cannot open directory: Permission denied [/home/<user>/.config/btop/themes]`; `btop --version` prints fine; the directory permissions look **correct** (`drwxrwxr-x <user> <user>`, `namei -l` shows no root-owned component); `command -v btop` resolves to `/snap/bin/btop`; `snap list btop` shows publisher `kz6fittycent`.
**First seen**: 2026-05
**Affects**: the third-party **snap** build of btop (strict AppArmor confinement) on Linux, whenever a real `~/.config/btop/` exists. `/snap/bin` precedes `/usr/bin` and `~/.local/bin` on `PATH`, so the snap shadows any apt / GitHub / brew btop.
**Status**: not a repo bug — the snap is an out-of-band install. Workaround = remove or shadow the snap so the repo-managed (apt / GitHub musl / brew) btop wins on `PATH`.

## Symptom

```text
terminate called after throwing an instance of 'std::filesystem::__cxx11::filesystem_error'
  what():  filesystem error: directory iterator cannot open directory: Permission denied [/home/daviddwlee84/.config/btop/themes]
[1]    NNNNN IOT instruction (core dumped)  btop
```

The version check is misleadingly healthy and the directory looks perfectly fine:

```sh
btop --version
# btop version: 1.4.7

ls -ld ~/.config/btop ~/.config/btop/themes
# drwxrwxr-x ... daviddwlee84 daviddwlee84 ... ~/.config/btop
# drwxrwxr-x ... daviddwlee84 daviddwlee84 ... ~/.config/btop/themes

namei -l ~/.config/btop/themes
# every component owned by the user; no root, no missing +x
```

So the obvious "fix" — `sudo chown -R "$USER:$USER" ~/.config/btop` / `chmod -R u+rwX` — **changes nothing**, because the denial is not a Unix-permission denial.

## Root Cause

`/snap/bin/btop` is a **snap** package (here, third-party publisher `kz6fittycent`). Snaps run under AppArmor confinement, and the **`home` interface does not grant access to hidden files/directories** (anything under a `.`-prefixed path such as `~/.config`). At startup btop scans its theme directory with `std::filesystem::directory_iterator(~/.config/btop/themes)`; the confinement denies the read, `directory_iterator` throws `filesystem_error`, the exception is uncaught, and `std::terminate` → `abort()` → `SIGABRT` ("IOT instruction (core dumped)").

The Unix permissions on `~/.config/btop/themes` (user-owned `775`) are a **red herring** — the EACCES comes from the kernel AppArmor layer, not the file mode. `snap connections btop` shows `home` *connected*, which misleads further; the `home` interface simply never covers dotfiles.

Why does the snap even read the real `~/.config/btop` rather than its confined `~/snap/btop/current/.config`? btop resolves the real `$HOME`/`$XDG_CONFIG_HOME`, so once a real `~/.config/btop/themes` exists, the confined process tries to iterate it and is denied.

This repo never installs the snap. On Linux it installs btop via apt (`dot_ansible/roles/devtools/tasks/main.yml`) with a GitHub musl-static fallback; macOS uses Homebrew. The snap was an out-of-band `snap install btop` that landed earlier on `PATH` (`/snap/bin` at a lower index than `/usr/bin` and `~/.local/bin`) and shadowed the working binary.

## Workaround

Remove the snap so the repo-managed btop takes over:

```sh
sudo snap remove btop
command -v btop          # → /usr/bin/btop (apt) or ~/.local/bin/btop (GitHub musl)
btop                     # launches; reads ~/.config/btop/themes fine (unconfined)
```

If you want the newest version via a package manager (the snap was 1.4.x; apt is older), install brew btop — Linuxbrew's `bin` precedes `/snap/bin`, so it wins on `PATH` even before removing the snap (removing it afterward is just cleanup):

```sh
brew install btop        # /home/linuxbrew/.linuxbrew/bin/btop, unconfined
```

Do **not** reach for `chown`/`chmod` on `~/.config/btop` — the directory is already user-owned and readable; the problem is snap confinement, not file mode.

## Prevention

- This repo manages `~/.config/btop/btop.conf` + `themes/catppuccin_mocha.theme` via chezmoi (`dot_config/btop/`), so the theme directory is always populated and correctly owned — on an **unconfined** btop. (It cannot save a confined snap; that's the snap's problem, not the config's.)
- Keep btop on the package-manager / GitHub-musl path the `devtools` role provides; avoid `snap install btop` on managed machines.
- Reproduce the crash deterministically (no real interactive terminal needed) by running the snap under a pty with a non-zero window size — a `script`/`tmux` 0×0 pty stops at the earlier "Failed to get size of terminal!" check and will *not* surface the theme-dir denial.

## Related

- [docs/tools/btop.md](../docs/tools/btop.md) — managed btop config, the `create_` seed-once rationale, and the same snap warning.
- [`git-delta-empty-stdin-huge-allocation`](git-delta-empty-stdin-huge-allocation.md) — another `IOT instruction (core dumped)` on Linux, different root cause (incompatible bat cache); useful cross-reference when grepping for the core-dump string.
- [`tmux-pane-vanishes-on-ctrl-c-despite-shell-wrapper`](tmux-pane-vanishes-on-ctrl-c-despite-shell-wrapper.md) — a different btop-adjacent trap (pane closes on Ctrl+C inside btop/htop).
