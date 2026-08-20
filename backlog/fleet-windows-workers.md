# `fleet`: Windows / WSL worker support

**Status**: P? — design captured 2026-08-20, nothing implemented. Blocked on a
reachability spike (can the head actually open an inbound TCP/22 to the target
devbox?), not on effort.
**Effort**: L for the whole arc; the useful first slice is M (~150 LOC in
`scripts/fleet/exec.py` + 4 `Host` fields + one bats test).
**Related**: `scripts/fleet/exec.py` (`_PATH_PRELUDE`, `_build_remote_cmd`),
`scripts/fleet/apply.py` (`Host`, `load_hosts`, `connect_host`),
`scripts/fleet/pueue.py` (`_REMOTE_CMD`), `dot_config/fleet/create_private_machines.toml.tmpl`,
`docs/infra/compute-scheduling.md`, `scripts/azure/dev_vm.py`,
`dotfiles-windows/scripts/enable-sshd.ps1`, `dotfiles-windows/scripts/enable-wsl-ubuntu.ps1`,
cross-repo note `dotfiles-all/docs/multi-machine-compute-plane.md` (superproject),
Windows-side twin `dotfiles-windows/backlog/fleet-worker-role.md`

## Context

2026-08-20. The user has several Windows devboxes (a mix of Microsoft Dev Box
and company-internal Windows machines) and wants:

> 1. 有一個電腦做為任務發起的地方 所有agent session都在這裡運行 登入環境也可以只配一台（因為Laptop不一定永遠開機連網）
> 2. 需要進行計算時可以提交到算力機器上（可能是當前或其他devbox之一） 但可能也需要顧慮如果說data可能在或不在該機器上

They brought a ChatGPT answer proposing a from-scratch build: `workers.yaml`,
`datasets.yaml`, a `run-on` wrapper, a `submit` scheduler with data-affinity
scoring, then Prefect / Dask / Ray as it grows.

**Most of that already exists here.** The gap is narrower than the proposal
assumes:

| Proposed layer | What this repo already has |
|---|---|
| `workers.yaml` inventory | `~/.config/fleet/machines.toml` + `load_hosts()` |
| `run-on worker -- cmd` | `fleet exec` (`scripts/fleet/exec.py`, asyncssh + semaphore-8 + `--ai`) |
| job queue / status / retry | pueue + `pqsum` + `fleet pueue` (cross-host read-only rollup) |
| host picker / inventory introspection | `fleet hosts` (+ `tv fleet-hosts` cable), `fleet info`, `fleet tmux` |
| network layer | Tailscale + `tsnet` |
| worker lifecycle | `wake` (WoL), `scripts/azure/dev_vm.py` (provision + register into machines.toml) |
| persistent agent shell | tmux + resurrect/continuum + `sesh` / `tmuxinator` |

What is actually missing, in priority order:

1. **Windows workers do not work at all.** `_build_remote_cmd()` emits a POSIX
   string — `export PATH="<_PATH_PRELUDE>"; exec <shlex-quoted argv>` — and the
   Windows repo's own `scripts/enable-sshd.ps1:64` sets the sshd
   `DefaultShell` to `pwsh`. `export` is not a pwsh command and `$HOME/...`
   does not interpolate the same way, so `fleet exec` against a devbox
   provisioned by our own Windows dotfiles fails today.
2. **No scheduler.** `fleet exec --hosts a,b` is explicit fan-out; nothing
   picks a host from resource or data requirements.
3. **No cross-repo record.** The superproject had no note on this surface and
   `docs/parity-matrix.md` had no fleet row. Both fixed in the same change as
   this doc.

## Investigation

The user's specific question was whether the worker must run under WSL, or
whether native Windows (PowerShell) is viable: *"WSL 可能容易一些 有沒有可能
Windows 原生跑（e.g. Powershell） 可以先調研一下如何實現"*.

**Answer: native is viable and is the more robust of the two.** That is the
opposite of the intuition, so the evidence matters.

### The WSL hop is the most fragile link in the chain

Calling `wsl.exe` from inside an SSH session on Windows is a long-standing
sore spot:

- microsoft/WSL#8072 — `Access is denied` when opening `wsl.exe` from an SSH session.
- microsoft/WSL#9373 — WSL does not start when connected to the Windows machine over SSH.
- microsoft/WSL#8889 — Windows executables run from an SSH session produce no output.

And the direct one, ansible-collections/community.general#11307: the WSL
connection plugin **fails when the Windows OpenSSH default shell is PowerShell
and not cmd**. The failure is a quoting failure, not a WSL failure — pwsh eats
the backticks in the POSIX command before bash ever sees it:

