#!/usr/bin/env bun
import { Database } from "bun:sqlite";
import { existsSync, mkdirSync, readFileSync, renameSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { createHash } from "node:crypto";
// copilot-throttle-shim.js — a tiny streaming reverse proxy that sits IN FRONT
// of the local copilot-api fork (default :4141). It provides the request
// compatibility fixes shared by Codex/Claude Code and stops GitHub's enterprise
// Copilot backend from 403-ing ("Forbidden") on bursts of premium requests,
// WITHOUT adding latency to normal single-agent flow.
//
//   agent client ─▶ shim (:4142) ─▶ copilot-api fork (:4141) ─▶ Copilot backend
//                    │
//                    ├─ adaptive semaphore: starts at MIN concurrent upstream
//                    │   POSTs and grows toward MAX only under clean queue
//                    │   pressure; 403/429 returns it to MIN for a cooldown.
//                    │   Bursts queue instead of hitting the backend together.
//                    │
//                    ├─ one bounded replay of classified, completed transient
//                    │   errors before model output. Ambiguous local connection
//                    │   failures quarantine admission instead of replaying work.
//                    │   GET/HEAD (health, /v1/models)
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
//   COPILOT_SHIM_HOST       listen address                 (default 127.0.0.1)
//   COPILOT_SHIM_UPSTREAM   upstream base URL              (default http://localhost:4141)
//   COPILOT_SHIM_MIN        adaptive concurrency floor       (default 4)
//   COPILOT_SHIM_MAX        adaptive concurrency ceiling     (default 8)
//   COPILOT_SHIM_RETRIES    retry attempts on transient    (default 1, maximum 3)
//   COPILOT_SHIM_BACKOFF_MS base backoff ms, doubles/try   (default 500)
//   COPILOT_SHIM_PING_MS    keepalive interval, 0=off      (default 15000)
//   COPILOT_SHIM_PING_AFTER_MS  silence tolerated before the SSE response is
//                           committed and pings start      (default 10000)
//   COPILOT_SHIM_STALL_MS   finite outer inactivity fallback (default 330000).
//                           A local timeout is not replayed: execution is unknown.
//   COPILOT_SHIM_BACKEND_HEADERS_TIMEOUT_MS / _BACKEND_INACTIVITY_TIMEOUT_MS
//                           effective backend deadlines (default 300000 each)
//   COPILOT_SHIM_BACKEND_VERSION actual launched package version (else unknown)
//   COPILOT_SHIM_METRICS_DB request timing database (default:
//                           $XDG_STATE_HOME/copilot-proxy/metrics.sqlite)
//   COPILOT_API_SQLITE_DB_PATH upstream token database override

const PORT = Number(process.env.COPILOT_SHIM_PORT ?? 4142);
const HOST = process.env.COPILOT_SHIM_HOST || "127.0.0.1";
const UPSTREAM = (process.env.COPILOT_SHIM_UPSTREAM ?? "http://localhost:4141").replace(/\/+$/, "");
const SHIM_VERSION = createHash("sha256").update(readFileSync(import.meta.path)).digest("hex");
const BACKEND_VERSION = /^[\w.+-]{1,80}$/.test(process.env.COPILOT_SHIM_BACKEND_VERSION ?? "")
  ? process.env.COPILOT_SHIM_BACKEND_VERSION : "unknown";
const HARD_MAX_CONCURRENCY = 32;
const positiveInt = (value, fallback, max = Number.MAX_SAFE_INTEGER) => {
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? Math.min(parsed, max) : fallback;
};
const STARTUP_MAX = positiveInt(process.env.COPILOT_SHIM_MAX, 8, HARD_MAX_CONCURRENCY);
const STARTUP_MIN = Math.min(STARTUP_MAX,
  positiveInt(process.env.COPILOT_SHIM_MIN, 4, HARD_MAX_CONCURRENCY));
const retrySetting = Number(process.env.COPILOT_SHIM_RETRIES ?? 1);
const RETRIES = Number.isInteger(retrySetting) && retrySetting >= 0 ? Math.min(retrySetting, 3) : 1;
const BACKOFF_MS = Math.max(0, Number(process.env.COPILOT_SHIM_BACKOFF_MS ?? 500));
const PING_MS = Math.max(0, Number(process.env.COPILOT_SHIM_PING_MS ?? 15000));
const PING_AFTER_MS = Math.max(0, Number(process.env.COPILOT_SHIM_PING_AFTER_MS ?? 10000));
const STALL_MS = positiveInt(process.env.COPILOT_SHIM_STALL_MS, 330000);
const BACKEND_HEADERS_MS = positiveInt(process.env.COPILOT_SHIM_BACKEND_HEADERS_TIMEOUT_MS, 300000);
const BACKEND_INACTIVITY_MS = positiveInt(process.env.COPILOT_SHIM_BACKEND_INACTIVITY_TIMEOUT_MS, 300000);
const RETRY_STATUS = new Set([500, 502, 503]);
const REQUEST_BODY_TIMEOUT_STATUS = 408;
const REQUEST_BODY_TIMEOUT_RETRIES = 1;
const MAX_BACKOFF_MS = 30000;
const MAX_RETRY_AFTER_MS = 300000;
const ADAPT_SUCCESS_THRESHOLD = 32;
const ADAPT_INCREASE_INTERVAL_MS = 60000;
const ADAPT_THROTTLE_COOLDOWN_MS = 300000;
const ERROR_BODY_TIMEOUT_MS = 2000;
const ERROR_BODY_MAX_BYTES = 2048;
const JSON_OBSERVE_MAX_BYTES = 1024 * 1024;
const RETENTION_MS = 90 * 86400 * 1000;
const FAST_ROUTING_TTL_MS = 5 * 60 * 1000;
const FAST_ROUTING_TIMEOUT_MS = 2000;

function errorSummary(error) {
  return String(error?.message ?? error ?? "unknown error").replace(/\s+/g, " ").slice(0, 500);
}

function logNonFatal(context, error) {
  try { console.error(new Date().toISOString(), "[shim]", `${context}: ${errorSummary(error)}`); }
  catch {}
}

// Stream cancellation is cleanup. Neither a synchronous throw nor a rejected
// cancel Promise may become an unhandled rejection in the Bun server process.
export function settleCancellation(target, reason, context = "stream cancellation failed") {
  try {
    return Promise.resolve(target?.cancel(reason)).catch((error) => logNonFatal(context, error));
  } catch (error) {
    logNonFatal(context, error);
    return Promise.resolve();
  }
}

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

export function admissionBarrierPath() { return `${metricsDbPath()}.admission.json`; }

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
  // Additive migration: historical rows remain explicitly unclassified.
  const columns = new Set(db.query("PRAGMA table_info(request_metrics)").all().map((row) => row.name));
  for (const [name, type] of Object.entries({
    outcome_version: "INTEGER", terminal_event: "TEXT", terminal_error_category: "TEXT",
    request_kind: "TEXT", request_kind_source: "TEXT", received_bytes: "INTEGER",
    forwarded_bytes: "INTEGER", timeout_owner: "TEXT", drain_outcome: "TEXT",
    backend_version: "TEXT", shim_version: "TEXT", reasoning_effort: "TEXT",
  })) {
    if (!columns.has(name)) db.exec(`ALTER TABLE request_metrics ADD COLUMN ${name} ${type}`);
  }
  db.exec(`CREATE TABLE IF NOT EXISTS request_attempts (
    trace_id TEXT NOT NULL, attempt INTEGER NOT NULL, started_at_ms INTEGER NOT NULL,
    ended_at_ms INTEGER, status INTEGER, outcome TEXT, timeout_owner TEXT,
    PRIMARY KEY(trace_id, attempt)
  );`);
  return db;
}

