import { createRemoteJWKSet, jwtVerify } from "jose";

const ADMIN_PATH = "/tools/weibo-lottery/admin/";
const ADMIN_TOKEN_PATH = "/tools/weibo-lottery/admin/token";
const ADMIN_SCRIPT_PATH = "/tools/weibo-lottery/admin/client.js";
const DOWNLOAD_PATH = "/tools/weibo-lottery/api/download";
const ASSET_PATH = "/weibo-lottery-v3.shortcut";
const CSRF_TOKEN_BYTES = 32;
const CSRF_TOKEN_PATTERN = /^[A-Za-z0-9_-]{43}$/;
const DOWNLOAD_TOKEN_ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";
const DOWNLOAD_TOKEN_LENGTH = 6;
const DOWNLOAD_TOKEN_PATTERN = /^[0-9A-Z]{6}$/;
const DOWNLOAD_TOKEN_INPUT_PATTERN = /^[0-9A-Za-z]{6}$/;
const LEGACY_DOWNLOAD_TOKEN_PATTERN = /^[A-Za-z0-9_-]{43}$/;
const DOWNLOAD_TOKEN_REJECTION_LIMIT = Math.floor(256 / DOWNLOAD_TOKEN_ALPHABET.length)
  * DOWNLOAD_TOKEN_ALPHABET.length;
const DOWNLOAD_TOKEN_RANDOM_BATCH_BYTES = 16;
const CSRF_COOKIE_NAME = "__Host-weibo-lottery-csrf";
const CSRF_MAX_AGE_SECONDS = 1_800;
const MAX_FORM_BYTES = 512;
const ACTIVE_TOKEN_STORAGE_KEY = "active-download-token-hash";
const jwksByIssuer = new Map();

const DEFAULT_CSP = "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'";
const ADMIN_CSP = "default-src 'none'; style-src 'unsafe-inline'; script-src 'self'; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'";

const SECURITY_HEADERS = Object.freeze({
  "Cache-Control": "no-store, max-age=0",
  "Content-Security-Policy": DEFAULT_CSP,
  "Permissions-Policy": "camera=(), geolocation=(), microphone=()",
  "Referrer-Policy": "no-referrer",
  "X-Content-Type-Options": "nosniff",
  "X-Frame-Options": "DENY",
});

const textEncoder = new TextEncoder();

const responseHeaders = (headers = {}) => new Headers({
  ...SECURITY_HEADERS,
  ...headers,
});

const htmlResponse = (html, status = 200, headers = {}) => new Response(html, {
  status,
  headers: responseHeaders({
    ...headers,
    "Content-Type": "text/html; charset=utf-8",
  }),
});

const textResponse = (text, status) => new Response(text, {
  status,
  headers: responseHeaders({ "Content-Type": "text/plain; charset=utf-8" }),
});

const jsonResponse = (value, status = 200, headers = {}) => Response.json(value, {
  status,
  headers: responseHeaders(headers),
});

const javascriptResponse = (source) => new Response(source, {
  status: 200,
  headers: responseHeaders({ "Content-Type": "text/javascript; charset=utf-8" }),
});

const normalizeTeamDomain = (rawValue) => {
  const value = typeof rawValue === "string" ? rawValue.trim() : "";
  if (!value) throw new Error("TEAM_DOMAIN is not configured");

  const url = new URL(value.includes("://") ? value : `https://${value}`);
  if (
    url.protocol !== "https:"
    || url.username
    || url.password
    || url.pathname !== "/"
    || url.search
    || url.hash
    || !url.hostname.endsWith(".cloudflareaccess.com")
  ) {
    throw new Error("TEAM_DOMAIN is invalid");
  }
  return url.origin;
};

const readAccessConfig = (env) => {
  const issuer = normalizeTeamDomain(env?.TEAM_DOMAIN);
  const audience = typeof env?.POLICY_AUD === "string" ? env.POLICY_AUD.trim() : "";
  if (!audience) throw new Error("POLICY_AUD is not configured");
  return { issuer, audience };
};

const remoteJwksFor = (issuer) => {
  if (!jwksByIssuer.has(issuer)) {
    jwksByIssuer.set(
      issuer,
      createRemoteJWKSet(new URL("/cdn-cgi/access/certs", `${issuer}/`)),
    );
  }
  return jwksByIssuer.get(issuer);
};

export const verifyAccessToken = async (
  assertion,
  { issuer, audience },
  keySet = remoteJwksFor(issuer),
) => {
  const result = await jwtVerify(assertion, keySet, {
    issuer,
    audience,
    requiredClaims: ["sub", "iat", "exp"],
  });
  return result.payload;
};

