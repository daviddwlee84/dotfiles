# tmux server exits when entering copy-mode (3.6a homebrew bottle, macOS)

**Symptoms** (grep this section):

- Status line shows `[server exited unexpectedly]` after a long-running session (anywhere from ~100 minutes to ~8 days uptime)
- Triggers when entering copy-mode (`prefix + [` by default; in this repo also via `prefix + b` / scroll wheel / clicking on past output to enter selection)
- All panes / windows / sessions die at once — `tmux ls` after the crash returns `no server running on /private/tmp/tmux-501/default`
- macOS Diagnostic Report at `~/Library/Logs/DiagnosticReports/tmux-YYYY-MM-DD-HHMMSS.ips` contains:
  - `"signal":"SIGABRT"` / `"indicator":"Abort trap: 6"` / `"type":"EXC_CRASH"`
  - `___BUG_IN_CLIENT_OF_LIBMALLOC_POINTER_BEING_FREED_WAS_NOT_ALLOCATED` in the symbol list (libmalloc abort = double-free or invalid free)
  - Stack frames in this exact order: `cmd_copy_mode_exec` → `window_pane_set_mode` → `window_copy_init` → `window_copy_clone_screen` → `screen_reinit` → `grid_clear_lines` → `grid_free_line`
  - `"asi": {"libsystem_c.dylib": ["crashed on child side of fork pre-exec"]}` — appears in every report; **unrelated diagnostic noise from libsystem_c**, not the actual fault. Don't chase.
  - `slice_uuid: 1b2d8e7b-bb77-3465-8bab-73f5bbaffe49` — fingerprint of the homebrew `tmux 3.6a` bottle. If your `.ips` has this UUID, you have this exact bug.
- Terminal **does not matter** — upstream reports include alacritty, ghostty, iTerm2; locally we hit it under alacritty.
- `tmux-resurrect` saved snapshot is intact — relaunching `tmux` + `tmux-continuum` restores layout, but in-pane process state (agent conversations, nvim buffers) is lost.

