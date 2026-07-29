# Zen's launcher entry dangles again right after you launch it once — and every `chezmoi apply` re-downloads 125 MB

**Symptoms** (grep this section):

- A `chezmoi apply` installs Zen correctly, the launcher entry works — then you
  launch the browser **once** and the entry disappears from the GNOME/KDE menu
  again. `applaunch Zen` goes dead. `appquit Zen` / `appactivate Zen` still work
  (they key off `--pkill` / `--wm-class`, not the `.desktop`).
- `~/Applications/zen.AppImage` is gone; in its place:
  ```console
  $ ls ~/Applications/
  zen_c97bf8b89d9e9fdba22107dcbef2a835.AppImage
  ```
- `~/.local/share/applications/zen-browser.desktop` still says
  `TryExec=/home/you/Applications/zen.AppImage`, which no longer exists — so
  the entry is **hidden**, not broken-on-click, and nothing logs an error.
- Two Zen entries in the launcher: ours plus
  `appimagekit_<hash>-Zen_Browser.desktop`.
- Every subsequent `chezmoi apply` re-downloads the full 125 MB AppImage,
  because the install guard looks for the stable filename that no longer
  exists. Then you launch it, it gets renamed, and the next apply downloads it
  again — forever.
- `pgrep -af zen` shows the process was started through AppImageLauncher even
  though you launched the AppImage directly:
  ```
  /opt/appimagelauncher.AppDir/usr/lib/x86_64-linux-gnu/appimagelauncher/binfmt-bypass /home/you/Applications/zen_c97bf8b8….AppImage
  ```

## Root cause

AppImageLauncher hooks **execution itself** via `binfmt_misc` (the
`binfmt-bypass` helper above), not merely the `~/Applications` directory watch.
So "we write our own `.desktop` entry in the ansible task, therefore the
first-run integration modal never matters" — the convention this repo used to
document — is simply false. Launching the AppImage by any route hands control
to AppImageLauncher first.

On integration it **moves the file into the integration directory and appends
an md5 checksum to the filename**. That is upstream behaviour by design: the
maintainer added the checksum so AIL can recognise an already-integrated
AppImage ([#7](https://github.com/TheAssassin/AppImageLauncher/issues/7),
[#547](https://github.com/TheAssassin/AppImageLauncher/issues/547)).

Two things that are easy to get wrong when diagnosing this:

- **The daemon is not the culprit.** `appimagelauncherd` watching
  `~/Applications` only writes the `appimagekit_*.desktop` entry — measured: it
  left the filename untouched. The rename comes from the *integrate* action.
- **Headless execution does not reproduce it.**
  `zen.AppImage --headless --screenshot …` runs without triggering the modal, so
  you cannot reproduce or test this with a scripted launch. Use
  `ail-cli integrate` instead, which drives the same code path non-interactively.

### `ask_to_move = false` does NOT fix it (measured)

The obvious-looking lever in `~/.config/appimagelauncher.cfg` does not work. It
suppresses the *dialog*, not the *move*. Measured on this repo's Ubuntu 24.04
box with a hardlink of the real AppImage, using `ail-cli integrate` as a
non-interactive stand-in for the modal:

```console
$ grep ask_to_move ~/.config/appimagelauncher.cfg
ask_to_move = true
$ ail-cli integrate /tmp/ailtest1.AppImage
Processing /tmp/ailtest1.AppImage
Moving AppImage to integration directory          # <-- moved + hash-renamed
$ ls ~/Applications | grep ailtest
ailtest1_c97bf8b89d9e9fdba22107dcbef2a835.AppImage

$ sed -i 's/^ask_to_move = true/ask_to_move = false/' ~/.config/appimagelauncher.cfg
$ ail-cli integrate /tmp/ailtest2.AppImage
Processing /tmp/ailtest2.AppImage
Moving AppImage to integration directory          # <-- SAME. still moved.
$ ls ~/Applications | grep ailtest
ailtest2_c97bf8b89d9e9fdba22107dcbef2a835.AppImage
```

So do not manage `appimagelauncher.cfg` hoping to pin the filename. It was
evaluated and rejected.

Relocating the AppImage outside `~/Applications` does not help either — because
the hook is on exec, a file elsewhere just gets the *"move into
~/Applications?"* treatment instead.

## Fix

Stop depending on the filename. In
`dot_ansible/roles/gui_apps_linux/tasks/main.yml`:

1. **Guard with a glob, not a fixed path** — `ansible.builtin.find` over
   `~/Applications` with `patterns: 'zen*.AppImage'`. A renamed (integrated)
   AppImage still counts as installed, which is what kills the re-download loop.
   Network calls (release metadata + download) are gated on `matched == 0`, so a
   steady-state apply touches the network zero times.
2. **Resolve the current path into a fact** (`zen_appimage_path` = newest match
   by `mtime`) and warn when more than one `zen*.AppImage` exists rather than
   silently picking.
3. **Re-assert desktop integration on every apply**, not only on download —
   the `.desktop` is rewritten from `zen_appimage_path` each run, so a rename
   self-heals on the next `chezmoi apply`. `copy` is content-idempotent, so this
   reports `changed` only when the path actually moved.
4. **Remove AIL's parallel entry** so `zen-browser.desktop` stays the single
   authority that `linux_app_register Zen --desktop=zen-browser` can rely on.
   `ail-cli deintegrate` + delete any `appimagekit_*Zen*.desktop`. Both must be
   `failed_when: false` — `ail-cli` ships only with the system AppImageLauncher
   package, never with **Lite** (noRoot), where a bare `command` would abort the
   play with "Unable to find executable".

Accepted trade-off: launching Zen still re-integrates and re-renames, and the
next apply cleans it up again. The state churns; it is never *broken*. Pinning
the filename is not achievable (see above), so self-healing is the design.

## Generalisable lesson

For any tool that a **daemon or shell hook can rename or relocate behind your
back**, an install guard keyed to an exact path is a re-download loop waiting to
happen, and any file you generate that embeds that path will dangle. Key the
guard on a glob, store the resolved path in a fact, and re-assert the derived
files every run instead of only at install time.

Related: [`ansible-folded-scalar-regex-empty-url-silent-skip.md`](ansible-folded-scalar-regex-empty-url-silent-skip.md)
— the previous Zen failure, with the same end symptom (a `.desktop` whose
`TryExec` dangles and a launcher entry that hides itself) reached by a
completely different route.
