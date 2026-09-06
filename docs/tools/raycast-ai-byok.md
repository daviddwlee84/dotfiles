# Raycast AI BYOK → the local Copilot proxy

Raycast AI can run on **your own** model backend, but only one of its two
BYOK-looking entry points actually can: Settings → AI → Experiments →
**Custom Providers**. It reads `~/.config/raycast/ai/providers.yaml`, and
**requests are sent straight from your Mac**, which is why a `http://localhost`
`base_url` genuinely connects. Point it at the
[Copilot → Claude Code proxy](copilot-claude-proxy.md) (`copilot-api`) and every
model in your Copilot subscription becomes a first-class Quick AI / AI Chat /
AI Commands model. **This does not need Raycast Pro** (verified on a non-Pro
trial account).

- **Shell helper**: `~/.config/shell/45_copilot_raycast.sh` (`copilot-raycast`)
- **Generated file**: `~/.config/raycast/ai/providers.yaml` (the one Raycast
  watches; override with `COPILOT_RAYCAST_CONFIG`)
- **`base_url` source (SSOT)**: `_copilot_pinned_base` in `43_copilot_proxy.sh` —
  `:4142` when the throttle shim is on, otherwise `:4141`
- **Backups**: `~/.local/state/copilot-raycast/backups/` (last
  `COPILOT_RAYCAST_KEEP`=10 kept)
- Needs the proxy running: `generate` / `diff` / `probe` run `copilot-proxy start`
  when it isn't answering; `status` and `doctor` do **not** (they are read-only
  diagnostics and just report "not running").
- Needs `curl` + `jq`; `yq` for validation and for preserving other providers.

!!! warning "Same Copilot ToS risk as the proxy"
    Raycast's requests go through the same reverse-engineered proxy and the same
    Copilot subscription — see the
    [proxy doc's ToS warning](copilot-claude-proxy.md). This adds a new source of
    volume on top: Quick AI easily fires several calls within seconds, sharing one
    backend with Claude Code. That is exactly why `base_url` points at the
    throttle shim (below).

## Quick start

```sh
copilot-raycast doctor            # pre-flight: proxy, shim, Raycast, config, drift
copilot-raycast generate          # probe sweep → back up → validate → atomic install
copilot-raycast                   # status (default action, read-only)
copilot-raycast probe             # classification table for every chat model (zero quota)
copilot-raycast diff              # what generate would change
```

Within ~5s of the write, typing `copilot` in Raycast's model picker finds all of
them — the suffix comes from `COPILOT_RAYCAST_SUFFIX` (default `" (Copilot)"`),
which exists precisely so one keyword catches the whole set.

## Why the "Custom API Keys" box cannot be used

This is the first thing everyone clicks, and the wall everyone hits. Settings →
AI has two entry points that both look like "bring your own model", but only one
of them can reach your machine:

| Raycast entry point | Request routing | Endpoint field? | Local proxy |
|---|---|---|---|
| Settings → AI → **Custom API Keys** (BYOK) | "requests are processed through our servers" | **no** — a key field only | **unusable** |
| Settings → AI → Experiments → **Custom Providers** | "routed directly to the provider's servers" | **yes** — `base_url` | **usable** |

The BYOK box knows a **fixed** provider list — you hand it a **key**, not an
**address**. Raycast 1.104's own panel text is
`Anthropic, Google, OpenAI: Requests are routed via Raycast servers` /
`OpenRouter: Requests are routed directly to the provider's servers`, and the
manual's words are that requests are "processed through our servers" (to unify
APIs, do fallbacks, and manage the final prompt). From inside Raycast's
infrastructure, `http://localhost:4141` obviously cannot reach your Mac — and the
one direct-routed entry (OpenRouter) still offers no endpoint field, only a key.
**No value you type into that key field will ever make this path work.**

## The right entry: Experiments → Custom Providers

1. Raycast → Settings → AI → **Experiments** → turn on **Custom Providers**.
2. Back in Custom Providers → **Reveal Providers Config** — it opens
   `~/.config/raycast/ai/providers.yaml`. The first time you enable the
   experiment, Raycast also drops `providers.template.yaml` out of its own bundle
   into that directory (that file's existence is what `doctor` uses to tell
   whether the experiment was ever switched on; the toggle itself has no public
   API).
