#!/usr/bin/env bun
import { Database } from "bun:sqlite";
import { existsSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
// copilot-throttle-shim.js — a tiny streaming reverse proxy that sits IN FRONT
// of the local copilot-api fork (default :4141). It provides the request
// compatibility fixes shared by Codex/Claude Code and stops GitHub's enterprise
// Copilot backend from 403-ing ("Forbidden") on bursts of premium requests,
// WITHOUT adding latency to normal single-agent flow.
//
//   agent client ─▶ shim (:4142) ─▶ copilot-api fork (:4141) ─▶ Copilot backend
//                    │
//                    ├─ semaphore: at most MAX concurrent in-flight upstream
//                    │   POSTs; a burst queues instead of hitting the backend
//                    │   all at once (that simultaneity is what trips abuse
//                    │   detection). Under the cap there is ZERO added latency.
//                    │
//                    ├─ transparent retry on 403/429/500/502/503/504 + network
//                    │   errors, jittered backoff, BEFORE any response body is
//                    │   streamed — so the agent never sees the transient 403
//                    │   ("Please run /login"). GET/HEAD (health, /v1/models)
//                    │   bypass both, so liveness checks stay instant.
//                    │
//                    └─ SSE keepalive + stall watchdog: an OpenAI reasoning
//                        model produces NOTHING on the wire until its first
//                        token, and copilot-api withholds the response headers
//                        for that whole time, so the client socket can sit
//                        silent for minutes. See "silent socket" below.
//
// The silent socket (why the keepalive exists)
// --------------------------------------------
// copilot-api does not open the SSE stream early: measured against :4141 with
// gpt-5.6-sol, the response HEADERS arrive at 8.11s and the first body chunk at
// 8.12s — the think time is spent entirely inside one `fetch()` with zero bytes
// on either socket. The backend log's own p50/p90/max for that window is
// 7s/20s/89s, and queueing on the semaphore above stacks on top of it. Real
// Anthropic streams cover this with periodic `ping` events; copilot-api emits
// none (verified: message_start / content_block_* / message_delta / message_stop
// only). A silent socket is free to be reaped by anything in the path — Bun's
// own idleTimeout, a Clash/mihomo idle sweep — and the agent then hangs with no
// error at all, which is the interrupt-and-type-"continue" symptom.
//
// So for client-requested streams the shim commits a `text/event-stream`
// response after PING_AFTER_MS and emits SSE comment frames (`: …\n\n`, ignored
// by every spec-compliant parser, including the Anthropic and OpenAI SDKs)
// until the upstream produces something. Fast non-2xx responses retain their
// real status; every successful `stream:true` response must still be SSE.
//
// Managed by copilot-proxy (see 43_copilot_proxy.sh: `copilot-proxy shim on`).
// Config via env (all optional):
//   COPILOT_SHIM_PORT       listen port                    (default 4142)
//   COPILOT_SHIM_UPSTREAM   upstream base URL              (default http://localhost:4141)
//   COPILOT_SHIM_MAX        max concurrent in-flight POSTs (default 4)
//   COPILOT_SHIM_RETRIES    retry attempts on transient    (default 3)
//   COPILOT_SHIM_BACKOFF_MS base backoff ms, doubles/try   (default 500)
//   COPILOT_SHIM_PING_MS    keepalive interval, 0=off      (default 15000)
//   COPILOT_SHIM_PING_AFTER_MS  silence tolerated before the SSE response is
//                           committed and pings start      (default 10000)
//   COPILOT_SHIM_STALL_MS   silence that counts as a wedged upstream: the
//                           attempt is aborted (retried when no bytes have
//                           reached the client yet), 0=off (default 240000)
//   COPILOT_SHIM_METRICS_DB request timing database (default:
//                           $XDG_STATE_HOME/copilot-proxy/metrics.sqlite)
//   COPILOT_API_SQLITE_DB_PATH upstream token database override

const PORT = Number(process.env.COPILOT_SHIM_PORT ?? 4142);
const UPSTREAM = (process.env.COPILOT_SHIM_UPSTREAM ?? "http://localhost:4141").replace(/\/+$/, "");
const MAX = Math.max(1, Number(process.env.COPILOT_SHIM_MAX ?? 4));
const RETRIES = Math.max(0, Number(process.env.COPILOT_SHIM_RETRIES ?? 3));
const BACKOFF_MS = Math.max(0, Number(process.env.COPILOT_SHIM_BACKOFF_MS ?? 500));
const PING_MS = Math.max(0, Number(process.env.COPILOT_SHIM_PING_MS ?? 15000));
const PING_AFTER_MS = Math.max(0, Number(process.env.COPILOT_SHIM_PING_AFTER_MS ?? 10000));
const STALL_MS = Math.max(0, Number(process.env.COPILOT_SHIM_STALL_MS ?? 240000));
const RETRY_STATUS = new Set([403, 429, 500, 502, 503, 504]);
const MAX_BACKOFF_MS = 30000;
const ERROR_BODY_TIMEOUT_MS = 2000;
const ERROR_BODY_MAX_BYTES = 2048;
const RETENTION_MS = 90 * 86400 * 1000;

function xdgPath(kind, ...parts) {
  const home = process.env.HOME ?? ".";
  const root = kind === "state"
    ? (process.env.XDG_STATE_HOME ?? join(home, ".local/state"))
    : (process.env.XDG_DATA_HOME ?? join(home, ".local/share"));
  return join(root, ...parts);
}

export function metricsDbPath() {
  return process.env.COPILOT_SHIM_METRICS_DB ?? xdgPath("state", "copilot-proxy", "metrics.sqlite");
}

export function tokenDbPath() {
  return process.env.COPILOT_API_SQLITE_DB_PATH ?? xdgPath("data", "copilot-api", "copilot-api.sqlite");
}

let metricsDb;
let lastRetentionAt = 0;
export function openMetricsDb(path = metricsDbPath()) {
  mkdirSync(dirname(path), { recursive: true });
  const db = new Database(path, { create: true });
  db.exec("PRAGMA journal_mode=WAL; PRAGMA busy_timeout=3000;");
  db.exec(`CREATE TABLE IF NOT EXISTS request_metrics (
    id INTEGER PRIMARY KEY,
    trace_id TEXT NOT NULL UNIQUE,
    created_at_ms INTEGER NOT NULL,
    endpoint TEXT NOT NULL,
    model TEXT,
    scope TEXT NOT NULL DEFAULT 'normal',
    streaming INTEGER NOT NULL DEFAULT 0,
    status INTEGER,
    attempts INTEGER NOT NULL DEFAULT 0,
    retries INTEGER NOT NULL DEFAULT 0,
    queue_ms REAL,
    upstream_headers_ms REAL,
    first_byte_ms REAL,
    stream_ms REAL,
    e2e_ms REAL,
    error_kind TEXT
  );
  CREATE INDEX IF NOT EXISTS request_metrics_created_idx ON request_metrics(created_at_ms);
  CREATE INDEX IF NOT EXISTS request_metrics_scope_model_idx ON request_metrics(scope, model, created_at_ms);`);
  return db;
}

export function pruneMetrics(db, now = Date.now()) {
  return db.query("DELETE FROM request_metrics WHERE created_at_ms < ?").run(now - RETENTION_MS);
}

function getMetricsDb() {
  if (!metricsDb) metricsDb = openMetricsDb();
  const now = Date.now();
  if (now - lastRetentionAt > 86400 * 1000) {
    pruneMetrics(metricsDb, now);
    lastRetentionAt = now;
  }
  return metricsDb;
}

function requestMetadata(pathname, body, headers) {
  let payload = {};
  try {
    payload = JSON.parse(typeof body === "string" ? body : new TextDecoder().decode(body));
  } catch {}
  return {
    endpoint: pathname,
    model: typeof payload?.model === "string" ? payload.model : null,
    streaming: payload?.stream === true,
    scope: headers.get("x-copilot-benchmark") === "1" ? "benchmark" : "normal",
  };
}

export function createMetricTracker(meta, db = getMetricsDb(), clock = () => performance.now()) {
  const wall = Date.now();
  const started = clock();
  let permitAt = null;
  let firstAt = null;
  let attempts = 0;
  let finished = false;
  const state = { ...meta };
  return {
    traceId: meta.traceId,
    attempt() { attempts++; },
    acquired() { if (permitAt === null) permitAt = clock(); },
    firstByte() { if (firstAt === null) firstAt = clock(); },
    finalize(status, errorKind = null) {
      if (finished) return;
      finished = true;
      const ended = clock();
      db.query(`INSERT OR IGNORE INTO request_metrics
        (trace_id,created_at_ms,endpoint,model,scope,streaming,status,attempts,retries,
         queue_ms,upstream_headers_ms,first_byte_ms,stream_ms,e2e_ms,error_kind)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`).run(
          state.traceId, wall, state.endpoint, state.model, state.scope,
          state.streaming ? 1 : 0, status, attempts, Math.max(0, attempts - 1),
          permitAt === null ? null : permitAt - started,
          permitAt === null || state.headersAt === undefined ? null : state.headersAt - permitAt,
          firstAt === null ? null : firstAt - started,
          firstAt === null ? null : ended - firstAt,
          ended - started, errorKind,
        );
    },
    headers() { state.headersAt = clock(); },
  };
}

function periodStart(period, now = Date.now()) {
  const durations = { day: 86400e3, week: 7 * 86400e3, month: 30 * 86400e3 };
  if (!(period in durations)) throw new Error(`invalid period: ${period}`);
  return now - durations[period];
}

function percentile(values, p) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor((sorted.length - 1) * p))];
}

