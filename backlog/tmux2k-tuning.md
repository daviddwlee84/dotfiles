# tmux2k tuning (bandwidth bug + theme alignment)

**Status**: P1 ready (two independent small changes)
**Effort**: S (both)
**Related**: `TODO.md` P1 · `dot_config/tmux/theme.tmux2k.conf` · `dot_config/tmux/theme.catppuccin.conf` · `docs/tools/tmux/themes.md`

## Context

2026-04, surfaced while reviewing the prompt + status-bar visual story end to
end (Ghostty theme → tmux theme → starship prompt → Neovim). Two tmux2k issues
became visible:

1. The `bandwidth` segment in `@tmux2k-right-plugins` has a known uint64
   underflow that occasionally renders as `18446744073709551615K`. The repo
   already documents this in the `theme.tmux2k.conf` file comment but still
   keeps the segment enabled.
2. tmux2k is configured with `@tmux2k-theme 'onedark'`, which clashes
   visually when switching between the Catppuccin tmux theme
   (`theme.catppuccin.conf`) and tmux2k. Ghostty/Neovim are Catppuccin; tmux2k
   onedark is the only odd one out.

## Investigation

### Bandwidth bug

From `dot_config/tmux/theme.tmux2k.conf` lines 28–30 (already in the file):

```conf
# NOTE: the `bandwidth` segment has a known uint64 underflow bug that can
# display 18446744073709551615K. See docs/tools/tmux/themes.md troubleshooting.
set -g @tmux2k-right-plugins "bandwidth network time"
```

The note exists but the workaround (drop the segment) wasn't applied.
Upstream issue: 2kabhishek/tmux2k tracker (search for "underflow" or
"bandwidth"). No fix shipped at time of writing.

Alternative throughput sources if the segment is missed:

- `nettop` (macOS, sudo, real-time UI)
- `bmon` / `iftop` (Linux, foreground TUI)
- Custom segment shelling out to `ifstat`/`vnstat`

For a status-bar use case (passive glance) the network segment alone (which
shows up/down state, not throughput) is usually enough. Drop bandwidth.

### Theme alignment

tmux2k bundled themes (per upstream `2k.tmux` source):
`onedark`, `catppuccin`, `nord`, `dracula`, `gruvbox`, `tokyo-night`,
`material`, `everforest`.

Switching `@tmux2k-theme 'onedark'` → `@tmux2k-theme 'catppuccin'` aligns
tmux2k with:

- `dot_config/tmux/theme.catppuccin.conf` (Catppuccin Mocha by default)
- Ghostty theme (Catppuccin variants per `dot_config/ghostty/config`)
- Neovim Catppuccin colorscheme

No layout change, only palette. Behaviour-equivalent.

## Options considered

### Bandwidth

| Option | Verdict |
|---|---|
| A. Drop `bandwidth`, keep `network time` | ✅ Simplest; loses throughput display |
| B. Replace with custom segment using `ifstat` | Higher effort; only worth it if throughput is actually missed in practice |
| C. Wait for upstream fix | Open-ended; no ETA |

Pick A. If throughput proves necessary later, add B as a follow-up.

### Theme

| Option | Verdict |
|---|---|
| A. `@tmux2k-theme 'catppuccin'` | ✅ Matches rest of stack |
| B. Keep `onedark` | Status quo; visual inconsistency |
| C. Custom theme via `@tmux2k-*` overrides | Overkill; bundled `catppuccin` is fine |

## Implementation

Single-file change to `dot_config/tmux/theme.tmux2k.conf`:

```diff
- set -g @tmux2k-theme 'onedark'
+ set -g @tmux2k-theme 'catppuccin'
  set -g @tmux2k-start-icon ""
  set -g @tmux2k-left-plugins "git cpu ram"
- # NOTE: the `bandwidth` segment has a known uint64 underflow bug that can
- # display 18446744073709551615K. See docs/tools/tmux/themes.md troubleshooting.
- set -g @tmux2k-right-plugins "bandwidth network time"
+ # NOTE: `bandwidth` segment dropped due to uint64 underflow bug
+ # (could display 18446744073709551615K). See docs/tools/tmux/themes.md.
+ # Re-add only if upstream ships a fix. Use ifstat/nettop for ad-hoc throughput.
+ set -g @tmux2k-right-plugins "network time"
```

After applying: `tmux source-file ~/.config/tmux/tmux.conf` then
`prefix + R` (or restart tmux server) to reload tmux2k plugin.

## Open questions

- Should `theme.catppuccin.conf` and tmux2k both pick up the same Catppuccin
  flavour (mocha/macchiato/frappe/latte) automatically? Currently both default
  to mocha so it's consistent, but if the `theme.catppuccin.conf` flavour is
  ever made dynamic (system light/dark sync), tmux2k won't follow. Not blocking
  the P1 changes; revisit if dynamic theme switching becomes a thing.

## References

- tmux2k upstream: https://github.com/2kabhishek/tmux2k
- `docs/tools/tmux/themes.md` (existing troubleshooting note)
- Today's session: `.specstory/history/2026-04-23_*.md`
