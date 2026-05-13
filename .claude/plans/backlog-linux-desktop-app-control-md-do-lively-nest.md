# Linux Desktop app control — graceful `app-*` helpers (Ubuntu/GNOME Wayland)

## Context

The macOS side shipped in commits `ce5e23a` (`54_macos_apps.sh.tmpl`) + `2fc5031` (`tv mac-apps`) gives graceful Quit / Launch / Activate / Restart / Hide on Mac via Apple Events. The user now has a real Ubuntu Desktop machine (GNOME Shell 46.0, Ubuntu 24.04.4, Wayland by default) to validate the Linux counterpart against item-#1 in `backlog/linux-desktop-app-control.md` ("no Ubuntu Desktop host to test against").

Empirical probe on this host invalidated the backlog's central assumption:

- `gapplication list-apps` returns **13 entries, all GNOME-core** (Calendar, Logs, Nautilus, …). **Zero** of the user's actual apps (Zen, Cursor, Spotify, Discord, Frpc-Desktop) have `DBusActivatable=true`. Backlog said "patchy good" for third-party — reality is 0% coverage.
- All 5 apps DO have stable `StartupWMClass` and known `Exec=` paths in `.desktop` files.
- `gtk-launch` / `dex` / `gio` are installed → **launch-by-desktop-id is fully solvable** without DBusActivatable.
- AppImage runtime path ≠ `.desktop` Exec path: Zen `.desktop` says `~/Applications/zen-x86_64_*.AppImage`, actual running binary is `/tmp/.mount_remp*/zen`. Pkill on Exec only hits the launcher wrapper.
- `.desktop` cruft: Zen has 4 entries (AppImage launcher leftovers), Cursor 2 (apt + AppImage), Discord 2 (apt + Flatpak — both installed, only apt running).
- `playerctl`, `wmctrl`, `xdotool`, `wlrctl`, `ydotool`, `wtype`, `qdbus` are **not installed**. Only D-Bus core tools present.
- `gnome-extensions` IS installed; `window-calls` is not (compositor-introspection extension would need manual install on Wayland).

Decision per user (`AskUserQuestion`):

1. **Hybrid auto + override file** scope
2. **`tv linux-apps`** channel mirroring `mac-apps` UX
3. Install **`playerctl` + `wmctrl` + `xdotool`** via ansible; document **`window-calls`** as manual; rely on **D-Bus core** as baseline

## Achievable verb coverage on Wayland GNOME (no compositor extension)

| Verb | Linux strategy | Coverage on user's app set |
|---|---|---|
| `applaunch NAME` | `gtk-launch <desktop-id>` (no DBusActivatable required) | ✓ all 5 |
| `apprunning NAME` | `pgrep -f <pkill-pattern>` (override or auto-derived) | ✓ all 5 |
| `appquit NAME` | `pkill -TERM -f <pkill-pattern>` — Electron + Firefox honour SIGTERM as graceful quit | ✓ all 5 (with correct per-app pattern) |
| `apprestart NAME` | composition: `appquit` + poll-gone (≤15s) + `applaunch` | ✓ inherits both |
| `appactivate NAME` | `gtk-launch` again — Electron + Firefox re-focus existing instance | ⚠ best-effort; **fully reliable only with `window-calls` extension installed** |
| `applist [--pids\|--all]` | enumerate `.desktop` dirs → pgrep each → emit running ones | ⚠ noisy; output is "apps the helper recognises that are alive", not "every GUI window" |
| `appresponsive NAME [TIMEOUT]` | best-effort: MPRIS no-op for media players via `playerctl`; otherwise degrades to `apprunning` with a stderr note | ⚠ Spotify only (via MPRIS); for Electron/Firefox there's no Linux analog to Apple Events' `with timeout` |

5/7 verbs work cleanly. 1 (`appactivate`) needs the extension for full fidelity but degrades reasonably. 1 (`appresponsive`) is documented-best-effort.

## Files to create / modify

### 1. NEW `dot_config/shell/56_linux_apps.sh.tmpl`

Gated on `{{- if eq .chezmoi.os "linux" -}}`. POSIX-compatible (shared between zsh + bash per the three-tier rule). Same public function names as `54_macos_apps.sh.tmpl` so `appquit Zen` is cross-platform.

**Key internal design:**

