import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { webcrypto } from "node:crypto";
import vm from "node:vm";

const source = readFileSync(new URL("./shortcut.js", import.meta.url), "utf8");
const buildSource = readFileSync(new URL("./build-shortcut.mjs", import.meta.url), "utf8");
const previewSource = readFileSync(new URL("./panel-preview.html", import.meta.url), "utf8");
const localInstallSource = readFileSync(new URL("./index.html", import.meta.url), "utf8");
const deployedInstallSource = readFileSync(
  new URL("../cloudflare-pages/tools/weibo-lottery/index.html", import.meta.url),
  "utf8",
);
const localShortcutUrl = new URL("./微博抽奖工具v4.shortcut", import.meta.url);
const legacyLocalShortcutUrl = new URL("./微博抽奖工具v3.1.shortcut", import.meta.url);
assert.equal(existsSync(localShortcutUrl), true);
assert.equal(existsSync(legacyLocalShortcutUrl), false);
const localShortcutAsset = readFileSync(localShortcutUrl);
const workerShortcutAsset = readFileSync(
  new URL("../cloudflare-worker/weibo-lottery-gate/assets/weibo-lottery-v3.shortcut", import.meta.url),
);
const blockedTermsKey = "weibo-repost-lottery-blocked-terms";

const visibleHtmlText = (value) => String(value)
  .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, "")
  .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, "")
  .replace(/<[^>]*>/g, "")
  .replaceAll("&amp;", "&")
  .replaceAll("&lt;", "<")
  .replaceAll("&gt;", ">");

class TestDOMParser {
  parseFromString(value) {
    return { body: { textContent: visibleHtmlText(value) } };
  }
}

const mobileProfile = (mblogs) => ({
  body: {
    ok: 1,
    data: {
      cards: [
        { card_type: 11 },
        ...mblogs.map((mblog) => ({ card_type: 9, mblog })),
      ],
    },
  },
});

const mobileRelation = (relation) => ({
  body: {
    ok: 1,
    data: { userInfo: { friendships_relation: relation } },
  },
});
const longText = (text) => ({ body: { ok: 1, data: { longTextContent: text } } });

const mobileReposts = (users) => ({
  body: {
    ok: 1,
    data: {
      data: users.map(({ uid, name }, index) => ({
        idstr: String(index + 1),
        user: { idstr: uid, screen_name: name },
      })),
      max: 1,
      total_number: users.length,
    },
  },
});

const original = (text) => ({ text_raw: text });
const retweet = (outerText, innerText) => ({
  text_raw: outerText,
  retweeted_status: { text_raw: innerText },
});
const rateLimitLabels = [
  "转发列表接口（repostTimeline）",
  "用户关系接口（100505）",
  "用户微博列表接口（107603）",
  "长微博正文接口（statuses/extend）",
];
const assertRateLimitSource = (scenario, expectedLabel) => {
  const message = scenario.elements.get("#wrl-error").textContent;
  assert.equal(message, `${expectedLabel}触发限流，请稍后再试，已停止本次抽奖。`);
  for (const label of rateLimitLabels) {
    if (label !== expectedLabel) assert.equal(message.includes(label), false);
  }
  assert.equal(message.includes("微博接口触发限流"), false);
};
const allCalls = [];

const createElement = (initialValue = "") => {
  const classes = new Set();
  const listeners = new Map();
  const attributes = new Map();
  const children = [];
  let textContent = "";
  const element = {
    value: initialValue,
    textHistory: [],
    disabled: false,
    style: {},
    classList: {
      add: (...values) => values.forEach((value) => classes.add(value)),
      remove: (...values) => values.forEach((value) => classes.delete(value)),
      contains: (value) => classes.has(value),
      toggle: (value, force) => {
        const enabled = force === undefined ? !classes.has(value) : Boolean(force);
        if (enabled) classes.add(value);
        else classes.delete(value);
        return enabled;
      },
    },
    focusCalls: [],
    blurCalls: 0,
    addEventListener: (name, listener) => listeners.set(name, listener),
    appendChild: (child) => children.push(child),
    replaceChildren: (...values) => children.splice(0, children.length, ...values),
    attachShadow: () => {},
    focus: (...args) => element.focusCalls.push(args),
    blur: () => { element.blurCalls += 1; },
    setAttribute: (name, value) => attributes.set(name, String(value)),
    getAttribute: (name) => attributes.get(name) ?? null,
    remove: () => {},
    select: () => {},
    children,
    listeners,
  };
  Object.defineProperty(element, "textContent", {
    get: () => textContent,
    set: (value) => {
      textContent = String(value);
      element.textHistory.push(textContent);
    },
  });
  return element;
};

const runScenario = async ({
  href,
  responses = [],
  fetchHandler,
  relationFetchHandler,
  onFetch,
  randomValues,
  storage = new Map(),
  drawCount = "2",
  clickStart = true,
}) => {
  const elements = new Map();
  const getElement = (selector) => {
    if (!elements.has(selector)) {
      elements.set(selector, createElement(selector === "#wrl-count" ? drawCount : ""));
    }
    return elements.get(selector);
  };

  const shadowRoot = {
    innerHTML: "",
    querySelector: getElement,
  };
  const hostElement = createElement();
  hostElement.attachShadow = () => shadowRoot;
  const body = { appendChild: () => {} };
  const documentElement = { appendChild: () => {} };
  const document = {
    body,
    documentElement,
    execCommand: () => true,
    getElementById: () => null,
    createElement: (tagName) => tagName === "div" ? hostElement : createElement(),
  };

  const calls = [];
  const fetchCalls = [];
  const clipboardWrites = [];
  const completionValues = [];
  let activeFetches = 0;
  let maxActiveFetches = 0;
  const randomQueue = randomValues ? [...randomValues] : null;
  const scenarioCrypto = randomQueue
    ? {
        getRandomValues: (bucket) => {
          bucket[0] = randomQueue.length ? randomQueue.shift() : 0;
          return bucket;
        },
      }
    : webcrypto;
  const context = {
    URL,
    URLSearchParams,
    DOMParser: TestDOMParser,
    Uint32Array,
    completion: (value) => completionValues.push(value),
    crypto: scenarioCrypto,
    document,
    fetch: async (url) => {
      const requestUrl = String(url);
      calls.push(requestUrl);
      allCalls.push(requestUrl);
      fetchCalls.push(requestUrl);
      onFetch?.(requestUrl, { calls, elements });
      const relationRequest = /^\/api\/container\/getIndex\?containerid=100505\d+$/.test(requestUrl);
      const response = relationRequest
        ? relationFetchHandler?.(requestUrl, calls.length) ?? mobileRelation(0)
        : fetchHandler ? fetchHandler(requestUrl, calls.length) : responses.shift();
      assert.ok(response, `unexpected fetch: ${url}`);
      activeFetches += 1;
      maxActiveFetches = Math.max(maxActiveFetches, activeFetches);
      try {
        await Promise.resolve();
        return {
          ok: response.httpOk !== false,
          status: response.status || 200,
          redirected: response.redirected || false,
          url: response.url || String(url),
          headers: { get: () => response.contentType || "application/json" },
          json: async () => response.body,
        };
      } finally {
        activeFetches -= 1;
      }
    },
    location: new URL(href),
    localStorage: {
      getItem: (key) => storage.has(key) ? storage.get(key) : null,
      setItem: (key, value) => storage.set(key, String(value)),
    },
    navigator: { clipboard: { writeText: async (value) => clipboardWrites.push(String(value)) } },
    setTimeout: (callback) => {
      callback();
      return 1;
    },
  };

  await vm.runInNewContext(source, context, { filename: "shortcut.js" });
  const callsBeforeStart = calls.slice();
  const start = getElement("#wrl-start").listeners.get("click");
  assert.equal(typeof start, "function");
  if (clickStart) await start();
  return {
    calls,
    callsBeforeStart,
    clipboardWrites,
    completionValues,
    elements,
    fetchCalls,
    maxActiveFetches,
    storage,
  };
};

