# copilot-proxy 2.5.2 upgrade and request stability

**Status**: shipped — implementation and bounded Ubuntu trial complete; production cutover, natural-usage observation and native Windows validation remain
**Effort**: L
**Owner**: Unix implementation; Windows mirrors the shared behavior with native package/process handling
**Decision date**: 2026-09-08
**Related**: `TODO.md`; `dot_config/shell/43_copilot_proxy.sh`; `dot_config/shell/copilot-throttle-shim.js`; user-supplied compact incident notes identified below

## Implementation results — 2026-09-08

Implemented the exact 2.5.2 pin, verified-artifact staging, transport-field/package
rollback, coordinated retries, earlier Astra compact budgets, shared lifecycle
and durable admission recovery, terminal-aware metrics, and native Windows parity.
The live Mac proxy was not upgraded or restarted. Ubuntu's default package stays
2.3.4; its original config and credential bytes were verified unchanged after testing.

The isolated trial ran on `ssh david_ubuntu`, Node 24.18.0 / Bun 1.3.14, with a
separately installed Codex 0.153.4, Astra at low reasoning effort, and shared shim SHA-256
`d0912c4fef76d74896e161b03cd64d28a0b1f6597cf7490d5613840efe014749`.
Both package archives had all 35 packaged files compared against installed bytes.
The actual 2.5.2 config migration also passed with custom 123456/234567ms deadlines,
legacy-key removal, and preservation of unrelated config and an existing fixture
admin key, entirely under a separate `COPILOT_API_HOME`.

| Trial phase | Logical / physical requests | Terminal-confirmed completed | Functional result |
|---|---:|---:|---|
| 2.3.4 baseline | 3 / 3 | 3 | Coding tools blocked by Ubuntu bubblewrap initialization |
| 2.5.2, same initial client policy | 3 / 3 | 3 | Same bubblewrap limitation; not a backend regression |
| 2.5.2 candidate verification | 6 / 6 | 6 | Real file edit, all four Python tests, a compaction item, and retained synthetic identifier after continuation |

Total: **12 logical requests, 12 dispatches, zero replay, zero backend error**.
After each phase `active=draining=unknown=0`; all recorded trial processes stopped
and ports 4241–4244 were confirmed closed. This small test does not establish an
improved production error rate or successful 800k-token compaction.

The initial client used `workspace-write`; tools failed with
`bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted` (an additional
non-inference sandbox probe also found UID mapping permission failure). Candidate
verification used the existing `codex-copilot` default `danger-full-access` as a
per-process override, after disclosure, within the remaining original budget.
No system sandbox setting changed. In that mode the trial directory is a workflow
boundary, not an OS-enforced filesystem sandbox, so the two coding phases are not
a controlled comparison of execution policies.

Reproducible tooling: `scripts/copilot_proxy/dogfood.py` (`prepare`, `run`, and
one-shot `verify-candidate` using only unspent original budget). It validates the
host before accessing credentials, verifies listener ownership, closes admission
before final counts, reserves budgets with exclusive creation/fsync, and stops
owned process groups even if their leader already exited. Private artifacts are
retained on Ubuntu at `/tmp/copilot-dogfood-20260908.FinAl7`; they include credential
copies and must not be committed or shared as a directory. The budget is exhausted.

Offline verification: full Unix Bats **150/150 passed**; all seven harness edge-case
tests passed separately; final Windows Copilot Pester **234 passed / one native-only skip**,
plus final shared integration **8/8** and focused final-change checks. Windows
PSScriptAnalyzer and bilingual docs build passed. Unix strict docs build fails
with the same nav/i18n + llmstxt warnings reproduced on isolated unchanged HEAD;
the referenced document exists, and this change did not delete it.

Testing incident: a Bun child briefly used live defaults, recording a synthetic
`after-recovery` HTTP400 and adding metrics columns on the Mac. An existing Windows
keepalive fixture also lacked metrics isolation and may have appended synthetic
rows before that gap was fixed. Service PIDs and credentials were not changed.
Both fixture routes now require isolation before import; details and the limits
of the verification are in the [incident note](../pitfalls/copilot-offline-fixture-child-uses-live-environment.md).

## Original outcome and scope

Upgrade the managed backend from `@jeffreycao/copilot-api@2.3.4` to the reviewed
exact `2.5.2`, retaining a smaller, observable shim. Optimize for fewer visible
failures and shorter retry loops, with explicit recovery when upstream execution
cannot be tracked. The user subsequently authorized implementation and isolated
Ubuntu dogfood; production cutover is separate from the completed trial above.

