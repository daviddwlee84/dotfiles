# Plan: install Linux clipboard CLIs (fix lazygit Ctrl+O + nvim yank)

## Context

On this Ubuntu desktop (Wayland / `niri`), lazygit `Ctrl+O` fails with
`No clipboard utilities available. Please install xsel, xclip, wl-clipboard …`
and Neovim yanks (`clipboard = "unnamedplus"`) silently never reach the
system clipboard. Same root cause for both.

**Root cause:** no ansible role installs `wl-clipboard`, `xclip`, or `xsel`.
`gui_apps_linux` installs CopyQ (a clipboard *manager* daemon — its `copyq`
CLI is not what lazygit/nvim/`x` shell out to) plus `playerctl`/`wmctrl`/
`xdotool`, but never the low-level clipboard binaries. Consequences on a
local Linux desktop:

- **lazygit** — its vendored `atotto/clipboard` looks for `wl-clipboard`
  (when `WAYLAND_DISPLAY` is set) → `xclip` → `xsel`; none exist → error.
- **Neovim** — `dot_config/nvim/lua/config/options.lua` only overrides to
  OSC 52 when `SSH_CONNECTION`/`SSH_TTY` is set. Locally it relies on the
  built-in provider auto-detect (`wl-copy` / `xclip` / `xsel`) → no binary
  → yank is a silent no-op.
- **`x` CLI** (`dot_dotfiles/bin/executable_x`) — `copy_backend` /
  `paste_backend` fall through to the OSC 52-only path locally, and
  `x copy-file` has *no* backend (needs `wl-copy` or `xclip`).

The repo's own `docs/tools/clipboard.md` already *assumes* `wl-copy`/`xclip`
exist locally ("default provider: `pbcopy` / `wl-copy` / `xclip`") with no
install story behind it.

**Intended outcome:** `chezmoi apply` on an Ubuntu desktop installs
`wl-clipboard` + `xclip` + `xsel`, after which Neovim yank and
`x copy` / `x copy-file` work natively, and lazygit `Ctrl+O` is routed
through `x copy` (works local *and* over SSH). Docs stop implying a
provider that isn't installed.

## Approach

### 1. Install the clipboard CLIs — `dot_ansible/roles/gui_apps_linux/tasks/main.yml`

Add one apt task next to the existing CopyQ / app-control block
(after ~line 1215), same guard as its neighbours
(`os_family == 'Debian'`, `target_architecture != 'armv7l'`,
`become: true`, `tags: [sudo]`). Install **`wl-clipboard` + `xclip` +
`xsel`** (xsel included to match lazygit's error text and `x`'s full
backend list):

```yaml
# =============================================================================
# Clipboard CLIs — the low-level binaries lazygit (Ctrl+O), Neovim
# (clipboard=unnamedplus), and `~/.dotfiles/bin/x` shell out to. CopyQ above
# is a history *manager*, not one of these.
#
#   - wl-clipboard  wl-copy/wl-paste — native Wayland (niri sessions). Both
#                   nvim's provider and atotto/clipboard (lazygit) prefer it
#                   when $WAYLAND_DISPLAY is set.
#   - xclip         X11 / XWayland fallback (also `x paste` / nvim on X11).
#   - xsel          named in lazygit's own error text; `x`'s last non-OSC-52
#                   backend. Redundant with xclip for lazygit but ~40KB.
#
# Server profiles deliberately don't get these — headless has no clipboard;
# OSC 52 (tmux `set-clipboard on` + `x`'s /dev/tty fallback) is the answer
# there.
# =============================================================================

- name: Install clipboard CLIs (wl-clipboard, xclip, xsel)
  when:
    - ansible_facts['os_family'] == 'Debian'
    - target_architecture != 'armv7l'
  become: true
  tags: [sudo]
  ansible.builtin.apt:
    name:
      - wl-clipboard
      - xclip
      - xsel
    state: present
    update_cache: false
```

No change to `dot_config/nvim/**` — once a backend binary exists it works,
and Neovim's SSH→OSC 52 branch is unaffected. `x` needs no change; it
already probes `wl-copy` → `xclip` → `xsel` → OSC 52.

### 2. Route lazygit `Ctrl+O` through `x` — `dot_config/lazygit/config.yml`

Add an `os:` block:

```yaml
os:
  copyToClipboardCmd: printf '%s' {{text}} | x copy
```

`Ctrl+O` then uses `x`'s backend chain: `wl-copy`/`xclip` locally, OSC 52
(`/dev/tty`, tmux-passthrough-wrapped) over SSH — so it copies to the
*local* clipboard from remote hosts too, unlike lazygit's native path.

**This is safe**, contrary to first read: lazygit shell-quotes the text via
`c.Cmd.Quote(str)` *before* substituting `{{text}}`
(`OSCommand.CopyToClipboard` in `pkg/commands/oscommands/os.go`), then runs
the result through `NewShell`. So `{{text}}` expands to an already-quoted
token (`'my commit subject'`, `$'a\nb'` for newlines); our static `'%s'`
format guards against a leading-dash payload. Only the built-in
`clipboard.WriteAll` path (used when `copyToClipboardCmd` is empty) is
unquoted-stdin — we're replacing it.

