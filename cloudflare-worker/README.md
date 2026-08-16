# chekinana Cloudflare Worker

This Worker provides a fixed API domain:

```text
https://api.chekinana.top
```

Production Scanner requests never contain a RunPod Pod ID or Scanner/backend
token. The Worker routes them through one `ScannerRuntime` Durable Object,
which keeps the current Pod ID private. Pod identity is used only to select the
upstream hostname; the Worker injects a separate Backend Bearer token from the
`CHEKI_BACKEND_API_TOKEN` secret. The effective upstream remains:

```text
https://<pod-id>-8080.proxy.runpod.net
```

The current iOS product and production deployment do not depend on a local
Python Backend or local Wrangler process. The explicit loopback mode documented
later is retained only as an opt-in development harness and is not configured
in `wrangler.toml`.

## Production Scanner runtime lifecycle

The public lifecycle routes are:

```text
GET       /api/scanner/runtime
WebSocket /api/scanner/runtime/start
POST      /api/scanner/runtime/stop
```

The WebSocket form is a `GET` with `Upgrade: websocket`. It is the normal iOS
Start path: opening it starts or attaches to startup, immediately sends the
latest persisted public snapshot, then sends updated snapshots while the
Durable Object checks readiness. The server closes the connection after
`ready` or a fixed terminal startup failure. A non-WebSocket request to the
Start route returns `426 websocket_upgrade_required` and cannot control RunPod.
Additional Start WebSockets attach to the same persisted startup attempt; they
never issue another primary start or temporary create. The attempt has one
15-minute deadline. A still-unhealthy Backend at that deadline receives a fixed
startup failure and every attached socket is closed.

Every new Start attempt performs a live RunPod lookup and, when the Pod is
`RUNNING`, the strict Backend health read even if the last persisted snapshot
was `ready`. A persisted public state is never accepted as current readiness.

All JSON responses and WebSocket messages use the same public body and contain
no Pod ID, hostname, token, task ID, template ID, network-volume ID, or RunPod
response body:

```json
{
  "ok": true,
  "state": "closed",
  "phase": "closed",
  "message": null,
  "retryAllowed": true,
  "canStart": true,
  "canTerminate": false,
  "updatedAt": "2026-08-04T12:00:00.000Z"
}
```

`state` and `phase` are both exactly `closed`, `preparing`, or `ready`; private
lifecycle and failure phases are never exposed. `ready` requires both a RunPod
`RUNNING` Pod and a strict Backend `GET /health` response: HTTP 200 with
`status=ok`, `model_loaded=true`, and `device=cuda`.

Preparing snapshots may also include the only public startup-progress field:

```json
"progress": { "current": 2, "total": 3 }
```

The three action-derived steps are: initial Pod inspection and control dispatch
(including a capacity fallback request), waiting for Pod provisioning/start or
creation recovery, and a running Pod whose strict Backend health is not ready.
The terminal `ready` state and all closed/error/cleanup responses omit
`progress`. The field contains no lifecycle label or private identifier. It is
derived from the persisted Durable Object transition, so new and reconnected
Start WebSockets receive the same current snapshot; every persisted preparing
transition is broadcast to all attached Start sockets. Legacy/unknown
message-less preparing snapshots conservatively restart at step 1. A read-only
runtime GET maps its already-required Pod/health observation to the same field
without adding another external call or changing persisted state.

Each `GET .../runtime` performs exactly one read-only RunPod Pod lookup and, for
a running Pod, one strict Backend health read before returning the normalized
state. This probe does not enter the startup control queue, reconcile startup,
change or close sockets, persist runtime state, create cleanup work, or set an
alarm. It therefore cannot advance, fail, or otherwise alter an in-progress
Start. It does not schedule another GPU-status lookup. Outside an active Start
WebSocket, the Worker never polls RunPod GPU status. During an active Start
WebSocket, Durable Object alarms perform the internal status/health checks;
when all clients disconnect, ordinary startup polling stops. The only bounded
exception is a persisted primary-dispatch or temporary-create recovery intent:
its watchdog continues read-only reconciliation until the 15-minute startup
deadline so a response-loss window cannot leak paid infrastructure.
The startup operation rechecks for an attached socket after every external
wait. Once no socket remains, it sends no later primary-start or temporary-create
request.

Pod reconciliation uses RunPod's Pod REST v1 API at
`https://rest.runpod.io/v1` with Bearer authorization. Primary Pod lookup is
exactly one `GET /pods/<id>?includeMachine=true`; the response must contain the
same valid private ID and a recognized `desiredStatus` (`status` remains
accepted for compatibility). HTTP 404 maps to public `closed`; no ID is
returned or logged. Temporary correlation recovery uses the official v1
`GET /pods` list and an exact unique-name match. The configured
`RUNPOD_POD_ID` is always the primary Pod. Start first reads that Pod; if it is
stopped, the Worker calls `POST /pods/<primary-id>/start` with no request body.
It does not fall
back for authorization, validation, rate-limit, timeout, transport, malformed
response, or generic RunPod errors.