The release includes package verification/rollback, request lifecycle ownership,
bounded retries, terminal-event metrics, earlier Astra compaction, and auth
diagnostics. Supervisor migration, global provider switching, automatic login,
periodic inference probes, and changes to remote network infrastructure are
separate work. Preserve the existing model, Fast routing, and native platform
authentication contracts except where the following plan explicitly changes them.

## Evidence already collected

- On 2026-09-08 this Mac's installed package and both repo defaults were `2.3.4`.
  GitHub and npm identified `2.5.2` as latest; release commit is
  `6c1117c974d9b7261fc4ab4420bfbe23ae25d4d2`, published 2026-09-07.
- npm advertised this `2.5.2` archive integrity; verify again against the artifact
  used for staging rather than trusting this note as the only provenance:
  `sha512-bMVpuniekbKKq0LMtmZZJKjDVpaOODAHs19akwkP/hyGfgcx+YK0X22jfB46lQb0p9EoywDrJMyTcAfLr18jEQ==`.
- In the 24-hour window ending 2026-09-08 06:55:53 UTC, normal Astra `/responses`
  metrics recorded 15 final HTTP 408s, 19 final HTTP 500s, and 44 requests marked
  successful after retry (57 replay attempts). These are historical observations,
  not a clean performance baseline: terminal failures may be counted as success
  by the current implementation, and compact is not separately classified.
- Backend logs contain `read ECONNRESET` under `fetch failed`, and the previous
  log generation contains refresh exchange `Bad credentials` followed by
  `IDE token expired`. Neither identifies abuse detection as the cause.
- The supplied Codex pitfall records a successful `compacted` event at
  2026-09-08 03:09:01.733 UTC. Astra compact works on at least some requests.
  Adjacent 408/499 records cannot be assigned to that compact by timing alone.
- The compact notes were read from the separate live clone:
  `~/.local/share/chezmoi/pitfalls/codex-astra-remote-compact-408-then-succeeds.md`
  and `~/.local/share/chezmoi/pitfalls/claude-astra-auto-compact-retries-at-83-percent.md`.
  They were not present in this umbrella's Unix checkout when planning. Reconcile
  their source commits during implementation; preserve the user's live-clone work.
- Current deadlines: shim 240s; backend Responses headers/inactivity 300s;
  Codex SSE idle 300s. The latter is not an established total request deadline.
  Astra live limits were context 1,000,000, prompt 872,000, output 128,000 tokens.
- v2.5.2 stops propagating post-dispatch client cancellation into upstream fetch:
  its HTTP lifecycle tests explicitly expect continued processing/draining.
  The shim currently frees its permit on cancellation and retries its own
  pre-header timeout. Together these can admit replacement work while the old
  backend request is still executing. Increasing one timeout does not fix this.
- The Unix shim has Responses terminal-presence detection absent from the Windows
  copy. It also treats `response.failed` and `response.incomplete` as terminal
  presence without classifying failure, allowing HTTP 200 to inflate success.
- Existing updates differ: Unix auto-restarts an already running backend;
  Windows swaps package/selection and requires an explicit restart. Neither
  implements a complete configuration/schema rollback. A changed built-in pin
  does not override an existing persisted package selection.

The exact body-read error remains:

```text
Timed out reading request body. Try again, or use a smaller request size.
user_request_timeout
```

No reviewed release change establishes a direct fix for that remote body-read
deadline or for rejected GitHub credentials. Transport improvements are a reason
to evaluate the upgrade, not evidence that these two problems are resolved.

## Options and decision

| Option | Benefit | Trade-off / decision |
|---|---|---|
| Keep 2.3.4 and adjust timeouts | Small change | Misses maintenance fixes and does not repair remote 408; rollback baseline only |
| Upgrade to 2.5.2 with the current shim | Fast version bump | Cancellation/retry ownership conflicts; rejected |
| Remove the shim | Fewer layers | Loses useful admission, Fast routing, metrics and keepalive; diagnostic direct mode only |
| Upgrade to 2.5.2 with coordinated shim behavior | Maintains useful features and makes recovery measurable | Selected; offline lifecycle gate must pass before live cutover |

Do not maintain an upstream fork just to restore old cancellation behavior in
this batch. Reconsider the target version if the lifecycle gate cannot be met.

## Implementation sequence

### 1. Correct measurement and establish a baseline

- Add backward-compatible metric fields for `terminal_event`, terminal error
  category, request kind and classification source, received bytes, normalized
  shim-to-backend bytes, attempt outcome, timeout owner, and drain outcome.
  Record the actual launched backend/shim versions for each measurement window.
