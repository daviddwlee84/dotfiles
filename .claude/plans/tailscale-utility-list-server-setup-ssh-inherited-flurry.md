# `tsnet` — Tailscale utility CLI + `tv tailnet` channel

## Context

Tailscale is on every machine here but the repo treats it as **install-and-troubleshoot only**: one Brewfile cask, one anti-formula comment, `docs/tools/Tailscale.md` (25 lines), one pitfall, one gitleaks rule. Zero shell helpers, zero CLI, zero `tv` channel, and `docs/this_repo/tool-managers.md` literally says *"Linux: system pkg outside repo"*.

Two concrete gaps prompted this:

1. **Device list → SSH config.** 15 tailnet devices exist; wiring one into `~/.ssh/config` is manual every time.
2. **Internal services that hard-require HTTPS.** The TREK/MCP case: `APP_URL` must be `https://…` or `http://localhost…` or the MCP OAuth server *silently* falls back to `http://localhost:3000`. `/api/health` → `ok`, `/mcp` → `401`, `/.well-known/oauth-protected-resource` → `200` — **all three look healthy in the broken state**. `tailscale serve` fixes it, but the setup has two non-automatable prerequisites (tailnet-wide HTTPS switch; `--operator`) that fail silently if missed.

### Three facts verified on this machine that shape the design

| Fact | Evidence | Consequence |
|---|---|---|
| **`~/.ssh/config` has no `Include` — the drop-ins are already dead** | 264 lines, `grep -in include` → nothing. `~/.ssh/config.d/{00-defaults,01_git}` exist but `ssh -G github.com` → `user david`, not `git` | The "legacy no-`Include`" fallback isn't hypothetical — it's the **default path on the primary machine** and `tsnet` hits it on first run. Also makes that branch fully testable today. |
| **Tailnet HTTPS certs are DISABLED** | `tailscale status --json` → `.CertDomains = null` | `tsnet serve`'s happy path **cannot be verified locally** until an Owner flips the admin-console switch. Preflight abort path *is* verifiable. |
| **`CLAUDE.md` is 31,648 chars** | over its own "~30k headroom" rule, 3 commits after `4e39f81` trimmed it | Any CLAUDE.md edit must be minimal; a real trim belongs in a separate commit. |

Decisions locked with the user: **new `tsnet` CLI (uv script + tyro) + tv channel** · **single managed-block file, must handle legacy no-`Include`** · **full serve wrapper (preflight → run → verify)** · **add Linux ansible install** · **fix SKILL.md.tmpl staleness + strengthen the AGENTS.md/CLAUDE.md reminder**.

---

## What ships

### New files
| Path | Purpose |
|---|---|
| `dot_dotfiles/bin/executable_tsnet` | The CLI. PEP 723 + `uv run --script` + tyro + rich + httpx. |
| `dot_config/shell/49_tsnet.sh` | tyro Strategy-A completion (49 dup is fine — 29/37/38/55/56/57 already dup; keeps the tyro cluster at 46–49). |
| `dot_config/television/cable/tailnet.toml` | The picker. |
| `docs/tools/tsnet.md` | Tool doc. |
| `tests/unit/tsnet_ssh_block.bats`, `tests/unit/tsnet_serve.bats` | ~24 offline tests. |
| `backlog/ssh-config-parser-unification.md` | Deferral note. |

### Modified
`scripts/init/dotfiles_init.py` (+`just gen-prompts`) · `dot_ansible/roles/networking_tools/tasks/main.yml` · `.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl` · `dot_config/shell/10_aliases.sh` · `dot_config/{zsh/tools/51,bash/51}_dotcfg_completion.*` · `docs/zsh/zsh-completions.md` · `docs/shells/aliases.md` · `docs/this_repo/tool-managers.md` + `.zh-TW` · `docs/tools/Tailscale.md` + `.zh-TW` · `docs/tools/tunnels.md` · `docs/tools/tv.md` · `mkdocs.yml` · `README.md` · `dot_agents/skills/chezmoi-dotfiles/SKILL.md.tmpl` · `CLAUDE.md` · `TODO.md`

---

## Design decisions (the load-bearing ones)

### 1. A third SSH-config parser — deliberate, paid for by a test not by shared code

