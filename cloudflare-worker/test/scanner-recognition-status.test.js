import test from "node:test";
import assert from "node:assert/strict";

import { handleRequest } from "../src/worker.js";

const LOCAL_TOKEN = "local-recognition-token-012345";
const PRODUCTION_TOKEN = "productiontestpod";
const TASK_ID = "0123456789abcdef0123456789abcdef";
const INTERNAL_PATH = "/api/internal/scanner/date-annotations";
const LOCAL_ENV = {
  CHEKINANA_SCANNER_LOCAL_MODE: "true",
  CHEKINANA_SCANNER_LOCAL_UPSTREAM: "http://127.0.0.1:8080",
  CHEKINANA_SCANNER_LOCAL_TOKEN: LOCAL_TOKEN,
  CHEKI_DATE_QWEN_API_KEY: "test-only-qwen-key",
  CHEKI_DATE_QWEN_BASE_URL: "https://qwen.test/compatible/v1",
};

function pngHeader(width, height, marker = 0) {
  return new Uint8Array([
    137, 80, 78, 71, 13, 10, 26, 10,
    0, 0, 0, 13, 73, 72, 68, 82,
    (width >>> 24) & 255,
    (width >>> 16) & 255,
    (width >>> 8) & 255,
    width & 255,
    (height >>> 24) & 255,
    (height >>> 16) & 255,
    (height >>> 8) & 255,
    height & 255,
    8, 2, 0, 0, 0, marker,
  ]);
}

function pngBytes(width, height, length, marker = 0) {
  const bytes = new Uint8Array(length);
  bytes.set(pngHeader(width, height, marker));
  return bytes;
}

function internalPayload(count = 6) {
  return {
    task_id: TASK_ID,
    results: Array.from({ length: count }, (_, id) => ({
      id,
      artifact_id: id * 2 + 1,
    })),
  };
}

function internalRequest(payload = internalPayload(), options = {}) {
  return new Request(`https://api.chekinana.top${INTERNAL_PATH}`, {
    method: options.method || "POST",
    headers: {
      "content-type": "application/json",
      "x-cheki-token": options.token ?? LOCAL_TOKEN,
      ...(options.headers || {}),
    },
    body: options.method === "GET" ? undefined : JSON.stringify(payload),
  });
}

function qwenResponse(candidate) {
  return Response.json({
    choices: [{
      message: { content: JSON.stringify(candidate) },
    }],
  });
}

test("handles six artifacts in one authenticated request with one limiter decision and concurrent Qwen calls", async () => {
  let limiterCalls = 0;
  let artifactCalls = 0;
  let qwenCalls = 0;
  let activeQwenCalls = 0;
  let maximumActiveQwenCalls = 0;
  let releaseQwen;
  const qwenGate = new Promise((resolve) => {
    releaseQwen = resolve;
  });
  const env = {
    ...LOCAL_ENV,
    CHEKI_DATE_RATE_LIMITER: {
      limit: async ({ key }) => {
        limiterCalls += 1;
        assert.equal(key, "local-scanner");
        return { success: true };
      },
    },
  };

  const response = await handleRequest(
    internalRequest(),
    env,
    async (value, init = {}) => {
      const url = new URL(value instanceof Request ? value.url : value);
      if (url.hostname === "127.0.0.1") {
        artifactCalls += 1;
        assert.equal(value.headers.get("x-cheki-token"), null);
        assert.equal(value.headers.get("cf-connecting-ip"), null);
        assert.equal(value.headers.get("x-forwarded-for"), null);
        const artifactId = Number(url.pathname.split("/").at(-1));
        return new Response(pngHeader(1_200, 1_908, artifactId), {
          headers: {
            "content-type": "image/png",
            "content-length": "30",
          },
        });
      }

      qwenCalls += 1;
      activeQwenCalls += 1;
      maximumActiveQwenCalls = Math.max(
        maximumActiveQwenCalls,
        activeQwenCalls,
      );
      if (qwenCalls === 6) releaseQwen();
      await qwenGate;
      const headers = new Headers(init.headers);
      assert.equal(headers.get("x-cheki-token"), null);
      assert.equal(headers.get("cookie"), null);
      activeQwenCalls -= 1;
      return qwenResponse({
        reasoning: "test-only",
        Date: {
          bbox: [100, 200, 900, 800],
          text: "2026.07.26",
        },
      });
    },
  );

  assert.equal(response.status, 200);
  assert.equal(limiterCalls, 1);
  assert.equal(artifactCalls, 6);
  assert.equal(qwenCalls, 6);
  assert.equal(maximumActiveQwenCalls, 6);
  const payload = await response.json();
  assert.equal(payload.status, "done");
  assert.equal(payload.results.length, 6);
  for (let id = 0; id < 6; id += 1) {
    assert.deepEqual(payload.results[id], {
      id,
      date: "2026.07.26",
      bbox: [120, 381, 1_080, 1_527],
    });
  }
  assert.equal(JSON.stringify(payload).includes("data:image"), false);
});