function tokenTotals(traceIds, path = tokenDbPath()) {
  const out = new Map();
  if (!traceIds.length || !existsSync(path)) return out;
  let db;
  try {
    db = new Database(path, { readonly: true });
    db.exec("PRAGMA busy_timeout=3000;");
    for (let offset = 0; offset < traceIds.length; offset += 400) {
      const ids = traceIds.slice(offset, offset + 400);
      const marks = ids.map(() => "?").join(",");
      const rows = db.query(`SELECT trace_id, model,
          SUM(COALESCE(input_tokens,0)) input_tokens,
          SUM(COALESCE(output_tokens,0)) output_tokens,
          SUM(COALESCE(total_tokens,0)) total_tokens,
          SUM(COALESCE(total_nano_aiu,0)) total_nano_aiu
        FROM token_usage_events WHERE trace_id IN (${marks}) GROUP BY trace_id, model`).all(...ids);
      for (const row of rows) {
        const key = `${row.trace_id}\u0000${row.model ?? ""}`;
        out.set(key, row);
        const anyKey = `${row.trace_id}\u0000*`;
        const any = out.get(anyKey) ?? { trace_id: row.trace_id, model: null, input_tokens: 0, output_tokens: 0, total_tokens: 0, total_nano_aiu: 0 };
        any.input_tokens += Number(row.input_tokens ?? 0);
        any.output_tokens += Number(row.output_tokens ?? 0);
        any.total_tokens += Number(row.total_tokens ?? 0);
        any.total_nano_aiu += Number(row.total_nano_aiu ?? 0);
        out.set(anyKey, any);
      }
    }
  } catch {}
  finally { try { db?.close(); } catch {} }
  return out;
}

function metricRows({ period = "day", scope = "normal", model = null, limit = null } = {}, path = metricsDbPath()) {
  if (!existsSync(path)) return [];
  const db = new Database(path, { readonly: true });
  db.exec("PRAGMA busy_timeout=3000;");
  const clauses = ["created_at_ms >= ?"];
  const params = [periodStart(period)];
  if (scope !== "all") { clauses.push("scope = ?"); params.push(scope); }
  if (model) { clauses.push("model = ?"); params.push(model); }
  let sql = `SELECT * FROM request_metrics WHERE ${clauses.join(" AND ")} ORDER BY created_at_ms DESC`;
  if (limit !== null) { sql += " LIMIT ?"; params.push(limit); }
  try { return db.query(sql).all(...params); }
  finally { db.close(); }
}