export function pruneMetrics(db, now = Date.now()) {
  db.query("DELETE FROM request_attempts WHERE started_at_ms < ?").run(now - RETENTION_MS);
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
  const responses = /^\/(?:v1\/)?responses(?:\/compact)?$/.test(pathname);
  const explicitCompact = pathname.endsWith("/responses/compact")
    || payload.compaction_trigger != null || payload.metadata?.compaction_trigger != null
    || headers.has("compaction_trigger");
  return {
    endpoint: pathname,
    model: typeof payload?.model === "string" ? payload.model : null,
    streaming: payload?.stream === true,
    scope: headers.get("x-copilot-benchmark") === "1" ? "benchmark" : "normal",
    request_kind: explicitCompact ? "compact" : responses ? "responses" : pathname.includes("messages") ? "messages" : "unknown",
    request_kind_source: pathname.endsWith("/responses/compact") ? "endpoint"
      : explicitCompact ? "protocol_metadata" : responses ? "endpoint_compact_unknown" : "endpoint",
    reasoning_effort: ["none", "minimal", "low", "medium", "high", "xhigh", "max"].includes(payload.reasoning?.effort)
      ? payload.reasoning.effort : null,
  };
}

export function createMetricTracker(meta, db = undefined, clock = () => performance.now()) {
  const wall = Date.now();
  const started = clock();
  let metricDb = db;
  if (metricDb === undefined) {
    try { metricDb = getMetricsDb(); }
    catch (error) { metricDb = null; logNonFatal("metrics disabled", error); }
  }
  let permitAt = null;
  let firstAt = null;
  let attempts = 0;
  let attemptFinalized = false;
  let finished = false;
  const state = { ...meta };
  return {
    traceId: meta.traceId,
    attempt() {
      attempts++;
      attemptFinalized = false;
      try {
        metricDb?.query("INSERT OR IGNORE INTO request_attempts (trace_id,attempt,started_at_ms) VALUES (?,?,?)")
          .run(meta.traceId, attempts, Date.now());
      } catch (error) { logNonFatal("attempt metrics write failed", error); }
      return attempts;
    },
    attemptOutcome(status, outcome, timeoutOwner = null) {
      if (attemptFinalized || !attempts) return;
      attemptFinalized = true;
      try {
        metricDb?.query("UPDATE request_attempts SET ended_at_ms=?,status=?,outcome=?,timeout_owner=? WHERE trace_id=? AND attempt=?")
          .run(Date.now(), status, outcome, timeoutOwner, meta.traceId, attempts);
      } catch (error) { logNonFatal("attempt metrics write failed", error); }
    },
    annotate(values) {
      Object.assign(state, values);
      // A protocol error may be returned while its unexpected body drains.
      // Update cleanup diagnostics without rewriting the client-visible result.
      if (finished && Object.hasOwn(values, "drain_outcome")) {
        try {
          metricDb?.query("UPDATE request_metrics SET drain_outcome=?,timeout_owner=COALESCE(?,timeout_owner) WHERE trace_id=?")
            .run(values.drain_outcome, values.timeout_owner ?? null, meta.traceId);
        } catch (error) { logNonFatal("drain metrics write failed", error); }
      }
    },
    acquired() { if (permitAt === null) permitAt = clock(); },
    firstByte() { if (firstAt === null) firstAt = clock(); },
    finalize(status, errorKind = null) {
      if (finished) return;
      finished = true;
      try {
        const ended = clock();
        metricDb?.query(`INSERT OR IGNORE INTO request_metrics
          (trace_id,created_at_ms,endpoint,model,scope,streaming,status,attempts,retries,
           queue_ms,upstream_headers_ms,first_byte_ms,stream_ms,e2e_ms,error_kind,
           outcome_version,terminal_event,terminal_error_category,request_kind,request_kind_source,
           received_bytes,forwarded_bytes,timeout_owner,drain_outcome,backend_version,shim_version,reasoning_effort)
          VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`).run(
            state.traceId, wall, state.endpoint, state.model, state.scope,
            state.streaming ? 1 : 0, status, attempts, Math.max(0, attempts - 1),
            permitAt === null ? null : permitAt - started,
            permitAt === null || state.headersAt === undefined ? null : state.headersAt - permitAt,
            firstAt === null ? null : firstAt - started,
            firstAt === null ? null : ended - firstAt,
            ended - started, errorKind,
            2, state.terminal_event ?? null, state.terminal_error_category ?? null,
            state.request_kind ?? "unknown", state.request_kind_source ?? "unknown",
            state.received_bytes ?? null, state.forwarded_bytes ?? null,
            state.timeout_owner ?? null, state.drain_outcome ?? null,
            BACKEND_VERSION, SHIM_VERSION, state.reasoning_effort ?? null,
          );
      } catch (error) { logNonFatal("metrics write failed", error); }
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
  const clientCancels = rows.filter((r) => r.error_kind === "client_cancel").length;
  const unverified = (r) => r.error_kind === "response_unverified"
    || (!r.outcome_version && /^\/(?:v1\/)?responses(?:\/compact)?$/.test(r.endpoint)
      && r.status >= 200 && r.status < 400 && !r.error_kind);
  const errors = rows.filter((r) => !unverified(r) && (r.error_kind || !(r.status >= 200 && r.status < 400))).length;
  return {
    period: options.period ?? "day",
    scope: options.scope ?? "normal",
    model: options.model ?? null,
    requests: rows.length,
    successes: rows.filter((r) => r.status >= 200 && r.status < 400 && !r.error_kind && !unverified(r)).length,
    unverified: rows.filter(unverified).length,
    errors,
    client_cancels: clientCancels,
    upstream_errors: errors - clientCancels,
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

const fastRouting = {
  state: "cold",
  mappings: {},
  refreshedAtMs: null,
  checkedAtMs: 0,
  error: null,
  pending: null,
};
const fastFallbackWarnings = new Set();

function responsesCapable(model) {
  if (!model || typeof model !== "object") return false;
  if ((model.policy?.state ?? "enabled") === "disabled") return false;
  if (model.model_picker_enabled === false) return false;
  if ((model.capabilities?.type ?? "chat") === "embeddings") return false;
  const endpoints = model.supported_endpoints;
  return !Array.isArray(endpoints)
    || endpoints.includes("/responses")
    || endpoints.includes("ws:/responses");
}

// GitHub exposes fast inference as a distinct model id while Codex expresses
// the same request as service_tier=fast. Derive pairs from the live catalog so
// this bridge follows entitlement/policy changes instead of pinning one model.
export function buildFastModelMappings(catalog) {
  const models = Array.isArray(catalog?.data) ? catalog.data.filter(responsesCapable) : [];
  const byId = new Map(models
    .filter((model) => typeof model.id === "string" && model.id)
    .map((model) => [model.id, model]));
  const mappings = {};
  for (const fast of models) {
    if (typeof fast.id !== "string" || !fast.id.endsWith("-fast")) continue;
    const standardId = fast.id.slice(0, -"-fast".length);
    const standard = byId.get(standardId);
    if (!standard) continue;
    mappings[standardId] = fast.id;
    if (typeof standard.claude_model_id === "string"
        && typeof fast.claude_model_id === "string") {
      mappings[standard.claude_model_id] = fast.claude_model_id;
    }
  }
  return Object.fromEntries(Object.entries(mappings).sort(([a], [b]) => a.localeCompare(b)));
}

function fastRoutingSnapshot() {
  return {
    state: fastRouting.state,
    mappings: { ...fastRouting.mappings },
    refreshed_at_ms: fastRouting.refreshedAtMs,
    checked_at_ms: fastRouting.checkedAtMs || null,
    ttl_ms: FAST_ROUTING_TTL_MS,
    error: fastRouting.error,
  };
}

function fastRoutingNeedsRefresh(now = Date.now()) {
  return !fastRouting.checkedAtMs || now - fastRouting.checkedAtMs >= FAST_ROUTING_TTL_MS;
}

async function fetchFastRoutingCatalog() {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), FAST_ROUTING_TIMEOUT_MS);
  try {
    const response = await fetch(`${UPSTREAM}/v1/models`, {
      headers: { "user-agent": "copilot-throttle-shim/fast-routing" },
      signal: ctl.signal,
    });
    if (!response.ok) throw new Error(`catalog returned HTTP ${response.status}`);
    return await response.json();
  } finally { clearTimeout(timer); }
}

async function refreshFastRouting(force = false) {
  if (fastRouting.pending) return fastRouting.pending;
  if (!force && !fastRoutingNeedsRefresh()) return fastRoutingSnapshot();
  fastRouting.state = Object.keys(fastRouting.mappings).length ? "refreshing" : "loading";
  fastRouting.pending = (async () => {
    fastRouting.checkedAtMs = Date.now();
    try {
      const mappings = buildFastModelMappings(await fetchFastRoutingCatalog());
      fastRouting.mappings = mappings;
      fastRouting.refreshedAtMs = Date.now();
      fastRouting.error = null;
      fastRouting.state = Object.keys(mappings).length ? "ready" : "unavailable";
      fastFallbackWarnings.clear();
      log(`fast routing ${fastRouting.state}: ${Object.entries(mappings)
        .map(([standard, fast]) => `${standard}->${fast}`).join(", ") || "no eligible sibling"}`);
    } catch (error) {
      fastRouting.error = errorSummary(error);
      fastRouting.state = Object.keys(fastRouting.mappings).length ? "stale" : "error";
      logNonFatal(`fast routing ${fastRouting.state}`, error);
    }
    return fastRoutingSnapshot();
  })().finally(() => { fastRouting.pending = null; });
  return fastRouting.pending;
}

const validLimit = (value, name) => {
  if (!Number.isInteger(value) || value < 1 || value > HARD_MAX_CONCURRENCY) {
    throw new Error(`${name} must be an integer from 1 to ${HARD_MAX_CONCURRENCY}`);
  }
  return value;
};

export function createAdaptiveLimiter({
  min = STARTUP_MIN,
  max = STARTUP_MAX,
  initial = min,
  successThreshold = ADAPT_SUCCESS_THRESHOLD,
  increaseIntervalMs = ADAPT_INCREASE_INTERVAL_MS,
  throttleCooldownMs = ADAPT_THROTTLE_COOLDOWN_MS,
  clock = () => Date.now(),
  onChange = () => {},
} = {}) {
  let floor = validLimit(min, "min");
  let ceiling = validLimit(max, "max");
  if (floor > ceiling) throw new Error("min must not exceed max");
  let limit = Math.max(floor, Math.min(validLimit(initial, "limit"), ceiling));
  const startupFloor = floor;
  const startupCeiling = ceiling;
  const startupLimit = limit;
  let pressureSuccesses = 0;
  let pressureSeen = false;
  let cooldownUntil = 0;
  let lastChangeAt = clock();
  let throttleEvents = 0;
  let lastThrottleStatus = null;

  const changeLimit = (next, reason) => {
    const bounded = Math.max(floor, Math.min(next, ceiling));
    if (bounded === limit) return false;
    const previous = limit;
    limit = bounded;
    lastChangeAt = clock();
    onChange({ previous, limit, reason });
    return true;
  };

  const snapshot = () => ({
    limit,
    min: floor,
    max: ceiling,
    adaptive: floor !== ceiling,
    pressure_successes: pressureSuccesses,
    successes_to_increase: limit >= ceiling
      ? 0 : Math.max(0, successThreshold - pressureSuccesses),
    cooldown_ms_remaining: Math.max(0, cooldownUntil - clock()),
    throttle_events: throttleEvents,
    last_throttle_status: lastThrottleStatus,
  });

  return {
    get limit() { return limit; },
    noteQueued() { pressureSeen = true; },
    observeStatus(status, underPressure = false) {
      const now = clock();
      if (status === 403 || status === 429) {
        throttleEvents++;
        lastThrottleStatus = status;
        pressureSuccesses = 0;
        pressureSeen = false;
        cooldownUntil = Math.max(cooldownUntil, now + throttleCooldownMs);
        changeLimit(floor, `upstream-${status}`);
        return snapshot();
      }
      if (!(status >= 200 && status < 400) || !(underPressure || pressureSeen)) {
        return snapshot();
      }
      if (now < cooldownUntil) return snapshot();
      if (limit >= ceiling) {
        pressureSuccesses = 0;
        pressureSeen = false;
        return snapshot();
      }
      pressureSuccesses++;
      if (pressureSuccesses >= successThreshold
          && now - lastChangeAt >= increaseIntervalMs) {
        pressureSuccesses = 0;
        pressureSeen = false;
        changeLimit(limit + 1, "clean-queue-pressure");
      }
      return snapshot();
    },
    configure(patch = {}) {
      const nextFloor = patch.min === undefined ? floor : validLimit(patch.min, "min");
      const nextCeiling = patch.max === undefined ? ceiling : validLimit(patch.max, "max");
      if (nextFloor > nextCeiling) throw new Error("min must not exceed max");
      const nextLimit = patch.limit === undefined
        ? Math.max(nextFloor, Math.min(limit, nextCeiling))
        : validLimit(patch.limit, "limit");
      if (nextLimit < nextFloor || nextLimit > nextCeiling) {
        throw new Error("limit must be between min and max");
      }
      floor = nextFloor;
      ceiling = nextCeiling;
      pressureSuccesses = 0;
      pressureSeen = false;
      cooldownUntil = 0;
      lastChangeAt = clock();
      changeLimit(nextLimit, "live-config");
      return snapshot();
    },
    reset() {
      floor = startupFloor;
      ceiling = startupCeiling;
      pressureSuccesses = 0;
      pressureSeen = false;
      cooldownUntil = 0;
      lastChangeAt = clock();
      changeLimit(startupLimit, "live-reset");
      return snapshot();
    },
    snapshot,
  };
}

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
      settleCancellation(resp.body, reason, "response body cancellation failed"),
      deadline.promise,
    ]);
  } finally { deadline.cancel(); }
}

