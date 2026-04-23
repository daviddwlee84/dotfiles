# tmux2k bandwidth segment shows huge bogus number (uint64 underflow)

**Symptoms** (grep this section): `18446744073709551615K`, gigantic K/M/G value
in tmux status bar's bandwidth segment, status bar suddenly very wide,
`@tmux2k-right-plugins "bandwidth"` displaying nonsense
**First seen**: 2026-04 (when first noticed; bug existed earlier)
**Affects**: `2kabhishek/tmux2k` plugin, all versions tested through 2026-04,
the `bandwidth` segment specifically (other segments unaffected)
**Status**: workaround in place (segment removed from default config); no
upstream fix as of 2026-04

## Symptom

`bandwidth` segment in tmux2k's status bar occasionally renders as a huge
number like `18446744073709551615K` (= `2^64 - 1` kilobytes ≈ 18.4 exabytes).
The value sometimes flickers back to a sane reading, sometimes sticks.
Status bar visibly widens when this happens, pushing other segments off-screen
on narrow windows.

Reproduce: enable bandwidth in tmux2k right plugins, leave a tmux session
running long enough that the underlying bandwidth helper script's accumulator
wraps. Trigger varies by interface activity pattern; not deterministic.

## Root cause

`tmux2k`'s bandwidth segment script computes deltas between successive byte
counters from `ifconfig` / `ip` output. When the previous-counter snapshot is
larger than the current (interface reset, counter wrap, helper restart, or
just a stale snapshot), the unsigned subtraction underflows to near-`UINT64_MAX`
instead of returning a negative or zero value. The result gets formatted as a
"K"-suffixed number directly without sanity check.

This is a pure plugin bug — not a tmux core issue, not a terminfo issue, not
a Catppuccin-vs-onedark issue.

## Workaround

Drop the `bandwidth` segment. Edit `dot_config/tmux/theme.tmux2k.conf`:

```diff
- set -g @tmux2k-right-plugins "bandwidth network time"
+ set -g @tmux2k-right-plugins "network time"
```

After applying: `tmux source-file ~/.config/tmux/tmux.conf` then
`prefix + R` (or restart tmux server) so the plugin reloads.

If real-time throughput is needed for an investigation, use ad-hoc tools
instead of the status bar:

- macOS: `nettop` (sudo, real-time UI)
- Linux: `bmon`, `iftop`, `nload` (TUI, foreground)
- Either: `ifstat -i <iface> 1` for one-line-per-second logs

## Prevention

`AGENTS.md` "Cross-file maintenance rules → Keyboard shortcuts" already lists
tmux2k under the cross-tool conflict check; not promoting to a Hard invariant
because the failure is cosmetic (visible immediately, no silent state
corruption). Documented in:

1. `dot_config/tmux/theme.tmux2k.conf` — inline NOTE comment near the segment list
2. `docs/tools/tmux/themes.md` — troubleshooting section
3. This pitfall doc

Re-introduce the segment only if upstream ships a fix (check release notes or
diff `2k.tmux` script for the bandwidth helper).

## Related

- Backlog research that originally surfaced this: `backlog/tmux2k-tuning.md`
- TODO entry that tracks the workaround commit: `TODO.md` P1 "tmux2k bandwidth bug"
- Upstream: https://github.com/2kabhishek/tmux2k (search issues for "bandwidth"
  or "underflow" before re-introducing)
- The workaround commit also addresses the unrelated theme alignment issue
  (`@tmux2k-theme onedark` → `catppuccin`); keep them separate in your mental
  model since they're independent fixes.
