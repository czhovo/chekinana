import test from "node:test";
import assert from "node:assert/strict";

import { handleRequest } from "../src/worker.js";

const LOCAL_TOKEN = "local-test-token-0123456789";
const OTHER_LOCAL_TOKEN = "other-test-token-987654321";
const LOCAL_ENV = {
  CHEKINANA_SCANNER_LOCAL_MODE: "true",
  CHEKINANA_SCANNER_LOCAL_UPSTREAM: "http://127.0.0.1:8080",
  CHEKINANA_SCANNER_LOCAL_TOKEN: LOCAL_TOKEN,
};
const IMAGE_BYTES = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3]);

function scannerRequest(path = "/api/status/task123", options = {}) {
  return new Request(`https://api.chekinana.top${path}`, {
    method: options.method || "GET",
    headers: {
      "x-cheki-token": options.token ?? LOCAL_TOKEN,
      ...(options.headers || {}),
    },
    body: options.body,
  });
}

async function responseBytes(response) {
  return new Uint8Array(await response.arrayBuffer());
}

test("keeps the default production RunPod proxy request and response contract unchanged", async () => {
  let calls = 0;
  const response = await handleRequest(new Request(
    "https://api.chekinana.top/api/status/task123?preserved=1",
    {
      headers: {
        "x-cheki-token": "productiontestpod",
        "x-client-marker": "preserved",
      },
    },
  ), {}, async (value, init = {}) => {
    calls += 1;
    assert.equal(
      value.url,
      "https://productiontestpod-8080.proxy.runpod.net/api/status/task123?preserved=1",
    );
    assert.equal(value.method, "GET");
    assert.equal(value.headers.get("x-cheki-token"), "productiontestpod");
    assert.equal(value.headers.get("x-client-marker"), "preserved");
    assert.deepEqual(init, {});
    return new Response(IMAGE_BYTES, {
      status: 201,
      headers: {
        "content-type": "image/png",
        "x-upstream-marker": "preserved",
      },
    });
  });

  assert.equal(calls, 1);
  assert.equal(response.status, 201);
  assert.equal(response.headers.get("content-type"), "image/png");
  assert.equal(response.headers.get("x-upstream-marker"), "preserved");
  assert.deepEqual(await responseBytes(response), IMAGE_BYTES);
});

test("keeps the production query-token fallback unchanged", async () => {
  const response = await handleRequest(new Request(
    "https://api.chekinana.top/api/status/task123?token=productiontestpod",
  ), {}, async (value) => {
    assert.equal(
      value.url,
      "https://productiontestpod-8080.proxy.runpod.net/api/status/task123?token=productiontestpod",
    );
    return new Response("production");
  });
  assert.equal(await response.text(), "production");
});

test("pins local upstream requests to the configured loopback origin", async () => {
  const response = await handleRequest(scannerRequest(
    "/api/status/task123?next=https%3A%2F%2Fevil.example%2F&token=must-not-forward",
    {
      headers: {
        "cf-connecting-ip": "192.0.2.10",
        "forwarded": "for=192.0.2.11;proto=https",
        "true-client-ip": "192.0.2.12",
        "x-client-ip": "192.0.2.13",
        "x-forwarded-for": "192.0.2.14",
        "x-forwarded-host": "attacker.example",
        "x-forwarded-port": "443",
        "x-forwarded-proto": "https",
        "x-real-ip": "192.0.2.15",
      },
    },
  ), LOCAL_ENV, async (value, init = {}) => {
    const url = new URL(value.url);
    assert.equal(url.protocol, "http:");
    assert.equal(url.hostname, "127.0.0.1");
    assert.equal(url.port, "8080");
    assert.equal(url.pathname, "/api/status/task123");
    assert.equal(url.searchParams.get("next"), "https://evil.example/");
    assert.equal(url.searchParams.get("token"), null);
    assert.equal(value.headers.get("x-cheki-token"), null);
    for (const name of [
      "cf-connecting-ip",
      "forwarded",
      "true-client-ip",
      "x-client-ip",
      "x-forwarded-for",
      "x-forwarded-host",
      "x-forwarded-port",
      "x-forwarded-proto",
      "x-real-ip",
    ]) {
      assert.equal(value.headers.get(name), null);
    }
    assert.deepEqual(init, {});
    return new Response("local-ok", {
      headers: { "x-upstream-marker": "local" },
    });
  });

  assert.equal(response.status, 200);
  assert.equal(response.headers.get("x-upstream-marker"), "local");
  assert.equal(await response.text(), "local-ok");
});

