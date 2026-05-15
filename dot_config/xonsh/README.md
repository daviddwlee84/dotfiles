# ~/.config/xonsh/ — Xonsh extension sandbox

The main `~/.xonshrc` is intentionally minimal (PATH, prompt, vim-mode gate,
xontrib loads, extension hooks). Personal additions belong **here**, so the
managed `~/.xonshrc` template stays small enough to read top-to-bottom.

## Files

| File          | Role |
|---            |---   |
| `rc.xsh`      | Versioned starter — Python-flavor aliases / helpers. Sourced by `~/.xonshrc` if present. |
| `~/.xonshrc.local` (not in this dir, not managed) | Untracked machine-local overrides. Mirrors the `~/.shellrc.secrets` rule — never auto-created. |

## Why this layout

Same three-tier split that `dot_config/{shell,zsh,bash}/` uses, scaled down for
a secondary shell:

- **Managed minimum** → `~/.xonshrc` (`dot_xonshrc.tmpl` in repo root)
- **Versioned extensions** → `~/.config/xonsh/rc.xsh` (this dir)
- **Per-machine secrets / overrides** → `~/.xonshrc.local` (you create it,
  chezmoi never touches it)

See [docs/shells/xonsh.md](../../docs/shells/xonsh.md) for the full story.