- For Responses SSE, only `response.completed` qualifies as successful completion.
  Classify `response.failed`, `response.incomplete`, missing terminal, client
  cancellation, and transport errors separately; do not invent completion events.
  Parse SSE across chunk boundaries/CRLF without retaining model output.
- Classify non-streaming Responses JSON by its protocol status/error instead;
  validate a legitimate compact-result object by that endpoint's schema. Such
  responses do not require an SSE terminal event. Unknown shapes stay unverified.
- Use explicit `compaction_trigger`/known protocol metadata when available;
  mark heuristic classifications as such and unrecognized cases `unknown`.
  The byte count at the shim is not the final backend-to-Copilot upload size.
- Keep one stable logical trace across replays and separate local attempt IDs.
  Account for actual retry/drain usage without double-counting joined metrics.
  Never persist prompts, credentials, full bodies, or raw provider error bodies.
- Capture a comparable baseline with the new classifier while still on 2.3.4.
  For a backend-only comparison also use the same new shim/client retry,
  timeout and drain policy on both versions, with model, effort, egress and
  concurrency unchanged. Otherwise label results as a bundled stability change.

### 2. Give backend execution and shim admission explicit owners

- Backend owns normal upstream headers/inactivity deadlines. Initial proposal:
  retain 300s there; use 330s for the shim's outer fallback, with positive-value
  validation and diagnosis of runtime overrides that reverse that ordering.
  The margin is a candidate to validate with fixtures, not a remote-408 fix.
- A queued request canceled before dispatch is removed immediately. Cancellation
  during retry backoff suppresses the next attempt and releases its permit.
- After dispatch, downstream cancellation switches that request to background
  draining: stop writing to the client, continue reading the backend, retain its
  admission permit, and never retry that canceled request. Release exactly once
  on backend completion/error. Expose `active`, `draining` and `unknown` counts.
- A local watchdog or broken shim-to-backend connection leaves execution
  uncertain. Do not automatically replay it or silently report the backend idle.
  Quarantine unresolved admission and surface an actionable recovery state;
  only a confirmed completion/termination or controlled backend recovery clears
  it. A finite alarm must expose stalled recovery rather than hide a slot leak.
- If all admission is quarantined as unknown, fail new requests promptly with an
  actionable recovery error; never leave them in an endless queue with keepalive.
  Controlled recovery must settle or explicitly account for remaining tracked
  streams before resetting capacity. Test this degraded state and recovery.
- Keep finite headers/inactivity watchdogs during draining. They are not absolute
  generation deadlines: ongoing chunks can keep a backend operation alive.
  Therefore a timer alone cannot prove unknown remote work has stopped.
- Preserve downstream keepalive for eligible SSE, JSON passthrough for
  non-streaming requests, Fast routing, and request normalization.

### 3. Bound automatic retry and distinguish rejection from transport failure

- Default to at most **two dispatches per shim ingress request**: initial attempt
  plus one replay before model bytes reach the client. This is not a guarantee
  about all autonomous retries a client may initiate as new requests.
- For shim-enabled Codex launchers, target `request_max_retries=0` and
  `stream_max_retries=0`; validate support and effective behavior with the actual
  installed client. Cover direct and SpecStory argv paths and Windows. Preserve
  the existing explicit bounded policy in direct mode and user CLI precedence.
  Inspect Claude's supported retry controls separately; do not invent an env var
  or claim a universal end-to-end attempt cap where the client owns retries.
- Replay a completed 408 only when a bounded parser identifies
  `user_request_timeout` (including nested JSON). Unknown 408 passes through.
- Completed transient 500/502/503 responses may receive the one replay. Backend
  watchdog timeouts are reported without immediately restarting a long attempt.
  A shim-local timeout/socket loss is `upstream_unknown`, not a normal 500.
- For 429, respect `Retry-After`; if a known remaining deadline cannot accommodate
  the wait, return the error instead of retrying earlier than requested.
  Retry 403 only with an explicit throttling classification; permission/auth 403,
  400, 401, 402 and policy/validation 422 pass through once.
- Never replay after forwarding model bytes. Identical body/model/trace are not
  an idempotency guarantee, especially after a completed `500 fetch failed`.
  Every retry is cancel-aware and consumes the same finite attempt budget.

### 4. Pilot earlier Astra compaction and improve auth diagnosis

