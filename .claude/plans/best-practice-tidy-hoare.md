# Tidy Go env vars — banish `~/go` from HOME

## Context

`go install` and Go's module cache currently clutter `$HOME` with a `~/go` tree.
On this Mac today: `GOPATH=~/go` (so `~/go/pkg/mod` exists), and interactive
`go install` resolves `GOBIN` to the **mise version-pinned toolchain dir**
(`~/.local/share/mise/installs/go/<ver>/bin`) — which gets wiped on every Go
version bump, silently losing installed CLIs.

Meanwhile the repo's automation **already** standardizes on `GOBIN=~/.local/bin`
(the "blessed dir", already on PATH) in `go_tools` role + `upgrade_tools.sh` — but
the interactive shell was never brought in line, and neither automation path sets
`GOPATH`, so a build-time module cache still recreates `~/go`.

**Goal (best-practice, user-approved scope):** make `~/go` never appear again.
Move `GOPATH` to the XDG data dir and pin `GOBIN=~/.local/bin` consistently across
**all three** Go-install surfaces (shell, ansible, upgrade). Module cache then lives
at `~/.local/share/go/pkg/mod` (data dir — survives `~/.cache` cleaners). `GOCACHE`
(build cache) stays at Go's macOS-native `~/Library/Caches/go-build` — under
`~/Library`, not clutter, left untouched by design.

Research basis: Go does **not** honor XDG for `GOPATH`/`GOBIN`/`GOMODCACHE` by
default (golang/go#17262, closed) and ignores `XDG_*` entirely on darwin; every
one of these vars is officially settable via `export`, and `go install pkg@version`
honors `GOBIN`. `export` (not `go env -w`) is correct here so editors/LSPs also see
the values.

## Changes

### 1. `dot_config/shell/02_legacy_tools.sh` — interactive shells (primary)

Replace the Go section (lines 6–10, the `## Go` header block down to the
`$GOPATH/bin` PATH line — **leave the toolchain PATH block at lines 17–23 intact**):

```sh
# =============================================================================
# Go (Golang) — keep HOME tidy: no ~/go. GOPATH → XDG data, go install → ~/.local/bin.
# XDG_DATA_HOME is exported by the rc files before this module (defensive fallback
# kept per repo convention). ~/.local/bin is already on PATH via 00_exports.sh.tmpl,
# so GOBIN targets need no extra PATH entry. GOCACHE stays macOS-native (~/Library).
# =============================================================================
export GOPATH="${GOPATH:-${XDG_DATA_HOME:-$HOME/.local/share}/go}"
export GOBIN="${GOBIN:-$HOME/.local/bin}"
```

- Drop the old `[[ -d "$GOPATH/bin" ]] && export PATH="$GOPATH/bin:$PATH"` line: with
  `GOBIN` set, `$GOPATH/bin` is never populated, and `~/.local/bin` is already on PATH
  (`dot_config/shell/00_exports.sh.tmpl:26`). Removing it avoids a misleading dead entry.
- Keep the `${GOPATH:-…}` / `${GOBIN:-…}` guards so a user override in
  `~/.shellrc.adhoc` / secrets still wins (matches every other module here).
- File is plain `.sh` (POSIX, both shells) — no templating; the `${XDG_..:-…}`
  fallback covers macOS + Linux identically.

### 2. `dot_ansible/roles/go_tools/tasks/main.yml` — add `GOPATH` to the install task

The `Install Go CLI tools via go install` task (`:34-44`) sets `GOBIN` but **not**
`GOPATH`, so its build-time module cache lands in the default `~/go/pkg/mod`.
Add one line to the task's `environment:` (next to the existing `GOBIN:` at `:43`):

```yaml
    GOPATH: "{{ ansible_facts['env']['HOME'] }}/.local/share/go"
```

Matches the existing hardcoded-`HOME` style in that block (ansible env doesn't carry
`XDG_DATA_HOME`).

### 3. `scripts/upgrade_tools.sh` — `cat_go()` set `GOPATH` alongside `GOBIN`

At `:542`, next to `export GOBIN="$HOME/.local/bin"`, add:

```sh
  export GOPATH="$HOME/.local/share/go"
```

Same reason: the upgrade re-install must not repopulate `~/go/pkg/mod`.

### 4. Docs — `docs/this_repo/config-conventions.md` § E1 PATH table (+ zh-TW mirror)

The `| ~/go/bin/ | Go | go install targets |` row (`:275`) is now false.
- Fold Go into the `~/.local/bin/` row (`:273`): "Auto-installed CLIs (uv, mise,
  chezmoi, just, fd, eza, **go install**, …)".
