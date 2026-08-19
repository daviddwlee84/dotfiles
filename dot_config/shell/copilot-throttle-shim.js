#!/usr/bin/env bun
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
//                    ├─ transparent retry on 403/429/502/503/504 + network
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
// until the upstream produces something. Requests answered inside the grace
// window keep the old behaviour byte for byte, real status code included.
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

const PORT = Number(process.env.COPILOT_SHIM_PORT ?? 4142);
const UPSTREAM = (process.env.COPILOT_SHIM_UPSTREAM ?? "http://localhost:4141").replace(/\/+$/, "");
const MAX = Math.max(1, Number(process.env.COPILOT_SHIM_MAX ?? 4));
const RETRIES = Math.max(0, Number(process.env.COPILOT_SHIM_RETRIES ?? 3));
const BACKOFF_MS = Math.max(0, Number(process.env.COPILOT_SHIM_BACKOFF_MS ?? 500));
const PING_MS = Math.max(0, Number(process.env.COPILOT_SHIM_PING_MS ?? 15000));
const PING_AFTER_MS = Math.max(0, Number(process.env.COPILOT_SHIM_PING_AFTER_MS ?? 10000));
const STALL_MS = Math.max(0, Number(process.env.COPILOT_SHIM_STALL_MS ?? 240000));
const RETRY_STATUS = new Set([403, 429, 502, 503, 504]);

// Ceiling for the keepalive path's own patience. It must outlast the WHOLE
// pipeline — every attempt's STALL_MS plus the backoffs between them — or it
// tears the client stream down mid-retry and throws away a retry that was about
// to succeed. 0 (watchdog disabled) means wait as long as the upstream does.
const GIVEUP_MS = STALL_MS ? (RETRIES + 1) * (STALL_MS + 30000) : 0;

// SSE comment frame. The spec says a line starting with ":" is a comment and is
// discarded by the parser, so this is invisible to the agent yet counts as
// traffic for every idle timer in the path.
const PING_FRAME = new TextEncoder().encode(": copilot-shim keepalive\n\n");