- After the backend comparison, pilot an Astra compact budget at **70% of the
  live prompt ceiling**: about 610,400 tokens for the observed 872,000 ceiling.
  Treat 0.70 as a conservative experiment, not a proven optimal threshold.
  Propose one validated optional `COPILOT_ASTRA_COMPACT_RATIO` override, `0 < r <= 1`.
  Reject derived values below the client's supported minimum instead of emitting
  an invalid compact setting.
- Feed the computed budget to the existing Codex/Claude launch/pin mechanisms.
  Keep the true context window and Claude `[1m]` hint intact; preserve explicit
  caller overrides. Verify each client's actual trigger from its own records.
  Apply to new/relaunched sessions and refreshed managed pins; do not rewrite
  the history or active configuration of an existing large session.
- Missing live metadata uses the existing supported fallback plus a warning;
  never manufacture a model capacity. Measure compact frequency, duration,
  completion and continuity of pending work alongside ordinary latency/usage.
- Diagnose refresh network failure, expired IDE token and `Bad credentials`
  separately. Cached `/models` or process health is not an auth test. Keep
  re-authentication explicit; do not restart all sessions on arbitrary 401s.

### 5. Stage exact packages and a complete rollback bundle

- Unix: update the built-in version/integrity. Windows: update default, verified
  version entries, and the entire default-version CDN manifest (filenames and
  SHA-256 hashes); preserve the previous version's rollback path. Changing only
  the CDN URL is insufficient because bundled chunk filenames change.
- Inspect the release archive and verify the bytes actually used by staging.
  Prefer installing the same verified archive, or verify staged runtime files
  against it. Current Unix separately verifies a download then installs by spec;
  Windows normal registry installation does not independently enforce its SRI
  allowlist. Do not describe either as stronger than it is.
- Preserve configured registries, proxy handling and existing source-policy
  boundaries. Do not add new public fallback on authentication, certificate,
  policy or package-absence errors.
- Snapshot the previous package prefix, selection/integrity, matching deployed
  wrapper/shim, their settings, and backend `config.json` before first new start.
  Use a local restricted-permission directory; these snapshots do not enter git.
  Back up SQLite consistently, including any needed migration recovery data.
- Exercise the `responsesTransport`/`headersTimeoutMsV2` migration to
  `upstreamTransport`/`headersTimeoutMs` against an isolated config copy.
  Validate recovery using non-default values, unrelated provider settings and
  absence of a prior config, not merely the current all-default case.
- Roll back the matched package, selection, wrapper/shim and changed transport
  settings. Preserve newer credentials and post-cutover usage records; never
  blindly replace databases or restore an obsolete token. Retain post-upgrade
  artifacts if schema recovery is necessary. Document the exact tested procedure
  for each platform before cutover; Unix currently has no public rollback verb.

## Required verification

| Gate | Test / acceptance |
|---|---|
| Real admission across cancellation | Loopback client → shim → draining backend → fake upstream; cap=1, cancel first request after dispatch, second must wait until the first worker actually ends |
| Deadline ownership | Millisecond-scaled backend watchdog fires before shim fallback; local fallback never dispatches a replay; runtime override mismatch is diagnosed |
| Cancel cleanup | Queue, backoff, pre-header and mid-stream cancellation; exact-once release for settled work, zero replay after cancel, visible quarantine for genuinely unknown work, no unhandled rejection; all-unknown admission fails promptly and recovers without discarding tracked streams |
| Retry classification | 408→200, repeated/unknown 408, 500→408, 401, permission403, throttle429, blocked error-body read and Retry-After; assert exact physical dispatch counts |
| Response outcome | SSE completed/failed/incomplete/missing terminal, CRLF/chunk splits and comments; valid non-streaming JSON and compact objects; HTTP200 failure must not increment success |
| Existing behavior | Fast routing, same-model/body/trace replay, tool-description normalization, non-streaming JSON and explicit direct mode remain correct |
| Upgrade transaction | Hash mismatch, wrong version, install/start failure, selection precedence and offline rollback; no failed staging may modify live state |
| Data compatibility | Additive metrics migration retains historical rows; backend config round-trip with custom values; rollback preserves new usage/credentials |
| Client settings | Both Unix launcher paths and Windows honor shim/direct retry defaults, user overrides and Astra compact ratio validation |

