# Add `claude-copilot-once` — one-shot pinned Copilot session

## Context

The Copilot→Claude Code proxy in `dot_config/shell/43_copilot_proxy.sh` exposes two
"enable" layers:

- **`claude-copilot`** — per-process env injection, zero file writes. But Claude Code's
  settings precedence means an active `copilot-here` pin in `settings.local.json` *beats*
  inherited shell env (the documented Gotcha at `docs/tools/copilot-claude-proxy.md:226`),
  so pure env injection is the *weaker* mechanism.
- **`copilot-here on/off`** — writes/removes `./.claude/settings.local.json`, the strongest
  non-CLI layer, but it's **sticky**: you must remember to `copilot-here off` afterwards.

The user wants a single wrapper that combines the *reliability* of the `settings.local.json`
pin with the *ephemerality* of `claude-copilot`: pin this project, run one session, then
auto-unpin — and it should refuse (not silently start the proxy) if the proxy isn't up, and
remind the user how to stop the proxy at the end.

**Decisions (defaults chosen while user was away — easy to override):**
1. Name: **`claude-copilot-once`** (as suggested).
2. Session step reuses **`claude-copilot "$@"`** → specstory markdown auto-save, arg
   passthrough (`-c`), `--no-specstory` all for free. The env it injects is identical to
   what `copilot-here on` already pins, so the redundancy is harmless.
3. Docs: update **English only**; the two `*.zh-TW.md` mirrors are already stale (old
   `ericc-ch` pkg) — flagged, not touched. Can be refreshed on request.

## Files to modify

### 1. `dot_config/shell/43_copilot_proxy.sh` — new function + trap helper

Add a new section after `copilot-here` / before `copilot-model` (or at end of the toggle
section). Two functions:

```sh
# --- one-shot pinned session (Layer 2, auto-reverted) ---------------------------

# Combine copilot-here (settings.local.json pin — beats inherited env, see Gotchas)
# with claude-copilot's ephemerality: pin THIS project, run ONE specstory-wrapped
# session, then unpin — even on Ctrl-C / kill. The proxy must already be up (we only
# notify; start it with `copilot-proxy start`). If copilot-here is already ON here,
# the existing pin is left untouched on exit (safe to run inside a pinned project).
# Example:
#   claude-copilot-once                 # pin, run, auto-unpin
#   claude-copilot-once -c              # continue last session
#   claude-copilot-once --no-specstory  # raw claude, no markdown auto-save
claude-copilot-once() {
  case "${1:-}" in
    -h|--help)
      printf '%s\n' "Usage: claude-copilot-once [--no-specstory] [claude args...]"
      printf '%s\n' "  Pin THIS project to the proxy (copilot-here on), run one Claude Code"
      printf '%s\n' "  session, then auto-unpin (copilot-here off) — even on Ctrl-C."
      printf '%s\n' "  Needs the proxy already running:  copilot-proxy start"
      return 0 ;;
  esac

  # 1. Proxy must already be answering — notify only, never auto-start.
  if ! _copilot_alive; then
    printf '%s\n' "claude-copilot-once: proxy not reachable on port $(_copilot_port)." >&2
    printf '%s\n' "  start it first:  copilot-proxy start" >&2
    return 1
  fi
  # copilot-here needs jq — fail early with a clear message.
  if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' "claude-copilot-once: jq is required (used by copilot-here)" >&2
    return 1
  fi

  # 2. Don't clobber an existing pin: only turn OFF what we turn ON.
  local _cco_was_on=0
  if [ -f ".claude/settings.local.json" ] \
     && [ "$(jq -r '.env.ANTHROPIC_BASE_URL // empty' ".claude/settings.local.json" 2>/dev/null)" != "" ]; then
    _cco_was_on=1
  fi

  if [ "$_cco_was_on" = "0" ]; then
    copilot-here on || return 1
    # Auto-unpin even on Ctrl-C / kill. Mirror tmux_status_run's INT/TERM/HUP
    # trap + explicit normal-path cleanup; a bare function-scope EXIT trap would
    # fire on the wrong event when bash sources this file (see explore notes).
    trap '_copilot_once_trap' INT TERM HUP
  else
    printf '%s\n' "claude-copilot-once: copilot-here already ON here — leaving the pin in place on exit."
  fi

  # 3. One session — specstory-wrapped + arg passthrough (reuses claude-copilot).
  claude-copilot "$@"
  local _rc=$?

  # 4. Revert only what we enabled.
  if [ "$_cco_was_on" = "0" ]; then
    trap - INT TERM HUP
    copilot-here off
  fi

  # 5. We never auto-stop the proxy — remind how.
  printf '%s\n' "claude-copilot-once: session ended. Proxy still running on $(_copilot_base)."
  printf '%s\n' "  stop it when done:  copilot-proxy stop"
  return $_rc
}

# Internal: INT/TERM/HUP handler — unpin, clear trap, re-raise INT so the
# interactive shell sees correct exit semantics (mirrors _tmux_status_run_trap
# in dot_config/shell/60_tmux_status.sh).
_copilot_once_trap() {
  copilot-here off >/dev/null 2>&1
  trap - INT TERM HUP
  printf '\n%s\n' "claude-copilot-once: interrupted — unpinned (copilot-here off). Proxy still up." >&2
  kill -INT $$ 2>/dev/null
}
```

