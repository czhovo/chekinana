import assert from "node:assert/strict";
import { createHash, webcrypto } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  createLocalJWKSet,
  exportJWK,
  generateKeyPair,
  SignJWT,
} from "jose";

import {
  ACTIVE_TOKEN_STORAGE_KEY,
  CSRF_TOKEN_PATTERN,
  createApp,
  DOWNLOAD_TOKEN_INPUT_PATTERN,
  DOWNLOAD_TOKEN_PATTERN,
  escapeHtml,
  hashToken,
  issueDownloadToken,
  LEGACY_DOWNLOAD_TOKEN_PATTERN,
  normalizeDownloadToken,
  randomDownloadToken,
  TokenStore,
  verifyAccessToken,
} from "../src/worker.js";

const ORIGIN = "https://chekinana.top";
const ADMIN_PATH = "/tools/weibo-lottery/admin/";
const ADMIN_TOKEN_PATH = "/tools/weibo-lottery/admin/token";
const ADMIN_SCRIPT_PATH = "/tools/weibo-lottery/admin/client.js";
const DOWNLOAD_PATH = "/tools/weibo-lottery/api/download";
const deployedShortcut = new Uint8Array(await readFile(
  new URL("../assets/weibo-lottery-v3.shortcut", import.meta.url),
));
const deployedShortcutSha256 = "9dd58c891295a8bd6f95c8179eec3b59b352c80928aea1e43c06a485eca92741";
const deployedShortcutSize = 32_612;

class SerialMemoryStorage {
  constructor() {
    this.values = new Map();
    this.tail = Promise.resolve();
  }

  get(key) {
    return Promise.resolve(this.values.get(key));
  }

  put(key, value) {
    this.values.set(key, value);
    return Promise.resolve();
  }

  delete(key) {
    this.values.delete(key);
    return Promise.resolve();
  }

  transaction(callback) {
    const run = this.tail.then(() => callback(this));
    this.tail = run.catch(() => {});
    return run;
  }
}

const createEnvironment = () => {
  const storage = new SerialMemoryStorage();
  const durableObject = new TokenStore({ storage });
  let assetFetches = 0;
  return {
    env: {
      TEAM_DOMAIN: "test-team.cloudflareaccess.com",
      POLICY_AUD: "test-audience",
      TOKEN_STORE: {
        idFromName(name) {
          assert.equal(name, "weibo-lottery-token-store");
          return "singleton";
        },
        get(id) {
          assert.equal(id, "singleton");
          return durableObject;
        },
      },
      ASSETS: {
        async fetch(request) {
          assetFetches += 1;
          if (new URL(request.url).pathname !== "/weibo-lottery-v3.shortcut") {
            return new Response("Not Found", { status: 404 });
          }
          return new Response(deployedShortcut);
        },
      },
    },
    storage,
    assetFetchCount: () => assetFetches,
  };
};

const accessVerifier = async (assertion, config) => {
  assert.deepEqual(config, {
    issuer: "https://test-team.cloudflareaccess.com",
    audience: "test-audience",
  });
  if (assertion !== "valid-admin-jwt") throw new Error("invalid JWT");
  return { sub: "admin", iat: 1, exp: 4_000_000_000 };
};

const app = createApp({ accessVerifier });

const sameOriginHeaders = (extra = {}) => ({
  Origin: ORIGIN,
  "Sec-Fetch-Site": "same-origin",
  ...extra,
});

const adminHeaders = (extra = {}) => sameOriginHeaders({
  "Cf-Access-Jwt-Assertion": "valid-admin-jwt",
  ...extra,
});

const accessHeaders = (extra = {}) => ({
  "Cf-Access-Jwt-Assertion": "valid-admin-jwt",
  ...extra,
});

const formRequest = (path, token, headers = {}) => new Request(`${ORIGIN}${path}`, {
  method: "POST",
  headers: sameOriginHeaders({
    "Content-Type": "application/x-www-form-urlencoded",
    ...headers,
  }),
  body: new URLSearchParams(token === undefined ? {} : { token }),
});