Extend `tests/fixtures/copilot-shim-hardening.mjs` and
`tests/unit/copilot_proxy.bats`; add a focused multi-hop lifecycle fixture if
the existing one cannot represent background backend workers. Windows mirrors
shared fixture behavior through `tests/Copilot.Tests.ps1`, adds update/rollback
transaction coverage, and refreshes its reviewed Unix source commit + shim hash.
Run the relevant Bats suite, Pester, PSScriptAnalyzer, PowerShell parse/runtime
checks and existing bilingual docs builds. Confirm both shim files are byte-identical.
Mac checks cannot replace Windows process/registry/CDN validation on Windows.

## Deployment and acceptance

1. Complete fixtures and rollback rehearsal first. Stage runtime in isolated
   config/state directories; initial checks use local fake services, not live
   inference. Confirm exact installed/launching versions and config compatibility.
2. Record a 2.3.4 baseline with corrected metrics. Pilot fixed concurrency 4 if
   choosing the conservative profile, applying the same profile to both versions
   before comparison. Match shim/client retry, timeout and drain settings as well;
   otherwise compare the complete bundle rather than claim backend-only causality.
3. When publishing is requested, commit/push Unix first, then Windows with the
   reviewed Unix shim commit/hash. Record both gitlinks and cross-repo docs in
   one outer commit after confirming the inner commits are upstream-reachable.
4. On this Mac, the live chezmoi source is a separate clone. Review its drift,
   bring it to the selected commit, or pass an explicit submodule `--source`;
   deploy only the intended wrapper/shim files. Load the updated launchers.
5. Cut over after foreground and draining work have settled. Explicitly select
   exact `2.5.2`, accounting for Unix update's automatic restart versus Windows'
   separate restart. Preserve the selected version when defaults change.
6. Check backend and shim health, live Astra catalog, effective timeouts, actual
   launch version and one small real Responses smoke request. Successful catalog
   access alone is insufficient. Continue normal work and observe natural compact
   events; avoid repeated inference benchmarks or synthetic giant prompts.
7. Observe 24–48 hours of representative usage. Aim for at least 500 ordinary
   Astra requests and 5 explicitly identified compactions; if natural usage does
   not supply them, report insufficient evidence and extend observation without
   generating quota-consuming traffic just to meet a count.
8. Compare terminal-confirmed completion, final408/5xx rates, EOF/stall counts,
   retries per logical request, first-byte/queue/e2e latency and usage by model,
   request kind/size, effort and concurrency. Report client cancellation and auth
   separately. The historical 15/19/44 counts are context, not a valid rate target.

Promote only when lifecycle and rollback gates pass, there are no new terminal
or configuration regressions, and comparable natural traffic supports better
failure behavior without a material latency/usage regression. A >20% p95 e2e
increase in a comparable sufficiently populated cohort requires investigation;
it is an operational review trigger, not statistical proof of causation.
Compact acceptance requires a real client compaction record and correct resumed
work, not just HTTP200. Then pilot the earlier compact budget separately.

Rollback immediately for duplicate dispatch of still-tracked work, repeated new
stream truncation, inability to recover admission, startup regression, or loss
of settings/credentials. A repeat of an existing intermittent 408 is evidence to
investigate, not by itself proof that the upgrade regressed or succeeded.

## Remaining validation questions

- Can draining be implemented across Bun client cancellation without abandoning
  the backend response reader? The multi-hop fixture is the release blocker.
- What retry controls do the installed Codex and Claude versions actually honor?
  Preserve and report client-owned behavior that cannot be controlled locally.
- Does a 70% Astra compact budget improve ordinary work enough to justify more
  frequent compaction? Compare quality/usage as well as successful completion.
- Do 408 and ECONNRESET persist at smaller inputs with the same egress? If so,
  inspect network/receiver evidence as a separate follow-up; no node switching or
  remote configuration changes are implied by this plan.

## Sources

- [v2.5.2 release](https://github.com/caozhiyuan/copilot-api/releases/tag/v2.5.2)
- [Shared transport change](https://github.com/caozhiyuan/copilot-api/commit/69fea0a)
- [v2.5.2 lifecycle tests](https://github.com/caozhiyuan/copilot-api/blob/v2.5.2/tests/upstream-http-lifecycle.test.ts)
- [v2.5.1 credential maintenance](https://github.com/caozhiyuan/copilot-api/releases/tag/v2.5.1)
- [OpenAI Codex configuration reference](https://developers.openai.com/codex/config-reference)
- [Request-body timeout investigation](../pitfalls/copilot-proxy-context-policy-and-request-body-errors.md)
- [Expired IDE token investigation](../pitfalls/copilot-proxy-ide-token-expired-after-refresh-backoff.md)
- [Separate supervisor backlog](copilot-proxy-supervisor.md)
