import { pathToFileURL } from "node:url";

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const counts = new Map();
const seen = new Map();
const arrivals = [];
const upstream = Bun.serve({
  port: 0,
  idleTimeout: 60,
  async fetch(req) {
    const url = new URL(req.url);
    if (req.method === "GET" && url.pathname === "/v1/models") {
      return Response.json({ data: [
        { id: "gpt-fixture", claude_model_id: "gpt-fixture[1m]", supported_endpoints: ["/responses"], model_picker_enabled: true, policy: { state: "enabled" }, capabilities: { type: "chat" } },
        { id: "gpt-fixture-fast", claude_model_id: "gpt-fixture-fast[1m]", supported_endpoints: ["/responses"], model_picker_enabled: true, policy: { state: "enabled" }, capabilities: { type: "chat" } },
      ] });
    }
    const mode = url.searchParams.get("mode") ?? "ok";
    const key = `${url.pathname}:${mode}`;
    counts.set(key, (counts.get(key) ?? 0) + 1);
    const body = req.method === "GET" || req.method === "HEAD" ? "" : await req.text();
    const record = { body, trace: req.headers.get("x-trace-id"), at: performance.now() };
    if (!seen.has(key)) seen.set(key, []);
    seen.get(key).push(record);
    arrivals.push(mode);
    const attempt = counts.get(key);
    await sleep(Number(url.searchParams.get("delay") ?? 0));
    if (mode === "retry500" && attempt === 1) return new Response('{"error":"transient"}', { status: 500 });
    if (mode === "retry408" && attempt === 1) return new Response('{"error":{"code":"user_request_timeout"}}', { status: 408 });
    if (mode === "always500") return new Response('{"error":"persistent"}', { status: 500 });
    if (mode === "nonsse") return Response.json({ ok: true });
    if (mode === "status400") return new Response('{"error":"bad"}', { status: 400, headers: { "content-type": "application/json" } });
    if (mode === "status401") return new Response('{"error":"unauthorized"}', { status: 401 });
    if (mode === "status422") return new Response('{"error":{"code":"cyber_policy"}}', { status: 422 });
    if (mode === "402") return new Response('{"error":"billing"}', { status: 402 });
    if (mode === "status429") return new Response('{"error":"rate limited"}', { status: 429 });
    if (mode === "backoff") return new Response('{"error":"retry later"}', { status: 500, headers: { "retry-after": "2" } });
    if (mode === "stallbody") {
      return new Response(new ReadableStream({ start(controller) { controller.enqueue(new TextEncoder().encode("partial")); } }), {
        status: 500,
        headers: { "content-type": "application/json" },
      });
    }
    const events = url.pathname.includes("responses")
      ? 'event: response.completed\ndata: {"type":"response.completed","response":{"status":"completed"}}\n\n'
      : 'event: message_start\ndata: {}\n\nevent: message_stop\ndata: {}\n\n';
    return new Response(events, { headers: { "content-type": mode === "mixedsse" ? "Text/Event-Stream; Charset=UTF-8" : "text/event-stream" } });
  },
});

process.env.COPILOT_SHIM_PORT = "0";
process.env.COPILOT_SHIM_UPSTREAM = `http://127.0.0.1:${upstream.port}`;
process.env.COPILOT_SHIM_MAX = "1";
process.env.COPILOT_SHIM_RETRIES = "1";
process.env.COPILOT_SHIM_BACKOFF_MS = "10";
process.env.COPILOT_SHIM_PING_AFTER_MS = "100";
process.env.COPILOT_SHIM_PING_MS = "50";
process.env.COPILOT_SHIM_STALL_MS = "5000";
process.env.COPILOT_SHIM_METRICS_DB = process.argv[3];
process.env.COPILOT_API_SQLITE_DB_PATH = `${process.argv[3]}.tokens`;
const { closeResponse, createMetricTracker, settleCancellation, startServer } = await import(pathToFileURL(process.argv[2]).href);
let cancelSettled = false;
const cancelPromise = closeResponse({ body: { async cancel() { await sleep(150); cancelSettled = true; } } }, new Error("test cleanup"));
await sleep(30);
const cancelBarrier = { waited: !cancelSettled };
await cancelPromise;
cancelBarrier.settled = cancelSettled;
await settleCancellation({ cancel() { return Promise.reject(new Error("fixture rejected cancel")); } });
await settleCancellation({ cancel() { throw new Error("fixture throwing cancel"); } });
let metricFailureContained = true;
try {
  const tracker = createMetricTracker(
    { traceId: "fixture-metric-failure", endpoint: "/fixture", model: "fixture", scope: "normal", streaming: true },
    { query() { throw new Error("fixture metric write failure"); } },
    () => 0,
  );
  tracker.finalize(200);
} catch { metricFailureContained = false; }
const cleanupFailures = { cancellationContained: true, metricFailureContained };
const shim = startServer();

