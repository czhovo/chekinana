import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import {
  EVENT_ENDPOINT,
  RequestCookieJar,
  extractEventFieldsFromText,
  extractWeiboCandidateRequest,
  statusReference,
} from "../src/event-weibo-extractor.js";
import { handleRequest } from "../src/worker.js";

const FIXTURES = JSON.parse(readFileSync(
  new URL("../../scripts/event_weibo_extractor/parity_fixtures.json", import.meta.url),
  "utf8",
));
const URL_FIXTURES = JSON.parse(readFileSync(
  new URL("../../scripts/event_weibo_extractor/url_contract_fixtures.json", import.meta.url),
  "utf8",
));

const PUBLIC_URL = "https://weibo.com/1234567890/AbC123";
const EVENT_ENV = {
  EVENT_WEIBO_RATE_LIMITER: { limit: async () => ({ success: true }) },
};

function eventRequest(body = { version: 1, weiboURL: PUBLIC_URL }, headers = {}) {
  return new Request(`https://api.chekinana.top${EVENT_ENDPOINT}`, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify(body),
  });
}

function responseWithCookies(body, cookies = [], init = {}) {
  const headers = new Headers(init.headers || {});
  for (const cookie of cookies) headers.append("set-cookie", cookie);
  return new Response(body, { ...init, headers });
}

function mockVisitorFetch({ statusPayload, assertHeaders } = {}) {
  const calls = [];
  const fetchImpl = async (value, init) => {
    const url = new URL(value);
    calls.push({ url, init });
    assert.equal(init.redirect, "manual");
    assert.equal(init.cache, "no-store");
    assert.equal(init.headers.get("authorization"), null);
    assert.equal(init.headers.get("x-cheki-token"), null);
    if (assertHeaders) assertHeaders(url, init.headers);

    if (url.pathname === "/visitor/genvisitor") {
      assert.equal(init.headers.get("cookie"), null);
      return responseWithCookies(
        'gen_callback({"retcode":20000000,"data":{"tid":"visitor-tid"}})',
        ["GEN=one; Domain=.weibo.com; Path=/; Secure; HttpOnly"],
      );
    }
    if (url.pathname === "/visitor/visitor") {
      assert.match(init.headers.get("cookie") || "", /GEN=one/u);
      return responseWithCookies(
        "cross_domain({})",
        ["VISITOR=anonymous; Domain=.weibo.com; Path=/; Secure; HttpOnly"],
      );
    }
    if (url.pathname === "/ajax/statuses/show") {
      const cookie = init.headers.get("cookie") || "";
      assert.match(cookie, /GEN=one/u);
      assert.match(cookie, /VISITOR=anonymous/u);
      return new Response(JSON.stringify(statusPayload ?? {
        text_raw: "活动名称：星光公演\n演出日期：2026年7月18日\n城市：上海\n地点：MAO Livehouse",
        created_at: "Mon Jul 13 20:00:00 +0800 2026",
        url_struct: [{ long_url: "https://wap.showstart.com/pages/activity/detail/1" }],
      }), { headers: { "content-type": "application/json" } });
    }
    throw new Error("unexpected mock URL");
  };
  return { fetchImpl, calls };
}

for (const fixture of FIXTURES) {
  test(`matches the shared Python fixture: ${fixture.id}`, async () => {
    const candidate = await extractEventFieldsFromText(fixture.text, {
      weiboURL: fixture.weiboURL,
      createdAt: fixture.createdAt,
      structuredURLs: fixture.structuredURLs || [],
    });
    assert.deepEqual(candidate, fixture.expected);
  });
}

test("checks a trusted ticket shortener for one allowlisted hop only", async () => {
  let calls = 0;
  const accepted = await extractEventFieldsFromText("活动名称：测试", {
    weiboURL: PUBLIC_URL,
    structuredURLs: ["https://t.cn/abc"],
    fetchShortener: async () => {
      calls += 1;
      return new Response(null, {
        status: 302,
        headers: { location: "https://wap.showstart.com/event/1" },
      });
    },
  });
  assert.equal(accepted.ticketURL, "https://wap.showstart.com/event/1");
  assert.equal(calls, 1);

  const rejected = await extractEventFieldsFromText("活动名称：测试", {
    weiboURL: PUBLIC_URL,
    structuredURLs: ["https://t.cn/private"],
    fetchShortener: async () => new Response(null, {
      status: 302,
      headers: { location: "http://127.0.0.1/private" },
    }),
  });
  assert.equal(rejected.ticketURL, "");

  const credentialed = await extractEventFieldsFromText("活动名称：测试", {
    weiboURL: PUBLIC_URL,
    structuredURLs: ["https://user@showstart.com/event/1"],
  });
  assert.equal(credentialed.ticketURL, "");
});