function enrichRows(rows) {
  const tokens = tokenTotals([...new Set(rows.map((r) => r.trace_id))]);
  return rows.map((r) => {
    const t = tokens.get(`${r.trace_id}\u0000${r.model ?? ""}`)
      ?? tokens.get(`${r.trace_id}\u0000*`) ?? {};
    const outputTokens = Number(t.output_tokens ?? 0);
    return {
      ...r,
      streaming: Boolean(r.streaming),
      input_tokens: Number(t.input_tokens ?? 0),
      output_tokens: outputTokens,
      total_tokens: Number(t.total_tokens ?? 0),
      total_aiu: Number(t.total_nano_aiu ?? 0) / 1e9,
      output_tps: r.streaming && r.stream_ms > 0 && outputTokens > 0
        ? outputTokens / (r.stream_ms / 1000) : null,
    };
  });
}

export function queryEvents(options = {}) {
  return enrichRows(metricRows({ ...options, limit: options.limit ?? 50 }));
}

export function queryStats(options = {}) {
  const rows = enrichRows(metricRows({ ...options, limit: null }));
  const nums = (field) => rows.map((r) => r[field]).filter((v) => Number.isFinite(v));
  const timing = {};
  for (const field of ["queue_ms", "upstream_headers_ms", "first_byte_ms", "stream_ms", "e2e_ms", "output_tps"]) {
    const values = nums(field);
    timing[field] = { p50: percentile(values, .5), p90: percentile(values, .9), max: percentile(values, 1) };
  }
  return {
    period: options.period ?? "day",
    scope: options.scope ?? "normal",
    model: options.model ?? null,
    requests: rows.length,
    successes: rows.filter((r) => r.status >= 200 && r.status < 400 && !r.error_kind).length,
    errors: rows.filter((r) => r.error_kind || !(r.status >= 200 && r.status < 400)).length,
    retries: rows.reduce((n, r) => n + Number(r.retries ?? 0), 0),
    input_tokens: rows.reduce((n, r) => n + r.input_tokens, 0),
    output_tokens: rows.reduce((n, r) => n + r.output_tokens, 0),
    total_tokens: rows.reduce((n, r) => n + r.total_tokens, 0),
    total_aiu: rows.reduce((n, r) => n + r.total_aiu, 0),
    timing,
  };
}

function jsonResponse(value, status = 200) {
  return Response.json(value, { status, headers: { "cache-control": "no-store" } });
}

// SSE comment frame. The spec says a line starting with ":" is a comment and is
// discarded by the parser, so this is invisible to the agent yet counts as
// traffic for every idle timer in the path.
const PING_FRAME = new TextEncoder().encode(": copilot-shim keepalive\n\n");

const log = (...a) => console.log(new Date().toISOString(), "[shim]", ...a);
const abortError = () => new DOMException("client aborted", "AbortError");

function abortableSleep(ms, signal) {
  if (signal?.aborted) return Promise.reject(abortError());
  return new Promise((resolve, reject) => {
    const timer = setTimeout(done, ms);
    const onAbort = () => { cleanup(); reject(abortError()); };
    function cleanup() {
      clearTimeout(timer);
      signal?.removeEventListener("abort", onAbort);
    }
    function done() { cleanup(); resolve(); }
    signal?.addEventListener("abort", onAbort, { once: true });
  });
}

// A cancellable timer promise. Racing a bare timer would leave one live timer
// per pull; this token is always canceled when another branch wins.
function timeoutToken(ms) {
  let id;
  const promise = new Promise((res) => { id = setTimeout(() => res({ tick: true }), ms); });
  return { promise, cancel: () => clearTimeout(id) };
}

// Headers resolve fetch() before its body is consumed. Retain the per-attempt
// controller so a retry/protocol rejection can terminate that physical request
// before a replacement attempt starts.
const responseAborters = new WeakMap();
function abortResponse(resp) {
  const abort = resp && responseAborters.get(resp);
  if (!abort) return;
  responseAborters.delete(resp);
  abort();
}

export async function closeResponse(resp, reason) {
  abortResponse(resp);
  if (!resp?.body) return;
  const deadline = timeoutToken(ERROR_BODY_TIMEOUT_MS);
  try {
    await Promise.race([
      resp.body.cancel(reason).catch(() => {}),
      deadline.promise,
    ]);
  } catch {}
  finally { deadline.cancel(); }
}

// ---- semaphore (at most MAX permits; canceled waiters are removed eagerly) ----
let active = 0;
const waiters = [];
function acquire(signal) {
  if (signal?.aborted) return Promise.reject(abortError());
  if (active < MAX) { active++; return Promise.resolve(); }
  return new Promise((resolve, reject) => {
    const waiter = { resolve, reject, signal, onAbort: null };
    waiter.onAbort = () => {
      const index = waiters.indexOf(waiter);
      if (index >= 0) waiters.splice(index, 1);
      signal?.removeEventListener("abort", waiter.onAbort);
      reject(abortError());
    };
    signal?.addEventListener("abort", waiter.onAbort, { once: true });
    waiters.push(waiter);
  });
}
function release() {
  active = Math.max(0, active - 1);
  while (waiters.length) {
    const next = waiters.shift();
    next.signal?.removeEventListener("abort", next.onAbort);
    if (next.signal?.aborted) { next.reject(abortError()); continue; }
    active++;
    next.resolve();
    break;
  }
}