const authorizeAdmin = async (request, env, verifier) => {
  let config;
  try {
    config = readAccessConfig(env);
  } catch {
    return { ok: false, status: 503 };
  }

  const assertion = request.headers.get("Cf-Access-Jwt-Assertion");
  if (!assertion) return { ok: false, status: 401 };

  try {
    await verifier(assertion, config);
    return { ok: true };
  } catch {
    return { ok: false, status: 401 };
  }
};

const isSameOriginPost = (request) => {
  if (request.method !== "POST") return false;
  const requestOrigin = new URL(request.url).origin;
  const origin = request.headers.get("Origin");
  const secFetchSite = request.headers.get("Sec-Fetch-Site");
  if (origin === null) return secFetchSite === "same-origin";
  return origin === requestOrigin
    && (secFetchSite === null || secFetchSite === "same-origin");
};

const hasNoExplicitCrossSiteEvidence = (request) => {
  if (request.method !== "POST") return false;
  const requestOrigin = new URL(request.url).origin;
  const origin = request.headers.get("Origin");
  const secFetchSite = request.headers.get("Sec-Fetch-Site");
  if (origin !== null && origin !== requestOrigin) return false;
  if (secFetchSite !== null && secFetchSite !== "same-origin") return false;
  return true;
};

const randomCsrfToken = (cryptoImplementation = crypto) => {
  const bytes = new Uint8Array(CSRF_TOKEN_BYTES);
  cryptoImplementation.getRandomValues(bytes);
  const binary = Array.from(bytes, (value) => String.fromCharCode(value)).join("");
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
};

export const randomDownloadToken = (cryptoImplementation = crypto) => {
  let token = "";
  const bytes = new Uint8Array(DOWNLOAD_TOKEN_RANDOM_BATCH_BYTES);
  while (token.length < DOWNLOAD_TOKEN_LENGTH) {
    cryptoImplementation.getRandomValues(bytes);
    for (const value of bytes) {
      if (value >= DOWNLOAD_TOKEN_REJECTION_LIMIT) continue;
      token += DOWNLOAD_TOKEN_ALPHABET[value % DOWNLOAD_TOKEN_ALPHABET.length];
      if (token.length === DOWNLOAD_TOKEN_LENGTH) break;
    }
  }
  return token;
};

export const normalizeDownloadToken = (value) => {
  const token = typeof value === "string" ? value : "";
  if (DOWNLOAD_TOKEN_INPUT_PATTERN.test(token)) return token.toUpperCase();
  if (LEGACY_DOWNLOAD_TOKEN_PATTERN.test(token)) return token;
  return "";
};

export const escapeHtml = (value) => String(value)
  .replaceAll("&", "&amp;")
  .replaceAll("<", "&lt;")
  .replaceAll(">", "&gt;")
  .replaceAll('"', "&quot;")
  .replaceAll("'", "&#39;");

const csrfCookie = (value) => `${CSRF_COOKIE_NAME}=${value}; Max-Age=${CSRF_MAX_AGE_SECONDS}; Path=/; Secure; HttpOnly; SameSite=Strict`;

const csrfCookieFromRequest = (request) => {
  const cookieHeader = request.headers.get("Cookie") || "";
  if (!cookieHeader || cookieHeader.length > 4_096) return "";
  const values = cookieHeader
    .split(";")
    .map((part) => part.trim())
    .filter((part) => part.startsWith(`${CSRF_COOKIE_NAME}=`))
    .map((part) => part.slice(CSRF_COOKIE_NAME.length + 1));
  return values.length === 1 ? values[0] : "";
};

const csrfTokensMatch = (submitted, cookieValue) => {
  const left = typeof submitted === "string" ? submitted : "";
  const right = typeof cookieValue === "string" ? cookieValue : "";
  let difference = left.length ^ right.length;
  for (let index = 0; index < 43; index += 1) {
    difference |= (left.charCodeAt(index) || 0) ^ (right.charCodeAt(index) || 0);
  }
  return difference === 0
    && CSRF_TOKEN_PATTERN.test(left)
    && CSRF_TOKEN_PATTERN.test(right);
};

const acceptsJson = (request) => (request.headers.get("Accept") || "")
  .split(",")
  .some((value) => value.trim().split(";", 1)[0].toLowerCase() === "application/json");

const adminFailureResponse = (request, status, text) => acceptsJson(request)
  ? jsonResponse({ error: "请求被拒绝" }, status)
  : textResponse(text, status);

export const hashToken = async (token, cryptoImplementation = crypto) => {
  const digest = await cryptoImplementation.subtle.digest("SHA-256", textEncoder.encode(token));
  return Array.from(new Uint8Array(digest), (value) => value.toString(16).padStart(2, "0")).join("");
};

export class TokenStore {
  constructor(ctx) {
    this.storage = ctx.storage;
  }