test("starts seventeen artifacts as 16+1 logical-worker waves", async () => {
  let limiterCalls = 0;
  let artifactCalls = 0;
  let firstWaveArtifactCalls = 0;
  let secondWaveArtifactCalls = 0;
  let activeArtifactCalls = 0;
  let maximumActiveArtifactCalls = 0;
  let qwenCalls = 0;
  let firstWaveReleased = false;
  let releaseFirstWave;
  const firstWaveGate = new Promise((resolve) => {
    releaseFirstWave = resolve;
  });
  const env = {
    ...LOCAL_ENV,
    CHEKI_DATE_RATE_LIMITER: {
      limit: async () => {
        limiterCalls += 1;
        return { success: true };
      },
    },
  };

  const response = await handleRequest(
    internalRequest(internalPayload(17)),
    env,
    async (value) => {
      const url = new URL(value instanceof Request ? value.url : value);
      if (url.hostname === "127.0.0.1") {
        artifactCalls += 1;
        if (firstWaveReleased) {
          secondWaveArtifactCalls += 1;
        } else {
          firstWaveArtifactCalls += 1;
        }
        activeArtifactCalls += 1;
        maximumActiveArtifactCalls = Math.max(
          maximumActiveArtifactCalls,
          activeArtifactCalls,
        );
        if (artifactCalls === 16) {
          firstWaveReleased = true;
          releaseFirstWave();
        }
        await firstWaveGate;
        activeArtifactCalls -= 1;
        const artifactId = Number(url.pathname.split("/").at(-1));
        return new Response(pngHeader(1_200, 1_908, artifactId), {
          headers: {
            "content-type": "image/png",
            "content-length": "30",
          },
        });
      }

      qwenCalls += 1;
      return qwenResponse({ reasoning: "none", Date: null });
    },
  );

  assert.equal(response.status, 200);
  assert.equal(limiterCalls, 1);
  assert.equal(artifactCalls, 17);
  assert.equal(qwenCalls, 17);
  assert.equal(firstWaveArtifactCalls, 16);
  assert.equal(secondWaveArtifactCalls, 1);
  assert.equal(maximumActiveArtifactCalls, 16);
  assert.equal(activeArtifactCalls, 0);
  const payload = await response.json();
  assert.equal(payload.status, "done");
  assert.equal(payload.results.length, 17);
});

test("bounds sixteen maximum-size images to one materialized Qwen stage and releases the gate", async () => {
  const imageLength = 3 * 1024 * 1024;
  let observedGate = null;
  let qwenCalls = 0;
  let activeQwenCalls = 0;
  let maximumActiveQwenCalls = 0;
  let markFirstQwenStarted;
  const firstQwenStarted = new Promise((resolve) => {
    markFirstQwenStarted = resolve;
  });
  let releaseQwen;
  const qwenGate = new Promise((resolve) => {
    releaseQwen = resolve;
  });
  const env = {
    ...LOCAL_ENV,
    CHEKI_DATE_RATE_LIMITER: {
      limit: async () => ({ success: true }),
    },
    __TEST_CHEKI_DATE_MODEL_GATE_OBSERVER: (gate) => {
      observedGate = gate;
    },
  };

  const responsePromise = handleRequest(
    internalRequest(internalPayload(16)),
    env,
    async (value) => {
      const url = new URL(value instanceof Request ? value.url : value);
      if (url.hostname === "127.0.0.1") {
        const artifactId = Number(url.pathname.split("/").at(-1));
        const bytes = pngBytes(1_200, 1_908, imageLength, artifactId);
        return new Response(bytes, {
          headers: {
            "content-type": "image/png",
            "content-length": String(bytes.byteLength),
          },
        });
      }

      qwenCalls += 1;
      activeQwenCalls += 1;
      maximumActiveQwenCalls = Math.max(
        maximumActiveQwenCalls,
        activeQwenCalls,
      );
      markFirstQwenStarted();
      await qwenGate;
      activeQwenCalls -= 1;
      return qwenResponse({ reasoning: "none", Date: null });
    },
  );

  await firstQwenStarted;
  assert.ok(observedGate);
  assert.deepEqual(observedGate.snapshot(), {
    activeCount: 1,
    usedEstimatedBytes: 24 * 1024 * 1024,
    queuedCount: 15,
  });
  assert.equal(qwenCalls, 1);
  releaseQwen();

  const response = await responsePromise;
  assert.equal(response.status, 200);
  assert.equal(qwenCalls, 16);
  assert.equal(maximumActiveQwenCalls, 1);
  assert.equal(activeQwenCalls, 0);
  assert.deepEqual(observedGate.snapshot(), {
    activeCount: 0,
    usedEstimatedBytes: 0,
    queuedCount: 0,
  });
});

