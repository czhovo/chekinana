import test from "node:test";
import assert from "node:assert/strict";

import {
  CHEKI_DATE_MAX_IMAGE_BYTES,
  CHEKI_DATE_QWEN_TIMEOUT_MS,
  annotateChekiDateResponse,
  normalizeQwenDateOutput,
} from "../src/cheki-date-annotator.js";
import { CHEKI_DATE_PROMPT } from "../src/cheki-date-prompt.js";
import { handleRequest as workerHandleRequest } from "../src/worker.js";

const IMAGE_BYTES = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3, 4]);
const TEST_ENV = {
  CHEKI_DATE_QWEN_API_KEY: "test-only-qwen-key",
  CHEKI_DATE_QWEN_BASE_URL: "https://qwen.test/compatible/v1",
};

test("uses a 90-second total Qwen request-and-response deadline", () => {
  assert.equal(CHEKI_DATE_QWEN_TIMEOUT_MS, 90_000);
});

function withMockRuntime(env, fetchImpl) {
  return {
    ...env,
    SCANNER_RUNTIME: {
      idFromName: () => "test-runtime",
      get: () => ({
        async fetch(request) {
          const url = new URL(request.url);
          url.protocol = "https:";
          url.hostname = "testpod-8080.proxy.runpod.net";
          url.searchParams.delete("token");
          if (/^\/api\/result\/[^/]+\/\d+$/u.test(url.pathname)) {
            url.searchParams.delete("date_annotation");
          }
          const headers = new Headers(request.headers);
          headers.set("x-cheki-token", "testpod");
          return fetchImpl(new Request(url.toString(), {
            method: request.method,
            headers,
            redirect: "manual",
          }));
        },
      }),
    },
  };
}

function handleRequest(request, env = {}, fetchImpl = fetch) {
  return workerHandleRequest(request, withMockRuntime(env, fetchImpl), fetchImpl);
}

function resultRequest(path = "/api/result/task123/0?date_annotation=1", headers = {}) {
  return new Request(`https://api.chekinana.top${path}`, {
    method: "GET",
    headers: {
      "x-cheki-token": "testpod",
      "cf-connecting-ip": "203.0.113.10",
      ...headers,
    },
  });
}