const csrfFromHtml = (html) => html
  .match(/<input type="hidden" name="csrf_token" value="([A-Za-z0-9_-]+)" \/>/u)?.[1] || "";

const csrfCookiePair = (response) => response.headers.get("Set-Cookie")?.split(";", 1)[0] || "";

const csrfFromCookiePair = (cookiePair) => cookiePair
  .match(/^__Host-weibo-lottery-csrf=([A-Za-z0-9_-]+)$/u)?.[1] || "";

const startAdminSession = async (env, headers = accessHeaders()) => {
  const response = await app.fetch(new Request(`${ORIGIN}${ADMIN_PATH}`, { headers }), env);
  assert.equal(response.status, 200);
  const html = await response.text();
  const csrfToken = csrfFromHtml(html);
  const cookiePair = csrfCookiePair(response);
  assert.match(csrfToken, CSRF_TOKEN_PATTERN);
  assert.equal(csrfFromCookiePair(cookiePair), csrfToken);
  return { response, html, csrfToken, cookiePair };
};

const adminPostRequest = ({
  csrfToken,
  cookiePair,
  headers = {},
  contentType = "application/x-www-form-urlencoded",
  body,
}) => {
  const requestHeaders = accessHeaders(headers);
  if (cookiePair !== null && cookiePair !== undefined) requestHeaders.Cookie = cookiePair;
  if (contentType !== null) requestHeaders["Content-Type"] = contentType;
  const requestBody = body ?? new URLSearchParams(
    csrfToken === undefined ? {} : { csrf_token: csrfToken },
  );
  return new Request(`${ORIGIN}${ADMIN_TOKEN_PATH}`, {
    method: "POST",
    headers: requestHeaders,
    body: requestBody,
  });
};

const postAdminSession = (env, session, options = {}) => app.fetch(adminPostRequest({
  csrfToken: Object.hasOwn(options, "csrfToken") ? options.csrfToken : session.csrfToken,
  cookiePair: Object.hasOwn(options, "cookiePair") ? options.cookiePair : session.cookiePair,
  headers: options.headers,
  contentType: Object.hasOwn(options, "contentType") ? options.contentType : undefined,
  body: options.body,
}), env);

const generateToken = async (env, headers = adminHeaders()) => {
  const session = await startAdminSession(env);
  const response = await postAdminSession(env, session, { headers });
  assert.equal(response.status, 200);
  const html = await response.text();
  const token = html.match(/<output id="token"[^>]*>([0-9A-Z]{6})<\/output>/u)?.[1];
  assert.match(token || "", DOWNLOAD_TOKEN_PATTERN);
  return { response, token, html, session };
};

const assertSecurityHeaders = (response) => {
  assert.equal(response.headers.get("Cache-Control"), "no-store, max-age=0");
  assert.match(response.headers.get("Content-Security-Policy") || "", /default-src 'none'/u);
  assert.match(response.headers.get("Content-Security-Policy") || "", /form-action 'self'/u);
  assert.match(response.headers.get("Content-Security-Policy") || "", /frame-ancestors 'none'/u);
  assert.equal(response.headers.get("X-Content-Type-Options"), "nosniff");
  assert.equal(response.headers.get("X-Frame-Options"), "DENY");
  assert.equal(response.headers.get("Referrer-Policy"), "no-referrer");
};

