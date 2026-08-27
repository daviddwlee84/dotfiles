# Copilot agent gateway (Claude Code + Codex)

Back [Claude Code](https://code.claude.com/docs/en/overview) with the models
served by a **GitHub Copilot subscription** (Claude when entitled; otherwise a
role-aware OpenAI fallback), via a local
reverse-engineered proxy — the maintained fork
[`caozhiyuan/copilot-api`](https://github.com/caozhiyuan/copilot-api)
(npm `@jeffreycao/copilot-api`). The original
[`ericc-ch/copilot-api`](https://github.com/ericc-ch/copilot-api) is
officially unmaintained ([issue #233](https://github.com/ericc-ch/copilot-api/issues/233)
points at the fork) but still works via `COPILOT_API_PKG=copilot-api@0.7.0`.
Both packages share the same token file
(`~/.local/share/copilot-api/github_token`), so switching needs **no re-auth**.

- **Shell helpers**: `~/.config/shell/43_copilot_proxy.sh` (`copilot-proxy`,
  `claude-copilot`, `codex-copilot`, `copilot-run`, `copilot-here`,
  `copilot-model`)
- **Runner**: `@jeffreycao/copilot-api` (pinned), installed **once** into
  `~/.local/share/copilot-api/pkg` and executed directly from there. Deliberately
  **not** `bunx` at launch: bunx re-resolves the package on every start, and bun
  stalls forever resolving through a socks `ALL_PROXY` — see
  [Gotchas](#start-used-to-hang-at-resolving-dependencies-behind-a-socks-proxy).
  A warm start does zero network before it binds the port.
- **Not installed by ansible** — installed on first `copilot-proxy start`, so it
  stays off the provisioning path. `copilot-proxy update --check` is read-only;
  only an explicit exact `copilot-proxy update VERSION` changes the pin.

!!! warning "This violates GitHub Copilot's Terms of Service"
    Using a Copilot subscription to power a non-GitHub agent is not permitted, and
    copilot-api is reverse-engineered/unofficial. It can trigger GitHub's
    **abuse detection** and lead to **temporary suspension of Copilot access**.
    Claude Code is token-hungry (frequent background calls, large context) —
    note the fork has **no rate limiter** (see Gotchas); `COPILOT_PROXY_QUIET=1`
    reduces background chatter. Use at your own risk; prefer a personal account
    over a corporate seat.

## Quick start

```sh
copilot-proxy auth      # one-time: GitHub device login (stores a ghu_ token)
copilot-proxy start
copilot-model --auto    # Claude if served; otherwise Sol/Terra/Luna by role

claude-copilot          # one-off session on the proxy (auto-starts it; no file writes)
claude-copilot-once     # pin THIS project, run one session, then auto-unpin (proxy must be up)
codex-copilot           # one-off Codex session; auto-picks OpenAI first
codex-copilot-once      # exact alias; neither name writes Codex config

copilot-here on         # OR: pin THIS project — plain `claude` uses the proxy
copilot-here off        # unpin — back to the real Anthropic backend
```

## How it works

```
Claude Code ──Anthropic /v1/messages──▶ throttle/metrics shim (:4142) ─▶ copilot-api (:4141)
                                          │ Claude: native Messages path
                                          │ GPT: Anthropic → Responses translation
                                          ▼
                                   api.githubcopilot.com  (your Copilot sub)

Codex ──OpenAI /v1/responses──────────▶ the same :4142 managed gateway
        (provider/model are one-invocation `-c` / `-m` overrides)
```

- Claude Code speaks only the **Anthropic Messages API** (`/v1/messages`).
- The fork uses Copilot's native Anthropic path for Claude ids and translates
  Claude Code requests to the **Responses API** for GPT ids. The pinned `2.3.4`
  forwards Claude Code's `output_config.effort` to `reasoning.effort`, preserves
  reasoning state, and handles the GPT-5.6 request shape.
- The original (`copilot-api@0.7.0`) always translates through
  `/chat/completions` — thinking blocks are dropped and WebSearch doesn't work.
- Claude Code is pointed at the proxy via `ANTHROPIC_BASE_URL` — injected either
  as per-process env (`claude-copilot`) or via the gitignored
  `./.claude/settings.local.json` (`copilot-here on`). See "Settings-layer design".

## Settings-layer design (which file gets the proxy config, and why)

Claude Code merges settings low → high: `~/.claude/settings.json` (user) →
`./.claude/settings.json` (project, committed) → `./.claude/settings.local.json`
(local, gitignored) → CLI flags. The
[docs](https://code.claude.com/docs/en/settings) (and third-party writeups)
claim shell env vars beat every settings-file `env` block, but **empirically
(verified 2026-07) current Claude Code lets the `settings.local.json` `env`
block beat inherited shell env** — see Gotchas.

Two of those layers are already owned by other tooling and must stay clean:

| Layer | Owner | Why proxy config must NOT go here |
|---|---|---|
| `~/.claude/settings.json` | chezmoi (`dot_claude/modify_settings.json.tmpl`) | always-on for *every* project; fights the chezmoi merge |
| `./.claude/settings.json` | `claude-plans-here` (`plansDirectory`) | committed to git — proxy config would leak to the team |

So the proxy uses the two layers nobody else owns:

| Enable | Mechanism | Scope | Disable |
|---|---|---|---|
| `claude-copilot` / `copilot-run` | per-process env vars | one session | just run plain `claude` next time |
| `claude-copilot-once` | `./.claude/settings.local.json` pin, auto-reverted | one session | automatic — unpins on exit |
| `copilot-here on` | `./.claude/settings.local.json` (gitignored) | this project, sticky | `copilot-here off` |

```
~/.claude/settings.json          .claude/settings.json         shell env                    .claude/settings.local.json
(chezmoi: hooks/plugins)    <    (git: plansDirectory)     <   (claude-copilot)         <   (copilot-here on/off)
```

(Shell env still beats the user- and project-level settings files, so
`claude-copilot` works everywhere `copilot-here` is off — it just cannot
*override* an active `copilot-here` pin.)

## Shell helpers

### `copilot-proxy [start|stop|status|stats|events|quota|bench|update|...]`

Manages the background proxy on `$COPILOT_PROXY_PORT` (default `4141`).

| Env var | Default | Meaning |
|---|---|---|
| `COPILOT_PROXY_PORT` | `4141` | port the proxy listens on |
| `COPILOT_HTTP_PROXY` | `auto` | How Node reaches GitHub `/models` at startup: `auto` attaches `--proxy-env` + `HTTPS_PROXY` when `proxy-status` detects Clash Verge / mihomo / CFW (or macOS System Proxy); `always` same but warns if none found; `never` skips (non-GFW hosts); or an explicit `http://127.0.0.1:PORT`. **Node ignores the macOS System Proxy** — TUN/Mixin used to hide this by capturing all TCP. |
| `COPILOT_API_PKG` | unset | Highest-priority temporary package override. Otherwise the persisted exact selection is used, then the built-in `@jeffreycao/copilot-api@2.3.4` pin. While set, `update VERSION` refuses to change persisted state. |
| `COPILOT_PROXY_RATE` | `15` | `--rate-limit` seconds — **original package only** (the fork has no rate limiter) |
| `COPILOT_PROXY_QUIET` | `0` | `1` = inject extra quota-saving Claude Code env (see below); off by default because it slightly degrades the UX |
| `COPILOT_INSTALL_NOPROXY` | `0` | `1` = install the package with the proxy env stripped, skipping the 45s stall on a host where bun cannot resolve through the proxy |

Set these in `~/.shellrc.adhoc` (or the per-shell secrets files). `start` refuses
to run until `copilot-proxy auth` has stored a token, and waits up to ~20s for the
proxy to answer before returning. `start` detects the package flavor from
`COPILOT_API_PKG`: only the exact original `copilot-api` gets
`--rate-limit`/`--wait` (the fork's `start` doesn't have those flags).

The **first** `start` installs the pinned package into
`~/.local/share/copilot-api/pkg` (stamped with the spec) and every later start
just execs the resulting binary — no registry round-trip, no per-launch resolve.
The install tries your ambient env first (needed where the registry is only
reachable *through* the proxy) and retries with the proxy stripped if that stalls;
either attempt is killed on a timeout, so a stalled install can never keep bun's
global cache lock and wedge the next one. If `start` times out it now also **kills
the server it spawned**, instead of leaving an orphan behind for every retry.

`copilot-proxy quota [--json]` (also `whoami`) is the real live plan/quota check.
On the fork it reads `/usage`, the same payload used by `/usage-viewer`; it
requires the proxy to be running. Use it instead of opening the plaintext token.

### Traffic statistics and safe benchmarks

The shim is enabled by default for managed Claude/Codex launchers. If it is
enabled but cannot start, launchers fail closed instead of silently bypassing
measurement; `copilot-proxy shim off` is the explicit direct-to-`:4141`
break-glass mode.

Before upstream model bytes are exposed, the shim retries the **same buffered
request and model** on network failures or HTTP 403/429/500/502/503/504. HTTP
402 and bare 401 pass through once. Queue waiters and retry backoff are
client-cancel aware, so an abandoned request cannot retain a permit ahead of
live work. Every successful streamed response must have the SSE media type,
including responses inside the grace window. For slow streams the shim sends
SSE comments while queueing/retrying; if that pre-header pipeline then yields a
non-2xx or a non-SSE HTTP 200, it emits the native Anthropic Messages or OpenAI
Responses terminal error shape instead of splicing JSON after comment frames.
Responses classify 402 as quota, 429 as rate limit, other post-commit 4xx as
invalid prompt, and 5xx/transport failures as server error so Codex does not
retry nonretryable failures. A delayed bare 401 must use `invalid_prompt` as a
stopgap because Codex has no nonretryable Responses authentication code; only a
pre-commit HTTP 401 preserves authentication semantics. Once model bytes have
started, a later body error/stall terminates the stream and is not retried.

```sh
copilot-proxy stats week --model gpt-5.6-sol
copilot-proxy events day --limit 20 --json
copilot-proxy quota --json
copilot-proxy bench --model gpt-5.6-sol --runs 3 --max-output 256
```

`stats` defaults to normal interactive traffic; choose `--scope benchmark` or
`--scope all` explicitly. It reports request/error/retry counts, p50/p90/max
queue time, upstream-header time, first-byte time, stream/end-to-end duration,
tokens, AIU and output tokens/sec. Output throughput is only calculated for a
completed stream that has a matching token event; otherwise it is `null`.

Timing rows are stored without prompts or response bodies in
`$XDG_STATE_HOME/copilot-proxy/metrics.sqlite` (WAL, 90-day retention). The
fork separately owns `$XDG_DATA_HOME/copilot-api/copilot-api.sqlite`; its
`token_usage_events` table is what `/usage-viewer` and `/token-usage*` read.
There is no quota-history table: `/usage` is live GitHub data. The CLI joins the
two databases by `x-trace-id`, aggregating multiple token events for the same
request/model first. `stats` and `events` work offline while both processes are
down.

`bench` sends real streaming Responses requests and consumes real quota. Safety
limits are enforced: 1–10 runs, 32–2048 maximum output tokens and concurrency
1–4. Benchmark rows are tagged separately and do not pollute normal-use stats.

### Package supply and explicit updates

Warm starts execute the installed binary and do not contact npm, so registry
availability only affects first install, reinstall or update. Normal npm
unpublishing is unlikely for an established package, but maintainer, policy and
Copilot-protocol risks remain; the package is still unofficial and has a small
maintainer surface.

`copilot-proxy update --check` queries canonical npm (configured registry only
as a warned fallback) and never installs. `update VERSION` accepts exact semver
only, verifies npm's SHA-512 tarball integrity, installs and smoke-tests a
staging prefix, atomically swaps it, and keeps `pkg.previous`. If a previously
running proxy fails to start after the swap, the old package selection and
prefix are restored and restarted. The selected `{spec, integrity, registry,
selected_at}` lives in `$XDG_STATE_HOME/copilot-proxy/package.json`.

The audited built-in release is `@jeffreycao/copilot-api@2.3.4`: tag commit
[`a515535`](https://github.com/caozhiyuan/copilot-api/commit/a51553569ba071e0c9a8329f8f5ccac2482a3945),
npm tarball SHA-1 `643f59e0c257db613954738f02300c0a7ceebfeb`, SRI
`sha512-yRMH3wQAH74a0K/3Gl0S3itSL7Dza/7qOGG32PXV3tKRd4feG3utpuIQf42HhnhIdcBwMz3qhmeWBPQrPxZQMQ==`,
35 files, and npm Trusted Publisher provenance from
[release run 32856658249](https://github.com/caozhiyuan/copilot-api/actions/runs/32856658249).
A host with a persisted older selection moves deliberately with
`copilot-proxy update 2.3.4`; verified exact rollback targets remain
`copilot-proxy update 2.3.0` and `copilot-proxy update 2.1.0`.

On a **normal install** (not `update`), the pinned selection is cross-checked
against what actually landed in the prefix. `package-lock.json` is consulted
only when its recorded `version` matches the installed one: the install prefix
is mixed-manager by design — `bun add` writes `bun.lock`, while the npm CA-stack
fallback writes `package-lock.json` and nothing ever removes it — so an old lock
routinely describes a version that is no longer installed. Without that gate the
check compares two different versions' genuine hashes and refuses every start
([pitfall](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/copilot-proxy-stale-package-lock-integrity.md)).
When no lock applies, the fallback compares npm registry metadata for the
**installed** version. Both refusal messages print `on disk:` and `pinned:`.

### `copilot-proxy doctor [--live]` (alias: `test`)

Diagnoses the whole path and exits non-zero on any failure. Read-only by default;
`--live` adds one real `POST /v1/messages` (`max_tokens: 1`, a non-`[1m]` chat
model) that costs one quota unit but is the only check that exercises streaming.

Sections, in order: prerequisites (`bun`/`curl`/`jq`) → **package** → token file →
proxy and throttle-shim liveness → stale installer → **models** → upstream
reachability → local proxy/VPN → **Codex Apps** → live inference probe.

The **package** check reports whether the pinned spec is installed in the prefix
and where its binary is. "Not installed" is a note, not a failure — the next
`start` installs it once.

The **stale-installer** check is a safety net for the trap described in
[Gotchas](#start-used-to-hang-at-resolving-dependencies-behind-a-socks-proxy): any
live `bun add … copilot-api` at rest means an install has stalled (bun hangs
resolving through a socks proxy) and is holding bun's global cache lock. The
installer now bounds and kills its own attempts, so this should stay empty; if it
ever fires, doctor prints the clear-and-restart one-liner.

The models section is the one that earns the command. It compares what the proxy
serves against what GitHub serves *right now*, which is the only way to separate
the two indistinguishable causes of a `400 model_not_supported`:

| Proxy has claude? | Upstream has claude? | Verdict | Fix |
|---|---|---|---|
| no | **yes** | stale cache | `copilot-proxy restart` |
| no | no | org policy disables Anthropic | a restart will not help |

It validates the main model **and** the Fable/Opus/Sonnet/Haiku aliases against
the served list, including `[1m]` aliases. A stale background-role id can make
workflows fail with 400 even while ordinary chat succeeds. No Claude entitlement
is a warning rather than a failure when the computed OpenAI profile is usable.

Upstream reachability probes both `api.enterprise.githubcopilot.com` and
`api.githubcopilot.com`, directly *and* through the macOS system proxy when one is
set, so a Clash/mihomo rule that black-holes one host shows up immediately. An
unauthenticated `400`/`401` counts as reached — only a connect/read failure is a
fault. `doctor` never prints your token: it passes credentials to `curl` via
`-K -` (stdin), never argv, since argv is readable through `ps`.

With `--live`, the Codex Apps section also probes
`https://chatgpt.com/backend-api/wham/apps` directly and through the detected
HTTP proxy. This GET consumes no model inference quota; it separates a
`codex_apps` startup interruption from the localhost Copilot route. Any real
HTTP status (including an auth rejection) proves network reachability, while
timeouts and TLS certificate failures remain distinct. `codex_apps` is a
remote ChatGPT MCP, not an Apple-Silicon-only Codex Desktop bridge.

### `claude-copilot [--no-specstory] [claude args...]` — one-off session

Layer 1: run a single Claude Code session on the proxy with **zero file
writes**. Auto-starts the proxy if it isn't answering, then launches `claude`
with the `ANTHROPIC_*` env injected per-process (shell env beats the user- and
project-level settings files — but **not** an active `copilot-here` pin in
`settings.local.json`; see Gotchas).

- Wraps in `specstory run claude` when specstory is installed (markdown
  auto-save — same convention as `scode`/`svibe`); opt out with
  `--no-specstory`. Extra args reach the claude CLI via specstory's
  `-c "custom command"` passthrough: `claude-copilot -c` → continue session.
- **The passthrough preserves your `claude_cmd`.** specstory's `-c` *replaces*
  the provider command rather than appending to it, so the args are appended to
  the effective `claude_cmd` from your specstory config (project
  `./.specstory/cli/config.toml` > user `~/.specstory/cli/config.toml` > bare
  `claude`). That is what keeps `claude_cmd = "claude --dangerously-skip-permissions"`
  in force for `claude-copilot --resume <id>` and not just for a bare
  `claude-copilot` — the two used to disagree, see
  [`pitfalls/specstory-custom-command-drops-configured-flags.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/specstory-custom-command-drops-configured-flags.md).
  `--no-specstory` deliberately does *not* inherit it (opting out of specstory
  opts out of its config too).
- Revert = nothing to revert; plain `claude` next time is untouched.

### `claude-copilot-once [--no-specstory] [claude args...]` — one-shot pinned session

Layer 1's ephemerality with Layer 2's reliability: pin **this project** via
`copilot-here on`, run one `claude-copilot` session, then `copilot-here off` on
exit — even on Ctrl-C. Use it when pure env injection isn't enough because
`settings.local.json` outranks shell env (see Gotchas), but you don't want to
leave a sticky pin behind.

- **Precondition:** the proxy must already be running — unlike `claude-copilot`
  this does **not** auto-start it; it prints a `copilot-proxy start` hint and
  returns non-zero if the proxy isn't answering.
- **Prior-pin safe:** if `copilot-here` is already `on` here, the existing pin is
  left in place on exit (nothing is unpinned that you didn't ask for). If that
  pin has gone **stale** — it differs from what `copilot-here on` would write
  now, e.g. an unavailable Claude id after the account moved to the OpenAI
  fallback, or a pin written before the Fable key was added — it prints the
  drift and asks whether to refresh it in place (`copilot-here on`) or keep it.
  The answer defaults to **keep** (and keeps automatically on a non-interactive
  stdin). Drift is computed by diffing the live file against the exact env block
  `copilot-here on` would merge (`_copilot_env_json`, the single source of truth
  for both), so it is precisely "the keys `on` would change" — no hand-picked
  subset that can silently fall behind. Keys present in the file but not in that
  block are *not* drift: `on` merges and never removes (only `off` removes).
  `copilot-here status` prints the same drift report.
- The session itself is just `claude-copilot "$@"`, so specstory auto-save,
  `--no-specstory`, and `-c` (continue) all work the same way.
- On exit it reminds you the proxy is still up and how to `copilot-proxy stop`.

### `copilot-run <cmd...>` — generic env injector

The building block under `claude-copilot`: auto-starts the proxy and runs *any*
command with the proxy env. Useful for other Anthropic-compatible tools or a
custom specstory invocation:

The injected block comes from `_copilot_env_json_for_model --live` — the same
single source of truth `copilot-here on` writes and `_copilot_here_drift`
compares against, so the two can no longer disagree about which keys exist.
`--live` is the only difference: it resolves `ANTHROPIC_BASE_URL` with
`_copilot_client_base` (what this process should talk to now) instead of the
pinned base a settings file records.

```sh
copilot-run specstory run claude    # exactly what claude-copilot does
copilot-run claude --resume         # raw claude, no specstory
```

### `codex-copilot [--no-specstory] [codex args...]` — one-off Codex session

`codex-copilot` and `codex-copilot-once` are identical, zero-persistence
launchers. They start the gateway/shim when necessary and pass a custom
`copilot_api` Responses provider to Codex as CLI `-c` overrides. They never edit
`~/.codex/config.toml` or `.codex/config.toml`, so plain `codex` remains on its
normal provider.

Codex uses the shim on `localhost:4142` by default. Besides throttling and
measurement, that boundary normalizes blank
descriptions in Codex `mcp_list_tools` Responses items. GitHub Copilot rejects
those with `Invalid 'input[0].tools[0].description': empty string`, while MCP
servers and the native Codex path may omit them. The shim fills only those tool
definition fields and leaves prompts, schemas, and tool names unchanged.
Codex currently zstd-compresses these requests; the shim decodes only the
Responses body it must repair, forwards ordinary JSON, and removes the stale
`content-encoding` header.
Explicit `copilot-proxy shim off` bypasses this compatibility repair as well as
metrics, so it is only a break-glass diagnostic mode.

This is a separate picker from Claude Code's `copilot-model --auto`: that path
remains Claude-first, while only this Codex launcher is OpenAI-first.

- If the caller supplies `-m` / `--model`, that value wins. Otherwise the live
  raw gateway catalog is ranked as OpenAI/Codex first (`Sol > Terra > GPT-5.5 >
  GPT-5.4 > GPT-5.3 Codex > Luna > mini`), then Claude, Gemini, and any remaining
  chat model. Embedding and disabled models are excluded.
- The launcher supplies the selected model's live context and prompt limits and
  pins `model_catalog_json` to a versioned cache of `codex debug models
  --bundled`. Codex's global `~/.codex/models_cache.json` is not provider-scoped;
  a gateway refresh can otherwise replace first-party entries with the smaller
  adapter subset and trigger fallback-metadata warnings for bundled models such
  as `gpt-5.6-sol`. The cache lives under
  `$XDG_CACHE_HOME/copilot-proxy/codex-models/` (default
  `~/.cache/copilot-proxy/codex-models/`) and regenerates after a Codex version
  change. Explicit later `-c model_catalog_json=...` still wins.
- Claude/Gemini fallback uses the gateway's Responses Lite translation. Basic
  tools, compaction and multi-agent orchestration remain available, but Responses
  `tool_search` is not supported on that path. Auto selection therefore keeps
  native Responses OpenAI models ahead of Anthropic.
- The launcher enables gateway-backed remote compaction and excludes the
  `mcp__codex_apps__sites` namespace that depends on unavailable `tool_search`.
  Explicit later `-c` arguments can still override either per invocation.
- When SpecStory is installed, the launcher defaults to `specstory run codex`.
  It preserves the effective `codex_cmd` (project config > user config > bare
  `codex`) before appending provider/model/user arguments. Use
  `--no-specstory` for raw Codex.

Codex intentionally does not get a `copilot-here` equivalent. Official Codex
configuration allows project `.codex/config.toml` for trusted project settings,
but ignores `model_provider`, `model_providers`, provider auth and other
host-owned metadata at project scope. An explicit launcher is therefore the
project/session boundary without changing the user-wide default. See the
[configuration reference](https://developers.openai.com/codex/config-reference)
and [configuration basics](https://developers.openai.com/codex/config-basic).

#### Experimental direct provider (not used by the helper)

This skips localhost and is useful only when the account's GitHub credential can
authenticate directly to the matching Copilot endpoint:

```toml
[model_providers.copilot-enterprise]
name = "GitHub Copilot Enterprise"
base_url = "https://api.enterprise.githubcopilot.com"
wire_api = "responses"
http_headers = { "Copilot-Integration-Id" = "vscode-chat", "Editor-Version" = "vscode/1.99.0", "Editor-Plugin-Version" = "copilot-chat/0.0.1", "User-Agent" = "GithubCopilot/1.0" }

[model_providers.copilot-enterprise.auth]
command = "gh"
args = ["auth", "token", "--hostname", "github.com"]
timeout_ms = 5000
refresh_interval_ms = 300000
```

This is an example, not managed config. On the tested EMU/Enterprise account,
the raw `gh auth token` produced `421 Misdirected Request` at the enterprise API
and could not perform the Copilot token exchange (`403`). The token saved by
`copilot-proxy auth`, followed by the normal short-lived Copilot token exchange,
did work. Endpoint routing also comes from that exchange; hard-coding personal
versus enterprise hosts is not portable. For those reasons the supported helper
uses the already authenticated localhost gateway.

### `copilot-here [on|off|status]` — sticky per-project toggle

Layer 2: pin **this project** to the proxy via `./.claude/settings.local.json`
so plain `claude` (and `scode`/`svibe` panes, which just run
`specstory run claude`) uses the proxy until you turn it off. Requires `jq`.

- `on` — jq-merges the proxy `env` block into `settings.local.json` (creates it
  if missing) and makes sure git ignores the file (via `.git/info/exclude`;
  Claude Code only auto-gitignores files *it* creates). The committed
  `.claude/settings.json` (`plansDirectory` etc.) is never touched.
- `off` — removes exactly the env keys `on` added; other content you put in
  `settings.local.json` survives, and the file is deleted if it becomes empty.
- `status` — pinned? which base URL / model? Flags a **stale** pin (model/base
  drifted from the current defaults) with the exact diff and a `copilot-here on`
  refresh hint, and warns when the proxy isn't running.

### `copilot-model [<id>|-l|-c|--auto]`

Switches the pinned Copilot model. Requires `jq`. Write target — never the
committed `.claude/settings.json`:

- `copilot-here` is ON in the current project → edits
  `./.claude/settings.local.json`.
- otherwise → writes the global state file
  `~/.local/state/copilot-proxy/model`, which `claude-copilot`, `copilot-run`
  and the next `copilot-here on` pick up. (`$COPILOT_CLAUDE_MODEL` overrides
  the state file; final fallback is `gpt-5.6-sol[1m]`.)

Behavior:

- Fuzzy id: `copilot-model opus-4-8` resolves to `claude-opus-4-8`; dotted
  input is normalized (`opus-4.8` works too).
- `[1m]` is a Claude Code-only context hint. The helper now derives it from
  live `/v1/models` `max_context_window_tokens` metadata for every provider;
  manual explicit suffixes remain usable while offline.
- Validated against the live proxy `/v1/models` (a static discovery list remains
  available for manual picking while offline); typos and ambiguous prefixes are
  rejected. `--auto` never writes from that offline list.
- `--auto` / `-a` requires a live catalog. It prefers Claude
  (`Fable > Opus > Sonnet > Haiku`), then ranks OpenAI by capability:
  `Sol > Terra > GPT-5.5 > GPT-5.4 > GPT-5.3 Codex > Luna > mini`, then Gemini.
  Luna deliberately follows older flagships because it is the lightweight tier.
  The Sol/Terra/Luna intent follows OpenAI's
  [current model guidance](https://developers.openai.com/api/docs/guides/latest-model).
- No argument → `fzf` picker. `-c` prints the main model, source layer, and
  the complete role profile.
- A local pin writes the complete role set. For an OpenAI profile:
  Main/Fable/Opus = Sol, Sonnet = Terra, Haiku/background = Luna. Missing tiers
  fall back to the selected main, never an unserved hard-coded id.
- The global state file stays a backward-compatible one-line main id; wrappers
  derive the live role profile when they inject env. Changes take effect on the
  next `claude` launch and do **not** require restarting the proxy.

Recommended sequence:

```sh
copilot-proxy start
copilot-model --auto        # save the main model / refresh a live project pin
copilot-model -c            # inspect main + Fable/Opus/Sonnet/Haiku
copilot-here on             # sticky project, or use claude-copilot-once
```

`claude-copilot-once` temporarily writes the same full profile and restores the
previous local state. An existing `copilot-here` pin still outranks shell env;
refresh it with `copilot-model --auto` or `copilot-here on`.

The role variables are read at Claude Code startup, so
  **the change only takes effect on the next `claude` launch** (env is read at
  startup).

## Injected env (what both layers set)

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://localhost:4141",
    "ANTHROPIC_AUTH_TOKEN": "dummy",
    "ANTHROPIC_MODEL": "gpt-5.6-sol[1m]",
    "ANTHROPIC_DEFAULT_FABLE_MODEL": "gpt-5.6-sol[1m]",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "gpt-5.6-sol[1m]",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "gpt-5.6-terra[1m]",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "gpt-5.6-luna[1m]",
    "ANTHROPIC_SMALL_FAST_MODEL": "gpt-5.6-luna[1m]",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
  }
}
```

`ANTHROPIC_AUTH_TOKEN` is ignored by the proxy but must be set.
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` cuts background chatter (helps with
rate limits). Do **not** paste this into the committed `.claude/settings.json` —
use `copilot-here on` instead.

With `COPILOT_PROXY_QUIET=1` (opt-in, default off), both layers additionally
inject the fork-README quota savers:

| Extra env | Effect | UX cost |
|---|---|---|
| `CLAUDE_CODE_ATTRIBUTION_HEADER=0` | no billing/version info in system prompts → avoids prompt-cache invalidation | none noticeable |
| `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false` | no prompt-suggestion calls | no suggestions |
| `CLAUDE_CODE_ENABLE_AWAY_SUMMARY=0` | no away-summary calls | no away summaries |
| `DISABLE_NON_ESSENTIAL_MODEL_CALLS=1` | fewer background model calls | fewer niceties (haiku flavor text etc.) |

`copilot-here off` removes these keys regardless of the current
`COPILOT_PROXY_QUIET` value.

## Claude Code feature compatibility through the proxy

The important split is **local orchestration vs Anthropic cloud services**:

| Feature | Through Copilot + GPT | Notes |
|---|---|---|
| CLI, tools, hooks, skills, memory, plugins, MCP, checkpoints, sandboxing | Yes | These are local Claude Code features; model behavior can still differ because GPT receives translated Claude prompts/tool schemas. |
| Subagents and dynamic workflows | Yes | Do not set `CLAUDE_CODE_SUBAGENT_MODEL` globally here, so workflow scripts/frontmatter retain normal routing. [Workflow docs](https://code.claude.com/docs/en/workflows) |
| `ultracode` | Yes on `2.3.4` | Ultracode is xhigh effort plus dynamic workflows, not a separate model. The upgraded fork forwards the requested effort to GPT-5.6. |
| Thinking/reasoning | Translated | GPT uses Responses reasoning rather than Anthropic-native thinking semantics. Persisted reasoning support is proxy-dependent. |
| Web search, fast/auto mode, MCP tool search | Provider-dependent | The base-URL gateway and Copilot endpoint decide availability; non-first-party tool search may require an extra bridge/plugin. |
| Ultrareview, Remote Control, Chrome, cloud Code Review, routines, web/mobile/Slack sessions | No | These require Claude.ai authentication/cloud services; a local API gateway cannot supply the subscription identity. `ultrareview` is unrelated to `ultracode`. |

See Claude Code's [feature availability](https://code.claude.com/docs/en/feature-availability),
[model configuration](https://code.claude.com/docs/en/model-config),
[gateway protocol](https://code.claude.com/docs/en/llm-gateway-protocol), and
[Ultrareview](https://code.claude.com/docs/en/ultrareview) references.

## Gotchas (these cost real debugging time)

### `start` used to hang at "Resolving dependencies" behind a socks proxy

**Fixed** (the runner no longer resolves at launch), but worth understanding
because the failure mode is so misleading — and because it will bite any *other*
`bunx`-based tool on a proxied host.

`start` used to run `bunx <pkg> start`, and bunx re-resolves the package on every
launch. **bun hangs indefinitely resolving through a socks `ALL_PROXY`** — while
`curl` through that same proxy reaches the registry in under half a second. So
every obvious check passes and nothing points at the installer. All you get is:

```
copilot-proxy: did not come up in time — check 'copilot-proxy logs'.
$ copilot-proxy logs
nohup: ignoring input
Resolving dependencies
```

Two things turned one stall into a permanent wedge: the stalled `bun add` kept
bun's **global install-cache lock**, so the next `start` hung on the lock too; and
`start`'s timeout returned without killing what it spawned, so each retry left
another orphan (five, in the wild) and none ever bound the port.

The runner now installs the pinned package **once** into
`~/.local/share/copilot-api/pkg` and execs that binary, so a warm start does no
network at all. The install itself is bounded and killed on timeout, falls back to
a proxy-stripped retry, and finally uses npm's CA stack if Bun reports
`UNKNOWN_CERTIFICATE_VERIFICATION_ERROR`. TLS verification stays enabled; this
works around the observed Bun-vs-Node CA-store difference rather than disabling
certificate checks. Note the registry here is npmmirror (a domestic mirror,
set in `~/.bunfig.toml` for GFW speed) — routing it through the proxy buys nothing
and is exactly what breaks bun.

Full post-mortem, with the verbatim symptoms to grep:
[`pitfalls/copilot-proxy-start-hangs-at-resolving-dependencies.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/copilot-proxy-start-hangs-at-resolving-dependencies.md).

### The model list is fetched ONCE at startup — geo + flaky fetches poison the session

`copilot-api` fetches `/models` from GitHub when the process starts, caches the
result for its whole lifetime, and never re-fetches. Two common ways that one
request returns a **Claude-less** catalog:

1. **Egress geo-filter (GFW hosts, post-TUN)** — GitHub serves Claude ids when the
   request egresses overseas (e.g. Singapore VLESS), and omits them on direct/CN
   egress. **Node does not honor the macOS System Proxy**, so with only
   System Proxy / no TUN, `copilot-api` and OpenCode fetch the direct catalog
   (0 Claude) while `curl` through Clash still sees Claude. Fix: `copilot-proxy
   start` with `COPILOT_HTTP_PROXY=auto` (default) attaches `--proxy-env` +
   `HTTPS_PROXY` when `proxy-status` finds a local proxy. OpenCode needs the
   same env in its launch environment.
2. **Flaky node** — a degraded Clash node returns a truncated list; restart after
   the node is healthy.

The tell is in the startup banner:

```
ℹ Models refresh: 17 new     ← often the direct/CN catalog (no claude ids)
ℹ Models refresh: 25 new     ← healthy via overseas proxy (includes claude-*)
```

`copilot-proxy doctor` A/Bs **upstream direct** vs **upstream via proxy** vs the
**served** cache so it no longer mis-labels geo-filter as "org entitlement".
Full write-up:
[`pitfalls/copilot-api-caches-degraded-model-list-at-startup.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/copilot-api-caches-degraded-model-list-at-startup.md).

### `settings.local.json` env beats shell env (docs say otherwise)

Verified empirically (2026-07): current Claude Code lets the `env` block of
`./.claude/settings.local.json` **override inherited shell env vars** — the
opposite of what the official settings docs imply. Consequences:

- `claude-copilot` / `copilot-run` **cannot** redirect a project where
  `copilot-here on` is active (harmless when both point at the same proxy,
  silently wrong when they don't).
- Trialing another proxy/port via the wrapper requires `copilot-here off`
  first.

### OpenAI models go silent while they think — the shim keeps the socket warm

`copilot-api` does **not** open the SSE stream early: measured against `:4141`
with `gpt-5.6-sol`, the response *headers* arrive at 8.11s and the first body
chunk at 8.12s, so a reasoning model's whole think time is spent inside one
`fetch()` with zero bytes on the wire. Real Anthropic streams cover that with
periodic `ping` events; this gateway emits none. Add the shim's concurrency
queue on top (`COPILOT_SHIM_MAX`, default 4 — request 5 waits in total silence)
and any idle timer in the path is free to reap a perfectly healthy connection.
The agent then hangs with no error, and the only way out is Esc + `continue`.

So for client-requested streams the shim commits the `text/event-stream`
response itself after `COPILOT_SHIM_PING_AFTER_MS` of silence and emits SSE
*comment* frames (`: copilot-shim keepalive`, discarded by every spec-compliant
parser, so invisible to both the Anthropic and OpenAI SDKs) every
`COPILOT_SHIM_PING_MS` until real bytes arrive — covering queue time, think
time, and mid-stream reasoning gaps alike. `COPILOT_SHIM_STALL_MS` bounds each
attempt: a pre-header stall is aborted and retried transparently (nothing but
comment frames has reached the client), a mid-stream stall fails the response
with a real error instead of hanging.

| Env | Default | Meaning |
|---|---|---|
| `COPILOT_SHIM_PING_MS` | `15000` | keepalive interval; `0` disables |
| `COPILOT_SHIM_PING_AFTER_MS` | `10000` | silence tolerated before the SSE response is committed early |
| `COPILOT_SHIM_STALL_MS` | `240000` | silence that counts as a wedged upstream; `0` disables |

Fast non-2xx responses keep their real status and headers, so a
`400 model_not_supported` or `401 IDE token expired` still reports itself
properly. A fast HTTP 2xx for `stream:true` is accepted only when its media type
is SSE; the shim can still reject a protocol mismatch before committing headers.
Once the SSE response is committed, a late non-2xx can only be delivered as a
protocol-native terminal event, so don't shrink `COPILOT_SHIM_PING_AFTER_MS` to
zero.

`0 tok` in FleetView is **not** evidence of this bug — that counter is only
filled in when an agent finishes. Check `agent-<id>.jsonl` for growing
`assistant` entries first. Full diagnosis:
[`pitfalls/copilot-proxy-openai-model-silent-stall.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/copilot-proxy-openai-model-silent-stall.md).

### An old shim build wedges the port instead of being replaced

`_copilot_shim_alive` probes `/_shim/health` rather than merely connecting, so
an arbitrary process — or an **older build of the shim** — cannot pass as a
healthy metrics shim. An older build proxies that path upstream, so `:4141`
answers `404` and the probe correctly says "dead" while the OS still says
"occupied". Startup used to read "dead" as "port free" and spawn a process that
died instantly with `EADDRINUSE`, leaving every managed launcher failing closed
against a shim that was in fact running.

`_copilot_shim_start` now reads the port directly (`lsof -tiTCP -sTCP:LISTEN`):
a listener whose command line matches `copilot-throttle-shim.js` is ours and
gets reclaimed; anything else is named (PID + command) and the start refuses,
because killing an unrelated process on a well-known port is not its call. Use
`COPILOT_SHIM_PORT` to move out of the way instead. The fingerprint to look for
is a flood of `GET /_shim/health 404` in the **proxy's** log
([pitfall](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/copilot-proxy-shim-eaddrinuse-stale-build.md)).

### The fork has no rate limiter

The fork's `start` dropped `--rate-limit`/`--wait`. Its README's mitigation is
reducing Claude Code's chatter instead — that's exactly what
`COPILOT_PROXY_QUIET=1` injects (off by default here; we prioritize UX over
Copilot quota). If you really want request throttling, fall back to the
original: `COPILOT_API_PKG=copilot-api@0.7.0`.

### Context management is translated, not Anthropic-native

Older fork releases could forward Claude Code's `context_management` field to
an endpoint that rejected it with 400
([caozhiyuan#305](https://github.com/caozhiyuan/copilot-api/issues/305)). The
The pinned `2.3.4` GPT-5.6 path suppresses that incompatible field and relies on Responses
reasoning/context handling instead. This avoids the 400, but Anthropic's exact
context-editing and prompt-cache semantics are not reproduced; long-session
behavior remains a compatibility surface to watch.

### Do not use Claude Code's `/model` picker

It sends Anthropic's *official* dated ids (e.g. `claude-opus-4-8-YYYYMMDD`),
which the Copilot backend rejects:

```
API Error: 400 {"error":{"message":"The requested model is not supported.",
"code":"model_not_supported", ...}}
```

Pin the model with `copilot-model` instead — undated hyphenated ids
(`claude-opus-4-8`) work; only the picker's dated ids fail.

### Dotted ids cause the "[Opus 4] retired" warning and a >100% context HUD

Historic gotcha, fixed by the hyphenated defaults. With a **dotted** id
(`claude-opus-4.8`, the only shape the original proxy accepted), Claude Code
fails to match its built-in model table, so it:

- displays `[Opus 4]` and warns *"Claude Opus 4 was retired"* (falls back to
  the nearest known, retired name), and
- assumes a **200k** context window, while Copilot actually serves opus-5 /
  opus-4-8 / sonnet-5 with **1M** (`max_context_window_tokens: 1000000` in `/v1/models`)
  — so HUD/statusline context can read >100% and compaction triggers on the
  wrong budget.

The helpers use hyphenated ids and derive `[1m]` from each live model's context
metadata. That applies to GPT ids too (`gpt-5.6-sol[1m]`, for example). Claude
Code strips the suffix before sending; a raw API client must use the plain id.

### The token gotcha: `gho_` vs `ghu_`

There are two different GitHub tokens, and they are **not** interchangeable:

| Source | Prefix | `copilot_internal/v2/token` exchange |
|---|---|---|
| OpenCode's stored auth | `gho_` | **fails (404)** |
| `copilot-proxy auth` (device login) | `ghu_` | **works** |

## Available models and role discovery

Treat `GET /v1/models` as live truth: GitHub can change the catalog by account,
organization policy, rollout and egress. Current Claude Code recognizes Fable,
Opus, Sonnet and Haiku roles; `copilot-model --auto` maps only ids actually in
that catalog. Use `copilot-model -l` for raw served ids and `copilot-model -c`
for the effective role mapping. Do not copy a dated Anthropic id or manually
guess which models have 1M context.

## Useful commands

```sh
claude-copilot                       # one-off proxy session (specstory-wrapped)
claude-copilot-once                  # one-shot session via the settings.local.json pin (auto-reverted)
copilot-here status                  # is this project pinned to the proxy?
copilot-model -c                     # current model + which layer it came from
copilot-proxy status                 # up? which Claude models?
copilot-proxy whoami                 # validate token → account / plan / quota
copilot-proxy logs 60                # tail the proxy log
# usage dashboard (bundled locally by the fork):
#   http://localhost:4141/usage-viewer?endpoint=http://localhost:4141/usage
```

## See also

- [Copilot embeddings → semantic search](copilot-embeddings.md) — the same proxy's
  `/v1/embeddings` endpoint wired into `copilot-embed` + `semsearch` (local semantic search)
- [Raycast AI BYOK → the local Copilot proxy](raycast-ai-byok.md) — the same proxy
  behind Raycast's Quick AI / AI Chat / AI Commands (`copilot-raycast`), plus the
  zero-quota probe that tells usable model ids from ones `/v1/models` only claims
- [caozhiyuan/copilot-api](https://github.com/caozhiyuan/copilot-api) — the
  maintained fork this setup runs (npm `@jeffreycao/copilot-api`)
- [ericc-ch/copilot-api](https://github.com/ericc-ch/copilot-api) — the
  unmaintained original ([#233](https://github.com/ericc-ch/copilot-api/issues/233));
  still usable via `COPILOT_API_PKG=copilot-api@0.7.0`
- [Copilot agent gateway commands](../shells/aliases.md#copilot-agent-gateway)
- [Claude Code settings precedence](https://code.claude.com/docs/en/settings) — why
  `settings.local.json` / env vars are the right injection layers
- [Agent overlays](agent-overlays.md) — the chezmoi-managed `~/.claude/settings.json`
  this design deliberately stays out of
- OpenCode's native GitHub Copilot provider (no proxy needed for OpenCode itself)
