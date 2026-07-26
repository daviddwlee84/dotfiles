# herdr CLI dies with `protocol_mismatch` after `brew upgrade herdr` — and Homebrew installs cannot live-handoff

## Symptoms

Right after `brew upgrade herdr` on macOS, **every** `herdr` CLI call fails while the
UI you are sitting in keeps working perfectly:

```console
$ herdr workspace list
{"id":"cli:workspace:list","error":{"code":"protocol_mismatch",
 "message":"client protocol 17 is newer than server protocol 16; restart the Herdr server
 before using this command. Stop the old server to use the new version.\nStopping exits pane
 processes.\nRun `HERDR_SOCKET_PATH=/Users/you/.config/herdr/herdr.sock herdr server stop`,
 then restart Herdr with the same socket override."}}
```

Note the exit code is **0** — the error is in the JSON body, not the process status, so
naive `cmd || fallback` wrappers do not notice.

```console
$ herdr status
client:
  version: 0.7.5
  protocol: 17
server:
  status: running
  version: 0.7.2
  protocol: 16
  compatible: no
update:
  restart_needed: yes
```

Downstream, in this repo, that means the following silently stop working (usually as an
**empty picker** rather than an error, because the tv channels pipe through `jq` and
swallow stderr with `2>/dev/null`):

- `prefix + T` → `tv herdr-sesh`, `prefix + a` → `tv herdr-agent-panes`, `prefix + i` → `tv herdr-review`
- `hvibe` / `hcode` / `hhere` / `hroot` (`dot_config/shell/24_herdr.sh`)
- every `[[keys.command]]` helper that calls the CLI: `review-mark.sh`, `pane-copy.sh`,
  `path-pick.sh`, `url-pick.sh`, `new-tab-at-space-root.sh`

The herdr TUI itself is unaffected — the running server and its attached client are both
still the old binary, talking the old protocol to each other.

## Root cause

herdr's client↔server socket API is versioned by an integer `protocol`. A brew upgrade
swaps `/usr/local/bin/herdr` (→ `../Cellar/herdr/<new>/bin/herdr`) but **cannot restart the
running server** — so the new CLI (protocol 17) refuses to talk to the old server
(protocol 16). herdr fails closed here on purpose rather than risk a mismatched wire format.

The trap is the recovery path, not the diagnosis:

> **`herdr update --handoff` — the live, pane-preserving upgrade — is disabled on Homebrew,
> mise, and Nix installs.** Upstream: *"`herdr update --handoff` only applies to installs
> managed by Herdr's own updater. Homebrew, mise, and Nix installs are updated through their
> package managers, so `herdr update` is disabled there and cannot perform live handoff."*
> ([session-state docs](https://github.com/ogulcancelik/herdr/blob/master/docs/next/website/src/content/docs/session-state.mdx))

So on **macOS (this repo installs herdr via homebrew-core)** there is **no** way to pick up a
new herdr version without stopping the server, and stopping the server **kills every pane
process** — shells, dev servers, tests, and every running coding agent.

Linux hosts are the opposite case: this repo installs the self-managed GitHub-release binary
into `~/.local/bin/herdr`, so `herdr update --handoff` *is* available there.

## Fix / workaround

There is no way to un-stage the upgrade short of `brew install herdr@<old>` (no such
formula exists). Pick one:

**A. Stay on the old server until a natural restart point.** The mismatch is CLI-only. Keep
using the TUI (`prefix+g` navigator, splits, tabs all still work — they are server-internal),
just avoid the CLI-backed helpers above. Restart at the end of the day.

**B. Restart deliberately, leaning on herdr's own restore.** Before stopping, know what
survives:

| Layer | Survives `herdr server stop`? |
|---|---|
| Workspace / tab / pane **topology** + labels | Yes — snapshot in `~/.config/herdr/session.json` |
| Pane **screen history** | Yes, if `[session]` history saving is on |
| AI-agent **conversations** | Yes, for agents with `herdr integration install <agent>` hooks + `resume_agents_on_restore = true` |
| **Running processes** (shells, servers, tests, `just`, builds) | **No — all killed** |

```bash
HERDR_SOCKET_PATH="$HOME/.config/herdr/herdr.sock" herdr server stop
herdr    # reattach; topology + agent sessions restore
```

**C. Prevent it up front** — pin herdr out of blanket brew upgrades if a long-running
session matters more than being current:

```bash
brew pin herdr        # `just upgrade-brew` / `brew upgrade` then skips it
brew unpin herdr      # when you're ready to take the restart
```

## Why this is easy to misdiagnose

- The UI keeps working flawlessly, so nothing *feels* broken — only the side-channel
  helpers stop responding, and they mostly fail as empty pickers.
- `herdr --version` reports **0.7.5** (the new client binary) even though the server you are
  actually sitting inside is still **0.7.2**. Always cross-check with `herdr status`, which
  prints client and server separately plus `compatible:` / `restart_needed:`.
- The CLI exits **0** on `protocol_mismatch`; only the JSON body carries the failure.

## See also

- [`docs/tools/herdr.md`](../docs/tools/herdr.md) — install / upgrade / config-overlay model
- Upstream session-state + live-handoff doc: <https://github.com/ogulcancelik/herdr/blob/master/docs/next/website/src/content/docs/session-state.mdx>