// ---- adaptive semaphore (canceled waiters are removed eagerly) ----------------
let active = 0;
const waiters = [];
const leases = new Set();
let recoveryRequired = false;
let admissionLoaded = false;

function loadAdmissionBarrier() {
  if (admissionLoaded) return;
  admissionLoaded = true;
  const path = admissionBarrierPath();
  if (!existsSync(path)) return;
  // Never guess that an old/corrupt marker is harmless. A wrapper can remove it
  // only after stopping this shim and confirming the backend process exited.
  recoveryRequired = true;
  let count = 1;
  try {
    if (statSync(path).size > 65536) throw new Error("oversized admission marker");
    const marker = JSON.parse(readFileSync(path, "utf8"));
    if (marker.version !== 1 || !Array.isArray(marker.leases) || !marker.leases.length) throw new Error("invalid admission marker");
    count = Math.min(marker.leases.length, HARD_MAX_CONCURRENCY);
  } catch (error) { logNonFatal("unclean admission marker requires controlled recovery", error); }
  for (let i = 0; i < count; i++) leases.add({ phase: "unknown", dispatched: true, id: `recovered-${i}` });
  active += count;
  log("unclean shim generation: inference blocked until backend and shim are stopped together and admission is recovered");
}

function persistAdmission() {
  if (recoveryRequired) return; // never overwrite evidence from the old process
  const path = admissionBarrierPath();
  const outstanding = [...leases].filter((lease) => lease.dispatched || lease.phase === "unknown")
    .map((lease) => ({ id: lease.id, phase: lease.phase === "unknown" ? "unknown" : "active" }));
  if (!outstanding.length) {
    try { unlinkSync(path); } catch (error) { if (error.code !== "ENOENT") throw error; }
    return;
  }
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = `${path}.${process.pid}.${crypto.randomUUID()}.tmp`;
  try {
    writeFileSync(temporary, JSON.stringify({ version: 1, upstream: UPSTREAM, leases: outstanding }), { mode: 0o600 });
    renameSync(temporary, path);
  } catch (error) {
    recoveryRequired = true;
    try { unlinkSync(temporary); } catch {}
    throw new Error(`cannot persist admission safely: ${errorSummary(error)}`);
  }
}
class AdmissionUnknownError extends Error {
  constructor() {
    super("shim admission is quarantined: backend execution is unknown; wait for tracked streams to settle, then restart the backend and shim together");
    this.name = "AdmissionUnknownError";
  }
}
function unknownCount() { return [...leases].filter((lease) => lease.phase === "unknown").length; }
function admissionUnavailable() { return recoveryRequired || unknownCount() >= limiter.limit; }

