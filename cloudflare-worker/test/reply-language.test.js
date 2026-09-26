import test from "node:test";
import assert from "node:assert/strict";

import {
  classifyReplyLanguage,
  resetReplyLanguageRateLimitForTests,
} from "../src/reply-language.js";
import { handleRequest } from "../src/worker.js";

const TEST_ENV = {
  NL_LLM_API_KEY: "test-only-key",
  NL_RATE_LIMITER: { limit: async () => ({ success: true }) },
};

const DEFAULT_INPUT = {
  version: 1,
  utterance: "列出所有偶像",
  phase: "initial",
};

function languageRequest(body = DEFAULT_INPUT, headers = {}) {
  return new Request("https://api.chekinana.top/api/nl/reply-language", {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify(body),
  });
}

function modelFetch(content, { status = 200, inspect } = {}) {
  return async (url, init) => {
    inspect?.(url, init);
    return new Response(JSON.stringify({
      choices: [{ message: { content: typeof content === "string" ? content : JSON.stringify(content) } }],
    }), { status, headers: { "content-type": "application/json" } });
  };
}

async function classify(content, input = DEFAULT_INPUT, options = {}) {
  resetReplyLanguageRateLimitForTests();
  return classifyReplyLanguage(languageRequest(input), TEST_ENV, {
    fetchImpl: modelFetch(content),
    ...options,
  });
}

function output(language, switchRequested = false, directiveOnly = false, businessUtterance) {
  return {
    version: 1,
    language,
    switch_requested: switchRequested,
    directive_only: directiveOnly,
    ...(businessUtterance === undefined ? {} : { business_utterance: businessUtterance }),
  };
}

async function assertReject(result, status, code) {
  assert.equal(result.status, status);
  assert.deepEqual(result.body, { version: 1, kind: "reject", code });
}

for (const [utterance, language] of [
  ["列出所有偶像", "zh-Hans"],
  ["列出所有偶像與活動", "zh-Hant"],
  ["アイドルを一覧にして", "ja"],
  ["List all idols", "en"],
]) {
  test(`accepts DeepSeek initial-language classification: ${language}`, async () => {
    const result = await classify(output(language), { ...DEFAULT_INPUT, utterance });
    assert.equal(result.status, 200);
    assert.deepEqual(result.body, output(language));
  });
}

for (const utterance of [
  "https://example.com/events/1",
  "Aina",
  "12345",
  "🎤✨",
  "偶像 idol アイドル",
]) {
  test(`accepts an undetermined non-language initial message: ${utterance}`, async () => {
    const result = await classify(output("undetermined"), { ...DEFAULT_INPUT, utterance });
    assert.equal(result.status, 200);
    assert.deepEqual(result.body, output("undetermined"));
  });
}

test("accepts an explicit initial target language independently of the instruction language", async () => {
  const input = { ...DEFAULT_INPUT, utterance: "日本語で答えて" };
  const result = await classify(output("ja", true, true), input);
  assert.equal(result.status, 200);
  assert.deepEqual(result.body, output("ja", true, true));
});

for (const [currentLanguage, utterance] of [
  ["zh-Hans", "List all idols"],
  ["zh-Hant", "アイドルを一覧にして"],
  ["ja", "列出所有偶像"],
  ["en", "列出所有偶像"],
]) {
  test(`continuation keeps ${currentLanguage} when only the input language changes`, async () => {
    const input = {
      version: 1,
      utterance,
      phase: "continuation",
      current_language: currentLanguage,
    };
    const result = await classify(output(currentLanguage), input);
    assert.equal(result.status, 200);
    assert.deepEqual(result.body, output(currentLanguage));
  });
}

test("accepts an explicit cross-language continuation switch", async () => {
  const input = {
    version: 1,
    utterance: "Please switch to Traditional Chinese",
    phase: "continuation",
    current_language: "en",
  };
  const result = await classify(output("zh-Hant", true, true), input);
  assert.equal(result.status, 200);
  assert.deepEqual(result.body, output("zh-Hant", true, true));
});

test("accepts an explicit request for the already-current reply language", async () => {
  const input = {
    version: 1,
    utterance: "Please continue in English",
    phase: "continuation",
    current_language: "en",
  };
  const result = await classify(output("en", true, true), input);
  assert.equal(result.status, 200);
  assert.deepEqual(result.body, output("en", true, true));
});