const mobile = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  responses: [
    {
      body: {
        ok: 1,
        data: {
          data: [
            { idstr: "1", user: { idstr: "101", screen_name: "用户甲" } },
            { idstr: "2", user: { idstr: "102", screen_name: "用户乙" } },
          ],
          max: 2,
          total_number: 3,
        },
      },
    },
    {
      body: {
        ok: 1,
        data: {
          data: [{ idstr: "3", user: { idstr: "103", screen_name: "用户丙" } }],
          max: 2,
          total_number: 3,
        },
      },
    },
    mobileProfile([original("日常原创")]),
    mobileProfile([original("另一条原创")]),
  ],
});

assert.equal(mobile.completionValues[0].ok, true);
assert.equal(mobile.completionValues[0].message, "微博抽奖工具v4已打开");
assert.equal(mobile.callsBeforeStart.length, 1);
assert.match(mobile.calls[0], /^\/api\/statuses\/repostTimeline\?/);
assert.match(mobile.calls[1], /page=2/);
assert.match(mobile.calls[2], /^\/api\/container\/getIndex\?containerid=100505\d+$/);
assert.match(mobile.calls[3], /^\/api\/container\/getIndex\?containerid=107603\d+&page=1&count=10$/);
assert.match(mobile.elements.get("#wrl-summary").textContent, /从 3 个去重用户名中抽取 2 个/);
assert.equal((mobile.elements.get("#wrl-output").textContent.match(/@/g) || []).length, 2);
assert.equal(mobile.elements.get("#wrl-lottery-account-title").textContent, "抽奖号排除（0）");
assert.equal(mobile.elements.get("#wrl-lottery-account-users").textContent, "无");
assert.equal(mobile.elements.get("#wrl-blocked-term-title").textContent, "屏蔽词排除（0）");
assert.equal(mobile.elements.get("#wrl-blocked-term-users").textContent, "无");
assert.equal(mobile.elements.get("#wrl-error").classList.contains("show"), false);

const parallel = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  drawCount: "1",
  responses: [
    ...Array.from({ length: 7 }, (_, index) => ({
      body: {
        ok: 1,
        data: {
          data: [{
            idstr: String(index + 1),
            user: { idstr: String(100 + index), screen_name: `用户${index + 1}` },
          }],
          max: 7,
          total_number: 7,
        },
      },
    })),
    mobileProfile([original("日常原创")]),
  ],
});

assert.equal(parallel.callsBeforeStart.length, 1);
assert.equal(parallel.calls.length, 9);
assert.equal(parallel.maxActiveFetches, 6);
assert.ok(parallel.elements.get("#wrl-pages").textHistory.includes("7 / 7 页"));
assert.match(parallel.elements.get("#wrl-summary").textContent, /从 7 个去重用户名中抽取 1 个/);
assert.equal(parallel.elements.get("#wrl-error").classList.contains("show"), false);

for (const repostRateResponse of [
  { httpOk: false, status: 432 },
  { body: { ok: 0, message: "请求过多，请稍后再试" } },
]) {
  const repostRateLimited = await runScenario({
    href: "https://m.weibo.cn/detail/5336202665263592",
    responses: [repostRateResponse],
    clickStart: false,
  });
  assert.equal(repostRateLimited.calls.length, 1);
  assertRateLimitSource(repostRateLimited, "转发列表接口（repostTimeline）");
}

const relationCalls = [];
const relationFiltering = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  drawCount: "1",
  randomValues: [1],
  fetchHandler: (url) => {
    if (url.startsWith("/api/statuses/repostTimeline?")) {
      return mobileReposts([
        { uid: "201", name: "已拉黑用户" },
        { uid: "202", name: "仅屏蔽但未拉黑" },
      ]);
    }
    relationCalls.push(url);
    return mobileProfile([original("正常原创")]);
  },
  relationFetchHandler: (url) => {
    relationCalls.push(url);
    return url.includes("100505201") ? mobileRelation(4) : mobileRelation(3);
  },
});

assert.equal(relationFiltering.elements.get("#wrl-output").textContent, "@仅屏蔽但未拉黑");
assert.equal(relationFiltering.elements.get("#wrl-lottery-account-users").textContent, "无");
assert.equal(relationFiltering.elements.get("#wrl-blocked-term-users").textContent, "无");
assert.deepEqual(relationCalls, [
  "/api/container/getIndex?containerid=100505201",
  "/api/container/getIndex?containerid=100505202",
  "/api/container/getIndex?containerid=107603202&page=1&count=10",
]);
assert.equal(relationCalls.some((url) => url.includes("107603201")), false);
const relationRedraw = relationFiltering.elements.get("#wrl-redraw").listeners.get("click");
await relationRedraw();
assert.deepEqual(relationCalls, [
  "/api/container/getIndex?containerid=100505201",
  "/api/container/getIndex?containerid=100505202",
  "/api/container/getIndex?containerid=107603202&page=1&count=10",
]);

const relationBeforeUsernameStorage = new Map([[blockedTermsKey, JSON.stringify(["ban"])]]);
const relationBeforeUsernameProfiles = [];
const relationBeforeUsername = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  drawCount: "1",
  randomValues: [2, 1],
  storage: relationBeforeUsernameStorage,
  fetchHandler: (url) => {
    if (url.startsWith("/api/statuses/repostTimeline?")) {
      return mobileReposts([
        { uid: "231", name: "BAN且已拉黑" },
        { uid: "232", name: "BAN但未拉黑" },
        { uid: "233", name: "关系优先后合格" },
      ]);
    }
    const uid = new URL(url, "https://m.weibo.cn").searchParams.get("containerid")?.replace("107603", "");
    relationBeforeUsernameProfiles.push(uid);
    return mobileProfile([original("合格原创")]);
  },
  relationFetchHandler: (url) => url.includes("100505231") ? mobileRelation(4) : mobileRelation(0),
});

assert.equal(relationBeforeUsername.elements.get("#wrl-output").textContent, "@关系优先后合格");
assert.deepEqual(relationBeforeUsernameProfiles, ["233"]);
assert.equal(relationBeforeUsername.elements.get("#wrl-lottery-account-users").textContent, "无");
assert.equal(relationBeforeUsername.elements.get("#wrl-blocked-term-title").textContent, "屏蔽词排除（1）");
assert.equal(relationBeforeUsername.elements.get("#wrl-blocked-term-users").textContent, "@BAN但未拉黑");

let blockedNameRelationFailures = 0;
const failedRelationBeforeUsername = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  drawCount: "1",
  randomValues: [1],
  storage: relationBeforeUsernameStorage,
  fetchHandler: (url) => {
    if (url.startsWith("/api/statuses/repostTimeline?")) {
      return mobileReposts([
        { uid: "234", name: "BAN且关系失败" },
        { uid: "235", name: "关系失败后合格" },
      ]);
    }
    assert.equal(url.includes("107603234"), false);
    return mobileProfile([original("合格原创")]);
  },
  relationFetchHandler: (url) => {
    if (url.includes("100505234")) {
      blockedNameRelationFailures += 1;
      return { httpOk: false, status: 500 };
    }
    return mobileRelation(0);
  },
});