test("jose validates Access signature, issuer, audience, and required claims", async () => {
  const issuer = "https://test-team.cloudflareaccess.com";
  const audience = "test-audience";
  const { publicKey, privateKey } = await generateKeyPair("RS256");
  const publicJwk = await exportJWK(publicKey);
  publicJwk.kid = "test-key";
  publicJwk.alg = "RS256";
  const localJwks = createLocalJWKSet({ keys: [publicJwk] });
  const assertion = await new SignJWT({ sub: "admin" })
    .setProtectedHeader({ alg: "RS256", kid: "test-key" })
    .setIssuer(issuer)
    .setAudience(audience)
    .setIssuedAt()
    .setExpirationTime("5m")
    .sign(privateKey);

  const payload = await verifyAccessToken(assertion, { issuer, audience }, localJwks);
  assert.equal(payload.sub, "admin");
  await assert.rejects(
    verifyAccessToken(assertion, { issuer, audience: "wrong-audience" }, localJwks),
  );
  await assert.rejects(
    verifyAccessToken(assertion, {
      issuer: "https://wrong-team.cloudflareaccess.com",
      audience,
    }, localJwks),
  );

  const otherKeyPair = await generateKeyPair("RS256");
  const wrongSignature = await new SignJWT({ sub: "admin" })
    .setProtectedHeader({ alg: "RS256", kid: "test-key" })
    .setIssuer(issuer)
    .setAudience(audience)
    .setIssuedAt()
    .setExpirationTime("5m")
    .sign(otherKeyPair.privateKey);
  await assert.rejects(
    verifyAccessToken(wrongSignature, { issuer, audience }, localJwks),
  );
  await assert.rejects(
    verifyAccessToken("not-a-jwt", { issuer, audience }, localJwks),
  );
});

test("deployed Worker asset matches the verified signed v3 fingerprint", () => {
  assert.equal(deployedShortcut.byteLength, deployedShortcutSize);
  assert.equal(createHash("sha256").update(deployedShortcut).digest("hex"), deployedShortcutSha256);
});

test("download token generator uses unbiased 0-9A-Z rejection sampling", () => {
  const source = [252, 255, 0, 10, 35, 9, 11, 34];
  const fakeCrypto = {
    getRandomValues(bucket) {
      bucket.fill(255);
      source.forEach((value, index) => { bucket[index] = value; });
      return bucket;
    },
  };

  const token = randomDownloadToken(fakeCrypto);
  assert.equal(token, "0AZ9BY");
  assert.match(token, DOWNLOAD_TOKEN_PATTERN);
  assert.match("0az9by", DOWNLOAD_TOKEN_INPUT_PATTERN);
  assert.equal(normalizeDownloadToken("0az9by"), token);
  assert.equal(normalizeDownloadToken("0AZ9B_"), "");
  assert.equal(normalizeDownloadToken("0AZ9B"), "");
});

test("download token allocation retries a SHA-256 collision", async () => {
  const { env, storage } = createEnvironment();
  const collidingToken = "000000";
  await storage.put(ACTIVE_TOKEN_STORAGE_KEY, await hashToken(collidingToken));
  let randomCalls = 0;
  const fakeCrypto = {
    subtle: webcrypto.subtle,
    getRandomValues(bucket) {
      bucket.fill(randomCalls === 0 ? 0 : 1);
      randomCalls += 1;
      return bucket;
    },
  };

  const token = await issueDownloadToken(env, fakeCrypto);
  assert.equal(token, "111111");
  assert.equal(randomCalls, 2);
  assert.deepEqual([...storage.values.entries()], [
    [ACTIVE_TOKEN_STORAGE_KEY, await hashToken("111111")],
  ]);
});

test("admin requires configured and valid Cloudflare Access JWT", async () => {
  const { env } = createEnvironment();

  const missingConfig = await app.fetch(new Request(`${ORIGIN}${ADMIN_PATH}`, {
    headers: { "Cf-Access-Jwt-Assertion": "valid-admin-jwt" },
  }), { ...env, TEAM_DOMAIN: "" });
  assert.equal(missingConfig.status, 503);

  const missingJwt = await app.fetch(new Request(`${ORIGIN}${ADMIN_PATH}`), env);
  assert.equal(missingJwt.status, 401);

  const wrongJwt = await app.fetch(new Request(`${ORIGIN}${ADMIN_PATH}`, {
    headers: { "Cf-Access-Jwt-Assertion": "wrong-admin-jwt" },
  }), env);
  assert.equal(wrongJwt.status, 401);

  const allowed = await app.fetch(new Request(`${ORIGIN}${ADMIN_PATH}`, {
    headers: { "Cf-Access-Jwt-Assertion": "valid-admin-jwt" },
  }), env);
  assert.equal(allowed.status, 200);
  assert.match(await allowed.text(), /微博抽奖工具v4 管理/u);
  assertSecurityHeaders(allowed);
});

