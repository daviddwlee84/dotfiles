# Clipboard & OSC 52

This doc explains how clipboard sync is wired across this dotfiles setup, with a focus on **OSC 52** — the escape sequence that lets a remote SSH session put text on your **local** machine's clipboard.

## TL;DR

| You are… | Yank in Neovim goes to… | Capture pane (`prefix+y/Y/C-y`) goes to… |
|----------|--------------------------|---------------------------------------------|
| Local (macOS or Linux desktop) | system clipboard (default provider: `pbcopy` / `wl-copy` / `xclip`) | same, via `tmux load-buffer -w -` which emits OSC 52 *and* sets tmux's paste buffer |
| SSH (remote box, with or without tmux) | **local** machine's clipboard (via OSC 52) | **local** machine's clipboard (via tmux → OSC 52) |

No extra tools, no X forwarding, no socat listener needed. The only hard requirement is a terminal emulator on your **local** machine that supports OSC 52 (Ghostty, Alacritty, iTerm2, Kitty, WezTerm — all do).

## What is OSC 52?

`OSC 52` is an ANSI escape sequence:

```
ESC ] 52 ; c ; <base64-of-data> BEL
```

Any program that can write to a terminal can emit this sequence; the terminal emulator on the other end decodes the base64 and writes it to the system clipboard. The crucial property: **escape sequences travel up the TTY back to the client terminal**, so this works transparently over SSH, mosh, and nested `tmux ssh` chains — no display server, no socket forwarding.

Tradeoffs:

- **Write** is ubiquitous. Most modern terminals allow it by default or with a simple opt-in.
- **Read** (paste from local clipboard back into remote apps) is much less supported — many terminals refuse for obvious security reasons (a malicious server could exfiltrate your clipboard). Ghostty prompts; Alacritty flat-out ignores it.
- A terminal multiplexer (tmux, screen, zellij) sits between the inner app and the outer terminal. It must be configured to either **emit** OSC 52 to its host terminal or **pass through** OSC 52 from inner apps.

