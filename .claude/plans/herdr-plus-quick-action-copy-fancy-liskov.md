# Fix silent OSC 52 clipboard failure for large scrollback copies

## Context

User question: does herdr-plus's Quick Action "copy pane" cross the SSH boundary, or is it local-only? Investigation confirmed `dot_config/herdr/executable_pane-copy.sh` already delegates to the repo's own `x copy` (`dot_dotfiles/bin/executable_x`), which auto-selects pbcopy/wl-copy/xclip/xsel and falls back to OSC 52 over bare SSH — so the mechanism the user thought might be missing (`x`'s cross-platform/SSH copy) is already wired in. No new backend is needed.

While confirming this, the user reported a concrete symptom: over SSH, copying **scrollback** (`prefix+S` / "Copy pane: content (scrollback)", i.e. `pane-copy.sh content --source recent`) did not land in the local clipboard, while copying process info / coord / cwd / dir (all short payloads) worked fine.

Root cause, confirmed by reading `executable_x` and this repo's own docs (`docs/tools/clipboard.md:170`, which already documents that OSC 52 is terminal-size-limited — "iTerm2 caps at 1 MB, many others at 64-256 KB"):

- `osc52_copy()` (`dot_dotfiles/bin/executable_x:61-76`) base64-encodes the entire payload and writes it to `/dev/tty` in one `printf`, with **no size check, no chunking, no warning**.
- OSC 52 has no delivery acknowledgment — the `write(2)` to `/dev/tty` succeeds regardless of whether the terminal on the other end accepts or silently drops an oversized escape sequence.
- `pane-copy.sh`'s `copy()` → `x copy` → `osc52_copy()` chain therefore returns success (exit 0) even when the terminal dropped the payload, so `pane-copy.sh:143`'s `echo "copied $source content for $pane"` fires unconditionally.
- Full pane scrollback easily exceeds the smallest common terminal caps (64-256 KB); process-info/coord/cwd/dir payloads are a handful of lines and always stay well under any cap. This exactly matches the reported pattern.

Second question (git pull rebase): already resolved, no action needed — `pull.rebase = true` + `rebase.autoStash = true` are already set globally via `modify_dot_gitconfig.tmpl:42-45`.

## Fix: make the OSC 52 size cap loud instead of silent

Add a payload-size guard to `osc52_copy()` in `dot_dotfiles/bin/executable_x` (the single shared clipboard backend — this fixes the failure mode for every consumer, not just herdr's `pane-copy.sh`). Follow the file's existing convention: other backends in `copy_backend()` print a specific `err "..."` and `exit 1` when the backend is available but execution fails (as opposed to `return 1`, which is reserved for "this backend isn't applicable here, try the next one").

```sh
osc52_copy() {
    [[ -w /dev/tty ]] || return 1
    command -v base64 >/dev/null 2>&1 || return 1

    local data
    data="$(base64 | tr -d '\n')"
    [[ -n "$data" ]] || return 0

    local max_len="${X_OSC52_MAX_BYTES:-75000}"
    if (( ${#data} > max_len )); then
        err "OSC 52 payload too large (${#data} bytes, cap ${max_len}); most terminals silently drop larger OSC 52 sequences (64-256KB is common, iTerm2 ~1MB)"
        err "tip: copy a smaller selection, or raise the cap: X_OSC52_MAX_BYTES=<n> x copy ..."
        exit 1
    fi

    if [[ -n "${TMUX:-}" ]]; then
        ...
    else
        ...
    fi
}
```

- Threshold defaults to `75000` (base64 chars) — comfortably above normal use (a paragraph, a stack trace, a visible pane screen) but below the smallest commonly-documented terminal cap, so it only trips for genuinely oversized payloads like full scrollback dumps.
- Overridable via `X_OSC52_MAX_BYTES` env var for users on terminals with a larger cap (e.g. iTerm2's ~1 MB).
- `exit 1` (not `return 1`) so `copy_backend()` does NOT also print the generic "no clipboard backend found" help text on top of this specific message — matches how `pbcopy`/`wl-copy`/`xclip`/`xsel` branches already behave on execution failure.
- Because `pane-copy.sh` runs under `set -eu` with no `pipefail`-masking here, `copy "$body"`'s new non-zero exit propagates and aborts the script **before** the misleading `echo "copied $source content for $pane"` line — the user now sees the real error instead of a false success message.

### Docs update (same commit)

`docs/tools/clipboard.md`:
- Add a row to the **Common failure modes** table (~line 155-164): large OSC 52 payload (e.g. full pane scrollback) silently dropped by the terminal → `x copy` now detects and reports this (as of this fix) instead of reporting false success; fix is to copy a smaller selection or raise `X_OSC52_MAX_BYTES`.
- Extend the **Design notes** bullet at line 170 to mention the new size guard and the `X_OSC52_MAX_BYTES` override.

No changes needed to `pane-copy.sh` itself — the fix in the shared `x copy` backend is sufficient; the error now propagates naturally through the existing `set -eu` + unguarded `copy "$body"` call.

## Verification

- `printf 'x%.0s' {1..100000} | x copy` (bash brace expansion) over a plain SSH session (no `DISPLAY`/`WAYLAND_DISPLAY`) — should now print the new `err` diagnostic and exit 1, not silently "succeed".
- `printf 'short text' | x copy` — should still succeed normally (regression check on the common case).
- `X_OSC52_MAX_BYTES=200000 printf 'x%.0s' {1..100000} | x copy` — should succeed once the cap is raised past the payload size.
- Over herdr + SSH: `prefix+S` (scrollback copy) on a pane with a large scrollback should now surface the error instead of a false "copied" message; on a pane with modest scrollback it should still copy successfully.
- `shellcheck dot_dotfiles/bin/executable_x` (this repo shellchecks its scripts subtree per pre-commit) to confirm the new arithmetic/conditional doesn't trip `set -e` under `set -euo pipefail` (the `(( ... ))` is used only as an `if` condition, which is safe).