test("accepts only the local header token and never the query token", async () => {
  let fetched = false;
  const response = await handleRequest(new Request(
    `https://api.chekinana.top/api/status/task123?token=${LOCAL_TOKEN}`,
  ), LOCAL_ENV, async () => {
    fetched = true;
    return new Response("unexpected");
  });

  assert.equal(fetched, false);
  assert.equal(response.status, 401);
  assert.deepEqual(await response.json(), {
    ok: false,
    error: "Token 无效或已过期",
  });
});

test("rejects an incorrect local header token without contacting an upstream", async () => {
  let fetched = false;
  const response = await handleRequest(scannerRequest(
    "/api/status/task123",
    { token: OTHER_LOCAL_TOKEN },
  ), LOCAL_ENV, async () => {
    fetched = true;
    return new Response("unexpected");
  });

  assert.equal(fetched, false);
  assert.equal(response.status, 401);
  assert.deepEqual(await response.json(), {
    ok: false,
    error: "Token 无效或已过期",
  });
});

for (const [label, env] of [
  ["missing upstream", {
    CHEKINANA_SCANNER_LOCAL_MODE: "true",
    CHEKINANA_SCANNER_LOCAL_TOKEN: LOCAL_TOKEN,
  }],
  ["missing token", {
    CHEKINANA_SCANNER_LOCAL_MODE: "true",
    CHEKINANA_SCANNER_LOCAL_UPSTREAM: "http://127.0.0.1:8080",
  }],
  ["invalid mode", {
    ...LOCAL_ENV,
    CHEKINANA_SCANNER_LOCAL_MODE: "TRUE",
  }],
  ["disabled mode conflict", {
    ...LOCAL_ENV,
    CHEKINANA_SCANNER_LOCAL_MODE: "false",
  }],
  ["weak token", {
    ...LOCAL_ENV,
    CHEKINANA_SCANNER_LOCAL_TOKEN: "short",
  }],
  ["HTTPS upstream", {
    ...LOCAL_ENV,
    CHEKINANA_SCANNER_LOCAL_UPSTREAM: "https://127.0.0.1:8080",
  }],
  ["localhost upstream", {
    ...LOCAL_ENV,
    CHEKINANA_SCANNER_LOCAL_UPSTREAM: "http://localhost:8080",
  }],
  ["LAN upstream", {
    ...LOCAL_ENV,
    CHEKINANA_SCANNER_LOCAL_UPSTREAM: "http://192.168.1.20:8080",
  }],
  ["userinfo upstream", {
    ...LOCAL_ENV,
    CHEKINANA_SCANNER_LOCAL_UPSTREAM: "http://user@127.0.0.1:8080",
  }],
  ["path upstream", {
    ...LOCAL_ENV,
    CHEKINANA_SCANNER_LOCAL_UPSTREAM: "http://127.0.0.1:8080/api",
  }],
  ["query upstream", {
    ...LOCAL_ENV,
    CHEKINANA_SCANNER_LOCAL_UPSTREAM: "http://127.0.0.1:8080?target=other",
  }],
  ["fragment upstream", {
    ...LOCAL_ENV,
    CHEKINANA_SCANNER_LOCAL_UPSTREAM: "http://127.0.0.1:8080/#other",
  }],
  ["invalid port", {
    ...LOCAL_ENV,
    CHEKINANA_SCANNER_LOCAL_UPSTREAM: "http://127.0.0.1:65536",
  }],
]) {
  test(`fails closed without exposing an invalid local configuration: ${label}`, async () => {
    let fetched = false;
    const response = await handleRequest(scannerRequest(), env, async () => {
      fetched = true;
      return new Response("unexpected");
    });

    assert.equal(fetched, false);
    assert.equal(response.status, 503);
    assert.equal(response.headers.get("cache-control"), "no-store");
    assert.deepEqual(await response.json(), {
      ok: false,
      error: "local_scanner_configuration_invalid",
    });
  });
}

test("removes the local token header and multipart token field before proxying", async () => {
  const formData = new FormData();
  formData.append("token", LOCAL_TOKEN);
  formData.append("wb", "1");
  formData.append("image", new Blob([IMAGE_BYTES], { type: "image/png" }), "source.png");
  const response = await handleRequest(scannerRequest("/api/process", {
    method: "POST",
    headers: { expect: "100-continue" },
    body: formData,
  }), LOCAL_ENV, async (value) => {
    assert.equal(value.headers.get("x-cheki-token"), null);
    assert.equal(value.headers.get("expect"), null);
    const forwarded = await value.formData();
    assert.equal(forwarded.get("token"), null);
    assert.equal(forwarded.get("wb"), "1");
    const image = forwarded.get("image");
    assert.equal(image.name, "source.png");
    assert.equal(image.type, "image/png");
    assert.deepEqual(new Uint8Array(await image.arrayBuffer()), IMAGE_BYTES);
    return Response.json({ status: "queued" });
  });

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { status: "queued" });
});