Design notes / why this shape:
- **Notify-only on proxy-down** matches the user's step 1 ("說沒有則提示") — no auto-start.
- **Prior-state guard** (`_cco_was_on`) makes it idempotent: running it inside a project the
  user already pinned won't unpin them.
- **Trap = `INT TERM HUP` + explicit clear on the normal path**, mirroring the repo's one
  portable idiom (`tmux_status_run` @ `dot_config/shell/60_tmux_status.sh:167-193`). The trap
  is cleared on *every* path where it's set, so no leak in zsh (which doesn't make traps
  function-local by default). In practice a foreground Ctrl-C is caught by `claude` itself and
  cleanup runs via the normal path; the trap covers shell-level TERM/HUP.
- **No `emulate -L zsh` / `pipefail` block** (unlike `copilot-proxy`/`copilot-model`): this
  function has no failure-sensitive pipelines — only a `jq` command substitution. Keeping it
  out avoids needless surface. (If we prefer internal consistency, the lightweight
  `[ -n "$ZSH_VERSION" ] && emulate -L zsh` guard is a safe add — flagging as optional.)

Also update the header **"Public surface:"** comment block (lines ~12-22) to list
`claude-copilot-once` right under `claude-copilot`.

### 2. `docs/tools/copilot-claude-proxy.md` — English guide

- Line **14** inline "Shell helpers" list: add `claude-copilot-once`.
- **Quick start** block (30-37): add a one-liner, e.g.
  `claude-copilot-once     # pin THIS project, run one session, auto-unpin`.
- **Settings-layer design** table (83-86): add a row on the pin side, e.g.
  `| \`claude-copilot-once\` | \`settings.local.json\` pin, auto-reverted | one session | automatic (unpins on exit) |`.
- **Shell helpers** section: add a new `### \`claude-copilot-once [--no-specstory] [args...]\` — one-shot pinned session`
  subsection after the `claude-copilot` one (ends line 135), explaining the pin+revert flow,
  the "proxy must be up" precondition, and the prior-pin guard.
- **Useful commands** block (316-325): add
  `claude-copilot-once                  # one-shot session via the settings.local.json pin`.

### 3. `docs/shells/aliases.md` — alias table (required by CLAUDE.md maintenance rule)

Add one row immediately after the `claude-copilot` row (line 791), same column format
(`Command | Type | Source File | Description`, `|` escaped as `\|` inside cells):

```
| `claude-copilot-once [--no-specstory] [args...]` | function | `dot_config/shell/43_copilot_proxy.sh` | One-shot Claude Code session via the **`copilot-here` pin** (`settings.local.json`), auto-reverted: checks the proxy is up (notifies, never auto-starts), `copilot-here on` → runs `claude-copilot` → `copilot-here off` on exit (even Ctrl-C). Leaves an existing pin untouched. Reminds how to `copilot-proxy stop`. |
```

## Out of scope / not needed

- **No tab completion** — the `copilot-*` are plain shell functions, not `executable_*` CLIs;
  the repo convention (CLAUDE.md) only mandates completions for `dot_dotfiles/bin/executable_*`.
  None of the sibling copilot functions have completions.
- **No `CLAUDE.md` edit** — its aliases rule is policy-only, no per-command inventory.
- **zh-TW mirrors deferred** — `docs/tools/copilot-claude-proxy.zh-TW.md` and
  `docs/shells/aliases.zh-TW.md` already lag English (old pkg/URL). Left untouched; noted in
  the final report as a separate refresh if wanted.

## Verification

1. **Both shells source cleanly** (POSIX subset check):
   `bash -n dot_config/shell/43_copilot_proxy.sh` and
   `zsh -n dot_config/shell/43_copilot_proxy.sh` → no errors.
2. **Proxy-down path**: with the proxy stopped, `claude-copilot-once` prints the
   "not reachable → copilot-proxy start" hint and returns non-zero; **no**
   `.claude/settings.local.json` is created.
3. **Happy path** (proxy up, dummy `claude` on PATH or `--no-specstory` + immediate exit):
   confirm `.claude/settings.local.json` is created during the run and removed after, and the
   "session ended … copilot-proxy stop" hint prints. Verify via `copilot-here status` before
   and after.
4. **Prior-pin guard**: run `copilot-here on` first, then `claude-copilot-once` → it announces
   "already ON … leaving the pin in place" and `copilot-here status` is still ON afterwards.
5. **Interrupt path**: Ctrl-C mid-session (or `kill -TERM`/`-HUP` the shell) → the pin is
   removed (`copilot-here status` = off) — no leaked `settings.local.json`.
6. **Docs build**: `uv run mkdocs build --strict` passes (the copilot page has internal
   anchors; the `## See also` slug `#copilot--claude-code-proxy` in aliases.md is unchanged).
7. Spot-check the rendered aliases table row and the new `###` subsection.