`_ssh_cfg_py` (in `dot_config/shell/96_ssh_setup.sh`) is a **surgical editor of human-written blocks**; `tsnet` owns a **whole delimited region no human writes**. More importantly `_ssh_cfg_py` *cannot answer* what `tsnet` needs: it returns only the first matching block (shadow detection needs every alias **in parse order**), and `configd_reachable()` hardcodes `~/.ssh/config.d` (`--out` may be anywhere, and may not exist yet). Shelling out would mean a deployed Python binary spawning `bash -c 'source …96_ssh_setup.sh'` to run an embedded Python heredoc.

The clean fix — one shared module in `scripts/` — is blocked: `scripts/**` is in `.chezmoiignore.tmpl`, and `96_ssh_setup.sh` runs during first-time setup where it must degrade gracefully (`return 127` → plain append), so it can't take a hard dependency on the chezmoi source dir.

**Cost paid explicitly**: `_resolve_includes()` is copied with a header naming all three copies, and `tsnet_ssh_block.bats` carries a **cross-implementation agreement test** — assert `tsnet`'s reachability verdict and `_ssh_cfg_py ensure-include` agree in all three states (reachable / unreachable / post-fix). Behavioural SSOT beats code SSOT here. Unification → `TODO.md` P2/M.

The awk in `cable/ssh-config.toml` stays: it's a display lister, and making a general SSH picker depend on a Tailscale tool would be worse.

### 2. `HostName` = MagicDNS FQDN, with a resolve-checked `auto` fallback

`100.x` CGNAT addresses are **not stable across node lifetimes** — reinstall / key-expiry / `logout`+`up` reassigns them, and a stale IP then connects to *whichever node now holds it*: host-key mismatch, not a clean failure. The FQDN is stable and is what `tailscale serve` hands back.

But MagicDNS can be off / `--accept-dns=false` / in the `dns-forward-failing` state this repo already has a pitfall for. So `--hostname-style auto` (default) uses the FQDN **iff** `MagicDNSEnabled` **and** `getaddrinfo(fqdn)` succeeds in 2 s; else falls back to the first IPv4 **and stamps why** in a comment. The unused form is always emitted as a comment so a human can swap by hand.

### 3. `User` is resolved, never guessed

Tailscale does not know POSIX usernames — `Self.UserID` / the top-level `User` map are *tailnet account* identities (`daviddwlee84@github`), so using them would be actively wrong. First hit wins:

`--user` → **an existing `Host <alias>` block in the include closure** (stable across reruns after hand-edits) → **`~/.config/fleet/machines.toml`** matched on `ssh_alias`/`hostname`/`name`/any `TailscaleIPs` → **TTY prompt** defaulting to `$USER` → **omit the line entirely** with `# User: unset — ssh will use $USER. Pass --user to pin it.`