function qwenEnvelope(candidate) {
  const content = typeof candidate === "string" ? candidate : JSON.stringify(candidate);
  return new Response(JSON.stringify({
    choices: [{ message: { content } }],
  }), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

function detectedCandidate(text = "2026.07.04", bbox = [100, 700, 450, 820]) {
  return {
    reasoning: "test-only reasoning",
    Date: { bbox, text },
  };
}

function standaloneDateRequest({
  bytes = IMAGE_BYTES,
  mediaType = "image/png",
  headers = {},
  body = bytes,
  signal,
} = {}) {
  return new Request("https://api.chekinana.top/api/cheki/date-annotation", {
    method: "POST",
    headers: {
      "content-type": mediaType,
      ...headers,
    },
    body,
    ...(body instanceof ReadableStream ? { duplex: "half" } : {}),
    ...(signal ? { signal } : {}),
  });
}

test("date prompt uses a recent-past preference only to break visually plausible ties", () => {
  assert.match(CHEKI_DATE_PROMPT, /参考日期为 2026 年 8 月 2 日/u);
  assert.match(CHEKI_DATE_PROMPT, /仅用于视觉平局裁决/u);
  assert.match(CHEKI_DATE_PROMPT, /优先不晚于参考日期且距离它较近的候选/u);
  assert.match(CHEKI_DATE_PROMPT, /2026 是可见笔画允许的合法候选时，优先转录为 2026/u);
  assert.match(CHEKI_DATE_PROMPT, /只有可见笔画明确支持未来日期时才允许输出/u);
  assert.match(CHEKI_DATE_PROMPT, /不确定时输出 null/u);
});

test("date prompt keeps month-day output and forbids inventing a year", () => {
  assert.match(CHEKI_DATE_PROMPT, /不脑补年份/u);
  assert.match(CHEKI_DATE_PROMPT, /只有月日时必须输出 `MM\.DD`/u);
  assert.match(CHEKI_DATE_PROMPT, /不得给只有月日的图像补全年份/u);
});

for (const mediaType of ["image/jpeg", "image/png", "image/webp"]) {
  test(`standalone date endpoint accepts ${mediaType} without RunPod`, async () => {
    let qwenCalls = 0;
    const response = await workerHandleRequest(standaloneDateRequest({
      mediaType,
      headers: {
        authorization: "Bearer client-secret-must-not-forward",
        cookie: "client-private=true",
      },
    }), TEST_ENV, async (value, init = {}) => {
      qwenCalls += 1;
      assert.equal(new URL(value).hostname, "qwen.test");
      const requestHeaders = new Headers(init.headers);
      assert.equal(requestHeaders.get("authorization"), "Bearer test-only-qwen-key");
      assert.equal(requestHeaders.get("cookie"), null);
      assert.doesNotMatch(init.body, /client-secret-must-not-forward|client-private/u);
      const qwenBody = JSON.parse(init.body);
      assert.match(
        qwenBody.messages[1].content[0].image_url.url,
        new RegExp(`^data:${mediaType.replace("/", "\\/")};base64,`, "u"),
      );
      return qwenEnvelope(detectedCandidate());
    });

    assert.equal(response.status, 200);
    assert.equal(response.headers.get("cache-control"), "no-store");
    assert.equal(response.headers.get("access-control-allow-origin"), "*");
    assert.deepEqual(await response.json(), {
      status: "detected",
      text: "2026.07.04",
      precision: "full_date",
      bbox: [100, 700, 450, 820],
    });
    assert.equal(qwenCalls, 1);
  });
}

test("standalone date endpoint returns not_detected as bounded JSON", async () => {
  const response = await workerHandleRequest(
    standaloneDateRequest(),
    TEST_ENV,
    async () => qwenEnvelope({ reasoning: "none", Date: null }),
  );
  assert.deepEqual(await response.json(), { status: "not_detected" });
});

test("standalone date endpoint preserves bytes across incremental Base64 blocks", async () => {
  const bytes = Uint8Array.from(
    { length: (3 * 0x2000) + 5 },
    (_, index) => index % 251,
  );
  let qwenCalls = 0;
  const response = await workerHandleRequest(
    standaloneDateRequest({ bytes }),
    TEST_ENV,
    async (_url, init) => {
      qwenCalls += 1;
      const body = JSON.parse(init.body);
      const dataURL = body.messages[1].content[0].image_url.url;
      assert.equal(
        dataURL,
        `data:image/png;base64,${Buffer.from(bytes).toString("base64")}`,
      );
      return qwenEnvelope({ reasoning: "none", Date: null });
    },
  );
  assert.equal(qwenCalls, 1);
  assert.deepEqual(await response.json(), { status: "not_detected" });
});

test("standalone date endpoint rejects unsupported and declared oversized images before Qwen", async () => {
  for (const [request, expectedError] of [
    [standaloneDateRequest({ mediaType: "application/octet-stream" }), "unsupported_image_type"],
    [standaloneDateRequest({
      headers: { "content-length": String(CHEKI_DATE_MAX_IMAGE_BYTES + 1) },
    }), "image_too_large"],
  ]) {
    let fetched = false;
    const response = await workerHandleRequest(request, TEST_ENV, async () => {
      fetched = true;
      throw new Error("must not call Qwen");
    });
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), {
      status: "unavailable",
      error: expectedError,
    });
    assert.equal(fetched, false);
  }
});