function backoffMs(attempt, retryAfter) {
  const seconds = Number(retryAfter);
  if (Number.isFinite(seconds) && seconds > 0) return Math.min(seconds * 1000, MAX_BACKOFF_MS);
  const date = retryAfter ? Date.parse(retryAfter) : NaN;
  if (Number.isFinite(date)) return Math.min(Math.max(0, date - Date.now()), MAX_BACKOFF_MS);
  const jitter = BACKOFF_MS > 0 ? Math.floor(Math.random() * BACKOFF_MS) : 0;
  return Math.min(BACKOFF_MS * 2 ** attempt + jitter, MAX_BACKOFF_MS);
}

function buildUpstream(req, bodyBuf, bodyWasDecoded = false, traceId = null) {
  const url = new URL(req.url);
  const target = UPSTREAM + url.pathname + url.search;
  const baseHeaders = new Headers(req.headers);
  baseHeaders.delete("host");
  baseHeaders.delete("content-length"); // fetch recomputes from body
  if (bodyWasDecoded) baseHeaders.delete("content-encoding");
  if (traceId) baseHeaders.set("x-trace-id", traceId);
  const method = req.method;
  const makeInit = (signal) => {
    const init = { method, headers: new Headers(baseHeaders), signal };
    if (bodyBuf !== undefined) init.body = bodyBuf;
    return init;
  };
  return { target, makeInit };
}

function blankDescription(value) {
  return typeof value !== "string" || value.trim().length === 0;
}

function toolLabel(tool) {
  const name = tool?.name ?? tool?.tool_name ?? tool?.title;
  return typeof name === "string" && name.trim() ? name.trim() : "unnamed tool";
}

// Codex records MCP discovery in Responses input items. Some MCP/plugin
// servers legally omit a tool description, which Codex serializes as "". The
// GitHub Copilot Responses endpoint is stricter than OpenAI's endpoint and
// rejects that request before inference:
//
//   Invalid 'input[0].tools[0].description': empty string.
//
// Only touch tool-definition arrays in the two Responses locations Codex uses;
// do not recursively rewrite user input, JSON Schema descriptions, or outputs.
export function normalizeResponsesToolDescriptions(payload) {
  let changed = 0;
  const patched = [];

  const normalizeTools = (tools, prefix, requireDescriptionField = false) => {
    if (!Array.isArray(tools)) return;
    tools.forEach((tool, index) => {
      if (!tool || typeof tool !== "object") return;
      if (requireDescriptionField && !("description" in tool)) return;
      if (!blankDescription(tool.description)) return;
      const label = toolLabel(tool);
      tool.description = `Tool ${label}.`;
      changed++;
      patched.push(`${prefix}[${index}].description`);
    });
  };

  if (!payload || typeof payload !== "object") return { changed, patched };
  // Built-in top-level tools such as web_search do not have a description by
  // design, so only repair an explicitly present-but-blank field there.
  normalizeTools(payload.tools, "tools", true);
  if (Array.isArray(payload.input)) {
    payload.input.forEach((item, index) => {
      // Codex versions have used more than one discriminator for persisted MCP
      // discovery. The stable shape is the nested tool-definition array itself.
      if (!item || typeof item !== "object") return;
      normalizeTools(item.tools, `input[${index}].tools`);
    });
  }
  return { changed, patched };
}

export function normalizeRequestBody(pathname, bodyBuf, contentEncoding = "") {
  if (pathname !== "/responses" && pathname !== "/v1/responses") {
    return { body: bodyBuf, inspectBody: bodyBuf, changed: 0, patched: [], parseError: null, decoded: false };
  }
  try {
    const encoding = contentEncoding.trim().toLowerCase();
    const decodedBody = encoding === "zstd" ? Bun.zstdDecompressSync(new Uint8Array(bodyBuf)) : bodyBuf;
    const payload = JSON.parse(new TextDecoder().decode(decodedBody));
    const result = normalizeResponsesToolDescriptions(payload);
    if (result.changed === 0) return { body: bodyBuf, inspectBody: decodedBody, ...result, parseError: null, decoded: false };
    const body = JSON.stringify(payload);
    return { body, inspectBody: body, ...result, parseError: null, decoded: encoding === "zstd" };
  } catch (error) {
    // Preserve malformed/non-JSON requests verbatim; the upstream remains the
    // authority for their validation and error response.
    return { body: bodyBuf, inspectBody: bodyBuf, changed: 0, patched: [], parseError: String(error), decoded: false };
  }
}

// Did the client ask for a streamed response? Only those may be answered with
// the early `text/event-stream` commit — a non-streaming caller expects one JSON
// body and would choke on comment frames. Unparseable/compressed bodies fall
// back to `false`, i.e. to the pre-keepalive behaviour.
export function wantsStream(body) {
  try {
    const text = typeof body === "string" ? body : new TextDecoder().decode(body);
    return JSON.parse(text)?.stream === true;
  } catch { return false; }
}

function isEventStream(contentType) {
  return (contentType ?? "").split(";", 1)[0].trim().toLowerCase() === "text/event-stream";
}

// One upstream `fetch` attempt with a ceiling on the silent pre-header window.
// A wedged upstream otherwise never settles this promise and the agent waits
// forever; RETRIES then gets a chance to re-issue the request instead.
function fetchAttempt(target, makeInit, clientSignal) {
  const ctl = new AbortController();
  const onClientAbort = () => ctl.abort();
  if (clientSignal?.aborted) ctl.abort();
  else clientSignal?.addEventListener("abort", onClientAbort, { once: true });
  let stalled = false;
  const timer = STALL_MS
    ? setTimeout(() => { stalled = true; ctl.abort(); }, STALL_MS)
    : null;
  const done = () => {
    if (timer) clearTimeout(timer);
    clientSignal?.removeEventListener("abort", onClientAbort);
  };
  return fetch(target, makeInit(ctl.signal)).then(
    (resp) => {
      done();
      responseAborters.set(resp, () => ctl.abort());
      return resp;
    },
    (err) => {
      done();
      throw stalled ? new Error(`upstream sent no response headers in ${STALL_MS}ms`) : err;
    },
  );
}