// A disconnected downstream does not imply that copilot-api stopped its work.
// Unknown leases survive every limiter reset; only controlled process recovery
// may clear them. Restarting just the shim cannot establish backend quiescence.
function createLease(signal, tracker) {
  const lease = {
    id: crypto.randomUUID(),
    phase: "queue", cancelled: Boolean(signal?.aborted), released: false,
    onCancel: null, dispatched: false,
    admitted() { lease.phase = "active"; leases.add(lease); },
    dispatch() {
      lease.dispatched = true;
      if (lease.cancelled) lease.phase = "draining";
      persistAdmission();
    },
    settled() {
      lease.dispatched = false;
      try { persistAdmission(); }
      catch (error) {
        recoveryRequired = true;
        logNonFatal("completed work could not clear admission marker; controlled recovery required", error);
      }
    },
    release() {
      if (lease.released || lease.phase === "unknown") return;
      lease.released = true;
      leases.delete(lease);
      signal?.removeEventListener("abort", cancel);
      if (lease.phase !== "queue") release();
      lease.phase = "done";
    },
    quarantine(owner) {
      if (lease.released || lease.phase === "unknown") return;
      lease.phase = "unknown";
      try { persistAdmission(); } catch (error) { logNonFatal("admission persistence failed", error); }
      tracker?.annotate({ timeout_owner: owner, drain_outcome: "unknown" });
      log("backend execution unknown; admission retained until controlled backend and shim recovery", tracker?.traceId ?? "");
      drainWaiters();
    },
    cancel: () => cancel(),
  };
  function cancel() {
    lease.cancelled = true;
    if (lease.dispatched && lease.phase !== "unknown" && !lease.released) {
      lease.phase = "draining";
      tracker?.annotate({ drain_outcome: "draining" });
    }
    lease.onCancel?.();
  }
  signal?.addEventListener("abort", cancel, { once: true });
  return lease;
}
const limiter = createAdaptiveLimiter({
  onChange({ previous, limit, reason }) {
    log(`limiter ${previous} -> ${limit} (${reason}; active=${active}, queued=${waiters.length})`);
    drainWaiters();
  },
});

function drainWaiters() {
  if (admissionUnavailable()) {
    for (const waiter of waiters.splice(0)) {
      waiter.signal?.removeEventListener("abort", waiter.onAbort);
      waiter.reject(new AdmissionUnknownError());
    }
    return;
  }
  while (active < limiter.limit && waiters.length) {
    const next = waiters.shift();
    next.signal?.removeEventListener("abort", next.onAbort);
    if (next.signal?.aborted) { next.reject(abortError()); continue; }
    active++;
    next.resolve();
  }
}

function acquire(signal) {
  if (signal?.aborted) return Promise.reject(abortError());
  if (admissionUnavailable()) return Promise.reject(new AdmissionUnknownError());
  if (active < limiter.limit) { active++; return Promise.resolve(); }
  limiter.noteQueued();
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
  drainWaiters();
}