Reference: [tmux Clipboard wiki](https://github.com/tmux/tmux/wiki/Clipboard), [XTerm control sequences (OSC)](https://www.invisible-island.net/xterm/ctlseqs/ctlseqs.html).

## How this repo wires it up

Four layers cooperate. Removing any one silently breaks remote-clipboard sync.

### 1. Terminal emulator (outer, on your local machine)

Must accept OSC 52 writes from whatever is running inside it.

**Ghostty / cmux** — [`dot_config/ghostty/config`](../../dot_config/ghostty/config):

```conf
clipboard-write = allow   # let inner apps set the system clipboard
clipboard-read  = ask     # prompt before reads (safer default)
```

Both match current Ghostty defaults but are pinned explicitly so policy drifts from upstream don't silently break (or weaken) this chain.

**Alacritty** — native support, no config needed. Paste from OSC 52 not supported.

**iTerm2 / Kitty / WezTerm** — native support. iTerm2 requires `Preferences → General → Selection → Applications in terminal may access clipboard` for reads.

### 2. Multiplexer — tmux

[`dot_config/tmux/common.conf`](../../dot_config/tmux/common.conf):

```tmux
set -g set-clipboard on

set -as terminal-features ",xterm*:clipboard"
set -as terminal-features ",ghostty*:clipboard"
set -as terminal-features ",alacritty*:clipboard"

set -g allow-passthrough on
```

- **`set-clipboard on`** — tmux both re-emits OSC 52 to the outer terminal when its own copy-mode yanks, and passes OSC 52 from inner apps (Neovim, less, etc.) through. `external` would only pass through; `on` is a strict superset and simpler.
- **`terminal-features …:clipboard`** — tells tmux the outer terminal supports OSC 52 without needing a terminfo `Ms` capability. Many distros ship a `tmux-256color` entry that lacks `Ms`, so declaring the feature directly avoids surprises when `chezmoi apply` is run on a fresh box.
- **`allow-passthrough on`** — lets terminal-image protocols (sixel, kitty graphics) work; also covers OSC passthrough for nested multiplexers.

**Capture-pane helpers** — [`dot_config/tmux/keybindings.conf`](../../dot_config/tmux/keybindings.conf) — use the tmux-native idiom rather than shelling out:

```tmux
bind y   run-shell "tmux capture-pane -p   | tmux load-buffer -w -"
bind Y   run-shell "tmux capture-pane -pS - | tmux load-buffer -w -"
bind C-y run-shell "tmux capture-pane -pS - | fzf-tmux … | tmux load-buffer -w -"
```

`load-buffer -w -` reads stdin into tmux's paste buffer *and* (because of `-w`) forwards to the system clipboard via OSC 52. Previously these bindings used a `pbcopy | xclip | xsel` fallback chain that only worked locally — over SSH they copied to the **remote** machine's clipboard, which is useless. The tmux-native form works identically in both places.

`set-buffer -w …` offers the same `-w` flag but takes data as an argument, which introduces shell-quoting landmines on multi-line pane content; `load-buffer -w -` reads stdin and sidesteps that.

### 3. Editor — Neovim

[`dot_config/nvim/lua/config/options.lua`](../../dot_config/nvim/lua/config/options.lua):

```lua
vim.opt.clipboard = "unnamedplus"

if vim.env.SSH_CONNECTION or vim.env.SSH_TTY then
  local osc52 = require("vim.ui.clipboard.osc52")
  vim.g.clipboard = {
    name = "OSC 52",
    copy  = { ["+"] = osc52.copy("+"),  ["*"] = osc52.copy("*")  },
    paste = { ["+"] = osc52.paste("+"), ["*"] = osc52.paste("*") },
  }
end
```

- Locally, LazyVim's default provider is used (`pbcopy`/`xclip`/`wl-copy` — with working paste).
- Over SSH, Neovim's built-in `vim.ui.clipboard.osc52` (shipping since Neovim 0.10) emits OSC 52 directly, bypassing any `pbcopy` binary on the remote host.
- The check is `SSH_CONNECTION or SSH_TTY` — either is set by `sshd` for an interactive session.

Why conditional rather than always-on OSC 52? OSC 52 paste is unreliable (see the terminal table above). Keeping the local provider for local sessions preserves Neovim's paste behaviour; the override only activates when `pbcopy` on the remote is clearly the wrong answer.

### 4. Shell CLI — `x` (cross-platform clipboard wrapper)

[`dot_dotfiles/bin/executable_x`](../../dot_dotfiles/bin/executable_x) (deployed to `~/.dotfiles/bin/x`) is a Bash wrapper with three subcommands:

```bash
printf "hello" | x copy        # copy stdin to clipboard
x copy path/to/file            # copy file contents
x paste                        # print clipboard to stdout
x open https://example.com     # open URL/file in default app
```

Its copy backend tries, in order: `clip.exe` (WSL) → `pbcopy` (macOS) → `wl-copy` (Wayland) → `xclip` → `xsel` → **OSC 52 fallback** writing directly to `/dev/tty`. This means `x copy` Just Works on macOS, Linux desktop, Linux SSH server, WSL, and anything else that can reach a terminal — you never have to think about which backend is available.

The OSC 52 fallback in `x` is also wrapped for tmux:

```bash
if [[ -n "${TMUX:-}" ]]; then
  printf '\033Ptmux;\033\033]52;c;%s\033\033\\\033\\' "$data" > /dev/tty
else
  printf '\033]52;c;%s\033\\' "$data" > /dev/tty
fi
```

The `DCS tmux; ... ST` wrapper is tmux's passthrough escape — it tells tmux "hand this sequence to the outer terminal as-is", needed because tmux otherwise intercepts OSC 52.

## Verifying the chain works

On the remote box where Neovim yank is misbehaving, run:

```bash
# tmux: does it believe the terminal can accept OSC 52?
tmux info | grep -Ei 'clipboard|Ms:'
# expect: clipboard: true  and an Ms entry that is NOT [missing]

# shell: can x copy reach the clipboard?
printf "hello from %s" "$(hostname)" | x copy
# then Cmd+V / Ctrl+V into a local app → should paste "hello from <remote-host>"

# Neovim: which provider is active?
nvim -c ':checkhealth provider.clipboard' -c ':only'
# expect: OSC 52 under SSH, native under local
```

If `tmux info` shows `clipboard: false` after editing `common.conf`, remember a running tmux server **keeps its old capability table** — `tmux kill-server` (losing sessions; `tmux-resurrect` can restore them) and re-attach.

## Common failure modes

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Yank works outside tmux but vanishes inside tmux (remote) | `set-clipboard off` or server running pre-edit binary | `tmux show -g set-clipboard`; `tmux kill-server` |
| `tmux info` shows `Ms: [missing]` | tmux's TERM entry lacks `Ms` *and* no `terminal-features …:clipboard` declared | already handled by [`common.conf`](../../dot_config/tmux/common.conf); on an unusual outer `$TERM`, add another `set -as terminal-features` line |
| Ghostty asks about clipboard every yank | `clipboard-read = ask`; Ghostty interprets some writes as reads when apps immediately re-fetch | switch to `clipboard-read = allow` if you trust everything inside your sessions |
| Neovim yank works, but `"*p` does nothing over SSH | paste over OSC 52 not supported by outer terminal | expected — use mouse middle-click or re-type; don't fight it |
| `prefix+y` still copies to remote clipboard | shim binary `tmux` resolves to an old pre-`load-buffer -w` version | `tmux -V` must be ≥ 3.3 for `load-buffer -w`; this repo enforces ≥ 3.3 via ansible `devtools` role |
| Nested tmux (`tmux inside ssh inside tmux`) | inner tmux eats OSC 52 | inner tmux needs `set -g allow-passthrough on`; already on in this config. Double-nested cases may require `Ptmux;…` wrapping |

## Design notes / non-defaults

- **tmux `set-clipboard`** is `on`, not `external`. `external` disables tmux's own OSC 52 emission from copy-mode; `on` is a superset and keeps `prefix+[` → `y` working.
- **Neovim OSC 52 provider** is gated on `SSH_CONNECTION`/`SSH_TTY` rather than always-on, specifically so local paste (`"+p`) continues to work. If you primarily work over SSH and don't mind the paste tradeoff, the `if …` block can be removed.
- **`x` CLI ordering** prefers local backends (`pbcopy`, `wl-copy`, etc.) over OSC 52. This is intentional: when `pbcopy` is available, it's faster, doesn't touch the TTY, and works for very large payloads (OSC 52 payloads are size-limited by the terminal — iTerm2 caps at 1 MB, many others at 64-256 KB).

## Clipboard history (`cb` / `cbl` / `cbe`)

OSC 52 covers **sync** — getting yanked text from a remote box to your local clipboard. Clipboard *history* — recalling something you copied an hour ago — is a separate concern with a separate backend, wrapped behind a unified shell API by [`dot_config/shell/56_clipboard_history.sh`](../../dot_config/shell/56_clipboard_history.sh).

### Hybrid backend

| OS | Backend | Install | CLI surface |
|----|---------|---------|------------|
| macOS | **Maccy** | `brew install --cask maccy` (signed, healthy on brew, auto-updating, macOS 14+) | None shipped — helper queries Maccy's plaintext SQLite directly |
| Ubuntu desktop | **CopyQ** | `sudo apt install copyq` (stock 22.04 / 24.04 repos; ansible role: [`gui_apps_linux`](../../dot_ansible/roles/gui_apps_linux/tasks/main.yml)) | `copyq read / select / eval / size / copy` |
| Ubuntu server | — | none | helper prints install hint and returns 1 |

Why hybrid rather than CopyQ everywhere: the **CopyQ Homebrew cask** is deprecated (disabled 2026-09-01) because `CopyQ.app` is not signed for macOS Gatekeeper. Only the cask is affected — the upstream project is fine, and the Linux package is unaffected (see [hluk/CopyQ#3498](https://github.com/hluk/CopyQ/issues/3498)). Maccy is the most maintained signed-and-on-brew clipboard manager for macOS; the trade-off is no shipped CLI, so we query the plaintext SQLite at `~/Library/Application Support/Maccy/Storage.sqlite` (cask install) or `~/Library/Containers/org.p0deje.Maccy/.../Storage.sqlite` (Mac App Store sandboxed).

### API

| Command | Behaviour |
|---------|-----------|
| `cbl [N]` | List recent `N` clipboard items (default 20), tab-separated `<idx>\t<first-line-preview>`. Filters to UTF-8 plain text only. |
| `cb` | Pipe `cbl 100` to fzf → selected item is moved to the top of the stack and copied to the system clipboard. CopyQ uses `copyq select`; Maccy uses `pbcopy` (Maccy then re-records, adding a duplicate at index 0 — known quirk, not a bug). |
| `cbe` | Same fzf flow as `cb`, but reads the item into a tempfile, opens `$EDITOR`, then writes the edited contents back to the clipboard. |

The first column of `cbl`'s output is:
- For CopyQ: the position index (`0` = top of stack)
- For Maccy: the SQLite `Z_PK` primary key

This is intentional — each backend can address its own items round-trip without translation.

### Manual backend override

Set `CLIP_BACKEND=copyq` or `CLIP_BACKEND=maccy` to skip autodetect (useful if both are installed on the same mac and you want the more-reliable CopyQ CLI):

```sh
CLIP_BACKEND=copyq cb     # one-off
export CLIP_BACKEND=copyq  # session
```

Unknown values print a hint and return 1.

### Coexistence with Raycast

On macOS the new helper does **not** disable Raycast's clipboard module — both will record every `⌘C` independently. Two separate histories, no functional conflict, slight storage duplication. To disable: Raycast → Extensions → Clipboard History → toggle off.

### Threat model — secrets in plaintext

Both Maccy and CopyQ store unencrypted SQLite. Anything you copy from a terminal / browser / text editor as plain text (e.g. `cat .env`, an API key pasted from Slack) lands in the DB readable by your own shell.

What is NOT recorded:
- macOS pasteboard items marked `org.nspasteboard.ConcealedType` / `TransientType` / `AutoGeneratedType`. 1Password, Bitwarden, KeePassXC, Keychain Access all set these — secrets pasted via those tools never enter the history.
- Anything copied while Maccy's "Ignore Events" toggle (`⌥`-click menu icon) or CopyQ's "Disable Clipboard Storing" is active.

For ad-hoc secret pastes, toggle "Ignore" before pasting and toggle off after.

### DB paths (for backup / inspection)

- Maccy (cask): `~/Library/Application Support/Maccy/Storage.sqlite` (+ `-wal`, `-shm`)
- Maccy (Mac App Store): `~/Library/Containers/org.p0deje.Maccy/Data/Library/Application Support/Maccy/Storage.sqlite`
- CopyQ: `~/.config/copyq/` on Linux, `~/Library/Application Support/copyq/` on macOS

The Maccy schema is documented in the [helper file's header comment](../../dot_config/shell/56_clipboard_history.sh) — verified against `p0deje/Maccy@master` source files (`HistoryItem.swift` + `HistoryItemContent.swift`).

## Related docs

- [tmux](./tmux/README.md) — "OSC 52 Clipboard (SSH-friendly yank)" section
- [Ghostty](./ghostty.md) — terminal-side notes
- [`dot_dotfiles/bin/executable_x`](../../dot_dotfiles/bin/executable_x) — the `x` wrapper source
- [`dot_config/shell/56_clipboard_history.sh`](../../dot_config/shell/56_clipboard_history.sh) — clipboard-history backend dispatch

## External references

- [tmux Clipboard wiki](https://github.com/tmux/tmux/wiki/Clipboard)
- [Neovim `:help clipboard-osc52`](https://neovim.io/doc/user/provider.html#clipboard-osc52)
- [XTerm OSC 52 spec](https://www.invisible-island.net/xterm/ctlseqs/ctlseqs.html#h3-Operating-System-Commands)