assert.equal(blockedNameRelationFailures, 2);
assert.equal(failedRelationBeforeUsername.elements.get("#wrl-output").textContent, "@关系失败后合格");
assert.equal(failedRelationBeforeUsername.elements.get("#wrl-lottery-account-users").textContent, "无");
assert.equal(failedRelationBeforeUsername.elements.get("#wrl-blocked-term-title").textContent, "屏蔽词排除（0）");
assert.equal(failedRelationBeforeUsername.elements.get("#wrl-blocked-term-users").textContent, "无");

const relationRetries = new Map();
const relationRetry = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  drawCount: "1",
  randomValues: [1, 1],
  fetchHandler: (url) => url.startsWith("/api/statuses/repostTimeline?")
    ? mobileReposts([
        { uid: "211", name: "关系未知" },
        { uid: "212", name: "后续合格" },
      ])
    : mobileProfile([original("正常原创")]),
  relationFetchHandler: (url) => {
    const uid = new URL(url, "https://m.weibo.cn").searchParams.get("containerid")?.replace("100505", "");
    relationRetries.set(uid, (relationRetries.get(uid) || 0) + 1);
    return uid === "211"
      ? { body: { ok: 1, data: { userInfo: {} } } }
      : mobileRelation(0);
  },
});

assert.equal(relationRetry.elements.get("#wrl-output").textContent, "@后续合格");
assert.equal(relationRetries.get("211"), 2);
assert.equal(relationRetries.get("212"), 1);
const relationRetryRedraw = relationRetry.elements.get("#wrl-redraw").listeners.get("click");
await relationRetryRedraw();
assert.equal(relationRetries.get("211"), 2);
assert.equal(relationRetries.get("212"), 1);

let relationLoginCalls = 0;
const relationLoggedOut = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  drawCount: "1",
  responses: [mobileReposts([{ uid: "221", name: "登录失效" }])],
  relationFetchHandler: () => {
    relationLoginCalls += 1;
    return { httpOk: false, status: 401 };
  },
});
assert.equal(relationLoginCalls, 1);
assert.match(relationLoggedOut.elements.get("#wrl-error").textContent, /登录微博/);

let relationRateCalls = 0;
const relationRateLimited = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  drawCount: "1",
  responses: [mobileReposts([{ uid: "222", name: "关系限流" }])],
  relationFetchHandler: () => {
    relationRateCalls += 1;
    return { httpOk: false, status: 429 };
  },
});
assert.equal(relationRateCalls, 1);
assertRateLimitSource(relationRateLimited, "用户关系接口（100505）");

let relationPayloadRateCalls = 0;
const relationPayloadRateLimited = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  drawCount: "1",
  responses: [mobileReposts([{ uid: "229", name: "关系消息限流" }])],
  relationFetchHandler: () => {
    relationPayloadRateCalls += 1;
    return { body: { ok: 0, message: "访问次数过多" } };
  },
});
assert.equal(relationPayloadRateCalls, 1);
assertRateLimitSource(relationPayloadRateLimited, "用户关系接口（100505）");

let relationHtmlCalls = 0;
const relationHtml = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  drawCount: "1",
  randomValues: [1, 1],
  fetchHandler: (url) => url.startsWith("/api/statuses/repostTimeline?")
    ? mobileReposts([
        { uid: "223", name: "关系接口网页响应" },
        { uid: "224", name: "网页响应后备" },
      ])
    : mobileProfile([original("正常原创")]),
  relationFetchHandler: (url) => {
    if (url.includes("100505223")) {
      relationHtmlCalls += 1;
      return { contentType: "text/html", body: "<html>error</html>" };
    }
    return mobileRelation(1);
  },
});
assert.equal(relationHtmlCalls, 2);
assert.equal(relationHtml.elements.get("#wrl-output").textContent, "@网页响应后备");
assert.equal(relationHtml.calls.some((url) => url.includes("107603223")), false);

for (const failureCase of [
  { label: "普通 JSON 失败", response: { body: { ok: 0, msg: "系统繁忙" } } },
  { label: "HTTP 失败", response: { httpOk: false, status: 500 } },
]) {
  let failedRelationCalls = 0;
  const failedUid = failureCase.label === "普通 JSON 失败" ? "225" : "227";
  const fallbackUid = failureCase.label === "普通 JSON 失败" ? "226" : "228";
  const ordinaryFailure = await runScenario({
    href: "https://m.weibo.cn/detail/5336202665263592",
    drawCount: "1",
    randomValues: [1, 1],
    fetchHandler: (url) => url.startsWith("/api/statuses/repostTimeline?")
      ? mobileReposts([
          { uid: failedUid, name: failureCase.label },
          { uid: fallbackUid, name: `${failureCase.label}后备` },
        ])
      : mobileProfile([original("正常原创")]),
    relationFetchHandler: (url) => {
      if (url.includes(`100505${failedUid}`)) {
        failedRelationCalls += 1;
        return failureCase.response;
      }
      return mobileRelation(2);
    },
  });
  assert.equal(failedRelationCalls, 2);
  assert.equal(ordinaryFailure.elements.get("#wrl-output").textContent, `@${failureCase.label}后备`);
  assert.equal(ordinaryFailure.calls.some((url) => url.includes(`107603${failedUid}`)), false);
}

const eligibilityUsers = [
  { uid: "301", name: "原创含抽" },
  { uid: "302", name: "比例等于一半" },
  { uid: "303", name: "比例小于一半" },
  { uid: "304", name: "比例大于一半" },
  { uid: "305", name: "没有原创" },
];
const eligibilityProfiles = new Map([
  ["301", mobileProfile([original("今天抽空写了原创")])],
  ["302", mobileProfile([
    original("日常原创"),
    { text: "抽奖转发", retweeted_status: { text: "活动正文" } },
  ])],
  ["303", mobileProfile([
    original("日常原创"),
    retweet("转发活动", "评论抽一位"),
    {
      text_raw: "普通转发",
      text: "抽奖伪字段",
      retweeted_status: { text_raw: "普通内容" },
    },
  ])],
  ["304", mobileProfile([
    original("日常原创"),
    retweet("抽奖一", "活动一"),
    retweet("活动二", "抽奖二"),
  ])],
  ["305", mobileProfile([retweet("普通转发", "普通内容")])],
]);
const eligibilityProfileOrder = [];
const eligibility = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  drawCount: "3",
  randomValues: [0, 0, 0, 0],
  fetchHandler: (url) => {
    if (url.startsWith("/api/statuses/repostTimeline?")) return mobileReposts(eligibilityUsers);
    const uid = new URL(url, "https://m.weibo.cn").searchParams.get("containerid")?.replace("107603", "");
    eligibilityProfileOrder.push(uid);
    return eligibilityProfiles.get(uid);
  },
});

const eligibilityOutput = eligibility.elements.get("#wrl-output").textContent.split(" ");
assert.deepEqual(eligibilityProfileOrder, ["302", "303", "304", "305", "301"]);
assert.deepEqual(new Set(eligibilityOutput), new Set(["@原创含抽", "@比例等于一半", "@比例小于一半"]));
assert.equal(eligibility.elements.get("#wrl-error").classList.contains("show"), false);
assert.ok(eligibility.calls
  .filter((url) => url.includes("containerid=107603"))
  .every((url) => /^\/api\/container\/getIndex\?containerid=107603\d+&page=1&count=10$/.test(url)));
assert.ok(eligibility.calls
  .filter((url) => url.includes("containerid=100505"))
  .every((url) => /^\/api\/container\/getIndex\?containerid=100505\d+$/.test(url)));
assert.equal(eligibility.calls.filter((url) => url.startsWith("/statuses/extend?")).length, 0);
assert.equal(eligibility.elements.get("#wrl-meta").textContent, "已检查 5 人 · 已通过 3 人");
assert.equal(eligibility.elements.get("#wrl-lottery-account-title").textContent, "抽奖号排除（2）");
assert.equal(
  eligibility.elements.get("#wrl-lottery-account-users").textContent,
  "@比例大于一半 @没有原创",
);