function backoffMs(attempt, retryAfter) {
  const seconds = Number(retryAfter);
  if (Number.isFinite(seconds) && seconds >= 0 && retryAfter != null && retryAfter !== "") return seconds * 1000;
  const date = retryAfter ? Date.parse(retryAfter) : NaN;
  if (Number.isFinite(date)) return Math.max(0, date - Date.now());
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

export function applyFastModelRouting(payload, mappings = {}) {
  const tier = typeof payload?.service_tier === "string"
    ? payload.service_tier.trim().toLowerCase() : null;
  const requested = tier === "fast" || tier === "priority" || tier === "ultrafast";
  const model = typeof payload?.model === "string" ? payload.model : null;
  const targets = new Set(Object.values(mappings));
  const alreadyFast = model !== null && targets.has(model);
  const target = model === null ? null : mappings[model] ?? null;
  let changed = 0;
  let routed = false;
  let fallback = false;

  if (requested) {
    if ((tier === "fast" || tier === "priority") && target) {
      payload.model = target;
      changed++;
      routed = true;
    } else if (!alreadyFast) {
      fallback = true;
    }
    if (Object.prototype.hasOwnProperty.call(payload, "service_tier")) {
      delete payload.service_tier;
      changed++;
    }
  }
  return { requested, requestedTier: tier, model, target, routed, alreadyFast, fallback, changed };
}

export function normalizeRequestBody(pathname, bodyBuf, contentEncoding = "", fastMappings = {}) {
  if (pathname !== "/responses" && pathname !== "/v1/responses") {
    return {
      body: bodyBuf, inspectBody: bodyBuf, changed: 0, toolDescriptionsChanged: 0,
      patched: [], routing: { requested: false }, parseError: null, decoded: false,
    };
  }
  try {
    const encoding = contentEncoding.trim().toLowerCase();
    const decodedBody = encoding === "zstd" ? Bun.zstdDecompressSync(new Uint8Array(bodyBuf)) : bodyBuf;
    const payload = JSON.parse(new TextDecoder().decode(decodedBody));
    const tools = normalizeResponsesToolDescriptions(payload);
    const routing = applyFastModelRouting(payload, fastMappings);
    const changed = tools.changed + routing.changed;
    if (changed === 0) {
      return {
        body: bodyBuf, inspectBody: decodedBody, changed, toolDescriptionsChanged: tools.changed,
        patched: tools.patched, routing, parseError: null, decoded: false,
      };
    }
    const body = JSON.stringify(payload);
    return {
      body, inspectBody: body, changed, toolDescriptionsChanged: tools.changed,
      patched: tools.patched, routing, parseError: null, decoded: encoding === "zstd",
    };
  } catch (error) {
    // Preserve malformed/non-JSON requests verbatim; the upstream remains the
    // authority for their validation and error response.
    return {
      body: bodyBuf, inspectBody: bodyBuf, changed: 0, toolDescriptionsChanged: 0,
      patched: [], routing: { requested: false }, parseError: String(error), decoded: false,
    };
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

function limiterStatus() {
  return {
    ...limiter.snapshot(),
    active,
    draining: [...leases].filter((lease) => lease.phase === "draining").length,
    unknown: unknownCount(),
    admission_available: !admissionUnavailable(),
    recovery_required: recoveryRequired || unknownCount() > 0,
    recovery: recoveryRequired || unknownCount() ? "settle tracked streams, then restart backend and shim together" : null,
    queued: waiters.length,
    startup: { min: STARTUP_MIN, max: STARTUP_MAX },
    versions: { backend: BACKEND_VERSION, shim: SHIM_VERSION },
    timeouts: {
      shim_fallback_ms: STALL_MS, backend_headers_ms: BACKEND_HEADERS_MS,
      backend_inactivity_ms: BACKEND_INACTIVITY_MS,
      compatible: STALL_MS > Math.max(BACKEND_HEADERS_MS, BACKEND_INACTIVITY_MS),
    },
  };
}

function isLoopbackRequest(req, server) {
  const address = server.requestIP(req)?.address ?? "";
  return address === "127.0.0.1" || address === "::1" || address === "::ffff:127.0.0.1";
}

async function updateLimiter(req) {
  let payload;
  try { payload = await req.json(); }
  catch { return jsonResponse({ error: "request body must be JSON" }, 400); }
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    return jsonResponse({ error: "request body must be a JSON object" }, 400);
  }
  try {
    if (payload.reset === true) {
      if (Object.keys(payload).some((key) => key !== "reset")) {
        throw new Error("reset cannot be combined with other settings");
      }
      limiter.reset();
    }
    else {
      const allowed = new Set(["min", "max", "limit"]);
      const unknown = Object.keys(payload).filter((key) => !allowed.has(key));
      if (unknown.length) throw new Error(`unknown setting(s): ${unknown.join(", ")}`);
      if (Object.keys(payload).length === 0) throw new Error("provide min, max, limit, or reset");
      limiter.configure(payload);
    }
    log(`limiter live config -> ${JSON.stringify(limiterStatus())}`);
    return jsonResponse(limiterStatus());
  } catch (err) {
    return jsonResponse({ error: err.message ?? String(err), ...limiterStatus() }, 400);
  }
}

class UpstreamUnknownError extends Error {
  constructor(message, owner) { super(message); this.name = "UpstreamUnknownError"; this.owner = owner; }
}

// After dispatch, downstream cancellation drains this physical request. Only
// the later local watchdog aborts it, and that leaves execution quarantined.
function fetchAttempt(target, makeInit, lease, attempt) {
  const ctl = new AbortController();
  let stalled = false;
  const init = makeInit(ctl.signal);
  init.headers.set("x-copilot-shim-attempt", String(attempt));
  lease.dispatch();
  const timer = setTimeout(() => { stalled = true; ctl.abort(); }, STALL_MS);
  return fetch(target, init).then(
    (resp) => {
      clearTimeout(timer);
      responseAborters.set(resp, () => ctl.abort());
      return resp;
    },
    (err) => {
      clearTimeout(timer);
      throw new UpstreamUnknownError(stalled
        ? `upstream sent no response headers in ${STALL_MS}ms; execution is unknown`
        : `backend connection failed; execution is unknown (${errorSummary(err)})`,
      stalled ? "shim_headers" : "shim_transport");
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
function observeResponsesTerminal(state, value) {
  const observed = state.responsesTerminal;
  if (observed && !observed.kind) {
    const text = observed.decoder.decode(value, { stream: true });
    // Keep only a bounded SSE field line, never a transcript. A terminal field
    // is accepted when its event's blank line arrives, not on a truncated field.
    for (const char of text) {
      if (char !== "\n") {
        if (observed.line.length < 512) observed.line += char;
        else observed.overflow = true;
        continue;
      }
      const line = observed.line.replace(/\r$/, "");
      if (line === "" && !observed.overflow) {
        if (observed.event && observed.data) observed.kind = observed.event;
        observed.event = null; observed.data = false;
      } else if (line.startsWith("event:") && !observed.overflow) {
        const event = line.slice(6).trim();
        observed.event = /^response\.(completed|failed|incomplete)$/.test(event) ? event : null;
      } else if (line.startsWith("data:")) {
        observed.data = true;
        if (!observed.event && !observed.overflow) {
          try {
            const event = JSON.parse(line.slice(5)).type;
            if (/^response\.(completed|failed|incomplete)$/.test(event)) observed.event = event;
          } catch {}
        }
      }
      observed.line = ""; observed.overflow = false;
      if (observed.kind) break;
    }
  }
  if (state.jsonInspection && !state.jsonInspection.overflow) {
    state.jsonInspection.bytes += value.byteLength;
    if (state.jsonInspection.bytes > JSON_OBSERVE_MAX_BYTES) {
      state.jsonInspection.overflow = true;
      state.jsonInspection.text = "";
    } else state.jsonInspection.text += state.jsonInspection.decoder.decode(value, { stream: true });
  }
}

export function classifyResponsesJson(payload, pathname = "/responses") {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) return "unverified";
  if (payload.error || payload.status === "failed") return "failed";
  if (payload.status === "incomplete") return "incomplete";
  if (payload.status === "completed") return "completed";
  if (pathname.endsWith("/compact") && payload.object === "response.compaction"
      && typeof payload.id === "string" && Number.isFinite(payload.created_at)
      && Array.isArray(payload.output) && payload.output.some((item) => item?.type === "compaction"
        && typeof item.encrypted_content === "string" && item.encrypted_content.length > 0)) return "completed";
  return "unverified";
}

function streamState(resp, pathname, lease = null) {
  const responses = /^\/(?:v1\/)?responses(?:\/compact)?$/.test(pathname);
  const sse = isEventStream(resp?.headers.get("content-type"));
  return {
    reader: resp?.body?.getReader() ?? null, response: resp ?? null, pipeline: null,
    pending: null, pulling: null, drainPromise: null, ended: false,
    idleMs: 0, status: resp?.status ?? 200, pathname, lease,
    cancelled: Boolean(lease?.cancelled), keepalive: PING_MS > 0 && sse,
    responsesTerminal: responses && sse
      ? { decoder: new TextDecoder(), line: "", overflow: false, event: null, data: false, kind: null } : null,
    jsonInspection: responses && !sse && resp?.ok
      ? { decoder: new TextDecoder(), bytes: 0, text: "", overflow: false } : null,
  };
}

function finishStream(state, controller, releaseOnce, label, tracker) {
  if (state.ended) return;
  state.ended = true;
  let errorKind = null;
  let terminal = state.responsesTerminal?.kind;
  if (state.responsesTerminal) {
    if (!terminal) errorKind = "upstream_protocol_eof";
    else if (terminal !== "response.completed") errorKind = terminal.replace(".", "_");
  }
  if (state.jsonInspection) {
    let outcome = "unverified";
    if (!state.jsonInspection.overflow) {
      try { outcome = classifyResponsesJson(JSON.parse(state.jsonInspection.text + state.jsonInspection.decoder.decode()), state.pathname); }
      catch {}
    }
    state.jsonInspection.text = "";
    terminal = `json.${outcome}`;
    if (outcome !== "completed") errorKind = `response_${outcome}`;
  }
  tracker?.annotate({ terminal_event: terminal ?? null, terminal_error_category: errorKind,
    drain_outcome: state.cancelled ? "completed" : null });
  tracker?.attemptOutcome(state.status, errorKind ?? "completed");
  if (state.lease && !state.cancelled && !errorKind) limiter.observeStatus(state.status, waiters.length > 0);
  state.lease?.settled();
  if (!state.cancelled) controller.close();
  releaseOnce();
  tracker?.finalize(state.cancelled ? 499 : state.status, state.cancelled ? "client_cancel" : errorKind);
  if (errorKind === "upstream_protocol_eof") log(`${label} ended before a Responses terminal event`);
}

async function pumpStep(state, controller, releaseOnce, label, tracker) {
  if (state.ended) return;
  if (!state.pending) state.pending = state.reader.read();

  const intervalMs = state.keepalive ? PING_MS : STALL_MS;
  if (!intervalMs) {
    const { done, value } = await state.pending;
    state.pending = null;
    if (done) { finishStream(state, controller, releaseOnce, label, tracker); return; }
    tracker?.firstByte();
    observeResponsesTerminal(state, value);
    if (!state.cancelled) controller.enqueue(value);
    return;
  }

  const tick = timeoutToken(intervalMs);
  const winner = await Promise.race([state.pending.then((read) => ({ read })), tick.promise]);
  tick.cancel();

  if (winner.read) {
    state.pending = null;
    state.idleMs = 0;
    if (winner.read.done) { finishStream(state, controller, releaseOnce, label, tracker); return; }
    tracker?.firstByte();
    observeResponsesTerminal(state, winner.read.value);
    if (!state.cancelled) controller.enqueue(winner.read.value);
    return;
  }

  state.idleMs += intervalMs;
  if (STALL_MS && state.idleMs >= STALL_MS) {
    const secs = Math.round(state.idleMs / 1000);
    log(`${label} stalled mid-stream: no upstream bytes for ${secs}s; failing the response`);
    abortResponse(state.response);
    void settleCancellation(state.reader, new Error("stalled"), "stalled reader cancellation failed");
    throw new UpstreamUnknownError(`shim: upstream stalled for ${secs}s; execution is unknown`, "shim_stream");
  }
  if (!state.cancelled) controller.enqueue(PING_FRAME);
}

function failStream(state, controller, releaseOnce, tracker, error) {
  if (state.ended) return;
  state.ended = true;
  const owner = error instanceof UpstreamUnknownError ? error.owner : "shim_transport";
  if (state.lease?.dispatched) state.lease.quarantine(owner);
  else releaseOnce();
  tracker?.annotate({ timeout_owner: owner, drain_outcome: state.cancelled ? "unknown" : null });
  tracker?.attemptOutcome(state.status, "upstream_unknown", owner);
  if (!state.cancelled && state.responsesTerminal && !state.responsesTerminal.kind) {
    tracker?.annotate({ terminal_event: "response.failed", terminal_error_category: "upstream_unknown" });
  }
  tracker?.finalize(state.cancelled ? 499 : state.status, state.cancelled ? "client_cancel" : "upstream_unknown");
  if (!state.cancelled) {
    if (state.responsesTerminal && !state.responsesTerminal.kind) {
      controller.enqueue(new TextEncoder().encode(`event: response.failed\ndata: ${JSON.stringify(responsesFailure(errorSummary(error), 502))}\n\n`));
      controller.close();
    } else if (isEventStream(state.response?.headers.get("content-type")) && !state.responsesTerminal) {
      controller.enqueue(new TextEncoder().encode(`event: error\ndata: ${JSON.stringify({ type: "error", error: { type: "api_error", message: errorSummary(error) } })}\n\n`));
      controller.close();
    } else controller.error(error);
  }
}

function enableDrain(state, releaseOnce, label, tracker) {
  const drain = () => {
    state.cancelled = true;
    state.keepalive = false;
    if (state.drainPromise || state.ended) return;
    // Let an already-pending pull relinquish the reader before the background
    // consumer takes over. This preserves exactly one read/cleanup owner.
    state.drainPromise = (async () => {
      await state.pulling?.catch(() => {});
      if (state.ended) return;
      if (!state.reader && state.pipeline) {
        const resp = await state.pipeline;
        const next = streamState(resp, state.pathname, state.lease);
        Object.assign(state, next, { cancelled: true, keepalive: false, drainPromise: state.drainPromise });
      }
      const sink = { enqueue() {}, close() {}, error() {} };
      if (!state.reader) { finishStream(state, sink, releaseOnce, label, tracker); return; }
      while (!state.ended) await pumpStep(state, sink, releaseOnce, label, tracker);
    })().catch((error) => failStream(state, { error() {} }, releaseOnce, tracker, error));
  };
  if (state.lease) state.lease.onCancel = drain;
  if (state.cancelled) drain();
  return drain;
}

// Stream an upstream response to the client, holding the semaphore permit until
// the stream ends / errors / is cancelled (true in-flight accounting).
function streamThrough(resp, releaseOnce, label = "stream", tracker = null, pathname = "", lease = null) {
  const headers = new Headers(resp.headers);
  headers.delete("content-encoding");  // Bun already decoded the upstream body
  headers.delete("content-length");
  headers.delete("transfer-encoding");
  if (tracker?.traceId) headers.set("x-trace-id", tracker.traceId);
  if (!resp.body) {
    const state = streamState(resp, pathname, lease);
    finishStream(state, { close() {} }, releaseOnce, label, tracker);
    return new Response(null, { status: resp.status, headers });
  }

  const state = streamState(resp, pathname, lease);
  const drain = enableDrain(state, releaseOnce, label, tracker);
  const stream = new ReadableStream({
    async pull(controller) {
      if (state.cancelled || state.ended) return;
      state.pulling = pumpStep(state, controller, releaseOnce, label, tracker);
      try { await state.pulling; }
      catch (err) { failStream(state, controller, releaseOnce, tracker, err); }
    },
    cancel() {
      if (lease) lease.cancel();
      else drain();
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
    await settleCancellation(reader, undefined, "error reader cancellation failed");
  }
  if (!size) return prefix;
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  const snippet = new TextDecoder().decode(bytes).replace(/\s+/g, " ").trim();
  return snippet ? `${prefix}: ${snippet.slice(0, 500)}` : prefix;
}

// Provider errors can contain JSON inside error.message. Bound both the bytes
// and traversal depth; persist categories, never the inspected error body.
export function classifyUpstreamError(status, text) {
  const codes = new Set();
  const messages = [];
  let visited = 0;
  function inspect(value, depth = 0) {
    if (depth > 5 || ++visited > 32) return;
    if (typeof value === "string") {
      messages.push(value.slice(0, ERROR_BODY_MAX_BYTES));
      try { inspect(JSON.parse(value), depth + 1); } catch {}
    } else if (value && typeof value === "object" && !Array.isArray(value)) {
      for (const key of ["code", "type"]) {
        if (typeof value[key] === "string") codes.add(value[key].toLowerCase());
      }
      if (value.error != null) inspect(value.error, depth + 1);
      if (value.message != null) inspect(value.message, depth + 1);
    }
  }
  inspect(String(text ?? "").slice(0, ERROR_BODY_MAX_BYTES));
  if (messages.some((message) => /^bad credentials\s*$/i.test(message))) return "bad_credentials";
  if (messages.some((message) => /^IDE token expired(?::.*)?\s*$/i.test(message))) return "ide_token_expired";
  if (codes.has("upstream_timeout")) return "backend_timeout";
  if (status === 408 && codes.has("user_request_timeout")) return "request_body_timeout";
  if (status === 401) return "authentication";
  if (status === 402) return "quota";
  if (status === 422 || codes.has("cyber_policy")) return "policy_or_validation";
  if (status === 400) return "validation";
  if (status === 429 || [...codes].some((code) => ["rate_limit_exceeded", "rate_limited", "too_many_requests", "throttled", "secondary_rate_limit"].includes(code))) return "throttle";
  if (status === 403) return "permission";
  return RETRY_STATUS.has(status) ? "transient_server" : "upstream_status";
}

async function inspectErrorResponse(resp, lease, tracker) {
  const reader = resp.body?.getReader();
  const deadline = timeoutToken(ERROR_BODY_TIMEOUT_MS);
  const chunks = [];
  let retained = 0;
  try {
    while (reader) {
      const winner = await Promise.race([reader.read().then((read) => ({ read })), deadline.promise]);
      if (winner.tick) throw new UpstreamUnknownError("backend error body did not finish; execution is unknown", "shim_error_body");
      if (winner.read.done) break;
      if (retained + winner.read.value.length > JSON_OBSERVE_MAX_BYTES) {
        throw new UpstreamUnknownError("backend error body exceeded the bounded inspection limit; execution is unknown", "shim_error_body");
      }
      chunks.push(winner.read.value); retained += winner.read.value.length;
    }
    lease.settled();
    const bytes = new Uint8Array(retained);
    let offset = 0;
    for (const part of chunks) { bytes.set(part, offset); offset += part.length; }
    const category = classifyUpstreamError(resp.status, new TextDecoder().decode(bytes));
    tracker.annotate({ terminal_error_category: category, timeout_owner: category === "backend_timeout" ? "backend" : null });
    tracker.attemptOutcome(resp.status, category, category === "backend_timeout" ? "backend" : null);
    const headers = new Headers(resp.headers);
    headers.delete("content-length"); headers.delete("content-encoding"); headers.delete("transfer-encoding");
    return { response: new Response(bytes, { status: resp.status, headers }), category };
  } catch (error) {
    abortResponse(resp);
    void settleCancellation(reader, error);
    throw error instanceof UpstreamUnknownError ? error
      : new UpstreamUnknownError("backend error body disconnected; execution is unknown", "shim_transport");
  } finally {
    deadline.cancel();
    try { reader?.releaseLock(); } catch {}
  }
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
// then splice in only a real SSE stream. Cancellation drains dispatched work.
function keepaliveThenForward(pipeline, releaseOnce, label, tracker, pathname, signal, lease) {
  const state = streamState(null, pathname, lease);
  state.pipeline = pipeline;
  state.keepalive = true;
  const drain = enableDrain(state, releaseOnce, label, tracker);
  let settled = false;
  const pull = async (controller) => {
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
            if (!state.cancelled) controller.enqueue(PING_FRAME);
            return;
          }

          settled = true;
          state.idleMs = 0;
          const { resp, err } = winner;
          state.response = resp ?? null;
          if (state.cancelled) return; // background drain owns the response now
          if (err || !resp.ok || !resp.body) {
            log(`${label} committed as SSE but upstream answered ${err ? `error (${err})` : resp.status}`);
            controller.enqueue(await terminalErrorFrame(pathname, err ? null : resp, err, signal));
            controller.close();
            state.ended = true;
            if (resp && !resp.body) lease.settled();
            releaseOnce();
            tracker?.annotate({ terminal_event: pathname.includes("responses") ? "response.failed" : "error" });
            tracker?.finalize(resp?.status ?? 502, err ? "upstream_error" : resp.ok ? "upstream_protocol" : "upstream_status");
            return;
          }
          const contentType = resp.headers.get("content-type") ?? "";
          if (!isEventStream(contentType)) {
            log(`${label} committed as SSE but upstream returned non-SSE ${contentType || "content"}`);
            // Still consume the unexpected body before releasing admission.
            state.reader = resp.body.getReader();
            state.lease.cancel();
            controller.enqueue(await terminalErrorFrame(pathname, null, new Error("upstream returned a non-SSE success body"), signal));
            controller.close();
            tracker?.finalize(resp.status, "upstream_protocol");
            return;
          }
          const next = streamState(resp, pathname, lease);
          Object.assign(state, next, { pipeline, pulling: state.pulling, drainPromise: state.drainPromise });
        }
        await pumpStep(state, controller, releaseOnce, label, tracker);
      } catch (err) {
        failStream(state, controller, releaseOnce, tracker, err);
      }
  };
  return new ReadableStream({
    async pull(controller) {
      if (state.cancelled || state.ended) return;
      state.pulling = pull(controller);
      await state.pulling;
    },
    cancel() {
      if (lease) lease.cancel();
      else drain();
    },
  });
}

export function startServer() {
  loadAdmissionBarrier();
  const server = Bun.serve({
    port: PORT,
    hostname: HOST,
    // Bun's 255s ceiling would otherwise cancel non-streaming requests before
    // the backend's 300s watchdog. The finite per-request watchdog owns this.
    idleTimeout: 0,
    async fetch(req, bunServer) {
    const url = new URL(req.url);
    const method = req.method;

    if (method === "GET" && url.pathname === "/_shim/health") {
      const routing = fastRoutingSnapshot();
      return jsonResponse({
        ok: true,
        ...limiterStatus(),
        fast_routing: { state: routing.state, mappings: Object.keys(routing.mappings).length },
      });
    }
    if (method === "GET" && url.pathname === "/_shim/fast-routing") {
      if (!isLoopbackRequest(req, bunServer)) {
        return jsonResponse({ error: "loopback request required" }, 403);
      }
      return jsonResponse(await refreshFastRouting(url.searchParams.get("refresh") === "1"));
    }
    if (method === "GET" && url.pathname === "/_shim/config") {
      return jsonResponse(limiterStatus());
    }
    if (method === "PATCH" && url.pathname === "/_shim/config") {
      if (!isLoopbackRequest(req, bunServer)
          || req.headers.get("x-copilot-shim-admin") !== "1") {
        return jsonResponse({ error: "loopback admin request required" }, 403);
      }
      return updateLimiter(req);
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

    if (admissionUnavailable()) return jsonResponse({ error: new AdmissionUnknownError().message }, 503);

    // Mutating requests (POST /v1/messages …): buffer body so we can resend on
    // retry, then throttle + retry. A peer may disappear while Bun is still
    // assembling a large Codex tools payload; contain that handler rejection.
    let bodyBuf;
    const bodyDeadline = timeoutToken(STALL_MS);
    try {
      const received = await Promise.race([
        req.arrayBuffer().then((body) => ({ body })), bodyDeadline.promise,
      ]);
      if (received.tick) {
        return jsonResponse({ error: { type: "shim_request_body_timeout", message: "shim did not receive the complete request body before its deadline" } }, 408);
      }
      bodyBuf = received.body;
    }
    catch (error) {
      const aborted = req.signal?.aborted;
      log(`${method} ${url.pathname} request body ${aborted ? "aborted" : "read failed"}: ${errorSummary(error)}`);
      return new Response(aborted ? "client aborted" : "shim: request body read failed", { status: aborted ? 499 : 400 });
    } finally { bodyDeadline.cancel(); }
    let routingSnapshot = fastRoutingSnapshot();
    let normalized = normalizeRequestBody(
      url.pathname, bodyBuf, req.headers.get("content-encoding") ?? "", routingSnapshot.mappings,
    );
    if (normalized.routing.requested && (fastRouting.pending || fastRoutingNeedsRefresh())) {
      routingSnapshot = await refreshFastRouting();
      normalized = normalizeRequestBody(
        url.pathname, bodyBuf, req.headers.get("content-encoding") ?? "", routingSnapshot.mappings,
      );
    }
    if (normalized.parseError) {
      log(`${method} ${url.pathname} could not inspect JSON (${bodyBuf.byteLength} bytes, content-type=${req.headers.get("content-type") ?? "unset"}, content-encoding=${req.headers.get("content-encoding") ?? "unset"}): ${normalized.parseError}`);
    }
    if (normalized.toolDescriptionsChanged > 0) {
      log(`${method} ${url.pathname} filled ${normalized.toolDescriptionsChanged} empty tool description(s): ${normalized.patched.join(", ")}`);
    }
    if (normalized.routing.routed) {
      log(`${method} ${url.pathname} fast route: ${normalized.routing.model} -> ${normalized.routing.target} (${normalized.routing.requestedTier})`);
    } else if (normalized.routing.fallback) {
      const warningKey = `${normalized.routing.model ?? "unknown"}:${normalized.routing.requestedTier}:${routingSnapshot.checked_at_ms ?? 0}`;
      if (!fastFallbackWarnings.has(warningKey)) {
        fastFallbackWarnings.add(warningKey);
        log(`fast requested for ${normalized.routing.model ?? "unknown model"} but no eligible sibling is available; using the standard model`);
      }
    }
    const incomingTrace = req.headers.get("x-trace-id") ?? "";
    const traceId = /^[\w.:-]{1,128}$/.test(incomingTrace) ? incomingTrace : crypto.randomUUID();
    const meta = requestMetadata(url.pathname, normalized.inspectBody, req.headers);
    const tracker = createMetricTracker({ ...meta, traceId, received_bytes: bodyBuf.byteLength,
      forwarded_bytes: typeof normalized.body === "string" ? new TextEncoder().encode(normalized.body).byteLength : normalized.body.byteLength });
    const { target, makeInit } = buildUpstream(req, normalized.body, normalized.decoded, traceId);

    const label = `${method} ${url.pathname}`;
    // The permit is now taken INSIDE the pipeline: queue time is silent time on
    // the client socket too, so the keepalive below has to be able to cover it.
    let acquired = false;
    const lease = createLease(req.signal, tracker);
    const releaseOnce = () => lease.release();

    // Queue for a permit, then talk to the upstream until a response is
    // committed. Resolves to a Response whose body has NOT been read yet, or to
    // a synthetic error Response (permit already released in that case).
    const runUpstream = async () => {
      let requestBodyTimeoutRetries = 0;
      const willQueue = active >= limiter.limit;
      const queuedAt = willQueue ? performance.now() : null;
      if (willQueue) {
        log(`queueing ${label} (active=${active}/${limiter.limit}, queued=${waiters.length + 1}, ceiling=${limiter.snapshot().max})`);
      }
      try { await acquire(req.signal); }
      catch (err) {
        releaseOnce();
        if (err instanceof AdmissionUnknownError) {
          tracker.finalize(503, "admission_unknown");
          return jsonResponse({ error: err.message }, 503);
        }
        tracker.finalize(499, "client_cancel");
        return new Response("client aborted", { status: 499 });
      }
      acquired = true;
      lease.admitted();
      tracker.acquired();
      if (queuedAt !== null) {
        log(`admitted ${label} after ${Math.round(performance.now() - queuedAt)}ms (active=${active}/${limiter.limit}, queued=${waiters.length})`);
      }

      for (let attempt = 0; attempt <= RETRIES; attempt++) {
        if (lease.cancelled || req.signal.aborted) {
          releaseOnce(); tracker.finalize(499, "client_cancel");
          return new Response("client aborted", { status: 499 });
        }
        const attemptId = tracker.attempt();
        let resp;
        let category = null;
        try {
          resp = await fetchAttempt(target, makeInit, lease, attemptId);
          if (!resp.ok) {
            const inspected = await inspectErrorResponse(resp, lease, tracker);
            resp = inspected.response; category = inspected.category;
          }
        } catch (err) {
          const owner = err instanceof UpstreamUnknownError ? err.owner : "shim_transport";
          lease.quarantine(owner);
          tracker.attemptOutcome(502, "upstream_unknown", owner);
          tracker.finalize(lease.cancelled ? 499 : 502, lease.cancelled ? "client_cancel" : "upstream_unknown");
          return new Response(`shim: ${errorSummary(err)}; recover backend and shim after tracked streams settle`, { status: 502 });
        }

        // A permission 403 is not evidence of throttling. Success pressure is
        // observed at completion below, rather than at HTTP 200 headers.
        if (category === "throttle") limiter.observeStatus(resp.status, willQueue || waiters.length > 0);

        // Retryable status and attempts left → back off and try again. A 408
        // user_request_timeout means the upstream did not finish reading the
        // already-buffered request body; replay it at most once so a transient
        // reader stall can recover without turning a persistent large-body
        // failure into four minute-long attempts.
        const bodyTimeoutRetry = resp.status === REQUEST_BODY_TIMEOUT_STATUS && category === "request_body_timeout"
          && requestBodyTimeoutRetries < REQUEST_BODY_TIMEOUT_RETRIES;
        const d = backoffMs(attempt, resp.headers.get("retry-after"));
        if ((category === "transient_server" || category === "throttle" || bodyTimeoutRetry)
            && attempt < RETRIES && d <= MAX_RETRY_AFTER_MS && !lease.cancelled) {
          if (bodyTimeoutRetry) requestBodyTimeoutRetries++;
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
        if (!resp.ok) {
          lease.settled();
          releaseOnce();
          tracker.finalize(lease.cancelled ? 499 : resp.status, lease.cancelled ? "client_cancel" : "upstream_status");
        }
        return resp;
      }
      releaseOnce(); // unreachable (last attempt always commits) — safety net
      return new Response("shim: retries exhausted", { status: 502 });
    };

    const pipeline = runUpstream();

    // Non-streaming callers keep the original shape: one await, real status.
    const eligible = PING_MS > 0 && PING_AFTER_MS > 0 && wantsStream(normalized.inspectBody);
    if (!eligible) {
      try { return streamThrough(await pipeline, releaseOnce, label, tracker, url.pathname, lease); }
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
        const state = streamState(early.resp, url.pathname, lease);
        const drain = enableDrain(state, releaseOnce, label, tracker);
        tracker.finalize(early.resp.status, "upstream_protocol");
        lease.cancel(); drain();
        return new Response("shim: upstream returned a non-SSE success body", {
          status: 502,
          headers: { "content-type": "text/plain; charset=utf-8", "x-trace-id": traceId },
        });
      }
      return streamThrough(early.resp, releaseOnce, label, tracker, url.pathname, lease);
    }

    // Slow path — still queued, or the model is still thinking. Commit the SSE
    // response now and start the heartbeat; the real stream is spliced in
    // underneath once the pipeline settles.
    const phase = acquired ? "upstream" : "queue";
    log(`${label} silent for ${PING_AFTER_MS}ms; keepalive engaged (phase=${phase}, active=${active}/${limiter.limit}, queued=${waiters.length})`);
    return new Response(keepaliveThenForward(pipeline, releaseOnce, label, tracker, url.pathname, req.signal, lease), {
      status: 200,
      headers: { "content-type": "text/event-stream", "cache-control": "no-cache", connection: "keep-alive", "x-trace-id": traceId },
    });
    },
  });

  void refreshFastRouting(true);
  if (STALL_MS <= Math.max(BACKEND_HEADERS_MS, BACKEND_INACTIVITY_MS)) {
    log("warning: shim fallback does not exceed the configured backend deadlines; check effective timeout overrides");
  }
  log(`listening on :${server.port} -> ${UPSTREAM} (limit=${limiter.limit}, range=${STARTUP_MIN}..${STARTUP_MAX}, retries=${RETRIES}, backoff=${BACKOFF_MS}ms, ping=${PING_MS}ms after ${PING_AFTER_MS}ms, stall=${STALL_MS}ms)`);
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
  console.log(`  requests ${stats.requests}  success ${stats.successes}  errors ${stats.errors}  upstream ${stats.upstream_errors}  cancelled ${stats.client_cancels}  retries ${stats.retries}`);
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
