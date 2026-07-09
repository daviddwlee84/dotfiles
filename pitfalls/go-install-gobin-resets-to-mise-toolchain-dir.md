# `go install` targets the mise toolchain dir, not ~/.local/bin — GOBIN keeps resetting

**Symptoms** (grep this section):
- `go env GOBIN` returns `/Users/<you>/.local/share/mise/installs/go/<ver>/bin` (or Linux `~/.local/share/mise/installs/go/<ver>/bin`) instead of `~/.local/bin`
- CLIs installed with `go install …@latest` silently **disappear after a `go` version bump** (mise upgrades Go → old `installs/go/<oldver>/bin` is removed → the binaries went with it)
- `export GOBIN="$HOME/.local/bin"` in your shell rc **does not stick**: correct right after the export, but reverts to the mise dir after the next `cd`
- `mise env -s zsh` prints `export GOBIN=/…/mise/installs/go/<ver>/bin` and `export GOROOT=…`
- `mise settings ls --all | grep -i go` lists `go_set_gopath` and `go_set_goroot` but there is **no `go_set_gobin`**

**First seen**: 2026-07
**Affects**: mise (all versions incl. 2026.2.5) managing Go on macOS + Linux; any host where `go` is a mise tool
**Status**: fixed in-repo (override `GOBIN` in mise's own `[env]`)

## Symptom

On a mise-managed Go, `go install` writes into the version-pinned toolchain dir:

```
$ go env GOBIN
/Users/david/.local/share/mise/installs/go/1.26.4/bin
```

Setting it from the shell looks like it works, then silently loses on the next prompt:

```
$ export GOBIN="$HOME/.local/bin"; echo $GOBIN
/Users/david/.local/bin
$ cd /tmp && cd -
$ echo $GOBIN
/Users/david/.local/share/mise/installs/go/1.26.4/bin   # reverted
```

The practical damage: every `go install`'d CLI lives under `installs/go/<ver>/bin`,
so `mise upgrade go` (or `go = "latest"` picking up a new release) wipes them all.

## Root cause

mise's Go backend **force-exports `GOBIN` (and `GOROOT`)** pointing at the active
toolchain's `bin`, and mise's shell activation re-asserts its env via `hook-env` on
**every directory change** — so it clobbers any plain shell `export` that ran earlier
in the rc. Unlike `GOPATH` (which mise leaves alone when `go_set_gopath=false`, its
default), there is **no `go_set_gobin` setting** to turn the GOBIN injection off.

`go env -w GOBIN=…` doesn't help either: a process env var (which mise sets) beats the
`go env` config file in Go's precedence order (env > GOENV file > built-in default).

## Workaround

Override `GOBIN` in **mise's own `[env]` table** — it is applied by the same
`hook-env` pass and takes precedence over the backend's default GOBIN, so it survives
`cd`. In `dot_config/mise/config.toml.tmpl`:

```toml
[env]
GOBIN = "{{ .chezmoi.homeDir }}/.local/bin"
```

Verify (fresh interactive shell, then a `cd` round-trip):

```
$ go env GOBIN            # -> ~/.local/bin
$ cd /tmp && cd -; go env GOBIN   # still ~/.local/bin
```

`GOPATH` does **not** need this treatment — mise ships `go_set_gopath=false`, so a
shell `export GOPATH=…` (dot_config/shell/02_legacy_tools.sh) is stable across `cd`.

## Prevention

When mise manages a tool that force-sets env vars with no `*_set_*` toggle, the shell
rc is the wrong layer — put the override in mise `[env]` so it wins the `hook-env`
race. For Go specifically, `dot_config/shell/02_legacy_tools.sh` still exports
`GOBIN`/`GOPATH` as the **non-mise fallback** (hosts without mise-managed Go), but the
mise `[env]` block is the authority whenever mise is active.

## Related

- `dot_config/mise/config.toml.tmpl` — the `[env] GOBIN` override
- `dot_config/shell/02_legacy_tools.sh` — shell fallback (GOPATH + GOBIN with `:-` guards)
- `docs/this_repo/config-conventions.md` § E1 — PATH dir table (`~/.local/share/go` GOPATH row)
- Upstream: mise Go backend sets GOROOT/GOBIN; only `go_set_gopath` / `go_set_goroot` are exposed