// One `pull` step over an upstream reader: forward the next chunk, or emit a
// keepalive frame once the upstream has been silent for PING_MS, or fail the
// stream when that silence reaches STALL_MS.
//
// `state.pending` is load-bearing: when the ping timer wins the race the read
// promise is NOT abandoned, it is carried into the next pull. Re-reading would
// drop a chunk. Keeping the pull-driven shape (rather than a `start()` pump)
// preserves backpressure toward the upstream.
async function pumpStep(state, controller, releaseOnce, label, tracker) {
  if (!state.pending) state.pending = state.reader.read();

  const intervalMs = state.keepalive ? PING_MS : STALL_MS;
  if (!intervalMs) {
    const { done, value } = await state.pending;
    state.pending = null;
    if (done) { controller.close(); releaseOnce(); tracker?.finalize(state.status); return; }
    tracker?.firstByte();
    controller.enqueue(value);
    return;
  }

  const tick = timeoutToken(intervalMs);
  const winner = await Promise.race([state.pending.then((read) => ({ read })), tick.promise]);
  tick.cancel();

  if (winner.read) {
    state.pending = null;
    state.idleMs = 0;
    if (winner.read.done) { controller.close(); releaseOnce(); tracker?.finalize(state.status); return; }
    tracker?.firstByte();
    controller.enqueue(winner.read.value);
    return;
  }

  state.idleMs += intervalMs;
  if (STALL_MS && state.idleMs >= STALL_MS) {
    const secs = Math.round(state.idleMs / 1000);
    log(`${label} stalled mid-stream: no upstream bytes for ${secs}s; failing the response`);
    try { state.reader.cancel(new Error("stalled")).catch(() => {}); } catch {}
    releaseOnce();
    tracker?.finalize(state.status, "upstream_stall");
    controller.error(new Error(`shim: upstream stalled for ${secs}s`));
    return;
  }
  controller.enqueue(PING_FRAME);
}

// Stream an upstream response to the client, holding the semaphore permit until
// the stream ends / errors / is cancelled (true in-flight accounting).
function streamThrough(resp, releaseOnce, label = "stream", tracker = null) {
  const headers = new Headers(resp.headers);
  headers.delete("content-encoding");  // Bun already decoded the upstream body
  headers.delete("content-length");
  headers.delete("transfer-encoding");
  if (tracker?.traceId) headers.set("x-trace-id", tracker.traceId);
  if (!resp.body) {
    releaseOnce(); tracker?.finalize(resp.status);
    return new Response(null, { status: resp.status, headers });
  }

  const state = {
    reader: resp.body.getReader(),
    pending: null,
    idleMs: 0,
    status: resp.status,
    // Only an SSE body may carry comment frames; a JSON body must stay verbatim.
    keepalive: PING_MS > 0 && isEventStream(headers.get("content-type")),
  };
  const stream = new ReadableStream({
    async pull(controller) {
      try { await pumpStep(state, controller, releaseOnce, label, tracker); }
      catch (err) { releaseOnce(); tracker?.finalize(resp.status, "stream_error"); controller.error(err); }
    },
    cancel(reason) {
      abortResponse(resp);
      releaseOnce(); tracker?.finalize(499, "client_cancel");
      try { state.reader.cancel(reason); } catch {}
    },
  });
  return new Response(stream, { status: resp.status, headers });
}

async function boundedErrorDetail(resp, err, signal) {
  if (err || !resp) return String(err ?? "upstream error");
  const prefix = `upstream returned ${resp.status}`;
  if (!resp.body) return prefix;
  const reader = resp.body.getReader();
  const chunks = [];
  let size = 0;
  const deadline = timeoutToken(ERROR_BODY_TIMEOUT_MS);
  let onAbort;
  const aborted = new Promise((resolve) => {
    onAbort = () => resolve({ aborted: true });
    if (signal?.aborted) onAbort();
    else signal?.addEventListener("abort", onAbort, { once: true });
  });
  try {
    while (size < ERROR_BODY_MAX_BYTES) {
      const winner = await Promise.race([
        reader.read().then((read) => ({ read })),
        deadline.promise,
        aborted,
      ]);
      if (winner.tick || winner.aborted || !winner.read || winner.read.done) break;
      const value = winner.read.value;
      const take = value.subarray(0, ERROR_BODY_MAX_BYTES - size);
      chunks.push(take);
      size += take.byteLength;
      if (take.byteLength < value.byteLength) break;
    }
  } catch {}
  finally {
    deadline.cancel();
    signal?.removeEventListener("abort", onAbort);
    abortResponse(resp);
    try { reader.cancel().catch(() => {}); } catch {}
  }
  if (!size) return prefix;
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  const snippet = new TextDecoder().decode(bytes).replace(/\s+/g, " ").trim();
  return snippet ? `${prefix}: ${snippet.slice(0, 500)}` : prefix;
}

function responsesErrorCode(status) {
  if (status === 402) return "insufficient_quota";
  if (status === 429) return "rate_limit_exceeded";
  if (status >= 400 && status < 500) return "invalid_prompt";
  return "server_error";
}

function responsesFailure(detail, status) {
  const created = Math.floor(Date.now() / 1000);
  return {
    type: "response.failed",
    sequence_number: 0,
    response: {
      id: `resp_shim_error_${crypto.randomUUID().replaceAll("-", "")}`,
      object: "response",
      created_at: created,
      status: "failed",
      error: { code: responsesErrorCode(status), message: `shim: ${detail}` },
      incomplete_details: null,
      instructions: null,
      max_output_tokens: null,
      metadata: {},
      model: "unknown",
      output: [],
      parallel_tool_calls: true,
      previous_response_id: null,
      reasoning: { effort: null, summary: null },
      store: false,
      temperature: null,
      text: { format: { type: "text" } },
      tool_choice: "auto",
      tools: [],
      top_p: null,
      truncation: "disabled",
      usage: null,
      user: null,
    },
  };
}