test("removes Expect while proxying one large multipart task exactly once", async () => {
  const largeImageBytes = new Uint8Array((5 * 1024 * 1024) + 17);
  for (let index = 0; index < largeImageBytes.length; index += 1) {
    largeImageBytes[index] = index % 251;
  }
  const completeTaskId = "0123456789abcdef0123456789abcdef";
  const formData = new FormData();
  formData.append("token", LOCAL_TOKEN);
  formData.append(
    "image",
    new Blob([largeImageBytes], { type: "image/jpeg" }),
    "large-source.jpg",
  );
  let calls = 0;

  const response = await handleRequest(scannerRequest("/api/process", {
    method: "POST",
    headers: { expect: "100-continue" },
    body: formData,
  }), LOCAL_ENV, async (value) => {
    calls += 1;
    assert.equal(value.headers.get("x-cheki-token"), null);
    assert.equal(value.headers.get("expect"), null);
    const forwarded = await value.formData();
    assert.equal(forwarded.get("token"), null);
    const image = forwarded.get("image");
    assert.equal(image.name, "large-source.jpg");
    assert.equal(image.type, "image/jpeg");
    assert.deepEqual(
      new Uint8Array(await image.arrayBuffer()),
      largeImageBytes,
    );
    return Response.json({ task_id: completeTaskId, status: "queued" });
  });

  assert.equal(calls, 1);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    task_id: completeTaskId,
    status: "queued",
  });
});

test("removes top-level local token fields from JSON and form bodies", async (t) => {
  await t.test("JSON", async () => {
    const response = await handleRequest(scannerRequest("/api/auth/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ token: LOCAL_TOKEN, keep: "yes" }),
    }), LOCAL_ENV, async (value) => {
      assert.deepEqual(await value.json(), { keep: "yes" });
      return Response.json({ ok: true });
    });
    assert.equal(response.status, 200);
  });

  await t.test("URL encoded", async () => {
    const response = await handleRequest(scannerRequest("/api/cancel/task123", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: `token=${encodeURIComponent(LOCAL_TOKEN)}&keep=yes`,
    }), LOCAL_ENV, async (value) => {
      const forwarded = new URLSearchParams(await value.text());
      assert.equal(forwarded.get("token"), null);
      assert.equal(forwarded.get("keep"), "yes");
      return Response.json({ ok: true });
    });
    assert.equal(response.status, 200);
  });
});

test("rejects unsupported local request bodies instead of forwarding a possible token", async () => {
  let fetched = false;
  const response = await handleRequest(scannerRequest("/api/process", {
    method: "POST",
    headers: { "content-type": "application/octet-stream" },
    body: LOCAL_TOKEN,
  }), LOCAL_ENV, async () => {
    fetched = true;
    return new Response("unexpected");
  });

  assert.equal(fetched, false);
  assert.equal(response.status, 400);
  assert.deepEqual(await response.json(), {
    ok: false,
    error: "local_scanner_request_invalid",
  });
});

test("maps local upstream failures to a fixed error without leaking details", async () => {
  const response = await handleRequest(scannerRequest(), LOCAL_ENV, async () => {
    throw new Error("private operating-system network detail");
  });

  assert.equal(response.status, 502);
  assert.equal(response.headers.get("cache-control"), "no-store");
  const body = await response.json();
  assert.deepEqual(body, {
    ok: false,
    error: "local_scanner_upstream_unavailable",
  });
  assert.doesNotMatch(JSON.stringify(body), /private|127\.0\.0\.1|8080/u);
});

test("preserves date annotation behavior in local mode without forwarding the scanner token", async () => {
  let backendCalls = 0;
  let qwenCalls = 0;
  const limiterKeys = [];
  const env = {
    ...LOCAL_ENV,
    CHEKI_DATE_QWEN_API_KEY: "test-only-qwen-key",
    CHEKI_DATE_QWEN_BASE_URL: "https://qwen.test/compatible/v1",
    CHEKI_DATE_RATE_LIMITER: {
      limit: async ({ key }) => {
        limiterKeys.push(key);
        return { success: true };
      },
    },
  };
  const response = await handleRequest(scannerRequest(
    "/api/result/task123/0?date_annotation=1",
    { headers: { "cf-connecting-ip": "192.0.2.10" } },
  ), env, async (value, init = {}) => {
    const url = new URL(value instanceof Request ? value.url : value);
    if (url.hostname === "127.0.0.1") {
      backendCalls += 1;
      assert.equal(url.toString(), "http://127.0.0.1:8080/api/result/task123/0");
      assert.equal(value.headers.get("x-cheki-token"), null);
      return new Response(IMAGE_BYTES, {
        headers: {
          "content-type": "image/png",
          "x-upstream-marker": "preserved",
        },
      });
    }

    qwenCalls += 1;
    assert.equal(url.toString(), "https://qwen.test/compatible/v1/chat/completions");
    const headers = new Headers(init.headers);
    assert.equal(headers.get("x-cheki-token"), null);
    assert.equal(headers.get("authorization"), "Bearer test-only-qwen-key");
    assert.equal(init.body.includes(LOCAL_TOKEN), false);
    return Response.json({
      choices: [{
        message: {
          content: JSON.stringify({
            reasoning: "test-only",
            Date: { bbox: [10, 20, 30, 40], text: "2026.07.23" },
          }),
        },
      }],
    });
  });

  assert.equal(backendCalls, 1);
  assert.equal(qwenCalls, 1);
  assert.deepEqual(limiterKeys, ["local-scanner"]);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("x-upstream-marker"), "preserved");
  assert.equal(response.headers.get("x-cheki-date-status"), "detected");
  assert.equal(response.headers.get("x-cheki-date-text"), "2026.07.23");
  assert.equal(response.headers.get("x-cheki-date-bbox"), "10,20,30,40");
  assert.deepEqual(await responseBytes(response), IMAGE_BYTES);
});

