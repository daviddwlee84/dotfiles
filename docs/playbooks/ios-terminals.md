# iOS terminals (iSH, a-Shell, SSH clients)

Whether this repo runs on iOS (it does not), what does, and how to keep an iPad
useful anyway.

**Short version**: iOS cannot run any agentic coding CLI, and that is
structural rather than a gap someone will close. Keep iSH as a notes-sync
appliance, use an SSH client for terminal work, and drive agents with
`claude --remote-control` from a machine that has a real OS.

## The verdict

| Goal | On iOS |
|---|---|
| Run `chezmoi apply` with this repo | ❌ Aborts before writing a single file |
| Run Claude Code / Codex / OpenCode locally | ❌ Structurally impossible |
| `git` + SSH + a local Unix filesystem | ✅ iSH does this today |
| Neovim / LazyVim | ⚠️ Starts; no LSP, no ripgrep, treesitter must compile locally |
| Drive an agent running elsewhere | ✅ `claude --remote-control` + the Claude iOS app |

## Why agent CLIs cannot run — three independent walls

Any one of these alone is fatal. All three are true simultaneously.

**1. iOS forbids `fork`/`exec` of arbitrary binaries.** nodejs-mobile documents
that `child_process` and `cluster` are unavailable on iOS. Every agent CLI
drives its work through a Bash tool, so a perfect ARM64 Node on-device still
would not help. This is the wall that matters most, and it applies to *every*
iOS app, not just iSH.

**2. App Review Guideline 2.5.2** forbids apps that "download, install, or
execute code". That guideline carries the Notarization marker, so it binds
alternative marketplaces in the EU and Japan too. UTM was blocked under it in
June 2024 — and that was the build *without* JIT.

**3. Claude Code stopped being JavaScript.** `@anthropic-ai/claude-code@2.1.220`
is a ~23 KB tarball; the real CLI ships as platform-native binaries through
`optionalDependencies`, with no iOS slice. Version 2.1.112 (superseded
2026-04-17) was the last one with a JS bundle. Codex is a Rust binary shim;
Gemini CLI needs Node >= 20.

Apple has not relaxed JIT. The only JIT entitlements are
`com.apple.developer.web-browser-engine.*` via BrowserEngineKit, restricted to
Apple-approved alternative browser engines distributed solely in the EU (Japan
from iOS 26.2). There is no application path for an emulator, runtime, or
shell. iOS 26 and iPadOS 26 changed nothing here; iPadOS 27's release notes do
not mention JIT, virtualization, or containers.

### iSH's own limit is real but secondary

iSH is a threaded-code interpreter for 32-bit x86 (i686) with musl. Node dies
there with `Illegal instruction` — but note the mechanism, because it predicts
more than the instruction set does:

iSH's CPUID *does* advertise `fpu|cmov|mmx|sse2`. The SIGILLs come from
unimplemented gadget slots in `asbestos/gen.c` and 31 `UNDEFINED` points in
`emu/decode.h`. A perfectly legal, in-baseline instruction still traps if its
host gadget is NULL. `LOOP` (0xE0–0xE2, from 1978) was still unimplemented as
of build 812.

**Consequence**: you cannot reason from "this tool only uses SSE2, so it is
safe". Test, do not predict. Rust's `i686` targets assume SSE2, so `ripgrep`
and friends are affected too.

## How much of this repo survives

### Portable — pure config, no binary dependency

The shell layer is cleaner than expected. All four entrypoints
(`dot_zshrc.tmpl`, `dot_bashrc.tmpl`, `dot_zshenv.tmpl`,
`dot_bash_profile.tmpl`) have **zero hard external-binary requirements** —
oh-my-zsh, ble.sh, starship, atuin, zoxide, mise, direnv, fzf, tv, sesh, yazi,
eza, bat, delta and nvim are all presence-gated behind `command -v` or
`[ -r ]`. A bare Alpine box loads them without a single error.

Also portable: `dot_ssh/` (plain text, `Include config.d/*`),
`.chezmoiexternal.toml.tmpl` (all `git-repo`, arch-independent), the `modify_`
overlays (POSIX sh with jq/python3 guards that pass through when absent), and
`dot_config/shell/04_ai_agents.sh`.

**But correctness is not the problem — cost is.** An interactive zsh sources
~110 files. Measured on native Apple Silicon: 1.89–2.12 s for
`zsh -i -c exit`, of which 907 ms is the modular layer, 83% concentrated in
nine files that fork external binaries. Under iSH that is minutes per shell.
Do not deploy the shell layer here.

### Not available for i686-musl

