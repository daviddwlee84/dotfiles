# `Error: Lua runtime failed` — yazi won't start, blaming `duckdb.yazi/main.lua`

**Symptoms** (grep this section): `Error: Lua runtime failed`; `Caused by:` `Failed to load plugin from "…/.config/yazi/plugins/duckdb.yazi/main.lua"`; `stack traceback:` `[C]: in local 'poll'` / `[string "?"]:28: in function 'require'` / `[string "init.lua"]:21: in main chunk`; `yazi` (or the `y` alias) exits immediately with no TUI; `ls ~/.config/yazi/plugins/` says `No such file or directory`; `ya` prints `command not found` while `yazi --version` works fine; repeated `chezmoi apply` never fixes it and says nothing about yazi.
**First seen**: 2026-07 (David-Ubuntu, Ubuntu 24.04, yazi 26.1.22)
**Affects**: any host whose yazi was installed by copying only the `yazi` binary out of a release archive — including, until fixed, the repo's own user-level ansible fallback.
**Status**: fixed (ansible installs `ya` too and probes for it; run-script converted to a self-healing `run_after_`; `init.lua` guarded with `pcall`).

## Symptom

```console
$ y
Error: Lua runtime failed

Caused by:
    Failed to load plugin from "/home/daviddwlee84/.config/yazi/plugins/duckdb.yazi/main.lua"
    stack traceback:
        [C]: in local 'poll'
        [string "?"]:28: in function 'require'
        [string "init.lua"]:21: in main chunk
```

The error names `duckdb.yazi`, so the obvious move is to go debug duckdb — the
plugin, the pinned rev, the `duckdb` CLI, the `spatial` extension. **All of that
is a dead end.** duckdb is innocent; it is merely the first plugin `init.lua`
happens to `require`.

The tell is one directory up:

```console
$ ls ~/.config/yazi/plugins/
No such file or directory          # not "duckdb.yazi is broken" — NOTHING is installed

$ yazi --version
Yazi 26.1.22 (4e0acf8 2026-01-22)  # the TUI is fine
$ ya --version
zsh: command not found: ya         # <- the actual root cause
```

`piper.yazi` was equally missing, which silently killed every Office / markdown /
epub / sqlite preview too — you just never saw an error for those, because piper
is only `require`d lazily by a preview rule, not at startup.

## Root cause

Upstream ships **two** binaries in every release asset — `yazi` (the TUI) and
`ya` (its CLI companion) — and they are a matched pair. `ya` is what creates
`~/.config/yazi/plugins/` via `ya pkg install`. Install one without the other and
you get a yazi that cannot ever acquire a plugin.

Three separate defects lined up to turn that into an unlaunchable file manager,
each one silent on its own:

1. **The installer dropped `ya`.** The user-level fallback in
   `dot_ansible/roles/devtools/tasks/main.yml` extracted the release zip and then
   copied exactly one file out of it:

   ```sh
   cp /tmp/yazi-…-musl/yazi ~/.local/bin/yazi     # `ya` sits right next to it, uncopied
   ```

   On the affected host the binary was the **gnu** build in `/usr/local/bin`
   (byte-identical to `yazi-x86_64-unknown-linux-gnu/yazi` from v26.1.22,
   confirmed by sha256) — a manual install with the same one-file mistake. Same
   shape, same outcome.

2. **The install probe couldn't see the gap.** The role gated on
   `yazi --version` / `command -v yazi` only. `yazi` was present, so the task
   reported OK forever and never repaired anything.

3. **The plugin run-script skipped silently, then marked itself done.**
   `run_onchange_after_45_yazi_plugins.sh.tmpl` opened with:

   ```sh
   if ! command -v ya >/dev/null 2>&1; then
       info "ya (yazi CLI) not found; skipping yazi plugin install (…)"
       exit 0
   fi
   ```

   An `info` (not a warning), and `exit 0`. Because it was `run_onchange_`,
   chezmoi then recorded the lockfile hash as satisfied — so even after `ya`
   appeared later, the script **never re-ran**. Only editing `package.toml` would
   have retriggered it. This is the [bat theme cache](bat-theme-cache-cleared-never-rebuilt.md)
   bug again, in a different costume.

Finally, `init.lua`'s call was unguarded:

```lua
require("duckdb"):setup({ mode = "standard" })
```