test("validates the exact public Weibo status URL shape", () => {
  assert.deepEqual(statusReference(PUBLIC_URL), { user: "1234567890", reference: "AbC123" });
  for (const value of [
    "http://weibo.com/123/AbC",
    "https://example.com/123/AbC",
    "https://user@weibo.com/123/AbC",
    "https://weibo.com:443/123/AbC",
    "https://weibo.com/extra/123/AbC",
    "https://weibo.com/123/not-valid!",
    "https://weibo.com/123/AbC?from=feed",
    "https://weibo.com/123/AbC?",
    "https://weibo.com/123/AbC#detail",
    "https://weibo.com/123/AbC#",
  ]) {
    assert.throws(() => statusReference(value));
  }

  for (const fixture of URL_FIXTURES) {
    if (fixture.valid) {
      assert.deepEqual(statusReference(fixture.url), {
        user: fixture.user,
        reference: fixture.status,
      }, fixture.id);
    } else {
      assert.throws(() => statusReference(fixture.url), undefined, fixture.id);
    }
  }

  assert.deepEqual(statusReference(`https://weibo.com/${"😀".repeat(200)}/AbC`), {
    user: "😀".repeat(200),
    reference: "AbC",
  });
  assert.throws(() => statusReference(`https://weibo.com/${"😀".repeat(201)}/AbC`));
});

test("shared valid URL fixtures reach the fixed status endpoint with decoded references", async () => {
  for (const fixture of [
    ...URL_FIXTURES.filter((item) => item.valid),
    {
      id: "user-at-200-code-points",
      url: `https://weibo.com/${"😀".repeat(200)}/AbC`,
      status: "AbC",
    },
  ]) {
    const visitor = mockVisitorFetch();
    const result = await extractWeiboCandidateRequest(eventRequest({
      version: 1,
      weiboURL: fixture.url,
    }), EVENT_ENV, { fetchImpl: visitor.fetchImpl });
    assert.equal(result.status, 200, fixture.id);
    assert.equal(result.body.candidate.weiboURL, fixture.url, fixture.id);
    const statusCall = visitor.calls.find(({ url }) => url.pathname === "/ajax/statuses/show");
    assert.equal(statusCall?.url.searchParams.get("id"), fixture.status, fixture.id);
    assert.equal(statusCall?.init.headers.get("referer"), new URL(fixture.url).toString(), fixture.id);
  }
});

test("shared invalid URL fixtures and 201-code-point users fail before upstream fetch", async () => {
  for (const fixture of [
    ...URL_FIXTURES.filter((item) => !item.valid),
    {
      id: "user-over-200-code-points",
      url: `https://weibo.com/${"😀".repeat(201)}/AbC`,
    },
  ]) {
    let fetched = false;
    const result = await extractWeiboCandidateRequest(eventRequest({
      version: 1,
      weiboURL: fixture.url,
    }), EVENT_ENV, {
      fetchImpl: async () => { fetched = true; throw new Error("must not fetch"); },
    });
    assert.equal(result.status, 422, fixture.id);
    assert.equal(result.body.code, "invalid_weibo_url", fixture.id);
    assert.equal(fetched, false, fixture.id);
  }
});