test("standalone date endpoint bounds an undeclared oversized stream before Qwen", async () => {
  let qwenCalls = 0;
  const chunk = new Uint8Array(1024 * 1024);
  let remaining = 17;
  const body = new ReadableStream({
    pull(controller) {
      if (remaining === 0) {
        controller.close();
        return;
      }
      remaining -= 1;
      controller.enqueue(chunk);
    },
  });
  const response = await workerHandleRequest(
    standaloneDateRequest({ body }),
    TEST_ENV,
    async () => {
      qwenCalls += 1;
      throw new Error("must not call Qwen");
    },
  );
  assert.deepEqual(await response.json(), {
    status: "unavailable",
    error: "image_too_large",
  });
  assert.equal(qwenCalls, 0);
});

test("standalone date endpoint bounds a stalled image body and cancels it", async () => {
  let canceled = false;
  let qwenCalls = 0;
  const body = new ReadableStream({
    pull() {},
    cancel() { canceled = true; },
  });
  const response = await workerHandleRequest(
    standaloneDateRequest({ body }),
    {
      ...TEST_ENV,
      __TEST_CHEKI_DATE_IMAGE_TIMEOUT_MS: 5,
    },
    async () => {
      qwenCalls += 1;
      throw new Error("must not call Qwen");
    },
  );
  assert.deepEqual(await response.json(), {
    status: "unavailable",
    error: "image_read_timeout",
  });
  assert.equal(canceled, true);
  assert.equal(qwenCalls, 0);
});

test("standalone date endpoint bounds Qwen and returns only a safe failure", async () => {
  let qwenCalls = 0;
  const response = await workerHandleRequest(
    standaloneDateRequest(),
    {
      ...TEST_ENV,
      __TEST_CHEKI_DATE_QWEN_TIMEOUT_MS: 5,
    },
    async () => {
      qwenCalls += 1;
      return new Promise(() => {});
    },
  );
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    status: "unavailable",
    error: "qwen_timeout",
  });
  assert.equal(qwenCalls, 1);
});

test("client cancellation aborts an in-flight Qwen request", async () => {
  const controller = new AbortController();
  let qwenSignal;
  let notifyStarted;
  const started = new Promise((resolve) => { notifyStarted = resolve; });
  const pending = workerHandleRequest(
    standaloneDateRequest({ signal: controller.signal }),
    TEST_ENV,
    async (_url, init) => {
      qwenSignal = init.signal;
      notifyStarted();
      return new Promise((resolve, reject) => {
        init.signal.addEventListener("abort", () => reject(init.signal.reason), {
          once: true,
        });
      });
    },
  );
  await started;
  assert.equal(qwenSignal.aborted, false);
  controller.abort("client canceled");
  const response = await pending;
  assert.equal(qwenSignal.aborted, true);
  assert.deepEqual(await response.json(), {
    status: "unavailable",
    error: "qwen_unavailable",
  });
});

test("standalone date endpoint rejects invalid model output without echoing it", async () => {
  const unsafeModelText = "private-model-output-must-not-leak";
  const response = await workerHandleRequest(
    standaloneDateRequest(),
    TEST_ENV,
    async () => qwenEnvelope(unsafeModelText),
  );
  const responseText = await response.text();
  assert.deepEqual(JSON.parse(responseText), {
    status: "unavailable",
    error: "invalid_model_output",
  });
  assert.doesNotMatch(responseText, new RegExp(unsafeModelText, "u"));
});

test("standalone date endpoint handles method, service failure, and CORS without echoing input", async () => {
  let fetched = false;
  const method = await workerHandleRequest(new Request(
    "https://api.chekinana.top/api/cheki/date-annotation",
  ), TEST_ENV, async () => {
    fetched = true;
    throw new Error("must not fetch");
  });
  assert.equal(method.status, 405);
  assert.deepEqual(await method.json(), {
    status: "unavailable",
    error: "method_not_allowed",
  });

  const unavailableResponse = await workerHandleRequest(
    standaloneDateRequest(),
    {},
    async () => {
      fetched = true;
      throw new Error("must not fetch");
    },
  );
  assert.deepEqual(await unavailableResponse.json(), {
    status: "unavailable",
    error: "service_unavailable",
  });

  const preflight = await workerHandleRequest(new Request(
    "https://api.chekinana.top/api/cheki/date-annotation",
    { method: "OPTIONS" },
  ), {}, async () => {
    fetched = true;
    throw new Error("must not fetch");
  });
  assert.equal(preflight.status, 200);
  assert.equal(preflight.headers.get("cache-control"), "no-store");
  assert.equal(preflight.headers.get("access-control-allow-origin"), "*");
  assert.match(preflight.headers.get("access-control-allow-methods") || "", /POST/u);
  assert.equal(fetched, false);
});