  async fetch(request) {
    if (request.method !== "POST") return textResponse("Method Not Allowed", 405);

    let body;
    try {
      body = await request.json();
    } catch {
      return textResponse("Bad Request", 400);
    }

    if (!/^[a-f0-9]{64}$/u.test(body?.hash || "")) return textResponse("Bad Request", 400);
    const pathname = new URL(request.url).pathname;

    if (pathname === "/issue") {
      const created = await this.storage.transaction(async (transaction) => {
        if (await transaction.get(ACTIVE_TOKEN_STORAGE_KEY) === body.hash) return false;
        await transaction.put(ACTIVE_TOKEN_STORAGE_KEY, body.hash);
        return true;
      });
      return Response.json({ created }, { headers: responseHeaders() });
    }

    if (pathname === "/consume") {
      const consumed = await this.storage.transaction(async (transaction) => {
        if (await transaction.get(ACTIVE_TOKEN_STORAGE_KEY) !== body.hash) return false;
        await transaction.delete(ACTIVE_TOKEN_STORAGE_KEY);
        return true;
      });
      return Response.json({ consumed }, { headers: responseHeaders() });
    }

    return textResponse("Not Found", 404);
  }
}

const tokenStore = (env) => {
  const id = env.TOKEN_STORE.idFromName("weibo-lottery-token-store");
  return env.TOKEN_STORE.get(id);
};