// Once early SSE commits HTTP 200, the only remaining failure channel is a
// protocol-native terminal event. Messages and Responses use different shapes.
async function terminalErrorFrame(pathname, resp, err, signal) {
  const detail = await boundedErrorDetail(resp, err, signal);
  if (pathname === "/responses" || pathname === "/v1/responses") {
    const payload = JSON.stringify(responsesFailure(detail, resp?.status));
    return new TextEncoder().encode(`event: response.failed\ndata: ${payload}\n\n`);
  }
  const payload = JSON.stringify({ type: "error", error: { type: "api_error", message: `shim: ${detail}` } });
  return new TextEncoder().encode(`event: error\ndata: ${payload}\n\n`);
}

// Slow path body: ping through queueing, bounded attempts and bounded backoffs,
// then splice in only a real SSE stream. Client cancellation aborts that pipeline.
function keepaliveThenForward(pipeline, releaseOnce, label, tracker, pathname, signal) {
  const state = { reader: null, response: null, pending: null, idleMs: 0, keepalive: true, status: 200 };
  let settled = false;
  return new ReadableStream({
    async pull(controller) {
      try {
        if (!settled) {
          const tick = timeoutToken(PING_MS);
          const winner = await Promise.race([
            pipeline.then((resp) => ({ resp }), (err) => ({ err })),
            tick.promise,
          ]);
          tick.cancel();

          if (winner.tick) {
            state.idleMs += PING_MS;
            controller.enqueue(PING_FRAME);
            return;
          }

          settled = true;
          state.idleMs = 0;
          const { resp, err } = winner;
          state.response = resp ?? null;
          if (err || !resp.ok || !resp.body) {
            log(`${label} committed as SSE but upstream answered ${err ? `error (${err})` : resp.status}`);
            controller.enqueue(await terminalErrorFrame(pathname, err ? null : resp, err, signal));
            controller.close();
            releaseOnce();
            tracker?.finalize(resp?.status ?? 502, err ? "upstream_error" : "upstream_status");
            return;
          }
          const contentType = resp.headers.get("content-type") ?? "";
          if (!isEventStream(contentType)) {
            log(`${label} committed as SSE but upstream returned non-SSE ${contentType || "content"}`);
            await closeResponse(resp, new Error("non-SSE success body"));
            controller.enqueue(await terminalErrorFrame(pathname, null, new Error("upstream returned a non-SSE success body"), signal));
            controller.close();
            releaseOnce();
            tracker?.finalize(resp.status, "upstream_protocol");
            return;
          }
          state.status = resp.status;
          state.reader = resp.body.getReader();
        }
        await pumpStep(state, controller, releaseOnce, label, tracker);
      } catch (err) {
        releaseOnce();
        tracker?.finalize(state.status, signal?.aborted ? "client_cancel" : "stream_error");
        controller.error(err);
      }
    },
    cancel(reason) {
      abortResponse(state.response);
      releaseOnce();
      tracker?.finalize(499, "client_cancel");
      try { state.reader?.cancel(reason); } catch {}
      pipeline.then((resp) => closeResponse(resp, reason)).catch(() => {});
    },
  });
}