- Replace the `~/go/bin/` row with a note (or drop it and add a one-liner under the
  table): GOPATH now lives at `~/.local/share/go`; `go install` → `~/.local/bin`;
  module cache → `~/.local/share/go/pkg/mod`.
- Mirror the same edit in `docs/this_repo/config-conventions.zh-TW.md:245-246`.

**No change needed** (verified consistent): `docs/this_repo/tool-managers.md:587-588`
and `docs/this_repo/upgrades.md:53` already describe GOBIN→`~/.local/bin`. `aliases.md`
is alias/function-scoped — a plain `export` doesn't belong there. `architecture.md`'s
tier note doesn't hardcode `~/go`, so it isn't made stale (its pre-existing GOPATH
mislabel under `00_exports` is out of scope).

## One-time manual cleanup (documented, NOT automated)

After apply + verify, the orphaned `~/go` can be removed. Module cache files are
created **read-only** by Go, so `rm -rf` alone can choke — use one of:

```sh
GOPATH="$HOME/go" go clean -modcache   # supported way to wipe the old cache
rmdir ~/go/bin ~/go/pkg ~/go 2>/dev/null || { chmod -R u+w ~/go && rm -rf ~/go; }
```

Left manual on purpose — never auto-`rm` a user data dir.

## Verification (per repo "validate with the app" invariant)

1. `chezmoi diff dot_config/shell/02_legacy_tools.sh` → review; `chezmoi apply`.
2. Open a **new** shell, then:
   ```sh
   go env GOPATH GOBIN GOMODCACHE GOCACHE
   #   GOPATH     = ~/.local/share/go
   #   GOBIN      = ~/.local/bin
   #   GOMODCACHE = ~/.local/share/go/pkg/mod   (derived from GOPATH)
   #   GOCACHE    = ~/Library/Caches/go-build    (macOS-native, unchanged)
   ```
   Confirms the mise-shim GOBIN override is gone.
3. Functional install:
   ```sh
   go install golang.org/x/tools/cmd/goimports@latest
   command -v goimports        # -> ~/.local/bin/goimports, runnable
   ls ~/go 2>/dev/null && echo "REGRESSION: ~/go recreated" || echo "ok: no ~/go"
   ls ~/.local/share/go/pkg/mod   # module cache landed in XDG data
   ```
4. Ansible surface: the `go_tools` install task has a `creates:` guard, so removing a
   managed binary (e.g. `rm ~/.local/bin/<tool>`) then re-running the role (or the
   `just` go_tools path) should reinstall it into `~/.local/bin` with **no** `~/go`.
   At minimum `ansible-playbook --syntax-check` the role and eyeball the rendered
   `environment:`.
5. Upgrade surface: `just upgrade-go` (reinstalls at `@latest`) → binaries in
   `~/.local/bin`, `~/go` not recreated.
6. Cross-platform sanity: the plain-`.sh` + `${XDG_DATA_HOME:-…}` fallback means the
   same block works on Linux (where XDG is native) — no template branch to test.

## Caveats to keep in mind

- **Cross-compiling + GOBIN set**: `go install` refuses cross-compiled binaries when
  `GOBIN` is set (`cannot install cross-compiled binaries when GOBIN is set`). Use
  `go build -o <path>` for those. Rare for day-to-day tool installs.
- **macOS ignores XDG for Go**: `GOCACHE`/`GOENV` stay under `~/Library` on this Mac
  by design (user chose not to force them to XDG) — intentional, not a gap.
