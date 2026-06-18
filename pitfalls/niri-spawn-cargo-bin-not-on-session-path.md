# niri `Mod+T` opens nothing — `~/.cargo/bin` not on the Wayland session PATH (and the `/usr/local/bin` symlink "fix" breaks multi-user)

**Symptoms** (grep this section):
- In a niri session, `Mod+T` (or any `spawn "<tool>"` keybind) does **nothing** —
  no window, no on-screen error.
- The binary clearly exists: `command -v alacritty` in your normal terminal prints
  `/home/<user>/.cargo/bin/alacritty` and running `alacritty` by hand works.
- The niri / systemd graphical-session PATH is only
  `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin` —
  it does **not** include `~/.cargo/bin` or `~/.local/bin`.
- Same trap for any tool installed by cargo/uv/npm into `~/.cargo/bin` /
  `~/.local/bin` that you try to `spawn` from `config.kdl`.

**First seen**: 2026-06-18 on `David-Ubuntu` (Ubuntu 24.04), first boot into niri
after the `installNiri` role landed. alacritty is cargo-built by `gui_apps_linux`
into `~/.cargo/bin/alacritty`.
**Affects**: any Wayland WM (niri, sway, …) launched from a display manager, for
any binary that lives under `$HOME` rather than a system dir. `i3`/X11 has the
same class of issue (it uses `exec` lines, also not shell-sourced).
**Status**: fixed in-repo per-user — see "Fix" below.

## Why

A WM launched by GDM runs under the **systemd user session**, whose PATH is the
default `/usr/local/bin:/usr/bin:…`. `~/.cargo/bin` and `~/.local/bin` are added
by the **interactive shell rc** (`dot_config/shell/00_exports.sh`, sourced by
`~/.zshrc` / `~/.bashrc`) — a graphical session never sources those, so the WM
and everything it `spawn`s never see them. `spawn "alacritty"` does a PATH
lookup, finds nothing, and silently no-ops.

## The tempting WRONG fix

```sh
sudo ln -sf ~/.cargo/bin/alacritty /usr/local/bin/alacritty   # DON'T
```

It "works" on a single-user box, but it points a **shared system path**
(`/usr/local/bin`, on everyone's PATH) at **one user's `$HOME`**. On a multi-user
host this breaks three ways:

1. **Permission** — another user running `alacritty` is sent into
   `/home/<that-one-user>/.cargo/bin/`; if that home is `0750`/`0700` they get
   permission-denied traversing it.
2. **Dangling link** — when the owning user `cargo uninstall`s / rebuilds, the
   system-wide symlink breaks for *everyone*.
3. **Trust** — a binary on the system PATH is now controlled by a non-root user
   who can swap its target.

## Fix (per-user, multi-user-safe)

Put the user-local bin dirs on PATH inside niri's own `environment {}` block,
templated per-user by chezmoi — niri applies it to every process it spawns, and
each user's render points at their own `$HOME`:

```kdl
// dot_config/niri/config.kdl.tmpl
environment {
    PATH "{{ .chezmoi.homeDir }}/.cargo/bin:{{ .chezmoi.homeDir }}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"
}
```

(niri does not *append* to PATH, so the value is the full list — keep the
standard session dirs after the user-local ones.) Changes need a niri restart
(`Mod+Shift+E` → re-login) to take effect. System-wide tools that belong to
everyone (e.g. the `fuzzel` launcher) still go through `apt` in the niri role —
that's correct; only the `$HOME`-scoped ones use the PATH block.

See [`dot_config/niri/config.kdl.tmpl`](../dot_config/niri/config.kdl.tmpl),
[`dot_ansible/roles/niri/tasks/main.yml`](../dot_ansible/roles/niri/tasks/main.yml)
(the "Desktop usability" comment), and [docs/playbooks/niri.md](../docs/playbooks/niri.md).
