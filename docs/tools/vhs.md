# VHS — terminal demo recorder

[charmbracelet/vhs](https://github.com/charmbracelet/vhs) records terminal sessions to GIF / MP4 / WebM from a `.tape` script. It headlessly replays your typed commands inside a virtual terminal and produces a deterministic, reviewable artifact — perfect for README demos, bug reproductions, and PR review aids.

- **Install**:
  - macOS — Homebrew (managed by `dot_ansible/roles/devtools/tasks/main.yml` macOS list). On macOS, Homebrew also pulls in `ttyd` and `ffmpeg` automatically as runtime deps.
  - Linux — GitHub release tarball into `~/.local/bin/vhs` (managed by `dot_ansible/roles/devtools/tasks/main.yml` `# --- vhs (Charm) ---` block). **Runtime deps `ttyd` and `ffmpeg` are NOT auto-installed** — see [Linux runtime dependencies](#linux-runtime-dependencies) below.
- **Verify**: `vhs --version`
- **Status in this repo**: installed, no `.tape` files yet. Create them under `docs/_demos/*.tape` if you start recording.

---

## Hello world

```bash
cat <<'TAPE' > /tmp/hello.tape
Output /tmp/hello.gif
Set FontSize 18
Set Width 800
Set Height 400
Type "echo Hello, VHS"
Enter
Sleep 1s
TAPE

vhs /tmp/hello.tape
file /tmp/hello.gif    # → GIF image data
```

Open the GIF in any image viewer (`open` on macOS, `xdg-open` on Linux, or drop into Slack / a PR description).

---

## Linux runtime dependencies

`vhs` shells out to `ttyd` (web-based PTY) and `ffmpeg` (video encoder). On Linux these are usually missing — install them once on each host that will record:

```bash
# Ubuntu / Debian
sudo apt install ffmpeg
# ttyd has no .deb in the default repos — use the prebuilt static binary:
curl -L "https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.$(uname -m)" \
  -o ~/.local/bin/ttyd && chmod +x ~/.local/bin/ttyd

# Verify
ttyd --version
ffmpeg -version | head -1
```

The ansible role deliberately does NOT auto-install these — `ffmpeg` is a heavy dep (50+ MB transitively) and `ttyd` doesn't have a clean apt path on every supported Ubuntu release. Recording is opt-in, so the dep install is opt-in too.

If `vhs` runs but produces a 0-byte output, that's almost always a missing `ttyd` or `ffmpeg`. `vhs --help` lists the path it expects.

---

## `.tape` script primer

A `.tape` file is a flat list of commands. Highlights:

```text
# Output target (one per file)
Output demo.gif
# Output demo.webm    # also supported
# Output frames/      # dump individual PNG frames

# Settings (apply to whole tape)
Set Shell zsh
Set FontSize 16
Set FontFamily "MonoLisa, JetBrainsMono Nerd Font"
Set Theme "Catppuccin Mocha"
Set Width 1200
Set Height 600
Set Padding 20
Set TypingSpeed 50ms
Set PlaybackSpeed 1.0
Set LoopOffset 0%

# Hide setup commands (typed but not shown in output)
Hide
Type "cd ~/scratch && clear"
Enter
Show

# Visible interactions
Type "ls -la"
Enter
Sleep 1s

Type "echo waiting"
Enter
Sleep 500ms

# Press special keys
Ctrl+C
Backspace 5
Enter
Tab
Escape

# Wait for a prompt regex before continuing (vhs ≥ 0.7)
Wait /\$\s$/
```

Full reference: `vhs --help` and the upstream `examples/` directory.

---

## Recording a real workflow demo

Skeleton for showing off something this repo actually does — e.g., `fleet-apply`:

```text
# docs/_demos/fleet-apply.tape
Output fleet-apply.gif
Set Shell zsh
Set FontSize 16
Set Theme "Catppuccin Mocha"
Set Width 1400
Set Height 800
Set TypingSpeed 60ms

Hide
Type "cd ~/.local/share/chezmoi && clear"
Enter
Show

Type "just fleet-apply --status"
Enter
Sleep 3s

Type "just fleet-apply"
Enter
Sleep 8s

Type 'q'    # exit watch view
```

Then commit the `.tape` (small, reviewable) and the rendered `.gif` (binary, large but reviewable in PR diff). Keep tapes deterministic — avoid commands that hit the network or clocks unless that's the point of the demo.

---

## Where to put tapes

This repo doesn't have an established convention yet. When you record the first one, suggested layout:

```
docs/_demos/
  fleet-apply.tape
  fleet-apply.gif
  sesh-tmux.tape
  sesh-tmux.gif
```

Underscore prefix keeps it out of the MkDocs nav. Embed in a doc page with a normal markdown image:

```markdown
![fleet-apply demo](../_demos/fleet-apply.gif)
```

If GIFs end up large (> 5 MB), reach for `Output demo.mp4` and embed via raw HTML — most browsers play inline MP4 in markdown viewers, and the file is typically 3–10× smaller.

---

## Tips

- **Reproducible recordings** — pin `Set TypingSpeed`, `Set PlaybackSpeed`, and avoid wall-clock-dependent commands. Two `vhs run X.tape` invocations should produce byte-identical output.
- **Catppuccin theme** — `Set Theme "Catppuccin Mocha"` matches this repo's tmux / starship aesthetic.
- **`vhs serve`** — runs a local HTTP UI for iterating on a tape. Saves the round-trip of `vhs file && open file.gif`.
- **CI rendering** — keep `.tape` source-of-truth and re-render `.gif` in CI on demand. The repo doesn't currently do this; would need `ffmpeg` + `ttyd` in the CI image.
- **Don't record secrets** — `vhs` captures whatever is on screen; use `Hide` blocks around any `cat ~/.env` or `gh auth status` that prints tokens.

---

## See also

- [Glow](glow.md), [Gum](gum.md), [Freeze](freeze.md) — the rest of the Charm CLI ecosystem
- [Freeze](freeze.md) — for **static** code/output screenshots, where a GIF is overkill