Before invoking the primary Start fetch, the Durable Object first establishes a
recovery-watchdog alarm and then persists an explicit dispatch intent. Only
after both writes succeed may the control fetch be invoked. This ordering means
every durable intent already has a wakeup; a crash before the intent write only
leaves a harmless alarm. Recovery probes RunPod read-only before deciding what
the intent means. Because RunPod visibility can lag, a single exited,
terminated, missing, or errored result retains the intent and schedules another
read-only probe. If the Pod remains closed through the 15-minute deadline, the
intent is cleared without a `stop`. A provisioning, starting, running, or
unconfirmable Pod is treated as a possibly accepted Start and retains the
at-most-once cleanup contract. Failures from the preceding read/authentication
path never create an intent and therefore cannot stop the primary.

Only when the primary start response explicitly states that GPU capacity is
unavailable does the Worker call the v1 `POST /pods` once. Its payload keeps the
configured `RUNPOD_TEMPLATE_ID` and `RUNPOD_NETWORK_VOLUME_ID` and supplies a
unique, non-secret temporary Pod name plus the existing GPU selection fields.
`RUNPOD_TEMPORARY_GPU_TYPE_IDS` may optionally provide a comma-separated
availability list; otherwise RunPod may select an available GPU type. There is
no GraphQL resume or Pod migration path.

Before the create POST, the Durable Object establishes a watchdog and persists
the exact temporary name as a create intent. As soon as any create response
yields a valid new Pod ID, it persists that ID as the current temporary Pod
before checking response status, health, connection state, or deadline. If the
response is lost or the Durable Object restarts first, recovery uses the v1 Pod
list and only an exact-name match: zero matches are retried until the
deadline, one match has its ID persisted before one `DELETE`, and multiple
matches fail with a fixed error without guessing. Cleanup never stops the
temporary Pod or mutates the primary.

RunPod status failures are classified only into fixed non-sensitive phases:
`runpod_configuration_missing`, `pod_not_found`, `pod_terminated`,
`runpod_authorization_failed`, `runpod_rate_limited`,
`runpod_status_timeout`, `runpod_status_unavailable`,
`runpod_invalid_response`, and fixed temporary-Pod configuration/create
failures. No response body, credential, Pod ID, URL, or private endpoint is
stored in the public body or emitted to the client. These phase names stay
internal; client-visible errors use fixed codes and messages.

`POST .../stop` is the public Close action. After its active-work safety check,
it waits 20 seconds. Four minutes after the last Scan task becomes terminal,
the idle path performs the same close workflow. New Scanner activity cancels a
pending close before it is attempted. At the deadline the Durable Object marks
the control attempt as used in persistent state before making the request:

- a primary Pod receives exactly one v1 `POST /pods/<id>/stop` with no body;
- a temporary Pod receives exactly one v1 `DELETE /pods/<id>` and is never
  stopped.

The Worker never automatically repeats a failed stop or terminate request.
After a successful temporary termination, the private runtime target returns to
the configured primary Pod. The Worker does not schedule any follow-up public
status request; any one-shot client confirmation timing remains separate from
these 20-second and four-minute control deadlines.

All production Scanner proxy routes use the private current Pod ID only for the
target hostname and overwrite upstream authorization with
`Bearer CHEKI_BACKEND_API_TOKEN`. Client authorization, cookies, Scanner-token,
and source-network headers are removed. Uploads and image results remain
streams; only small JSON process/status responses are read to adapt the public
contract and maintain active-task leases. One instance-level control queue
serializes start, reconciliation, proxy admission, and idle stop.
The queue is never held while streaming media. A request lease remains active
until the returned body is actually consumed or canceled; a persisted expiry is
only a conservative recovery path after Durable Object eviction.

Each accepted `/api/process` task stays active until `/api/status/<task-id>`
reports `done` or `failed` (a Backend 404 is also terminal). Backend task checks
remain separate from GPU-status checks and never stop or terminate a Pod while
a Scanner task or response lease is active. Scanner API 1.2 request/response
adaptation, Backend Bearer injection, and secret/header stripping are unchanged.

Recovery checks for confirmed active Backend tasks use bounded parallelism so
one slow Backend status check does not force all other task checks to wait in
series while the runtime control queue is held. Set
`SCANNER_ACTIVE_TASK_CHECK_CONCURRENCY` to a positive integer; the default is
`4` and values are capped at `8`. Each check retains its own six-second abort
deadline, and an individual check failure keeps only that task active for the
next recovery pass. This does not introduce parallel GPU inference: the Worker
only performs small Backend status requests.

The same two-phase rule applies when an idle/user shutdown deadline expires:
the control queue snapshots the Pod identity, shutdown-request tuple, task IDs,
and task versions; bounded Backend status I/O runs outside that queue; and the
results merge under control. A cleared/replaced shutdown request is a tombstone,
so a stale check cannot stop a newer target. The final stop/delete remains
serialized and records its attempted state before the single RunPod action.

`SCANNER_TIMING_LOGS=true` enables aggregate Scanner timing diagnostics. Logs
contain only fixed route/stage names, HTTP status, counts, configured
concurrency, and integer elapsed milliseconds. They never contain task IDs,
image names or bytes, tokens, Pod IDs, URLs, or upstream bodies. Process and
result proxy timings are always logged; status polling is logged only when it
is terminal, non-200, or at least 250 ms, avoiding high-volume normal poll logs.