const callTokenStore = async (env, pathname, hash) => {
  const response = await tokenStore(env).fetch(new Request(`https://token-store.internal${pathname}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ hash }),
  }));
  if (!response.ok) throw new Error("Token store unavailable");
  return response.json();
};

export const issueDownloadToken = async (env, cryptoImplementation) => {
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const token = randomDownloadToken(cryptoImplementation);
    const hash = await hashToken(token, cryptoImplementation);
    const { created } = await callTokenStore(env, "/issue", hash);
    if (created) return token;
  }
  throw new Error("Unable to allocate token");
};

const consumeDownloadToken = async (env, token, cryptoImplementation) => {
  const normalizedToken = normalizeDownloadToken(token);
  if (!normalizedToken) return false;
  const hash = await hashToken(normalizedToken, cryptoImplementation);
  const { consumed } = await callTokenStore(env, "/consume", hash);
  return consumed === true;
};

const adminClientSource = `(() => {
  const form = document.querySelector('form[action="${ADMIN_TOKEN_PATH}"]');
  const csrfInput = form?.querySelector('input[name="csrf_token"]');
  const output = document.querySelector('#token');
  const button = form?.querySelector('button[type="submit"]');
  if (!form || !csrfInput || !output || !button) return;

  let submitting = false;
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (submitting) return;
    submitting = true;
    button.disabled = true;

    try {
      const response = await fetch(form.action, {
        method: 'POST',
        headers: {
          Accept: 'application/json',
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        credentials: 'same-origin',
        body: new URLSearchParams(new FormData(form)),
      });
      const result = await response.json();
      if (!response.ok || typeof result.token !== 'string' || typeof result.csrfToken !== 'string') {
        throw new Error('request failed');
      }
      csrfInput.value = result.csrfToken;
      output.textContent = result.token;
    } catch {
      output.textContent = '请求失败，请重试';
    } finally {
      button.disabled = false;
      submitting = false;
    }
  });
})();
`;

const adminDocument = (token = "", csrfToken = "") => `<!doctype html>
<html lang="zh-CN">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
    <title>微博抽奖工具v4 管理</title>
    <style>
      * { box-sizing: border-box; }
      body { margin: 0; min-height: 100svh; display: grid; place-items: center; padding: 24px; font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif; color: #1d1d1f; background: #fff; }
      main { width: min(100%, 360px); display: grid; gap: 16px; }
      h1 { margin: 0; font-size: 22px; }
      button, output { width: 100%; min-height: 52px; border-radius: 10px; font: inherit; }
      button { border: 0; color: #fff; background: #1d1d1f; font-weight: 600; }
      output { display: flex; align-items: center; padding: 12px; border: 1px solid #d2d2d7; overflow-wrap: anywhere; user-select: all; }
    </style>
    <script src="${ADMIN_SCRIPT_PATH}" defer></script>
  </head>
  <body>
    <main>
      <h1>微博抽奖工具v4 管理</h1>
      <form method="post" action="${ADMIN_TOKEN_PATH}">
        <input type="hidden" name="csrf_token" value="${escapeHtml(csrfToken)}" />
        <button type="submit">生成token</button>
      </form>
      <output id="token" aria-live="polite">${escapeHtml(token)}</output>
    </main>
  </body>
</html>`;

const readUrlEncodedForm = async (request) => {
  const contentType = request.headers.get("Content-Type")?.split(";", 1)[0].trim().toLowerCase();
  if (contentType !== "application/x-www-form-urlencoded") return null;

  const contentLength = request.headers.get("Content-Length");
  if (contentLength !== null) {
    if (!/^\d+$/u.test(contentLength) || Number(contentLength) > MAX_FORM_BYTES) return null;
  }

  try {
    const body = await request.text();
    if (textEncoder.encode(body).byteLength > MAX_FORM_BYTES) return null;
    return new URLSearchParams(body);
  } catch {
    return null;
  }
};

const readSubmittedToken = async (request) => {
  const form = await readUrlEncodedForm(request);
  if (!form) return "";
  const values = form.getAll("token");
  return values.length === 1 ? values[0] : "";
};

export const createApp = ({
  accessVerifier = verifyAccessToken,
  cryptoImplementation = crypto,
} = {}) => ({
  async fetch(request, env) {
    const url = new URL(request.url);

    if ((url.pathname === "/tools/weibo-lottery/admin" || url.pathname === ADMIN_PATH) && request.method === "GET") {
      const authorization = await authorizeAdmin(request, env, accessVerifier);
      if (!authorization.ok) return textResponse("访问被拒绝", authorization.status);
      try {
        const csrfToken = randomCsrfToken(cryptoImplementation);
        return htmlResponse(adminDocument("", csrfToken), 200, {
          "Content-Security-Policy": ADMIN_CSP,
          "Set-Cookie": csrfCookie(csrfToken),
        });
      } catch {
        return textResponse("服务暂时不可用", 503);
      }
    }

    if (url.pathname === ADMIN_SCRIPT_PATH) {
      const authorization = await authorizeAdmin(request, env, accessVerifier);
      if (!authorization.ok) return textResponse("访问被拒绝", authorization.status);
      if (request.method !== "GET") return textResponse("Method Not Allowed", 405);
      return javascriptResponse(adminClientSource);
    }

    if (url.pathname === ADMIN_TOKEN_PATH) {
      if (request.method !== "POST") return textResponse("Method Not Allowed", 405);
      const authorization = await authorizeAdmin(request, env, accessVerifier);
      if (!authorization.ok) return adminFailureResponse(request, authorization.status, "访问被拒绝");
      if (!hasNoExplicitCrossSiteEvidence(request)) {
        return adminFailureResponse(request, 403, "请求被拒绝");
      }

      const form = await readUrlEncodedForm(request);
      const csrfValues = form?.getAll("csrf_token") || [];
      const submittedCsrf = csrfValues.length === 1 ? csrfValues[0] : "";
      if (!csrfTokensMatch(submittedCsrf, csrfCookieFromRequest(request))) {
        return adminFailureResponse(request, 403, "请求被拒绝");
      }

      try {
        const nextCsrfToken = randomCsrfToken(cryptoImplementation);
        const token = await issueDownloadToken(env, cryptoImplementation);
        if (acceptsJson(request)) {
          return jsonResponse({ token, csrfToken: nextCsrfToken }, 200, {
            "Set-Cookie": csrfCookie(nextCsrfToken),
          });
        }
        return htmlResponse(adminDocument(token, nextCsrfToken), 200, {
          "Content-Security-Policy": ADMIN_CSP,
          "Set-Cookie": csrfCookie(nextCsrfToken),
        });
      } catch {
        return adminFailureResponse(request, 503, "服务暂时不可用");
      }
    }

    if (url.pathname === DOWNLOAD_PATH) {
      if (request.method !== "POST") return textResponse("Method Not Allowed", 405);
      if (!isSameOriginPost(request)) return textResponse("请求被拒绝", 403);

      const submittedToken = normalizeDownloadToken(await readSubmittedToken(request));
      if (!submittedToken) {
        return textResponse("token无效或已使用", 403);
      }

      try {
        const assetUrl = new URL(ASSET_PATH, request.url);
        const assetResponse = await env.ASSETS.fetch(new Request(assetUrl));
        if (!assetResponse.ok) return textResponse("服务暂时不可用", 503);
        const assetBytes = await assetResponse.arrayBuffer();

        if (!await consumeDownloadToken(env, submittedToken, cryptoImplementation)) {
          return textResponse("token无效或已使用", 403);
        }

        return new Response(assetBytes, {
          status: 200,
          headers: responseHeaders({
            "Content-Disposition": "attachment; filename*=UTF-8''%E5%BE%AE%E5%8D%9A%E6%8A%BD%E5%A5%96%E5%B7%A5%E5%85%B7v4.shortcut",
            "Content-Type": "application/octet-stream",
          }),
        });
      } catch {
        return textResponse("服务暂时不可用", 503);
      }
    }

    return textResponse("Not Found", 404);
  },
});

export {
  ACTIVE_TOKEN_STORAGE_KEY,
  CSRF_TOKEN_PATTERN,
  DOWNLOAD_TOKEN_INPUT_PATTERN,
  DOWNLOAD_TOKEN_PATTERN,
  LEGACY_DOWNLOAD_TOKEN_PATTERN,
};
export default createApp();