test("admin GET issues a hidden CSRF value and matching hardened host cookie", async () => {
  const { env } = createEnvironment();
  const session = await startAdminSession(env);
  const setCookie = session.response.headers.get("Set-Cookie") || "";

  assert.equal(session.response.headers.get("Content-Type"), "text/html; charset=utf-8");
  assert.match(session.html, /<form method="post" action="\/tools\/weibo-lottery\/admin\/token">/u);
  assert.match(session.html, /<input type="hidden" name="csrf_token" value="[A-Za-z0-9_-]{43}" \/>/u);
  assert.match(session.html, /<button type="submit">生成token<\/button>/u);
  assert.match(session.html, /<script src="\/tools\/weibo-lottery\/admin\/client\.js" defer><\/script>/u);
  assert.equal((session.html.match(/<script\b/gu) || []).length, 1);
  assert.match(setCookie, /^__Host-weibo-lottery-csrf=[A-Za-z0-9_-]{43};/u);
  assert.match(setCookie, /; Max-Age=1800(?:;|$)/u);
  assert.match(setCookie, /; Path=\/(?:;|$)/u);
  assert.match(setCookie, /; Secure(?:;|$)/u);
  assert.match(setCookie, /; HttpOnly(?:;|$)/u);
  assert.match(setCookie, /; SameSite=Strict(?:;|$)/u);
  assert.doesNotMatch(setCookie, /;\s*Domain=/iu);
  const csp = session.response.headers.get("Content-Security-Policy") || "";
  assert.match(csp, /script-src 'self'/u);
  assert.match(csp, /connect-src 'self'/u);
  assert.doesNotMatch(csp, /script-src[^;]*'unsafe-inline'/u);
  assert.match(csp, /frame-ancestors 'none'/u);
  assert.match(csp, /base-uri 'none'/u);
  assertSecurityHeaders(session.response);
  assert.equal(
    escapeHtml(`<script data-x="'">&`),
    "&lt;script data-x=&quot;&#39;&quot;&gt;&amp;",
  );
});

test("external admin client route requires Access and returns strict JavaScript", async () => {
  const { env } = createEnvironment();
  const missingJwt = await app.fetch(new Request(`${ORIGIN}${ADMIN_SCRIPT_PATH}`), env);
  assert.equal(missingJwt.status, 401);

  const response = await app.fetch(new Request(`${ORIGIN}${ADMIN_SCRIPT_PATH}`, {
    headers: accessHeaders(),
  }), env);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Content-Type"), "text/javascript; charset=utf-8");
  const source = await response.text();
  assert.doesNotThrow(() => new Function(source));
  assert.match(source, /event\.preventDefault\(\)/u);
  assert.match(source, /if \(submitting\) return/u);
  assert.match(source, /Accept: 'application\/json'/u);
  assert.match(source, /'Content-Type': 'application\/x-www-form-urlencoded'/u);
  assert.match(source, /credentials: 'same-origin'/u);
  assert.match(source, /body: new URLSearchParams\(new FormData\(form\)\)/u);
  assert.match(source, /output\.textContent = result\.token/u);
  assert.doesNotMatch(source, /innerHTML/u);
  assert.doesNotMatch(response.headers.get("Content-Security-Policy") || "", /script-src 'self'/u);
  assertSecurityHeaders(response);
});

test("generated token is cryptographically sized and only its hash is stored", async () => {
  const { env, storage } = createEnvironment();
  const { response, token, html, session } = await generateToken(env);

  assert.equal(token.length, 6);
  assert.match(token, DOWNLOAD_TOKEN_PATTERN);
  assert.match(html, /<button type="submit">生成token<\/button>/u);
  assertSecurityHeaders(response);

  const rotatedCookiePair = csrfCookiePair(response);
  const rotatedCsrfToken = csrfFromHtml(html);
  assert.match(rotatedCsrfToken, CSRF_TOKEN_PATTERN);
  assert.equal(csrfFromCookiePair(rotatedCookiePair), rotatedCsrfToken);
  assert.notEqual(rotatedCookiePair, session.cookiePair);

  const expectedHash = await hashToken(token);
  assert.deepEqual([...storage.values.entries()], [[ACTIVE_TOKEN_STORAGE_KEY, expectedHash]]);
  assert.equal(JSON.stringify([...storage.values.entries()]).includes(token), false);
});