const classifiedStorage = new Map([[blockedTermsKey, JSON.stringify(["ban"])]]);
const classifiedProfileOrder = [];
const classified = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  drawCount: "1",
  randomValues: [5, 4, 3, 2, 1],
  storage: classifiedStorage,
  fetchHandler: (url) => {
    if (url.startsWith("/api/statuses/repostTimeline?")) {
      return mobileReposts([
        { uid: "311", name: "屏蔽词优先" },
        { uid: "312", name: "零条微博" },
        { uid: "313", name: "没有原创" },
        { uid: "314", name: "抽奖比例超标" },
        { uid: "315", name: "分类合格用户" },
        { uid: "316", name: "BAN未实际检查" },
      ]);
    }
    const uid = new URL(url, "https://m.weibo.cn").searchParams.get("containerid")?.replace("107603", "");
    classifiedProfileOrder.push(uid);
    if (uid === "311") return mobileProfile([retweet("正文含 BAN 和抽", "抽奖")]);
    if (uid === "312") return mobileProfile([]);
    if (uid === "313") return mobileProfile([retweet("普通转发", "普通内容")]);
    if (uid === "314") {
      return mobileProfile([
        original("普通原创"),
        retweet("抽奖一", "普通活动"),
        retweet("抽奖二", "普通活动"),
      ]);
    }
    return mobileProfile([original("合格原创")]);
  },
});

assert.deepEqual(classifiedProfileOrder, ["311", "312", "313", "314", "315"]);
assert.equal(classified.calls.some((url) => /containerid=(?:100505|107603)316(?:&|$)/.test(url)), false);
assert.equal(classified.elements.get("#wrl-output").textContent, "@分类合格用户");
assert.equal(classified.elements.get("#wrl-lottery-account-title").textContent, "抽奖号排除（3）");
assert.equal(
  classified.elements.get("#wrl-lottery-account-users").textContent,
  "@零条微博 @没有原创 @抽奖比例超标",
);
assert.equal(classified.elements.get("#wrl-blocked-term-title").textContent, "屏蔽词排除（1）");
assert.equal(classified.elements.get("#wrl-blocked-term-users").textContent, "@屏蔽词优先");
await classified.elements.get("#wrl-copy").listeners.get("click")();
assert.deepEqual(classified.clipboardWrites, ["@分类合格用户"]);

const freshExclusionGroups = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  drawCount: "1",
  randomValues: [1, 0],
  fetchHandler: (url) => {
    if (url.startsWith("/api/statuses/repostTimeline?")) {
      return mobileReposts([
        { uid: "319", name: "首轮抽奖号" },
        { uid: "320", name: "两轮合格" },
      ]);
    }
    const uid = new URL(url, "https://m.weibo.cn").searchParams.get("containerid")?.replace("107603", "");
    return uid === "319" ? mobileProfile([]) : mobileProfile([original("合格原创")]);
  },
});

assert.equal(freshExclusionGroups.elements.get("#wrl-lottery-account-users").textContent, "@首轮抽奖号");
await freshExclusionGroups.elements.get("#wrl-redraw").listeners.get("click")();
assert.equal(freshExclusionGroups.elements.get("#wrl-output").textContent, "@两轮合格");
assert.equal(freshExclusionGroups.elements.get("#wrl-lottery-account-title").textContent, "抽奖号排除（0）");
assert.equal(freshExclusionGroups.elements.get("#wrl-lottery-account-users").textContent, "无");
assert.equal(freshExclusionGroups.elements.get("#wrl-blocked-term-title").textContent, "屏蔽词排除（0）");
assert.equal(freshExclusionGroups.elements.get("#wrl-blocked-term-users").textContent, "无");

const missingUidStorage = new Map([[blockedTermsKey, JSON.stringify(["ban"])]]);
const missingUid = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  drawCount: "1",
  randomValues: [1],
  storage: missingUidStorage,
  fetchHandler: (url) => url.startsWith("/api/statuses/repostTimeline?")
    ? mobileReposts([
        { uid: "", name: "BAN但缺少UID" },
        { uid: "317", name: "缺UID后合格" },
      ])
    : mobileProfile([original("合格原创")]),
});

assert.equal(missingUid.elements.get("#wrl-output").textContent, "@缺UID后合格");
assert.match(missingUid.elements.get("#wrl-summary").textContent, /从 1 个去重用户名中抽取 1 个/);
assert.equal(missingUid.elements.get("#wrl-pages").textContent, "1 / 1 人");
assert.equal(missingUid.elements.get("#wrl-blocked-term-title").textContent, "屏蔽词排除（0）");
assert.equal(missingUid.elements.get("#wrl-blocked-term-users").textContent, "无");
assert.equal(missingUid.elements.get("#wrl-lottery-account-users").textContent, "无");
assert.equal(missingUid.calls.some((url) => /containerid=(?:100505|107603)(?:&|$)/.test(url)), false);

const onlyMissingUid = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  drawCount: "1",
  fetchHandler: (url) => {
    assert.equal(url.startsWith("/api/statuses/repostTimeline?"), true);
    return mobileReposts([{ uid: "", name: "唯一无UID记录" }]);
  },
});

assert.equal(onlyMissingUid.calls.length, 1);
assert.match(onlyMissingUid.elements.get("#wrl-error").textContent, /接口没有返回可用用户名/);
assert.equal(onlyMissingUid.elements.get("#wrl-result").classList.contains("show"), false);

const duplicateNameWithUid = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  drawCount: "1",
  fetchHandler: (url) => url.startsWith("/api/statuses/repostTimeline?")
    ? mobileReposts([
        { uid: "", name: "同名候选" },
        { uid: "318", name: "同名候选" },
      ])
    : mobileProfile([original("合格原创")]),
});

assert.equal(duplicateNameWithUid.elements.get("#wrl-output").textContent, "@同名候选");
assert.match(duplicateNameWithUid.elements.get("#wrl-summary").textContent, /从 1 个去重用户名中抽取 1 个/);
assert.equal(duplicateNameWithUid.calls.some((url) => url.includes("100505318")), true);
assert.equal(duplicateNameWithUid.calls.some((url) => url.includes("107603318")), true);
assert.equal(duplicateNameWithUid.elements.get("#wrl-lottery-account-users").textContent, "无");
assert.equal(duplicateNameWithUid.elements.get("#wrl-blocked-term-users").textContent, "无");

const longTextUsers = [
  { uid: "601", name: "原微博长文中奖" },
  { uid: "602", name: "外层长文中奖" },
];
const longTextProfiles = new Map([
  ["601", mobileProfile([
    original("原创内容"),
    {
      text_raw: "外层截断无关键词",
      retweeted_status: { idstr: "9601", isLongText: true, text_raw: "原微博截断无关键词" },
    },
  ])],
  ["602", mobileProfile([
    original("原创内容"),
    {
      idstr: "9602",
      isLongText: 1,
      text_raw: "外层截断无关键词",
      retweeted_status: { text_raw: "原微博短文无关键词" },
    },
  ])],
]);
const longTextIds = [];
const longTextLottery = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  drawCount: "2",
  randomValues: [1],
  fetchHandler: (url) => {
    if (url.startsWith("/api/statuses/repostTimeline?")) return mobileReposts(longTextUsers);
    if (url.startsWith("/api/container/getIndex?")) {
      const uid = new URL(url, "https://m.weibo.cn").searchParams.get("containerid")?.replace("107603", "");
      return longTextProfiles.get(uid);
    }
    const id = new URL(url, "https://m.weibo.cn").searchParams.get("id");
    longTextIds.push(id);
    return longText(id === "9601" ? "原微博完整正文含抽奖" : "外层完整正文含抽奖");
  },
});