function makeProxyAndQwenFetch({
  candidate = detectedCandidate(),
  upstreamStatus = 200,
  upstreamType = "image/png",
  upstreamBody = IMAGE_BYTES,
  onRunPod,
  onQwen,
  qwenResponse,
} = {}) {
  const calls = [];
  const fetchImpl = async (value, init = {}) => {
    const url = new URL(value instanceof Request ? value.url : value);
    calls.push({ url, init, value });
    if (url.hostname.endsWith(".proxy.runpod.net")) {
      onRunPod?.(url, init, value);
      return new Response(upstreamBody, {
        status: upstreamStatus,
        headers: {
          "content-type": upstreamType,
          "x-upstream-marker": "preserved",
        },
      });
    }
    onQwen?.(url, init, value);
    return qwenResponse ?? qwenEnvelope(candidate);
  };
  return { calls, fetchImpl };
}

async function responseBytes(response) {
  return new Uint8Array(await response.arrayBuffer());
}

test("annotates only the current two-segment result route and strips the Worker-only query", async () => {
  let qwenCalls = 0;
  const mock = makeProxyAndQwenFetch({
    onRunPod(url, init, value) {
      assert.equal(url.pathname, "/api/result/task123/7");
      assert.equal(url.searchParams.get("date_annotation"), null);
      assert.equal(url.searchParams.get("download"), "1");
      assert.equal(value.headers.get("x-cheki-token"), "testpod");
      assert.deepEqual(init, {});
    },
    onQwen() {
      qwenCalls += 1;
    },
  });
  const response = await handleRequest(resultRequest(
    "/api/result/task123/7?download=1&date_annotation=1",
  ), TEST_ENV, mock.fetchImpl);

  assert.equal(response.status, 200);
  assert.equal(qwenCalls, 1);
  assert.deepEqual(await responseBytes(response), IMAGE_BYTES);
  assert.equal(response.headers.get("content-type"), "image/png");
  assert.equal(response.headers.get("x-upstream-marker"), "preserved");
  assert.equal(response.headers.get("x-cheki-date-status"), "detected");
  assert.equal(response.headers.get("x-cheki-date-text"), "2026.07.04");
  assert.equal(response.headers.get("x-cheki-date-precision"), "full_date");
  assert.equal(response.headers.get("x-cheki-date-bbox"), "100,700,450,820");
  assert.equal(response.headers.get("x-cheki-date-error"), null);
  assert.equal(response.headers.get("cache-control"), "no-store");
});

test("preserves a non-200 upstream image response and does not send a partial image to Qwen", async () => {
  let qwenCalls = 0;
  const mock = makeProxyAndQwenFetch({
    upstreamStatus: 206,
    onQwen() {
      qwenCalls += 1;
    },
  });
  const response = await handleRequest(resultRequest(), TEST_ENV, mock.fetchImpl);

  assert.equal(qwenCalls, 0);
  assert.equal(response.status, 206);
  assert.equal(response.headers.get("content-type"), "image/png");
  assert.equal(response.headers.get("x-upstream-marker"), "preserved");
  assert.equal(response.headers.get("x-cheki-date-status"), "unavailable");
  assert.equal(response.headers.get("x-cheki-date-error"), "image_unavailable");
  assert.deepEqual(await responseBytes(response), IMAGE_BYTES);
});

