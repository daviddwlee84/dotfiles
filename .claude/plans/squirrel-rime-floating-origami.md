# Squirrel (Rime): upgrade ts_hanru_mac + sync config across both Macs

## Context — what's actually going on

| | Local (MacBook Pro) | ts_hanru_mac (Mac mini) |
|---|---|---|
| Squirrel / librime | **1.1.2** / 1.16.0 (= latest cask) | **1.0.3** / 1.13.0 — outdated |
| How installed | official `.pkg` (receipt `im.rime.inputmethod.Squirrel`), installed via the pkg on 2026-04-04, Sparkle self-updated it on 2026-05-31 | official `.pkg` from 2025-05-17. Sparkle checked on 2026-09-24 and showed an update alert that was dismissed |
| `installInputMethod` | **false** → no `*.custom.yaml`, upstream defaults | true → 3 managed files, content identical to the repo (only a trailing newline differs) |
| Schema menu | upstream default: 朙月拼音 / ·简化字 / ·語句流 / 注音 / 倉頡 / 地球 / stroke… | repo `schema_list`: **注音·臺灣正體**, 注音, 朙月拼音 (patched to **臺灣字形**), 地球拼音, 倉頡五代 |
| page_size | 5 | 9 |
| Selection keys | rime-bopomofo 3.0 → **⇧1–⇧0** | rime-bopomofo 2.4 → **Shift+A–J** |

- The 臺灣正體 / 臺灣字形 options on ts_hanru_mac **all come from this repo's managed config** (`.chezmoitemplates/rime/{default,luna_pinyin}.custom.yaml`). Nothing remote-only needs importing.
- The local Mac has no hand-written `*.custom.yaml` (only build/, *.userdb/, installation.yaml, user.yaml), so turning on chezmoi there overwrites nothing. Userdb (learned words) and user.yaml stay unmanaged.
- Turning it on locally *does* change the local schema menu to the repo list: 朙月拼音·简化字, 朙月拼音·語句流 and 筆畫 drop out of the menu. Their schema files stay on disk and can be added back to the shared `schema_list` if wanted.
- **Install method needs no change.** The `squirrel-app` cask just installs the same official `Squirrel-1.1.2.pkg`, and the cask is marked `auto_updates`, so `brew upgrade` skips it anyway. Squirrel updates itself through Sparkle. Moving it under brew would gain nothing.
- Remote `user.yaml` has `zh_hans: true`, meaning 簡體 output was toggled at runtime there. That is per-machine state and isn't synced. Toggle it back with Ctrl+` if it's unintended.

User decisions: standardise on ⇧+數字 and pin it with a managed patch; turn on `installInputMethod` locally.

## Steps

1. **Upgrade ts_hanru_mac to 1.1.2.** On that Mac: Squirrel menu → 檢查更新 (Sparkle). The non-GUI fallback is `ssh -t ts_hanru_mac 'brew install --cask --force squirrel-app'`, which needs a sudo password for the pkg installer. Afterwards `installation.yaml` should show `1.1.2` / `1.16.0`, and Shift+A–J changes to ⇧digit automatically.
2. **Pin ⇧-digit selection** in the new shared `.chezmoitemplates/rime/bopomofo.custom.yaml`:
   ```yaml
   patch:
     menu/alternative_select_labels: ['⇧1','⇧2','⇧3','⇧4','⇧5','⇧6','⇧7','⇧8','⇧9','⇧0']
     key_binder/bindings/+:        # append; duplicates 3.0's own rules harmlessly
       - { when: has_menu, accept: Shift+exclam, send: KP_1 }
       # … Shift+at→KP_2 … Shift+parenright→KP_0
   ```
   - Render it through `private_Library/Rime/bopomofo.custom.yaml.tmpl`, plus the Linux `~/.config/ibus/rime/` counterpart if the existing files have one.
   - `bopomofo_tw` does `__include: bopomofo.schema:/`. Check `build/bopomofo_tw.schema.yaml` after deploy, and if the patch isn't inherited, add a matching `bopomofo_tw.custom.yaml`.
   - The shared-template rule means copying it byte-identically to `dotfiles-windows` (not cloned here). I'll flag that in the report.
3. **Turn on locally:** set `installInputMethod = true` in `~/.config/chezmoi/chezmoi.toml:120`, then `chezmoi diff` (expect only new `~/Library/Rime/*.custom.yaml`), then `chezmoi apply`. Ansible skips installs because both .app bundles exist.
4. **Redeploy:** `"/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel" --reload` on both Macs. The remote also needs the new file: its checkout is diverged (`ahead 6, behind 7`, uncommitted edits), so do a manual `chezmoi apply ~/Library/Rime/bopomofo.custom.yaml` after pulling, or `fleet-apply-file`. I won't touch its other local changes.
5. **Small cleanup:** change the cask name in `dot_ansible/roles/input_method/tasks/main.yml:39` and the warning message from `squirrel` to `squirrel-app` (the old name is only a rename alias).
6. **Docs:** in `docs/input_methods/README.md` (+ `.zh-TW`), add the new managed file and a note on selection keys by version, and mention that Squirrel updates through Sparkle (pkg) rather than brew.

## Verification

- Both Macs: `installation.yaml` shows `1.1.2`/`1.16.0`, and `pkgutil --pkg-info im.rime.inputmethod.Squirrel` shows 1.1.2.
- Both: the `build/bopomofo_tw.schema.yaml` menu block has ⇧ labels, `page_size: 9`, no `ABCDEFGHIJ`, and contains `Shift+exclam`. `build/default.yaml` `schema_list` starts with `bopomofo_tw`.
- `diff` the remote `~/Library/Rime/*.custom.yaml` against local.
- Manual check: on each Mac, Ctrl+` shows 注音·臺灣正體 first. Typing ㄧㄡˇ gives 9 ⇧-labelled candidates and Shift+2 picks the 2nd. Terminal starts in ASCII.