- **Override file**: `~/.config/shell/linux-apps.conf` — sourced if present at top of helper. Not auto-stubbed (avoids empty-file footgun, mirrors the `.shellrc.secrets` rule from CLAUDE.md). Contract:
  ```sh
  linux_app_register Zen \
    --desktop=zen-browser \
    --pkill='\.mount_.+/zen($| )' \
    --wm-class=zen
  linux_app_register Spotify \
    --desktop=spotify_spotify \
    --pkill='^/snap/spotify/[^/]+/usr/share/spotify/spotify' \
    --wm-class=spotify \
    --mpris=spotify
  ```
  `linux_app_register` populates an in-process associative map (zsh `typeset -A` / bash `declare -A` — guarded by `$ZSH_VERSION`/`$BASH_VERSION` so POSIX `sh` skips registration but reads still work via flat env vars `LINUX_APP_<id>_PKILL` fallback).
- **Auto-derivation** (fallback when no override): scan `.desktop` dirs (`/usr/share/applications`, `~/.local/share/applications`, `/var/lib/flatpak/exports/share/applications`, `~/.local/share/flatpak/exports/share/applications`, `/var/lib/snapd/desktop/applications`). For a given NAME, match on (a) exact desktop-id stem, (b) `Name=` field, (c) `StartupWMClass=`. Derive `pkill` from basename of `Exec=` stripped of args and `%U`/`%F`/`%u`/`%f` field codes. **Choose latest mtime** when multiple `.desktop` files match (handles Zen's 4-entry cruft).
- **Wayland focus path**: at helper-source time, check `command -v gnome-extensions && gnome-extensions list | grep -q window-calls`. If present, set `_linuxapp_have_winext=1` and `appactivate` calls `gdbus call --session --dest org.gnome.Shell.Extensions.Windows --object-path /org/gnome/Shell/Extensions/Windows --method org.gnome.Shell.Extensions.Windows.Activate <wm-class>`. Otherwise `appactivate` = `applaunch` with a one-line stderr hint "(install window-calls extension for true focus)".
- **`appresponsive`**: if `--mpris=NAME` registered AND `playerctl` available, do `timeout "$TIMEOUT" playerctl -p "$NAME" status >/dev/null`. Else degrade to `apprunning` + stderr note. Document non-equivalence vs macOS Apple Events.
- **Guards**: `_linuxapp_guard_linux` (mirror `_macapp_guard_darwin`), `_linuxapp_need_name`, `_linuxapp_resolve <NAME> → <pkill-pattern>` central resolver.
- **Heredoc help on `-h`/`--help`** in each verb, same as the macOS file.

### 2. NEW `dot_config/television/cable/linux-apps.toml.tmpl`

Gated on `{{- if and (eq .chezmoi.os "linux") (eq .profile "ubuntu_desktop") -}}`. Mirrors `dot_config/television/cable/mac-apps.toml.tmpl` keybindings exactly:

| Key | Action |
|---|---|
| Enter | `actions:activate` (calls `appactivate`) |
| Alt+Q | `actions:quit` + reload_source |
| Alt+R | `actions:restart` + reload_source |
| Alt+H | `actions:hide` — **omit** on Linux (no equivalent; GNOME hide-via-System-Events has no analog without extension); document as macOS-only in the channel header comment |
| Alt+K | `actions:force-kill` (SIGKILL by PID) + reload_source |
| Alt+I | `actions:info` — `ps -p $pid` + `pgrep -af <pattern>` + `gdbus introspect` if D-Bus name known |
| Alt+P | `actions:probe` — calls `appresponsive` |

**Source command**: enumerate running apps via the helper's `applist --pids` (sourced inline at channel-load — same trick as mac-apps inlining the AppleScript). Output `<pid>\t<name>` to match mac-apps's split format.

**Why omit Alt+H**: the Linux side can't do "hide windows" without compositor IPC. Better to drop the key than to ship a no-op that silently fails — leaves the slot free for a future bind (`Alt+M` minimize?).

### 3. MODIFY `dot_ansible/roles/gui_apps_linux/tasks/main.yml`

Append a small apt task (cite the same `state: present` install-only convention as the rest of the role):

```yaml
- name: Install GUI app control utilities (apt)
  ansible.builtin.apt:
    name:
      - playerctl       # MPRIS — Spotify/VLC/Firefox media control
      - wmctrl          # X11 window control (no-op on Wayland but cheap)
      - xdotool         # X11 input + window control (no-op on Wayland)
    state: present
  become: true
  when: ansible_os_family == "Debian"
  tags: [gui_apps_linux, app_control]
```

**Do NOT** automate `gnome-extension` install — user explicitly asked for manual. Document the one-liner instead (see step 6).

### 4. MODIFY `dot_config/shell/54_macos_apps.sh.tmpl`

Add a one-line cross-reference comment near the top header (within the existing comment block, no behaviour change):

```
# Linux counterpart: dot_config/shell/56_linux_apps.sh.tmpl (same verb names,
# different backend — gtk-launch + pkill -TERM + optional GNOME window-calls
# extension). Verbs are cross-platform by design.
```

### 5. MODIFY `docs/shells/aliases.md`

Add 7 rows mirroring the existing macOS rows at lines 631–637, marking as **Linux-only**. Single-line each, citing `dot_config/shell/56_linux_apps.sh.tmpl`. Also add a `tv linux-apps` row near line 449. Per CLAUDE.md cross-file maintenance rule.

### 6. MODIFY `docs/playbooks/linux-gui-apps.md`

Append a new section "**Controlling installed apps from the shell**" covering:

- The 7 `app-*` helpers + `tv linux-apps` channel
- Override file path + syntax with the user's 5 apps as a copy-paste starter
- **`window-calls` manual install** one-liner: `gnome-extensions install ~/Downloads/window-calls@domandoman.xyz.zip && gnome-extensions enable window-calls@domandoman.xyz` (note: needs Wayland session **logout** for activation; `Alt+F2 r` only works on X11)
- Coverage matrix (the table from this plan's "Achievable verb coverage" section)
- Known limits: focus, hide, responsiveness

### 7. MODIFY `backlog/linux-desktop-app-control.md`

Update status from "P? deferred — evaluation only" to "**P2 implemented (partial coverage by design)**". Replace the theoretical option matrix with empirical findings. Keep the references list. Add a note that option A (gapplication-only) is **dead** — superseded by gtk-launch + pkill + optional extension.

### 8. NEW `pitfalls/linux-app-control-appimage-runtime-path.md`

Symptom-titled. Body: "`pkill -f /home/$USER/Applications/foo.AppImage` succeeds but the app keeps running." Root cause: AppImage mounts itself via FUSE at `/tmp/.mount_<hash>/<binary>`; the AppImage path matches only the launcher/binfmt-bypass wrappers, not the actual process. Fix: match on the basename of the inner binary (`/\.mount_.+/<name>($| )`) or use `StartupWMClass`-derived process name.

### 9. NEW `pitfalls/linux-app-control-gapplication-zero-coverage.md`

Symptom: "`gapplication list-apps` only shows GNOME core apps; my Electron/AppImage/Snap/Flatpak apps are missing." Root cause: gapplication enumerates apps with `DBusActivatable=true` in `.desktop` files; almost no third-party app sets this. Fix: don't rely on gapplication for third-party app control on Ubuntu Desktop — use `gtk-launch <desktop-id>` (works on any `.desktop` file) and pgrep/pkill on the runtime binary path or `StartupWMClass`-derived process name. Empirical: 13 apps total on a daily-driver Ubuntu 24.04 Wayland session; zero of 5 user-installed daily apps.

### 10. MODIFY `CLAUDE.md` — cross-file rule

Add row to the "Cross-file maintenance rules" table:

```
| `dot_config/shell/54_macos_apps.sh.tmpl` (macOS app-* helpers) / `dot_config/shell/56_linux_apps.sh.tmpl` (Linux counterpart) / `dot_config/television/cable/mac-apps.toml.tmpl` / `dot_config/television/cable/linux-apps.toml.tmpl` | Both shell helpers MUST expose the SAME public function names (`appquit` / `applaunch` / `appactivate` / `apprestart` / `apprunning` / `applist` / `appresponsive`) so users get cross-platform muscle memory. Backends diverge by necessity (Apple Events vs gtk-launch + pkill). When adding a new verb to one side, decide upfront whether it can be implemented on the other or document the gap in `backlog/linux-desktop-app-control.md`. | [docs/playbooks/linux-gui-apps.md](docs/playbooks/linux-gui-apps.md) — "Controlling installed apps from the shell" section; both tv channel files must use the same Alt+ keybindings where the verb exists on both sides (Alt+H is mac-only by design — Linux can't hide windows without compositor IPC). |
```

## Critical reused functions / patterns

- `_macapp_guard_darwin` + `_macapp_need_name` style from `54_macos_apps.sh.tmpl:20-35` → mirror as `_linuxapp_guard_linux` + `_linuxapp_need_name`.
- `mac-apps.toml.tmpl:62-72` two-stage preview (info + responsiveness) → mirror for the Linux channel, dropping the responsiveness preview to a stderr note when `playerctl` absent or `--mpris` not registered.
- `applist --pids` AppleScript at `54_macos_apps.sh.tmpl:141-149` outputs `<pid>\t<name>` — Linux mirror outputs the same format from pgrep so tv `display = "{split:\\t:0}  {split:\\t:1}"` and `output = "{split:\\t:1}"` are identical between channels.
- Repo's three-tier override pattern (`~/.shellrc.adhoc`, `~/.shellrc.secrets`) at `dot_zshrc.tmpl` lines that source `.shellrc.adhoc` → the same "source-if-present, never auto-stub" rule applies to `~/.config/shell/linux-apps.conf`.
- `.chezmoiignore.tmpl` — add `~/.config/shell/linux-apps.conf` to ignored paths so chezmoi never tries to manage user's per-host overrides.

## Pre-populated override snippet for this host

Drop into `~/.config/shell/linux-apps.conf` after deploy (or paste into the playbook docs as the canonical example):

```sh
# Zen Browser — AppImage, multiple .desktop entries
linux_app_register Zen \
  --desktop=zen-browser \
  --pkill='\.mount_.+/zen($| )' \
  --wm-class=zen

# Cursor — apt install (running) + AppImage residue (ignore the AppImage one)
linux_app_register Cursor \
  --desktop=cursor \
  --pkill='^/usr/share/cursor/cursor( |$)' \
  --wm-class=Cursor

# Discord — apt install is running; Flatpak is also installed but idle
linux_app_register Discord \
  --desktop=discord \
  --pkill='^/usr/share/discord/Discord( |$)' \
  --wm-class=discord

# Spotify — snap-confined
linux_app_register Spotify \
  --desktop=spotify_spotify \
  --pkill='^/snap/spotify/[^/]+/usr/share/spotify/spotify' \
  --wm-class=spotify \
  --mpris=spotify

# Frpc-Desktop — AppImage, hash in .desktop filename WILL drift on re-download
linux_app_register Frpc-Desktop \
  --desktop=appimagekit_557220393761292184db845cd26816c3-Frpc-Desktop \
  --pkill='\.mount_.+/frpc-desktop($| )' \
  --wm-class=Frpc-Desktop
```

## Verification

End-to-end test plan (run after `chezmoi apply` on this Ubuntu Desktop host):

1. **Source check**: `exec zsh -i -c 'type appquit applaunch appactivate apprestart apprunning applist appresponsive'` → all 7 must be functions.
2. **Override file**: write `~/.config/shell/linux-apps.conf` with the 5 entries above → `source ~/.config/shell/56_linux_apps.sh` → `linux_app_register --list` (debug verb) must show 5 entries.
3. **Auto-derivation**: rename override file → `apprunning Zen` should still find the process via `.desktop` scan + basename heuristic.
4. **Launch**: `applaunch Cursor` (Cursor must already be closed) — Cursor window opens, `apprunning Cursor` exits 0.
5. **Quit**: `appquit Cursor` — window closes cleanly, no "save unsaved files?" prompt lost (Electron handles SIGTERM via `before-quit`). After ≤5s, `apprunning Cursor` exits 1.
6. **Restart**: `apprestart Discord` — Discord quits, polls until gone, relaunches. Notifications/voice reconnect.
7. **Activate**: with Zen already running in the background, `appactivate Zen` brings it to front (Wayland default behaviour of Firefox-based apps); confirm `window-calls`-less path still re-focuses.
8. **Activate-with-extension**: install `window-calls` manually per playbook → re-test step 7 → should now work even when an Electron app's own re-focus is broken.
9. **List**: `applist` outputs at least the 5 registered + any other running .desktop-matching apps. `applist --pids` adds the PID column.
10. **Responsiveness**: `appresponsive Spotify 3` exits 0 when Spotify is playing (MPRIS reachable via `playerctl`). `appresponsive Discord 3` prints stderr "no responsiveness probe configured" and degrades to `apprunning` result.
11. **tv channel**: `tv linux-apps` opens picker showing running apps. Enter activates, Alt+Q quits, Alt+R restarts, Alt+K SIGKILL, Alt+P probes. Picker reloads after destructive actions.
12. **Mac parity**: re-run the same 7-verb test on the user's Mac (they have one) to confirm the cross-platform contract — same function name, same exit-code semantics, only the backend differs.
13. **Ansible role**: `cd dot_ansible && ansible-playbook --check --diff -i inventory site.yml --tags app_control` on the local host → reports playerctl/wmctrl/xdotool would be installed (or skips on already-present).
14. **Docs build**: `uv run mkdocs build --strict` after `docs/shells/aliases.md` + `docs/playbooks/linux-gui-apps.md` edits → no broken links.

## Out of scope (explicitly deferred)

- KDE / Sway / Hyprland compositor backends — open `backlog/linux-desktop-app-control.md` follow-up if a second compositor joins the fleet.
- Automated `window-calls` extension install — needs user consent dialog on GNOME 46, can't be silenced.
- `appresponsive` parity with macOS Apple Events for non-MPRIS apps — no Linux analog exists; documented limitation.
- Cleaning up the user's `.desktop` cruft (4 Zen entries, duplicate Discord apt+Flatpak) — that's user-data territory, not dotfiles territory. Helper handles it gracefully (latest-mtime pick); cleanup is a separate `pitfalls/` note if it bites later.
