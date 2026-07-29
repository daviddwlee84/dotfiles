# zsh: `local path` silently empties `$PATH` — every command in the function becomes "command not found"

**Symptoms** (grep this section): `command not found: tr` / `command not found: sed` / `command not found: wc` for coreutils that are demonstrably on `$PATH`; `launchctl`, `awk`, `docker` not found inside one function while `command -v` finds them everywhere else; a `command -v <tool>` guard suddenly returning false so a downstream branch takes the wrong path with **no error at all**; the same function working perfectly under bash and failing only under zsh
**First seen**: 2026-07
**Affects**: any zsh function in this repo (`dot_config/shell/*.sh` is sourced by zsh *and* bash; `dot_config/zsh/**` is zsh-only). macOS hits it hardest — zsh is the default login shell there
**Status**: fixed in `51_docker_net.sh` and `29_log_tools.sh`; guarded by `tests/unit/docker_net.bats`

## Symptom

```
$ docker-net on
_dnet_mirrors:10: command not found: tr
_dnet_mirrors:11: command not found: sed

docker-net on   http://127.0.0.1:7897

  · no-proxy                   localhost,127.0.0.1,::1,*.local,...
_dnet_running_containers:3: command not found: wc
_dnet_running_containers:3: command not found: tr
docker-net: no daemon.json for a none install
```

Yet every one of those is on `$PATH`, and calling the same helpers by hand in the same shell works:

```
TRACE info_load: OK  SRV=[28.5.1] OS=[Docker Desktop]
TRACE shape=[desktop]
TRACE PATH=[/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin]
TRACE tr=[/usr/bin/tr]
```

The **second** half is the dangerous half. `command not found` is at least loud. In the trace above `_dnet_shape` reported `desktop` when called directly but `none` from inside the function — because its first line is `_dnet_have docker || { printf 'none'; return 1; }`, and with an empty `PATH` that guard is simply false. A guard clause keyed on the shape then stopped firing, and the function sailed past a check that was supposed to stop it. Nothing printed a warning.

Minimal reproduction:

```console
$ zsh -f -c 'f() { local path; echo "PATH=[$PATH]"; command -v tr || echo "tr: NOT FOUND"; }; f'
PATH=[]
tr: NOT FOUND

$ bash --norc -c 'f() { local path; command -v tr >/dev/null && echo "tr: found"; }; f'
tr: found
```

## Root cause

zsh keeps several **tied** variable pairs: an array and a scalar that are two views of the same value. `path` ⇄ `PATH` is one of them, along with `fpath` ⇄ `FPATH`, `cdpath` ⇄ `CDPATH`, `manpath` ⇄ `MANPATH`.

`local path` declares a new, **empty** local `path` — and because the tie is by name, `PATH` becomes empty for the remainder of the function. It is restored on return, which is exactly what makes it hard to see: `echo $PATH` before and after the call both look fine.

bash has no such tie. `path` there is an ordinary variable, so **every bash-only test passes**. In this repo that is a real trap: `dot_config/shell/*.sh` is sourced by both shells, but a Bats suite that only ever runs `bash --norc -c` will never exercise the zsh semantics.

Other reserved-ish names with action at a distance: `status` (zsh's `$?`), `argv` (`$@`), `options`, `signals`, `psvar`, `mailpath`.

## Workaround

Rename the variable. There is nothing to configure.

```sh
# BAD  — blanks PATH for the rest of the function under zsh
local path
path="$(some_lookup)"

# GOOD
local target
target="$(some_lookup)"
```

Audit the whole tree for the same trap — note this parses the **declared names**, so `local action="${1:-status}"` (which merely mentions `status` in a default value) is not a false positive:

```bash
for f in dot_config/shell/*.sh dot_config/zsh/**/*.zsh; do
  [ -f "$f" ] || continue
  hits=$(grep -hoE '^[[:space:]]*local[[:space:]]+[^;#]*' "$f" \
         | sed -E 's/^[[:space:]]*local[[:space:]]+//' \
         | tr ' ' '\n' | sed -E 's/=.*//' \
         | grep -xE 'path|fpath|cdpath|manpath|status|argv|options|signals|psvar|mailpath' \
         | sort -u | tr '\n' ' ')
  [ -n "$hits" ] && echo "$f -> $hits"
done
```

That sweep found two sites: `_dnet_on` / `_dnet_off` / `_dnet_edit_daemon_json` in `dot_config/shell/51_docker_net.sh`, and `svclog`'s launchd branch in `dot_config/shell/29_log_tools.sh` — the latter macOS-only, so it was broken 100% of the time on the platform where zsh is the default shell, and had been for as long as it existed.

## Prevention

- **Never** `local path` (or `fpath` / `cdpath` / `manpath` / `status` / `argv`). Use `target`, `logpath`, `cfg`, `dest`.
- **Test shell functions under zsh, not only bash.** `tests/unit/docker_net.bats` runs the affected code paths through `zsh -f -c` for exactly this reason, plus a static check that no zsh-special name is declared `local` anywhere in the file.
- Symptom-to-cause shortcut: *"`command not found` for a coreutil that is obviously installed, inside one function only"* ⇒ look for a `local` on a tied name, not at `$PATH` itself.
- The silent half is worse than the loud half. Any `command -v` guard downstream of the declaration flips to false, so **branches change without an error message**. If a function starts taking an impossible path under zsh, check its `local` list first.

## Related

- [docs/tools/docker-net.md](../docs/tools/docker-net.md) — the tool where this surfaced
- [`chezmoiignore-negation-noop-under-recursive-glob`](chezmoiignore-negation-noop-under-recursive-glob.md) — same shape of bug: a declaration whose effect lands far from where it is written
- zsh manual, *Parameters Used By The Shell* — the tied array/scalar pairs
- `AGENTS.md` → "Three-tier file placement": why `dot_config/shell/*.sh` must survive both shells