test("active token storage has no TTL or expiration metadata", async () => {
  const { env, storage } = createEnvironment();
  const { token } = await generateToken(env);
  assert.deepEqual([...storage.values.entries()], [
    [ACTIVE_TOKEN_STORAGE_KEY, await hashToken(token)],
  ]);
  assert.equal(typeof storage.values.get(ACTIVE_TOKEN_STORAGE_KEY), "string");
  assert.equal(storage.values.get(ACTIVE_TOKEN_STORAGE_KEY).length, 64);
});

test("generating B atomically invalidates unused A and leaves no token after B is consumed", async () => {
  const { env, storage } = createEnvironment();
  const first = await generateToken(env);
  const second = await generateToken(env);
  assert.notEqual(first.token, second.token);
  assert.deepEqual([...storage.values.entries()], [
    [ACTIVE_TOKEN_STORAGE_KEY, await hashToken(second.token)],
  ]);

  const replaced = await app.fetch(formRequest(DOWNLOAD_PATH, first.token), env);
  assert.equal(replaced.status, 403);
  const active = await app.fetch(formRequest(DOWNLOAD_PATH, second.token), env);
  assert.equal(active.status, 200);
  assert.equal(storage.values.size, 0);
  const replay = await app.fetch(formRequest(DOWNLOAD_PATH, second.token), env);
  assert.equal(replay.status, 403);
});

test("JSON admin submission returns only token data and rotates CSRF state", async () => {
  const { env, storage } = createEnvironment();
  const session = await startAdminSession(env);
  const response = await postAdminSession(env, session, {
    headers: {
      Accept: "application/json",
      Origin: ORIGIN,
      "Sec-Fetch-Site": "same-origin",
    },
  });

  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Content-Type"), "application/json");
  assertSecurityHeaders(response);
  const rawBody = await response.text();
  assert.doesNotMatch(rawBody, /<!doctype|<html|<output/iu);
  const result = JSON.parse(rawBody);
  assert.deepEqual(Object.keys(result).sort(), ["csrfToken", "token"]);
  assert.match(result.token, DOWNLOAD_TOKEN_PATTERN);
  assert.match(result.csrfToken, CSRF_TOKEN_PATTERN);
  assert.equal(csrfFromCookiePair(csrfCookiePair(response)), result.csrfToken);
  assert.notEqual(result.csrfToken, session.csrfToken);
  assert.equal(storage.values.size, 1);
  assert.deepEqual([...storage.values.entries()], [
    [ACTIVE_TOKEN_STORAGE_KEY, await hashToken(result.token)],
  ]);
});

test("JSON admin errors are generic and do not leak submitted CSRF values", async () => {
  const { env, storage } = createEnvironment();
  const session = await startAdminSession(env);
  const wrongCsrf = `${session.csrfToken[0] === "x" ? "y" : "x"}${session.csrfToken.slice(1)}`;
  const response = await postAdminSession(env, session, {
    csrfToken: wrongCsrf,
    headers: { Accept: "application/json" },
  });

  assert.equal(response.status, 403);
  assert.equal(response.headers.get("Content-Type"), "application/json");
  assert.deepEqual(await response.json(), { error: "请求被拒绝" });
  assert.equal(response.headers.get("Set-Cookie"), null);
  assert.equal(storage.values.size, 0);

  const crossSite = await postAdminSession(env, session, {
    headers: {
      Accept: "application/json",
      Origin: "https://attacker.invalid",
      "Sec-Fetch-Site": "cross-site",
    },
  });
  const crossSiteBody = await crossSite.text();
  assert.equal(crossSite.status, 403);
  assert.deepEqual(JSON.parse(crossSiteBody), { error: "请求被拒绝" });
  assert.equal(crossSiteBody.includes(session.csrfToken), false);
  assert.equal(crossSiteBody.includes(session.cookiePair), false);
  assert.equal(storage.values.size, 0);
});