test("expires, updates, and deletes request-local visitor cookies", () => {
  let now = Date.parse("2030-01-01T00:00:00Z");
  const jar = new RequestCookieJar(() => now);
  const source = "https://weibo.com/visitor/session";

  jar.absorb(new Headers({
    "set-cookie": "SHORT=lived; Domain=.weibo.com; Path=/; Secure; Max-Age=1",
  }), source);
  assert.equal(jar.header("https://weibo.com/ajax/statuses/show"), "SHORT=lived");
  now += 1_100;
  assert.equal(jar.header("https://weibo.com/ajax/statuses/show"), "");

  jar.absorb(new Headers({
    "set-cookie": "SID=first; Domain=.weibo.com; Path=/; Max-Age=10",
  }), source);
  jar.absorb(new Headers({
    "set-cookie": "SID=second; Domain=.weibo.com; Path=/; Max-Age=20",
  }), source);
  assert.equal(jar.header("https://weibo.com/ajax/statuses/show"), "SID=second");

  jar.absorb(new Headers({
    "set-cookie": "SID=invalid; Domain=.com; Path=/; Max-Age=0",
  }), source);
  assert.equal(jar.header("https://weibo.com/ajax/statuses/show"), "SID=second");

  jar.absorb(new Headers({
    "set-cookie": "SID=deleted; Domain=.weibo.com; Path=/; Expires=Wed, 01 Jan 2040 00:00:00 GMT; Max-Age=0",
  }), source);
  assert.equal(jar.header("https://weibo.com/ajax/statuses/show"), "");

  jar.absorb(new Headers({
    "set-cookie": "PRIORITY=kept; Domain=.weibo.com; Path=/; Expires=Wed, 01 Jan 2020 00:00:00 GMT; Max-Age=10",
  }), source);
  assert.equal(jar.header("https://weibo.com/ajax/statuses/show"), "PRIORITY=kept");
  now += 10_100;
  assert.equal(jar.header("https://weibo.com/ajax/statuses/show"), "");

  const expiresAt = new Date(now + 2_000).toUTCString();
  jar.absorb(new Headers({
    "set-cookie": `EXPIRES=alive; Domain=.weibo.com; Path=/; Expires=${expiresAt}`,
  }), source);
  assert.equal(jar.header("https://weibo.com/ajax/statuses/show"), "EXPIRES=alive");
  now += 2_100;
  assert.equal(jar.header("https://weibo.com/ajax/statuses/show"), "");
});

test("falls back when Worker Set-Cookie accessors throw or return non-arrays", () => {
  const source = "https://weibo.com/visitor/session";
  for (const [id, getSetCookie] of [
    ["throws", () => { throw new TypeError("runtime accessor unavailable"); }],
    ["non-array", () => "not-an-array"],
  ]) {
    const jar = new RequestCookieJar();
    jar.absorb({
      getSetCookie,
      getAll: () => [`FALLBACK_${id.replace("-", "_")}=safe; Domain=.weibo.com; Path=/; Secure`],
      get: () => null,
    }, source);
    assert.match(jar.header("https://weibo.com/ajax/statuses/show"), /^FALLBACK_/u, id);
  }
});

test("returns an exact seven-field candidate without forwarding client credentials", async () => {
  const { fetchImpl, calls } = mockVisitorFetch();
  const response = await handleRequest(eventRequest(undefined, {
    authorization: "Bearer must-not-forward",
    cookie: "USER_SESSION=must-not-forward",
    "x-cheki-token": "must-not-forward",
  }), EVENT_ENV, fetchImpl);

  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.equal(response.headers.get("set-cookie"), null);
  assert.equal(response.headers.get("access-control-allow-origin"), "*");
  assert.deepEqual(await response.json(), {
    version: 1,
    kind: "candidate",
    candidate: {
      name: "星光公演",
      date: "2026-07-18",
      city: "上海",
      livehouse: "MAO Livehouse",
      weiboURL: PUBLIC_URL,
      ticketURL: "https://wap.showstart.com/pages/activity/detail/1",
      note: "",
    },
  });
  assert.equal(calls.length, 3);
});

test("handles long text through the fixed Weibo long-text endpoint", async () => {
  const calls = [];
  const fetchImpl = async (value, init) => {
    const url = new URL(value);
    calls.push(url.pathname);
    if (url.pathname === "/visitor/genvisitor") {
      return new Response('gen_callback({"retcode":20000000,"data":{"tid":"tid"}})');
    }
    if (url.pathname === "/visitor/visitor") return new Response("ok");
    if (url.pathname === "/ajax/statuses/show") {
      return new Response(JSON.stringify({
        isLongText: true,
        mblogid: "AbC123",
        text_raw: "摘要",
        created_at: "Mon Jul 13 20:00:00 +0800 2026",
      }));
    }
    if (url.pathname === "/ajax/statuses/longtext") {
      return new Response(JSON.stringify({ data: { longTextContent: "活动名称：长文公演\n演出日期：2026-08-02" } }));
    }
    throw new Error("unexpected URL");
  };
  const result = await extractWeiboCandidateRequest(eventRequest(), EVENT_ENV, { fetchImpl });
  assert.equal(result.status, 200);
  assert.equal(result.body.candidate.name, "长文公演");
  assert.deepEqual(calls, [
    "/visitor/genvisitor",
    "/visitor/visitor",
    "/ajax/statuses/show",
    "/ajax/statuses/longtext",
  ]);
});

