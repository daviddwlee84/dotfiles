# Pasting images into a remote coding agent over SSH

**Status: research only — no solution adopted yet.** This doc surveys the landscape for getting a *local* clipboard **image** (a screenshot) into a coding agent (Claude Code, and Neovim-adjacent workflows) that is running on a *remote* box over SSH. It is the image-shaped sequel to [`clipboard.md`](./clipboard.md): OSC 52 solves the **text** half of remote clipboard sync, but it explicitly **cannot carry image or file payloads**, so a different mechanism is needed.

When we pick and wire something into the dotfiles, this doc graduates from "survey" to "here's how it's wired" (and gets a `.zh-TW.md` mirror like the rest of `docs/tools/`).

## The core constraint

| | Where it lives | How it crosses SSH today |
|---|---|---|
| Yanked **text** | remote app → local clipboard | **OSC 52** — escape sequence rides the TTY up to the local terminal ([`clipboard.md`](./clipboard.md)) |
| Screenshot **image** | **local** clipboard → remote agent | ❌ nothing built-in — OSC 52 is text-only; the image bytes never leave your laptop |

The asymmetry is the whole problem. The clipboard with the screenshot in it is on your **local** machine; the agent that needs to *see* the image runs on the **remote** box. OSC 52 goes the wrong direction (remote→local) and only carries base64 text anyway. So every solution below boils down to the same move: **get the local image bytes onto the remote filesystem as a file, then hand the agent that file path** (agents read images from paths via their Read tool). They differ only in *how* the bytes travel and *how automated* the round-trip is.

> **Why not just a terminal image protocol (kitty graphics / sixel / iTerm2 inline)?** Those are **output** protocols — they let a remote program *draw* an image into your terminal. They do not give a remote program a way to *ingest* an image sitting in your local clipboard. Wrong direction again. (We already have `allow-passthrough on` for the display side; it does nothing for input.)

## Taxonomy of approaches

### 0. Baseline — manual file + path reference (zero tooling)

Save the screenshot somewhere the remote can see it, then reference the path in the agent prompt.

```bash
scp ~/shot.png remote:/tmp/            # or drag into an sshfs/VS Code mount
# then in Claude Code on the remote:
#   @/tmp/shot.png   what's wrong with this layout?
```

- **Pros:** works everywhere, no daemon, no tunnel, survives tmux/mosh. This is the fallback that always works.
- **Cons:** manual every time; breaks flow. Everything below is just automation of this baseline.

### 1. Networked daemon + SSH reverse tunnel (the Zeitler family)

The most principled fit for a **pure terminal / tmux** workflow. A tiny daemon runs on your **local** machine and reads the local clipboard; the **remote** side reaches it through an SSH **reverse** tunnel (`RemoteForward`) and writes the bytes to a temp file. We already keep long-lived SSH configs, so adding a `RemoteForward` line is cheap.

#### 1a. `claude-ssh-image-skill` — ccimgd + ccimg + `/paste-image` skill