**First seen**: 2026-04-28 (locally; upstream first report 2025-12-23)
**Affects**: `tmux 3.6a` homebrew stable bottle on macOS 26.x / Apple Silicon. Issue is **terminal-agnostic and CPU-vendor-agnostic** within Apple Silicon (M3 Max / M4 Pro / Mac16,10 all confirmed upstream).
**Status**: **fixed upstream** in commit [`035a2f3`](https://github.com/tmux/tmux/commit/035a2f35d40628dcfe235179220fc0ede848a195) (2026-01-06); **not yet released as a tagged version** — homebrew `tmux 3.6a` bottle is the latest stable as of 2026-04 and still ships the bug.

## Symptom

After a long-running tmux session (uptime varies wildly: 100 minutes locally, 12 hours, 25 hours, 8 days in upstream reports), entering copy-mode aborts the entire tmux server with `Abort trap: 6`. From the user's POV: **the terminal redraws once, the tmux status bar disappears, and you're back in the bare login shell**. All sessions, all panes, all running processes die simultaneously.

The `.ips` Diagnostic Report shows libmalloc abort during `grid_free_line` — i.e. tmux is freeing a grid line whose backing allocation was already freed (or was never on the heap). The release path is initiated by copy-mode entry: when you press `prefix + [`, tmux clones the current screen into a copy-mode-owned screen via `window_copy_clone_screen`, which calls `screen_reinit` → `grid_clear_lines` → `grid_free_line` on the destination grid before populating it with the cloned content. The double-free triggers there.

## Root cause

A bug in `screen_reinit` / `grid_clear_lines` introduced in the 3.6 line. Long-running sessions accumulate the precondition (specifics in the upstream commit) and entering copy-mode triggers the abort. Fixed in [tmux/tmux@035a2f3](https://github.com/tmux/tmux/commit/035a2f35d40628dcfe235179220fc0ede848a195).

Upstream tracking: [tmux/tmux#4777](https://github.com/tmux/tmux/issues/4777) — closed 2026-01-06, fix verified by reporters running master for ~2 weeks without recurrence ([comment](https://github.com/tmux/tmux/issues/4777#issuecomment-3784173705)).

## Workaround

**Until tmux 3.7 / 3.6b ships** with the fix, switch the local install to `--HEAD`:

```bash
# 1. Save anything you care about — running tmux server must die.
tmux ls                          # confirm what's running first

# 2. Kill the server (otherwise the new binary won't be picked up;
#    a running tmux server keeps the old binary mapped in memory).
tmux kill-server

# 3. Reinstall from master.
brew install --HEAD tmux
# OR if already installed: brew reinstall --HEAD tmux

# 4. Verify.
tmux -V                          # should show "tmux next-3.7" or similar (HEAD marker)
which tmux                       # /opt/homebrew/bin/tmux
```

After 3.7 (or 3.6b) is tagged on homebrew-core, revert to the bottle:

```bash
tmux kill-server
brew uninstall tmux
brew install tmux                # back to stable bottle (no --HEAD)
tmux -V                          # confirm 3.7+ or 3.6b
```

### Trade-offs of `--HEAD`

- **No bottle, no `brew upgrade` auto-pull.** `brew upgrade tmux` won't refresh a `--HEAD` install with new master commits. To pick up new fixes you must `brew reinstall --HEAD tmux` (which downloads the latest master and rebuilds locally).
- **Local build means Xcode CLT is required.** `xcode-select --install` if you don't already have it; the user already does on this Mac.
- **ABI churn risk.** When dependencies (libevent, ncurses, openssl, utf8proc) get bumped by `brew upgrade`, a `--HEAD`-built binary may need `brew reinstall --HEAD tmux` to relink. If `tmux` starts segfaulting at startup after an unrelated `brew upgrade`, the relink fixed it 99% of the time.
- **Master can break.** Upstream tmux master is generally stable but is not a release. If you hit a different bug, `brew uninstall tmux && brew install tmux` returns to 3.6a (which has *this* bug — pick your poison until 3.7 ships).

## Why ansible / Linuxbrew / tmux-appimage paths are not affected

The repo's Linux upgrade paths in [`dot_ansible/roles/devtools/tasks/main.yml`](../dot_ansible/roles/devtools/tasks/main.yml#L1933-L1953) (Linuxbrew or `nelsonenzo/tmux-appimage`) target a **different** tmux problem (the 3.2a popup-clamp invariant in `AGENTS.md` → "Tmux ≥ 3.3 required for popup menu"). They install whatever Linuxbrew ships (also 3.6a today, also vulnerable on Apple-Silicon-Linux ARM hosts in theory) or whatever `tmux-appimage` cuts (currently 3.4 — older, may also be vulnerable but no upstream reports on Linux yet).

If a Linux host hits the same `.ips`-equivalent (Linux core dump showing the same stack), the workaround on Linuxbrew hosts is the same: `brew install --HEAD tmux`. On `tmux-appimage` hosts, build from source manually until 3.7 lands. Don't preemptively retrofit; only one upstream user has ever reported hitting this on Linux.

## Prevention

- **Don't paper over with config.** No `set -g …` change in `dot_config/tmux/common.conf` mitigates this — it's a heap bug in the binary, not a config-driven behaviour.
- **Don't avoid copy-mode.** Restricting your own muscle memory is not a real workaround for a daily driver tool.
- **Watch for the tmux 3.7 (or 3.6b) tag.** When it lands on `homebrew-core`, switch back to bottle (steps above). [TODO entry](../TODO.md) tracks this.
- **If a new machine joins the fleet with macOS + Apple Silicon + tmux installed via `brew install tmux`**, follow the workaround proactively (one `brew reinstall --HEAD tmux` saves a 100-minute-to-8-day surprise later).

## Related

- Upstream issue: [tmux/tmux#4777](https://github.com/tmux/tmux/issues/4777)
- Upstream fix commit: [`035a2f3`](https://github.com/tmux/tmux/commit/035a2f35d40628dcfe235179220fc0ede848a195)
- [`AGENTS.md` → Tmux ≥ 3.3 required for popup menu](../AGENTS.md) — adjacent invariant about a **different** tmux version-related failure (popup-clamp on 3.2a). The 3.3 floor doesn't help here; this bug requires 3.7 (or `--HEAD`).
- [`pitfalls/tmux-resurrect-agents.md`](tmux-resurrect-agents.md) — what's lost when the server dies (layout restored, agent conversation state isn't).
- [`pitfalls/tmux-display-menu-silent-fail.md`](tmux-display-menu-silent-fail.md) — another "tmux silently fails with no error" trap (different cause, similar mental model: don't blame your config first).
- [`pitfalls/yazi-tmux-popup-crash.md`](yazi-tmux-popup-crash.md) — the *other* known way to crash the tmux server in this repo's setup (display-popup + yazi). Different stack, different fix; cross-linked because both produce `[server exited unexpectedly]`.
- macOS triage: `~/Library/Logs/DiagnosticReports/tmux-*.ips` (JSONL — `head -1` is the manifest, body is a single JSON blob with `threads[0].frames`). Compare `slice_uuid` to identify the binary; compare `frames` to identify the stack.