Stable production lifecycle/proxy errors are:

- `503 scanner_runtime_unavailable`: the Durable Object binding or required
  server configuration is unavailable.
- `503 scanner_backend_offline`, `scanner_backend_starting`, or
  `scanner_backend_configuration_invalid`: a Scanner request arrived before
  readiness or required Backend authorization is missing.
- `409 scanner_backend_busy`: explicit stop was refused because a Scanner
  stream or confirmed Backend task is still active.
- `502 scanner_upstream_unavailable`: the ready Backend request failed.
- `502 scanner_backend_rejected` or `scanner_backend_invalid_response`: Backend
  1.2 rejected the request or returned an invalid contract response.
- `404 scanner_task_not_found`: Backend 1.2 did not find the requested job or
  result. Upstream error bodies and private headers are never forwarded.
- Public `closed` with a fixed capacity message: no GPU was available;
  `retryAllowed` remains true, so the user may retry immediately.

Required Worker secrets (names only):

```text
RUNPOD_API_KEY
RUNPOD_POD_ID
RUNPOD_TEMPLATE_ID
RUNPOD_NETWORK_VOLUME_ID
CHEKI_BACKEND_API_TOKEN
```

`RUNPOD_TEMPORARY_GPU_TYPE_IDS` is an optional secret/configuration value. None
of these values belongs in iOS, source, `wrangler.toml`, logs, screenshots,
fixtures, public responses, or documentation examples. `CHEKI_BACKEND_API_TOKEN`
is independent of Pod identity; missing Backend authorization fails closed with
a fixed response and no upstream request.

This implementation must be deployed before the matching frontend change. The
only permitted live verification for this change is one read-only production
`GET /api/scanner/runtime`. No start, resume, create, stop, terminate, Scanner
upload, or other live functional verification belongs in this rollout.

This v1 App has no account/authentication system, so the public start endpoint
currently has no client credential by explicit product contract. Before public
distribution, protect paid GPU starts with real user authorization or App
Attest; a second hard-coded app token or retry cooldown is not an adequate
substitute.

## Scanner processing boundary

The Python Backend/RunPod service is extraction-only. It accepts the source
photo, uses SAM3 to detect and rectify polaroids, and exposes only clean
`polaroid` image results. It does not call Qwen, generate an ink image, encode
the result, classify an Idol, or accept/return Idol candidates, prototypes, or
Pattern IDs.

The public iOS routes remain stable:

```text
POST /api/process
GET  /api/status/<task-id>
GET  /api/result/<task-id>/<numeric-result-id>
```

Production adapts those routes to Backend API contract 1.2:

```text
POST /v1/jobs
GET  /v1/jobs/<job-id>
GET  /v1/jobs/<job-id>/results/<1-based-index>
```

The public `POST /api/process` body is the Backend 1.2 multipart body and is
forwarded as a stream, without calling `formData()` or buffering the source
image in the Worker. It contains `file` (required), `sleeve` (default `0`),
`wb` (default `1`), `denoise` (default `1`), and `sharpen` (default `0`). The
Backend accepts JPG/JPEG, PNG, BMP, TIF/TIFF, and WebP; its default request
limit is 30 MiB. The Worker replaces client authorization with its private
Backend Bearer token and maps the Backend HTTP-202 job response back to public
`task_id` and `status`.

Backend states map to the public status contract as follows:

```text
queued    -> queued
running   -> processing
succeeded -> done
failed    -> failed
```

Only a succeeded Backend job contains the complete `results` array. A public
result item has this shape:

```json
{
  "id": "1",
  "type": "polaroid",
  "label": "cheki_001.png",
  "quadrilateral": [[100, 200], [900, 200], [900, 1400], [100, 1400]]
}
```

`results_count`, `extraction_complete`, `source_image`, and
`coordinate_system` remain top-level public status fields. The coordinate
system is `exif_transposed_original_pixels`, origin `top_left`, `x_axis=right`,
`y_axis=down`, and `quad_order` is exactly
`["top_left","top_right","bottom_right","bottom_left"]`. Results are ordered
by center x, then center y. Each result download is the Backend PNG stream. A
successful job with no detection is `done` with `results_count=0` and an empty
array.

Backend 1.2 does not implement cancel/delete, incremental progress, or
restart-recovery. It publishes the complete result metadata only at
`succeeded`. The Worker runtime therefore treats only `succeeded` and `failed`
as terminal upstream states and rechecks active tasks at `/v1/jobs/<job-id>`.
The Backend does not call Qwen, encode or classify an Idol, or receive candidate
and Pattern data. Date annotation remains a separate Worker/Qwen step around a
single public result download.

In production, this Worker adapts the stable public routes to Backend 1.2 on
RunPod. The explicit local mode below intentionally remains a legacy transparent
loopback harness; this change does not expand or convert its Backend contract.
Both modes retain the optional public single-result date-annotation behavior.
Proxy connection failures return a fixed error code and do not include the
upstream hostname, Pod ID, or operating-system error.

This contract-1.2 adapter is source-only in the current change. It is not
deployed and was not tested against a Pod or live Backend.

## Explicit local Scanner mode

Local Windows GPU testing can replace only the Scanner upstream while keeping
the same Worker routes. This mode is disabled by default and must be enabled
only through local Worker environment values:

```text
CHEKINANA_SCANNER_LOCAL_MODE=true
CHEKINANA_SCANNER_LOCAL_UPSTREAM=http://127.0.0.1:8080
CHEKINANA_SCANNER_LOCAL_TOKEN=<local test secret>
```

The upstream accepts only an explicit `http://127.0.0.1:<port>` origin with no
userinfo, path, query, or fragment. The local token must arrive in
`X-Cheki-Token`; it is compared through fixed-length SHA-256 digests and is
removed from headers, query parameters, and supported request bodies before the
request reaches Python. Invalid, missing, or conflicting local configuration
fails closed with the fixed `local_scanner_configuration_invalid` error.
Unsupported local request bodies return `local_scanner_request_invalid`, and
local connection failures return `local_scanner_upstream_unavailable`; neither
response includes configuration or network details.

Local proxying also removes `Forwarded`, `X-Forwarded-*`, `X-Real-IP`,
Cloudflare client-IP headers, and related client-source headers before the
request reaches Python. Date annotation remains protected by the same Scanner
token check as its result download.

The Python backend must separately set
`CHEKINANA_TRUST_LOOPBACK_PROXY=true` and bind `HOST=127.0.0.1`. That backend
mode trusts only the actual IPv4 loopback peer, never forwarding headers. Only
Wrangler listens on the LAN. Do not add any of the local variables to
`wrangler.toml` or a deployed Worker environment.

Leaving all three local Scanner variables absent selects the Durable Object
production lifecycle/proxy behavior. The complete Windows setup,
firewall, test, iOS Debug, and cleanup procedure is in
[`docs/windows-lan-gpu-backend.md`](../docs/windows-lan-gpu-backend.md).
The local status and start routes report public `ready`, but local stop returns
`409 local_scanner_stop_unavailable`: Wrangler cannot safely stop the separate
Windows Python process, which must be closed on that host.

## Independent handwritten-date annotation

The app can annotate an already available Cheki image without starting,
querying, or proxying to RunPod:

```text
POST /api/cheki/date-annotation
Content-Type: image/jpeg | image/png | image/webp

<raw image bytes>
```

The response is always bounded JSON with `Cache-Control: no-store` and the
shared CORS policy. A detected date returns:

```json
{
  "status": "detected",
  "text": "2026.07.04",
  "precision": "full_date",
  "bbox": [100, 700, 450, 820]
}
```

The other successful shapes are `{ "status": "not_detected" }` and
`{ "status": "unavailable", "error": "<fixed-code>" }`. `precision` is
`full_date` for `YYYY.MM.DD` and `month_day` for `MM.DD`. The bbox uses Qwen's
normalized `[0,1000]` coordinate space and is temporary client UI metadata.

The route accepts at most 16 MiB, rejects unsupported or empty bodies before a
model call, gives the request stream 10 seconds, and makes one server-side Qwen
request with a single 90-second request-and-response deadline. It uses the same
fixed prompt, strict output schema, Qwen configuration, safe fixed errors, and
no-retry policy as Scanner-result annotation below. Client authorization,
cookies, image bytes, Data URLs, model reasoning, and model error bodies are
never forwarded back, logged, or stored. It has no Scanner token or RunPod
dependency.

## Optional handwritten-date annotation for one Scanner result

The existing single-result download can opt into one Qwen date-recognition
step:

```text
GET /api/result/<task-id>/<result-id>?date_annotation=1
```

Production needs no client Scanner token. Explicit local mode still requires
its local `X-Cheki-Token` as documented above.

Only that exact two-segment result route, a `GET`, and exactly one
`date_annotation=1` query value enable annotation. The legacy
`/api/result/<task-id>` route and all ordinary result, process, status, cancel,
NL, and Event requests keep their existing behavior. The Worker removes the
Worker-only `date_annotation` query before forwarding the result request to
RunPod.

The response status, content type, and body remain the original RunPod image
response. Existing upstream headers are preserved apart from the Worker's
existing CORS handling and the annotation-specific headers below:

```text
X-Cheki-Date-Status: detected
X-Cheki-Date-Text: 2026.07.04
X-Cheki-Date-Precision: full_date
X-Cheki-Date-Bbox: 100,700,450,820
```

`X-Cheki-Date-Precision` is `full_date` for `YYYY.MM.DD` and `month_day` for
`MM.DD`. Coordinates are four integers in Qwen's normalized `[0,1000]`
coordinate space. A reliable no-date result is:

```text
X-Cheki-Date-Status: not_detected
```

Configuration, image-read, Qwen, timeout, and strict model-output
failures never replace or remove the image. They return the original image plus:

```text
X-Cheki-Date-Status: unavailable
X-Cheki-Date-Error: <fixed-code>
```

The fixed unavailable codes are `image_unavailable`,
`unsupported_image_type`, `image_too_large`, `image_read_timeout`,
`image_read_failed`, `service_unavailable`, `qwen_timeout`,
`qwen_unavailable`, `invalid_model_output`, and `internal_error`.

All opted-in responses use `Cache-Control: no-store`, and the date headers are
listed in `Access-Control-Expose-Headers`. Model reasoning and upstream error
bodies are never returned. The Worker's shared preflight handler returns HTTP
200 for an `OPTIONS` request and exposes the same CORS contract without calling
RunPod or Qwen.