[AlexZeitler/claude-ssh-image-skill](https://github.com/AlexZeitler/claude-ssh-image-skill) · MIT · Go (static binaries) · **the direct answer to the original question.**

Architecture (base64-over-TCP, no scp):

```
/paste-image (remote Claude skill)
  └─ Bash: ccimg (remote client)
       └─ TCP 127.0.0.1:9998  ──(SSH -R reverse tunnel)──▶  ccimgd (local daemon)
                                                              └─ reads local clipboard
                                                                 (wl-paste / xclip / pngpaste)
       ◀── JSON { ok, image: <base64 PNG> } ───────────────────
  └─ ccimg writes /tmp/…png, prints the path
  └─ Claude's Read tool loads that path → image is now in the session
```

Setup, verbatim from the README:

```bash
# build both binaries (needs Go)
git clone https://github.com/AlexZeitler/claude-ssh-image-skill.git
cd claude-ssh-image-skill && ./build.sh

# local daemon — Linux
cp daemon/ccimgd-linux-amd64 ~/.local/bin/ccimgd
cp daemon/ccimgd.service ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now ccimgd
# local daemon — macOS
brew install pngpaste
cp daemon/ccimgd-darwin-arm64 /usr/local/bin/ccimgd
cp daemon/com.ccimgd.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.ccimgd.plist

# remote: client binary + the skill
scp client/ccimg-linux-amd64 remote:~/.local/bin/ccimg
scp skill/paste-image.md      remote:~/.claude/commands/paste-image.md
```

Reverse tunnel (in `~/.ssh/config` so it's automatic):

```ssh-config
Host remote-server
    RemoteForward 9998 localhost:9998
```

…or ad hoc: `ssh -R 9998:localhost:9998 remote-server`. Allow the client without a prompt by adding `"Bash(ccimg)"` to the remote `~/.claude/settings.json` `permissions.allow`. Usage: copy an image locally, then run `/paste-image` in the remote Claude session.

- **Clipboard backends:** Wayland `wl-paste`, X11 `xclip`, macOS `pngpaste` (auto-detected).
- **Fit for us:** ★ best fit for terminal/tmux. Port **9998** is deliberately distinct from sshimg.nvim's 9999 so both daemons can run at once.
- **Cost:** must keep the reverse tunnel up; local daemon must be running; PNG-only.

#### 1b. `sshimg.nvim` — imgd + Neovim plugin (scp transfer)

[AlexZeitler/sshimg.nvim](https://github.com/AlexZeitler/sshimg.nvim) · MIT · Python daemon + Lua plugin. Same author, **Neovim** target instead of Claude, and a different transport: **scp** rather than base64-over-TCP.

```
Screenshot (local) → imgd daemon → SSH reverse tunnel → scp → Remote Neovim
```

```bash
# local daemon
cp daemon/imgd.py ~/.local/bin/imgd && chmod +x ~/.local/bin/imgd
cp daemon/imgd.service ~/.config/systemd/user/imgd.service
systemctl --user enable --now imgd
ssh -R 9999:localhost:9999 yourserver      # reverse tunnel (port 9999)
```

```lua
-- lazy.nvim
{ "AlexZeitler/sshimg.nvim", opts = {
    port = 9999, host = "127.0.0.1",
    -- <leader>pa → save under ./assets/ ; <leader>pp → save beside current file
} }
```

Press `<leader>pa` / `<leader>pp` in a Markdown buffer on the remote → the plugin scps the local clipboard image over and inserts `![](assets/2026-…​.png)` at the cursor.

- **Deps:** local = `wl-paste` + `scp` + Python 3 (Wayland only, per README); remote = Neovim + Python 3.
- **Fit for us:** ★ complements our Neovim-over-SSH setup (the SSH-conditional OSC 52 provider in [`clipboard.md`](./clipboard.md) §3 "Editor — Neovim"). It writes a real file into the repo tree, which is exactly what an agent reading that Markdown later would want. Downsides: Wayland-only clipboard read as documented; no macOS/X11 path out of the box.

> **Background article** tying 1a+1b together: [Paste clipboard images into Claude Code over SSH](https://alexanderzeitler.com/articles/paste-clipboard-images-into-claude-code-over-ssh/).

### 2. GUI-editor bridge — let the editor own the clipboard

If the agent is driven from **VS Code Remote-SSH**, the paste problem disappears: VS Code runs **locally** and owns the local clipboard, so a normal `Ctrl/Cmd+V` into the Claude Code extension's input carries the image through the editor's remote channel — no daemon, no tunnel.

- **Official:** [Claude Code VS Code extension](https://code.claude.com/docs/en/vs-code) over Remote-SSH. Zero extra setup beyond the two extensions; also gives graphical diffs/plan review.
- **Community CLI-in-terminal variants** (for when you run the Claude *CLI* inside VS Code's integrated terminal rather than the extension): e.g. [marcucio/claude-image-paste](https://github.com/marcucio/claude-image-paste) reads the local clipboard, uploads via the Remote-SSH filesystem, and pastes the resulting remote path. Marketplace has a few more (`claude-remote-image-paste`, `claude-paste-image`) doing the same trick.
- **Fit for us:** ★ best fit for the **VS Code side** of a dual workflow. Does nothing for a bare tmux SSH session.

### 3. Local clipboard → path injector (terminal-agnostic)

Tools that hotkey-capture or read the local clipboard, drop it to a file, and **type the file path** into whatever terminal has focus. Because they inject *text* (a path), they sail over SSH like any keystrokes.

| Tool | Platform | Mechanism | Notes |
|---|---|---|---|
| [Invoke](https://getinvoke.dev/learn/screenshot-paste-claude-code-terminal/) | cross-platform | hotkey screenshot → `~/.screenshots/…` → pastes the path | paid (~$49 one-time); zero SSH config; but path is **local** — only works if the terminal app maps it to a remote-visible path (mount) or you accept a local capture flow |
| [Clipport](https://github.com/arihantsethia/clipport) | macOS + iTerm2 | `clipportd` daemon uploads the clipboard image over the existing SSH connection, inserts the **remote** path | single keystroke; iTerm2 paste hotkey → helper; macOS/iTerm2 only, proprietary protocol (not OSC 52) |

- **Fit for us:** situational. Clipport is the cleanest single-keystroke UX **if** you standardize on macOS + iTerm2 (we don't — Ghostty/Alacritty across macOS + Linux).

### 4. Cloud — sidestep SSH entirely

[Claude Code on the web](https://code.claude.com/docs/en/claude-code-on-the-web) runs the agent in Anthropic's sandbox; you paste images straight into the browser (local clipboard, no SSH in the loop).

- **Fit for us:** only when the code can live in Anthropic's cloud. Not a general answer for arbitrary remote boxes / private infra.

## Comparison matrix

| Approach | Target | Local deps | Remote deps | Transport | Tunnel? | Platforms | Fit |
|---|---|---|---|---|---|---|---|
| 0 · manual `scp` + `@path` | any agent | — | — | scp/mount | no | all | fallback |
| 1a · claude-ssh-image-skill | **Claude Code CLI** | ccimgd + wl-paste/xclip/pngpaste | ccimg + skill | base64/TCP :9998 | **reverse** | Wayland/X11/macOS | ★ terminal |
| 1b · sshimg.nvim | **Neovim** | imgd + wl-paste + scp + py3 | nvim + py3 | scp :9999 | **reverse** | Wayland (docs) | ★ nvim |
| 2 · VS Code Remote-SSH | Claude ext / CLI | VS Code | Remote-SSH server | editor channel | no | all | ★ VS Code |
| 3 · Invoke / Clipport | any terminal agent | daemon | — | path inject / upload | no | Invoke: all · Clipport: mac+iTerm2 | situational |
| 4 · Claude Code web | web agent | browser | — (cloud) | HTTPS | no | all | cloud-only |

## Fit against *this* setup (notes for the eventual decision)

- **We are dual-mode** (owner uses *both* tmux/terminal and VS Code/Neovim), so the likely answer is **two complementary picks**, not one: **1a** for terminal/tmux Claude, and either **2** (VS Code) or **1b** (Neovim) for the editor side. 1a and 1b coexist by design (ports 9998 vs 9999).
- **Reverse tunnel is the recurring cost.** We already curate `~/.ssh/config`; a `RemoteForward` line per box is the price of entry for the whole family-1 approach. Worth deciding whether to standardize a port (e.g. 9998) across hosts.
- **Clipboard backend spread:** our machines span macOS, Wayland, and X11. 1a auto-detects all three; 1b as documented is Wayland-only — a gap to weigh if the owner is on macOS/X11 for the Neovim path.
- **Existing infra already helps the display side** (`allow-passthrough on`, `set-clipboard on`) but is orthogonal to *input*; none of it needs to change.
- **Build/trust:** family-1 tools are small MIT Go/Python we'd build from source and run as a **user** systemd/launchd service reading the clipboard and listening on localhost — same trust surface as the `x` CLI. No root.
- **Security note:** a localhost daemon that serves your clipboard image on demand is reachable by anything that can hit the forwarded port on the remote — i.e. anyone with an account on that box while the tunnel is up. Acceptable for single-user boxes; think twice on shared hosts.

## Open questions before adopting

1. One tool or two (terminal + editor)? Standardize the reverse-tunnel port?
2. Package via ansible `devtools` role (build Go binary + install user service) or vendor prebuilt binaries?
3. macOS/X11 story for the Neovim path if we want 1b (upstream is Wayland-only) — patch or restrict to Claude-CLI (1a) only?
4. Wrap the reverse-tunnel `RemoteForward` into the managed SSH config, or leave it host-local?

## External references

- [claude-ssh-image-skill (ccimgd/ccimg)](https://github.com/AlexZeitler/claude-ssh-image-skill) — MIT
- [sshimg.nvim](https://github.com/AlexZeitler/sshimg.nvim) — MIT
- [Article: Paste clipboard images into Claude Code over SSH](https://alexanderzeitler.com/articles/paste-clipboard-images-into-claude-code-over-ssh/)
- [Article: Introducing sshimg.nvim](https://alexanderzeitler.com/articles/introducing-sshimg-nvim-paste-images-into-remote-neovim-over-ssh/)
- [Clipport](https://github.com/arihantsethia/clipport) · [write-up](https://arihantsethia.com/clipport-paste-across-remote-terminals/)
- [Invoke — screenshot paste into the terminal](https://getinvoke.dev/learn/screenshot-paste-claude-code-terminal/)
- [Claude Code in VS Code](https://code.claude.com/docs/en/vs-code) · [Claude Code on the web](https://code.claude.com/docs/en/claude-code-on-the-web)

## Related docs

- [`clipboard.md`](./clipboard.md) — OSC 52 text clipboard sync (the text half; explains why images can't ride OSC 52)
- [`tmux/README.md`](./tmux/README.md) — `allow-passthrough` / terminal image display side
- [`aicapture.md`](./aicapture.md) — the *text* scrollback → agent capture layer (adjacent "feed context to the agent" tooling)