test("accepts a same-language request combined with verbatim business text", async () => {
  const input = {
    version: 1,
    utterance: "继续用中文回答，然后列出所有活动",
    phase: "continuation",
    current_language: "zh-Hans",
  };
  const expected = output("zh-Hans", true, false, "列出所有活动");
  const result = await classify(expected, input);
  assert.equal(result.status, 200);
  assert.deepEqual(result.body, expected);
});

for (const utterance of [
  "日语和英语有什么区别？",
  "How do I translate 日本語 into English?",
  "“请用繁体中文”这句话是什么意思？",
]) {
  test(`language mention or translation discussion is not a switch: ${utterance}`, async () => {
    const input = {
      version: 1,
      utterance,
      phase: "continuation",
      current_language: "zh-Hans",
    };
    const result = await classify(output("zh-Hans"), input);
    assert.equal(result.status, 200);
    assert.deepEqual(result.body, output("zh-Hans"));
  });
}

test("accepts a pure language switch without a business utterance", async () => {
  const input = {
    version: 1,
    utterance: "以后请用英语回答",
    phase: "continuation",
    current_language: "zh-Hans",
  };
  const result = await classify(output("en", true, true), input);
  assert.equal(result.status, 200);
  assert.deepEqual(result.body, output("en", true, true));
});

test("accepts a combined switch only with verbatim contiguous business evidence", async () => {
  const input = {
    version: 1,
    utterance: "请改用日语，然后列出所有偶像",
    phase: "continuation",
    current_language: "zh-Hans",
  };
  const expected = output("ja", true, false, "列出所有偶像");
  const result = await classify(expected, input);
  assert.equal(result.status, 200);
  assert.deepEqual(result.body, expected);
});

for (const [label, candidate, input] of [
  ["unknown language", output("ko"), DEFAULT_INPUT],
  ["extra output field", { ...output("zh-Hans"), reason: "Chinese text" }, DEFAULT_INPUT],
  ["switch to undetermined", output("undetermined", true, true), DEFAULT_INPUT],
  ["directive without switch", output("zh-Hans", false, true), DEFAULT_INPUT],
  ["business without switch", output("zh-Hans", false, false, "列出所有偶像"), DEFAULT_INPUT],
  ["continuation language drift", output("ja"), {
    version: 1,
    utterance: "アイドルを一覧にして",
    phase: "continuation",
    current_language: "en",
  }],
  ["generated business text", output("ja", true, false, "すべてのアイドルを表示"), {
    version: 1,
    utterance: "请改用日语，然后列出所有偶像",
    phase: "continuation",
    current_language: "zh-Hans",
  }],
  ["rewritten business punctuation", output("en", true, false, "list all idols."), {
    version: 1,
    utterance: "Use English and list all idols",
    phase: "continuation",
    current_language: "ja",
  }],
  ["whole utterance as business", output("en", true, false, "Use English and list all idols"), {
    version: 1,
    utterance: "Use English and list all idols",
    phase: "continuation",
    current_language: "ja",
  }],
  ["business on directive-only output", output("ja", true, true, "请改用日语"), {
    version: 1,
    utterance: "请改用日语",
    phase: "continuation",
    current_language: "zh-Hans",
  }],
]) {
  test(`rejects invalid or ungrounded model output: ${label}`, async () => {
    await assertReject(await classify(candidate, input), 422, "invalid_model_output");
  });
}

test("uses deepseek-flash with strict JSON mode and forwards only validated text fields", async () => {
  const clientAuthorization = "Bearer client-private-value";
  const clientCookie = "session=client-private-value";
  const clientScannerToken = "client-scanner-private-value";
  const input = {
    version: 1,
    utterance: "アイドルを一覧にして",
    phase: "continuation",
    current_language: "ja",
  };
  let modelCalls = 0;
  const result = await classifyReplyLanguage(languageRequest(input, {
    authorization: clientAuthorization,
    cookie: clientCookie,
    "x-cheki-token": clientScannerToken,
  }), TEST_ENV, {
    fetchImpl: modelFetch(output("ja"), {
      inspect: (url, init) => {
        modelCalls += 1;
        assert.equal(url, "https://api.deepseek.com/chat/completions");
        assert.equal(init.method, "POST");
        assert.deepEqual(Object.keys(init.headers).sort(), ["authorization", "content-type"]);
        assert.equal(init.headers.authorization, "Bearer test-only-key");
        const body = JSON.parse(init.body);
        assert.equal(body.model, "deepseek-flash");
        assert.equal(body.temperature, 0);
        assert.equal(body.max_tokens, 512);
        assert.equal(body.stream, false);
        assert.deepEqual(body.response_format, { type: "json_object" });
        assert.deepEqual(body.thinking, { type: "disabled" });
        assert.deepEqual(JSON.parse(body.messages[1].content), input);
        assert.match(body.messages[0].content, /never change language merely because/u);
        assert.match(body.messages[0].content, /contiguous substring/u);
        assert.doesNotMatch(init.body, /client-private-value|client-scanner-private-value/u);
      },
    }),
  });
  assert.equal(modelCalls, 1);
  assert.equal(result.status, 200);
  assert.deepEqual(result.body, output("ja"));
});