The Worker reads at most 16 MiB from a cloned status-200 JPEG, PNG, or WebP
result. Partial and other non-200 responses are returned unchanged without a
model call. The original response stream remains the client response. The
Worker sends one image Data URL and the fixed handwritten-date prompt to
`qwen3.7-plus`, with thinking disabled and `max_tokens` set to 1024. There is
no automatic retry. The image read has a 10-second deadline, and the single
Qwen request and response have one 90-second deadline. Images, Data URLs, model
output, Scanner tokens, task IDs, result IDs, cookies, and Pod details are
neither logged nor stored by this feature.

The bbox is temporary UI metadata only. The Worker neither draws it onto the
image nor stores a modified image; the client receives the exact upstream image
body in every annotation outcome.

Required Worker secrets:

```powershell
npx wrangler secret put CHEKI_DATE_QWEN_API_KEY
npx wrangler secret put CHEKI_DATE_QWEN_BASE_URL
```

`CHEKI_DATE_QWEN_BASE_URL` is the private HTTPS OpenAI-compatible base URL; the
Worker appends `/chat/completions`. Do not put either value in source,
`wrangler.toml`, logs, test fixtures, or documentation. The non-secret model
name is configured as `CHEKI_DATE_QWEN_MODEL`.

Date annotation has no dedicated frequency limiter or rate-limiter binding.
After Scanner-token authentication, every exact opted-in result request may
make the existing single Qwen call. Production must continue to provide the two
Qwen secrets above; their values remain untracked. The independent
`NL_RATE_LIMITER` and `EVENT_WEIBO_RATE_LIMITER` bindings and policies are
unchanged.

## Event candidate from a public Weibo URL or pasted text

`POST /api/event/weibo-candidate` is an independent, non-scanner route. It
does not accept a Pod ID and never proxies to RunPod. It accepts exactly one of
these backward-compatible request shapes:

```json
{
  "version": 1,
  "weiboURL": "https://weibo.com/1234567890/AbC123"
}
```

```json
{
  "version": 1,
  "text": "活动名称：示例公演\n日期：2026-08-02"
}
```

`weiboURL` and `text` are mutually exclusive; missing, combined, or additional
fields are rejected. Text input goes directly to the Event model and performs
no Weibo request. URL input validates and fetches the public status, optional
long text, publication time, author-avatar metadata, post-image metadata, and
structured ticket URLs before calling the same model.

Only one exact public `https://weibo.com/<user>/<ASCII-status-id>` or
`https://www.weibo.com/<user>/<ASCII-status-id>` URL is accepted. Userinfo,
ports, repeated or trailing slashes, query strings, and fragments are rejected.
Both raw path segments use strict percent and UTF-8 decoding: malformed escapes,
invalid UTF-8, decoded control characters, and decoded `/`, `?`, or `#` in the
user segment are rejected. The decoded user is limited to 1–200 Unicode code
points and the decoded status must be ASCII alphanumeric. The Worker does not
fetch the supplied URL. It extracts the status reference and calls only fixed
Weibo visitor, status, and optional long-text endpoints.

The Event extractor reuses `NL_LLM_API_KEY`, `NL_LLM_ENDPOINT`, and
`NL_LLM_MODEL` (default `deepseek-v4-flash`). Its dedicated system prompt treats
the source body as untrusted data, requests one exact JSON object, and forbids
embedded instructions from changing the task. The model receives the bounded
body, source kind, current Asia/Shanghai date, and, for URL input, the validated
Weibo URL, publication time when present, and server-resolved trusted ticket
URLs. Explicit ticket-price lines such as `普通:75` or multiple labelled tiers
are selected deterministically from that same bounded source, passed to the
model as `sourcePriceText`, and overlaid unchanged on the validated response;
merchandise and benefit prices are excluded. DeepSeek extracts `name`, `date`,
`city`, `livehouse`, `address`, `price`,
`weiboURL`, and `ticketURL`. It never receives client authorization, cookies,
scanner tokens, an avatar field, an image URL field, or a note field. `note`
remains entirely user-authored and is not part of this API response.

A successful response contains exactly nine candidate strings plus the stable
`imageUrls: string[]` field:

```json
{
  "version": 1,
  "kind": "candidate",
  "candidate": {
    "name": "示例公演",
    "date": "2026-08-02",
    "city": "合肥",
    "livehouse": "示例Livehouse",
    "address": "合肥市蜀山区示例路88号",
    "price": "早鸟票88/现场票108",
    "avatar_url": "https://tvax1.sinaimg.cn/example/avatar.jpg",
    "imageUrls": [
      "https://wx1.sinaimg.cn/large/example-1.jpg",
      "https://wx2.sinaimg.cn/large/example-2.jpg"
    ],
    "weiboURL": "https://weibo.com/1234567890/AbC123",
    "ticketURL": ""
  }
}
```

Missing or ambiguous fields remain empty strings. The response is a candidate,
not a persistence instruction: the client must display every field for editing
and save only after explicit user confirmation.