const responseErrorCode = (result) => {
  const data = result.body.match(/^data: (.+)$/m)?.[1];
  return data ? JSON.parse(data)?.response?.error?.code ?? null : null;
};

const call = async (path, mode, { stream = true, delay = 120, signal, payload } = {}) => {
  const response = await fetch(`http://127.0.0.1:${shim.port}${path}?mode=${mode}&delay=${delay}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload ?? { model: mode, stream, marker: mode }),
    signal,
  });
  const body = await response.text();
  return {
    status: response.status,
    body,
    events: [...body.matchAll(/^event: (\S+)/gm)].map((match) => match[1]),
    pings: (body.match(/^: /gm) ?? []).length,
  };
};

try {
  const fastRoute = await call("/v1/responses", "fast-route", {
    delay: 0,
    payload: { model: "gpt-fixture", service_tier: "fast", stream: true, marker: "fast-route" },
  });
  const retry = await call("/v1/messages", "retry500", { delay: 250 });
  const retry408 = await call("/v1/messages", "retry408", { delay: 0 });
  const exhausted = await call("/v1/responses", "always500", { delay: 150 });
  const delayedResponses = {
    status400: await call("/v1/responses", "status400", { delay: 150 }),
    status401: await call("/v1/responses", "status401", { delay: 150 }),
    status402: await call("/v1/responses", "402", { delay: 150 }),
    status422: await call("/v1/responses", "status422", { delay: 150 }),
    status429: await call("/v1/responses", "status429", { delay: 150 }),
  };
  const responseCodes = Object.fromEntries(Object.entries(delayedResponses).map(([key, value]) => [key, responseErrorCode(value)]));
  responseCodes.status500 = responseErrorCode(exhausted);
  const nonSse = await call("/v1/messages", "nonsse", { delay: 150 });
  const fastNonSse = await call("/v1/messages", "nonsse", { delay: 0 });
  const mixedSse = await call("/v1/messages", "mixedsse", { delay: 150 });
  const billing = await call("/v1/messages", "402", { stream: false, delay: 0 });
  const stallStarted = performance.now();
  const stalled = await call("/v1/messages", "stallbody", { delay: 100 });
  const stalledMs = performance.now() - stallStarted;

  const activeCtl = new AbortController();
  const activeAbort = call("/v1/messages", "activeabort", { signal: activeCtl.signal, delay: 500 }).catch((error) => error.name);
  await sleep(50);
  activeCtl.abort();
  const activeAbortResult = await activeAbort;

  const holder = call("/v1/messages", "hold", { delay: 350 });
  await sleep(20);
  const deadCtl = new AbortController();
  const dead = call("/v1/messages", "dead", { signal: deadCtl.signal }).catch((error) => error.name);
  await sleep(30);
  deadCtl.abort();
  const liveAfterQueue = call("/v1/messages", "live-after-queue", { delay: 0 });
  await holder;
  const deadResult = await dead;
  const queueLiveResult = await liveAfterQueue;

  const backoffCtl = new AbortController();
  const backoff = call("/v1/messages", "backoff", { stream: false, signal: backoffCtl.signal, delay: 0 }).catch((error) => error.name);
  await sleep(100);
  const backoffReleaseStarted = performance.now();
  backoffCtl.abort();
  const liveAfterBackoff = await call("/v1/messages", "live-after-backoff", { delay: 0 });
  const backoffReleaseMs = performance.now() - backoffReleaseStarted;
  const backoffResult = await backoff;

  const metrics = await (await fetch(`http://127.0.0.1:${shim.port}/_shim/events?scope=all&limit=50`)).json();
  const retrySeen = seen.get("/v1/messages:retry500") ?? [];
  const retry408Seen = seen.get("/v1/messages:retry408") ?? [];
  const fastSeen = seen.get("/v1/responses:fast-route") ?? [];
  const expectedRetryBody = JSON.stringify({ model: "retry500", stream: true, marker: "retry500" });
  const result = {
    cancelBarrier,
    cleanupFailures,
    fastRoute: {
      response: fastRoute,
      forwarded: fastSeen.length === 1 ? JSON.parse(fastSeen[0].body) : null,
    },
    retry,
    retry408,
    exhausted,
    delayedResponses,
    responseCodes,
    nonSse,
    fastNonSse,
    mixedSse,
    billing,
    stalled: { ...stalled, elapsed_ms: stalledMs },
    cancellation: { activeAbortResult, deadResult, queueLiveResult, backoffResult, liveAfterBackoff, backoffReleaseMs, arrivals },
    retryReplay: {
      attempts: retrySeen.length,
      sameBody: retrySeen.length === 2 && retrySeen.every((entry) => entry.body === expectedRetryBody),
      sameTrace: retrySeen.length === 2 && Boolean(retrySeen[0].trace) && retrySeen[0].trace === retrySeen[1].trace,
      delayMs: retrySeen.length === 2 ? retrySeen[1].at - retrySeen[0].at : null,
    },
    retry408Replay: { attempts: retry408Seen.length },
    counts: Object.fromEntries(counts),
    metrics,
  };
  console.log(JSON.stringify(result));

  if (retry.status !== 200 || retry.pings < 1 || retry.events.join(",") !== "message_start,message_stop") throw new Error("retry path failed");
  if (retry408.status !== 200 || result.retry408Replay.attempts !== 2) throw new Error("408 body-timeout retry failed");
  if (!cancelBarrier.waited || !cancelBarrier.settled) throw new Error("response cleanup barrier was not awaited");
  if (!cleanupFailures.cancellationContained || !cleanupFailures.metricFailureContained) throw new Error("cleanup failure escaped");
  if (result.fastRoute.response.status !== 200 || result.fastRoute.forwarded?.model !== "gpt-fixture-fast" || "service_tier" in result.fastRoute.forwarded) throw new Error("fast routing failed");
  if (!result.retryReplay.sameBody || !result.retryReplay.sameTrace || result.retryReplay.attempts !== 2) throw new Error("retry replay changed");
  if (exhausted.events.at(-1) !== "response.failed" || !exhausted.body.includes('"status":"failed"')) throw new Error("responses terminal failure failed");
  if (JSON.stringify(responseCodes) !== JSON.stringify({ status400: "invalid_prompt", status401: "invalid_prompt", status402: "insufficient_quota", status422: "invalid_prompt", status429: "rate_limit_exceeded", status500: "server_error" })) throw new Error("responses error classification failed");
  if (counts.get("/v1/responses:status400") !== 1 || counts.get("/v1/responses:status401") !== 1 || counts.get("/v1/responses:402") !== 1 || counts.get("/v1/responses:status422") !== 1 || counts.get("/v1/responses:status429") !== 2) throw new Error("responses retry classification changed");
  if (nonSse.events.at(-1) !== "error" || !nonSse.body.includes("non-SSE")) throw new Error("delayed non-SSE guard failed");
  if (fastNonSse.status !== 502 || !fastNonSse.body.includes("non-SSE")) throw new Error("fast non-SSE guard failed");
  if (mixedSse.events.join(",") !== "message_start,message_stop") throw new Error("case-insensitive SSE media type failed");
  if (billing.status !== 402 || counts.get("/v1/messages:402") !== 1) throw new Error("402 retried");
  if (stalled.events.at(-1) !== "error" || stalledMs > 4000) throw new Error("stalled error body was unbounded");
  if (activeAbortResult !== "AbortError") throw new Error("active upstream abort was not propagated");
  if (deadResult !== "AbortError" || arrivals.includes("dead") || queueLiveResult.status !== 200) throw new Error("canceled waiter reached upstream");
  if (backoffResult !== "AbortError" || liveAfterBackoff.status !== 200 || backoffReleaseMs > 1000 || counts.get("/v1/messages:backoff") !== 1) throw new Error("backoff cancellation retained permit or retried");
  const hasMetric = (predicate) => metrics.some(predicate);
  if (!hasMetric((row) => row.model === "retry500" && row.status === 200 && row.attempts === 2 && row.retries === 1 && !row.error_kind)) throw new Error("successful retry metrics missing");
  if (!hasMetric((row) => row.model === "gpt-fixture-fast" && row.status === 200)) throw new Error("fast routing metrics missing");
  if (!hasMetric((row) => row.model === "always500" && row.status === 500 && row.attempts === 2 && row.retries === 1 && row.error_kind === "upstream_status")) throw new Error("exhausted retry metrics missing");
  if (metrics.filter((row) => row.model === "nonsse" && row.error_kind === "upstream_protocol").length !== 2) throw new Error("fast/delayed protocol mismatch metrics missing");
  if (!hasMetric((row) => row.model === "activeabort" && row.status === 499 && row.attempts === 1 && row.error_kind === "client_cancel")) throw new Error("active cancellation metrics missing");
  if (!hasMetric((row) => row.model === "dead" && row.status === 499 && row.attempts === 0 && row.error_kind === "client_cancel")) throw new Error("queued cancellation metrics missing");
  if (!hasMetric((row) => row.model === "backoff" && row.status === 499 && row.attempts === 1 && row.error_kind === "client_cancel")) throw new Error("backoff cancellation metrics missing");
} finally {
  shim.stop(true);
  upstream.stop(true);
}
