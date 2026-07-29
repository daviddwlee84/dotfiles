# `tsnet` — tailnet devices → ssh config, and tailnet-HTTPS `serve`

An in-house CLI (`dot_dotfiles/bin/executable_tsnet`, deployed to `~/.dotfiles/bin/tsnet`)
that wraps the two Tailscale workflows this repo actually needs. Both exist because
the underlying happy paths fail **silently**.

Picker twin: **`tv tailnet`**. Install notes for Tailscale itself: [Tailscale.md](Tailscale.md).

> **Name collision (cosmetic)**: Tailscale ships a Go library also called
> [`tsnet`](https://pkg.go.dev/tailscale.com/tsnet) for embedding a node in a Go
> program. No binary conflict, but expect the occasional confusing search result.

## Quick reference

```bash
tsnet list                        # tailnet devices (table)
tsnet list --tsv --online-only    # wire format for tv tailnet
tsnet describe david-ubuntu       # one device + whether ssh already knows it

tsnet ssh-config david-ubuntu     # write a managed ~/.ssh/config.d block
tsnet ssh-config a b c --dry-run  # preview, touch nothing

tsnet doctor                      # can this box do tailnet HTTPS? (never mutates)
tsnet serve 39100                 # preflight → tailscale serve --bg → verify
tsnet serve 39100 --off           # tear it down
tsnet status                      # decoded serve/funnel config

tsnet --host david_ubuntu doctor  # run the tailscale side on a remote box
```

Exit codes are meaningful, so `tsnet doctor --json | jq -e .ok` is a usable gate:

| Code | Meaning | Code | Meaning |
|---|---|---|---|
| 0 | ok (incl. "already correct, nothing written") | 6 | HTTPS certs disabled / node not covered |
| 1 | generic failure | 7 | operator not set (Linux) |
| 2 | tailscale binary missing | 8 | nothing listening on the target port |
| 3 | backend not Running | 9 | `:443` claimed by a different target |
| 4 | ssh-config target unreachable, fix declined | 10 | block written but shadowed (`--strict` only) |
| 5 | managed-block markers malformed | | |

---

## `tsnet ssh-config`

Writes a **managed block** into `~/.ssh/config.d/20-tailscale` (override with
`--out`, or `--inline` to append to `~/.ssh/config` itself):

```
# BEGIN tsnet ssh-config v1 — managed block; edits INSIDE are overwritten
# tailnet: daviddwlee84.github (tail7f7fc5.ts.net)
# regenerate: tsnet ssh-config david-ubuntu

Host david-ubuntu
    HostName david-ubuntu.tail7f7fc5.ts.net
    # tailscale IP: 100.77.43.16
    User david
# END tsnet ssh-config
```

Anything **outside** the markers is preserved byte-for-byte. Reruns are
byte-identical and skip the write entirely (mtime untouched) — which is why the
block deliberately carries **no timestamp**.

Malformed markers (unpaired, or more than one `BEGIN`) are a hard **exit 5** with
nothing written. A truncated previous write must never be "repaired" by guessing
which region is ours.

### The three ways this silently does nothing — and how each is caught

**1. `~/.ssh/config` has no `Include`.** Writing a `config.d/` drop-in is then a
no-op ssh never reads. This is not hypothetical: it is the state of a stock
`~/.ssh/config` that predates this repo's `dot_ssh/create_private_config`, and
`tsnet` refuses with **exit 4** plus the evidence:

```
tsnet: /Users/you/.ssh/config has no `Include` that reaches /Users/you/.ssh/config.d/20-tailscale
       -> writing there would be a SILENT no-op (ssh would never read it).
       Detected: /Users/you/.ssh/config is 308 lines, 0 Include directive(s).
       /Users/you/.ssh/config.d/ already holds 2 unloaded file(s): 00-defaults, 01_git
```

Adding the `Include` is **not** a no-op, and `tsnet` says so before doing it. ssh
takes the **first-obtained** value for every keyword, so a top-inserted `Include`
makes `config.d/*` win wherever both define the same host. The delta preview is
unconditional:

```
       Adding the Include at the TOP would change resolution for 2 host(s):
         github.com           user: david → git   (01_git:5 would now win)
         gitlab.com           user: david → git   (01_git:9 would now win)
       Use --include-position=bottom to keep the existing config winning.
```

Three ways out: `--add-include=yes` (restructure), `--include-position=bottom`
(strictly additive — drop-ins only supply keywords the monolith didn't set), or
`--inline` (append the block to `~/.ssh/config`, zero precedence change).

Without a TTY, `tsnet` **refuses** rather than choosing — a piped or cron
invocation must never silently change how existing hosts resolve. Pass `--yes`.

**2. The `Include` is scoped inside a `Host` block.** An `Include` that appears
after a `Host foo` line belongs to that block, so ssh only reads it when
connecting to `foo`. Reported as a warning naming the guard.

**3. An earlier `Host` block shadows ours.** Same first-obtained rule. `tsnet`
walks the include closure in **true parse order** and names the file and line:

```
tsnet: `david-ubuntu` is already defined at ~/.ssh/config:142, which ssh parses
       BEFORE ~/.ssh/config.d/20-tailscale. Our block is inert.
       Fix: remove that block, or rerun with --alias-prefix ts-
```

Exit 0 by default (the file *was* written correctly); `--strict` makes it exit 10.

Finally, every run ends with `ssh -G <alias>` and asserts the resolved `hostname`
matches what was written. **That single check catches all three failure modes**,
which is what makes this class of silent failure impossible to miss.

### Where `HostName` and `User` come from

`--hostname-style auto` (default) uses the **MagicDNS FQDN** if MagicDNS is
enabled *and* `getaddrinfo()` succeeds; otherwise it falls back to the first IPv4
and stamps why. A `100.x` CGNAT address is **not stable across a node's
lifetime** — reinstall, key expiry, or a `logout`/`up` cycle reassigns it, and a
stale IP then connects to *whichever node now holds it*, producing a host-key
mismatch rather than a clean failure. The unused form is always emitted as a
comment so you can swap by hand. Force with `magicdns` / `ip` / `short`.

`User` is **resolved, never guessed** — Tailscale genuinely does not know POSIX
usernames (`Self.UserID` is a tailnet *account* identity like `you@github`, so
using it would be actively wrong). First hit wins:

1. `--user`
2. an existing `Host <alias>` block in the include closure (stable across reruns)
3. `~/.config/fleet/machines.toml` — matched on `ssh_alias` / `hostname` / `name`
   / any of the node's tailscale IPs. Covers only a subset (the tailnet also has
   phones and other people's Macs), so it's a lookup, not a requirement.
4. a TTY prompt defaulting to `$USER`
5. **omitted entirely**, with `# User: unset — ssh will use $USER.` Identical
   runtime behaviour to guessing `$USER`, but nothing wrong gets baked into a
   file that outlives the guess.

`tsnet` never creates keys. `--setup-remote` (or the prompt on a TTY) hands the
terminal to [`ssh-setup-remote`](../tutorials/setup_ssh_key_on_remote.md), which
does key generation + `ssh-copy-id`.

---

## `tsnet serve` — tailnet HTTPS for services that require it

Some services hard-require an `https://` origin. The motivating case: an MCP
server whose OAuth discovery inherits OAuth 2.1's HTTPS-issuer rule and silently
falls back to `http://localhost:3000` when `APP_URL` is anything else. In the
broken state `/api/health` returns `ok`, `/mcp` returns `401`, and
`/.well-known/oauth-protected-resource` returns `200` — **all three look healthy**
while every agent client fails the handshake.

`tailscale serve` fixes it with a real Let's Encrypt cert for the tailnet name,
but has two prerequisites that cannot be automated. `tsnet` checks them first:

| Check | Source | Failure |
|---|---|---|
| `binary` | `which` → `/usr/local/bin` → the app bundle → `$TSNET_TAILSCALE_BIN` | exit 2 |
| `backend` | `.BackendState == "Running"` | exit 3 |
| `health` | `.Health` non-empty | warn |
| `certs` | `.CertDomains` null/empty | **exit 6** |
| `cert-covers-node` | `.Self.DNSName` ∈ `.CertDomains` | exit 6 |
| `operator` | Linux + non-root: `tailscale debug prefs` → `OperatorUser` | exit 7 |
| `listener` | can we connect to the target port? | exit 8 |
| `port-443-free` | `tailscale serve status --json` | exit 9 (or 0 if already ours) |
| `funnel-off` | `.AllowFunnel` | **warn — PUBLIC INTERNET** |

The two manual steps, printed as copy-pasteable remediation:

```bash
# 1. TAILNET-WIDE, needs an Owner/Admin in the web console:
#    https://login.tailscale.com/admin/dns → "HTTPS Certificates" → Enable
tailscale cert "$(tailscale status --json | jq -r .Self.DNSName | sed 's/\.$//')"

# 2. Once per Linux box, so a non-root user can drive serve:
sudo tailscale set --operator=$USER
```

Neither is ever run for you: the first has no CLI at all, and non-interactive
remote `sudo` is exactly the thing that hangs forever on a password prompt.

Three details that matter:

- **`OperatorUser` is `json:",omitempty"`** — an *absent* key is the unset state,
  not `""`. The check is skipped entirely on macOS, which has no operator concept
  (the CLI authenticates through the app's local API).
- **Verification retries for 90 s** (`--verify-timeout`). The first request after
  enabling HTTPS triggers certificate issuance and can take 10–60 s; a single-shot
  probe would report a false failure. `tailscale cert` itself is **never** retried
  — issuance is Let's Encrypt rate-limited (~50/week/domain).
- **Any status `< 500` counts as reachable.** An OAuth-protected endpoint
  correctly answers `401` on `/`; treating that as failure would be backwards.

Structural verification runs first regardless: `serve status --json` must show
`.Web["<fqdn>:443"].Handlers["<path>"].Proxy` pointing at your target. A mismatch
there is a hard failure whatever HTTP says.

`tsnet serve` is idempotent — a mapping that already points at your exact target
is an exit-0 no-op, not a conflict.

> **Funnel is deliberately not implemented.** `tailscale funnel` is the
> public-internet sibling of `serve`; one flag would take an internal service from
> tailnet-only to world-readable. Check 9 warns loudly if funnel is already on.

---

## `--host` — driving a remote box

`tsnet --host david_ubuntu serve 39100` runs the tailscale side over plain `ssh`.

It uses `ssh` rather than `fleet exec` on purpose: `fleet` resolves hosts from
`~/.config/fleet/machines.toml`, and requiring an inventory entry before you can
run one preflight inverts the tool's purpose — `tsnet` is what you use *before* a
box is in any inventory. Plain `ssh` also accepts an ssh alias, `user@host`, **or
a MagicDNS name**, including one `tsnet ssh-config` just wrote.

All reads are batched into **one round trip** with sentinel-delimited sections
(six naive `ssh host tailscale …` calls at WAN latency is a visibly sluggish
preflight). Two consequences worth knowing:

- Every sentinel is preceded by a bare `echo`, because `tailscale status --json`
  does not terminate its output with a newline — without that, the next sentinel
  lands glued to the final `}` and **every section after `status` vanishes**.
  A missing serve section would then read as `{}` = "port free", which is
  confidently wrong. An absent END sentinel is now a hard error.
- **The final HTTPS probe runs locally**, not on the remote. The URL's whole
  purpose is being reachable from where you are; probing it from the remote's own
  loopback proves nothing about the tailnet path.

`--host` is **rejected for `ssh-config`**, which writes *your local* config.

---

## Maintaining it

- **`--tsv` column order is a wire format**, consumed by
  `dot_config/television/cable/tailnet.toml` as `{split:\t:N}`:
  `0:name 1:fqdn 2:ip 3:os 4:online 5:tailnet 6:tags`. Reorder it and the channel
  breaks. The channel keys off **column 1 (fqdn)**, not column 0: HostNames are
  **not unique** on a real tailnet (`raspberrypi`, `localhost` and duplicated
  laptop names all recur), and `tsnet describe` correctly refuses an ambiguous
  needle.
- **Four shapes in `tailscale status --json`** bite a casual reading, and all four
  are live: `Peer` is a **dict keyed by nodekey** (not a list); every `DNSName`
  carries a **trailing dot**; **more than one tailnet** can appear (foreign nodes
  are excluded unless `--all-tailnets`); untagged nodes have **no `Tags` key** at
  all. `tests/unit/tsnet_ssh_block.bats` exercises all four in one fixture.
- **Include resolution is implemented here for the third time in this repo** —
  after `dot_config/shell/96_ssh_setup.sh:_ssh_cfg_py` (a surgical editor of
  human-written blocks) and the awk in `cable/ssh-config.toml` (a display lister).
  Deliberate: `tsnet` needs every alias in **parse order** (for shadow detection)
  and reachability of an **arbitrary path that may not exist yet**, neither of
  which `_ssh_cfg_py` can answer. The shared-module fix is blocked by `scripts/**`
  being chezmoi-ignored. They are kept honest by a **cross-implementation
  agreement test** in `tests/unit/tsnet_ssh_block.bats`, not by shared code.
  Unification is tracked in [`TODO.md`](https://github.com/daviddwlee84/dotfiles/blob/main/TODO.md).
- Completion is tyro **Strategy A** (`dot_config/shell/49_tsnet.sh`); see
  [zsh-completions § F](../zsh/zsh-completions.md).