test("Durable Object consumes once and serializes concurrent consumers", async () => {
  const storage = new SerialMemoryStorage();
  const durableObject = new TokenStore({ storage });
  const hash = await hashToken("Aa0zZ9");
  const call = (pathname) => durableObject.fetch(new Request(`https://token-store.internal${pathname}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ hash }),
  }));

  const issued = await call("/issue");
  assert.deepEqual(await issued.json(), { created: true });

  const results = await Promise.all(Array.from({ length: 12 }, async () => {
    const response = await call("/consume");
    return (await response.json()).consumed;
  }));
  assert.equal(results.filter(Boolean).length, 1);
  assert.equal(results.filter((value) => !value).length, 11);
  assert.equal(storage.values.size, 0);
});

test("concurrent issues finish with exactly one active hash", async () => {
  const storage = new SerialMemoryStorage();
  const durableObject = new TokenStore({ storage });
  const hashes = await Promise.all(
    ["000000", "111111", "222222", "333333"].map((token) => hashToken(token)),
  );
  const call = (pathname, hash) => durableObject.fetch(new Request(
    `https://token-store.internal${pathname}`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ hash }),
    },
  ));

  const issued = await Promise.all(hashes.map((hash) => call("/issue", hash)));
  assert.equal((await Promise.all(issued.map((response) => response.json())))
    .filter(({ created }) => created).length, hashes.length);
  assert.equal(storage.values.size, 1);
  assert.equal(hashes.includes(storage.values.get(ACTIVE_TOKEN_STORAGE_KEY)), true);

  const consumed = await Promise.all(hashes.map(async (hash) => {
    const response = await call("/consume", hash);
    return (await response.json()).consumed;
  }));
  assert.equal(consumed.filter(Boolean).length, 1);
  assert.equal(storage.values.size, 0);
});

test("download rejects missing, incorrect, and reused tokens without distinguishing them", async () => {
  const { env } = createEnvironment();
  const missing = await app.fetch(formRequest(DOWNLOAD_PATH, undefined), env);
  const incorrect = await app.fetch(formRequest(DOWNLOAD_PATH, "ZZZZZZ"), env);
  assert.equal(missing.status, 403);
  assert.equal(incorrect.status, 403);
  assert.equal(await missing.text(), await incorrect.text());

  const { token } = await generateToken(env);
  const success = await app.fetch(formRequest(DOWNLOAD_PATH, token), env);
  assert.equal(success.status, 200);
  assert.equal(success.headers.get("Content-Type"), "application/octet-stream");
  assert.equal(
    success.headers.get("Content-Disposition"),
    "attachment; filename*=UTF-8''%E5%BE%AE%E5%8D%9A%E6%8A%BD%E5%A5%96%E5%B7%A5%E5%85%B7v4.shortcut",
  );
  assert.deepEqual(new Uint8Array(await success.arrayBuffer()), deployedShortcut);
  assertSecurityHeaders(success);

  const reused = await app.fetch(formRequest(DOWNLOAD_PATH, token), env);
  assert.equal(reused.status, 403);
  assert.equal(await reused.text(), "token无效或已使用");
});

test("download normalizes submitted token case before hash and one-time consume", async () => {
  const { env, storage } = createEnvironment();
  const canonicalToken = "AB12CD";
  await storage.put(ACTIVE_TOKEN_STORAGE_KEY, await hashToken(canonicalToken));

  const lowercase = await app.fetch(formRequest(DOWNLOAD_PATH, "ab12cd"), env);
  assert.equal(lowercase.status, 200);
  assert.deepEqual(new Uint8Array(await lowercase.arrayBuffer()), deployedShortcut);

  const reusedUppercase = await app.fetch(formRequest(DOWNLOAD_PATH, canonicalToken), env);
  assert.equal(reusedUppercase.status, 403);
  assert.equal(storage.values.size, 0);
});