The model may infer a missing year from one unambiguous month/day only with the
documented source context: URL input prefers a reasonable year based on the
Weibo publication time, while pasted text may cautiously use the current
Shanghai date. Insufficient evidence or multiple performance dates produces an
empty date. The server then enforces the exact model schema and returns the
exact nine-string-plus-image-array public schema, field byte limits, real
`YYYY-MM-DD` calendar dates, concise city values, venue-name-only `livehouse`,
separate address and price text, and HTTPS ticket URLs on the fixed provider
allowlist. `weiboURL` is always overlaid from the validated request source (or
empty for text input).
For URL input, `avatar_url` is selected only from the Weibo status author's
avatar metadata, normalized to an allowlisted HTTPS Weibo/Sina image URL, and
never guessed by the model. `imageUrls` is selected independently from explicit
post-picture structures and inline body images; author metadata is never
traversed for this field. URLs retain source order, are de-duplicated after
normalization, and are restricted to allowlisted Weibo/Sina HTTPS image hosts,
at most nine entries, 2,048 characters per URL, and 8,192 UTF-8 bytes in total.
Malformed, untrusted, or over-limit individual image entries are ignored rather
than failing Event extraction. For Text input, `avatar_url` is an empty string
and `imageUrls` is an empty array.

All failures use a fixed typed body:

```json
{
  "version": 1,
  "kind": "reject",
  "code": "invalid_weibo_url"
}
```

The route may return `400 invalid_request`, `405 method_not_allowed`,
`422 invalid_weibo_url`, `422 status_unavailable`,
`422 invalid_model_output`, `429 rate_limited`,
`503 rate_limit_unavailable`, `503 service_unavailable`,
`503 model_unavailable`, `502 weibo_upstream_unavailable`,
`502 invalid_upstream_response`, `504 upstream_timeout`,
`504 model_timeout`, or `500 internal_error`. Responses use
`Cache-Control: no-store` and never include a model/upstream body or source
text.

The anonymous visitor cookie jar exists only inside one request invocation.
The Worker never forwards client cookies, authorization, scanner tokens, or
other client headers to Weibo; redirects are handled manually against a fixed
host allowlist. Candidate URLs, status identifiers, upstream bodies, cookies,
and upstream errors are not logged or returned. Ticket URLs retain the
deterministic provider allowlist and trusted shorteners are inspected for only
one manual hop.

After basic method, content-type, and declared content-length validation, the
dedicated rate limiter runs before any request body is read. The body is then
read as a stream under a 2-second deadline; crossing 32 KiB of UTF-8 bytes
immediately cancels the reader and returns `400 invalid_request`. Visitor
cookies retain RFC-style `Max-Age` precedence over `Expires`, are evicted before
header generation when expired, and remain request-local.

The Worker bundles the pinned `he` package so HTML5 named, numeric, legacy
semicolon-less, and entity-boundary behavior matches Python's
`HTMLParser` plus `html.unescape` without a runtime network lookup.

Production requires a separate rate-limiter binding named
`EVENT_WEIBO_RATE_LIMITER`, configured for 5 calls per 60 seconds. The current
`namespace_id = "1002"` must be confirmed as unique in the target Cloudflare
account before deployment. Missing or unavailable binding state fails closed.
The request-body, Weibo, and DeepSeek stages have independent 2-second,
20-second, and 12-second limits. A separate 36-second hard cap starts before the
dedicated rate-limiter decision and covers every awaited route stage. If that
decision stalls, the route returns `504 upstream_timeout` without reading the
body or calling Weibo or DeepSeek. If the cap expires later, the active request
or response reader is aborted and cancelled where the runtime exposes that
capability. The Weibo allowance is cumulative across the anonymous visitor,
status, optional long-text, and optional ticket-shortener chain. Every stage
allowance remains subject to the 36-second whole-route cap, including limiter,
parsing, and serialization time. This replaces the former single 15-second
budget without treating a longer timeout as a performance fix.

The required `visitor_generate`, `visitor_incarnate`, and `status` operations
each have a 3-second per-attempt limit and at most two sequential attempts. A
successful attempt is never repeated. Each attempt owns an independent abort
controller, and cookies observed by a failed attempt are discarded; only a
fully successful attempt advances the request-local cookie jar. The cumulative
20-second Weibo limit and 36-second route cap always take precedence and prevent
another attempt after either expires.

Optional `long_text` and `ticket_shortener` operations each have one 2-second
attempt and no retry. Long-text failure retains the already validated status
summary, and ticket-shortener failure produces an empty trusted-ticket list, so
the single model call can still proceed. At most one structurally valid trusted
shortener is fetched. Candidate and ticket-provider validation remain
unchanged. Only an optional-operation timeout or the cumulative 20-second Weibo
timeout can fail open this way. The 36-second route cap always propagates as a
fixed timeout, and a final hard-deadline check prevents a model request from
starting after that cap has elapsed.

An internal timeout diagnostic is emitted exactly once only after a required
stage exhausts its attempts, an optional stage reaches its single timeout, or a
global deadline expires while a Weibo operation is active. Its entire value is
one fixed allowlisted stage class: `event_weibo_timeout:visitor_generate`,
`event_weibo_timeout:visitor_incarnate`, `event_weibo_timeout:status`,
`event_weibo_timeout:long_text`, or
`event_weibo_timeout:ticket_shortener`. Model, limiter, and request-body timeouts
never emit this diagnostic. It never contains a URL, host, query, user/status
identifier, cookie, body, credential, or upstream/model content.

