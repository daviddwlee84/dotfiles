# `hhere -p ../sibling` ignores the path and opens the workspace at `~`

## Symptoms

From a repo, point `hhere` at a sibling directory with a **relative** path:

```console
Pueue-Raycast-Extension on  main
❯ hhere -p ../Agent-Deck-Raycast-Extension
```

The command **succeeds** — exit 0, nothing on stderr, no herdr error JSON — and a
workspace is created. But the new space's shell is sitting in `$HOME`, not in
`../Agent-Deck-Raycast-Extension`. Confirm with:

```console
$ herdr pane list --workspace w1E | jq -r '.result.panes[].cwd'
/Users/david
```

Two details that make this hard to spot:

- **Absolute paths work fine.** `hhere -p ~/Documents/Program/Foo` (the shell
  expands `~` before `hhere` ever sees it) lands correctly, so the flag looks
  like it works — only the relative form is broken.
- **The workspace label is still right.** The label comes from `basename` in the
  shell function, so the space is *named* `Agent-Deck-Raycast-Extension` while
  its pane is in `~`. herdr only auto-relabels to the live cwd basename after a
  `cd` in tab 1, so nothing renames the space to `~` to give the game away.

The same applied to `hcode -p ../foo` / `hvibe -p ../foo`, but there the miss
surfaced as the misleading error `not inside a git repo` instead.

## Root cause

**`herdr workspace create --cwd` is resolved by the herdr *server*, not by the
calling shell.** The server's own working directory is whatever directory
`herdr server` happened to be launched from — for a server started from this
repo, `/Users/david/.local/share/chezmoi`:

```console
$ lsof -a -p "$(pgrep -f 'herdr server')" -d cwd | tail -1
herdr  1576 david  cwd  DIR  1,5  2528  24013827  /Users/david/.local/share/chezmoi
```

So the relative path is joined to *that*, not to your `$PWD`. Proof — from
`/tmp/hh-test/alpha`, both of these ignore `$PWD` completely:

```console
$ cd /tmp/hh-test/alpha
$ herdr workspace create --cwd ./docs --label T --no-focus | jq -r '.result.root_pane.cwd'
/Users/david/.local/share/chezmoi/docs      # ← server cwd + ./docs

$ herdr workspace create --cwd ../bravo --label T2 --no-focus | jq -r '.result.root_pane.cwd'
/Users/david                                # ← miss → SILENT fallback to $HOME
```

The second line is the whole bug: when the server-side join misses, herdr does
**not** error — it falls back to `$HOME` and returns `{"result":{"type":"ok"}}`.

**tmux does not behave this way**, which is why the sesh originals
(`shere` / `scode` / `svibe`) never needed a guard and the herdr ports looked
like faithful analogs. tmux resolves `new-session -c` **client-side**:

```console
$ cd /tmp/tmux-rel/alpha
$ tmux new-session -d -s T -c ../bravo
$ tmux display-message -p -t T '#{pane_current_path}'
/private/tmp/tmux-rel/bravo                 # ← correct, despite the tmux server
                                            #   also living in .../chezmoi
```

## Fix

Absolutize `-p/--path` **in the calling shell**, before it reaches herdr —
`dot_config/shell/24_herdr.sh` → `_herdr_abs_dir`, used by `hhere`, `hcode`,
and `hvibe`:

```bash
function _herdr_abs_dir() {
    local abs
    abs=$(CDPATH=''; cd -- "$1" >/dev/null 2>&1 && pwd -P)
    if [ -z "$abs" ]; then
        echo "${2:-herdr}: --path is not a directory: $1" >&2
        return 1
    fi
    printf '%s\n' "$abs"
}
```

- `CDPATH=''` — without it, a `CDPATH` hit can retarget the `cd` to a *different*
  directory of the same name **and** echo the resolved path into the capture,
  giving a two-line `$target`. (Same idiom already used in
  `dot_config/herdr/executable_path-pick.sh`.) Path arguments should not honour
  `CDPATH`; `-p bravo` now means `./bravo`, always.
- `--` — a target beginning with `-` is a path, not a `cd` flag.
- `>/dev/null` — belt-and-braces against the same echo.
- `pwd -P` — canonicalize symlinks, matching what `git rev-parse --show-toplevel`
  returns for the `hcode`/`hvibe` paths.
- **Returning 1 on a non-directory is the point.** Previously a typo'd `-p` was
  indistinguishable from success; now `hhere -p ../typo` says
  `hhere: --path is not a directory: ../typo` instead of silently opening `~`,
  and `hcode -p ../typo` no longer misreports it as `not inside a git repo`.

`hroot` needs nothing — it derives its path from `git rev-parse --show-toplevel`
(absolute) and passes it through `hhere`.

## Generalisable rule

**Any path handed to a daemon over a socket must be absolutized by the client.**
The server has its own cwd and no idea where you are. This applies to every
`--cwd` in `24_herdr.sh` and to future herdr CLI surfaces
(`tab create --cwd`, `pane split --cwd`) — those are currently safe only because
they are fed `$repo_root` from `git rev-parse`, which is already absolute. If a
new call site ever gets a user-supplied path, route it through `_herdr_abs_dir`.

The `--cwd` consumers that are *not* affected, and why:

| Call site | Path source | Safe because |
|---|---|---|
| `24_herdr.sh` `hvibe`/`hcode` `workspace create` / `pane split` / `_herdr_tool_tab` | `_sesh_git_root` | `git rev-parse --show-toplevel` is absolute |
| `dot_config/herdr/executable_new-tab-at-space-root.sh` | `herdr pane get` → `foreground_cwd` | herdr reports absolute paths |
| `dot_config/television/cable/herdr-sesh.toml` → `actions.open` | zoxide | `zoxide query -l` emits absolute paths |

## Related

- [`docs/tools/herdr.md`](../docs/tools/herdr.md) § cwd & workspace-naming model
- `dot_config/shell/22_sesh.sh` — the tmux originals, unaffected (client-side `-c`)