test("resolves one trusted short-link hop without visitor or client credentials", async () => {
  const visitor = mockVisitorFetch({
    statusPayload: {
      text_raw: "活动名称：票务测试",
      created_at: "Mon Jul 13 20:00:00 +0800 2026",
      url_struct: [{ short_url: "https://t.cn/ticket" }],
    },
  });
  let shortenerCalls = 0;
  let detachedCalls = 0;
  const fetchImpl = async function detachedFetch(value, init) {
    assert.equal(this, undefined);
    detachedCalls += 1;
    const url = new URL(value);
    if (url.hostname === "t.cn") {
      shortenerCalls += 1;
      assert.equal(init.redirect, "manual");
      assert.equal(init.headers.get("cookie"), null);
      assert.equal(init.headers.get("authorization"), null);
      assert.equal(init.headers.get("x-cheki-token"), null);
      return new Response(null, {
        status: 302,
        headers: { location: "https://wap.showstart.com/event/1" },
      });
    }
    return visitor.fetchImpl(value, init);
  };
  const result = await extractWeiboCandidateRequest(eventRequest(), EVENT_ENV, { fetchImpl });
  assert.equal(result.status, 200);
  assert.equal(result.body.candidate.ticketURL, "https://wap.showstart.com/event/1");
  assert.equal(shortenerCalls, 1);
  assert.equal(detachedCalls, 4);
});

test("accepts only the exact request schema", async () => {
  let fetched = false;
  const fetchImpl = async () => {
    fetched = true;
    throw new Error("must not fetch");
  };
  for (const body of [
    { version: 1, weiboURL: PUBLIC_URL, extra: true },
    { version: 2, weiboURL: PUBLIC_URL },
    { version: 1 },
    { version: 1, weiboURL: 123 },
  ]) {
    const result = await extractWeiboCandidateRequest(eventRequest(body), EVENT_ENV, { fetchImpl });
    assert.equal(result.status, 400);
    assert.equal(result.body.code, "invalid_request");
  }
  assert.equal(fetched, false);
});

test("charges rate limit before parsing an invalid Weibo URL", async () => {
  let limited = false;
  let fetched = false;
  const result = await extractWeiboCandidateRequest(eventRequest({
    version: 1,
    weiboURL: "https://example.com/123/AbC",
  }), {
    EVENT_WEIBO_RATE_LIMITER: { limit: async () => { limited = true; return { success: true }; } },
  }, {
    fetchImpl: async () => { fetched = true; throw new Error("must not fetch"); },
  });
  assert.equal(result.status, 422);
  assert.equal(result.body.code, "invalid_weibo_url");
  assert.equal(limited, true);
  assert.equal(fetched, false);
});

test("rate limiting happens before invalid JSON body parsing", async () => {
  let fetched = false;
  const request = new Request(`https://api.chekinana.top${EVENT_ENDPOINT}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: "{",
  });
  const result = await extractWeiboCandidateRequest(request, {
    EVENT_WEIBO_RATE_LIMITER: { limit: async () => ({ success: false }) },
  }, {
    fetchImpl: async () => { fetched = true; throw new Error("must not fetch"); },
  });
  assert.equal(result.status, 429);
  assert.equal(result.body.code, "rate_limited");
  assert.equal(fetched, false);
});

test("rejects declared oversized bodies before consuming rate limit", async () => {
  let limited = false;
  const request = eventRequest(undefined, { "content-length": "4097" });
  const result = await extractWeiboCandidateRequest(request, {
    EVENT_WEIBO_RATE_LIMITER: { limit: async () => { limited = true; return { success: true }; } },
  });
  assert.equal(result.status, 400);
  assert.equal(result.body.code, "invalid_request");
  assert.equal(limited, false);
});

test("streaming request-body bound cancels after 4096 UTF-8 bytes", async () => {
  let cancelled = false;
  let limited = 0;
  let fetched = false;
  const stream = new ReadableStream({
    start(controller) {
      controller.enqueue(new Uint8Array(3_000));
      controller.enqueue(new Uint8Array(1_097));
    },
    cancel() {
      cancelled = true;
    },
  });
  const request = new Request(`https://api.chekinana.top${EVENT_ENDPOINT}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: stream,
    duplex: "half",
  });
  const result = await extractWeiboCandidateRequest(request, {
    EVENT_WEIBO_RATE_LIMITER: { limit: async () => { limited += 1; return { success: true }; } },
  }, {
    fetchImpl: async () => { fetched = true; throw new Error("must not fetch"); },
  });
  assert.equal(result.status, 400);
  assert.equal(result.body.code, "invalid_request");
  assert.equal(limited, 1);
  assert.equal(fetched, false);
  assert.equal(cancelled, true);
});