test("uses one unspoofable local date-limit key across rotating forwarding headers", async () => {
  const limiterKeys = [];
  let qwenCalls = 0;
  const env = {
    ...LOCAL_ENV,
    CHEKI_DATE_QWEN_API_KEY: "test-only-qwen-key",
    CHEKI_DATE_QWEN_BASE_URL: "https://qwen.test/compatible/v1",
    CHEKI_DATE_RATE_LIMITER: {
      limit: async ({ key }) => {
        limiterKeys.push(key);
        return { success: limiterKeys.length <= 5 };
      },
    },
  };
  const fetchImpl = async (value) => {
    const url = new URL(value instanceof Request ? value.url : value);
    if (url.hostname === "127.0.0.1") {
      assert.equal(value.headers.get("cf-connecting-ip"), null);
      assert.equal(value.headers.get("forwarded"), null);
      assert.equal(value.headers.get("x-forwarded-for"), null);
      assert.equal(value.headers.get("x-real-ip"), null);
      return new Response(IMAGE_BYTES, {
        headers: { "content-type": "image/png" },
      });
    }
    qwenCalls += 1;
    return Response.json({
      choices: [{
        message: {
          content: JSON.stringify({
            reasoning: "none",
            Date: null,
          }),
        },
      }],
    });
  };

  for (let index = 0; index < 6; index += 1) {
    const response = await handleRequest(scannerRequest(
      "/api/result/task123/0?date_annotation=1",
      {
        headers: {
          "cf-connecting-ip": `192.0.2.${index + 1}`,
          "forwarded": `for=198.51.100.${index + 1}`,
          "x-forwarded-for": `203.0.113.${index + 1}`,
          "x-real-ip": `198.18.0.${index + 1}`,
        },
      },
    ), env, fetchImpl);
    assert.equal(
      response.headers.get("x-cheki-date-status"),
      index < 5 ? "not_detected" : "unavailable",
    );
    if (index === 5) {
      assert.equal(response.headers.get("x-cheki-date-error"), "rate_limited");
    }
    await response.arrayBuffer();
  }

  assert.deepEqual(limiterKeys, Array(6).fill("local-scanner"));
  assert.equal(qwenCalls, 5);
});

test("keeps the production date-limit client IP key unchanged", async () => {
  const limiterKeys = [];
  const env = {
    CHEKI_DATE_QWEN_API_KEY: "test-only-qwen-key",
    CHEKI_DATE_QWEN_BASE_URL: "https://qwen.test/compatible/v1",
    CHEKI_DATE_RATE_LIMITER: {
      limit: async ({ key }) => {
        limiterKeys.push(key);
        return { success: true };
      },
    },
  };
  const response = await handleRequest(new Request(
    "https://api.chekinana.top/api/result/task123/0?date_annotation=1",
    {
      headers: {
        "x-cheki-token": "productiontestpod",
        "cf-connecting-ip": "192.0.2.44",
        "x-forwarded-for": "198.51.100.44",
      },
    },
  ), env, async (value) => {
    const url = new URL(value instanceof Request ? value.url : value);
    if (url.hostname.endsWith(".proxy.runpod.net")) {
      return new Response(IMAGE_BYTES, {
        headers: { "content-type": "image/png" },
      });
    }
    return Response.json({
      choices: [{
        message: {
          content: JSON.stringify({
            reasoning: "none",
            Date: null,
          }),
        },
      }],
    });
  });

  assert.deepEqual(limiterKeys, ["192.0.2.44"]);
  assert.equal(response.headers.get("x-cheki-date-status"), "not_detected");
  await response.arrayBuffer();
});