export function startServer() {
  const server = Bun.serve({
    port: PORT,
    // Seconds; 255 is Bun's ceiling. With PING_MS keepalives the client socket
    // no longer goes quiet for anywhere near this long, but leave the headroom:
    // it is the last line of defence when pings are disabled.
    idleTimeout: 255,
    async fetch(req) {
    const url = new URL(req.url);
    const method = req.method;

    if (method === "GET" && url.pathname === "/_shim/health") {
      return jsonResponse({ ok: true, active, queued: waiters.length });
    }
    if (method === "GET" && url.pathname === "/_shim/stats") {
      try {
        return jsonResponse(queryStats({
          period: url.searchParams.get("period") ?? "day",
          scope: url.searchParams.get("scope") ?? "normal",
          model: url.searchParams.get("model") || null,
        }));
      } catch (err) { return jsonResponse({ error: String(err) }, 400); }
    }
    if (method === "GET" && url.pathname === "/_shim/events") {
      try {
        const limit = Math.min(500, Math.max(1, Number(url.searchParams.get("limit") ?? 50)));
        return jsonResponse(queryEvents({
          period: url.searchParams.get("period") ?? "day",
          scope: url.searchParams.get("scope") ?? "normal",
          model: url.searchParams.get("model") || null,
          limit,
        }));
      } catch (err) { return jsonResponse({ error: String(err) }, 400); }
    }

    // Health / metadata reads: straight passthrough, no permit, no retry.
    if (method === "GET" || method === "HEAD") {
      try {
        const { target, makeInit } = buildUpstream(req, undefined);
        return streamThrough(await fetch(target, makeInit(req.signal)), () => {});
      } catch (err) {
        return new Response(`shim: upstream unreachable: ${err}`, { status: 502 });
      }
    }

    // Mutating requests (POST /v1/messages …): buffer body so we can resend on
    // retry, then throttle + retry.
    const bodyBuf = await req.arrayBuffer();
    const normalized = normalizeRequestBody(url.pathname, bodyBuf, req.headers.get("content-encoding") ?? "");
    if (normalized.parseError) {
      log(`${method} ${url.pathname} could not inspect JSON (${bodyBuf.byteLength} bytes, content-type=${req.headers.get("content-type") ?? "unset"}, content-encoding=${req.headers.get("content-encoding") ?? "unset"}): ${normalized.parseError}`);
    }
    if (normalized.changed > 0) {
      log(`${method} ${url.pathname} filled ${normalized.changed} empty tool description(s): ${normalized.patched.join(", ")}`);
    }
    const traceId = req.headers.get("x-trace-id") || crypto.randomUUID();
    const meta = requestMetadata(url.pathname, normalized.inspectBody, req.headers);
    const tracker = createMetricTracker({ ...meta, traceId });
    const { target, makeInit } = buildUpstream(req, normalized.body, normalized.decoded, traceId);

    const label = `${method} ${url.pathname}`;
    // The permit is now taken INSIDE the pipeline: queue time is silent time on
    // the client socket too, so the keepalive below has to be able to cover it.
    let acquired = false;
    let released = false;
    const releaseOnce = () => { if (acquired && !released) { released = true; release(); } };

    // Queue for a permit, then talk to the upstream until a response is
    // committed. Resolves to a Response whose body has NOT been read yet, or to
    // a synthetic error Response (permit already released in that case).
    const runUpstream = async () => {
      const willQueue = active >= MAX;
      try { await acquire(req.signal); }
      catch (err) {
        tracker.finalize(499, "client_cancel");
        return new Response("client aborted", { status: 499 });
      }
      acquired = true;
      tracker.acquired();
      if (willQueue) log(`queued ${label} (${active} in-flight, ${waiters.length} waiting)`);

      for (let attempt = 0; attempt <= RETRIES; attempt++) {
        tracker.attempt();
        let resp;
        try {
          resp = await fetchAttempt(target, makeInit, req.signal);
        } catch (err) {
          if (req.signal?.aborted) {
            releaseOnce();
            tracker.finalize(499, "client_cancel");
            return new Response("client aborted", { status: 499 });
          }
          if (attempt < RETRIES) {
            const d = backoffMs(attempt);
            log(`${label} network error (${err}); retry ${attempt + 1}/${RETRIES} in ${d}ms`);
            try { await abortableSleep(d, req.signal); }
            catch {
              releaseOnce();
              tracker.finalize(499, "client_cancel");
              return new Response("client aborted", { status: 499 });
            }
            continue;
          }
          releaseOnce();
          tracker.finalize(502, "upstream_error");
          return new Response(`shim: upstream unreachable: ${err}`, { status: 502 });
        }

        // Retryable status and attempts left → back off and try again. The 403
        // arrives fast (<2s, before any body), so retrying here is safe.
        if (RETRY_STATUS.has(resp.status) && attempt < RETRIES) {
          const d = backoffMs(attempt, resp.headers.get("retry-after"));
          log(`${label} -> ${resp.status}; retry ${attempt + 1}/${RETRIES} in ${d}ms`);
          await closeResponse(resp, new Error(`retrying upstream status ${resp.status}`));
          try { await abortableSleep(d, req.signal); }
          catch {
            releaseOnce();
            tracker.finalize(499, "client_cancel");
            return new Response("client aborted", { status: 499 });
          }
          continue;
        }

        if (attempt > 0) log(`${label} -> ${resp.status} after ${attempt} retr${attempt === 1 ? "y" : "ies"}`);
        tracker.headers();
        return resp;
      }
      releaseOnce(); // unreachable (last attempt always commits) — safety net
      return new Response("shim: retries exhausted", { status: 502 });
    };

    const pipeline = runUpstream();

    // Non-streaming callers keep the original shape: one await, real status.
    const eligible = PING_MS > 0 && PING_AFTER_MS > 0 && wantsStream(normalized.inspectBody);
    if (!eligible) {
      try { return streamThrough(await pipeline, releaseOnce, label, tracker); }
      catch (err) { releaseOnce(); tracker.finalize(500, "pipeline_error"); return new Response(`shim: ${err}`, { status: 500 }); }
    }

    // Fast path — upstream answered inside the grace window, so nothing about
    // this request changes: real status, real headers, no injected frames.
    const grace = timeoutToken(PING_AFTER_MS);
    const early = await Promise.race([
      pipeline.then((resp) => ({ resp }), (err) => ({ err })),
      grace.promise,
    ]);
    grace.cancel();
    if (early.err) { releaseOnce(); tracker.finalize(500, "pipeline_error"); return new Response(`shim: ${early.err}`, { status: 500 }); }
    if (early.resp) {
      const contentType = early.resp.headers.get("content-type") ?? "";
      if (early.resp.ok && (!early.resp.body || !isEventStream(contentType))) {
        log(`${label} upstream returned non-SSE ${contentType || "content"} for a streaming request`);
        await closeResponse(early.resp, new Error("non-SSE success body"));
        releaseOnce();
        tracker.finalize(early.resp.status, "upstream_protocol");
        return new Response("shim: upstream returned a non-SSE success body", {
          status: 502,
          headers: { "content-type": "text/plain; charset=utf-8", "x-trace-id": traceId },
        });
      }
      return streamThrough(early.resp, releaseOnce, label, tracker);
    }

    // Slow path — still queued, or the model is still thinking. Commit the SSE
    // response now and start the heartbeat; the real stream is spliced in
    // underneath once the pipeline settles.
    log(`${label} silent for ${PING_AFTER_MS}ms; committing SSE early and sending keepalives`);
    return new Response(keepaliveThenForward(pipeline, releaseOnce, label, tracker, url.pathname, req.signal), {
      status: 200,
      headers: { "content-type": "text/event-stream", "cache-control": "no-cache", connection: "keep-alive", "x-trace-id": traceId },
    });
    },
  });

  log(`listening on :${server.port} -> ${UPSTREAM} (max=${MAX}, retries=${RETRIES}, backoff=${BACKOFF_MS}ms, ping=${PING_MS}ms after ${PING_AFTER_MS}ms, stall=${STALL_MS}ms)`);
  return server;
}

