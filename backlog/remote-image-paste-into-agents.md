# Paste local clipboard images into a remote coding agent over SSH

**Status**: P? (needs evaluation first — spike before committing)
**Effort**: M (build + user service + SSH config wiring; L if we also patch sshimg.nvim for macOS/X11)
**Related**: user-facing survey [`docs/tools/remote-image-paste.md`](../docs/tools/remote-image-paste.md) (+ `.zh-TW.md`) · [`docs/tools/clipboard.md`](../docs/tools/clipboard.md) (OSC 52, the text half) · `~/.ssh/config` `RemoteForward` · ansible `devtools` role

## Context

2026-07-03, conversation prompt (zh-TW): *"現在關於 remote machine 上 claude code 之類的 agent session 貼 image 有什麼好的 solution 嗎？"* → then *"開 `docs/tools/remote-image-paste.md`，然後在 `clipboard.md` 引用……zeitler / sshimg / ccimgd / ccimg / clipport / claude-ssh-image 之類的 solution 都調研一下，但純調研先不選……我自己兩者都會用（tmux/terminal + VS Code/Neovim）。評估進 backlog 就好，先不落地。"*

**Gap this fills**: our clipboard story ([`docs/tools/clipboard.md`](../docs/tools/clipboard.md)) is text-only. OSC 52 moves yanked *text* remote→local; it cannot carry an **image** local→remote, which is the direction needed to feed a screenshot to an agent running on a remote box. Confirmed no prior coverage: grep of the whole repo (docs/ + backlog/ + pitfalls/ + `.specstory/`) for `zeitler|sshimg|ccimgd|ccimg|clipport|claude-ssh-image|image.?over.?ssh` returned zero real hits before this work.

The full option survey (0. manual, 1a/1b Zeitler daemons, 2. VS Code, 3. Invoke/Clipport, 4. web) with a comparison matrix and per-option technical detail now lives in the user-facing doc — **read that first**; this backlog only holds the decision-relevant residue.

## Investigation

Researched via web fetch of the three user-supplied sources + adjacent tools (2026-07-03). Verified technical facts captured in the survey doc. Key decision inputs:

- **Best fit is likely two complementary tools, not one** (we are dual-mode):
  - terminal/tmux Claude → **1a `claude-ssh-image-skill`** (ccimgd local daemon + ccimg remote client + `/paste-image` skill; base64-over-TCP on **:9998**; clipboard backends `wl-paste`/`xclip`/`pngpaste` auto-detected → covers macOS/Wayland/X11; MIT Go static binaries).
  - editor side → **2 VS Code Remote-SSH + Claude ext** (paste "just works" because VS Code owns the local clipboard; zero daemon/tunnel) **or 1b `sshimg.nvim`** (imgd + scp on **:9999**; writes a real file into the repo tree; but **Wayland-only** clipboard read per upstream — gap on macOS/X11).
  - 1a and 1b coexist by design (9998 vs 9999).
- **Recurring cost = the reverse tunnel**: family-1 needs `RemoteForward 9998 localhost:9998` per host in `~/.ssh/config`. We already curate SSH config, so cheap — but decide whether to standardize the port fleet-wide and whether to fold it into managed config or leave host-local.
- **Trust surface**: a user-level systemd/launchd daemon reading the clipboard and listening on localhost — same posture as our `x` CLI, no root. Security caveat: on a **shared** remote host, anyone with an account can hit the forwarded port while the tunnel is up and pull whatever's on your local clipboard. Fine for single-user boxes; flag for shared hosts.
- **Not chosen / rejected for us**: Invoke (paid, and its injected path is *local* — needs a mount to be remote-visible); Clipport (macOS + iTerm2 only — we run Ghostty/Alacritty cross-platform); Claude Code web (requires code to live in Anthropic cloud — not general for private infra).

## Open questions (decide before implementing)

1. One tool or two (terminal + editor)? Likely 1a + (2 or 1b).
2. Standardize the reverse-tunnel port (e.g. 9998) across the fleet? Fold `RemoteForward` into managed `~/.ssh/config` or leave host-local?
3. Package family-1 via ansible `devtools` role (build Go binary + install user systemd/launchd unit) or vendor prebuilt binaries?
4. macOS/X11 story for the Neovim path if we want 1b (upstream Wayland-only) — patch upstream, or restrict the Neovim path and rely on 1a for Claude only?
5. Security gate: only enable on single-user hosts? Any per-host opt-in flag?

## Not doing yet

Per user: **survey only, do not implement this session.** No ansible role, no `~/.ssh/config` changes, no binaries built. When picked up: this graduates the survey doc from "research" to "here's how it's wired", and adds a row to [`docs/this_repo/tool-managers.md`](../docs/this_repo/tool-managers.md) A–Z index for whatever binary/service lands.