Omitting beats guessing `$USER`: identical runtime behaviour, nothing wrong baked into a file that outlives the guess. `machines.toml` covers only a subset (the tailnet has iOS handsets and other people's Macs) — it's a lookup, not a requirement, and must not error when absent.

### 4. `--host` uses plain `ssh`, not `fleet exec`

`fleet exec` resolves hosts from `machines.toml` — requiring an inventory entry before you can run one preflight **inverts the tool's purpose**; `tsnet` is what you use *before* a box is in any inventory. It also drags in `asyncssh` (a full SSH implementation) to fan out to N hosts, tripling cold start for a tool whose selling point is working on a fresh machine. Plain `ssh` also accepts an ssh alias, `user@host`, **or a MagicDNS name** — including one `tsnet ssh-config` just wrote.

Reuse the *idea* from `scripts/fleet/exec.py:_PATH_PRELUDE` (remote non-login shells often lack `tailscale`'s dir), and **batch all probes into one round trip** via sentinel-delimited output — 6 naive ssh calls at ~300 ms WAN RTT is a visibly sluggish preflight.

Split of work: all tailscale reads + the listener check + the `serve` write run **remote**; the final HTTPS probe runs **local** (the URL's purpose is reachability from *here*; probing from the remote's own loopback proves nothing) — and the output says so. **Nothing needing `sudo` is ever auto-run over ssh** — it's printed and the run aborts. `--host` is **rejected for `ssh-config`** (that writes *your local* config).

---

## Implementation

### Step 1 — `dot_dotfiles/bin/executable_tsnet`

Copy the idioms from `dot_dotfiles/bin/executable_mi-router` verbatim: `#!/usr/bin/env -S uv run --quiet --script`, `# /// script` block, `console`/`err` Rich pair, `die(msg, code)`, `@dataclass` per subcommand with docstrings as help, `Cmd = Union[...]`, `tyro.cli(Args, config=(tyro.conf.OmitSubcommandPrefixes,))`. Deps: `tyro>=0.9`, `rich>=13`, `httpx>=0.27`. No `asyncssh`, no `platformdirs`.

```
tsnet list       [--tsv|--json] [--online-only] [--all-tailnets] [--os-filter OS]
tsnet describe   MACHINE [--json]                     # backs the tv preview pane
tsnet ssh-config MACHINE... [--out PATH] [--inline] [--alias A] [--alias-prefix P]
                 [--user U] [--identity-file F] [--identities-only] [--port N]
                 [--hostname-style auto|magicdns|ip|short] [--add-include ask|yes|no]
                 [--include-position top|bottom] [--setup-remote] [--dry-run]
                 [--no-verify] [--strict] [--yes] [--json]
tsnet serve      PORT [--path /] [--https-port 443] [--off] [--force] [--dry-run]
                 [--allow-no-listener] [--verify-timeout 90] [--json]
tsnet doctor     [--port N] [--json]                  # preflight only, never mutates
tsnet status     [--json]                             # decoded serve/funnel config

global: --host HOST  --ssh-opt OPT...  --timeout 10  --tailscale-bin PATH
```

**`--tsv` is a wire format** (same status as `appsrc scan --tsv` in CLAUDE.md) — reorder it and every `{split:\t:N}` in the channel breaks:

```
0:name  1:fqdn  2:ip  3:os  4:online  5:tailnet  6:tags
```
`fqdn` = `DNSName` with the **trailing dot stripped** · `online` = `up`/`down` (awk-friendly, never `True`) · `tags` = `-` when the key is absent (it is, for untagged nodes) · sorted self-first, then online, then name. No header.

`--json` implies non-interactive: anything that would prompt becomes a non-zero exit with the remediation in the payload.

**Traps in `tailscale status --json`** — all four appear live and all four are in the test fixture: `Peer` is a **dict keyed by nodekey** (iterate `.values()`, never index) · every `DNSName` has a **trailing dot** · **two tailnets** are present (`tail8cadff.ts.net` strays are excluded unless `--all-tailnets`) · untagged nodes have **no `Tags` key at all**.

**Exit codes**: `0` ok (incl. "already correct, nothing written") · `1` generic · `2` no tailscale binary · `3` backend not Running · `4` ssh-config target unreachable, user declined fix · `5` malformed markers · `6` certs disabled / node uncovered · `7` operator unset · `8` nothing listening · `9` `:443` claimed · `10` written but shadowed (`--strict` only).

### Step 2 — the managed-block algorithm

Markers, **with no timestamp** (a timestamp makes every rerun a diff and destroys idempotency):

```
# BEGIN tsnet ssh-config v1 — managed block; edits INSIDE are overwritten
# tailnet: daviddwlee84.github (tail7f7fc5.ts.net)

Host david-ubuntu
    HostName david-ubuntu.tail7f7fc5.ts.net
    # tailscale IP: 100.77.43.16
    User david
    IdentityFile ~/.ssh/id_ed25519_david-ubuntu
# END tsnet ssh-config
```

1. **Load + normalise** devices (see the four traps above).
2. **Resolve target** — `--out` (default `~/.ssh/config.d/20-tailscale`), or `$SSH_CFG_ROOT` when `--inline`.
3. **Build the include closure** — DFS from `$SSH_CFG_ROOT` following `Include`, in file order, glob-expanded + `sorted()`, `realpath` visited-set. The resulting order **is ssh's parse order**; steps 8 and 9 depend on it.
4. **Reachability check → the legacy fallback.** Match `--out` against each `Include` *pattern* (not each resolved file — the target may not exist yet) via `fnmatch`, plus `realpath` equality against files already in the closure. Unreachable → print the concrete diagnosis (`~/.ssh/config` is 264 lines, 0 Include directives; `config.d/` holds 2 unloaded files) and offer:
   - **(a) `--add-include=yes`** — insert `Include ~/.ssh/config.d/*`. **This is not a no-op and the prompt must say so**: ssh takes the *first-obtained* value, so a top-inserted Include makes `config.d/*` win. On this Mac that flips `github.com` from `User david` to `User git`. So **unconditionally** diff `ssh -G <alias>` for every alias defined in both the root config and the newly-reachable drop-ins, and print the deltas before writing. `--include-position=bottom` makes the drop-ins strictly additive instead.
   - **(b) `--inline`** — same block appended to `~/.ssh/config`. Zero precedence change. Right answer for a machine you don't want to restructure.
   - **(c) abort** — exit 4.
5. **Render** via a pure `render_block(entries) -> str` (this is what the bats tests target). 4-space indent, aliases sorted, `IdentityFile` tildified, omitted keys emit nothing.
6. **Splice** — exactly one BEGIN/END pair → replace inclusive, everything outside preserved byte-for-byte; zero → append after one blank line; **unpaired or >1 BEGIN → exit 5, write nothing** (never guess which region is ours).
7. **Idempotency** — if the spliced bytes equal the current bytes, print `unchanged: <path>` and **do not write** (mtime preserved → `chezmoi status` and backup tooling stay quiet). With no timestamp in the block this is always true for an unchanged tailnet.
8. **Atomic write** — `mkstemp(dir=parent)` → write → `chmod 0600` → `os.replace()`, temp unlinked on any exception. Same shape as `_ssh_cfg_py.write_atomic`.
9. **Shadow detection** — walk the closure in parse order collecting every non-wildcard alias (skip patterns with `*?!`, same rule as `block_matches`), excluding lines inside our own markers. Lower ordinal elsewhere → **we are inert**; name `file:line`, suggest `--alias-prefix ts-`. Exit 0 by default, 10 with `--strict`.
10. **Verify** (unless `--no-verify`) — `ssh -G <alias>`, assert `hostname` matches what we wrote. This one check catches **both** failure modes at once (ineffective Include *and* shadowing) and is what makes this whole silent-failure class impossible to miss.
11. **Hand off to `ssh-setup-remote`** — it's a shell *function*, so `os.execvp("bash", ["bash","-c",'source "$HOME/.config/shell/96_ssh_setup.sh"; ssh-setup-remote "$1"',"_",alias])`. `execvp` not `subprocess` so the TTY is handed over cleanly (it does ~10 `read -r` prompts and `ssh-copy-id` needs a real terminal). Gated on the file existing; otherwise just print the command.

### Step 3 — `serve` preflight → execute → verify

| # | id | Source | Fail |
|---|---|---|---|
| 1 | `binary` | `which`, `/usr/local/bin/tailscale`, the app bundle, `$TSNET_TAILSCALE_BIN` | exit 2 |
| 2 | `backend` | `.BackendState == "Running"` | exit 3 |
| 3 | `health` | `.Health` non-empty | warn |
| 4 | `certs` | `.CertDomains` null/`[]` | **exit 6** ← fires here today |
| 5 | `cert-covers-node` | `.Self.DNSName` (dot-stripped) ∈ `.CertDomains` | exit 6 |
| 6 | `operator` | Linux + non-root only: `tailscale debug prefs` → `OperatorUser`. **The key is `omitempty` — absent means unset.** Skipped entirely on Darwin (no operator concept there). | exit 7 |
| 7 | `listener` | `socket.create_connection(("127.0.0.1",PORT),1)`; on failure name what *is* there via `lsof`/`ss` | exit 8 (`--allow-no-listener` → warn) |
| 8 | `port-443-free` | `tailscale serve status --json` — `{}` = free (verified). Already ours → **exit 0 no-op** | exit 9, or `--force` |
| 9 | `funnel-off` | `.AllowFunnel` non-empty | **warn loudly — PUBLIC INTERNET** |

Remediation text is copy-pasteable and names the human step explicitly, e.g. check 4:

```
tsnet: tailnet HTTPS certificates are DISABLED (.CertDomains = null)
       TAILNET-WIDE setting, CANNOT be automated — needs an Owner/Admin:
         1. https://login.tailscale.com/admin/dns → "HTTPS Certificates" → Enable
         2. tailscale cert "$(tailscale status --json | jq -r .Self.DNSName | sed 's/\.$//')"
         3. tsnet doctor
```
With `--host`, remediation is pre-filled as `ssh david_ubuntu 'sudo tailscale set --operator=$USER'`.

**Execute**: `tailscale serve --bg --https=443 http://127.0.0.1:<PORT>` (+ `--set-path` when `--path` ≠ `/`).

**Verify**: (a) re-read `serve status --json`, assert `.Web["<fqdn>:443"].Handlers["<path>"].Proxy` matches — a structural mismatch is a hard failure regardless of HTTP; (b) probe **locally** with `httpx`, retried to a 90 s deadline — **the first request after enabling HTTPS triggers Let's Encrypt issuance and takes 10–60 s**, so a single shot reports a false failure. Any status `< 500` counts as reachable: an MCP OAuth server correctly answers `401` on `/`, and calling that a failure would be exactly backwards. **Never retry `tailscale cert`** (LE rate limit ~50/week/domain). Then print the URL plus the line that matters:

```
ready: https://david-ubuntu.tail7f7fc5.ts.net/
       (register as the MCP base URL — satisfies the https:// requirement
        that http://<lan-ip> silently fails)
```

### Step 4 — `dot_config/television/cable/tailnet.toml`

Thin shell-out to the CLI (the `fleet-hosts.toml` pattern) — *not* awk (`Peer`-as-dict + trailing dots + two tailnets + absent `Tags` would make a fourth fragile parser), *not* the `lan-devices` cached-TSV+`watch` pattern (that exists because nmap takes 30 s; `tailscale status --json` is a ~40 ms unix-socket call, so a cache would go stale exactly when a device comes online).

```toml
[source] command = ["tsnet list --tsv --online-only", "tsnet list --tsv", "tsnet list --tsv --all-tailnets"]  # Ctrl+S cycles
[preview] command = "tsnet describe '{split:\t:0}'"
```

Keybindings — **`alt-w` and `alt-z` are the only two Alt letters unused across all 48 channels** (verified), and there are **no tmux root-table `bind -n M-*` bindings** to shadow them (verified). Spend both on the two genuinely new verbs; established verbs keep their established letters:

| Key | Action |
|---|---|
| `Enter` | `ssh <fqdn>` — matches `fleet-hosts` and `ssh-config` muscle memory |
| `Alt+W` | **new** — `tsnet ssh-config` |
| `Alt+Z` | **new** — `tsnet --host <fqdn> doctor` |
| `Alt+T` | probe (established: fleet-hosts, ssh-config) |
| `Alt+Y` | copy FQDN (established across 7 channels) |
| `Alt+P` | `tailscale ping` (direct vs DERP path) |

### Step 5 — Linux install: new `installTailscale` prompt + `networking_tools` tagged section

**New prompt key, not riding an existing one.** Not `installTunnelTools` — `docs/tools/tunnels.md` is about exposing localhost *to the public internet*; `tailscale serve` is the categorical opposite (tailnet-only). The ngrok analogue is `tailscale funnel`, deliberately not implemented. Not `installNetworkingTools` — that's a read-only diagnostics bundle (nmap/mtr/httpie/gping/trippy); installing a daemon that joins a mesh and reconfigures DNS because someone wanted `nmap` is a consent violation.

Placement: a `tags: [tailscale]` section inside `dot_ansible/roles/networking_tools/tasks/main.yml`, structurally identical to the existing `tags: [tunnel_tools]` section at L686–1008 (verified present). No new role, no new hash line (L39 already hashes that file).

Mechanism: **official apt repo via `deb822_repository` + a SCOPED `apt-get update`** — the Steam pattern from `gui_apps_linux`, not `curl | sh`. `gui_apps_linux/tasks/main.yml:720` already names tailscale as one of the third-party sources that makes an unscoped `apt-get update` flaky; the install script creates that same source anyway, just opaquely and non-idempotently. Guard on `tailscale version`, `rescue:` → warn + print the `curl | sh` fallback, RedHat gets a parallel best-effort block.

**Deliberately not automated** (install-vs-upgrade invariant + both are interactive), printed as a post-install `debug` message using the *same string* check 6 prints, so it's recognisable later:

```
sudo tailscale up                      # browser login, joins the tailnet
sudo tailscale set --operator=$USER    # lets `tsnet serve` run without sudo
```

Then `just gen-prompts` (regenerates `.chezmoi.toml.tmpl` + `Dockerfile` — **never hand-edit the marker regions**), `TAGS="${TAGS},tailscale"` gated on the key and `ne .chezmoi.os "darwin"`, and the README option-table row.

### Step 6 — SKILL.md.tmpl: new content + the backfill

New: a `{{- if dig "installTailscale" false . }}` bullet under *What's enabled*, and a `tsnet` bullet under *Custom in-house CLIs*.

Backfill the staleness the audit found (last touched `cfae33d` 2026-07-20; **59 commits since**):

| Fix | Why |
|---|---|
| **L147 `prefix + e`** | **Wrong and dangerous.** That alias was removed; `prefix + E` is now *"Explode — break every pane into its own window"*. An agent that reads this and mis-shifts **destroys the user's layout**. Highest priority in the file. |
| 4 missing CLIs | `agent-warmup`, `crash-blackbox`, `view-ebook` (its sibling `view-office` *is* listed), `nvidia-driver-drift-check` |
| The whole `herdr` family | CLI + 3 tv channels + `just upgrade-herdr` + `docs/tools/herdr.md` + 3 pitfalls. The word "herdr" appears **nowhere** in the skill — an agent on this host cannot discover it. |
| `agentSounds` prompt key | Added 2026-07-25; a new prompt key is *precisely* the contract's stated edit trigger |
| `installWakeOnLan` gate | The `wake` bullet is unconditional, so hosts without it still see `wake` advertised |
| "~40 channels" → 48 | |

### Step 7 — `CLAUDE.md` (= `AGENTS.md`, symlink — one edit covers both)

The current row's claim that freshness "is automatic" is wrong in a load-bearing way: **only the `{{ dig … }}` substitutions re-render, the prose does not.** That is exactly why 5 CLIs, all of `herdr`, and `agentSounds` went missing. Replacement (compact, ~+150 chars):

> `dot_agents/skills/chezmoi-dotfiles/SKILL.md.tmpl` — **only the `{{ dig … }}` substitutions re-render on apply; the prose does NOT.** A new `dot_dotfiles/bin/executable_*`, tool family, or prompt key stays invisible to every agent until hand-added here (an audit found 5 CLIs, all of `herdr`, and `agentSounds` missing). Keep it lean — the `ls dot_dotfiles/bin/` escape hatch is a fallback, not a substitute.

The 3-parser hazard goes as a trailing clause on the **existing** in-house-CLI row, not a new row.

> **Headroom flag**: CLAUDE.md is already 31,648 chars (~1.6k **over** its own ~30k rule). This adds ~+150. A real trim — the fattest candidate is the yazi-preview row, ~1,450 chars nearly all duplicated in `docs/tools/yazi-previews.md` — is cleaner as its **own commit** than smuggled into a Tailscale change.

### Step 8 — tests (bats; there is no pytest in this repo)

Follow `tests/unit/x_cli.bats`: `load "../test_helper.bash"`, `setup_path_stub`, stub `tailscale` as an inline heredoc in `$BATS_STUB_DIR` that records argv and cats fixture JSON. No `tests/fixtures/` dir exists — keep it that way. `just bats` already globs `tests/unit`.

**`tsnet_ssh_block.bats`** — exact block bytes · idempotent (byte-identical **and mtime unchanged** — this is the test that fails if anyone re-adds a timestamp) · content outside markers preserved · legacy no-`Include` → exit 4 + **file not created** · `--add-include=yes` fixes it **and agrees with `_ssh_cfg_py ensure-include`** in all three states (the cross-implementation SSOT guard) · `--include-position=bottom` · `--inline` · malformed markers → exit 5 + **file byte-identical** · shadow → `file:line` + exit 10 with `--strict` · `--alias-prefix` · `--tsv` field count = 7 and exact order · one fixture exercising all four tailnet traps at once · `User` omitted-not-guessed when non-TTY · `User` from `machines.toml`.

**`tsnet_serve.bats`** — certs disabled → exit 6 **and `tailscale serve` never appears in the recorded argv** (the no-mutation half is the important half) · node uncovered · operator unset on Linux (prefs JSON **without** the key, the real shape) · operator check **skipped** on Darwin · no listener → exit 8, `--allow-no-listener` proceeds · `:443` taken → exit 9 no mutation · `:443` already ours → exit 0 no-op · `--dry-run` prints the exact command and invokes nothing · `doctor --json` parseable with `.ok == false` · funnel warning.

---

## Verification

**Runnable here today:**
```bash
cd "$(chezmoi source-path)"
just bats && uv run mkdocs build --strict && just gen-prompts --check && just lint
chezmoi diff && chezmoi apply

tsnet list                                             # 15 devices, 2 tailnets
tsnet list --tsv | awk -F'\t' '{print NF}' | sort -u   # must print exactly: 7
tsnet describe david-ubuntu && tv tailnet              # Ctrl+S cycles 3 sources

# The legacy-Include path reproduces for real on this Mac:
tsnet ssh-config david-ubuntu --dry-run
#   → reports "no Include reaches ~/.ssh/config.d/20-tailscale"
#   → lists the resolution delta (github.com user: david → git)
#   → exits 4 without writing

# Idempotency against a throwaway tree (zero risk to real ~/.ssh):
SSH_CFG_ROOT=/tmp/t/config tsnet ssh-config david-ubuntu --out /tmp/t/config.d/20-tailscale --add-include=yes --yes
SSH_CFG_ROOT=/tmp/t/config tsnet ssh-config david-ubuntu --out /tmp/t/config.d/20-tailscale --yes   # → "unchanged"

tsnet doctor              # checks 1,2,3 pass; check 4 FAILS — expected, see below
tsnet serve 8787 --dry-run
tsnet --host david_ubuntu doctor                       # one ssh round trip
```

**Explicitly NOT verifiable here** (per the *"validate with the app, not just syntax"* invariant):

1. **The `serve` happy path.** `.CertDomains` is `null` — tailnet HTTPS is a **tailnet-wide admin-console setting** with no CLI and no automation path. Until an Owner enables it at <https://login.tailscale.com/admin/dns>, `tsnet serve` correctly aborts at check 4 and execute/verify/probe are **never exercised against a live tailnet**. Covered by stubs (tests 15–24) and the `--dry-run` command construction — that's most of the risk, but the final report must say the E2E path was not run.
2. **The ansible Linux install.** Best available from macOS: `just ansible-syntax-check` → `just ansible-check` → `fleet chezmoi diff david_ubuntu`, then on the box itself `ansible-playbook playbooks/linux.yml --tags tailscale --check`. `--syntax-check` alone is only a first pass.

**After the switch is flipped:**
```bash
tailscale cert "$(tailscale status --json | jq -r .Self.DNSName | sed 's/\.$//')"
python3 -m http.server 8787 --bind 127.0.0.1 &
tsnet serve 8787 && curl -I "https://$(tailscale status --json | jq -r .Self.DNSName | sed 's/\.$//')/"
tsnet serve 8787 --off
```

---

## Risks

- **Adding the `Include` at the top of `~/.ssh/config` is a behaviour change on this Mac**, not a no-op — it flips `github.com` to `User git`. The delta preview must be **unconditional**, never behind a flag.
- **`tailscale funnel` is one flag from making an internal service public.** v1 ships no `--funnel`; check 9 warns loudly if funnel is already on. Don't let a convenience flag creep in.
- **A third apt source on Linux** compounds flakiness `gui_apps_linux` already documents — don't "simplify" the scoped `apt-get update` away.
- **`tsnet` collides with Tailscale's own Go library name** (`tailscale.com/tsnet`) — cosmetic, no binary conflict; noted in the docs.
- **macOS `serve` needs the app running** (the macsys system extension *is* the daemon) — fine here, would not work on the delisted App Store build.
- **`--host` against a box with neither `ss` nor `lsof`** → check 7 degrades to unknown; warn, don't abort.

## Deferred to `TODO.md` / `backlog/`

- `P2 [M]` **Unify the three SSH-config parsers** → `backlog/ssh-config-parser-unification.md` (blocked on `scripts/**` being chezmoi-ignored)
- `P? [M]` **`tsnet sync-fleet`** — reconcile tailnet devices into `machines.toml`; needs a spike on the population mismatch first
- `P3 [S]` **`tsnet funnel`** · `P3 [M]` **serve for TCP / unix-socket targets** (v1 is HTTP-proxy only)
- `P2 [S]` **CLAUDE.md headroom trim** — its own commit
