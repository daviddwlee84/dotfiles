#!/usr/bin/env bun
// copilot-throttle-shim.js — a tiny streaming reverse proxy that sits IN FRONT
// of the local copilot-api fork (default :4141). It exists to stop GitHub's
// enterprise Copilot backend from 403-ing ("Forbidden") on bursts of premium
// requests, WITHOUT adding latency to normal single-agent flow.
//
//   Claude Code ─▶ shim (:4142) ─▶ copilot-api fork (:4141) ─▶ Copilot backend
//                    │
//                    ├─ semaphore: at most MAX concurrent in-flight upstream
//                    │   POSTs; a burst queues instead of hitting the backend
//                    │   all at once (that simultaneity is what trips abuse
//                    │   detection). Under the cap there is ZERO added latency.
//                    │
//                    └─ transparent retry on 403/429/502/503/504 + network
//                        errors, jittered backoff, BEFORE any response body is
//                        streamed — so the agent never sees the transient 403
//                        ("Please run /login"). GET/HEAD (health, /v1/models)
//                        bypass both, so liveness checks stay instant.
//
// Managed by copilot-proxy (see 43_copilot_proxy.sh: `copilot-proxy shim on`).
// Config via env (all optional):
//   COPILOT_SHIM_PORT       listen port                    (default 4142)
//   COPILOT_SHIM_UPSTREAM   upstream base URL              (default http://localhost:4141)
//   COPILOT_SHIM_MAX        max concurrent in-flight POSTs (default 4)
//   COPILOT_SHIM_RETRIES    retry attempts on transient    (default 3)
//   COPILOT_SHIM_BACKOFF_MS base backoff ms, doubles/try   (default 500)

const PORT = Number(process.env.COPILOT_SHIM_PORT ?? 4142);
const UPSTREAM = (process.env.COPILOT_SHIM_UPSTREAM ?? "http://localhost:4141").replace(/\/+$/, "");
const MAX = Math.max(1, Number(process.env.COPILOT_SHIM_MAX ?? 4));
const RETRIES = Math.max(0, Number(process.env.COPILOT_SHIM_RETRIES ?? 3));
const BACKOFF_MS = Math.max(0, Number(process.env.COPILOT_SHIM_BACKOFF_MS ?? 500));
const RETRY_STATUS = new Set([403, 429, 502, 503, 504]);

const log = (...a) => console.log(new Date().toISOString(), "[shim]", ...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

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

function buildUpstream(req, bodyBuf) {
  const url = new URL(req.url);
  const target = UPSTREAM + url.pathname + url.search;
  const headers = new Headers(req.headers);
  headers.delete("host");
  headers.delete("content-length"); // fetch recomputes from body
  const init = { method: req.method, headers, signal: req.signal };
  if (bodyBuf !== undefined) init.body = bodyBuf;
  return { target, init };
}

// Stream an upstream response to the client, holding the semaphore permit until
// the stream ends / errors / is cancelled (true in-flight accounting).
function streamThrough(resp, releaseOnce) {
  const headers = new Headers(resp.headers);
  headers.delete("content-encoding");  // Bun already decoded the upstream body
  headers.delete("content-length");
  headers.delete("transfer-encoding");
  if (!resp.body) { releaseOnce(); return new Response(null, { status: resp.status, headers }); }

  const reader = resp.body.getReader();
  const stream = new ReadableStream({
    async pull(controller) {
      try {
        const { done, value } = await reader.read();
        if (done) { controller.close(); releaseOnce(); return; }
        controller.enqueue(value);
      } catch (err) { releaseOnce(); controller.error(err); }
    },
    cancel(reason) { releaseOnce(); try { reader.cancel(reason); } catch {} },
  });
  return new Response(stream, { status: resp.status, headers });
}

const server = Bun.serve({
  port: PORT,
  idleTimeout: 255, // seconds — long opus streams (saw up to ~77s)
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
    const { target, init } = buildUpstream(req, bodyBuf);

    const willQueue = active >= MAX;
    await acquire();
    if (willQueue) log(`queued ${method} ${url.pathname} (${active} in-flight, ${waiters.length} waiting)`);
    let released = false;
    const releaseOnce = () => { if (!released) { released = true; release(); } };

    try {
      for (let attempt = 0; attempt <= RETRIES; attempt++) {
        let resp;
        try {
          resp = await fetch(target, init);
        } catch (err) {
          if (req.signal?.aborted) { releaseOnce(); return new Response("client aborted", { status: 499 }); }
          if (attempt < RETRIES) {
            const d = backoffMs(attempt);
            log(`${method} ${url.pathname} network error (${err}); retry ${attempt + 1}/${RETRIES} in ${d}ms`);
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
          log(`${method} ${url.pathname} -> ${resp.status}; retry ${attempt + 1}/${RETRIES} in ${d}ms`);
          try { await resp.body?.cancel(); } catch {}
          await sleep(d);
          continue;
        }

        // Commit: stream this response (2xx, or the real error after retries).
        if (attempt > 0) log(`${method} ${url.pathname} -> ${resp.status} after ${attempt} retr${attempt === 1 ? "y" : "ies"}`);
        return streamThrough(resp, releaseOnce);
      }
      releaseOnce(); // unreachable (last attempt always commits) — safety net
      return new Response("shim: retries exhausted", { status: 502 });
    } catch (err) {
      releaseOnce();
      return new Response(`shim: ${err}`, { status: 500 });
    }
  },
});

log(`listening on :${server.port} -> ${UPSTREAM} (max=${MAX}, retries=${RETRIES}, backoff=${BACKOFF_MS}ms)`);
