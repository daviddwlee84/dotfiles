// Offline two-hop acceptance: no credentials or real inference endpoints.
// bun copilot-shim-lifecycle.mjs /absolute/copilot-throttle-shim.js /tmp/metrics-prefix
import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";
import { Database } from "bun:sqlite";
import { existsSync, readFileSync, statSync, unlinkSync } from "node:fs";
import { createConnection } from "node:net";

const [shimPath, dbPrefix, scenario = "all"] = process.argv.slice(2);
if (!shimPath || !dbPrefix) throw new Error("provide shim path and temporary metrics prefix");
if (scenario === "probe-blocked" || scenario === "probe-recovered") {
  const configuredUpstream = new URL(process.env.COPILOT_SHIM_UPSTREAM ?? "http://invalid");
  if (process.env.COPILOT_SHIM_PORT !== "0" || configuredUpstream.hostname !== "127.0.0.1"
      || Number(configuredUpstream.port) < 1024 || ["4141", "4142"].includes(configuredUpstream.port)
      || !process.env.COPILOT_SHIM_METRICS_DB?.startsWith(`${dbPrefix}-`)) {
    throw new Error("recovery probe requires explicit isolated port, backend and temporary metrics configuration");
  }
  const api = await import(pathToFileURL(shimPath).href);
  const server = api.startServer();
  try {
    assert.ok(server.port >= 1024 && ![4141, 4142].includes(server.port));
    console.log(JSON.stringify({ ready: true, pid: process.pid, shim_port: server.port, upstream: configuredUpstream.href }));
    const base = `http://127.0.0.1:${server.port}`;
    const status = await (await fetch(`${base}/_shim/health`)).json();
    const result = await fetch(`${base}/responses`, { method: "POST", headers: { "content-type": "application/json" }, body: '{"model":"after-recovery","stream":true}' });
    await result.text();
    if (scenario === "probe-blocked") {
      assert.equal(status.recovery_required, true);
      assert.equal(result.status, 503);
    } else {
      assert.equal(status.unknown, 0); assert.equal(status.recovery_required, false);
      assert.equal(result.status, 200);
    }
    console.log(JSON.stringify({ ok: true }));
  } finally { server.stop(true); }
  process.exit(0);
}
if (scenario === "all") {
  const results = [];
  for (const kind of ["draining", "outcomes", "migration", "unknown_headers", "unknown_stream"]) {
    const child = Bun.spawn([process.execPath, import.meta.path, shimPath, dbPrefix, kind], { stdout: "pipe", stderr: "pipe", env: { ...process.env } });
    const deadline = setTimeout(() => child.kill(), 55000);
    const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
    clearTimeout(deadline);
    if (code) throw new Error(`${kind} failed (${code})\n${stdout}\n${stderr}`);
    const ready = stdout.split("\n").find((line) => line.startsWith('{"ready":true,'));
    assert.equal(JSON.parse(ready).pid, child.pid, "readiness was not emitted by the owned child");
    results.push(JSON.parse(stdout.trim().split("\n").at(-1)));
  }
  console.log(JSON.stringify({ ok: true, scenarios: results }));
  process.exit(0);
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const deferred = () => { let resolve; const promise = new Promise((r) => { resolve = r; }); return { promise, resolve }; };
async function until(predicate, label, timeout = 8000) {
  const deadline = performance.now() + timeout;
  while (performance.now() < deadline) { if (await predicate()) return; await sleep(5); }
  throw new Error(`timed out: ${label}`);
}
const encoder = new TextEncoder();
const frame = (type) => `event: response.${type}\r\ndata: {"type":"response.${type}","response":{"status":"${type}"}}\r\n\r\n`;
const gates = new Map();
const calls = new Map();
const records = [];
let workers = 0;
let peakWorkers = 0;
let backendDisconnects = 0;
const gate = (mode) => { const d = deferred(); gates.set(mode, d); return d; };
const upstream = Bun.serve({
  hostname: "127.0.0.1", port: 0, idleTimeout: 0,
  async fetch(req) {
    const payload = await req.json();
    const markerPath = `${dbPath}.admission.json`;
    assert.ok(existsSync(markerPath), "physical dispatch happened before durable admission was recorded");
    assert.ok(JSON.parse(readFileSync(markerPath, "utf8")).leases.length > 0);
    if (process.platform !== "win32") assert.equal(statSync(markerPath).mode & 0o777, 0o600);
    const mode = payload.model;
    calls.set(mode, (calls.get(mode) ?? 0) + 1);
    const count = calls.get(mode);
    records.push({ mode, at: performance.now(), trace: req.headers.get("x-trace-id"), attempt: req.headers.get("x-copilot-shim-attempt"), body: JSON.stringify(payload) });
    workers++; peakWorkers = Math.max(peakWorkers, workers);
    let finished = false;
    const finish = () => { if (!finished) { finished = true; workers--; } };
    req.signal.addEventListener("abort", finish, { once: true });
    const response = (body, status = 200, headers = {}) => { finish(); return new Response(body, { status, headers }); };
    if (mode === "backend-timeout") {
      await sleep(250);
      return response(frame("completed"), 200, { "content-type": "text/event-stream" });
    }
    if ((mode === "retry408" && count === 1) || mode === "always408" || (mode === "500-408" && count === 2)) {
      return response(JSON.stringify({ error: { message: JSON.stringify({ error: { code: "user_request_timeout" } }) } }), 408);
    }
    if (mode === "unknown408") return response('{"error":{"code":"another_timeout"}}', 408);
    if (mode === "500-408" || mode === "retry500" && count === 1) return response('{"error":"transient"}', 500);
    if (mode === "401") return response('{"error":{"message":"IDE token expired: unauthorized: token expired"}}', 401);
    if (mode === "bad-credentials") return response('{"error":{"message":"Bad credentials"}}', 500);
    if (mode === "403") return response('{"error":{"code":"permission_denied"}}', 403);
    if (mode === "403-throttle") return response('{"error":{"code":"rate_limit_exceeded"}}', 403);
    if (mode === "422") return response('{"error":{"code":"cyber_policy"}}', 422);
    if (mode === "429-long") return response('{"error":"limited"}', 429, { "retry-after": "3600" });
    if (mode === "backoff") return response('{"error":"transient"}', 500, { "retry-after": "2" });
    if (mode === "429" && count === 1) return response('{"error":"limited"}', 429, { "retry-after": "0.06" });
    if (mode === "json-completed") return response('{"object":"response","status":"completed","output":[]}', 200, { "content-type": "application/json" });
    if (mode === "json-incomplete") return response('{"object":"response","status":"incomplete","output":[]}', 200, { "content-type": "application/json" });
    if (mode === "json-unverified") return response('{"ok":true}', 200, { "content-type": "application/json" });
    if (mode === "bodyless") return response(null, 204);
    if (mode === "bodyless-delayed") { await sleep(40); return response(null, 204); }
    if (mode === "json-compact") return response('{"id":"cmp_fixture","object":"response.compaction","created_at":1,"output":[{"type":"compaction","encrypted_content":"fixture-encrypted"}]}', 200, { "content-type": "application/json" });
    if (mode === "unknown-headers" || mode === "cancel-headers" || mode === "hold-queue") await gates.get(mode)?.promise;
    const stream = new ReadableStream({
      async start(controller) {
        try {
          if (mode === "cancel-stream" || mode === "unknown-stream") {
            controller.enqueue(encoder.encode('event: response.created\ndata: {"type":"response.created"}\n\n'));
            await gates.get(mode)?.promise;
          }
          const kind = mode === "failed" ? "failed" : mode === "incomplete" ? "incomplete" : "completed";
          const text = mode === "truncated" ? 'event: response.created\ndata: {}\n\n'
            : mode === "partial-terminal" ? frame(kind).slice(0, -4) : frame(kind);
          if (mode === "split") {
            controller.enqueue(encoder.encode(": heartbeat\r\n\r\n"));
            for (let i = 0; i < text.length; i += 3) { controller.enqueue(encoder.encode(text.slice(i, i + 3))); await sleep(1); }
          } else controller.enqueue(encoder.encode(text));
          controller.close();
        } catch {} finally { finish(); }
      },
      cancel() { finish(); },
    });
    return new Response(stream, { headers: { "content-type": "text/event-stream" } });
  },
});

function makeBackend() {
  return Bun.serve({
    hostname: "127.0.0.1", port: 0, idleTimeout: 0,
    async fetch(req) {
      if (req.method === "GET") return Response.json({ data: [] });
      const body = await req.text();
      const mode = JSON.parse(body).model;
      req.signal.addEventListener("abort", () => { backendDisconnects++; }, { once: true });
      // This is v2.5.2's intentional ownership: backend timeout is its own
      // signal; disconnecting its client does not cancel dispatched upstream.
      const ctl = new AbortController();
      const timer = setTimeout(() => ctl.abort(), mode === "backend-timeout" ? 100 : 4000);
      let result;
      try {
        result = await fetch(`http://127.0.0.1:${upstream.port}/responses`, {
          method: "POST", body, headers: req.headers, signal: ctl.signal,
        });
      } catch {
        clearTimeout(timer);
        return Response.json({ error: { type: "upstream_timeout", message: "backend watchdog" } }, { status: 504 });
      }
      clearTimeout(timer);
      if (!result.body) return new Response(null, { status: result.status, headers: result.headers });
      const reader = result.body.getReader();
      return new Response(new ReadableStream({
        async start(controller) {
          try {
            while (true) {
              const { done, value } = await reader.read();
              if (done) break;
              try { controller.enqueue(value); } catch {} // continue draining
            }
            try { controller.close(); } catch {}
          } catch (error) { try { controller.error(error); } catch {} }
          finally { try { reader.releaseLock(); } catch {} }
        },
        cancel() { /* backend keeps draining the physical upstream worker */ },
      }), { status: result.status, headers: result.headers });
    },
  });
}

let backend = makeBackend();
const dbPath = `${dbPrefix}-${scenario}.sqlite`;
if (scenario === "migration") {
  const old = new Database(dbPath, { create: true });
  old.exec(`CREATE TABLE request_metrics (
    id INTEGER PRIMARY KEY, trace_id TEXT NOT NULL UNIQUE, created_at_ms INTEGER NOT NULL,
    endpoint TEXT NOT NULL, model TEXT, scope TEXT NOT NULL DEFAULT 'normal', streaming INTEGER NOT NULL DEFAULT 0,
    status INTEGER, attempts INTEGER NOT NULL DEFAULT 0, retries INTEGER NOT NULL DEFAULT 0,
    queue_ms REAL, upstream_headers_ms REAL, first_byte_ms REAL, stream_ms REAL, e2e_ms REAL, error_kind TEXT
  );`);
  old.query("INSERT INTO request_metrics (trace_id,created_at_ms,endpoint,model,status) VALUES (?,?,?,?,?)")
    .run("legacy-trace", Date.now(), "/responses", "legacy-model", 200);
  old.close();
}
process.env.COPILOT_SHIM_PORT = "0";
process.env.COPILOT_SHIM_HOST = "127.0.0.1";
process.env.COPILOT_SHIM_UPSTREAM = `http://127.0.0.1:${backend.port}`;
process.env.COPILOT_SHIM_MIN = "1";
process.env.COPILOT_SHIM_MAX = "1";
process.env.COPILOT_SHIM_RETRIES = "1";
process.env.COPILOT_SHIM_BACKOFF_MS = "5";
process.env.COPILOT_SHIM_PING_AFTER_MS = "15";
process.env.COPILOT_SHIM_PING_MS = "10";
process.env.COPILOT_SHIM_STALL_MS = scenario.startsWith("unknown") ? "250" : "5000";
process.env.COPILOT_SHIM_BACKEND_HEADERS_TIMEOUT_MS = "4000";
process.env.COPILOT_SHIM_BACKEND_INACTIVITY_TIMEOUT_MS = "4000";
process.env.COPILOT_SHIM_BACKEND_VERSION = "2.5.2-fixture";
process.env.COPILOT_SHIM_METRICS_DB = dbPath;
process.env.COPILOT_API_SQLITE_DB_PATH = `${dbPath}.tokens`;
assert.equal(process.env.COPILOT_SHIM_PORT, "0");
assert.equal(process.env.COPILOT_SHIM_UPSTREAM, `http://127.0.0.1:${backend.port}`);
assert.equal(process.env.COPILOT_SHIM_METRICS_DB, dbPath);
assert.ok(backend.port >= 1024 && ![4141, 4142].includes(backend.port));
let api = await import(pathToFileURL(shimPath).href);
let shim = api.startServer();
assert.ok(shim.port >= 1024 && ![4141, 4142].includes(shim.port));
console.log(JSON.stringify({ ready: true, pid: process.pid, shim_port: shim.port, upstream: process.env.COPILOT_SHIM_UPSTREAM }));
const health = () => fetch(`http://127.0.0.1:${shim.port}/_shim/health`).then((r) => r.json());
const call = async (model, { signal, stream = true, path = "/responses", ...extra } = {}) => {
  const resp = await fetch(`http://127.0.0.1:${shim.port}${path}`, {
    method: "POST", headers: { "content-type": "application/json" }, signal,
    body: JSON.stringify({ model, stream, input: "fixture-private-prompt-do-not-store", ...extra }),
  });
  return { status: resp.status, body: await resp.text() };
};
const checkedCall = (model, options) => call(model, options).catch((error) => ({ error: error.name }));

try {
  if (scenario === "migration") {
    const migrated = api.openMetricsDb();
    assert.equal(migrated.query("SELECT COUNT(*) n FROM request_metrics").get().n, 1);
    assert.equal(migrated.query("SELECT outcome_version FROM request_metrics").get().outcome_version, null);
    assert.equal(migrated.query("SELECT COUNT(*) n FROM request_attempts").get().n, 0);
    api.pruneMetrics(migrated);
    migrated.close();
    assert.equal(api.queryStats({ model: "legacy-model" }).successes, 0);
    assert.equal(api.queryStats({ model: "legacy-model" }).unverified, 1);
    const repeated = api.openMetricsDb(); repeated.close();
    assert.equal((await call("migration-new")).status, 200);
    assert.equal(api.queryStats({ model: "migration-new" }).successes, 1);
  } else if (scenario === "draining") {
    for (const mode of ["cancel-headers", "cancel-stream"]) {
      const held = gate(mode);
      const ctl = new AbortController();
      const first = checkedCall(mode, { signal: ctl.signal });
      await until(() => calls.has(mode), `${mode} dispatched`);
      if (mode === "cancel-stream") await sleep(40);
      ctl.abort();
      assert.equal((await first).error, "AbortError");
      await until(async () => (await health()).draining === 1, `${mode} retained drain`);
      const nextMode = `after-${mode}`;
      const second = call(nextMode);
      await sleep(60);
      assert.equal(calls.get(nextMode) ?? 0, 0, "replacement reached physical upstream before drain completed");
      assert.equal(workers, 1);
      held.resolve();
      assert.equal((await second).status, 200);
      await until(async () => (await health()).active === 0, "drain released exactly once");
    }
    assert.equal(backendDisconnects, 0, "shim canceled its backend connection during client cancellation");
    const held = gate("hold-queue");
    const holder = call("hold-queue");
    await until(() => calls.has("hold-queue"), "holder dispatched");
    const deadCtl = new AbortController();
    const dead = checkedCall("canceled-queue", { signal: deadCtl.signal });
    await until(async () => (await health()).queued === 1, "waiter queued");
    deadCtl.abort();
    assert.equal((await dead).error, "AbortError");
    await until(async () => (await health()).queued === 0, "waiter removed");
    held.resolve(); await holder;
    assert.equal(calls.get("canceled-queue") ?? 0, 0);
    const backoffCtl = new AbortController();
    const backoff = checkedCall("backoff", { signal: backoffCtl.signal, stream: false });
    await until(() => calls.get("backoff") === 1, "backoff first dispatch");
    await sleep(30); backoffCtl.abort();
    assert.equal((await backoff).error, "AbortError");
    assert.equal((await call("after-backoff")).status, 200);
    assert.equal(calls.get("backoff"), 1);
    const rows = api.queryEvents({ scope: "all", limit: 100 });
    for (const mode of ["cancel-headers", "cancel-stream"]) {
      const row = rows.find((entry) => entry.model === mode);
      assert.equal(row.status, 499); assert.equal(row.drain_outcome, "completed");
      assert.equal(row.error_kind, "client_cancel"); assert.equal(row.terminal_event, "response.completed");
    }
    assert.equal(peakWorkers, 1);
  } else if (scenario === "outcomes") {
    for (const mode of ["split", "failed", "incomplete", "truncated", "partial-terminal", "retry408", "always408", "unknown408", "500-408", "retry500", "401", "bad-credentials", "403", "403-throttle", "422", "429", "429-long", "backend-timeout"]) await call(mode);
    for (const mode of ["json-completed", "json-incomplete", "json-unverified"]) await call(mode, { stream: false });
    assert.equal((await call("bodyless", { stream: false })).status, 204);
    await until(async () => (await health()).active === 0, "bodyless response released admission");
    assert.ok(!existsSync(api.admissionBarrierPath()), "bodyless response left an admission marker");
    await call("bodyless-delayed");
    await until(async () => (await health()).active === 0, "delayed bodyless response released admission");
    assert.ok(!existsSync(api.admissionBarrierPath()), "delayed bodyless response left an admission marker");
    await call("json-compact", { stream: false, path: "/responses/compact" });
    await until(async () => (await health()).active === 0, "outcome requests completed");
    const rows = api.queryEvents({ scope: "all", limit: 100 });
    const byModel = Object.fromEntries(rows.map((row) => [row.model, row]));
    assert.equal(byModel.split.terminal_event, "response.completed");
    assert.equal(byModel.failed.error_kind, "response_failed");
    assert.equal(byModel.incomplete.error_kind, "response_incomplete");
    assert.equal(byModel.truncated.error_kind, "upstream_protocol_eof");
    assert.equal(byModel["partial-terminal"].error_kind, "upstream_protocol_eof");
    assert.equal(byModel["json-completed"].terminal_event, "json.completed");
    assert.equal(byModel["json-incomplete"].error_kind, "response_incomplete");
    assert.equal(byModel["json-unverified"].error_kind, "response_unverified");
    assert.equal(byModel["json-compact"].terminal_event, "json.completed");
    assert.equal(byModel["json-compact"].request_kind, "compact");
    assert.equal(byModel.bodyless.error_kind, "response_unverified");
    assert.equal(byModel["bodyless-delayed"].error_kind, "upstream_protocol");
    assert.equal(byModel["backend-timeout"].timeout_owner, "backend");
    assert.equal(byModel["bad-credentials"].terminal_error_category, "bad_credentials");
    assert.equal(byModel["401"].terminal_error_category, "ide_token_expired");
    for (const mode of ["retry408", "always408", "500-408", "retry500", "403-throttle", "429"]) assert.equal(calls.get(mode), 2, mode);
    for (const mode of ["unknown408", "401", "bad-credentials", "403", "422", "429-long", "backend-timeout"]) assert.equal(calls.get(mode), 1, mode);
    const retryRecords = records.filter((row) => row.mode === "retry408");
    assert.equal(retryRecords[0].trace, retryRecords[1].trace);
    assert.equal(retryRecords[0].body, retryRecords[1].body);
    assert.deepEqual(retryRecords.map((row) => row.attempt), ["1", "2"]);
    const limited = records.filter((row) => row.mode === "429");
    assert.ok(limited[1].at - limited[0].at >= 55, "Retry-After was shortened");
    assert.equal(api.queryStats({ scope: "all", model: "failed" }).successes, 0);
    assert.equal(api.queryStats({ scope: "all", model: "json-unverified" }).unverified, 1);
    assert.equal(api.queryStats({ scope: "all", model: "json-completed" }).successes, 1);
    for (const row of rows) {
      assert.equal(row.outcome_version, 2); assert.equal(row.backend_version, "2.5.2-fixture");
      assert.match(row.shim_version, /^[a-f0-9]{64}$/); assert.ok(row.received_bytes > 0); assert.ok(row.forwarded_bytes > 0);
    }
    const db = new Database(dbPath, { readonly: true });
    assert.equal(db.query("SELECT COUNT(*) n FROM request_attempts").get().n, records.length);
    assert.deepEqual(db.query("SELECT outcome FROM request_attempts WHERE trace_id=? ORDER BY attempt").all(byModel.retry408.trace_id).map((row) => row.outcome), ["request_body_timeout", "completed"]);
    assert.deepEqual(db.query("SELECT outcome FROM request_attempts WHERE trace_id=? ORDER BY attempt").all(byModel["403"].trace_id).map((row) => row.outcome), ["permission"]);
    const serialized = JSON.stringify(db.query("SELECT * FROM request_metrics").all()) + JSON.stringify(db.query("SELECT * FROM request_attempts").all());
    assert.ok(!serialized.includes("fixture-private-prompt-do-not-store"));
    assert.ok(!serialized.includes("fixture-encrypted"));
    db.close();
  } else {
    if (scenario === "unknown_headers") {
      // A client which never finishes uploading must time out before admission,
      // even with Bun's transport idleTimeout disabled for long JSON responses.
      const ingress = await new Promise((resolve, reject) => {
        let received = "";
        const socket = createConnection({ host: "127.0.0.1", port: shim.port }, () => {
          socket.write(`POST /responses HTTP/1.1\r\nHost: 127.0.0.1:${shim.port}\r\nContent-Type: application/json\r\nContent-Length: 1024\r\nConnection: close\r\n\r\n{"model":"incomplete-upload"`);
        });
        const timer = setTimeout(() => {
          socket.destroy();
          reject(new Error("isolated ingress probe exceeded its deadline"));
        }, 5000);
        socket.on("data", (chunk) => {
          received += chunk.toString();
          if (received.includes("shim_request_body_timeout")) {
            clearTimeout(timer); socket.destroy();
            resolve({ status: Number(received.match(/^HTTP\/1\.1 (\d+)/)?.[1]), body: received });
          }
        });
        socket.on("error", (error) => { clearTimeout(timer); reject(error); });
      });
      assert.equal(ingress.status, 408);
      assert.ok(ingress.body.includes("shim_request_body_timeout"));
      assert.equal(calls.get("incomplete-upload") ?? 0, 0);
    }
    const mode = scenario === "unknown_headers" ? "unknown-headers" : "unknown-stream";
    const held = gate(mode);
    const first = checkedCall(mode);
    await until(() => calls.has(mode), "unknown request dispatched");
    const queued = checkedCall("behind-unknown");
    await until(async () => (await health()).unknown === 1, "uncertain execution quarantined");
    const failed = await first;
    assert.ok(failed.error || failed.status >= 500 || failed.body.includes("execution is unknown"));
    const rejected = await queued;
    assert.ok(rejected.body.includes("quarantined"));
    const at = performance.now();
    const immediate = await call("all-unknown");
    assert.equal(immediate.status, 503); assert.ok(performance.now() - at < 1000);
    assert.equal(calls.get("all-unknown") ?? 0, 0);
    assert.equal(calls.get("behind-unknown") ?? 0, 0);
    assert.equal(calls.get(mode), 1);
    const reset = await fetch(`http://127.0.0.1:${shim.port}/_shim/config`, { method: "PATCH", headers: { "content-type": "application/json", "x-copilot-shim-admin": "1" }, body: '{"reset":true}' });
    assert.equal((await reset.json()).unknown, 1, "limiter reset cleared unproven work");
    assert.equal((await health()).timeouts.compatible, false);
    // A fresh shim process may not clear capacity while the backend still owns
    // an old worker. The durable barrier must survive this attempted restart.
    const probe = async (kind) => {
      const child = Bun.spawn([process.execPath, import.meta.path, shimPath, dbPrefix, kind], { stdout: "pipe", stderr: "pipe", env: { ...process.env } });
      const deadline = setTimeout(() => child.kill(), 10000);
      const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
      clearTimeout(deadline);
      assert.equal(code, 0, `${kind}: ${stdout}\n${stderr}`);
      const ready = JSON.parse(stdout.split("\n").find((line) => line.startsWith('{"ready":true,')));
      assert.equal(ready.pid, child.pid);
      assert.equal(ready.upstream, `${process.env.COPILOT_SHIM_UPSTREAM}/`);
      assert.ok(ready.shim_port >= 1024 && ![4141, 4142].includes(ready.shim_port));
    };
    shim.stop(true);
    assert.ok(existsSync(api.admissionBarrierPath()));
    await probe("probe-blocked");
    assert.equal(calls.get("after-recovery") ?? 0, 0);
    // Stand in for the wrapper's verified full stop: settle tracked workers and
    // stop both services before explicitly removing the marker, then restart.
    held.resolve(); await until(() => workers === 0, "physical worker settled before recovery");
    await sleep(30); await backend.stop(true);
    unlinkSync(api.admissionBarrierPath());
    backend = makeBackend();
    process.env.COPILOT_SHIM_UPSTREAM = `http://127.0.0.1:${backend.port}`;
    await probe("probe-recovered");
    assert.equal(calls.get("after-recovery"), 1);
  }
  console.log(JSON.stringify({ scenario, ok: true, physical_dispatches: records.length, peak_workers: peakWorkers }));
} finally {
  for (const held of gates.values()) held.resolve();
  shim.stop(true); backend.stop(true); upstream.stop(true);
}