test("settles every worker and releases the model gate after one artifact or Qwen failure", async (t) => {
  for (const failure of ["artifact", "qwen"]) {
    await t.test(failure, async () => {
      let observedGate = null;
      let artifactCalls = 0;
      let qwenCalls = 0;
      const env = {
        ...LOCAL_ENV,
        CHEKI_DATE_RATE_LIMITER: {
          limit: async () => ({ success: true }),
        },
        __TEST_CHEKI_DATE_MODEL_GATE_OBSERVER: (gate) => {
          observedGate = gate;
        },
      };
      let timeout;
      const timeoutPromise = new Promise((_, reject) => {
        timeout = setTimeout(
          () => reject(new Error(`${failure} failure left workers pending`)),
          2_000,
        );
      });
      try {
        const response = await Promise.race([
          handleRequest(
            internalRequest(internalPayload(16)),
            env,
            async (value) => {
              const url = new URL(value instanceof Request ? value.url : value);
              if (url.hostname === "127.0.0.1") {
                artifactCalls += 1;
                if (failure === "artifact" && artifactCalls === 1) {
                  throw new Error("test-only artifact failure");
                }
                return new Response(pngHeader(1_200, 1_908, artifactCalls), {
                  headers: {
                    "content-type": "image/png",
                    "content-length": "30",
                  },
                });
              }

              qwenCalls += 1;
              if (failure === "qwen" && qwenCalls === 1) {
                return new Response("test-only model failure", { status: 500 });
              }
              return qwenResponse({ reasoning: "none", Date: null });
            },
          ),
          timeoutPromise,
        ]);

        assert.equal(response.status, 502);
        assert.equal(artifactCalls, 16);
        assert.equal(qwenCalls, failure === "artifact" ? 15 : 16);
        assert.ok(observedGate);
        assert.deepEqual(observedGate.snapshot(), {
          activeCount: 0,
          usedEstimatedBytes: 0,
          queuedCount: 0,
        });
      } finally {
        clearTimeout(timeout);
      }
    });
  }
});

test("repeated done status reads are pure proxy operations and never call Qwen", async () => {
  const donePayload = {
    task_id: TASK_ID,
    status: "done",
    results: [{
      id: 0,
      polaroid_result_id: 0,
      ink_result_id: 1,
      date: "2026.07.26",
      bbox: [1, 2, 3, 4],
      pattern: "pattern1",
    }],
  };
  let backendCalls = 0;
  let qwenCalls = 0;
  const env = {
    ...LOCAL_ENV,
    CHEKI_DATE_RATE_LIMITER: {
      limit: async () => {
        throw new Error("status must not consume date rate limit");
      },
    },
  };
  const fetchImpl = async (value) => {
    const url = new URL(value instanceof Request ? value.url : value);
    if (url.hostname === "127.0.0.1") {
      backendCalls += 1;
      return Response.json(donePayload);
    }
    qwenCalls += 1;
    throw new Error("status must not call Qwen");
  };

  for (let attempt = 0; attempt < 2; attempt += 1) {
    const response = await handleRequest(new Request(
      `https://api.chekinana.top/api/status/${TASK_ID}`,
      { headers: { "x-cheki-token": LOCAL_TOKEN } },
    ), env, fetchImpl);
    assert.deepEqual(await response.json(), donePayload);
  }
  assert.equal(backendCalls, 2);
  assert.equal(qwenCalls, 0);
});

test("maps any artifact or Qwen failure to one fixed sanitized error", async () => {
  const env = {
    ...LOCAL_ENV,
    CHEKI_DATE_RATE_LIMITER: {
      limit: async () => ({ success: true }),
    },
  };
  let qwenCalls = 0;
  const response = await handleRequest(
    internalRequest(internalPayload(1)),
    env,
    async (value) => {
      const url = new URL(value instanceof Request ? value.url : value);
      if (url.hostname === "127.0.0.1") {
        return new Response(pngHeader(1_200, 1_908), {
          headers: { "content-type": "image/png" },
        });
      }
      qwenCalls += 1;
      return new Response("private model failure", { status: 500 });
    },
  );

  assert.equal(qwenCalls, 1);
  assert.equal(response.status, 502);
  const payload = await response.json();
  assert.deepEqual(payload, {
    status: "failed",
    error: "date_annotation_unavailable",
  });
  assert.doesNotMatch(JSON.stringify(payload), /private|qwen|127\.0\.0\.1/u);
});

