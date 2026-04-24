# Super Productivity — Local REST API reference

Cross-referenced against the upstream wiki page
[`docs/wiki/3.01-API.md`](https://github.com/super-productivity/super-productivity/blob/master/docs/wiki/3.01-API.md)
and source files on **2026-04-23**. Treat as a snapshot — the API is actively
evolving. When in doubt, regenerate from the wiki + source files listed below.

> **Initial draft of this page assumed the wiki didn't exist.** It does — the
> upstream `docs/wiki/3.01-API.md` documents all three SP API systems (Sync
> Server, Plugin API, Local REST API). This file focuses on the Local REST API
> only (the one we use), with extra detail on the security model and
> reverse-engineered behaviour the wiki glosses over.

## Three API systems — disambiguation

Super Productivity exposes **three** distinct API surfaces. Don't confuse them:

| API | What | Where | Auth |
|---|---|---|---|
| **Sync Server REST API** | Sync user data across devices via the SuperSync provider (NOT WebDAV) | Remote server (`packages/super-sync-server/`) | JWT Bearer |
| **Plugin API** | In-app `PluginAPI` global for installed plugins (sandboxed VM/iframe) | Inside the app process | None (sandbox enforced) |
| **Local REST API** | HTTP control surface for external scripts on the same machine | `http://127.0.0.1:3876` in the desktop Electron app | None — localhost-only |

**This document covers only the Local REST API.** The TV channel
[`tv super-productivity`](../../dot_config/television/cable/super-productivity.toml)
talks to it.

The Sync Server is a completely separate concern from the Local REST API.
**Enabling Dropbox / WebDAV / SuperSync as your sync provider has zero effect
on whether the Local REST API works.** They are independent toggles.

## Version requirement (the gotcha)

The Local REST API was added in upstream PR
[#6981](https://github.com/super-productivity/super-productivity/pull/6981)
(merged 2026-03-28) and first shipped in **v18.0.0** (released 2026-03-26
cycle). DNS-rebinding hardening landed in PR #6996 right after.

| Installed version | Local REST API works? |
|---|---|
| ≤ v17.x | **No** — the HTTP server doesn't exist; toggle is absent |
| ≥ v18.0.0 | Yes — toggle visible in Settings → Misc |

Check what you have:

```bash
defaults read "/Applications/Super Productivity.app/Contents/Info.plist" CFBundleShortVersionString
brew info --cask super-productivity | head -5    # latest available
```

The Brewfile cask
([`dot_config/homebrew/Brewfile.darwin.tmpl:83`](../../dot_config/homebrew/Brewfile.darwin.tmpl))
pins to "latest", but if your local install lags, run
`brew upgrade --cask super-productivity` (or `just upgrade-brew`).

## Why we care

We use the Local REST API to drive the read-only TV channel
[`tv super-productivity`](../../dot_config/television/cable/super-productivity.toml)
([source script](../../dot_config/television/executable_super-productivity-source.sh)).

There is **no official CLI** and **no official MCP server** as of this writing.
The "API" issue ([#312](https://github.com/super-productivity/super-productivity/issues/312))
has been open since 2017; an "MCP server plugin" idea exists in a 2025-03 issue
but no roadmap commitment. The Local REST API is the only official
programmatic surface for external tools, and it only works while the desktop
Electron app is running.

The Plugin API is a viable alternative for in-app extensions (e.g. the
shipped `api-test-plugin` and `sync-md` plugins use it), but plugins run
in-process and aren't suitable for shell automation. Stick with REST.

## Source of truth

| Concern | Upstream file |
|---|---|
| Official user-facing reference | [`docs/wiki/3.01-API.md`](https://github.com/super-productivity/super-productivity/blob/master/docs/wiki/3.01-API.md) |
| HTTP server, port, host gating, limits | `electron/local-rest-api.ts` |
| Constants + payload shapes | `electron/shared-with-frontend/local-rest-api.model.ts` |
| Route table + handler logic | `src/app/core/electron/local-rest-api-handler.service.ts` |
| Unit tests (39 cases, useful as behaviour spec) | `src/app/core/electron/local-rest-api-handler.service.spec.ts` |
| Toggle setting key | `misc.isLocalRestApiEnabled` (global config state) |
| Plugin API (separate concern) | `packages/plugin-api/src/types.ts`, `docs/plugin-development.md` |

## Enabling the API

The server is **off by default**. To enable (v18.0.0+ only):

1. Open Super Productivity desktop app
2. **Settings → Misc → "Enable local REST API"**
   *(NOT "Sync & Export" — that section configures Dropbox/WebDAV/SuperSync
   data sync, which has nothing to do with the REST API.)*
3. Restart the app (toggle takes effect on next app start, not live)

Verify:

```bash
curl -s http://127.0.0.1:3876/health | jq
# {"ok":true,"data":{"server":"up","rendererReady":true}}
```


Failure modes:

| Curl exit | What it means |
|---|---|
| `7` (connection refused) | App not running, or API toggle off |
| `28` (timeout) | App hung; check the renderer process |
| `200` with `rendererReady: false` | Server is up but Angular renderer hasn't initialized — every route except `/health` will return `503 APP_NOT_READY` |

## Server constants

From `electron/shared-with-frontend/local-rest-api.model.ts`:

| Constant | Value |
|---|---|
| `LOCAL_REST_API_HOST` | `127.0.0.1` (localhost only — no external binding) |
| `LOCAL_REST_API_PORT` | `3876` |
| `LOCAL_REST_API_TIMEOUT_MS` | `15000` (renderer round-trip timeout) |
| `LOCAL_REST_API_MAX_BODY_BYTES` | `1048576` (1 MiB request body cap) |
| `LOCAL_REST_API_MAX_CONCURRENT_REQUESTS` | `50` |

## Security model

- **DNS-rebinding guard**: server inspects the `Host:` header. Allowed values:
  `127.0.0.1:3876`, `127.0.0.1`, `localhost:3876`, `localhost`. Anything else
  returns `403 FORBIDDEN`. So you cannot use a custom DNS name (e.g.
  `sp.local`) to talk to it.
- **No auth** beyond Host gating. Anything that can hit localhost on this
  machine can read and mutate your tasks. Plan accordingly if you ever publish
  it via SSH port-forward.
- **Concurrency cap**: at >50 in-flight requests the server returns
  `429 TOO_MANY_REQUESTS`.
- **No CORS headers** are emitted; browser-based callers will be blocked unless
  the page is served from the renderer itself.

## Response envelope

Every response is JSON with one of these shapes:

```json
{ "ok": true,  "data": <any> }
{ "ok": false, "error": { "code": "STRING", "message": "STRING", "details"?: <any> } }
```

**The `data` wrapper is universal** — every "Returns" entry in the route table
below describes the shape of `data`, NOT the top-level response. When piping
to `jq`, always extract `.data` first:

```bash
# Right
curl -sf http://127.0.0.1:3876/tasks | jq '.data[].title'
curl -sf http://127.0.0.1:3876/tasks/$ID | jq '.data.notes'
curl -sf http://127.0.0.1:3876/task-control/current | jq -r '.data.id // empty'

# Wrong (would get "Cannot index boolean with string" — .ok is bool)
curl -sf http://127.0.0.1:3876/tasks | jq '.[].title'
```

A `null` current task is returned as `{"ok":true,"data":null}`, not
`{"ok":true}` — so `jq -r '.data.id // empty'` is the safe pattern.

Known error codes (from the renderer + server):

| Code | HTTP | When |
|---|---|---|
| `FORBIDDEN` | 403 | Bad `Host:` header |
| `TOO_MANY_REQUESTS` | 429 | >50 concurrent |
| `APP_NOT_READY` | 503 | Server up, renderer not yet initialised |
| `INVALID_REQUEST_BODY` | 400 | Body present but not valid JSON |
| `INVALID_INPUT` | 400 | Body parses but fails route-specific validation |
| `TASK_NOT_FOUND` | 404 | `:id` does not match any task (active or archive depending on route) |
| `NOT_FOUND` | 404 | Route not in the table |
| `RENDERER_TIMEOUT` | 504 | Renderer didn't reply within 15s |
| `INTERNAL_ERROR` | 500 | Anything else |

## Route table

All routes accept and return JSON. `:id` is a string (UUID-like) generated by
the app. Query params are parsed via `URL.searchParams` — repeated keys become
arrays, single keys become strings.

### Health

| Method | Path | Returns |
|---|---|---|
| `GET` | `/health` | `{server: "up", rendererReady: bool}` — the only route that works before the renderer is ready. |

### App status

| Method | Path | Returns |
|---|---|---|
| `GET` | `/status` | `{currentTask, currentTaskId, taskCount}` — `currentTask` is the full task object or `null`. |

### Current task control

| Method | Path | Body | Returns |
|---|---|---|---|
| `GET` | `/task-control/current` | — | full current task or `null` |
| `POST` | `/task-control/current` | `{taskId: string \| null}` | `{currentTaskId}` — start (focus) a task; pass `null` to clear |
| `POST` | `/task-control/stop` | — | `{currentTaskId: null}` — stops the current task |

### Tasks (collection)

| Method | Path | Notes |
|---|---|---|
| `GET` | `/tasks` | List, filterable. Query params: `query` (substring match on `title`, case-insensitive), `projectId`, `tagId`, `includeDone` (bool, default `false`), `source` (`active` \| `archived` \| `all`, default `active`). All four filters verified working against live data. |
| `POST` | `/tasks` | Create. Body must include `title` (non-empty string). Other allowed fields whitelisted server-side: see "Allowed mutable fields" below. Returns the created task with status `201`. |

### Tasks (single)

| Method | Path | Notes |
|---|---|---|
| `GET` | `/tasks/:id` | Returns the task object. `404 TASK_NOT_FOUND` if missing. |
| `PATCH` | `/tasks/:id` | Body is a partial task; only whitelisted fields are applied — extras silently dropped. **`notes` is full replacement, no append semantics.** |
| `DELETE` | `/tasks/:id` | Removes the task (and its sub-tasks). Returns `{deleted: true, id}`. |
| `POST` | `/tasks/:id/start` | Sets the task as the current focused task. Equivalent to `POST /task-control/current` with `{taskId: id}`. |
| `POST` | `/tasks/:id/archive` | Moves task (with sub-tasks) to archive. |
| `POST` | `/tasks/:id/restore` | Restores from archive. `404 TASK_NOT_FOUND` if not in archive. |

### Projects

| Method | Path | Notes |
|---|---|---|
| `GET` | `/projects` | Lists all projects. Query: `query` for substring-on-title filter. No create/update/delete routes. |

### Tags

| Method | Path | Notes |
|---|---|---|
| `GET` | `/tags` | Lists all tags. Query: `query` for substring-on-title filter. No create/update/delete routes. |

### Allowed mutable fields

Server enforces a whitelist on `POST /tasks` and `PATCH /tasks/:id` —
everything else is dropped silently with no warning. From
`local-rest-api-handler.service.ts`:

```text
title, notes, isDone, timeEstimate, timeSpent,
projectId, tagIds, dueDay, dueWithTime, plannedAt
```

Implications:

- Cannot set `subTaskIds`, `parentId`, `_projectId`, `attachments`, etc. via REST.
- Cannot append to `notes` — you must `GET`, edit, then `PATCH` the full string.
- `timeSpent` is settable, which is unusual: it lets external timers backfill
  hours without going through the focus-task flow.

## What is NOT exposed

These are common asks that the API does **not** currently cover. Always
double-check upstream before relying on absence — the API is being added to.

- **No "today" route.** The "Today" view is a renderer-side aggregation —
  empirically it includes anything with `dueDay == today`, the focused
  current task, and tasks tagged with the built-in `TODAY` tag. The TODAY
  tag has a fixed reserved id confirmed against live data: `id == "TODAY"`
  regardless of locale or display title (`title` shows the localized
  "Today" string). Same fixed-id pattern applies to other built-ins:
  `KANBAN_IN_PROGRESS`, `EM_IMPORTANT`, `EM_URGENT` (tags) and
  `INBOX_PROJECT` (project). So `GET /tasks?tagId=TODAY` is a partial
  approximation — easy to query, but it will miss `dueDay`-only entries
  unless the user also explicitly tagged them. A faithful Today
  reconstruction needs `dueDay == today` UNION `tagId=TODAY` UNION current
  task.
- **No recurring-task creation.** Tracked upstream (issue filed 2026-04-16).
- **No notes append.** Use `PATCH` with the full new string.
- **No project / tag CRUD.** Read-only.
- **No worklog / time-tracking session API.** You can update `timeSpent` via
  `PATCH`, but there's no event-style endpoint.
- **No attachments / sub-tasks via REST.** They round-trip via `GET`/`PATCH`
  but there's no dedicated endpoint to add a sub-task.
- **No webhooks / SSE / WebSocket.** Polling only — see the TV channel's
  `watch = 5.0`.
- **No deep-link URL scheme verified.** A search of the upstream repo for
  `superproductivity://` returned no hits as of this writing. Don't construct
  links assuming one exists.

## Plan for graduating to programmatic control

Confirmed alignment with the upstream direction (desktop-only, plugin-friendly,
API-first):

```
Super Productivity Desktop
    └── Local REST API (127.0.0.1:3876)
            └── tv super-productivity              ← v0.1 (this PR), read-only
            └── future: spctl                      ← deferred (P? in TODO.md)
            └── future: super-productivity-mcp     ← deferred (P? in TODO.md)
```

The TV channel deliberately exercises every read route so that any future CLI
or MCP server can reuse the same shell-level integration tests. Mutating
operations (start, stop, complete, archive) are intentionally NOT in v0.1 — the
routes exist (`POST /task-control/stop`, `POST /tasks/:id/start`,
`PATCH /tasks/:id` with `{isDone:true}`, `POST /tasks/:id/archive`) but want
proven behaviour first.

## Verifying this doc

If the renderer service file changes upstream, regenerate the route table:

```bash
gh api -X GET "repos/super-productivity/super-productivity/contents/src/app/core/electron/local-rest-api-handler.service.ts" \
  --jq '.content' | base64 -d | grep -E "method === '|path === '|segments\["
```

The route table above lines up 1:1 with the `if` branches in `_routeRequest`
(plus the inner `_handleTaskRoutes` cases for `/tasks/:id/...`).