assert.deepEqual(longTextIds, ["9601", "9602"]);
assert.deepEqual(
  new Set(longTextLottery.elements.get("#wrl-output").textContent.split(" ")),
  new Set(["@原微博长文中奖", "@外层长文中奖"]),
);
assert.equal(longTextLottery.elements.get("#wrl-error").classList.contains("show"), false);

const longFailureCounts = { extend: 0, failedProfile: 0, passingProfile: 0 };
const longFailure = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  drawCount: "1",
  randomValues: [1, 1],
  fetchHandler: (url) => {
    if (url.startsWith("/api/statuses/repostTimeline?")) {
      return mobileReposts([
        { uid: "701", name: "长文失败" },
        { uid: "702", name: "后续合格" },
      ]);
    }
    if (url.startsWith("/api/container/getIndex?")) {
      const uid = new URL(url, "https://m.weibo.cn").searchParams.get("containerid")?.replace("107603", "");
      if (uid === "701") {
        longFailureCounts.failedProfile += 1;
        return mobileProfile([
          original("原创内容"),
          retweet("普通转发", "截断内容"),
        ].map((mblog, index) => index === 1
          ? { ...mblog, retweeted_status: { ...mblog.retweeted_status, idstr: "9701", isLongText: true } }
          : mblog));
      }
      longFailureCounts.passingProfile += 1;
      return mobileProfile([original("合格原创")]);
    }
    longFailureCounts.extend += 1;
    return { body: { ok: 0, msg: "系统繁忙，请稍后再试" } };
  },
});

assert.equal(longFailure.elements.get("#wrl-output").textContent, "@后续合格");
assert.deepEqual(longFailureCounts, { extend: 2, failedProfile: 1, passingProfile: 1 });
const redrawAfterLongFailure = longFailure.elements.get("#wrl-redraw").listeners.get("click");
await redrawAfterLongFailure();
assert.deepEqual(longFailureCounts, { extend: 2, failedProfile: 1, passingProfile: 1 });

const longRateCalls = [];
const longRateLimited = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  drawCount: "1",
  randomValues: [1],
  fetchHandler: (url) => {
    if (url.startsWith("/api/statuses/repostTimeline?")) {
      return mobileReposts([
        { uid: "703", name: "长文限流" },
        { uid: "704", name: "不应继续" },
      ]);
    }
    if (url.startsWith("/api/container/getIndex?")) {
      const uid = new URL(url, "https://m.weibo.cn").searchParams.get("containerid")?.replace("107603", "");
      longRateCalls.push(`profile:${uid}`);
      return mobileProfile([
        original("原创内容"),
        { text_raw: "转发", retweeted_status: { idstr: "9702", isLongText: true, text_raw: "截断" } },
      ]);
    }
    longRateCalls.push("extend");
    return { httpOk: false, status: 418 };
  },
});

assert.deepEqual(longRateCalls, ["profile:703", "extend"]);
assertRateLimitSource(longRateLimited, "长微博正文接口（statuses/extend）");

let longPayloadRateCalls = 0;
const longPayloadRateLimited = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  drawCount: "1",
  fetchHandler: (url) => {
    if (url.startsWith("/api/statuses/repostTimeline?")) {
      return mobileReposts([{ uid: "706", name: "长正文消息限流" }]);
    }
    if (url.includes("containerid=107603706")) {
      return mobileProfile([
        original("原创内容"),
        { text_raw: "转发", retweeted_status: { idstr: "9704", isLongText: true, text_raw: "截断" } },
      ]);
    }
    longPayloadRateCalls += 1;
    return { body: { ok: 0, msg: "访问频繁，请稍后再试" } };
  },
});
assert.equal(longPayloadRateCalls, 1);
assertRateLimitSource(longPayloadRateLimited, "长微博正文接口（statuses/extend）");

const longTextLoggedOut = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  drawCount: "1",
  fetchHandler: (url) => {
    if (url.startsWith("/api/statuses/repostTimeline?")) {
      return mobileReposts([{ uid: "705", name: "长文登录失效" }]);
    }
    if (url.startsWith("/api/container/getIndex?")) {
      return mobileProfile([
        original("原创内容"),
        { text_raw: "转发", retweeted_status: { idstr: "9703", isLongText: true, text_raw: "截断" } },
      ]);
    }
    return { httpOk: false, status: 401 };
  },
});

assert.equal(longTextLoggedOut.calls.filter((url) => url.startsWith("/statuses/extend?")).length, 1);
assert.match(longTextLoggedOut.elements.get("#wrl-error").textContent, /登录微博/);

const retryCounts = new Map();
const retryUsers = [
  { uid: "401", name: "主页失败" },
  { uid: "402", name: "合格用户" },
];
const retryAndCache = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  drawCount: "1",
  randomValues: [1, 1],
  fetchHandler: (url) => {
    if (url.startsWith("/api/statuses/repostTimeline?")) return mobileReposts(retryUsers);
    const uid = new URL(url, "https://m.weibo.cn").searchParams.get("containerid")?.replace("107603", "");
    retryCounts.set(uid, (retryCounts.get(uid) || 0) + 1);
    return uid === "401"
      ? { body: { ok: 0, msg: "系统繁忙，请稍后再试" } }
      : mobileProfile([original("合格原创")]);
  },
});

assert.equal(retryAndCache.elements.get("#wrl-output").textContent, "@合格用户");
assert.equal(retryAndCache.elements.get("#wrl-lottery-account-users").textContent, "无");
assert.equal(retryAndCache.elements.get("#wrl-blocked-term-users").textContent, "无");
assert.equal(retryCounts.get("401"), 2);
assert.equal(retryCounts.get("402"), 1);
const redraw = retryAndCache.elements.get("#wrl-redraw").listeners.get("click");
assert.equal(typeof redraw, "function");
await redraw();
assert.equal(retryAndCache.elements.get("#wrl-output").textContent, "@合格用户");
assert.equal(retryCounts.get("401"), 2);
assert.equal(retryCounts.get("402"), 1);

const rateCalls = [];
const rateLimited = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  drawCount: "1",
  randomValues: [1],
  fetchHandler: (url) => {
    if (url.startsWith("/api/statuses/repostTimeline?")) {
      return mobileReposts([
        { uid: "501", name: "限流用户" },
        { uid: "502", name: "不应检查" },
      ]);
    }
    rateCalls.push(url);
    return { httpOk: false, status: 429 };
  },
});

assert.equal(rateCalls.length, 1);
assertRateLimitSource(rateLimited, "用户微博列表接口（107603）");
assert.equal(rateLimited.elements.get("#wrl-result").classList.contains("show"), false);
assert.equal(rateLimited.elements.get("#wrl-start").textContent, "尝试继续");

const payloadRateLimited = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  drawCount: "1",
  fetchHandler: (url) => url.startsWith("/api/statuses/repostTimeline?")
    ? mobileReposts([{ uid: "503", name: "消息限流" }])
    : { body: { ok: 0, msg: "访问次数过多，请稍后再试" } },
});

assert.equal(payloadRateLimited.calls.length, 3);
assertRateLimitSource(payloadRateLimited, "用户微博列表接口（107603）");