test("uses a separate prefixed key with the existing NL rate limiter", async () => {
  let receivedKey;
  const result = await classifyReplyLanguage(languageRequest(DEFAULT_INPUT, {
    "cf-connecting-ip": "203.0.113.7",
  }), {
    ...TEST_ENV,
    NL_RATE_LIMITER: {
      limit: async ({ key }) => {
        receivedKey = key;
        return { success: true };
      },
    },
  }, { fetchImpl: modelFetch(output("zh-Hans")) });
  assert.equal(result.status, 200);
  assert.equal(receivedKey, "reply-language:203.0.113.7");
});

test("fails closed when the rate limiter is missing", async () => {
  let fetched = false;
  const result = await classifyReplyLanguage(languageRequest(), {
    NL_LLM_API_KEY: "test-only-key",
  }, {
    fetchImpl: async () => {
      fetched = true;
      return new Response("unexpected");
    },
  });
  await assertReject(result, 503, "rate_limit_unavailable");
  assert.equal(fetched, false);
});

test("rejects a denied rate-limit decision before calling the model", async () => {
  let fetched = false;
  const result = await classifyReplyLanguage(languageRequest(), {
    ...TEST_ENV,
    NL_RATE_LIMITER: { limit: async () => ({ success: false }) },
  }, {
    fetchImpl: async () => {
      fetched = true;
      return new Response("unexpected");
    },
  });
  await assertReject(result, 429, "rate_limited");
  assert.equal(fetched, false);
});

test("fails without a model key after request validation", async () => {
  const result = await classifyReplyLanguage(languageRequest(), {
    NL_RATE_LIMITER: { limit: async () => ({ success: true }) },
  });
  await assertReject(result, 503, "service_unavailable");
});

test("returns a typed timeout and never retries the language model", async () => {
  let modelCalls = 0;
  const result = await classifyReplyLanguage(languageRequest(), TEST_ENV, {
    timeoutMs: 10,
    fetchImpl: async () => {
      modelCalls += 1;
      return new Promise(() => {});
    },
  });
  await assertReject(result, 503, "upstream_timeout");
  assert.equal(modelCalls, 1);
});

test("rejects malformed model JSON without exposing it or retrying", async () => {
  let modelCalls = 0;
  const result = await classifyReplyLanguage(languageRequest(), TEST_ENV, {
    fetchImpl: modelFetch("```json\nnot-valid\n```", {
      inspect: () => { modelCalls += 1; },
    }),
  });
  await assertReject(result, 422, "invalid_model_output");
  assert.equal(modelCalls, 1);
  assert.doesNotMatch(JSON.stringify(result.body), /not-valid/u);
});

test("rejects a declared oversized request before rate limiting", async () => {
  let limited = false;
  let fetched = false;
  const request = languageRequest(DEFAULT_INPUT, { "content-length": "16385" });
  const result = await classifyReplyLanguage(request, {
    ...TEST_ENV,
    NL_RATE_LIMITER: {
      limit: async () => {
        limited = true;
        return { success: true };
      },
    },
  }, {
    fetchImpl: async () => {
      fetched = true;
      return new Response("unexpected");
    },
  });
  await assertReject(result, 400, "invalid_request");
  assert.equal(limited, false);
  assert.equal(fetched, false);
});