for (const { label, candidate, expected } of [
  {
    label: "full date",
    candidate: detectedCandidate("2024.02.29", [0, 1, 999, 1000]),
    expected: {
      status: "detected",
      text: "2024.02.29",
      precision: "full_date",
      bbox: "0,1,999,1000",
    },
  },
  {
    label: "month and day",
    candidate: detectedCandidate("02.29", [5, 6, 7, 8]),
    expected: {
      status: "detected",
      text: "02.29",
      precision: "month_day",
      bbox: "5,6,7,8",
    },
  },
  {
    label: "no date",
    candidate: { reasoning: "none", Date: null },
    expected: {
      status: "not_detected",
      text: null,
      precision: null,
      bbox: null,
    },
  },
]) {
  test(`returns fixed date headers for ${label}`, async () => {
    const mock = makeProxyAndQwenFetch({ candidate });
    const response = await handleRequest(resultRequest(), TEST_ENV, mock.fetchImpl);

    assert.equal(response.headers.get("x-cheki-date-status"), expected.status);
    assert.equal(response.headers.get("x-cheki-date-text"), expected.text);
    assert.equal(response.headers.get("x-cheki-date-precision"), expected.precision);
    assert.equal(response.headers.get("x-cheki-date-bbox"), expected.bbox);
    assert.equal(response.headers.get("x-cheki-date-error"), null);
    assert.deepEqual(await responseBytes(response), IMAGE_BYTES);
  });
}

test("sends only the fixed prompt and image Data URL to Qwen", async () => {
  let qwenCalls = 0;
  const mock = makeProxyAndQwenFetch({
    onQwen(url, init) {
      qwenCalls += 1;
      assert.equal(url.toString(), "https://qwen.test/compatible/v1/chat/completions");
      assert.equal(init.method, "POST");
      assert.equal(init.redirect, "manual");
      const headers = new Headers(init.headers);
      assert.equal(headers.get("authorization"), "Bearer test-only-qwen-key");
      assert.equal(headers.get("content-type"), "application/json");
      assert.equal(headers.get("x-cheki-token"), null);
      assert.equal(headers.get("cookie"), null);

      const body = JSON.parse(init.body);
      assert.equal(body.model, "qwen3.7-flash");
      assert.equal(body.max_tokens, 1024);
      assert.equal(body.stream, false);
      assert.equal(body.enable_thinking, false);
      assert.equal(body.messages.length, 2);
      assert.equal(body.messages[0].role, "system");
      assert.match(body.messages[0].content, /手写日期/u);
      assert.deepEqual(Object.keys(body.messages[1]), ["role", "content"]);
      assert.equal(body.messages[1].content.length, 1);
      const image = body.messages[1].content[0];
      assert.equal(image.type, "image_url");
      assert.match(image.image_url.url, /^data:image\/png;base64,/u);
      assert.deepEqual(
        new Uint8Array(Buffer.from(image.image_url.url.split(",", 2)[1], "base64")),
        IMAGE_BYTES,
      );
      assert.equal(image.min_pixels, 65_536);
      assert.equal(image.max_pixels, 2_621_440);
      assert.doesNotMatch(init.body, /task123|testpod|203\.0\.113\.10/u);
    },
  });
  const response = await handleRequest(resultRequest(), TEST_ENV, mock.fetchImpl);
  assert.equal(qwenCalls, 1);
  assert.equal(response.headers.get("x-cheki-date-status"), "detected");
  await response.arrayBuffer();
});

test("ordinary result proxy behavior remains unchanged and never calls Qwen", async () => {
  let qwenCalls = 0;
  const mock = makeProxyAndQwenFetch({
    onQwen() {
      qwenCalls += 1;
    },
  });
  const response = await handleRequest(
    resultRequest("/api/result/task123/0?download=1"),
    TEST_ENV,
    mock.fetchImpl,
  );

  assert.equal(qwenCalls, 0);
  assert.equal(mock.calls.length, 1);
  assert.equal(mock.calls[0].url.searchParams.get("download"), "1");
  assert.equal(response.headers.get("x-cheki-date-status"), null);
  assert.equal(response.headers.get("cache-control"), null);
  assert.deepEqual(await responseBytes(response), IMAGE_BYTES);
});

