# Freeze — code & terminal output → image

[charmbracelet/freeze](https://github.com/charmbracelet/freeze) generates static images (PNG / SVG) of source code or arbitrary terminal output. Unlike VHS (which records sessions), Freeze is a one-shot snapshot — better for issue reports, blog posts, and PR thumbnails.

- **Install**:
  - macOS — Homebrew (managed by `dot_ansible/roles/devtools/tasks/main.yml` macOS list)
  - Linux — GitHub release tarball into `~/.local/bin/freeze` (managed by `dot_ansible/roles/devtools/tasks/main.yml` `# --- freeze (Charm) ---` block)
- **Verify**: `freeze --version`
- **Status in this repo**: installed, no usage yet — pull it in when you next need a clean code screenshot.

---

## Two modes

```bash
# 1) Source file → image (auto-detects language by extension)
freeze main.py --output code.png
freeze README.md --output readme.png

# 2) Terminal output → image (-x runs the command and captures ANSI)
freeze --execute "ls -la" --output ls.png
freeze --execute "git log --oneline -n 10" --output gitlog.png
```

Mode 1 is the everyday case (paste pretty code into Slack / Notion / a slide). Mode 2 is for when you specifically want the terminal aesthetic, ANSI colors and all.

---

## Common flags

```bash
# Theme (Charm ships ~50 — see `freeze --help`)
freeze main.py -o code.png --theme "catppuccin-mocha"

# Window decorations (mac-style traffic lights)
freeze main.py -o code.png --window
freeze main.py -o code.png --window --border.radius 8 --shadow.blur 20

# Font + size
freeze main.py -o code.png --font.family "JetBrains Mono" --font.size 14

# Line numbers + range
freeze main.py -o code.png --show-line-numbers --lines 10,40

# Background + padding
freeze main.py -o code.png --background "#1E1E2E" --padding 30

# Multiple in one go via config file
freeze --config ~/.config/freeze/default.json main.py -o code.png
```

`freeze --help` lists every flag; the upstream README has a visual gallery of themes and window styles.

---

## Recommended config

Save a per-user default so every screenshot has the same aesthetic without flag noise. Charm reads `~/.config/freeze/default.json` automatically when no `--config` is passed:

```jsonc
// ~/.config/freeze/default.json — NOT managed by this repo (private)
{
  "theme": "catppuccin-mocha",
  "background": "#1E1E2E",
  "border": { "radius": 8, "thickness": 0 },
  "shadow": { "blur": 20, "x": 0, "y": 4 },
  "window": true,
  "padding": [20, 30],
  "margin": [0, 0],
  "font": { "family": "JetBrains Mono", "size": 14, "ligatures": true }
}
```

Catppuccin Mocha matches this repo's tmux/starship default theme. If you switch to `tmux2k`, swap to `dracula` or `nord`.

---

## Usage patterns

### Code review thumbnail

```bash
# Snapshot the changed hunk for a PR cover image
git diff HEAD~1 -- src/foo.py | freeze --language diff -o /tmp/pr.png
```

### Issue report

```bash
# Bake the failing command + traceback into a single image
freeze --execute "pytest tests/test_broken.py" -o /tmp/issue.png
```

`freeze --execute` runs the command, captures stdout AND stderr with ANSI colors preserved, then renders. Useful when the bug repro is "this colored output looks wrong".

### Snippet from a long file

```bash
freeze src/auth.py --lines 42,67 --show-line-numbers -o snippet.png
```

`--lines` takes a comma-separated `start,end` (1-indexed). Combine with `--show-line-numbers` so reviewers can cross-reference the file.

### SVG for blog posts

```bash
freeze main.py -o code.svg
```

SVG output is theme-aware (light/dark via media queries), scales infinitely, and is typically 5–10× smaller than the equivalent PNG. Drop into hugo/zola/jekyll posts and let the browser render.

---

## Where to use it in this repo (future)

The repo has no `freeze`-generated images today. Plausible uses if/when adding visual docs:

- `docs/playbooks/linux-gui-apps.md` — snippet of the decision-tree YAML
- `docs/this_repo/upgrades.md` — sample `just upgrade` output
- `docs/tools/aicapture.md` — `aifix` invocation with the highlighted prompt
- README — small SVG snippets of starship prompt / tmux status bar

When you add one, drop the source `.png` / `.svg` next to the doc (e.g., `docs/playbooks/linux-gui-apps.snippet.png`) and reference relatively.

---

## Tips

- **Determinism** — pin font, theme, padding via config so two screenshots of the same code byte-match. Aids review.
- **Font fallbacks** — if the named font isn't installed, `freeze` silently falls back to a built-in monospace. Install Nerd Fonts via this repo's `dot_ansible/roles/fonts/` if your config references one.
- **Width control** — long lines can wrap or get truncated. Use `--width` to force a column count (e.g., `--width 100`) or pre-format with `fmt -w 100`.
- **Don't snapshot secrets** — `freeze --execute` captures whatever the command prints. Same warning as VHS: skip `cat .env`, redact tokens before snapshotting.

---

## See also

- [VHS](vhs.md) — for **moving** demos (terminal sessions → GIF / MP4)
- [Glow](glow.md), [Gum](gum.md) — the rest of the Charm CLI ecosystem
- [`bat`](https://github.com/sharkdp/bat) — for syntax-highlighted terminal-only output (no image)