```
/bin/bash: -c: line 1: syntax error near unexpected token `)'
```

The reporter's resolution: *"When I set the default OpenSSH shell back to cmd,
everything works as expected."*

This repo's stack sits exactly on that combination, because
`dotfiles-windows/scripts/enable-sshd.ps1` deliberately sets
`DefaultShell -> pwsh` so interactive `ssh devbox` lands in PowerShell 7.

### `pwsh -EncodedCommand` removes the whole quoting class

Send the payload as base64 of UTF-16LE:

```
ssh devbox-b 'pwsh -NoProfile -EncodedCommand <BASE64>'
```

The wire string is pure ASCII — no quotes, no backticks, no `$`, no `%` — so it
survives byte-for-byte whether the remote `DefaultShell` is cmd.exe or pwsh.
Two consequences worth stating plainly:

- It neutralises the entire #11307 bug class rather than working around it.
- **`fleet` never has to know which `DefaultShell` the box has**, which means we
  do not have to change `enable-sshd.ps1`, and a devbox someone else set up
  works the same as ours.

The WSL target rides the same wrapper: the encoded pwsh payload internally calls
`wsl.exe -d <distro> -u <user> -- bash -lc '<script>'`. The quoting is resolved
by pwsh *inside* the payload, never across the sshd boundary. Prior art for the
"feed bash over stdin instead of fighting quotes" idiom, plus the encoding
fixes, is already in `dotfiles-windows/scripts/enable-wsl-ubuntu.ps1`:

```powershell
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)   # BOM-free stdin to bash
$env:WSL_UTF8 = '1'                                         # wsl.exe emits UTF-8, not UTF-16
```

### Native Windows has a *smaller* PATH problem than POSIX

`_PATH_PRELUDE` exists because a POSIX non-login SSH shell gets a minimal PATH
(macOS: `/usr/bin:/bin:/usr/sbin:/sbin`), so `command -v pueue` false-negatives
on every host with a non-system install. Windows sshd exec sessions inherit the
user's registry environment, which already contains the scoop shims
(`~\scoop\shims`), cargo, and uv tool dirs. The native path needs only a thin
insurance prelude, not the full ladder.

### Do not put a queue on native Windows

pueue's README now claims Windows is *"fully supported and working fine for
quite a while"*, but two caveats decide this:

- On Windows, pueue executes tasks **through PowerShell** — different semantics
  from the POSIX side for the same queued string.
- Nukesor/pueue#344: `pueued` does not handle Windows service events, so a
  service registration times out. It has to be started from a logon-triggered
  Scheduled Task instead.

So: keep queues where pueue is solid (POSIX hosts, and WSL if a WSL worker
exists). Native Windows gets synchronous `fleet exec` only. Revisit if real
demand appears.

### The actual risk is reachability, not shells

The ChatGPT proposal assumes the head can always open an inbound SSH connection
to a worker. For a corporate Dev Box both usual routes may be closed at once:

- `dotfiles-windows`'s `managedMachine` prompt is literally defined as *"Managed
  or corporate machine (skip org-policy-blocked apps like **Tailscale** and
  Grammarly)"* — so on a managed box there is no overlay network.
- A Dev Box has no public IP and its supported connection paths are the Dev Box
  service (RDP / browser / VS Code headless). Peer-to-peer inbound TCP/22 is not
  a guaranteed property.

That combination has **no inbound transport at all**, and no amount of shell
engineering fixes it. The design therefore needs a documented outbound-dialing
tier where the worker connects to the head. Recorded, not built — see Options.

Lifecycle, on the other hand, is straightforward when it is wanted:
`az devcenter dev dev-box start|stop|list` via the `devcenter` CLI extension
(Azure CLI >= 2.75). Same shape as the existing `scripts/azure/dev_vm.py`.

## Options considered

### Transport tier (pick per host, not globally)

| Tier | How | Pros | Cons |
|---|---|---|---|
| A. Inbound SSH → native pwsh | `pwsh -NoProfile -EncodedCommand` over the existing asyncssh plumbing | no new daemon; DefaultShell-agnostic; reuses every `fleet` primitive | needs inbound 22; no queue |
| B. Inbound SSH → WSL hop | same wrapper, payload calls `wsl.exe … bash -lc` | full POSIX env, unix dotfiles already bootstrapped there, pueue works | inherits WSL#8072/#9373/#8889; WSL must be running or cold-start on first job |
| C. Outbound dialing | worker connects out: `ssh -R` / autossh reverse tunnel, GitHub self-hosted runner, or a poll-based work pool (Prefect) | only route that works on a locked-down corp Dev Box | new moving part; state lives somewhere new; not a `fleet` primitive today |

**Chosen for v1: A, with B available per host.** C is documented as the escape
hatch and deferred until a real box proves unreachable.

### Execution matrix

| host `platform` / `exec_via` | remote command sent |
|---|---|
| `posix` (default — today's behaviour, unchanged) | `export PATH="<_PATH_PRELUDE>"; exec <shlex-quoted argv>` |
| `windows` + `native` | `pwsh -NoProfile -EncodedCommand <base64 UTF-16LE>` |
| `windows` + `wsl` | same wrapper; payload calls `wsl.exe -d <distro> -u <user> -- bash -lc '<script>'` |

### `machines.toml` schema addition

```toml
[[hosts]]
name       = "devbox-b"
ssh_alias  = "devbox-b"
platform   = "windows"        # posix (default) | windows
exec_via   = "native"         # native (default when platform=windows) | wsl
wsl_distro = "Ubuntu-24.04"
wsl_user   = "david"
```

**Trap**: `load_hosts()` silently drops unknown TOML keys
(`{k: v for k, v in merged.items() if k in host_fields}`). Any new field must
land on the `Host` dataclass in the same commit or setting it is a no-op with no
error. The `tsnet sync-fleet` TODO entry records the same trap for
`tailscale_*` fields.

### Where the head lives — deliberately not pinned

`fleet` runs anywhere `uv run` + asyncssh work. On a Windows devbox that is its
own WSL, which `installWslUbuntu` + `wslUbuntuBootstrap` already provision with
this exact dotfiles repo — so "Windows devbox as head" is true today with no new
mechanism. A `role = "head"` marker is only worth adding once a scheduler needs
to reason about it.

## Current blocker / open questions

- **Reachability spike (the real blocker).** For each target devbox: does
  `ssh <box> 'pwsh -NoProfile -Command "$PSVersionTable.PSVersion"'` succeed from
  the intended head? Answer per box before writing code — tier A and tier C are
  different programs.
- Which box is the head, long term? Currently undecided by the user; the design
  intentionally does not depend on the answer.
- Is `installSshServer` acceptable on the corporate boxes at all (it opens
  inbound 22 and needs admin)?
- Does `wsl.exe` actually work over SSH on *these* boxes, or do they reproduce
  WSL#8072? Only worth testing if a WSL worker is wanted.

## Decision

**2026-08-20 — design captured, implementation deferred pending the reachability
spike.** Sequencing when it unblocks:

1. **First slice (M)** — `fleet exec` learns `platform` / `exec_via`: 4 fields on
   the `Host` dataclass, a branch in `_build_remote_cmd()`, the base64 wrapper
   helper, a `machines.toml` template comment block, and a bats test with an ssh
   stub asserting the emitted wire string. No new subcommand, so the completion
   pair (`dot_config/zsh/tools/45_fleet_completion.zsh` +
   `dot_config/bash/45_fleet_completion.bash`) is untouched.
   ⚠ `CLAUDE.md`'s coupling rule applies: `pueue.py:_REMOTE_CMD` and
   `exec.py:_PATH_PRELUDE` are two copies of the same PATH-augmentation logic and
   move together.
2. Then, only if wanted: `fleet info` / `fleet tmux` platform awareness.
3. Explicitly **not** now: the resource/data-affinity scheduler (`labels`,
   `datasets.toml`, a scoring table), cross-host queue writes (already blocked on
   the existing P2 "Pueue TLS remote-connect profiles" — reference it, do not open
   a parallel track), Dev Box lifecycle, and Prefect / Dask / Ray.
   `docs/infra/compute-scheduling.md` already surveys the last of those.

## References

- ansible-collections/community.general#11307 — WSL connection plugin fails when Windows OpenSSH DefaultShell is PowerShell, not cmd.
- microsoft/WSL#8072 (`Access is denied` from an SSH session), #9373 (WSL will not start over SSH), #8889 (no output from Windows executables over SSH).
- PowerShell/Win32-OpenSSH wiki — `DefaultShell`, `DefaultShellCommandOption`, `DefaultShellEscapeArguments` (the escape-arguments flag explicitly does **not** apply to powershell/bash/cygwin/cmd).
- Nukesor/pueue#344 — `pueued` does not handle Windows service events.
- Microsoft Learn — `az devcenter dev dev-box start|stop`, Dev Box autostop / hibernate schedules.
- Cross-repo architecture note: `dotfiles-all/docs/multi-machine-compute-plane.md` (superproject).