function cliOptions(args) {
  const out = { period: "day", scope: "normal", model: null, limit: 50, json: false };
  for (let i = 0; i < args.length; i++) {
    const value = args[i];
    if (["day", "week", "month"].includes(value)) out.period = value;
    else if (value === "--json") out.json = true;
    else if (value === "--model") out.model = args[++i];
    else if (value === "--scope") out.scope = args[++i];
    else if (value === "--limit") out.limit = Math.min(500, Math.max(1, Number(args[++i])));
    else if (value === "--runs") out.runs = Number(args[++i]);
    else if (value === "--max-output") out.maxOutput = Number(args[++i]);
    else if (value === "--concurrency") out.concurrency = Number(args[++i]);
    else if (value === "--base") out.base = args[++i];
    else throw new Error(`unknown option: ${value}`);
  }
  if (!["normal", "benchmark", "all"].includes(out.scope)) throw new Error(`invalid scope: ${out.scope}`);
  return out;
}

function n(value, digits = 1) {
  return value === null || value === undefined ? "-" : Number(value).toFixed(digits);
}

function printStats(stats) {
  console.log(`copilot-proxy stats (${stats.period}, ${stats.scope}${stats.model ? `, ${stats.model}` : ""})`);
  console.log(`  requests ${stats.requests}  success ${stats.successes}  errors ${stats.errors}  retries ${stats.retries}`);
  console.log(`  tokens   in ${stats.input_tokens}  out ${stats.output_tokens}  total ${stats.total_tokens}  AIU ${n(stats.total_aiu, 6)}`);
  console.log("  metric                    p50        p90        max");
  for (const [field, label] of [["queue_ms","queue ms"],["upstream_headers_ms","headers ms"],["first_byte_ms","first byte ms"],["stream_ms","stream ms"],["e2e_ms","end-to-end ms"],["output_tps","output tok/s"]]) {
    const row = stats.timing[field];
    console.log(`  ${label.padEnd(22)} ${n(row.p50).padStart(9)} ${n(row.p90).padStart(10)} ${n(row.max).padStart(10)}`);
  }
}

function printEvents(rows) {
  if (!rows.length) { console.log("copilot-proxy events: no matching requests"); return; }
  for (const r of rows) {
    console.log(`${new Date(r.created_at_ms).toISOString()} ${String(r.status ?? "-").padEnd(3)} ${r.scope.padEnd(9)} ${(r.model ?? "-").padEnd(22)} e2e=${n(r.e2e_ms)}ms first=${n(r.first_byte_ms)}ms out=${r.output_tokens} tps=${n(r.output_tps)} trace=${r.trace_id}`);
  }
}

async function runBenchmark(options) {
  const runs = options.runs ?? 3;
  const maxOutput = options.maxOutput ?? 256;
  const concurrency = options.concurrency ?? 1;
  if (!Number.isInteger(runs) || runs < 1 || runs > 10) throw new Error("--runs must be 1..10");
  if (!Number.isInteger(maxOutput) || maxOutput < 32 || maxOutput > 2048) throw new Error("--max-output must be 32..2048");
  if (!Number.isInteger(concurrency) || concurrency < 1 || concurrency > 4) throw new Error("--concurrency must be 1..4");
  if (!options.model) throw new Error("benchmark requires --model ID");
  const base = (options.base ?? `http://localhost:${PORT}`).replace(/\/$/, "");
  const pending = Array.from({ length: runs }, (_, index) => ({ index, traceId: crypto.randomUUID() }));
  const results = [];
  async function worker() {
    while (pending.length) {
      const job = pending.shift();
      try {
        const response = await fetch(`${base}/v1/responses`, {
          method: "POST",
          headers: { "content-type": "application/json", "x-copilot-benchmark": "1", "x-trace-id": job.traceId },
          body: JSON.stringify({
            model: options.model, stream: true, max_output_tokens: maxOutput,
            input: `Return exactly ${Math.min(64, maxOutput)} lowercase words separated by spaces. Benchmark nonce ${job.traceId}.`,
          }),
        });
        await response.arrayBuffer();
        results.push({ run: job.index + 1, trace_id: job.traceId, status: response.status });
      } catch (err) {
        results.push({ run: job.index + 1, trace_id: job.traceId, status: null, error: String(err) });
      }
    }
  }
  await Promise.all(Array.from({ length: concurrency }, worker));
  await abortableSleep(300);
  const traceSet = new Set(results.map((r) => r.trace_id));
  const metrics = enrichRows(metricRows({ period: "day", scope: "benchmark", model: options.model, limit: 500 }))
    .filter((r) => traceSet.has(r.trace_id));
  const byTrace = new Map(metrics.map((r) => [r.trace_id, r]));
  return {
    model: options.model, runs, max_output: maxOutput, concurrency,
    results: results.sort((a, b) => a.run - b.run).map((r) => ({ ...r, metrics: byTrace.get(r.trace_id) ?? null })),
  };
}

async function runCli(command, args) {
  const options = cliOptions(args);
  if (command === "stats") {
    const result = queryStats(options);
    options.json ? console.log(JSON.stringify(result)) : printStats(result);
  } else if (command === "events") {
    const result = queryEvents(options);
    options.json ? console.log(JSON.stringify(result)) : printEvents(result);
  } else if (command === "bench") {
    const result = await runBenchmark(options);
    if (options.json) console.log(JSON.stringify(result));
    else {
      console.log(`copilot-proxy bench: ${result.model}, ${result.runs} run(s), concurrency ${result.concurrency}`);
      for (const row of result.results) {
        const m = row.metrics;
        console.log(`  #${row.run} HTTP ${row.status ?? "ERR"}  first=${n(m?.first_byte_ms)}ms  e2e=${n(m?.e2e_ms)}ms  out=${m?.output_tokens ?? 0}  tok/s=${n(m?.output_tps)}${row.error ? `  ${row.error}` : ""}`);
      }
    }
  } else throw new Error(`unknown command: ${command}`);
}

if (import.meta.main) {
  const command = Bun.argv[2];
  if (["stats", "events", "bench"].includes(command)) {
    runCli(command, Bun.argv.slice(3)).catch((err) => { console.error(`copilot-shim: ${err.message ?? err}`); process.exitCode = 2; });
  } else startServer();
}
