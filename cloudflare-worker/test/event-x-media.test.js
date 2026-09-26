import test from "node:test";
import assert from "node:assert/strict";

import {
  X_MEDIA_ENDPOINT,
  normalizedXMediaSourceURL,
  proxiedXMediaURL,
  proxyXMediaRequest,
} from "../src/event-x-media.js";
import { handleRequest } from "../src/worker.js";

const SOURCE = "https://pbs.twimg.com/media/HPHVJCmaMAAL1go.jpg?name=orig";
const PROXY = `https://api.chekinana.top${X_MEDIA_ENDPOINT}?url=${encodeURIComponent(SOURCE)}`;

function mediaRequest(value = PROXY, init = {}) {
  return new Request(value, { method: "GET", ...init });
}

function imageResponse(bytes = new Uint8Array([0xff, 0xd8, 0xff, 0xd9]), init = {}) {
  return new Response(bytes, {
    ...init,
    status: init.status ?? 200,
    headers: { "content-type": "image/jpeg", ...init.headers },
  });
}

test("X media proxy URL has a fixed public contract and canonical pbs source", () => {
  assert.equal(normalizedXMediaSourceURL(SOURCE), SOURCE);
  assert.equal(proxiedXMediaURL(SOURCE), PROXY);
  assert.equal(
    proxiedXMediaURL("https://PBS.TWIMG.COM/media/one.jpg"),
    `https://api.chekinana.top${X_MEDIA_ENDPOINT}?url=${encodeURIComponent("https://pbs.twimg.com/media/one.jpg")}`,
  );
});

test("X media route fetches only the source image without forwarding client credentials", async () => {
  let fetchCalls = 0;
  const response = await handleRequest(mediaRequest(PROXY, {
    headers: {
      authorization: "Bearer client-secret",
      cookie: "session=client-secret",
      "x-cheki-token": "scanner-secret",
    },
  }), {}, async (value, init) => {
    fetchCalls += 1;
    assert.equal(value, SOURCE);
    assert.equal(init.method, "GET");
    assert.equal(init.redirect, "manual");
    assert.equal(init.cache, "no-store");
    const headers = new Headers(init.headers);
    assert.equal(headers.get("authorization"), null);
    assert.equal(headers.get("cookie"), null);
    assert.equal(headers.get("x-cheki-token"), null);
    assert.equal(headers.get("accept"), "image/avif,image/webp,image/png,image/jpeg,image/gif");
    return imageResponse();
  });
  assert.equal(fetchCalls, 1);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("content-type"), "image/jpeg");
  assert.equal(response.headers.get("access-control-allow-origin"), "*");
  assert.equal(response.headers.get("cache-control"), "public, max-age=86400");
  assert.equal(response.headers.get("x-content-type-options"), "nosniff");
  assert.deepEqual([...new Uint8Array(await response.arrayBuffer())], [0xff, 0xd8, 0xff, 0xd9]);
});

test("X media route caches validated responses and serves a later hit without upstream fetch", async () => {
  const entries = new Map();
  const cache = {
    async match(request) {
      return entries.get(request.url)?.clone();
    },
    async put(request, response) {
      entries.set(request.url, response.clone());
    },
  };
  let fetchCalls = 0;
  const fetchImpl = async () => {
    fetchCalls += 1;
    return imageResponse(new Uint8Array([1, 2, 3]));
  };
  const first = await handleRequest(mediaRequest(), {}, fetchImpl, { xMediaCache: cache });
  assert.equal(first.status, 200);
  assert.deepEqual([...new Uint8Array(await first.arrayBuffer())], [1, 2, 3]);
  const second = await handleRequest(mediaRequest(), {}, async () => {
    throw new Error("cache hit must avoid upstream");
  }, { xMediaCache: cache });
  assert.equal(second.status, 200);
  assert.deepEqual([...new Uint8Array(await second.arrayBuffer())], [1, 2, 3]);
  assert.equal(fetchCalls, 1);
  assert.equal(entries.size, 1);
});

test("X media cache API failures fail open to the restricted upstream", async () => {
  const response = await handleRequest(mediaRequest(), {}, async () => imageResponse(), {
    xMediaCache: {
      async match() { throw new Error("cache unavailable"); },
      async put() { throw new Error("cache unavailable"); },
    },
  });
  assert.equal(response.status, 200);
});

test("X media route rejects invalid methods, query shapes, and source URLs", async () => {
  const invalid = [
    new Request(PROXY, { method: "POST" }),
    mediaRequest(`https://api.chekinana.top${X_MEDIA_ENDPOINT}`),
    mediaRequest(`${PROXY}&url=${encodeURIComponent(SOURCE)}`),
    mediaRequest(`${PROXY}&extra=1`),
    mediaRequest(`https://api.chekinana.top${X_MEDIA_ENDPOINT}?url=${encodeURIComponent("http://pbs.twimg.com/media/a.jpg")}`),
    mediaRequest(`https://api.chekinana.top${X_MEDIA_ENDPOINT}?url=${encodeURIComponent("https://user:pass@pbs.twimg.com/media/a.jpg")}`),
    mediaRequest(`https://api.chekinana.top${X_MEDIA_ENDPOINT}?url=${encodeURIComponent("https://pbs.twimg.com:444/media/a.jpg")}`),
    mediaRequest(`https://api.chekinana.top${X_MEDIA_ENDPOINT}?url=${encodeURIComponent("https://pbs.twimg.com./media/a.jpg")}`),
    mediaRequest(`https://api.chekinana.top${X_MEDIA_ENDPOINT}?url=${encodeURIComponent("https://pbs.twimg.com.evil.example/media/a.jpg")}`),
    mediaRequest(`https://api.chekinana.top${X_MEDIA_ENDPOINT}?url=${encodeURIComponent("https://pbs.twimg.com/media/a.jpg#fragment")}`),
  ];
  let fetchCalls = 0;
  for (const request of invalid) {
    const response = await proxyXMediaRequest(request, {
      fetchImpl: async () => { fetchCalls += 1; return imageResponse(); },
    });
    assert.equal(response.status, request.method === "POST" ? 405 : 400);
    assert.equal(response.headers.get("cache-control"), "no-store");
  }
  assert.equal(fetchCalls, 0);
});