3. `copilot-raycast generate` writes the real `providers.yaml`; Raycast reloads
   within ~5s.

Raycast's description of this path, verbatim from the app bundle, is that
requests are "routed directly to the provider's servers" — i.e. from your Mac,
which is what makes `localhost` valid.

!!! note "Documented — but thinly, and in two different places"
    The per-user file *is* in the official manual, under
    [AI → Custom Providers (Bring Your Own Models)](https://manual.raycast.com/v1/ai#custom-providers-bring-your-own-models)
    — that exact URL is what the app's own **Learn more about custom providers**
    button opens. What it documents is only "Settings → AI → Custom Providers →
    Reveal Providers Config" plus a downloadable template; it enumerates no
    fields, so the schema table below is read off that template and off live
    behaviour, not off the page. The separate
    [teams/custom-provider page](https://manual.raycast.com/teams/custom-provider.md)
    is a **different feature**: an *organization-wide* `providers.yaml` that
    "overrides any local provider files set by members", tagged
    *Tier: Enterprise Exclusive*. Both use the same schema.

    Neither Enterprise nor Pro is required. The 9 models on this page run on a
    non-Pro trial account: `defaults read com.raycast.macos subscriptions_active`
    is `0`, `raycastAI_deviceInfo` decodes to `{"credits":48,"total_credits":50}`,
    and every loaded model carries `"requires_better_ai": false`.

## How it works

```
Raycast (Quick AI / AI Chat / AI Commands)
  │ reads ~/.config/raycast/ai/providers.yaml (at launch + ~5s after a change)
  │ POST <base_url>/chat/completions        ← straight from your Mac, no Raycast server
  ▼
copilot-throttle-shim (localhost:4142)      ← max 4 concurrent + transparent 403/429 retry
  │
  ▼
copilot-api (localhost:4141)                ← Claude Code uses this too
  │ Authorization: Bearer <copilot token>
  ▼
api.githubcopilot.com                       (your Copilot sub)
```

Raycast appends `/chat/completions` to `base_url` itself. copilot-api serves both
paths (`/chat/completions` and `/v1/chat/completions`), so `http://localhost:4142`
and `http://localhost:4142/v1` both route; the generator writes the latter.

Raycast makes **no network calls at config-load time** — it only parses the YAML.
So a model id that cannot possibly work looks perfectly healthy in the picker
until you send the first message and get a 400. That is why the probe in the next
section is not optional.

## Which port: `:4142` or `:4141`

The `base_url` written into `providers.yaml` follows `_copilot_pinned_base`: the
throttle shim (`:4142`) when it is enabled, otherwise the fork directly
(`:4141`). Same reasoning as `copilot-here`'s persisted pin — the file outlives
this shell, so it must **not** be gated on "is the shim alive right now".

The shim matters here more than anywhere else: Raycast and Claude Code now share
one Copilot backend, and Quick AI's usage pattern is **bursty** — a run of short
requests dropped into the middle of a long Claude Code session. The shim's
semaphore (4 concurrent) plus transparent retry on 403/429 is what stops that
burst from knocking Claude Code into `Please run /login`. If it is off:

```sh
copilot-proxy shim on             # then re-run copilot-raycast generate to rewrite base_url
```

Conversely, the **probe sweep deliberately hits `:4141` direct**: it is ~22
requests fired 6-wide, and routing them through the shim would just queue them
behind its 4 permits — pointlessly, because a request rejected at validation never
reaches the failure the retry logic protects against. (Observed: a hand-run probe
aimed at `:4142` during a busy Claude Code session sat in
`queued POST … (4 in-flight, 4 waiting)` past a 15s `--max-time`, while the same
POST to `:4141` answered instantly.) Set `COPILOT_RAYCAST_PROBE_BASE` if you want
the sweep throttled too.

## The zero-quota probe

This is the most valuable part of this page. **`/v1/models` cannot be used as the
filter** — only as a metadata source. Whether a model works is something you have
to ask.

The method: POST `{"model":"<ID>","messages":[]}` to `/chat/completions`. That
request is rejected during **request validation**, before it reaches
**inference**, so it moves no usage counter. The error body sorts every model into
exactly three classes:

| Response body | Verdict | Action |
|---|---|---|
| `messages must be non-empty` | **usable** — `/chat/completions` works | **emit** into `providers.yaml` |
| `model_not_supported` | catalogue lists it, this account is not entitled | drop |
| `unsupported_api_for_model` | model exists, but only on `/responses` | drop |

What the three responses actually look like (copilot-api wraps the upstream error
verbatim inside `error.message`, hence the double JSON):

```
$ curl -s -X POST http://localhost:4141/v1/chat/completions \
    -H 'content-type: application/json' -d '{"model":"claude-opus-5","messages":[]}'
{"error":{"message":"{\"error\":{\"message\":\"messages must be non-empty\",\"code\":\"\"}}\n","type":"error"}}

$ ... -d '{"model":"claude-sonnet-4-5","messages":[]}'
{"error":{"message":"{\"error\":{\"message\":\"The requested model is not supported.\",\"code\":\"model_not_supported\",\"param\":\"model\",\"type\":\"invalid_request_error\"}}\n","type":"error"}}

$ ... -d '{"model":"gpt-5.5","messages":[]}'
{"error":{"message":"{\"error\":{\"message\":\"model \\\"gpt-5.5\\\" is not accessible via the /chat/completions endpoint\",\"code\":\"unsupported_api_for_model\"}}\n","type":"error"}}
```

!!! danger "The static `/v1/models` metadata lies in BOTH directions"
    **It drops models that work**: `gemini-2.5-pro` and `gemini-3-flash-preview`
    have `supported_endpoints: null` (empty), so a metadata filter deletes them
    outright — and **both are usable**.

    **It keeps models that don't**: `claude-sonnet-4-5` (plus
    `claude-opus-4-6/4-7/4-8`, `claude-sonnet-4-6`, `claude-haiku-4-5`) has
    `supported_endpoints` containing `"/chat/completions"`,
    `model_picker_enabled: true` and `policy.state: "enabled"` — it looks
    flawless, and **every one of them returns `model_not_supported`**.

    ```sh
    curl -s http://localhost:4141/v1/models \
      | jq -r '.data[] | select(.id=="claude-sonnet-4-5" or .id=="gemini-2.5-pro")
               | {id, model_picker_enabled, policy: .policy.state, endpoints: .supported_endpoints}'
    #   claude-sonnet-4-5  true  "enabled"  ["/chat/completions","/v1/messages"]   → actually unusable
    #   gemini-2.5-pro     true  "enabled"  null                                   → actually usable
    ```

    **No field in `/v1/models` predicts this.** The probe is the only truth.

Only two static pre-filters run before the sweep: `capabilities.type == "chat"`
(drops the three embedding models) and grepping out the `[1m]` aliases (a
Claude-Code-only 1M-context sugar that a raw API client gets rejected for).
Everything else is decided by the probe.

**Temperature cannot be probed the same way.** The `messages` check fires
*before* parameter validation, so `{"messages":[],"temperature":0.7}` still
answers `messages must be non-empty`. Temperature is therefore a heuristic rather
than a measurement: `false` for the OpenAI reasoning family (`gpt-*`, `*codex*`,
`o1`/`o3`/`o4*`) and Microsoft `mai-*`, `true` for the rest (Anthropic and Google
both accept it here). Override wholesale with `COPILOT_RAYCAST_TEMP=on|off`.

## `providers.yaml` schema

The generated file (excerpt; the full one has 9 models):

```yaml
providers:
  - id: copilot
    name: "GitHub Copilot"
    base_url: http://localhost:4142/v1
    models:
      # --- Anthropic ---
      - id: "claude-opus-5"
        name: "Claude Opus 5 (Copilot)"
        context: 1000000
        abilities:
          temperature: { supported: true }
          vision: { supported: true }
          system_message: { supported: true }
          tools: { supported: true }
          reasoning_effort: { supported: true }
```

| Field | Required | Meaning |
|---|---|---|
| `providers[].id` | yes | unique provider id; `copilot-raycast` owns only `COPILOT_RAYCAST_ID` (default `copilot`) and preserves every other one verbatim |
| `providers[].name` | yes | provider name shown in Raycast |
| `providers[].base_url` | yes | Raycast appends `/chat/completions` to it |
| `providers[].api_keys` | no | `alias → key` map. **Not needed for a local proxy** (omit it when the endpoint needs no auth) |
| `providers[].additional_parameters` | no | extra params merged into the `/chat/completions` body |
| `models[].id` | yes | the provider's own model id, **must be a string** |
| `models[].name` | yes | display name in the picker, **must be a string** |
| `models[].description` | no | descriptive text |
| `models[].provider` | no | selects an `api_keys` alias |
| `models[].context` | yes | context window, **must be a bare integer** — quoted or missing takes down the whole file |
| `models[].abilities.*` | no | `temperature` / `vision` / `system_message` / `tools` / `reasoning_effort`, each `{ supported: bool }` |

Metadata mapping: `capabilities.limits.max_context_window_tokens` → `context`,
`capabilities.supports.vision` → `abilities.vision`, `.tool_calls` →
`abilities.tools`, `.reasoning_effort` (**an array** — non-empty counts as
supported) → `abilities.reasoning_effort`. `system_message` has no counterpart in
`/v1/models`, and every Copilot chat model accepts one, so it is a constant
`true`.

Models preserve the same vendor grouping as `_copilot_pick_best_model`: Claude,
Codex, GPT, **grok**, then Gemini, with Fable > Opus > Sonnet > Haiku inside
Claude and newest-version-first tie breaks. The explicit vendor bands keep the
file easy to scan; an unknown vendor falls into a catalog-derived
`model_picker_category` sub-band (`powerful > versatile > lightweight`). All
unknown vendors deliberately remain below the known Gemini band, preserving the
stable vendor grouping. Grok sits below GPT and above Gemini. Inside the
GPT/o-series and grok bands, the same catalog tier keeps a newer lightweight id
below an older powerful one. Grok stays `temperature: supported` deliberately — unlike the reasoning-only GPT/Codex
endpoints, grok accepts temperature — and is grouped by `.vendor` with comment headings. Those
headings use the raw vendor string from `/v1/models`, so `gpt-5.4` lands under
`# --- OpenAI ---` while `gpt-5-mini` lands under `# --- Azure OpenAI ---` —
that is genuinely what the catalogue says; purely cosmetic.

## Shell helpers

### `copilot-raycast [status]` — default action, read-only

```
copilot-raycast   config /Users/david/.config/raycast/ai/providers.yaml

  file             present, 9 model(s) under provider 'copilot'
  raycast          9 model(s) live in the picker
  base_url         http://localhost:4142/v1
  shim             on (:4142)
  live usable      9 model(s) pass the probe
  drift            none — the file matches the live catalogue
```

`file` is how many models are in the file; `raycast` is how many Raycast
**actually loaded** — a mismatch means the config was rejected (see Gotchas).
`drift` compares the file's ids against a live probe with `comm(1)` and lists both
`stale in file:` and `missing      :` differences.

### `copilot-raycast generate [-n|--dry-run] [-a|--all]`

Probe every chat model → render → temp file → `yq` validate → timestamped
backup → one `mv` into place.

```
copilot-raycast: backup /Users/david/.local/state/copilot-raycast/backups/providers-20260726-173630.yaml
copilot-raycast: wrote 9 model(s) → /Users/david/.config/raycast/ai/providers.yaml
  base_url http://localhost:4142/v1   (Raycast reloads within ~5s)
  copilot-raycast status   # confirm Raycast actually accepted it
```

- `-n` / `--dry-run` — render to stdout, write nothing.
- `-a` / `--all` — also emit the probe-rejected models, **fully commented out**,
  so the next entitlement change from GitHub is a one-line diff:

  ```yaml
      # - id: "claude-opus-4-8"   # not_supported
      #   name: "Claude Opus 4.8 (Copilot)"
      #   context: 1000000
  ```

- **Other providers survive verbatim**: every entry whose `id !=
  COPILOT_RAYCAST_ID` is pulled out with `yq`, re-indented, and appended under
  `# --- other providers, preserved from the previous file ---`, comments
  included. If the file already exists **and `yq` is missing**, `generate`
  **refuses** rather than overwrite blindly — there is no cheap POSIX way to tell
  a provider entry from a model entry in arbitrary YAML.
- It also refuses to write when no model passes the probe (that is an
  entitlement/auth fault, not a config one — it points you at
  `copilot-proxy doctor`).

### `copilot-raycast diff`

Unified diff of the current file against what `generate` would write. The
`# Probed:` timestamp is normalised to `<run timestamp>` on **both** sides —
otherwise every run would differ by construction and the command would be
useless:

```
copilot-raycast: no changes (/Users/david/.config/raycast/ai/providers.yaml is current)
```

When the file does not exist yet it prints "generate would create it" plus the
full contents instead.

### `copilot-raycast probe [MODEL]`

No argument = the classification table for every model; one model id = a single
verdict string (`ok` / `not_supported` / `responses_only` / `no_response` /
`unknown`), which is the script-friendly form.

```
copilot-raycast probe   base http://localhost:4141   22 chat model(s)

  OK             claude-opus-5                1000000 vision tools reasoning
  NOT_SUPPORTED  claude-opus-4-8              1000000 vision tools reasoning
  NOT_SUPPORTED  claude-sonnet-4-5             200000 vision tools
  RESPONSES_ONLY gpt-5.5                      1050000 vision tools reasoning
  OK             gpt-5.4                      1050000 vision tools reasoning
  OK             gemini-2.5-pro                128000 vision tools
  RESPONSES_ONLY mai-code-1-flash-picker       256000 tools reasoning

  OK              usable via /chat/completions — emitted into providers.yaml
  NOT_SUPPORTED   catalogue lists it, the account is not entitled to it
  RESPONSES_ONLY  exists, but only on /responses — Raycast cannot reach it
```

(Excerpt from the 22 rows. Measured 2026-07: 9 OK, 6 NOT_SUPPORTED, 7
RESPONSES_ONLY.) The sweep runs `COPILOT_RAYCAST_JOBS` wide (default 6) and gives
each model one free retry to absorb a transient 429/502 — without it a single
blip would silently delete a good model from the file.

### `copilot-raycast doctor` (alias: `test`)

```
copilot-raycast doctor   base http://localhost:4142/v1   config /Users/david/.config/raycast/ai/providers.yaml

Prerequisites
  ✓ curl             /usr/bin/curl
  ✓ jq               /usr/local/bin/jq
  ✓ yq               /usr/local/bin/yq

Proxy
  ✓ listening        http://localhost:4141
  ✓ throttle shim    http://localhost:4142 — base_url points here

Raycast
  ✓ installed        /Applications/Raycast.app  v1.104.23
  ✓ custom providers experiment has been enabled (template installed)
  ✓ loaded models    9 live in the picker for provider 'copilot'

Config
  ✓ present          /Users/david/.config/raycast/ai/providers.yaml
  ✓ parse            valid (providers present, every model has id/name/int context)

Models
  ✓ probe            9 of 22 chat models usable
  ✓ drift            the 9 model(s) in the file match the live catalogue
  · cache            copilot-api caches /models at start — 'copilot-proxy restart' if stale

all checks passed (0 warning(s))
```

Any ✗ exits non-zero. The `custom providers` line is a heuristic: it detects
whether `providers.template.yaml` exists (Raycast drops it out of its bundle the
first time the experiment is enabled), which is why the wording is "experiment
**has been** enabled" rather than "is currently on" — that toggle has no public
API.

### `copilot-raycast edit`

Open the config in `$EDITOR` and **re-validate on save**. A broken result is
reported explicitly with a `generate`-or-restore-from-backup hint, instead of
leaving you staring at an empty model picker in Raycast. Exits 1 when the file
does not exist.

## Config

| Env var | Default | Meaning |
|---|---|---|
| `COPILOT_RAYCAST_CONFIG` | `$XDG_CONFIG_HOME/raycast/ai/providers.yaml` | the file Raycast watches |
| `COPILOT_RAYCAST_ID` | `copilot` | the `providers[].id` this tool owns; every **other** id in the file is preserved |
| `COPILOT_RAYCAST_LABEL` | `GitHub Copilot` | `providers[].name` |
| `COPILOT_RAYCAST_SUFFIX` | `" (Copilot)"` | appended to each model's display name, so typing `copilot` in the picker finds them all |
| `COPILOT_RAYCAST_TEMP` | `auto` | `auto`\|`on`\|`off` — overrides the temperature heuristic (it cannot be probed) |
| `COPILOT_RAYCAST_JOBS` | `6` | concurrent probes in the sweep |
| `COPILOT_RAYCAST_PROBE_BASE` | `$(_copilot_base)` (`:4141`) | where the probe POSTs; deliberately **not** the shim |
| `COPILOT_RAYCAST_KEEP` | `10` | timestamped backups to retain |

Set these in `~/.shellrc.adhoc` (or `~/.config/{zsh/secrets.zsh,bash/secrets.sh}`).

## Gotchas (these cost real debugging time)

### Raycast validates `providers.yaml` all-or-nothing and reports NOTHING

One model missing `context`, or written as `context: "128000"` (a type mismatch
on the Swift side), makes **every** custom provider disappear from the picker —
including providers that have nothing to do with this file. No error message, no
red badge, no log line.

That is why `generate` always renders to a temp file and validates it with `yq`
(at least one provider, provider ids unique, every model carrying `!!str id`,
`!!str name`, `!!int context`) before the `mv`. Hand edits should always go
through `copilot-raycast edit` (which re-validates for you), or be followed
immediately by `copilot-raycast status` to check the `raycast` line's count.

### `model_picker_enabled: true` does not mean the model works

`claude-sonnet-4-5` reports `model_picker_enabled: true`,
`policy.state: "enabled"` and a `supported_endpoints` that explicitly lists
`"/chat/completions"` — and returns `model_not_supported` when you send to it.
Conversely `gemini-2.5-pro` has `supported_endpoints: null` and works perfectly.
Filtering on metadata gets it wrong in both directions at once. See
[the zero-quota probe](#the-zero-quota-probe) above.

### A model missing from the picker is usually a rejected file, not a missing model

Ask what Raycast actually loaded before guessing.
`raycastAI_modelRouterModelInfo` is a base64 JSON blob keyed by provider id,
containing the models Raycast **accepted**:

```sh
plutil -extract raycastAI_modelRouterModelInfo raw -o - \
  ~/Library/Preferences/com.raycast.macos.plist | base64 -d | jq -r '.copilot[].model'
```

Empty → the file was rejected (or Raycast never read it). Present but short →
that is a genuinely missing model. `copilot-raycast status` and `doctor` read
exactly this, which turns a silent rejection into a visible line.

### `model_not_supported` when you actually send a message

Raycast makes no network calls at config-load time, so a dead id looks completely
normal in the picker until the first message. It means the file is stale — GitHub
withdrew an entitlement. Fix:

```sh
copilot-raycast diff              # see what changed
copilot-raycast generate          # re-probe and rewrite
```

### The proxy caches `/models` ONCE at startup — a stale catalogue survives regenerate

`copilot-api` fetches the catalogue **once at process start** and caches it for
its whole lifetime, so "just regenerate" hands you the same broken list. The last
line of `doctor` exists to remind you of this. Restart the proxy first:

```sh
copilot-proxy restart && copilot-raycast generate
```

A geo-filtered egress produces the identical symptom (the whole Claude family
vanishes) — full write-up in
[the proxy doc's model-list section](copilot-claude-proxy.md#the-model-list-is-fetched-once-at-startup--geo--flaky-fetches-poison-the-session)
and
[`pitfalls/copilot-api-caches-degraded-model-list-at-startup.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/copilot-api-caches-degraded-model-list-at-startup.md).

### Raycast's file watcher coalesces rapid writes and can skip a reload

So the install path is deliberately a **single write** (`mv`), and the backup goes
to a *different* directory (`~/.local/state/copilot-raycast/backups/`) rather than
leaving a `.bak` next to the config — that would be a second touch. If you script
this file yourself, use the same shape: render to a temp file, then one `mv`.

### The built-in **Web** and **DALL·E** extensions can never work with a custom provider

Locally-installed AI Extensions are fine — `Location` gets called, runs on your Mac
and returns. But the built-in **Web** extension always shows a warning triangle and
*"Extension is not supported for this model"*, and no amount of YAML fixes it.

That is architectural. Raycast's binary names exactly two extensions
`remote_package_*` — `remote_package_web` and `remote_package_dalle` — while every
other one is `builtin_package_*` (`browser`, `clipboard`, `github`, `jira`, `linear`,
`media`, `reminders`, `zoom`, …). The remote pair executes on Raycast's own
infrastructure, and a custom-provider request never goes there: Raycast's UI says
these requests are *"routed directly to the provider's servers"*. The very property
that makes `localhost` reachable is what puts the hosted tools out of reach.

**No ability key turns it on.** `web_search: { supported: true }` was A/B-tested on
one model and silently ignored. The keys the config parser actually reads sit in one
contiguous string table under `RaycastApp/AIProvider+Additions.swift`:

```
models  api_keys  base_url  context  abilities → { tools, vision, system_message }
```

`temperature` and `reasoning_effort` are also accepted (both appear in Raycast's own
Enterprise `providers.yaml` template). `web_search`, `image_generation` and
`structured_outputs` belong to *other* structs — Raycast's hosted-model catalogue and
its OpenRouter client — not to `providers.yaml`. `copilot-raycast` therefore never
emits them.

Workaround: install a search extension that runs locally with its own API key (Exa
Search, Tavily, …) and `@`-tag it. Note that an extension only reaches the model if
it is in that chat's **AI Extensions** list or `@`-tagged — enabling it under
Settings → Extensions is not enough, which is why an enabled `Ask Weather` can still
draw *"I don't have a weather tool available"*.

## Alternative: Ollama Host + an Ollama-protocol shim

Raycast Settings → AI also has an **Ollama Host** field, and community projects
(e.g.
[raycast-ai-openrouter-proxy](https://github.com/miikkaylisiurunen/raycast-ai-openrouter-proxy))
work by **impersonating an Ollama server** and translating to any OpenAI-compatible
backend.

That route is **not recommended here**: it needs another service running (its only
documented run path is `docker compose up`), another protocol translation layer
(Ollama ↔ OpenAI), and its own `models.json` that requires a restart after edits;
it self-describes as *Work In Progress* and ships no built-in auth. Custom Providers speak the native OpenAI schema, need zero extra
processes, talk directly to the proxy we already run — and `copilot-raycast` keeps
that YAML in sync with the live catalogue automatically. There is no reason to
insert another layer.

## Verify

```sh
copilot-raycast doctor                       # → all checks passed (0 warning(s))
copilot-raycast diff                         # → no changes (… is current)
yq '.providers[].models[].id' ~/.config/raycast/ai/providers.yaml   # → 9 ids
plutil -extract raycastAI_modelRouterModelInfo raw -o - \
  ~/Library/Preferences/com.raycast.macos.plist | base64 -d | jq -r '.copilot[].model'
#   → the SAME 9 ids = Raycast really accepted it (not just "the file got written")
```

## See also

- [Copilot → Claude Code proxy](copilot-claude-proxy.md) — the proxy this points
  at (auth, model ids, the throttle shim, ToS, gotchas)
- [Copilot embeddings → semantic search](copilot-embeddings.md) — the same proxy's
  `/v1/embeddings` endpoint
- [`copilot-raycast` in the alias reference](../shells/aliases.md#copilot-agent-gateway)
  — the one-line summary and its source file
- [Raycast manual — Bring Your Own Keys](https://manual.raycast.com/ai/bring-your-own-keys)
  — where "processed through our servers" comes from, i.e. the trap in the first
  section
- [Raycast manual — AI → Custom Providers (Bring Your Own Models)](https://manual.raycast.com/v1/ai#custom-providers-bring-your-own-models)
  — the per-user flow, and the URL behind the app's own "Learn more about custom
  providers" button
- [Raycast manual — Custom provider (Teams)](https://manual.raycast.com/teams/custom-provider.md)
  — the *Enterprise Exclusive* org-wide file that overrides members' local ones;
  same schema
- [Ernest0-Production/raycast-ai-custom-providers](https://github.com/Ernest0-Production/raycast-ai-custom-providers)
  — a Raycast extension for editing `providers.yaml` in a GUI (it backs up first);
  [aadishv.dev's Raycast + Copilot notes](https://www.aadishv.dev/raycast-copilot/)
  are the manual version of this same path