## Natural-language typed-plan API

`POST /api/nl/interpret` is an independent, non-scanner route. It is handled
before RunPod token parsing, does not accept or require a Pod ID, and never
proxies to RunPod. Its responses include `Cache-Control: no-store`.

Request:

```json
{
  "version": 1,
  "utterance": "添加 2026-08-01 的夏日祭",
  "localDate": "2026-07-16",
  "timezone": "Asia/Shanghai"
}
```

For a follow-up to a clarification, `draft` contains one previously validated
partial operation and its missing-slot enumeration. It must contain only values
the user already supplied:

```json
{
  "version": 1,
  "utterance": "日期是 2026-08-01",
  "localDate": "2026-07-16",
  "timezone": "Asia/Shanghai",
  "draft": {
    "intent": "addevent",
    "slots": { "name": "夏日祭" },
    "missing": ["date"]
  }
}
```

When `draft` is present, the model may return a fixed reject or exactly one
operation/draft with the same intent. Existing draft slots must be preserved
unchanged, and only slots corresponding to the current `missing` values may be
added. Switching intent, returning multiple operations, dropping or rewriting
existing slots, and adding unrelated optional slots are rejected locally.

An `addevent` operation is complete only when both `name` and `date` are
present. `url` is optional context: it is preserved across clarification, but
it never substitutes for the event name. For example, a URL-only request has
this typed response:

```json
{
  "version": 1,
  "kind": "clarify",
  "draft": {
    "intent": "addevent",
    "slots": { "url": "https://weibo.com/123/event456" }
  },
  "missing": ["event_name", "date"]
}
```

With URL plus name, `missing` is `["date"]`; with URL plus date, it is
`["event_name"]`. Empty Event slots use `["event_name", "date"]` as well:
missing name always maps to `event_name`, regardless of whether a URL is
present. A raw URL is never accepted as the `name` slot. This NL route does not
invoke Event extraction. The standalone Python extractor and the separate
`/api/event/weibo-candidate` Worker route are documented independently above.

Every accepted message is sent to the same DeepSeek interpretation prompt.
There is no prefix, keyword, regex, or other local semantic router and no
scan-only second prompt. A valid typed `unsupported_request` is terminal. The
only optional second model attempt repeats the identical request after invalid
JSON/schema/provenance output and is independent of utterance content.

The strict registry includes the existing Idol, Event, and Cheki operations plus
`navigate`, `open_scan`, `deleteidol`, `favoriteidol`, `editevent`,
`deleteevent`, `editcheki`, `deletecheki`, and the generic record operations
`listrecord`, `showrecord`, `addrecord`, `editrecord`, and `deleterecord`.
Targets, Idol/Event references, scan candidate references, and temporary-result
references are human-readable user text for App-side resolution. Model-created
UUIDs, object/model/file/media identifiers, URIs, and paths are rejected. The
model produces only typed intents and slots, never internal command strings.

Navigation schemas are:

```text
navigate { destination: scan|idols|calendar|events|gallery|settings|chekiroku_import,
           date?: YYYY-MM-DD }
open_scan { recognize_date?: boolean, recognize_idol?: boolean,
            includes_unassigned?: boolean, candidate_refs?: string[],
            fixed_date?: YYYY-MM-DD, date_from?: YYYY-MM-DD,
            date_to?: YYYY-MM-DD }
```

`navigate.date` is calendar-only. `fixed_date` is mutually exclusive with a
range; range endpoints appear together and are ordered. Date fields are
forbidden when `recognize_date` is explicitly false. `candidate_refs` and
`includes_unassigned` are forbidden when `recognize_idol` is explicitly false.
When the recognition boolean is omitted, related fields imply it is enabled.

Generic records use `record_type: cheki|shame|douga`. `showrecord` and
`deleterecord` accept exactly `record_type` and human `target`. `addrecord`
accepts optional `idols`, `event`, `date`, and `note`; `editrecord` adds the
required human `target` and strict patch semantics. Cheki alone may use
positive-integer `idx`, Boolean `favorite`, and `size: mini|wide`.
`listrecord` may omit `record_type`, but must then omit those three Cheki-only
fields. Shame and Douga reject `idx`, `favorite`, and `size`.

Patch operations use omission for no change and an exact unique `clear_fields`
array for explicit clearing. Sentinel strings, `null`, empty strings, unknown
clear names, duplicate clears, and assigning and clearing the same field are
rejected. Clear enums are:

```text
editidol:   group,birthday,color,verification,bio,avatar
editevent:  date,city,livehouse,price,url,ticket_url,note
editcheki:  idols,event,date,idx,user,note,size
editrecord cheki: idols,event,date,idx,note,size
editrecord shame/douga: idols,event,date,note
```

`favorite` is assigned as a JSON Boolean and is never cleared. Destructive
intents remain typed plans; the Worker never claims execution, and the App must
perform confirmation before mutation.

Successful responses have exactly one of these shapes:

```json
{
  "version": 1,
  "kind": "plan",
  "operations": [
    {
      "intent": "addevent",
      "slots": { "name": "夏日祭", "date": "2026-08-01" }
    }
  ]
}
```