const relationResumeCalls = [];
let relationResumeLimits = 0;
const relationResume = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  drawCount: "2",
  randomValues: [3, 2, 1],
  fetchHandler: (url) => {
    if (url.startsWith("/api/statuses/repostTimeline?")) {
      return mobileReposts([
        { uid: "511", name: "先排除抽奖号" },
        { uid: "512", name: "已通过用户" },
        { uid: "513", name: "关系限流后通过" },
        { uid: "514", name: "不应检查的后续用户" },
      ]);
    }
    const uid = new URL(url, "https://m.weibo.cn").searchParams.get("containerid")?.replace("107603", "");
    relationResumeCalls.push(`profile:${uid}`);
    return uid === "511" ? mobileProfile([]) : mobileProfile([original("合格原创")]);
  },
  relationFetchHandler: (url) => {
    const uid = new URL(url, "https://m.weibo.cn").searchParams.get("containerid")?.replace("100505", "");
    relationResumeCalls.push(`relation:${uid}`);
    if (uid === "513" && relationResumeLimits < 2) {
      relationResumeLimits += 1;
      return { httpOk: false, status: 429 };
    }
    return mobileRelation(0);
  },
});

const relationResumeStart = relationResume.elements.get("#wrl-start").listeners.get("click");
assert.equal(relationResume.elements.get("#wrl-start").textContent, "尝试继续");
assert.equal(relationResume.elements.get("#wrl-meta").textContent, "已检查 2 人 · 已通过 1 人");
assert.deepEqual(relationResumeCalls, [
  "relation:511",
  "profile:511",
  "relation:512",
  "profile:512",
  "relation:513",
]);
await relationResumeStart();
assert.equal(relationResume.elements.get("#wrl-start").textContent, "尝试继续");
assert.equal(relationResume.elements.get("#wrl-meta").textContent, "已检查 2 人 · 已通过 1 人");
await relationResumeStart();
assert.equal(relationResume.elements.get("#wrl-start").textContent, "执行抽奖");
assert.equal(relationResume.elements.get("#wrl-output").textContent, "@已通过用户 @关系限流后通过");
assert.deepEqual(relationResumeCalls, [
  "relation:511",
  "profile:511",
  "relation:512",
  "profile:512",
  "relation:513",
  "relation:513",
  "relation:513",
  "profile:513",
]);
assert.equal(relationResume.elements.get("#wrl-lottery-account-title").textContent, "抽奖号排除（1）");
assert.equal(relationResume.elements.get("#wrl-lottery-account-users").textContent, "@先排除抽奖号");
assert.equal(relationResume.elements.get("#wrl-blocked-term-title").textContent, "屏蔽词排除（0）");
assert.equal(relationResume.elements.get("#wrl-blocked-term-users").textContent, "无");
assert.equal(
  relationResume.calls.filter((url) => url.startsWith("/api/statuses/repostTimeline?")).length,
  1,
);
assert.equal(relationResume.calls.some((url) => /containerid=(?:100505|107603)514(?:&|$)/.test(url)), false);

const profileResumeCalls = [];
let profileResumeLimited = true;
const profileResume = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  drawCount: "2",
  randomValues: [2, 1],
  fetchHandler: (url) => {
    if (url.startsWith("/api/statuses/repostTimeline?")) {
      return mobileReposts([
        { uid: "521", name: "主页前已通过" },
        { uid: "522", name: "主页限流后通过" },
        { uid: "523", name: "主页后续用户" },
      ]);
    }
    const uid = new URL(url, "https://m.weibo.cn").searchParams.get("containerid")?.replace("107603", "");
    profileResumeCalls.push(`profile:${uid}`);
    if (uid === "522" && profileResumeLimited) {
      profileResumeLimited = false;
      return { httpOk: false, status: 429 };
    }
    return mobileProfile([original("合格原创")]);
  },
  relationFetchHandler: (url) => {
    const uid = new URL(url, "https://m.weibo.cn").searchParams.get("containerid")?.replace("100505", "");
    profileResumeCalls.push(`relation:${uid}`);
    return mobileRelation(0);
  },
});

assert.equal(profileResume.elements.get("#wrl-start").textContent, "尝试继续");
assert.equal(profileResume.elements.get("#wrl-meta").textContent, "已检查 1 人 · 已通过 1 人");
await profileResume.elements.get("#wrl-start").listeners.get("click")();
assert.equal(profileResume.elements.get("#wrl-start").textContent, "执行抽奖");
assert.equal(profileResume.elements.get("#wrl-output").textContent, "@主页前已通过 @主页限流后通过");
assert.deepEqual(profileResumeCalls, [
  "relation:521",
  "profile:521",
  "relation:522",
  "profile:522",
  "profile:522",
]);
assert.equal(
  profileResume.calls.filter((url) => url.startsWith("/api/statuses/repostTimeline?")).length,
  1,
);
assert.equal(profileResume.calls.some((url) => url.includes("523")), false);

const extendResumeCalls = [];
let extendResumeLimited = true;
const extendResume = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  drawCount: "2",
  randomValues: [2, 1],
  fetchHandler: (url) => {
    if (url.startsWith("/api/statuses/repostTimeline?")) {
      return mobileReposts([
        { uid: "531", name: "长文前已通过" },
        { uid: "532", name: "长文限流后通过" },
        { uid: "533", name: "长文后续用户" },
      ]);
    }
    if (url.startsWith("/api/container/getIndex?")) {
      const uid = new URL(url, "https://m.weibo.cn").searchParams.get("containerid")?.replace("107603", "");
      extendResumeCalls.push(`profile:${uid}`);
      return uid === "532"
        ? mobileProfile([
            original("合格原创"),
            { text_raw: "普通转发", retweeted_status: { idstr: "9532", isLongText: true, text_raw: "截断正文" } },
          ])
        : mobileProfile([original("合格原创")]);
    }
    extendResumeCalls.push("extend:9532");
    if (extendResumeLimited) {
      extendResumeLimited = false;
      return { httpOk: false, status: 429 };
    }
    return longText("普通完整正文");
  },
  relationFetchHandler: (url) => {
    const uid = new URL(url, "https://m.weibo.cn").searchParams.get("containerid")?.replace("100505", "");
    extendResumeCalls.push(`relation:${uid}`);
    return mobileRelation(0);
  },
});

assert.equal(extendResume.elements.get("#wrl-start").textContent, "尝试继续");
assert.equal(extendResume.elements.get("#wrl-meta").textContent, "已检查 1 人 · 已通过 1 人");
await extendResume.elements.get("#wrl-start").listeners.get("click")();
assert.equal(extendResume.elements.get("#wrl-start").textContent, "执行抽奖");
assert.equal(extendResume.elements.get("#wrl-output").textContent, "@长文前已通过 @长文限流后通过");
assert.deepEqual(extendResumeCalls, [
  "relation:531",
  "profile:531",
  "relation:532",
  "profile:532",
  "extend:9532",
  "extend:9532",
]);
assert.equal(
  extendResume.calls.filter((url) => url.startsWith("/api/statuses/repostTimeline?")).length,
  1,
);
assert.equal(extendResume.calls.some((url) => /containerid=(?:100505|107603)533(?:&|$)/.test(url)), false);

const profileLoggedOut = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  drawCount: "1",
  fetchHandler: (url) => url.startsWith("/api/statuses/repostTimeline?")
    ? mobileReposts([{ uid: "504", name: "登录失效" }])
    : { httpOk: false, status: 401 },
});

assert.equal(profileLoggedOut.calls.length, 3);
assert.match(profileLoggedOut.elements.get("#wrl-error").textContent, /登录微博/);
assert.equal(profileLoggedOut.elements.get("#wrl-start").textContent, "执行抽奖");