test("legacy 43-character download token remains case-sensitive and one-time", async () => {
  const { env, storage } = createEnvironment();
  const legacyToken = `${"A".repeat(42)}_`;
  assert.match(legacyToken, LEGACY_DOWNLOAD_TOKEN_PATTERN);
  await storage.put(ACTIVE_TOKEN_STORAGE_KEY, await hashToken(legacyToken));

  const wrongCase = await app.fetch(formRequest(DOWNLOAD_PATH, `${"a".repeat(42)}_`), env);
  assert.equal(wrongCase.status, 403);
  assert.equal(storage.values.size, 1);

  const first = await app.fetch(formRequest(DOWNLOAD_PATH, legacyToken), env);
  assert.equal(first.status, 200);
  assert.deepEqual(new Uint8Array(await first.arrayBuffer()), deployedShortcut);

  const second = await app.fetch(formRequest(DOWNLOAD_PATH, legacyToken), env);
  assert.equal(second.status, 403);
  assert.equal(storage.values.size, 0);
});

test("old token-per-hash storage keys are never consumed", async () => {
  const { env, storage } = createEnvironment();
  const legacyToken = `${"B".repeat(42)}-`;
  const oldStorageKey = `token:${await hashToken(legacyToken)}`;
  await storage.put(oldStorageKey, true);

  const response = await app.fetch(formRequest(DOWNLOAD_PATH, legacyToken), env);
  assert.equal(response.status, 403);
  assert.deepEqual([...storage.values.entries()], [[oldStorageKey, true]]);
  assert.equal(storage.values.has(ACTIVE_TOKEN_STORAGE_KEY), false);
});

test("nearby invalid new and legacy token lengths are rejected before asset access", async () => {
  const { env, assetFetchCount } = createEnvironment();
  for (const token of [
    "A".repeat(5),
    "A".repeat(7),
    "A".repeat(42),
    "A".repeat(44),
  ]) {
    const response = await app.fetch(formRequest(DOWNLOAD_PATH, token), env);
    assert.equal(response.status, 403, `length ${token.length}`);
  }
  assert.equal(assetFetchCount(), 0);
});

test("concurrent downloads allow exactly one response to receive the asset", async () => {
  const { env } = createEnvironment();
  const { token } = await generateToken(env);
  const responses = await Promise.all(Array.from(
    { length: 8 },
    () => app.fetch(formRequest(DOWNLOAD_PATH, token), env),
  ));
  assert.equal(responses.filter((response) => response.status === 200).length, 1);
  assert.equal(responses.filter((response) => response.status === 403).length, 7);
});

test("same-origin checks reject CSRF without consuming a valid token", async () => {
  const { env, storage } = createEnvironment();
  const adminCsrf = await app.fetch(new Request(`${ORIGIN}${ADMIN_TOKEN_PATH}`, {
    method: "POST",
    headers: {
      "Cf-Access-Jwt-Assertion": "valid-admin-jwt",
      Origin: "https://attacker.invalid",
      "Sec-Fetch-Site": "cross-site",
    },
  }), env);
  assert.equal(adminCsrf.status, 403);
  assert.equal(storage.values.size, 0);

  const { token } = await generateToken(env);
  const wrongOrigin = await app.fetch(formRequest(DOWNLOAD_PATH, token, {
    Origin: "https://attacker.invalid",
  }), env);
  assert.equal(wrongOrigin.status, 403);

  const wrongFetchSite = await app.fetch(formRequest(DOWNLOAD_PATH, token, {
    "Sec-Fetch-Site": "cross-site",
  }), env);
  assert.equal(wrongFetchSite.status, 403);

  const sameSite = await app.fetch(formRequest(DOWNLOAD_PATH, token), env);
  assert.equal(sameSite.status, 200);
});