test("X media redirects remain HTTPS on the exact pbs host", async () => {
  let calls = 0;
  const accepted = await proxyXMediaRequest(mediaRequest(), {
    fetchImpl: async (value) => {
      calls += 1;
      if (calls === 1) {
        return new Response(null, {
          status: 302,
          headers: { location: "https://pbs.twimg.com/media/redirected.jpg" },
        });
      }
      assert.equal(value, "https://pbs.twimg.com/media/redirected.jpg");
      return imageResponse();
    },
  });
  assert.equal(accepted.status, 200);

  for (const location of [
    "https://example.com/media/a.jpg",
    "http://pbs.twimg.com/media/a.jpg",
    "https://pbs.twimg.com:444/media/a.jpg",
  ]) {
    let redirectCalls = 0;
    const rejected = await proxyXMediaRequest(mediaRequest(), {
      fetchImpl: async () => {
        redirectCalls += 1;
        return new Response(null, { status: 302, headers: { location } });
      },
    });
    assert.equal(rejected.status, 502);
    assert.equal(redirectCalls, 1);
  }
});

test("X media route rejects non-images and declared or streamed oversized images", async () => {
  const nonImage = await proxyXMediaRequest(mediaRequest(), {
    fetchImpl: async () => new Response("not an image", {
      headers: { "content-type": "text/html" },
    }),
  });
  assert.equal(nonImage.status, 502);

  const declared = await proxyXMediaRequest(mediaRequest(), {
    maximumBytes: 4,
    fetchImpl: async () => imageResponse(new Uint8Array([1]), {
      headers: { "content-length": "5" },
    }),
  });
  assert.equal(declared.status, 502);

  const streamed = await proxyXMediaRequest(mediaRequest(), {
    maximumBytes: 4,
    fetchImpl: async () => imageResponse(new Uint8Array([1, 2, 3, 4, 5])),
  });
  assert.equal(streamed.status, 502);
});

test("X media cleanup does not wait for a delayed cancel promise", async () => {
  let cancelCalls = 0;
  let rejectCancel;
  const delayedCancel = new Promise((_, reject) => {
    rejectCancel = reject;
  });
  const body = new ReadableStream({
    start(controller) {
      controller.enqueue(new Uint8Array([1]));
    },
    cancel() {
      cancelCalls += 1;
      return delayedCancel;
    },
  });
  const pending = proxyXMediaRequest(mediaRequest(), {
    maximumBytes: 4,
    fetchImpl: async () => new Response(body, {
      headers: {
        "content-length": "5",
        "content-type": "image/jpeg",
      },
    }),
  });
  const result = await Promise.race([
    pending,
    new Promise((resolve) => setTimeout(() => resolve("cancel_blocked_response"), 100)),
  ]);

  assert.notEqual(result, "cancel_blocked_response");
  assert.equal(result.status, 502);
  assert.equal(cancelCalls, 1);
  rejectCancel(new Error("expected delayed cancel rejection"));
  await new Promise((resolve) => setTimeout(resolve, 0));
});

test("X media does not request a redirect hop after the absolute deadline", async () => {
  let fetchCalls = 0;
  let cancelCalls = 0;
  const response = await proxyXMediaRequest(mediaRequest(), {
    timeoutMs: 5,
    fetchImpl: async () => {
      fetchCalls += 1;
      assert.equal(fetchCalls, 1, "a request started after the deadline");
      const blockedUntil = Date.now() + 15;
      while (Date.now() < blockedUntil) {
        // Keep the timer task pending so the absolute deadline check is exercised.
      }
      return new Response(new ReadableStream({
        start(controller) {
          controller.enqueue(new Uint8Array([1]));
        },
        cancel() {
          cancelCalls += 1;
        },
      }), {
        status: 302,
        headers: { location: "https://pbs.twimg.com/media/redirected.jpg" },
      });
    },
  });

  assert.equal(response.status, 504);
  assert.equal(fetchCalls, 1);
  assert.equal(cancelCalls, 1);
  assert.deepEqual(await response.json(), {
    version: 1,
    kind: "reject",
    code: "x_media_upstream_timeout",
  });
});

test("X media route enforces its independent timeout", async () => {
  const response = await proxyXMediaRequest(mediaRequest(), {
    timeoutMs: 5,
    fetchImpl: async () => new Promise(() => {}),
  });
  assert.equal(response.status, 504);
  assert.deepEqual(await response.json(), {
    version: 1,
    kind: "reject",
    code: "x_media_upstream_timeout",
  });
});