const persistedStorage = new Map([
  [blockedTermsKey, JSON.stringify(["  已有词  ", "已有词", "EXISTING", "existing", "", 7])],
]);
const blockedTermsUi = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  responses: [mobileReposts([{ uid: "801", name: "界面用户" }])],
  storage: persistedStorage,
  clickStart: false,
});
const termsContainer = blockedTermsUi.elements.get("#wrl-block-terms");
assert.deepEqual(termsContainer.children.map((child) => child.textContent), ["已有词", "EXISTING"]);
const blockedInline = blockedTermsUi.elements.get("#wrl-block-inline");
const manageBlocked = blockedTermsUi.elements.get("#wrl-manage-blocked");
const blockedInput = blockedTermsUi.elements.get("#wrl-block-input");
assert.equal(blockedInline.classList.contains("show"), false);
manageBlocked.listeners.get("click")();
assert.equal(blockedInline.classList.contains("show"), true);
assert.equal(manageBlocked.getAttribute("aria-expanded"), "true");
assert.equal(blockedInput.focusCalls.length, 0);
const enterBlockedTerm = (value) => {
  blockedInput.value = value;
  let prevented = false;
  blockedInput.listeners.get("keydown")({ key: "Enter", preventDefault: () => { prevented = true; } });
  assert.equal(prevented, true);
};
enterBlockedTerm("  NewWord  ");
enterBlockedTerm("newword");
enterBlockedTerm("   ");
assert.deepEqual(termsContainer.children.map((child) => child.textContent), ["已有词", "EXISTING", "NewWord"]);
assert.deepEqual(JSON.parse(persistedStorage.get(blockedTermsKey)), ["已有词", "EXISTING", "NewWord"]);
termsContainer.children.find((child) => child.textContent === "已有词").listeners.get("click")();
assert.deepEqual(termsContainer.children.map((child) => child.textContent), ["EXISTING", "NewWord"]);
manageBlocked.listeners.get("click")();
assert.equal(blockedInline.classList.contains("show"), false);
assert.equal(manageBlocked.getAttribute("aria-expanded"), "false");
assert.equal(blockedInput.blurCalls, 1);

const blockedTermsReloaded = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  responses: [mobileReposts([{ uid: "802", name: "重载用户" }])],
  storage: persistedStorage,
  clickStart: false,
});
assert.deepEqual(
  blockedTermsReloaded.elements.get("#wrl-block-terms").children.map((child) => child.textContent),
  ["EXISTING", "NewWord"],
);

const singleHitStorage = new Map([[blockedTermsKey, JSON.stringify(["bad"])]]);
const singleHitUsers = [
  { uid: "811", name: "用户名BAD命中" },
  { uid: "812", name: "正文命中" },
  { uid: "813", name: "零命中" },
];
const singleHitProfiles = new Map([
  ["812", mobileProfile([{ text: "<span>bad</span>" }])],
  ["813", mobileProfile([{ text: '<span data-note="bad">普通原创</span>' }])],
]);
const singleHitProfileOrder = [];
const singleHitFiltering = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  drawCount: "1",
  randomValues: [2, 1],
  storage: singleHitStorage,
  fetchHandler: (url) => {
    if (url.startsWith("/api/statuses/repostTimeline?")) return mobileReposts(singleHitUsers);
    const uid = new URL(url, "https://m.weibo.cn").searchParams.get("containerid")?.replace("107603", "");
    singleHitProfileOrder.push(uid);
    return singleHitProfiles.get(uid);
  },
});

assert.deepEqual(singleHitProfileOrder, ["812", "813"]);
assert.equal(singleHitFiltering.elements.get("#wrl-output").textContent, "@零命中");
assert.equal(singleHitFiltering.elements.get("#wrl-lottery-account-users").textContent, "无");
assert.equal(singleHitFiltering.elements.get("#wrl-blocked-term-title").textContent, "屏蔽词排除（2）");
assert.equal(
  singleHitFiltering.elements.get("#wrl-blocked-term-users").textContent,
  "@用户名BAD命中 @正文命中",
);
assert.equal(singleHitFiltering.elements.get("#wrl-error").classList.contains("show"), false);

const outerHitStorage = new Map([[blockedTermsKey, JSON.stringify(["block"])]]);
const outerHitProfileOrder = [];
const outerHitFiltering = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  drawCount: "1",
  randomValues: [1],
  storage: outerHitStorage,
  fetchHandler: (url) => {
    if (url.startsWith("/api/statuses/repostTimeline?")) {
      return mobileReposts([
        { uid: "815", name: "外层候选" },
        { uid: "816", name: "外层后备" },
      ]);
    }
    const uid = new URL(url, "https://m.weibo.cn").searchParams.get("containerid")?.replace("107603", "");
    outerHitProfileOrder.push(uid);
    return uid === "815"
      ? mobileProfile([original("普通原创"), retweet("外层包含 BLOCK", "嵌套普通内容")])
      : mobileProfile([original("后备原创")]);
  },
});

assert.deepEqual(outerHitProfileOrder, ["815", "816"]);
assert.equal(outerHitFiltering.elements.get("#wrl-output").textContent, "@外层后备");
assert.equal(outerHitFiltering.elements.get("#wrl-error").classList.contains("show"), false);

const nestedHitStorage = new Map([[blockedTermsKey, JSON.stringify(["block"])]]);
const nestedHitProfileOrder = [];
const nestedHitFiltering = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  drawCount: "1",
  randomValues: [1],
  storage: nestedHitStorage,
  fetchHandler: (url) => {
    if (url.startsWith("/api/statuses/repostTimeline?")) {
      return mobileReposts([
        { uid: "817", name: "嵌套候选" },
        { uid: "818", name: "嵌套后备" },
      ]);
    }
    const uid = new URL(url, "https://m.weibo.cn").searchParams.get("containerid")?.replace("107603", "");
    nestedHitProfileOrder.push(uid);
    return uid === "817"
      ? mobileProfile([original("普通原创"), retweet("外层普通内容", "嵌套包含 block")])
      : mobileProfile([original("后备原创")]);
  },
});

assert.deepEqual(nestedHitProfileOrder, ["817", "818"]);
assert.equal(nestedHitFiltering.elements.get("#wrl-output").textContent, "@嵌套后备");
assert.equal(nestedHitFiltering.elements.get("#wrl-error").classList.contains("show"), false);

const noBlockedTerms = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  drawCount: "1",
  fetchHandler: (url) => url.startsWith("/api/statuses/repostTimeline?")
    ? mobileReposts([{ uid: "814", name: "badbadbad" }])
    : mobileProfile([original("bad bad bad")]),
});
assert.equal(noBlockedTerms.elements.get("#wrl-output").textContent, "@badbadbad");
assert.equal(noBlockedTerms.elements.get("#wrl-error").classList.contains("show"), false);

const dynamicStorage = new Map();
const dynamicCalls = { profile811: 0, profile812: 0, extend: 0 };
const dynamicTerms = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  drawCount: "1",
  randomValues: [1, 1, 1],
  storage: dynamicStorage,
  fetchHandler: (url) => {
    if (url.startsWith("/api/statuses/repostTimeline?")) {
      return mobileReposts([
        { uid: "821", name: "长文候选" },
        { uid: "822", name: "备用候选" },
      ]);
    }
    if (url.startsWith("/api/container/getIndex?")) {
      const uid = new URL(url, "https://m.weibo.cn").searchParams.get("containerid")?.replace("107603", "");
      if (uid === "821") {
        dynamicCalls.profile811 += 1;
        return mobileProfile([{ idstr: "9821", isLongText: true, text_raw: "截断原创" }]);
      }
      dynamicCalls.profile812 += 1;
      return mobileProfile([original("备用原创")]);
    }
    dynamicCalls.extend += 1;
    return longText('<p data-word="foo foo foo foo foo">FOO</p>');
  },
});