```json
{
  "version": 1,
  "kind": "plan",
  "operations": [
    { "intent": "addcheki", "slots": {} }
  ]
}
```

`addscancheki` has the equivalent minimal operation with `slots: {}`. Legacy
`addcheki` validation still accepts historical `else` and `?` size values for
backward compatibility, while the current prompt emits only `mini` or `wide`.
Clarification remains limited to the existing `idol`, `event_name`, and `date`
missing fields.

A plan contains 1 through 50 independently validated operations. Heterogeneous
operations are accepted and their order is preserved for sequential App
execution and per-operation results. A clarification follow-up remains exactly
one operation/draft and cannot expand into a multi-operation plan.

```json
{
  "version": 1,
  "kind": "reject",
  "code": "unsupported_request"
}
```

The Worker returns only fixed reject codes for request, rate-limit, model,
timeout, and upstream failures. It never forwards the model's prose or upstream
error body. The request schema has no image, local-database, confirmation
history, cookie, or secret field, and unknown fields are rejected.

Model-produced dates must be backed by an explicit numeric date in the current
utterance/validated draft or must exactly match deterministic Chinese
today/tomorrow/day-after calculations from `localDate`. `user` and `size` enum
values require a narrow canonical or Chinese phrase mapping, and
`temporary: "all"` requires an explicit all-selection/anaphora phrase. Values
without that evidence are rejected instead of being treated as model defaults.

Required secret:

```powershell
npx wrangler secret put NL_LLM_API_KEY
```

Configured non-secret Worker variables:

- `NL_LLM_MODEL` (default: `deepseek-v4-flash`)
- `NL_LLM_ENDPOINT` (default: the DeepSeek OpenAI-compatible chat-completions
  endpoint; custom endpoints must use HTTPS)

Production requires the configured Cloudflare rate-limiter binding named
`NL_RATE_LIMITER`, currently set to 20 requests per 60 seconds. If it is absent,
invalid, or unavailable, the NL route fails closed with
`rate_limit_unavailable` and does not call the LLM.

Method, content type, and a valid declared body length no greater than 16 KiB
are checked before rate limiting. Once allowed, the request body is streamed
under an independent 2-second body deadline and a 16 KiB UTF-8 byte cap.
Oversized chunks, invalid UTF-8, read failures, aborted requests, and stalled
bodies are cancelled and return the fixed `400 invalid_request` response. The
separate 8-second DeepSeek deadline starts afterward and remains fully
available for the upstream request and response body.

Local development may explicitly set
`NL_ALLOW_IN_MEMORY_RATE_LIMIT="true"` to use a best-effort per-isolate,
per-IP limit of 20 requests per minute. That Map-backed fallback is not a
production configuration or a global rate-limit guarantee.

### Operational diagnosis

The NL route always returns a typed reject body for its own failures. Clients
should decode that body even when the HTTP status is not 200.

- `503 rate_limit_unavailable`: this route is deployed, but its production
  rate-limiter binding is missing or unavailable; the LLM was not called.
- `503 upstream_timeout`: the LLM request or streamed response body exceeded
  the Worker deadline.
- `503 upstream_unavailable`: the LLM network request or upstream HTTP status
  failed.
- `422 invalid_model_output`: the upstream body, JSON, or typed-plan schema was
  invalid.
- Scanner-style `401 Token 无效或已过期` on `/api/nl/interpret`: the request
  fell through to the legacy scanner proxy, so the deployed Worker does not
  match the local NL route implementation.
- `404`: the edge route/domain configuration did not reach this Worker.

The upstream call uses one low-temperature, non-thinking JSON-mode request for
the default DeepSeek endpoint and a bounded token budget. One 8-second Worker
deadline covers connection, response headers, and the complete streamed
response body. This leaves four seconds of response-delivery margin inside the
iOS client's 12-second transport timeout. The Worker cancels and aborts a body
as soon as it exceeds 64 KiB. Neither request bodies nor user utterances are
logged by this code.

If the first HTTP 200 model response is readable but fails JSON, typed schema,
or provenance validation, the Worker may repeat the identical model request
once when at least two seconds remain in that same 8-second deadline. Network,
HTTP, response-stream, oversized-body, and timeout failures are never retried.
Both attempts share one route-level rate-limit decision, and the second output
passes the same strict validator; model prose and invalid output are never
returned to the client.

There is no content-dependent retry or local semantic re-evaluation. A valid
typed `unsupported_request` is returned immediately. The route-level rate-limit
decision runs exactly once even when invalid model output receives the one
content-agnostic retry.

## Local verification

The tests mock the LLM upstream and do not require a model key or paid service:

```powershell
cd cloudflare-worker
npm ci
npm test
node --check src/worker.js
node --check src/cheki-date-annotator.js
node --check src/cheki-date-prompt.js
node --check src/nl-interpreter.js
node --check src/event-weibo-extractor.js
```

## Deploy

```powershell
cd cloudflare-worker
npx wrangler login
npx wrangler deploy
```

After deployment, add `https://api.chekinana.top` to the WeChat Mini Program
valid domains for `request`, `uploadFile`, and `downloadFile`.
