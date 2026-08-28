# lazygit `Ctrl+O` "No clipboard utilities available" / Neovim yank never reaches the system clipboard

**Symptoms** (grep this section):

- lazygit `Ctrl+O` (copy to clipboard) flashes an error and copies nothing:
  ```
  No clipboard utilities available. Please install xsel, xclip, wl-clipboard or Termux:API add-on for termux-clipboard-get/set.
  ```
- **Paired symptom, same root cause:** in Neovim, `yy` / `"+y` / visual-mode
  `y` put nothing on the system clipboard. Paste into another app gets old
  content. `:checkhealth provider.clipboard` reports:
  ```
  clipboard: No clipboard tool found. :help clipboard
  ```
- `x copy` appears to work but only ever uses its OSC 52 `/dev/tty` fallback
  (nothing lands on a GUI paste); `x copy-file FILE` fails outright:
  ```
  x: no file clipboard backend found.
  ```
- Local Ubuntu desktop session (Wayland / `niri`, or an X11 session) — **not**
  over SSH. Over SSH these all work (OSC 52 path).
- CopyQ is installed and its tray icon is running, yet none of lazygit /
  Neovim / `x` can see a clipboard.

**First seen**: 2026-08
**Affects**: any `ubuntu_desktop` host before this fix; lazygit (all versions),
Neovim (all versions — clipboard support is a runtime binary probe, there is
no `+clipboard` build flag), `dot_dotfiles/bin/executable_x`.
**Status**: fixed — `dot_ansible/roles/gui_apps_linux` now installs
`wl-clipboard` + `xclip` + `xsel`; `dot_config/lazygit/config.yml` routes
`Ctrl+O` through `x copy`.

## Root cause

No ansible role installed a clipboard CLI. `gui_apps_linux` installed **CopyQ**
— but CopyQ is a clipboard-*history manager*. Its `copyq` CLI
(`copyq copy` / `copyq clipboard`) is a bespoke interface; it is **not** one
of the binaries the three consumers probe for:

| Consumer | What it shells out to |
|---|---|
| lazygit `Ctrl+O` | vendored `atotto/clipboard`: `$WAYLAND_DISPLAY` set → `wl-copy`; else `xclip`; else `xsel`; else `termux-clipboard-set`. None found → the error above. |
| Neovim `clipboard=unnamedplus` | built-in provider auto-detect: `pbcopy` (macOS) → `wl-copy`/`wl-paste` → `xclip` → `xsel` → … . None found → yank is a silent no-op (`unnamedplus` still "works", it just writes to a register with no OS bridge). |
| `~/.dotfiles/bin/x` | `copy_backend()`: `clip.exe` → `pbcopy` → `wl-copy` (needs `$WAYLAND_DISPLAY`) → `xclip`/`xsel` (need `$DISPLAY`) → **OSC 52 to `/dev/tty`**. `copy_file_backend()` has *no* OSC 52 fallback. |

`dot_config/nvim/lua/config/options.lua` only overrides to the OSC 52 provider
when `SSH_CONNECTION` / `SSH_TTY` is set — so locally it depends entirely on a
provider binary existing. `docs/tools/clipboard.md` already *assumed*
`wl-copy` / `xclip` were present ("default provider …") with no install story.

## Workaround / fix

Immediate, by hand:

```sh
sudo apt install wl-clipboard xclip xsel
```

In this repo (already applied):

- `dot_ansible/roles/gui_apps_linux/tasks/main.yml` — task
  **"Install clipboard CLIs (wl-clipboard, xclip, xsel)"**, next to the CopyQ
  / app-control block, same `os_family == 'Debian'` + `target_architecture !=
  'armv7l'` + `tags: [sudo]` guard. Runs on `ubuntu_desktop` only (via the
  `gui_apps` tag in `run_onchange_after_20_ansible_roles.sh.tmpl`).
- `dot_config/lazygit/config.yml` — adds:
  ```yaml
  os:
    copyToClipboardCmd: "printf '%s' {{text}} | x copy"
  ```
  so `Ctrl+O` uses `x`'s backend chain: `wl-copy`/`xclip` locally, OSC 52 over
  SSH (lazygit's native path would target the *remote's* clipboard). Safe
  because lazygit shell-quotes `{{text}}` via `c.Cmd.Quote` before
  substitution (`OSCommand.CopyToClipboard`).

Server profiles deliberately get **none** of this — headless has no
clipboard; OSC 52 (`set-clipboard on` + `x`'s `/dev/tty` fallback) is the
whole story there.

## Diagnostics

```sh
echo "$XDG_SESSION_TYPE $WAYLAND_DISPLAY $DISPLAY"   # wayland / x11?
command -v wl-copy xclip xsel                        # any backend at all?
printf hi | wl-copy && wl-paste                      # Wayland round-trip
printf hi | xclip -selection clipboard && xclip -selection clipboard -o
nvim --headless -c 'checkhealth provider.clipboard' -c 'q'
```

## Prevention

Rule (see `AGENTS.md` cross-file table): a new tool installed by any
mechanism gets a row in `docs/this_repo/tool-managers.md` § Tool index. The
clipboard CLIs are now listed there and in
`docs/playbooks/linux-gui-apps.md`. Neovim / lazygit / `x` all silently
degrade without them, so the install lives with CopyQ in `gui_apps_linux`
rather than being assumed.

## Related

- [`docs/tools/clipboard.md`](../docs/tools/clipboard.md) — the 4-layer OSC 52
  chain (terminal / tmux / Neovim / `x`) + the lazygit `Ctrl+O` note.
- [`docs/playbooks/linux-gui-apps.md`](../docs/playbooks/linux-gui-apps.md) —
  inventory row.
- `dot_config/nvim/lua/config/options.lua` — the `SSH_CONNECTION` gate on the
  OSC 52 provider.
- atotto/clipboard selection order: `WAYLAND_DISPLAY` → wl-clipboard → xclip →
  xsel (checked with `exec.LookPath`).