`mise` (no 32-bit build upstream), `starship` / `ripgrep` / `eza` / `atuin` /
`fzf` (no 32-bit Linux release asset at all), and every tokio-based Rust tool
(`available_parallelism()` returns 0 → divide-by-zero panic; `uv` segfaults,
astral-sh/uv#2732 closed as not-planned). Go binaries hit a documented
lock-up in iSH (ish-app/ish#1230) — which includes `chezmoi` itself.

`fleet` cannot run *from* iSH: asyncssh needs `cryptography`, which publishes
zero i686 wheels.

### The install path breaks before anything is written

In failure order:

1. `bootstrap.sh` is bash-only (arrays) — BusyBox ash cannot run it.
2. `dotfiles_init.py` needs Python >= 3.11; Alpine 3.14 has 3.9.5, and uv
   cannot download a managed CPython because **python-build-standalone has no
   i686-Linux target**. **Hard blocker.**
3. `run_once_before_00_bootstrap.sh.tmpl` runs
   `uv tool install --python 3.13 ansible-core` under `set -e`, failing for the
   same reason — so chezmoi aborts before writing any dotfile. **Hard blocker.**
4. `.chezmoi.toml.tmpl` uses `promptChoiceOnce` (chezmoi >= 2.42); Alpine
   3.14's apk chezmoi is 2.0.16.

The ansible layer never even gets a chance: 166 Debian / 91 Darwin / 20 RedHat
`os_family` branches and **zero** Alpine, so it silently no-ops rather than
exploding.

## Recommended stack

Compute stays on the fleet. The iPad is a control plane plus a local file
layer.

| Role | Tool | Cost |
|---|---|---|
| Agent work | `claude --remote-control NAME` + Claude iOS app | $0 if you already subscribe |
| Terminal | Blink Shell (see caveats) | ~$20/yr |
| Local Unix + vault git | **iSH** (see below — do not migrate to a-Shell) | free |
| Vault git alternative | Working Copy Pro | ~$36 one-off |

### `claude --remote-control`

Run it inside tmux on any fleet host; scan the QR with the Claude iOS app.
Outbound HTTPS only — no inbound port, no VPN. Your filesystem, MCP servers,
`CLAUDE.md` and subagents all stay.

!!! danger "This repo will silently disable it"

    `dot_config/shell/43_copilot_proxy.sh`'s `_copilot_env_json()` writes both
    `ANTHROPIC_BASE_URL` (pointing at the Copilot shim, not
    `api.anthropic.com`) and `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` into
    a project's `.claude/settings.local.json`. Either one disables Remote
    Control, and older CLIs report it as *"not yet enabled for your account"* —
    which sends you debugging your subscription instead of your config.

    Audit `.claude/settings.local.json` in any project you pinned with
    `copilot-here` before relying on Remote Control. See
    [copilot-claude-proxy](../tools/copilot-claude-proxy.md).

### SSH clients

Your **server side is already correct**: `dot_config/tmux/common.conf.tmpl`
sets `extended-keys on`, `extended-keys-format csi-u` (tmux >= 3.5) and
`terminal-features 'xterm*:extkeys'`. The gap is client-side.

| Client | mosh | Nerd Font | CSI-u | Notes |
|---|---|---|---|---|
| **Blink Shell** | ✅ 1.4.0 | ✅ ~50 patched fonts, paste a URL | ❌ hterm engine | Deepest keyboard remapping on iOS (Caps → tap-Esc / hold-Ctrl). Subscription only |
| Moshi | Pro only | ❌ no font import → tofu | unknown | First-class **herdr** integration; $199 buyout |
| ShadowTerm | ✅ | ✅ claimed | — | herdr auto-detect + MCP; only 17 ratings — unverified |
| Prompt 3 | ✅ | ❌ | — | One-off purchase, but **cannot remap external keyboards** |
| Secure ShellFish | ❌ | — | — | Best Files integration; tmux session picker + Handoff |
| Termius | ✅ free tier | ❌ | — | Best cross-device host sync |

**Shift+Enter in Claude Code** needs CSI-u (`ESC[13;2u`); a plain PTY sends the
same CR for Enter and Shift+Enter. Blink has no CSI-u, so bind a key to hex
`0A`, or use **Ctrl+J** — the universal fallback.

Open Blink issues worth knowing: #2232 (`⏺` U+23FA is East-Asian-Ambiguous
width; hterm's table disagrees with Claude Code, shifting every line) and
#2268 / #2134 (CJK IME composition misrenders inside Claude Code).

**mosh does not work from inside iSH** (ish-app/ish#589, #2655) — iSH lacks
full raw/UDP socket support and iOS reclaims sockets on suspend. Use plain SSH
+ tmux there; use Blink if you want real mosh.

## Setting up iSH

```sh
wget -qO- https://raw.githubusercontent.com/daviddwlee84/dotfiles/main/scripts/ios/ish-bootstrap.sh | sh
```

[`scripts/ios/ish-bootstrap.sh`](../../scripts/ios/ish-bootstrap.sh) installs a
deliberately small set (git, openssh-client, tmux, nano, vim, curl), seeds
`~/.ssh/config`, and adds two helpers to `~/.profile`.

### The mount helpers

iSH reaches iOS Files via `mount -t ios null <dir>`, which shows the folder
picker and stores a security-scoped bookmark. **The mount does not survive an
app restart** — which is why `mount -t ios` accumulates in everyone's history.

```sh
ovault              # mount if needed, cd into the vault
ovault Jingle.AI    # ...and descend into a repo
ovsync Jingle.AI    # add -A, commit, pull --rebase --autostash, push
```

`ovault` also registers the repo in `safe.directory`, because the iOS-backed
tree always looks foreign-owned and git otherwise refuses it with "detected
dubious ownership". That lands in `~/.gitconfig` inside the Alpine rootfs, so
it persists.

### Alpine branch: 3.18, not newest

The App Store build pins **Alpine 3.14** (EOL 2023-05-01). Moving forward
helps, but not far:

| Branch | Status |
|---|---|
| 3.18 | Community's last-known-sane target |
| 3.19 | `sudo` crashes on launch; `procps` segfaults `uptime` |
| 3.20 | Installing `coreutils` breaks `/dev` |
| **edge** | **Do not.** Alpine raised the x86 baseline to SSE2 and builds `-march=pentium-m`; much of the userland becomes unrunnable under iSH |

The bootstrap keeps your current branch unless you pass
`ISH_SWITCH_BRANCH=1`.

### tmux from inside iSH needs a trimmed config

iSH hardcodes `TERM=xterm-256color`, so this repo's
`terminal-features 'xterm*:extkeys'` **matches** and tmux believes the outer
terminal speaks extended keys. It does not — hterm marks `CSI > Pm m` as "won't
support". The failure is worse than silence:

- `C-1` … `C-9` window switching stops working entirely.
- `C-2` and `C-6` still arrive, as legacy `C-Space` (0x00) and `C-^` (0x1E) —
  so they **trigger whatever else is bound to those**, rather than doing
  nothing.

If you run tmux inside iSH, hand-write a minimal `~/.tmux.conf` there: drop
`extended-keys` / `extkeys` and the `bind -n C-1..C-9` block (use
`prefix + 1..9`), and set `mouse off` — iSH overrides hterm's touch handler, so
mouse events never reach the tty at all (ish-app/ish#2537, #2375, #2708). Keep
`set-clipboard on`; OSC 52 does work.

### iOS-side settings that matter more than any package

- **Auto-Lock → Never.** Locking the screen freezes iSH.
- **Guided Access** locked to iSH, if you run `sshd` and connect *into* the
  device.
- A Nerd Font installed via iFont or a configuration profile, then
  `/proc/ish/defaults/font_family`. Prefer a `*Nerd Font Mono` variant —
  non-Mono patched fonts have uneven advance widths and desync the cursor
  (ish-app/ish#1483).

### Running sshd on the device

Useful for one thing: letting an agent on your laptop drive the iSH setup over
LAN instead of you typing on a soft keyboard.

```sh
apk add openssh && ssh-keygen -A && passwd
sed -i 's/^#\?Port .*/Port 22000/' /etc/ssh/sshd_config
/usr/sbin/sshd
```

Ports below 1024 are unavailable (the app is unprivileged). The session dies
when iSH leaves the foreground; `cat /dev/location > /dev/null &` extends that
via background location but is battery-hungry and unreliable
(ish-app/ish#1613, #2195). Tailscale cannot help — the iOS app ships no CLI,
so `tailscale serve` does not exist there.

## Deliberate non-decisions

Recorded so they are not relitigated.

| Not doing | Why |
|---|---|
| **No `alpine` profile** | `.profile` expresses user role, never OS/arch facts — the same rule that removed `macos_intel`. It would also imply ansible support that would need ~166 new apk branches |
| **No apk support in ansible** | Negative ROI for a 32-bit emulator whose own community recommends staying on an EOL branch |
| **No separate `dotfiles-ios` repo** | The Windows companion earns independence with 298 files, a different shell language, and a real `windows-latest` CI gate. iSH's deployable surface is ~6 files and **no CI can exist** — no runner can emulate "Alpine x86 under iSH". An unverifiable six-file repo rots |
| **No per-file opt-out for `dot_config/shell/**`** | Only iSH would want it, and iSH should hand-copy instead |

Revisit if: Apple ships a general JIT entitlement; you start managing configs
for several iOS apps (>~20 files); or a CI-runnable non-SSE2 x86 Alpine
environment appears.

**The trap to avoid**: this repo fails *cleanly* on Alpine — ansible no-ops
silently, the shell layer loads without errors. It looks one patch away from
working. It is not: the destination is an environment that takes minutes to
open a shell and cannot run a single agent.

## See also

- [glibc and musl](../glibc-and-musl.md)
- [fleet-hosts](../tools/fleet-hosts.md) — the picker now lands you in a
  resumable tmux session, which is what makes a mobile client usable
- [copilot-claude-proxy](../tools/copilot-claude-proxy.md)
