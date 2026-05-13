# `pkill -f /path/to/foo.AppImage` succeeds but the AppImage keeps running

**Symptoms** (grep this section):

- `pkill -f /home/$USER/Applications/foo.AppImage` returns exit code 0 (signal sent
  to at least one process) but the app's window stays open. `pgrep -f
  /home/$USER/Applications/foo.AppImage` finds 1–2 PIDs even after `pkill`.
- `pgrep -af zen` shows a process tree like:
  ```
  1051685 /opt/appimagelauncher.AppDir/usr/lib/x86_64-linux-gnu/appimagelauncher/binfmt-bypass /home/$USER/Applications/zen-x86_64_*.AppImage
  1051701 /home/$USER/Applications/zen-x86_64_*.AppImage
  1051702 squashfuse /home/$USER/Applications/zen-x86_64_*.AppImage /tmp/.mount_remp6447713832535214190 -f -o ro,nodev,noatime ...
  1051705 /tmp/.mount_remp6447713832535214190/zen      ← the actual app
  1051754 /tmp/.mount_remp6447713832535214190/zen -contentproc -parentBuildID ...
  ```
  Only the first 3 lines contain the `.AppImage` path — `pkill -f .AppImage`
  kills those (binfmt-bypass + wrapper + squashfuse) but leaves the real app
  (last 2 lines) running. The wrapper's death tears down the FUSE mount but
  the binary is already loaded and keeps running until it tries to read
  from the now-stale mount.
- `appquit Zen` (or any `app-*` helper using auto-derived patterns from
  `dot_config/shell/56_linux_apps.sh`) silently fails for AppImage apps —
  pkill exits 0, helper assumes success, but the app is still running.

**First seen**: 2026-05-13 on Ubuntu 24.04 Wayland during the empirical
probe for `backlog/linux-desktop-app-control.md`. Confirmed against the
user's Zen Browser and Frpc-Desktop AppImages.

**Why this happens**:

AppImages mount themselves via FUSE at `/tmp/.mount_<hash>/` and execute
the inner binary from that path. The `.desktop` `Exec=` field points at
the `.AppImage` file (the unmounted artefact), but the kernel process
table records the actual mounted path (`/tmp/.mount_<hash>/<inner-binary>`).
`pkill -f` matches against the full command line of each process —
processes whose command line contains the `.AppImage` path are only the
wrapper / launcher / squashfuse layers, not the running app.

Compounding factor: AppImage runtime paths include a random hash that
changes every time the AppImage is invoked (`/tmp/.mount_remp6447*` vs
`/tmp/.mount_Frpc-D4MNzod`), so you can't hard-code the runtime path in
config — only the basename of the inner binary is stable.

**Fix**:

Match on the **inner binary basename** anchored to the `/tmp/.mount_*/`
prefix, not the `.AppImage` path. In `~/.config/shell/linux-apps.conf`:

```sh
# Zen Browser
linux_app_register Zen \
  --desktop=zen-browser \
  --pkill='\.mount_.+/zen($| )' \
  --wm-class=zen

# Frpc-Desktop
linux_app_register Frpc-Desktop \
  --desktop=appimagekit_<hash>-Frpc-Desktop \
  --pkill='\.mount_.+/frpc-desktop($| )' \
  --wm-class=Frpc-Desktop
```

The `\.mount_.+/<inner>($| )` regex:
- `\.mount_` — the FUSE mountpoint prefix `/tmp/.mount_…`
- `.+/` — any mount hash followed by a slash
- `<inner>` — the inner binary basename (often the AppImage name lowercased
  and stripped of `.AppImage` + version + arch suffixes)
- `($| )` — end of line OR space (so renderer child processes whose
  command line starts with the same path are also killed)

To find the inner binary name for an installed AppImage **while it's
running**:

```sh
pgrep -af "$(basename ~/Applications/foo.AppImage)" \
  | awk '{for(i=1;i<=NF;i++)if($i ~ /\.mount_/)print $i}' \
  | head -1
```

Or peek inside the AppImage without running it (slower, but works for
debugging):

```sh
~/Applications/foo.AppImage --appimage-mount &
sleep 1
ls /tmp/.mount_*/AppRun  # AppRun is the entrypoint; tail -1 of /proc/<pid>/exe
```

**Related**:

- `dot_config/shell/56_linux_apps.sh.tmpl` — the helper that documents the
  override file pattern; its auto-derivation **deliberately fails** for
  AppImages so users get pushed toward an explicit override.
- `backlog/linux-desktop-app-control.md` → empirical findings section #2.
- `docs/playbooks/linux-gui-apps.md` → "Override file: when to override vs
  let auto-derivation handle it".
- `docs/tools/appimage.md` — AppImageLauncher's binfmt-bypass shim
  contributes to the process-tree depth shown above.