test("a stalled request body is cancelled and rejected within the total deadline", async () => {
  let cancelled = false;
  const stream = new ReadableStream({
    pull() {
      return new Promise(() => {});
    },
    cancel() {
      cancelled = true;
    },
  }, { highWaterMark: 0 });
  const request = new Request(`https://api.chekinana.top${EVENT_ENDPOINT}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: stream,
    duplex: "half",
  });
  const result = await extractWeiboCandidateRequest(request, EVENT_ENV, { deadlineMs: 5 });
  assert.equal(result.status, 400);
  assert.equal(result.body.code, "invalid_request");
  assert.equal(cancelled, true);
});

test("fails closed when the dedicated rate limiter is unavailable", async () => {
  let fetched = false;
  const result = await extractWeiboCandidateRequest(eventRequest(), {}, {
    fetchImpl: async () => { fetched = true; throw new Error("must not fetch"); },
  });
  assert.deepEqual(result, {
    status: 503,
    body: { version: 1, kind: "reject", code: "rate_limit_unavailable" },
  });
  assert.equal(fetched, false);
});

test("enforces the dedicated event rate limiter", async () => {
  let fetched = false;
  const result = await extractWeiboCandidateRequest(eventRequest(), {
    EVENT_WEIBO_RATE_LIMITER: { limit: async () => ({ success: false }) },
  }, {
    fetchImpl: async () => { fetched = true; throw new Error("must not fetch"); },
  });
  assert.equal(result.status, 429);
  assert.equal(result.body.code, "rate_limited");
  assert.equal(fetched, false);
});

test("maps an unavailable public status to the fixed 422 reject", async () => {
  const { fetchImpl } = mockVisitorFetch({ statusPayload: { ok: 0, error: "private upstream detail" } });
  const result = await extractWeiboCandidateRequest(eventRequest(), EVENT_ENV, { fetchImpl });
  assert.equal(result.status, 422);
  assert.deepEqual(result.body, { version: 1, kind: "reject", code: "status_unavailable" });
  assert.doesNotMatch(JSON.stringify(result.body), /private upstream detail/u);
});

test("maps upstream network and schema failures to fixed rejects", async (t) => {
  await t.test("network", async () => {
    const result = await extractWeiboCandidateRequest(eventRequest(), EVENT_ENV, {
      fetchImpl: async () => { throw new Error("private network detail"); },
    });
    assert.deepEqual(result, {
      status: 502,
      body: { version: 1, kind: "reject", code: "weibo_upstream_unavailable" },
    });
  });
  await t.test("synchronous invocation error", async () => {
    const result = await extractWeiboCandidateRequest(eventRequest(), EVENT_ENV, {
      fetchImpl() { throw new Error("private synchronous detail"); },
    });
    assert.deepEqual(result, {
      status: 502,
      body: { version: 1, kind: "reject", code: "weibo_upstream_unavailable" },
    });
    assert.doesNotMatch(JSON.stringify(result.body), /private synchronous detail/u);
  });
  await t.test("schema", async () => {
    const result = await extractWeiboCandidateRequest(eventRequest(), EVENT_ENV, {
      fetchImpl: async () => new Response("not a visitor callback"),
    });
    assert.deepEqual(result, {
      status: 502,
      body: { version: 1, kind: "reject", code: "invalid_upstream_response" },
    });
  });
});

test("applies one total deadline without automatic retry", async () => {
  let calls = 0;
  const result = await extractWeiboCandidateRequest(eventRequest(), EVENT_ENV, {
    deadlineMs: 5,
    fetchImpl: async () => {
      calls += 1;
      return new Promise(() => {});
    },
  });
  assert.equal(result.status, 504);
  assert.equal(result.body.code, "upstream_timeout");
  assert.equal(calls, 1);
});

test("rejects oversized upstream bodies without exposing them", async () => {
  const result = await extractWeiboCandidateRequest(eventRequest(), EVENT_ENV, {
    fetchImpl: async () => new Response("x".repeat(1_048_577)),
  });
  assert.equal(result.status, 502);
  assert.equal(result.body.code, "invalid_upstream_response");
});

test("handles preflight locally before scanner token parsing", async () => {
  const response = await handleRequest(new Request(
    `https://api.chekinana.top${EVENT_ENDPOINT}`,
    { method: "OPTIONS" },
  ));
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.equal(response.headers.get("access-control-allow-origin"), "*");
});

test("returns the typed 405 before scanner token parsing", async () => {
  const response = await handleRequest(new Request(`https://api.chekinana.top${EVENT_ENDPOINT}`), EVENT_ENV);
  assert.equal(response.status, 405);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.deepEqual(await response.json(), {
    version: 1,
    kind: "reject",
    code: "method_not_allowed",
  });
});