for (const path of [
  "/api/result/task123?date_annotation=1",
  "/api/result/task123/0/extra?date_annotation=1",
  "/api/status/task123?date_annotation=1",
  "/api/process?date_annotation=1",
  "/api/cancel/task123?date_annotation=1",
]) {
  test(`does not annotate a non-target route: ${path}`, async () => {
    let qwenCalls = 0;
    const mock = makeProxyAndQwenFetch({
      onQwen() {
        qwenCalls += 1;
      },
    });
    const response = await handleRequest(resultRequest(path), TEST_ENV, mock.fetchImpl);
    assert.equal(qwenCalls, 0);
    assert.equal(response.headers.get("x-cheki-date-status"), null);
    await response.arrayBuffer();
  });
}

for (const path of [
  "/api/result/task123/0?date_annotation=0",
  "/api/result/task123/0?date_annotation=true",
  "/api/result/task123/0?date_annotation=1&date_annotation=1",
  "/api/result/task123/0?date_annotation=1&date_annotation=0",
]) {
  test(`requires exactly one explicit date_annotation=1 flag: ${path}`, async () => {
    let qwenCalls = 0;
    const mock = makeProxyAndQwenFetch({
      onQwen() {
        qwenCalls += 1;
      },
    });
    const response = await handleRequest(resultRequest(path), TEST_ENV, mock.fetchImpl);
    assert.equal(qwenCalls, 0);
    assert.equal(response.headers.get("x-cheki-date-status"), null);
    assert.equal(mock.calls[0].url.searchParams.get("date_annotation"), null);
    await response.arrayBuffer();
  });
}

for (const {
  label,
  env,
  qwenResponse,
  qwenThrows,
  expectedError,
  expectedQwenCalls,
} of [
  {
    label: "missing Qwen key",
    env: {
      CHEKI_DATE_QWEN_BASE_URL: "https://qwen.test/compatible/v1",
    },
    expectedError: "service_unavailable",
    expectedQwenCalls: 0,
  },
  {
    label: "non-HTTPS Qwen endpoint",
    env: {
      ...TEST_ENV,
      CHEKI_DATE_QWEN_BASE_URL: "http://qwen.test/compatible/v1",
    },
    expectedError: "service_unavailable",
    expectedQwenCalls: 0,
  },
  {
    label: "Qwen fetch failure",
    env: TEST_ENV,
    qwenThrows: true,
    expectedError: "qwen_unavailable",
    expectedQwenCalls: 1,
  },
  {
    label: "Qwen HTTP failure",
    env: TEST_ENV,
    qwenResponse: new Response("private upstream detail", { status: 500 }),
    expectedError: "qwen_unavailable",
    expectedQwenCalls: 1,
  },
  {
    label: "invalid Qwen JSON",
    env: TEST_ENV,
    qwenResponse: qwenEnvelope("not JSON"),
    expectedError: "invalid_model_output",
    expectedQwenCalls: 1,
  },
]) {
  test(`fails open for the image and closed for the model on ${label}`, async () => {
    let qwenCalls = 0;
    const fetchImpl = async (value) => {
      const url = new URL(value instanceof Request ? value.url : value);
      if (url.hostname.endsWith(".proxy.runpod.net")) {
        return new Response(IMAGE_BYTES, {
          headers: { "content-type": "image/png", "x-upstream-marker": "preserved" },
        });
      }
      qwenCalls += 1;
      if (qwenThrows) throw new Error("private upstream detail");
      return qwenResponse;
    };
    const response = await handleRequest(resultRequest(), env, fetchImpl);

    assert.equal(qwenCalls, expectedQwenCalls);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("content-type"), "image/png");
    assert.equal(response.headers.get("x-upstream-marker"), "preserved");
    assert.equal(response.headers.get("x-cheki-date-status"), "unavailable");
    assert.equal(response.headers.get("x-cheki-date-error"), expectedError);
    assert.doesNotMatch(JSON.stringify([...response.headers]), /private upstream detail/u);
    assert.deepEqual(await responseBytes(response), IMAGE_BYTES);
  });
}