test("rejects input schema, image payloads, control characters, and excessive text before the model", async (t) => {
  const invalidBodies = [
    ["extra field", { ...DEFAULT_INPUT, image: "selected-photo" }],
    ["image data URL", { ...DEFAULT_INPUT, utterance: "说明foo,data:image/jpeg;base64,AAAA" }],
    ["initial current language", { ...DEFAULT_INPUT, current_language: "zh-Hans" }],
    ["continuation missing current language", { ...DEFAULT_INPUT, phase: "continuation" }],
    ["invalid current language", { ...DEFAULT_INPUT, phase: "continuation", current_language: "ko" }],
    ["control character", { ...DEFAULT_INPUT, utterance: "列出\u0000偶像" }],
    ["overlong utterance", { ...DEFAULT_INPUT, utterance: "偶".repeat(1_001) }],
  ];
  for (const [label, body] of invalidBodies) {
    await t.test(label, async () => {
      let modelCalls = 0;
      const result = await classifyReplyLanguage(languageRequest(body), TEST_ENV, {
        fetchImpl: async () => {
          modelCalls += 1;
          return new Response("unexpected");
        },
      });
      await assertReject(result, 400, "invalid_request");
      assert.equal(modelCalls, 0);
    });
  }
});

test("mirrors the established privacy guard for real credential forms before the model", async () => {
  for (const utterance of [
    "请处理 deadbeef",
    "Authorization: secret-value",
    "Cookie: session=value",
    "Bearer secret-value",
    "X-Cheki-Token: secret-value",
    "access_token=secret-value",
    "pod id: example",
    "pod abc123xyz",
    "Pod ID 为 abc123xyz，用来扫描这些照片",
    "scancheki pod=abcdefghi",
    "https://abc123xyz-8000.proxy.runpod.net/api",
    "添加 Event https://user:password@example.com/live",
  ]) {
    let modelCalls = 0;
    const result = await classifyReplyLanguage(languageRequest({
      ...DEFAULT_INPUT,
      utterance,
    }), TEST_ENV, {
      fetchImpl: async () => {
        modelCalls += 1;
        return new Response("unexpected");
      },
    });
    await assertReject(result, 400, "invalid_request");
    assert.equal(modelCalls, 0, utterance);
  }
});

test("does not reject ordinary discussion of security or infrastructure terms", async () => {
  for (const utterance of [
    "请解释 token 的用途",
    "讨论 password 与 API key 的区别",
    "讨论 Pod 架构",
    "RunPod 的产品介绍",
  ]) {
    const result = await classify(output("zh-Hans"), { ...DEFAULT_INPUT, utterance });
    assert.equal(result.status, 200, utterance);
  }
});

test("rejects non-JSON image and binary requests before rate limiting or model access", async () => {
  let limited = false;
  let fetched = false;
  const request = new Request("https://api.chekinana.top/api/nl/reply-language", {
    method: "POST",
    headers: { "content-type": "image/jpeg" },
    body: new Uint8Array([0xff, 0xd8, 0xff]),
  });
  const response = await handleRequest(request, {
    ...TEST_ENV,
    NL_RATE_LIMITER: {
      limit: async () => {
        limited = true;
        return { success: true };
      },
    },
  }, async () => {
    fetched = true;
    return new Response("unexpected");
  });
  assert.equal(response.status, 400);
  assert.deepEqual(await response.json(), { version: 1, kind: "reject", code: "invalid_request" });
  assert.equal(limited, false);
  assert.equal(fetched, false);
});

test("reply-language route and preflight stay local and disable caching", async () => {
  const response = await handleRequest(languageRequest(), TEST_ENV, modelFetch(output("zh-Hans")));
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.equal(response.headers.get("access-control-allow-origin"), "*");
  assert.deepEqual(await response.json(), output("zh-Hans"));

  const preflight = await handleRequest(new Request(
    "https://api.chekinana.top/api/nl/reply-language",
    { method: "OPTIONS" },
  ));
  assert.equal(preflight.status, 200);
  assert.equal(preflight.headers.get("cache-control"), "no-store");
  assert.match(preflight.headers.get("access-control-allow-methods"), /POST/u);
});

test("reply-language route rejects unsupported methods without scanner fallback", async () => {
  const response = await handleRequest(new Request(
    "https://api.chekinana.top/api/nl/reply-language",
    { method: "GET" },
  ));
  assert.equal(response.status, 405);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.deepEqual(await response.json(), {
    version: 1,
    kind: "reject",
    code: "method_not_allowed",
  });
});