const log = (...a) => console.log(new Date().toISOString(), "[shim]", ...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// A cancellable timer promise. Racing a bare `sleep()` would leave one live
// timer per pull, which on a long stream is thousands of them.
function timeoutToken(ms) {
  let id;
  const promise = new Promise((res) => { id = setTimeout(() => res({ tick: true }), ms); });
  return { promise, cancel: () => clearTimeout(id) };
}

// ---- semaphore (at most MAX permits; hands a permit straight to a waiter) ----
let active = 0;
const waiters = [];
function acquire() {
  if (active < MAX) { active++; return Promise.resolve(); }
  return new Promise((res) => waiters.push(res));
}
function release() {
  active--;
  const next = waiters.shift();
  if (next) { active++; next(); }
}

function backoffMs(attempt, retryAfter) {
  const ra = Number(retryAfter);
  if (Number.isFinite(ra) && ra > 0) return Math.min(ra * 1000, 30000);
  return BACKOFF_MS * 2 ** attempt + Math.floor(Math.random() * BACKOFF_MS); // + jitter
}

function buildUpstream(req, bodyBuf, bodyWasDecoded = false) {
  const url = new URL(req.url);
  const target = UPSTREAM + url.pathname + url.search;
  const headers = new Headers(req.headers);
  headers.delete("host");
  headers.delete("content-length"); // fetch recomputes from body
  if (bodyWasDecoded) headers.delete("content-encoding");
  const init = { method: req.method, headers, signal: req.signal };
  if (bodyBuf !== undefined) init.body = bodyBuf;
  return { target, init };
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
    return { body: bodyBuf, changed: 0, patched: [], parseError: null, decoded: false };
  }
  try {
    const encoding = contentEncoding.trim().toLowerCase();
    const decodedBody = encoding === "zstd" ? Bun.zstdDecompressSync(new Uint8Array(bodyBuf)) : bodyBuf;
    const payload = JSON.parse(new TextDecoder().decode(decodedBody));
    const result = normalizeResponsesToolDescriptions(payload);
    if (result.changed === 0) return { body: bodyBuf, ...result, parseError: null, decoded: false };
    return { body: JSON.stringify(payload), ...result, parseError: null, decoded: encoding === "zstd" };
  } catch (error) {
    // Preserve malformed/non-JSON requests verbatim; the upstream remains the
    // authority for their validation and error response.
    return { body: bodyBuf, changed: 0, patched: [], parseError: String(error), decoded: false };
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

// One upstream `fetch` attempt with a ceiling on the silent pre-header window.
// A wedged upstream otherwise never settles this promise and the agent waits
// forever; RETRIES then gets a chance to re-issue the request instead.
function fetchAttempt(target, init, clientSignal) {
  if (!STALL_MS) return fetch(target, { ...init, signal: clientSignal });
  const ctl = new AbortController();
  const onClientAbort = () => ctl.abort();
  if (clientSignal?.aborted) ctl.abort();
  else clientSignal?.addEventListener("abort", onClientAbort, { once: true });
  let stalled = false;
  const timer = setTimeout(() => { stalled = true; ctl.abort(); }, STALL_MS);
  const done = () => {
    clearTimeout(timer);
    clientSignal?.removeEventListener("abort", onClientAbort);
  };
  return fetch(target, { ...init, signal: ctl.signal }).then(
    (resp) => { done(); return resp; },
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
async function pumpStep(state, controller, releaseOnce, label) {
  if (!state.pending) state.pending = state.reader.read();

  if (!state.keepalive) {
    const { done, value } = await state.pending;
    state.pending = null;
    if (done) { controller.close(); releaseOnce(); return; }
    controller.enqueue(value);
    return;
  }

  const tick = timeoutToken(PING_MS);
  const winner = await Promise.race([state.pending.then((read) => ({ read })), tick.promise]);
  tick.cancel();

  if (winner.read) {
    state.pending = null;
    state.idleMs = 0;
    if (winner.read.done) { controller.close(); releaseOnce(); return; }
    controller.enqueue(winner.read.value);
    return;
  }

  state.idleMs += PING_MS;
  if (STALL_MS && state.idleMs >= STALL_MS) {
    const secs = Math.round(state.idleMs / 1000);
    log(`${label} stalled mid-stream: no upstream bytes for ${secs}s; failing the response`);
    try { state.reader.cancel(new Error("stalled")); } catch {}
    releaseOnce();
    controller.error(new Error(`shim: upstream stalled for ${secs}s`));
    return;
  }
  controller.enqueue(PING_FRAME);
}

// Stream an upstream response to the client, holding the semaphore permit until
// the stream ends / errors / is cancelled (true in-flight accounting).
function streamThrough(resp, releaseOnce, label = "stream") {
  const headers = new Headers(resp.headers);
  headers.delete("content-encoding");  // Bun already decoded the upstream body
  headers.delete("content-length");
  headers.delete("transfer-encoding");
  if (!resp.body) { releaseOnce(); return new Response(null, { status: resp.status, headers }); }

  const state = {
    reader: resp.body.getReader(),
    pending: null,
    idleMs: 0,
    // Only an SSE body may carry comment frames; a JSON body must stay verbatim.
    keepalive: PING_MS > 0 && (headers.get("content-type") ?? "").includes("text/event-stream"),
  };
  const stream = new ReadableStream({
    async pull(controller) {
      try { await pumpStep(state, controller, releaseOnce, label); }
      catch (err) { releaseOnce(); controller.error(err); }
    },
    cancel(reason) { releaseOnce(); try { state.reader.cancel(reason); } catch {} },
  });
  return new Response(stream, { status: resp.status, headers });
}

// The upstream committed a non-2xx AFTER the shim already promised the client a
// 200 SSE stream, so the status line is spent. Both the Anthropic and the
// OpenAI streaming protocols carry failures as an `error` event, which their
// SDKs surface as a normal API error — that is the only channel left here.
async function sseErrorFrame(resp, err) {
  let detail = err ? String(err) : `upstream returned ${resp.status}`;
  if (resp && !err) {
    try { detail = `upstream returned ${resp.status}: ${(await resp.text()).slice(0, 500)}`; } catch {}
  }
  const payload = JSON.stringify({ type: "error", error: { type: "api_error", message: `shim: ${detail}` } });
  return new TextEncoder().encode(`event: error\ndata: ${payload}\n\n`);
}

// Slow path body: ping until `pipeline` (queueing + retries + upstream headers)
// settles, then forward the real stream through the same pump.
function keepaliveThenForward(pipeline, releaseOnce, label) {
  const state = { reader: null, pending: null, idleMs: 0, keepalive: true };
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
            if (GIVEUP_MS && state.idleMs >= GIVEUP_MS) {
              // fetchAttempt bounds each attempt, so reaching this means the
              // pipeline itself is wedged past its whole retry budget.
              const secs = Math.round(state.idleMs / 1000);
              log(`${label} gave up after ${secs}s without upstream headers`);
              settled = true;
              pipeline.then((resp) => resp?.body?.cancel()).catch(() => {});
              controller.enqueue(await sseErrorFrame(null, `no upstream response in ${secs}s`));
              controller.close();
              releaseOnce();
              return;
            }
            controller.enqueue(PING_FRAME);
            return;
          }

          settled = true;
          state.idleMs = 0;
          const { resp, err } = winner;
          if (err || !resp.ok || !resp.body) {
            log(`${label} committed as SSE but upstream answered ${err ? `error (${err})` : resp.status}`);
            controller.enqueue(await sseErrorFrame(err ? null : resp, err));
            controller.close();
            releaseOnce();
            return;
          }
          state.reader = resp.body.getReader();
        }
        await pumpStep(state, controller, releaseOnce, label);
      } catch (err) { releaseOnce(); controller.error(err); }
    },
    cancel(reason) {
      releaseOnce();
      try { state.reader?.cancel(reason); } catch {}
      pipeline.then((resp) => resp?.body?.cancel(reason)).catch(() => {});
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

    // Health / metadata reads: straight passthrough, no permit, no retry.
    if (method === "GET" || method === "HEAD") {
      try {
        const { target, init } = buildUpstream(req, undefined);
        return streamThrough(await fetch(target, init), () => {});
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
    const { target, init } = buildUpstream(req, normalized.body, normalized.decoded);

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
      await acquire();
      acquired = true;
      if (willQueue) log(`queued ${label} (${active} in-flight, ${waiters.length} waiting)`);

      for (let attempt = 0; attempt <= RETRIES; attempt++) {
        let resp;
        try {
          resp = await fetchAttempt(target, init, req.signal);
        } catch (err) {
          if (req.signal?.aborted) { releaseOnce(); return new Response("client aborted", { status: 499 }); }
          if (attempt < RETRIES) {
            const d = backoffMs(attempt);
            log(`${label} network error (${err}); retry ${attempt + 1}/${RETRIES} in ${d}ms`);
            await sleep(d);
            continue;
          }
          releaseOnce();
          return new Response(`shim: upstream unreachable: ${err}`, { status: 502 });
        }

        // Retryable status and attempts left → back off and try again. The 403
        // arrives fast (<2s, before any body), so retrying here is safe.
        if (RETRY_STATUS.has(resp.status) && attempt < RETRIES) {
          const d = backoffMs(attempt, resp.headers.get("retry-after"));
          log(`${label} -> ${resp.status}; retry ${attempt + 1}/${RETRIES} in ${d}ms`);
          try { await resp.body?.cancel(); } catch {}
          await sleep(d);
          continue;
        }

        if (attempt > 0) log(`${label} -> ${resp.status} after ${attempt} retr${attempt === 1 ? "y" : "ies"}`);
        return resp;
      }
      releaseOnce(); // unreachable (last attempt always commits) — safety net
      return new Response("shim: retries exhausted", { status: 502 });
    };

    const pipeline = runUpstream();

    // Non-streaming callers keep the original shape: one await, real status.
    const eligible = PING_MS > 0 && PING_AFTER_MS > 0 && wantsStream(normalized.body);
    if (!eligible) {
      try { return streamThrough(await pipeline, releaseOnce, label); }
      catch (err) { releaseOnce(); return new Response(`shim: ${err}`, { status: 500 }); }
    }

    // Fast path — upstream answered inside the grace window, so nothing about
    // this request changes: real status, real headers, no injected frames.
    const grace = timeoutToken(PING_AFTER_MS);
    const early = await Promise.race([
      pipeline.then((resp) => ({ resp }), (err) => ({ err })),
      grace.promise,
    ]);
    grace.cancel();
    if (early.err) { releaseOnce(); return new Response(`shim: ${early.err}`, { status: 500 }); }
    if (early.resp) return streamThrough(early.resp, releaseOnce, label);

    // Slow path — still queued, or the model is still thinking. Commit the SSE
    // response now and start the heartbeat; the real stream is spliced in
    // underneath once the pipeline settles.
    log(`${label} silent for ${PING_AFTER_MS}ms; committing SSE early and sending keepalives`);
    return new Response(keepaliveThenForward(pipeline, releaseOnce, label), {
      status: 200,
      headers: { "content-type": "text/event-stream", "cache-control": "no-cache", connection: "keep-alive" },
    });
    },
  });

  log(`listening on :${server.port} -> ${UPSTREAM} (max=${MAX}, retries=${RETRIES}, backoff=${BACKOFF_MS}ms, ping=${PING_MS}ms after ${PING_AFTER_MS}ms, stall=${STALL_MS}ms)`);
  return server;
}

if (import.meta.main) startServer();