test("does not retry invalid Qwen output", async () => {
  let qwenCalls = 0;
  const mock = makeProxyAndQwenFetch({
    onQwen() {
      qwenCalls += 1;
    },
    qwenResponse: qwenEnvelope("not JSON"),
  });
  const response = await handleRequest(resultRequest(), TEST_ENV, mock.fetchImpl);
  assert.equal(qwenCalls, 1);
  assert.equal(response.headers.get("x-cheki-date-error"), "invalid_model_output");
  assert.deepEqual(await responseBytes(response), IMAGE_BYTES);
});

test("cancels an oversized Qwen response and preserves the image", async () => {
  let qwenCalls = 0;
  const mock = makeProxyAndQwenFetch({
    onQwen() {
      qwenCalls += 1;
    },
    qwenResponse: new Response("x".repeat(32_769), { status: 200 }),
  });
  const response = await handleRequest(resultRequest(), TEST_ENV, mock.fetchImpl);
  assert.equal(qwenCalls, 1);
  assert.equal(response.headers.get("x-cheki-date-status"), "unavailable");
  assert.equal(response.headers.get("x-cheki-date-error"), "invalid_model_output");
  assert.deepEqual(await responseBytes(response), IMAGE_BYTES);
});

test("returns the original non-image upstream response with unavailable headers", async () => {
  let qwenCalls = 0;
  const mock = makeProxyAndQwenFetch({
    upstreamStatus: 404,
    upstreamType: "application/json",
    upstreamBody: "{\"error\":\"missing\"}",
    onQwen() {
      qwenCalls += 1;
    },
  });
  const response = await handleRequest(resultRequest(), TEST_ENV, mock.fetchImpl);
  assert.equal(qwenCalls, 0);
  assert.equal(response.status, 404);
  assert.equal(response.headers.get("content-type"), "application/json");
  assert.equal(response.headers.get("x-cheki-date-status"), "unavailable");
  assert.equal(response.headers.get("x-cheki-date-error"), "image_unavailable");
  assert.equal(await response.text(), "{\"error\":\"missing\"}");
});

test("does not call Qwen for an unsupported successful content type", async () => {
  let qwenCalls = 0;
  const mock = makeProxyAndQwenFetch({
    upstreamType: "application/octet-stream",
    onQwen() {
      qwenCalls += 1;
    },
  });
  const response = await handleRequest(resultRequest(), TEST_ENV, mock.fetchImpl);
  assert.equal(qwenCalls, 0);
  assert.equal(response.headers.get("x-cheki-date-status"), "unavailable");
  assert.equal(response.headers.get("x-cheki-date-error"), "unsupported_image_type");
  assert.deepEqual(await responseBytes(response), IMAGE_BYTES);
});

test("rejects a declared oversized image for annotation without dropping it", async () => {
  let qwenCalls = 0;
  const fetchImpl = async (value) => {
    const url = new URL(value instanceof Request ? value.url : value);
    if (url.hostname.endsWith(".proxy.runpod.net")) {
      return new Response(IMAGE_BYTES, {
        headers: {
          "content-type": "image/png",
          "content-length": String(CHEKI_DATE_MAX_IMAGE_BYTES + 1),
        },
      });
    }
    qwenCalls += 1;
    return qwenEnvelope(detectedCandidate());
  };
  const response = await handleRequest(resultRequest(), TEST_ENV, fetchImpl);
  assert.equal(qwenCalls, 0);
  assert.equal(response.headers.get("x-cheki-date-error"), "image_too_large");
  assert.deepEqual(await responseBytes(response), IMAGE_BYTES);
});

