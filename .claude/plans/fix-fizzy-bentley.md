# Make the Zen AppImage install survive AppImageLauncher

## Context

Earlier in this session we fixed three bugs in the `gui_apps_linux` Zen block (folded-scalar regex → empty URL, `is succeeded` passing for skipped tasks, `retries:` without `until:`) and installed Zen 1.21.9b. That worked — but the moment the browser was launched, **AppImageLauncher renamed the managed file**:

```
~/Applications/zen.AppImage  →  ~/Applications/zen_c97bf8b89d9e9fdba22107dcbef2a835.AppImage
```

Two concrete harms, both live right now:

1. `zen-browser.desktop`'s `Exec=`/`TryExec=` dangle again → the launcher entry is hidden and `applaunch Zen` (registered `--desktop=zen-browser` in `~/.config/shell/linux-apps.conf`) is dead.
2. The role's guard only looks at the exact stable path, so the next `chezmoi apply` sees "not installed" and **re-downloads 125 MB** — then the user integrates again, forever.

This is also the true origin of the 2025 orphan `zen-x86_64_fe71259e….AppImage`, which we had assumed was a manual download.

The rename is [upstream by design](https://github.com/TheAssassin/AppImageLauncher/issues/547) — AppImageLauncher appends an md5-of-path checksum so it can recognise already-integrated AppImages. It intercepts at **exec time** via `binfmt-bypass` (visible in `pgrep -af zen`), not only by watching `~/Applications`, so relocating the file elsewhere would just trade the rename for a "move into ~/Applications?" prompt.

**Therefore the fix is to stop the role depending on a fixed filename**, rather than to fight AppImageLauncher. The repo's documented convention ("we write our own `.desktop` in the same task, so the integration modal never matters") rests on a false premise and must be corrected too.

## Design

The role stops treating `~/Applications/zen.AppImage` as a constant and instead treats **"whichever `zen*.AppImage` is in `~/Applications`"** as the install. Desktop integration is re-asserted on *every* apply rather than only on download, so a rename self-heals on the next `chezmoi apply`.

Per the user's decisions: our `zen-browser.desktop` stays the single authority (the role deintegrates AppImageLauncher's parallel entry), and `ask_to_move = false` is tested empirically before we commit to managing AppImageLauncher's config.

## Changes

### 1. `dot_ansible/roles/gui_apps_linux/tasks/main.yml` — Zen block (currently ~L767–890)

- **Replace the exact-path `stat` guard** with `ansible.builtin.find` over `~/Applications`, `patterns: 'zen*.AppImage'`, `file_type: file`. Download only when `matched == 0`.
- **Set a `zen_appimage_path` fact** = newest match by `mtime` (or the freshly downloaded `~/Applications/zen.AppImage`). Emit a `debug` warning when `matched > 1` so accumulating copies are visible rather than silent.
- **Move icon + `.desktop` + `update-desktop-database` out of the download-gated block** so they run every apply, with `Exec=`/`TryExec=` built from `zen_appimage_path`. This is what makes a rename self-healing. Gate the icon download on the icon file being absent instead of on the download result.
- **Deintegrate AppImageLauncher's copy**: when `ail-cli` exists and an `appimagekit_*Zen*.desktop` is present, run `ail-cli deintegrate <zen_appimage_path>`, then remove any leftover `appimagekit_*Zen_Browser.desktop`. All `failed_when: false` — `ail-cli` is absent in AppImageLauncher **Lite** / noRoot mode, and this must stay non-fatal there.
- Keep the three fixes already made (`equalto` asset match, the no-match `debug` warning, `is not skipped` guards, real `until:` retries).

Nothing in this block gains `become:`/`tags: [sudo]` — it stays fully user-level per the existing noRoot contract.

### 2. `ask_to_move` — measure first, then decide

Before writing any config: set `ask_to_move = false` in `~/.config/appimagelauncher.cfg`, rename the AppImage back to `~/Applications/zen.AppImage`, launch it once, and check whether it is renamed again.

- **If the rename stops** → manage the file as `dot_config/modify_appimagelauncher.cfg`. It must be `modify_`, not a plain file: `AppImageLauncherSettings` (a foreign writer) also owns this file, which is exactly the case `docs/tools/chezmoi-prefixes.md` reserves the prefix for. Preserve unknown keys; set only `ask_to_move`.
- **If it still renames** → drop this entirely. The glob-based role change already covers it; do not ship an unverified third-party config tweak.

Either way the role change stands on its own — this is belt-and-braces, not the fix.

### 3. Docs (required by the CLAUDE.md cross-file table)

- `docs/playbooks/linux-gui-apps.md` **and** `.zh-TW`: update the Zen inventory row (path is now "any `~/Applications/zen*.AppImage`"), and correct convention point 1 in *AppImage + AppImageLauncher — the catch-all* — "stable filename" is **not** something we can rely on once AppImageLauncher integrates.
- `docs/tools/appimage.md` **and** `.zh-TW`: fix the *Zen Browser (installed automatically)* recipe (L93–95). It currently claims writing our own `.desktop` means "no need to run the AppImage once to trigger AppImageLauncher's first-run integration prompt" — false. Also fix the upgrade instruction, which tells you to delete a path that may not exist.
- **New pitfall** `pitfalls/appimagelauncher-renames-managed-appimage.md`, titled by symptom (launcher entry dangles again *after launching Zen once*; apply re-downloads 125 MB every time). Cross-link from `pitfalls/ansible-folded-scalar-regex-empty-url-silent-skip.md`, which currently implies the stable path is dependable. Add the index row in `pitfalls/README.md`.

## Verification

1. **Role runs correctly against the current broken state** — extract the Zen block verbatim into a standalone play (the technique used earlier in this session: copy L767→pre-Antigravity, indent 2, add `gather_facts: true` + `target_architecture`) and run it. Assert: **no download** (the existing `zen_c97bf8b8….AppImage` is found), and `zen-browser.desktop`'s `TryExec` now resolves to an executable file.
2. **Regression simulation** — rename the AppImage by hand to a different `zen_<something>.AppImage`, re-run, and confirm the `.desktop` self-heals with no re-download. This is the actual bug; it must be reproduced and shown fixed.
3. **Single launcher entry** — `ls ~/.local/share/applications/ | grep -i zen` shows only `zen-browser.desktop`.
4. **`applaunch Zen` actually launches**, and `appquit`/`appactivate` still match (they key off `--pkill`/`--wm-class`, which are unaffected).
5. `ANSIBLE_CONFIG=./ansible.cfg ansible-playbook playbooks/linux.yml --syntax-check`.
6. `uv run mkdocs build --strict` — must stay at **174 warnings**, the measured pre-existing baseline (tracked in `backlog/mkdocs-anchor-drift.md`). Any increase is mine and must be fixed.
7. Confirm the deintegration path is a no-op, not an error, when `ail-cli` is missing (simulate with `PATH` lacking it).