A bare `require` makes a missing plugin **fatal**, so the whole file manager was
unusable rather than merely missing data previews — and the error pointed at the
wrong component.

## Workaround

Immediate, on any affected host — install `ya` **from the same yazi release** as
your `yazi` binary (a version-skewed pair is its own problem), then let it work:

```sh
yazi --version                     # -> Yazi 26.1.22 …; use that tag below
cd "$(mktemp -d)"
curl -sSL -O "https://github.com/sxyazi/yazi/releases/download/v26.1.22/yazi-x86_64-unknown-linux-gnu.zip"
python3 -m zipfile -e yazi-x86_64-unknown-linux-gnu.zip .
install -m 755 yazi-x86_64-unknown-linux-gnu/ya ~/.local/bin/ya

ya pkg install                     # materializes ~/.config/yazi/plugins/
```

Pick the `-musl` asset instead if your `yazi` is the musl build (`ldd` on it says
`not a dynamic executable`). `~/.local/bin` precedes `/usr/local/bin` in this
repo's PATH, so this works without sudo even when `yazi` itself is root-owned.

Verify — and note `ya pkg install` rewrites `~/.config/yazi/package.toml`, so
confirm it didn't introduce drift:

```sh
ls ~/.config/yazi/plugins/         # duckdb.yazi  piper.yazi
chezmoi diff ~/.config/yazi/       # must be EMPTY (the lockfile is kept comment-free for exactly this reason)
```

Debugging aid: `ya.err()` output only reaches `~/.local/state/yazi/yazi.log`
when `YAZI_LOG` is set. Nothing is logged without it.

```sh
YAZI_LOG=debug yazi; grep -i duckdb ~/.local/state/yazi/yazi.log
```

## Prevention

Four fixes, all in this repo:

1. **`dot_ansible/roles/devtools/tasks/main.yml`** copies **both** binaries out
   of the archive, and both presence probes now check
   `command -v yazi && command -v ya` so a partial install self-repairs. The
   probes carry the repo's usual
   `PATH: {{ HOME }}/.local/bin:/usr/local/bin:{{ PATH }}` environment block —
   without it ansible cannot see a `ya` in `~/.local/bin` and would pointlessly
   re-trigger the sudo/apt path on every run.

2. **`.chezmoiscripts/global/run_after_45_yazi_plugins.sh.tmpl`** (renamed from
   `run_onchange_after_45_…`) runs on every apply and decides for itself. Fast
   path is one stamp read plus one stat per plugin (~2 ms, no network); it
   reinstalls when any plugin dir is missing *or* the lockfile hash changed. It
   also refuses to write its stamp if `ya pkg install` claims success while
   plugins are still absent, so a half-failure retries next apply instead of
   latching.

3. **The missing-`ya` branch is now a loud multi-line `warn`** that names the
   consequence (all plugin previewers dead) and the fix, instead of a one-line
   `info` that scrolled past.

4. **`dot_config/yazi/init.lua` wraps the `require` in `pcall`** and reports via
   `ya.err` + `ya.notify`. Yazi now starts regardless; you lose data-file
   previews and get told why. `pcall` is yieldable in Lua 5.4, so it correctly
   catches errors thrown from `require`'s internal `poll` yield — verified
   against the real binary, not assumed.

**Generalisable rules**:

- When upstream ships a **binary pair**, install and probe for both. A probe that
  checks only the famous half of a pair is not a probe.
- Same `run_onchange_` rule as the bat theme: hash-gating is only valid when the
  script's *product* lives in chezmoi's tree. `~/.config/yazi/plugins/` does not.
- A missing optional component should degrade the feature, not the application.
  Prefer `pcall` + a visible notification over a bare `require` in `init.lua` —
  but do keep it *visible*; trading a crash for silence is not an improvement.

## Related

- [`bat-theme-cache-cleared-never-rebuilt.md`](bat-theme-cache-cleared-never-rebuilt.md)
  — same `run_onchange_`-can't-see-outside-the-tree defect
- [`docs/tools/data-viewers.md`](../docs/tools/data-viewers.md) — duckdb.yazi wiring (the three places it must be registered)
- [`docs/tools/office-viewers.md`](../docs/tools/office-viewers.md) — the `ya pkg` mechanism and piper.yazi
- [`docs/tools/yazi-previews.md`](../docs/tools/yazi-previews.md) — the non-plugin previewer deps (chafa, poppler, …)
