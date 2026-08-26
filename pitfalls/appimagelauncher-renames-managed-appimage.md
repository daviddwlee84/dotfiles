# Zen has two launcher icons, or its managed launcher disappears after login

**Symptoms** (grep this section):

- GNOME shows both `zen-browser.desktop` and an
  `appimagekit_<hash>-Zen_Browser.desktop` entry.
- Deleting the `appimagekit_*` entry works only until the next login;
  `appimagelauncherd` creates it again.
- An older setup loses Zen from search after first launch because
  `TryExec=~/Applications/zen.AppImage` dangles after AppImageLauncher renames
  the file to `zen_<md5>.AppImage`.
- A fixed-path install outside `~/Applications` still shows an integration
  prompt when executed normally.

## Root cause

AppImageLauncher has two independent integration paths:

1. `appimagelauncherd` watches `~/Applications` and can recreate
   `appimagekit_*.desktop` entries at login.
2. Its `binfmt_misc` interpreter intercepts AppImage **execution itself**. On
   integration it moves the file to the integration directory and appends an
   md5 checksum. Therefore writing a second `.desktop` file, or merely moving
   the AppImage outside the watched directory, does not opt the app out.

`ask_to_move = false` only suppresses the question; it does not disable the
move. This was measured with `ail-cli integrate`, and is not a stable-file-name
control.

The missing piece is AppImageLauncher's supported per-process escape hatch:
its binfmt interpreter checks `APPIMAGELAUNCHER_DISABLE` and launches the
AppImage directly when the variable is set. See the upstream
[`APPIMAGELAUNCHER_DISABLE` discussion](https://github.com/TheAssassin/AppImageLauncher/discussions/679).

## Fix

The `gui_apps_linux` role now gives Zen one owner and one desktop ID:

1. Migrate the newest legacy `~/Applications/zen*.AppImage` once to the fixed
   path `~/.local/opt/zen/zen.AppImage` (outside AIL's watched directory).
2. Write only `~/.local/share/applications/zen-browser.desktop`.
3. Launch it as
   `/usr/bin/env APPIMAGELAUNCHER_DISABLE=1 ~/.local/opt/zen/zen.AppImage %U`,
   preventing execution-time reintegration as well as login-time discovery.
4. Remove stale `appimagekit_*Zen*.desktop` files and their generated icons.
5. Migrate the obsolete GNOME favorite ID `ZenBrowser.desktop` to the stable
   `zen-browser.desktop` ID without otherwise changing the favorites list.

This reaches a genuinely steady state: the daemon cannot see the managed
AppImage and the launcher bypasses the binfmt integration path. A later login
does not recreate a second icon, and repeated role runs are idempotent.

## Debugging desktop-entry identity

The launcher groups and shadows applications by **desktop file ID**, not only
by the visible `Name=`. First inventory all candidate files, then inspect their
identity and ownership:

```sh
find ~/.local/share/applications /usr/share/applications \
  /var/lib/snapd/desktop/applications -maxdepth 1 -type f -name '*.desktop' \
  -print 2>/dev/null | sort
rg -il '^(Name=.*(Zen|Clash)|Exec=.*(zen|clash))' \
  ~/.local/share/applications /usr/share/applications 2>/dev/null
rg -n '^(Name|Exec|TryExec|Icon|NoDisplay|StartupWMClass)=' <file.desktop>
dpkg -S /usr/share/applications/'Clash Verge.desktop'
journalctl --user -u appimagelauncherd --since today
```

Two different basenames mean two desktop IDs and normally two icons. The same
basename at user and system scope means the user entry shadows the system one.
`NoDisplay=true` usually marks a protocol handler and should not be mistaken
for a visible duplicate. A missing `TryExec` target makes an entry disappear
rather than producing an on-click error.

## Generalisable lesson

For an app managed by a desktop-integration daemon, deleting generated output
is not a fix while the daemon can rediscover the input. Establish one owner,
put its executable outside watched directories, use the tool's explicit opt-out
when execution is intercepted, and keep one stable desktop ID.

Related: [`ansible-folded-scalar-regex-empty-url-silent-skip.md`](ansible-folded-scalar-regex-empty-url-silent-skip.md)
— the earlier Zen failure had the same visible result (a hidden launcher caused
by dangling `TryExec`) but a different Ansible templating cause.