test("same-origin POST remains compatible when Safari omits Sec-Fetch-Site", async () => {
  const { env } = createEnvironment();
  const { token } = await generateToken(env, {
    Origin: ORIGIN,
    "Cf-Access-Jwt-Assertion": "valid-admin-jwt",
  });

  const response = await app.fetch(new Request(`${ORIGIN}${DOWNLOAD_PATH}`, {
    method: "POST",
    headers: {
      Origin: ORIGIN,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams({ token }),
  }), env);
  assert.equal(response.status, 200);
  assert.deepEqual(new Uint8Array(await response.arrayBuffer()), deployedShortcut);
});

test("invalid admin CSRF, form, and explicit cross-site evidence never issue a token", async () => {
  const { env, storage } = createEnvironment();
  const session = await startAdminSession(env);
  const differentToken = `${session.csrfToken[0] === "x" ? "y" : "x"}${session.csrfToken.slice(1)}`;
  const validBody = `csrf_token=${encodeURIComponent(session.csrfToken)}`;
  const cases = [
    { name: "missing field", options: { csrfToken: undefined } },
    { name: "wrong field", options: { csrfToken: differentToken } },
    {
      name: "duplicate field",
      options: { body: `${validBody}&${validBody}` },
    },
    { name: "missing cookie", options: { cookiePair: null } },
    {
      name: "wrong cookie",
      options: { cookiePair: `__Host-weibo-lottery-csrf=${differentToken}` },
    },
    {
      name: "duplicate cookie",
      options: { cookiePair: `${session.cookiePair}; ${session.cookiePair}` },
    },
    {
      name: "wrong origin",
      options: { headers: { Origin: "https://attacker.invalid" } },
    },
    {
      name: "null origin",
      options: { headers: { Origin: "null", "Sec-Fetch-Site": "same-origin" } },
    },
    {
      name: "cross-site",
      options: { headers: { "Sec-Fetch-Site": "cross-site" } },
    },
    {
      name: "same-site",
      options: { headers: { "Sec-Fetch-Site": "same-site" } },
    },
    {
      name: "origin and fetch metadata conflict",
      options: { headers: { Origin: ORIGIN, "Sec-Fetch-Site": "cross-site" } },
    },
    {
      name: "wrong content type",
      options: { contentType: "text/plain" },
    },
    {
      name: "oversized body",
      options: { body: `${validBody}&padding=${"x".repeat(600)}` },
    },
  ];

  for (const item of cases) {
    const response = await postAdminSession(env, session, item.options);
    assert.equal(response.status, 403, item.name);
    assert.equal(response.headers.get("Content-Type"), "text/plain; charset=utf-8", item.name);
    assert.equal(response.headers.get("Set-Cookie"), null, item.name);
    assert.equal(storage.values.size, 0, item.name);
  }
});

test("admin token generation supports normal and Safari form header variants", async () => {
  const variants = [
    {
      name: "normal",
      headers: { Origin: ORIGIN, "Sec-Fetch-Site": "same-origin" },
    },
    {
      name: "Origin without fetch metadata",
      headers: { Origin: ORIGIN },
    },
    {
      name: "Safari same-origin metadata without Origin",
      headers: { "Sec-Fetch-Site": "same-origin" },
    },
    {
      name: "Safari without either optional header",
      headers: {},
    },
  ];

  for (const variant of variants) {
    const { env, storage } = createEnvironment();
    const session = await startAdminSession(env);
    const response = await postAdminSession(env, session, { headers: variant.headers });
    assert.equal(response.status, 200, variant.name);
    assert.equal(response.headers.get("Content-Type"), "text/html; charset=utf-8", variant.name);
    const html = await response.text();
    const downloadToken = html
      .match(/<output id="token"[^>]*>([0-9A-Z]{6})<\/output>/u)?.[1] || "";
    const nextCsrfToken = csrfFromHtml(html);
    const nextCookiePair = csrfCookiePair(response);
    assert.match(downloadToken, DOWNLOAD_TOKEN_PATTERN, variant.name);
    assert.match(nextCsrfToken, CSRF_TOKEN_PATTERN, variant.name);
    assert.equal(csrfFromCookiePair(nextCookiePair), nextCsrfToken, variant.name);
    assert.notEqual(nextCookiePair, session.cookiePair, variant.name);
    assert.equal(storage.values.size, 1, variant.name);
  }
});

test("static shortcut asset is never exposed by a public Worker route", async () => {
  const { env, assetFetchCount } = createEnvironment();
  const response = await app.fetch(new Request(`${ORIGIN}/weibo-lottery-v3.shortcut`), env);
  assert.equal(response.status, 404);
  assert.equal(assetFetchCount(), 0);
  assertSecurityHeaders(response);
});
