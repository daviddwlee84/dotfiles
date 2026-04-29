# Gum — shell-script-friendly TUI prompts

[charmbracelet/gum](https://github.com/charmbracelet/gum) is a single-binary toolbox of TUI primitives (`choose`, `input`, `confirm`, `spin`, `filter`, `format`, `style`, `write`, `pager`) for use inside shell scripts. It bundles the same Bubble Tea / Bubbles / Lip Gloss UI behind a CLI, so scripts can have polished interactive UX without dragging in a Go build.

- **Install**:
  - macOS — Homebrew (managed by `dot_ansible/roles/devtools/tasks/main.yml` macOS list)
  - Linux — GitHub release tarball into `~/.local/bin/gum` (managed by `dot_ansible/roles/devtools/tasks/main.yml` `# --- gum (Charm) ---` block)
- **Verify**: `gum --version`
- **Status in this repo**: installed, not yet wired into existing scripts. See [Where it would fit](#where-it-would-fit-future-refactors) below.

---

## Cheat sheet

```bash
# Pick one
choice=$(gum choose --header "Pick action" "train" "test" "deploy")

# Pick many (space toggles, enter confirms)
items=$(gum choose --no-limit --header "Pick keys to import" id_rsa github_key work_key)

# Free-text input
name=$(gum input --placeholder "experiment name" --prompt "▸ ")

# Multi-line input
notes=$(gum write --placeholder "release notes (Ctrl+D when done)")

# Yes/no
gum confirm "Run now?" && ./run.sh

# Filter a list with fuzzy search (think gum-flavored fzf)
host=$(printf '%s\n' alpha beta gamma | gum filter --placeholder "host…")

# Spinner around a long command
gum spin --title "Building…" --spinner dot -- bash -c 'sleep 3 && echo done'

# Style standalone text
gum style --foreground 212 --border double --padding "1 2" "Hello $USER"

# Format markdown / code in-line
gum format -- "# Header" "" "- bullet **bold**"

# Page through long output (alternative to less)
some-long-command | gum pager
```

`gum --help` lists every subcommand; each subcommand has its own `--help` with all flags.

---

## Why it pairs well with this dotfiles repo

- **No Bash boilerplate** — replaces `read -p` / `select` / hand-rolled menus with one-liners that already handle keyboard navigation, escape-to-cancel, and reasonable defaults.
- **Single static binary** — installs identically on macOS / Linux / WSL via Homebrew or GitHub release; same script works everywhere.
- **Composable with pipes** — every output goes to stdout, so `gum choose | xargs -I{} …` plugs straight into existing pipelines.
- **Honors `NO_COLOR`** — falls back to plain output when stdout isn't a TTY or `NO_COLOR=1` is set, so scripts can be piped without breakage.

---

## Common patterns

### `gum choose` for menus that outgrow tmux's `display-menu`

The tmux popup menu (`dot_config/tmux/executable_menu.sh`) currently uses a tier-based fallback to fight tmux's silent-fail-when-too-tall bug (see `pitfalls/tmux-display-menu-silent-fail.md`). `gum choose` has no row cap and renders the same menu without tiering:

```bash
# Instead of `tmux display-menu -T '...' "Last window" Tab last-window …`
choice=$(gum choose --header "tmux menu" --height 20 \
  "Last window" "Last pane" "Choose window" "Choose session" \
  "Pane numbers" "Sesh picker" "Lazygit" "New window" \
  "Split |" "Split -" "Zoom" "→ Layouts" "→ Theme" "→ Cheatsheet")
case "$choice" in
  "Last window") tmux last-window ;;
  …
esac
```

### `gum confirm` instead of `read -r yes_no`

```bash
# Before
read -r -p "Overwrite [y/N]? " ans
[[ "$ans" =~ ^[Yy] ]] && do_thing

# After
gum confirm --default=No "Overwrite?" && do_thing
```

### `gum spin` to silence a noisy long-runner

```bash
# Hide the chatty output of a slow command behind a spinner
gum spin --show-output --title "chezmoi apply" -- chezmoi apply -v
```

`--show-output` keeps stdout streaming under the spinner; drop it to fully suppress.

### `gum input --password` for secrets

```bash
# Reads without echoing; pipe straight into a sudo helper
gum input --password --placeholder "sudo password" \
  | install -m 0600 /dev/stdin /tmp/sudo-pass
```

### `gum filter` as an `fzf` alternative for one-shot pickers

`fzf` is still the right tool for ZLE keybindings (`Ctrl+T`, `Ctrl+R`) — its preview window and bindings are tighter. `gum filter` shines when you want consistent Charm styling inside a script that already uses other gum primitives.

---

## Where it would fit (future refactors)

These spots in the repo are documented as gum candidates but were intentionally left untouched in the install PR. When you next touch them, consider the swap:

| File | Current UX | gum sketch |
|---|---|---|
| `dot_config/tmux/executable_menu.sh` | tier-based `display-menu` (~14-row cap) | `gum choose --height N` |
| `dot_config/tmux/executable_menu-theme.sh` | 2-row `display-menu` | `gum choose "catppuccin" "tmux2k"` |
| `scripts/import_ssh_to_bw.sh` | `read -r choice` + manual parse | `gum choose --no-limit` + `gum confirm` |
| `scripts/upgrade_tools.sh` | CLI args only | `gum choose --no-limit` for category multi-select when called with no args |

Don't bulk-refactor — the existing scripts work, and tmux integration in particular has subtle invariants (see `CLAUDE.md` → "Tmux ≥ 3.3 required for popup menu"). Swap one at a time, when you're already in the file for another reason.

---

## Environment / styling

Gum reads `GUM_*` env vars to set defaults globally. Useful ones:

```bash
# In ~/.config/zsh/tools/99_local.zsh (private)
export GUM_INPUT_CURSOR_FOREGROUND="#FF6188"
export GUM_INPUT_PROMPT_FOREGROUND="#A9DC76"
export GUM_CHOOSE_CURSOR_FOREGROUND="#FFD866"
```

Full list: `gum --help` after each subcommand. The repo doesn't ship gum-wide defaults — keep them user-local so SSH sessions to other hosts inherit the upstream defaults.

---

## Tips

- **Cancellation** — `Esc` cancels and exits with non-zero. Always use `set -o pipefail` or check the exit code: `choice=$(gum choose …) || exit 0`.
- **Empty arrays** — `gum choose --no-limit` with nothing selected exits 0 with empty stdout. Guard with `[[ -n "$choice" ]] || exit 0`.
- **TTY detection** — gum auto-disables interactivity when stdin isn't a TTY (e.g., inside a pipe). For tests, pass `--height` and pre-feed stdin via heredoc.
- **In tmux popups** — `gum choose` works inside `tmux display-popup -E -- gum choose …`. Use `-w 60% -h 60%` to size the popup.

---

## See also

- [Glow](glow.md), [VHS](vhs.md), [Freeze](freeze.md) — the rest of the Charm CLI ecosystem
- [Fzf](fzf.md) — the established fuzzy-finder; complementary, not replaced
- [tmux overview](tmux/README.md) — popup menus and the `display-menu` height limit