test("times out one Qwen request without retry and preserves the image", async () => {
  let qwenCalls = 0;
  const upstream = new Response(IMAGE_BYTES, {
    headers: { "content-type": "image/png" },
  });
  const result = await annotateChekiDateResponse(
    resultRequest(),
    upstream,
    TEST_ENV,
    {
      qwenTimeoutMs: 5,
      fetchImpl: async () => {
        qwenCalls += 1;
        return new Promise(() => {});
      },
    },
  );
  assert.equal(qwenCalls, 1);
  assert.deepEqual(result, { status: "unavailable", error: "qwen_timeout" });
  assert.deepEqual(await responseBytes(upstream), IMAGE_BYTES);
});

test("exposes all annotation headers to browser clients", async () => {
  const mock = makeProxyAndQwenFetch();
  const response = await handleRequest(resultRequest(), TEST_ENV, mock.fetchImpl);
  const exposed = response.headers.get("access-control-expose-headers") || "";
  for (const name of [
    "x-cheki-date-status",
    "x-cheki-date-text",
    "x-cheki-date-precision",
    "x-cheki-date-bbox",
    "x-cheki-date-error",
  ]) {
    assert.match(exposed, new RegExp(name, "u"));
  }
});

test("handles annotated result preflight locally without a Pod or Qwen call", async () => {
  let fetched = false;
  const response = await handleRequest(new Request(
    "https://api.chekinana.top/api/result/task123/0?date_annotation=1",
    { method: "OPTIONS" },
  ), {}, async () => {
    fetched = true;
    throw new Error("must not fetch");
  });
  assert.equal(fetched, false);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.equal(response.headers.get("access-control-allow-origin"), "*");
  assert.match(
    response.headers.get("access-control-expose-headers") || "",
    /x-cheki-date-status/u,
  );
});

test("strictly accepts only the documented Qwen date schema", () => {
  assert.deepEqual(normalizeQwenDateOutput(detectedCandidate()), {
    status: "detected",
    text: "2026.07.04",
    precision: "full_date",
    bbox: [100, 700, 450, 820],
  });
  assert.deepEqual(normalizeQwenDateOutput({
    reasoning: "",
    Date: { bbox: [0, 0, 1, 1], text: "02.29" },
  }), {
    status: "detected",
    text: "02.29",
    precision: "month_day",
    bbox: [0, 0, 1, 1],
  });
  assert.deepEqual(normalizeQwenDateOutput({ reasoning: "none", Date: null }), {
    status: "not_detected",
  });
});

for (const [label, candidate] of [
  ["non-object", []],
  ["missing reasoning", { Date: null }],
  ["non-string reasoning", { reasoning: 1, Date: null }],
  ["extra top-level key", { reasoning: "", Date: null, extra: true }],
  ["extra Date key", { reasoning: "", Date: { bbox: [1, 2, 3, 4], text: "01.01", extra: true } }],
  ["float bbox", detectedCandidate("01.01", [1.5, 2, 3, 4])],
  ["boolean bbox", detectedCandidate("01.01", [true, 2, 3, 4])],
  ["short bbox", detectedCandidate("01.01", [1, 2, 3])],
  ["reversed x bbox", detectedCandidate("01.01", [5, 2, 3, 4])],
  ["reversed y bbox", detectedCandidate("01.01", [1, 5, 3, 4])],
  ["negative bbox", detectedCandidate("01.01", [-1, 2, 3, 4])],
  ["oversized bbox", detectedCandidate("01.01", [1, 2, 3, 1001])],
  ["invalid full date", detectedCandidate("2023.02.29")],
  ["invalid month day", detectedCandidate("04.31")],
  ["un-normalized date", detectedCandidate("2026.7.4")],
  ["hyphenated date", detectedCandidate("2026-07-04")],
  ["year zero", detectedCandidate("0000.01.01")],
]) {
  test(`rejects strict model output violation: ${label}`, () => {
    assert.equal(normalizeQwenDateOutput(candidate), null);
  });
}
