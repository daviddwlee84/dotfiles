# `zsh: command not found: _nvm_lazy_load` in non-interactive shells (Claude Code Bash, scripts, CI)

**Symptoms** (grep this section):

```
zsh: command not found: _nvm_lazy_load
zsh: command not found: _nvm_lazy_load
zsh: command not found: _nvm_lazy_load
```

- Repeated 1–3× per `npx <pkg>` (or `npm`, `node`, `nvm`) call inside a non-interactive zsh — Claude Code's Bash tool, `zsh -c '…'` from a script, CI runners.
- The command still runs to completion afterwards (mise's `npx` shim eventually wins), but the error noise pollutes stdout/stderr and breaks `tail -n` / parsing.
- `~/.config/zsh/tools/02_legacy.zsh` exists on disk and defines `_nvm_lazy_load()` + `npx() { _nvm_lazy_load; npx "$@"; }` (and friends for `nvm`, `node`, `npm`).
- `chezmoi managed --include=files | grep 02_legacy` shows ONLY `.config/zsh/02_legacy_tools.zsh` (note: `_tools` suffix, parent dir, NOT `tools/`). The `tools/02_legacy.zsh` file is unmanaged.
- The chezmoi-managed `dot_config/zsh/02_legacy_tools.zsh` gates nvm sourcing behind `LOAD_NVM=1` and intentionally does NOT define lazy wrappers.

**First seen**: 2026-04-27 on `Da-Weis-Mac-mini`
**Affects**: macOS / Linux hosts that adopted chezmoi after already running a hand-rolled `~/.config/zsh/tools/` setup (the orphan dates back to a 2025-02-era pre-chezmoi config). Independent of nvm version, mise version, Node version.
**Status**: ad-hoc `rm` per host. **No `.chezmoiremove` enforcement** (deliberately — see [Workaround](#workaround) for rationale).

## Symptom

```bash
$ zsh -c 'npx some-pkg --version' 2>&1
zsh: command not found: _nvm_lazy_load
zsh: command not found: _nvm_lazy_load
zsh: command not found: _nvm_lazy_load
1.2.3
```

The exit code is still 0, but the noise breaks downstream parsers and confuses agents reading the output. Inside Claude Code's Bash tool the symptom is identical — the harness already passes commands through zsh, and the orphan loads regardless of `[[ -o interactive ]]`.

## Root cause

Two files with similar names live at different paths:

| Path | Origin | Defines wrappers? | Sources `nvm.sh`? |
|---|---|---|---|
| `~/.config/zsh/02_legacy_tools.zsh` | chezmoi-managed (`dot_config/zsh/02_legacy_tools.zsh`) | No | Only when `LOAD_NVM=1` |
| `~/.config/zsh/tools/02_legacy.zsh` | **orphan** — pre-chezmoi era, never tracked | **Yes** (`npx() { _nvm_lazy_load; npx "$@"; }` etc.) | Inside `_nvm_lazy_load`, on first wrapper call |

`dot_zshrc.tmpl` globs both `~/.config/zsh/*.zsh` and `~/.config/zsh/tools/*.zsh` for every shell — interactive or not. When the orphan loads, it conditionally defines `_nvm_lazy_load` + the four wrappers if `~/.nvm/nvm.sh` exists and `nvm` isn't already a shell function. Both conditions hold on this machine.

When you call `npx`, the wrapper fires:

1. `npx()` calls `_nvm_lazy_load`
2. `_nvm_lazy_load` does `unset -f nvm node npm npx _nvm_lazy_load`, then sources `~/.nvm/nvm.sh`
3. The wrapper recurses with `npx "$@"` — by now resolves to mise's `npx` (PATH-prepended via `mise activate zsh` in `tools/05_mise.zsh:14`)

The recursive resolution to mise's binary is *correct* — but somewhere in step 2 (or in nvm.sh's own initialization), a sibling wrapper (`npm()` / `node()`) gets re-invoked AFTER `_nvm_lazy_load` has already been unset. That re-invocation hits a stale wrapper definition that still references the now-undefined `_nvm_lazy_load`, producing the "command not found" line. The error is silent in interactive shells because the lazy-load happens once at startup and the noise blends with normal init; in non-interactive shells it's the only stderr the agent sees.

The chezmoi migration moved tool init from `~/.config/zsh/tools/<n>.zsh` (per-tool, lots of files) to `~/.config/zsh/<n>_tools.zsh` (consolidated, parent dir). The new file `02_legacy_tools.zsh` superseded the orphan `02_legacy.zsh`, but **chezmoi never overwrote it** — the paths differ in both filename and directory. The orphan kept loading from the un-managed location.

## Workaround

```bash
rm ~/.config/zsh/tools/02_legacy.zsh
```

If you customized the orphan with your own lazy-loader (a working one, gated on `[[ -o interactive ]]`), move that customisation into `~/.zshrc.adhoc` (machine-local, not chezmoi-managed) before deleting.

### Why no `.chezmoiremove` enforcement

The pre-chezmoi era meant different machines bootstrapped from slightly different starting points. Some hosts in the fleet may have hand-customised `02_legacy.zsh` content (custom paths, extra exports, working lazy-loaders). A blanket `.chezmoiremove` entry would silently nuke those on the next `chezmoi apply`. The grep-friendly title above is the durable mechanism: when the symptom resurfaces, this doc's first paragraph hits the search and the fix is one `rm`.

If a future host shows up with the orphan and zero customisation, an audit-and-prune script (planned in [`TODO.md`](../TODO.md) → "Audit `~/.config/zsh/tools/` for other pre-chezmoi orphans") is the right tool — content-aware, not path-blind.

## Prevention

- When migrating a tool init from `tools/<n>.zsh` to top-level `<n>_tools.zsh` (or any rename that doesn't co-locate old + new), document the OLD path in a pitfall doc like this one. The grep-on-symptom pattern handles the long tail without needing per-host enforcement.
- Don't use `.chezmoiremove` to clean up orphans whose content you can't characterise across all hosts. Prefer content-guarded `run_once_*.sh.tmpl` scripts (check signature, then remove) — but for one-off orphans, the noise of writing such a script outweighs the benefit; ad-hoc `rm` plus a pitfall is enough.
- Keep `dot_config/zsh/02_legacy_tools.zsh`'s `LOAD_NVM=1` gate intact. Removing the gate (i.e. always sourcing `nvm.sh`) would re-introduce zsh startup latency on every shell, defeating the mise-canonical design.

## Related

- [`dot_config/zsh/02_legacy_tools.zsh`](../dot_config/zsh/02_legacy_tools.zsh) — the chezmoi-managed file that supersedes the orphan; gates nvm sourcing behind `LOAD_NVM=1`.
- [`dot_config/zsh/tools/05_mise.zsh`](../dot_config/zsh/tools/05_mise.zsh) — mise activation, runs unconditionally; provides the canonical `node`/`npm`/`npx` shims.
- [`dot_config/mise/config.toml.tmpl`](../dot_config/mise/config.toml.tmpl) — mise's tool list (`node = "lts"`).
- [`TODO.md`](../TODO.md) — `[?/S] Audit ~/.config/zsh/tools/ for other pre-chezmoi orphans` follow-up.
