# Offline Copilot fixture child sends after-recovery to the live gateway

**Symptoms**: test model `after-recovery` in the live metrics database;
`status=400`, `attempts=1`, `retries=0`; additive test schema columns appear in
the live `request_metrics` table
**First seen**: 2026-09-08 07:46:48 UTC
**Affects**: Bun fixture subprocesses relying on inherited `process.env` mutations
**Status**: fixture isolation guards fixed; incident disclosed; live schema not downgraded

## What happened

During offline acceptance work for copilot-api 2.5.2, a recovery-probe subprocess
did not receive the parent's mutated isolation environment. Without explicit
child environment values, the shim module fell back to the ordinary local
gateway and metrics paths. The probe sent its synthetic `after-recovery` request
to the existing gateway and recorded one HTTP 400 with no retry.

Importing the shim could run its additive metrics schema initialization before
the fixture established that its server was isolated. Checking only server
readiness after import therefore did not protect the live database. Probing an
expected port also cannot establish that the listener belongs to the spawned
child: an existing service may answer it.

Read-only verification found that the Mac's backend and shim remained the same
processes started the previous day, and the original shim's health endpoint
continued responding. No stop, restart or authentication action was issued.
The live metrics database did gain the additive columns and one synthetic row.
The current backend log contained no `after-recovery` model line; the observed
400 alone is not proof about every downstream billing or execution detail.

A subsequent review found that an existing Windows inline keepalive fixture
also omitted its temporary metrics paths. Earlier Pester runs may have added
synthetic `m` rows, even though that fixture's upstream was local and fake.
It now sets temporary metrics/token-usage paths and validates isolation before
import. Do not describe the whole testing session as having only one possible
synthetic metrics write.

## Fix and prevention

- Pass an explicit `{ ...process.env }` to every `Bun.spawn` fixture child after
  assigning the test's isolation settings. Do not depend on implicit inheritance
  of a mutated environment.
- Before importing code with initialization side effects, require `port=0`, a
  fixture-owned loopback upstream on an ephemeral port, and the exact temporary
  metrics prefix. Reject ordinary ports 4141/4142 and default state paths.
- Have the child emit readiness containing its PID and actual ephemeral port;
  verify that the PID is the one returned by the process handle. Do not accept
  an unrelated listener as readiness.
- Stop only owned process handles. Fixture teardown must never call the public
  proxy manager or kill by a broad command-name pattern.
- Validate both process isolation and data-path isolation. A bind failure does
  not undo module-import side effects.

The live additive schema was not forcibly rolled back while the service was
writing to it. The synthetic model is identifiable in metrics and must not be
used in production-model performance comparisons. This is a disclosed testing
side effect, not a claim that the Mac's runtime data remained untouched.

## Related

- [Lifecycle fixture](../tests/fixtures/copilot-shim-lifecycle.mjs)
- [Remote dogfood runner](../scripts/copilot_proxy/dogfood.py)
- [Upgrade design](../backlog/copilot-proxy-backend-2-5-2-stability.md)
