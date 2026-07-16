# chekinana Cloudflare Worker

This Worker provides a fixed API domain:

```text
https://api.chekinana.top
```

Scanner requests send the current RunPod Pod ID in `X-Cheki-Token`. The Worker
forwards those requests to:

```text
https://<pod-id>-8080.proxy.runpod.net
```

## Event candidate from a public Weibo URL

`POST /api/event/weibo-candidate` is an independent, non-scanner route. It
does not accept a Pod ID, does not use the LLM, and never proxies to RunPod.
The exact request is:

```json
{
  "version": 1,
  "weiboURL": "https://weibo.com/1234567890/AbC123"
}
```

Only one exact public `https://weibo.com/<user>/<ASCII-status-id>` or
`https://www.weibo.com/<user>/<ASCII-status-id>` URL is accepted. Userinfo,
ports, repeated or trailing slashes, query strings, and fragments are rejected.
Both raw path segments use strict percent and UTF-8 decoding: malformed escapes,
invalid UTF-8, decoded control characters, and decoded `/`, `?`, or `#` in the
user segment are rejected. The decoded user is limited to 1–200 Unicode code
points and the decoded status must be ASCII alphanumeric. The Worker does not
fetch the supplied URL. It extracts the status reference and calls only fixed
Weibo visitor, status, and optional long-text endpoints.

A successful response contains exactly seven candidate strings:

```json
{
  "version": 1,
  "kind": "candidate",
  "candidate": {
    "name": "示例公演",
    "date": "2026-08-02",
    "city": "合肥",
    "livehouse": "示例Livehouse",
    "weiboURL": "https://weibo.com/1234567890/AbC123",
    "ticketURL": "",
    "note": ""
  }
}
```

Missing or ambiguous fields remain empty strings. The response is a candidate,
not a persistence instruction: the client must display every field for editing
and save only after explicit user confirmation.

All failures use a fixed typed body:

```json
{
  "version": 1,
  "kind": "reject",
  "code": "invalid_weibo_url"
}
```

The route may return `400 invalid_request`, `405 method_not_allowed`,
`422 invalid_weibo_url`, `422 status_unavailable`, `429 rate_limited`,
`503 rate_limit_unavailable`, `502 weibo_upstream_unavailable`,
`502 invalid_upstream_response`, `504 upstream_timeout`, or
`500 internal_error`. Responses use `Cache-Control: no-store`.

The anonymous visitor cookie jar exists only inside one request invocation.
The Worker never forwards client cookies, authorization, scanner tokens, or
other client headers to Weibo; redirects are handled manually against a fixed
host allowlist. Candidate URLs, status identifiers, upstream bodies, cookies,
and upstream errors are not logged or returned. Ticket URLs retain the
deterministic provider allowlist and trusted shorteners are inspected for only
one manual hop.

After basic method, content-type, and declared content-length validation, the
dedicated rate limiter runs before any request body is read. The body is then
read as a stream under the same total deadline; crossing 4096 UTF-8 bytes
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
The full visitor/status/extraction operation has one 15-second deadline and no
automatic retry.

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

The model registry mirrors the iOS typed-plan client exactly: `addidol`,
`addevent`, `listidol`, `listevent`, `scancheki`, `addcheki`, `addscancheki`,
`listcheki`, `showidol`, `showevent`, and `showcheki`. `scancheki` refers to
photos already selected by the App and has no model-produced scanner slots;
`addcheki` uses selected album photos; `addscancheki` saves existing temporary
scan results. The model produces only typed intents and slots, never executable
App command strings.

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
  "kind": "clarify",
  "draft": { "intent": "addcheki", "slots": { "idols": ["小爱"] } },
  "missing": ["event_or_date"]
}
```

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

There is one additional narrow re-evaluation path for selected-photo scanning.
When the first response is an exact, valid `unsupported_request`, a local
detector may request one second model decision only if the complete utterance is
a standalone, affirmative request whose sole action is scanning photos already
selected in the App and at least two seconds remain. The detector only gates the
second LLM call; it never creates or executes a plan. The second request uses a
fixed scan-only prompt under the same 8-second deadline, rate-limit decision,
typed schema, and validator. Only exact `scancheki {}` is accepted; any other
model result or re-evaluation failure preserves the first
`unsupported_request`, including fetch, HTTP, response-stream, read, oversized
body, and deadline failures. Negation, questions, quotation/explanation,
translation, conditional wording, prompt injection, substring-only mentions,
and requests combined with save, add, delete, or another action do not enter
this path. Error mapping for the ordinary first model call is unchanged.

## Local verification

The tests mock the LLM upstream and do not require a model key or paid service:

```powershell
cd cloudflare-worker
npm ci
npm test
node --check src/worker.js
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