test("requires local header authentication and strips token and forwarding headers", async () => {
  let fetched = false;
  const response = await handleRequest(new Request(
    `https://api.chekinana.top${INTERNAL_PATH}?token=${LOCAL_TOKEN}`,
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(internalPayload(1)),
    },
  ), {
    ...LOCAL_ENV,
    CHEKI_DATE_RATE_LIMITER: {
      limit: async () => ({ success: true }),
    },
  }, async () => {
    fetched = true;
    return new Response("unexpected");
  });

  assert.equal(fetched, false);
  assert.equal(response.status, 401);
});

test("preserves production header and query token semantics only for the selected Pod", async (t) => {
  for (const mode of ["header", "query"]) {
    await t.test(mode, async () => {
      let artifactToken = null;
      let artifactQueryToken = null;
      const requestUrl = mode === "query"
        ? `https://api.chekinana.top${INTERNAL_PATH}?token=${PRODUCTION_TOKEN}`
        : `https://api.chekinana.top${INTERNAL_PATH}`;
      const headers = {
        "content-type": "application/json",
        ...(mode === "header"
          ? { "x-cheki-token": PRODUCTION_TOKEN }
          : {}),
      };
      const response = await handleRequest(new Request(requestUrl, {
        method: "POST",
        headers,
        body: JSON.stringify(internalPayload(1)),
      }), {
        CHEKI_DATE_QWEN_API_KEY: "test-only-qwen-key",
        CHEKI_DATE_QWEN_BASE_URL: "https://qwen.test/compatible/v1",
        CHEKI_DATE_RATE_LIMITER: {
          limit: async () => ({ success: true }),
        },
      }, async (value) => {
        const url = new URL(value instanceof Request ? value.url : value);
        if (url.hostname.endsWith(".proxy.runpod.net")) {
          assert.equal(
            url.hostname,
            `${PRODUCTION_TOKEN}-8080.proxy.runpod.net`,
          );
          artifactToken = value.headers.get("x-cheki-token");
          artifactQueryToken = url.searchParams.get("token");
          return new Response(pngHeader(1_200, 1_908), {
            headers: { "content-type": "image/png" },
          });
        }
        return qwenResponse({ reasoning: "none", Date: null });
      });

      assert.equal(response.status, 200);
      assert.equal(
        artifactToken,
        mode === "header" ? PRODUCTION_TOKEN : null,
      );
      assert.equal(
        artifactQueryToken,
        mode === "query" ? PRODUCTION_TOKEN : null,
      );
    });
  }
});

test("rejects oversized result batches before rate limiting or fetching", async () => {
  let limiterCalls = 0;
  let fetchCalls = 0;
  const response = await handleRequest(
    internalRequest(internalPayload(65)),
    {
      ...LOCAL_ENV,
      CHEKI_DATE_RATE_LIMITER: {
        limit: async () => {
          limiterCalls += 1;
          return { success: true };
        },
      },
    },
    async () => {
      fetchCalls += 1;
      return new Response("unexpected");
    },
  );
  assert.equal(response.status, 400);
  assert.equal(limiterCalls, 0);
  assert.equal(fetchCalls, 0);
  assert.deepEqual(await response.json(), {
    ok: false,
    error: "scanner_date_request_invalid",
  });
});

test("rejects unknown JSON fields and declared oversized bodies before rate limiting", async (t) => {
  for (const { label, request } of [
    {
      label: "unknown field",
      request: internalRequest({
        ...internalPayload(1),
        image_url: "https://untrusted.test/image.png",
      }),
    },
    {
      label: "declared oversized body",
      request: new Request(
        `https://api.chekinana.top${INTERNAL_PATH}`,
        {
          method: "POST",
          headers: {
            "content-type": "application/json",
            "content-length": String((16 * 1024) + 1),
            "x-cheki-token": LOCAL_TOKEN,
          },
          body: "{}",
        },
      ),
    },
  ]) {
    await t.test(label, async () => {
      let limiterCalls = 0;
      let fetchCalls = 0;
      const response = await handleRequest(request, {
        ...LOCAL_ENV,
        CHEKI_DATE_RATE_LIMITER: {
          limit: async () => {
            limiterCalls += 1;
            return { success: true };
          },
        },
      }, async () => {
        fetchCalls += 1;
        return new Response("unexpected");
      });
      assert.equal(response.status, 400);
      assert.equal(limiterCalls, 0);
      assert.equal(fetchCalls, 0);
      assert.deepEqual(await response.json(), {
        ok: false,
        error: "scanner_date_request_invalid",
      });
    });
  }
});