assert.equal(dynamicTerms.elements.get("#wrl-output").textContent, "@长文候选");
assert.deepEqual(dynamicCalls, { profile811: 1, profile812: 0, extend: 0 });
const dynamicInput = dynamicTerms.elements.get("#wrl-block-input");
dynamicInput.value = "foo";
dynamicInput.listeners.get("keydown")({ key: "Enter", preventDefault: () => {} });
const dynamicRedraw = dynamicTerms.elements.get("#wrl-redraw").listeners.get("click");
await dynamicRedraw();
assert.equal(dynamicTerms.elements.get("#wrl-output").textContent, "@备用候选");
assert.deepEqual(dynamicCalls, { profile811: 1, profile812: 1, extend: 1 });
const dynamicTermsContainer = dynamicTerms.elements.get("#wrl-block-terms");
dynamicTermsContainer.children.find((child) => child.textContent === "foo").listeners.get("click")();
await dynamicRedraw();
assert.equal(dynamicTerms.elements.get("#wrl-output").textContent, "@长文候选");
assert.deepEqual(dynamicCalls, { profile811: 1, profile812: 1, extend: 1 });

const truncated = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  drawCount: "1",
  responses: [
    {
      body: {
        ok: 1,
        data: {
          data: [{ idstr: "1", user: { screen_name: "用户甲" } }],
          max: 2,
          total_number: 2,
        },
      },
    },
    {
      body: {
        ok: 1,
        data: { data: [], max: 2, total_number: 2 },
      },
    },
  ],
});

assert.equal(truncated.elements.get("#wrl-error").classList.contains("show"), true);
assert.match(truncated.elements.get("#wrl-error").textContent, /提前为空/);

const notStatusPage = await runScenario({
  href: "https://weibo.com/",
  drawCount: "1",
  responses: [],
});

assert.equal(notStatusPage.calls.length, 0);
assert.match(notStatusPage.elements.get("#wrl-error").textContent, /m\.weibo\.cn/);

const unrelatedTwoPartRoute = await runScenario({
  href: "https://weibo.com/hot/search",
  drawCount: "1",
  responses: [],
});

assert.equal(unrelatedTwoPartRoute.calls.length, 0);
assert.match(unrelatedTwoPartRoute.elements.get("#wrl-error").textContent, /m\.weibo\.cn/);

const unsupportedHost = await runScenario({
  href: "https://example.com/7929840325/5307506404363728",
  drawCount: "1",
  responses: [],
});

assert.equal(unsupportedHost.calls.length, 0);
assert.match(unsupportedHost.elements.get("#wrl-error").textContent, /m\.weibo\.cn/);

const loggedOut = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  drawCount: "1",
  responses: [{ httpOk: false, status: 401 }],
  clickStart: false,
});

assert.equal(loggedOut.calls.length, 1);
assert.match(loggedOut.elements.get("#wrl-error").textContent, /登录微博/);
assert.equal(loggedOut.elements.get("#wrl-start").textContent, "执行抽奖");

const forbidden = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  drawCount: "1",
  responses: [{ httpOk: false, status: 403 }],
  clickStart: false,
});

assert.equal(forbidden.calls.length, 1);
assertRateLimitSource(forbidden, "转发列表接口（repostTimeline）");
assert.equal(forbidden.elements.get("#wrl-start").textContent, "执行抽奖");

const loginRedirect = await runScenario({
  href: "https://m.weibo.cn/detail/5336202665263592",
  drawCount: "1",
  responses: [{
    redirected: true,
    url: "https://passport.weibo.com/sso/signin",
    contentType: "text/html",
  }],
  clickStart: false,
});

assert.equal(loginRedirect.calls.length, 1);
assert.match(loginRedirect.elements.get("#wrl-error").textContent, /登录微博/);
assert.equal(allCalls.some((url) => url.startsWith("/setting/getFilter")), false);
assert.doesNotMatch(source, /id="wrl-url"/);
assert.doesNotMatch(source, /setting\/getFilter|屏蔽名单|filteredUserIds/);
assert.doesNotMatch(source, /weibo\.com|\/ajax\/|popcard|openapi/i);
assert.match(source, /containerid: `100505\$\{uid\}`/);
assert.match(source, /relation === 4/);
assert.match(source, /throw new Error\(`用户关系请求失败：\$\{lastError\}`\)/);
assert.match(source, />微博抽奖工具v4</);
assert.match(source, /placeholder="请输入中奖人数"/);
assert.match(source, />执行抽奖</);
assert.match(source, /检查登录…/);
assert.match(source, /MAX_PARALLEL_PAGES = 6/);
assert.match(
  source,
  /id="wrl-output"[\s\S]*?id="wrl-lottery-account-title">抽奖号排除（0）<\/strong>[\s\S]*?id="wrl-blocked-term-title">屏蔽词排除（0）<\/strong>[\s\S]*?id="wrl-redraw"/,
);
assert.match(
  source,
  /<button id="wrl-manage-blocked"[^>]*>管理屏蔽词<\/button>\s*<div id="wrl-block-inline" class="block-inline">[\s\S]*?<\/div>\s*<\/div>\s*<\/section>/,
);
assert.match(source, /\.block-inline\{display:none;min-height:0}/);
assert.match(source, /\.block-inline\.show\{display:grid}/);
assert.match(source, /\.block-terms\{[^}]*max-height:160px[^}]*overflow:auto[^}]*overscroll-behavior:contain/);
assert.doesNotMatch(source, /block-modal|block-card|block-close|wrl-block-modal|wrl-block-close/);
assert.doesNotMatch(source.match(/\.block-inline\{[^}]*}/)?.[0] || "", /100dvh|place-items|position:/);
assert.doesNotMatch(source, /220 \+ Math\.random\(\) \* 140/);
assert.doesNotMatch(source, /微博转发抽取|#ff8200|#16704d|#efc7c2|#9d3028|#fff3f1|class="subtitle"|class="foot"/);

assert.match(buildSource, /const outputPath = join\(projectDirectory, "微博抽奖工具v4\.shortcut"\)/);
assert.match(buildSource, /const javascript = readFileSync\(javascriptPath, "utf8"\)\.trim\(\)/);
assert.match(buildSource, /<key>WFJavaScript<\/key>\s*<string>\$\{escapeXml\(javascript\)\}<\/string>/);
assert.match(buildSource, /<key>WFWorkflowName<\/key>\s*<string>微博抽奖工具v4<\/string>/);
assert.deepEqual(localShortcutAsset, workerShortcutAsset);
assert.match(previewSource, /<title>微博抽奖工具v4<\/title>/);
assert.equal(localInstallSource, deployedInstallSource);
for (const installSource of [localInstallSource, deployedInstallSource]) {
  assert.match(installSource, /<title>微博抽奖工具v4<\/title>/);
  assert.doesNotMatch(installSource, /<h1\b/);
  assert.match(
    installSource.match(/<main>([\s\S]*?)<\/main>/)?.[1] || "",
    /^\s*<a class="install" href="https:\/\/www\.icloud\.com\/shortcuts\/fa00fff149aa4edbb74f84b3b5eab0bb">安装微博抽奖工具v4<\/a>\s*$/,
  );
  assert.match(installSource, /\.install\s*\{[^}]*width:\s*100%[^}]*height:\s*52px[^}]*border-radius:\s*10px/s);
  assert.doesNotMatch(installSource, /请使用 iPhone Safari 安装。/);
  assert.doesNotMatch(installSource, /<input\b|<form\b|\/tools\/weibo-lottery\/api\/download|请向作者索要token|\.shortcut\b|<script\b/i);
}
for (const artifactSource of [source, buildSource, previewSource, localInstallSource, deployedInstallSource]) {
  assert.doesNotMatch(artifactSource, /微博抽奖工具(?!v4)/);
}
assert.doesNotMatch(source, /countLiteralOccurrences|blockedCounts|count\s*>=\s*5/);

process.stdout.write("shortcut tests passed\n");
