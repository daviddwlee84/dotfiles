# Zen `.desktop` entry exists but `~/Applications/zen.AppImage` was never downloaded — ansible installed nothing and reported success

**Symptoms** (grep this section):

- `~/.local/share/applications/zen-browser.desktop` exists with a **recent**
  mtime, but the file it points at does not:
  ```console
  $ stat ~/Applications/zen.AppImage
  stat: cannot statx '/home/you/Applications/zen.AppImage': No such file or directory
  ```
- Zen is missing from the GNOME/KDE launcher even though the `.desktop` is
  there — because `TryExec=` resolves to a nonexistent path, so the entry is
  *hidden* rather than broken-on-click.
- `applaunch Zen` (from `dot_config/shell/56_linux_apps.sh.tmpl`, registered
  with `--desktop=zen-browser`) does nothing. `appquit Zen` / `appactivate Zen`
  still work, because those match on `--pkill` / `--wm-class`, not the
  `.desktop`.
- The browser you're actually running is some **unmanaged** leftover, e.g.
  `~/Applications/zen-x86_64_fe71259eecb23542da2f5f4364ef8539.AppImage`
  (AppImageLauncher's hash-suffixed integration copy), pinned at whatever
  version you first downloaded by hand.
- Websites start rejecting the browser: Twitch's `Log in to Twitch` →
  `Your browser is not currently supported`, because the Gecko base is years
  old. Confirm with:
  ```console
  $ ~/Applications/<the-appimage> --appimage-extract application.ini
  $ grep -E '^(Version|BuildID)=' squashfs-root/application.ini
  Version=1.11.5b
  BuildID=20250419054652
  ```
- `ansible-playbook ... --tags gui_apps` reports **`failed=0`** and prints no
  warning. `--syntax-check` passes. The `rescue:` block never fires.

## Root cause — two independent bugs that only bite together

### 1. `\\.` inside a YAML **folded scalar** is not an escape

The asset picker in `dot_ansible/roles/gui_apps_linux/tasks/main.yml` was:

```yaml
zen_appimage_url: >-
  {{ (zen_release.json.assets
      | selectattr('name', 'match', '^zen-' + target_architecture + '\\.AppImage$')
      ...
```

In a folded (`>-`) or plain scalar, YAML performs **no escape processing** —
both backslashes survive into the Jinja string literal, and the compiled regex
becomes `^zen-x86_64\\.AppImage$`, i.e. *literal backslash followed by any
character*. It can never match `zen-x86_64.AppImage`.

In a **double-quoted** scalar YAML *does* process `\\` → `\`, so the identical
expression works. Demonstrated side by side:

```yaml
- set_fact:
    pat_folded: >-
      {{ '^zen-' + target_architecture + '\\.AppImage$' }}
    res_folded: >-
      {{ names | select('match', '^zen-' + target_architecture + '\\.AppImage$') | list }}
    pat_dq: "{{ '^zen-' + target_architecture + '\\.AppImage$' }}"
    res_dq: "{{ names | select('match', '^zen-' + target_architecture + '\\.AppImage$') | list }}"
```
```
pat_folded=[^zen-x86_64\\.AppImage$]  res_folded=[]
pat_dq    =[^zen-x86_64\.AppImage$]   res_dq=['zen-x86_64.AppImage']
```

`| default('')` then swallowed the empty `first`, and `when: zen_appimage_url |
length > 0` skipped the download **without failing**.

This is the mirror image of
[`ansible-when-regex-replace-backslash-strip.md`](ansible-when-regex-replace-backslash-strip.md),
where `when: >-` needs the *doubled* form. The two folded-scalar contexts
disagree, which is exactly why neither is memorable — **stop hand-escaping
regexes in ansible and use a non-regex test when the value is exact.**

### 2. A *skipped* task passes `is succeeded`

The follow-up tasks were gated on:

```yaml
when: zen_appimage_dl is defined and zen_appimage_dl is succeeded
```

`succeeded` only asserts "not failed". A skipped task is not failed, so **every
downstream task ran anyway** — writing the icon, the `.desktop` entry and
`update-desktop-database` for an AppImage that had never been fetched. That is
what produced a fresh-looking `.desktop` pointing into the void, and what kept
the failure completely silent across many `chezmoi apply` runs.

### 3. (Bonus) `retries:`/`delay:` without `until:` are no-ops

Both `get_url` tasks carried `retries: 3` / `delay: 5` but no `until:`, so
ansible ignored them entirely — the "3 retries" for a 125 MB download over a
GFW-region link never existed. The Cursor block a few hundred lines up in the
same file has it right (`until: cursor_dl is succeeded`).

## Fix

All three are fixed in `gui_apps_linux/tasks/main.yml`:

- **Match the asset name literally**, no regex, no escaping:
  `selectattr('name', 'equalto', 'zen-' + target_architecture + '.AppImage')`
- **Fail loudly, not silently** — a `debug` task fires when
  `zen_appimage_url | length == 0`, naming the expected asset and the upstream
  releases URL, so an upstream rename is visible in the apply log.
- **Gate on not-skipped**, not just not-failed:
  ```yaml
  when:
    - zen_appimage_dl is defined
    - zen_appimage_dl is not skipped
    - zen_appimage_dl is succeeded
  ```
- Added `until: <reg> is succeeded` to both `get_url` tasks so the retries work.

## Recovery on an already-broken machine

Re-running the role is enough — the install guard finds no `zen*.AppImage` in
`~/Applications` and installs the current release:

```console
$ just apply-tags gui_apps          # or: just apply-ubuntu_desktop
$ ~/Applications/zen.AppImage --appimage-extract platform.ini
$ grep Milestone squashfs-root/platform.ini
Milestone=153.0
```

Then retire the unmanaged copy — **quit Zen first**, its AppImage is
squashfuse-mounted while running and deleting it mid-flight breaks the session:

```console
$ pkill -f '\.mount_.+/zen($| )'
$ rm ~/Applications/zen-x86_64_*.AppImage
$ rm ~/.local/share/applications/appimagekit_*Zen_Browser.desktop
$ update-desktop-database ~/.local/share/applications
```

The profile lives in `~/.zen/` and is shared by both copies, so bookmarks /
tabs / extensions carry over untouched. Note the jump is one-way: once Zen
1.21 (Firefox 153) opens that profile it is upgraded, and the old 1.11
(Firefox 137) binary will refuse to start against it — which is another reason
to delete the stale AppImage rather than keep it "just in case".

## Generalisable lessons

- **Never hand-escape a regex inside a YAML folded scalar.** Prefer `equalto` /
  `in` / `search` on an unescaped substring. If a real regex is unavoidable,
  put it in a double-quoted scalar *and* print it once with `debug` to confirm
  the backslash count.
- **`is succeeded` is not "it ran".** For any task chain where the producer can
  be skipped by a `when:`, gate consumers on `is not skipped` (or `is changed`).
  This applies to every `register` + `when: ... is succeeded` pair in the repo.
- **A `rescue:` block does not catch a no-op.** Resilient ansible has to be
  paired with an explicit "nothing matched" warning, otherwise `failed=0` means
  "nothing broke", not "it worked".
- Related: [`ansible-when-regex-replace-backslash-strip.md`](ansible-when-regex-replace-backslash-strip.md),
  [`uv-tool-install-creates-guard-misses-executables-from.md`](uv-tool-install-creates-guard-misses-executables-from.md)
  (same shape: an install guard short-circuits and the missing artifact is only
  noticed much later).
- **Sequel:** the stable filename this fix relied on turned out not to be stable
  at all — AppImageLauncher renames it on first launch, producing the *same* end
  symptom (dangling `TryExec`, hidden launcher entry) by a different route, plus
  a 125 MB re-download every apply. See
  [`appimagelauncher-renames-managed-appimage.md`](appimagelauncher-renames-managed-appimage.md).