Leave `readFromClipboardCmd` unset (native lib is fine for the rare
paste-into-commit-description case; `x paste` can't read over SSH anyway).

**PATH note:** `x` resolves via `$HOME/.dotfiles/bin` on PATH
(`dot_config/shell/00_exports.sh.tmpl`), which covers every normal launch
(shell alias `lg`, tmux `prefix+G`, nvim). A lazygit spawned *directly* by
niri wouldn't have that dir on PATH (niri's `environment.PATH` omits it) —
if that path matters, use `printf '%s' {{text}} | "$HOME/.dotfiles/bin/x" copy`
instead. Decide during implementation; default to bare `x`.

### 3. Doc mirrors (same commit — CLAUDE.md cross-file rules)

| File | Edit |
|---|---|
| `docs/this_repo/tool-managers.md` | § role table (~L424) + apt-deps table (~L854): add `wl-clipboard`, `xclip`, `xsel` to the `gui_apps_linux` rows. Tool index (A–Z): new rows `wl-clipboard` / `xclip` / `xsel` (macOS `n/a` — pbcopy built-in; Linux `apt`; role `gui_apps_linux`). Upgrade-automation list (~L977): append to the `playerctl / wmctrl / xdotool` "apt-upgrade" row. |
| `docs/this_repo/tool-managers.zh-TW.md` | mirror all of the above. |
| `docs/playbooks/linux-gui-apps.md` | Inventory table (~L86, by the CopyQ row): add a row for the clipboard CLIs (`wl-clipboard` / `xclip` / `xsel`; apt; `gui_apps_linux`; gated `profile=ubuntu_desktop` via tag selection). |
| `docs/tools/clipboard.md` + `.zh-TW.md` | §"How this repo wires it up" / the `x` section: state that `wl-clipboard` + `xclip` + `xsel` are installed by `gui_apps_linux` on desktop profiles (the doc currently implies the provider just exists). Fix the TL;DR "default provider" line to point at the install. Add a short "lazygit" note: `Ctrl+O` routed through `x copy` via `os.copyToClipboardCmd`. |
| `docs/tools/git_diff_workflow.md` | ~L16: note the `config.yml` `os.copyToClipboardCmd` addition alongside the existing `git.pagers`/delta mention. |
| `docs/shells/aliases.md` | `lg` row (~L81): no change needed (alias unchanged); optionally footnote that `Ctrl+O` copies via `x`. |
| `README.md` | "What You Get" gui_apps_linux bundle line (~L327): add "clipboard CLIs (wl-clipboard, xclip, xsel)". (Line is already stale re CopyQ/xdotool — optionally fold those in too.) |

### 4. New pitfall — `pitfalls/lazygit-ctrl-o-no-clipboard-utilities-nvim-yank-silent.md`

Symptom-titled. Verbatim error string
(`No clipboard utilities available. Please install xsel, xclip, wl-clipboard or Termux:API …`),
the paired nvim-yank-silent symptom, root cause (no role installed the
binaries; CopyQ ≠ these), fix (`gui_apps_linux` now installs them; `sudo apt
install wl-clipboard xclip xsel` as the manual one-liner), and the
`:checkhealth provider.clipboard` / `wl-paste`/`xclip -o` diagnostics.
Add the index line in `pitfalls/README.md`.

## Verification

1. `just gen-prompts --check` — no prompt changes, sanity only.
2. Ansible syntax + targeted run:
   `cd dot_ansible && ansible-playbook playbooks/linux.yml --syntax-check`
   then `--tags gui_apps --check` (or real run) and confirm
   `command -v wl-copy xclip xsel` all resolve afterward.
3. lazygit config validation (CLAUDE.md "validate with the app"):
   `chezmoi apply ~/.config/lazygit/config.yml` then launch `lazygit` — it
   prints YAML/schema parse errors to the status view on startup if the
   `os:` block is malformed. `lazygit --config` dumps the merged config.
4. `uv run mkdocs build --strict` — doc nav / links.
5. Functional, on this host after install:
   - `printf hi | wl-copy && wl-paste` round-trips.
   - `nvim` → `yy` on a line → `:checkhealth provider.clipboard` shows
     `wl-copy`/`wl-paste`; paste into another app works.
   - lazygit → `Ctrl+O` on a commit hash (and on a commit *subject* with
     spaces) → no error, exact text in clipboard (`x paste`).
   - `printf hi | x copy && x paste` → `hi`; `x copy-file /etc/hostname`
     no longer errors.
6. `pre-commit run --files <changed>` (shellcheck/shfmt/markdown, redact hook).

## Out of scope

- Server profiles (`ubuntu_server` / `centos_server`) — OSC 52 only, by design.
- The pre-existing "no `x` CLI row in tool-managers Tool index" gap — note it,
  don't necessarily fix here.
