import { interpretNaturalLanguage } from "./nl-interpreter.js";
import {
  EVENT_ENDPOINT,
  extractWeiboCandidateRequest,
} from "./event-weibo-extractor.js";
import { annotateChekiDateResponse } from "./cheki-date-annotator.js";

const RUNPOD_HTTP_PORT = 8080;
const LOCAL_SCANNER_MODE = "CHEKINANA_SCANNER_LOCAL_MODE";
const LOCAL_SCANNER_UPSTREAM = "CHEKINANA_SCANNER_LOCAL_UPSTREAM";
const LOCAL_SCANNER_TOKEN = "CHEKINANA_SCANNER_LOCAL_TOKEN";
const LOCAL_SCANNER_CONFIGURATION_ERROR = "local_scanner_configuration_invalid";
const LOCAL_SCANNER_REQUEST_ERROR = "local_scanner_request_invalid";
const LOCAL_SCANNER_UPSTREAM_ERROR = "local_scanner_upstream_unavailable";
const LOCAL_SCANNER_TOKEN_PATTERN = /^[A-Za-z0-9._~-]{16,256}$/u;
const LOOPBACK_UPSTREAM_PATTERN = /^http:\/\/127\.0\.0\.1:([1-9]\d{0,4})\/?$/u;
const LOCAL_CLIENT_SOURCE_HEADERS = [
  "cf-connecting-ip",
  "cf-ipcountry",
  "cf-pseudo-ipv4",
  "cf-ray",
  "cf-visitor",
  "forwarded",
  "true-client-ip",
  "x-client-ip",
  "x-cluster-client-ip",
  "x-forwarded-for",
  "x-forwarded-host",
  "x-forwarded-port",
  "x-forwarded-proto",
  "x-real-ip",
];
const DATE_ANNOTATION_QUERY = "date_annotation";
const DATE_RESPONSE_HEADERS = [
  "x-cheki-date-status",
  "x-cheki-date-text",
  "x-cheki-date-precision",
  "x-cheki-date-bbox",
  "x-cheki-date-error",
];

function json(body, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "access-control-allow-origin": "*",
      "access-control-allow-methods": "GET,POST,OPTIONS",
      "access-control-allow-headers": "content-type,x-cheki-token",
      ...extraHeaders,
    },
  });
}

function normalizePodId(value) {
  const raw = (value || "").trim();
  const urlMatch = raw.match(/^https?:\/\/([a-z0-9]+)-\d+\.proxy\.runpod\.net/i);
  if (urlMatch) return urlMatch[1];

  const host = raw.replace(/^https?:\/\//i, "").split(/[/?#:\s]/)[0];
  const hostMatch = host.match(/^([a-z0-9]+)-\d+\.proxy\.runpod\.net/i);
  if (hostMatch) return hostMatch[1];

  return /^[a-z0-9]+$/i.test(host) ? host : "";
}

function getRequestToken(request, url) {
  const headerToken = request.headers.get("x-cheki-token");
  if (headerToken) return headerToken;

  const queryToken = url.searchParams.get("token");
  if (queryToken) return queryToken;

  return "";
}

function hasEnvironmentValue(env, name) {
  return env?.[name] !== undefined && env?.[name] !== null;
}

function parseLocalScannerConfiguration(env) {
  const rawMode = env?.[LOCAL_SCANNER_MODE];
  const hasLocalSettings = hasEnvironmentValue(env, LOCAL_SCANNER_UPSTREAM)
    || hasEnvironmentValue(env, LOCAL_SCANNER_TOKEN);

  if (rawMode === undefined || rawMode === null || rawMode === "false") {
    return hasLocalSettings
      ? { kind: "invalid" }
      : { kind: "production" };
  }
  if (rawMode !== "true") return { kind: "invalid" };

  const upstream = env?.[LOCAL_SCANNER_UPSTREAM];
  const token = env?.[LOCAL_SCANNER_TOKEN];
  if (typeof upstream !== "string" || typeof token !== "string"
    || !LOCAL_SCANNER_TOKEN_PATTERN.test(token)) {
    return { kind: "invalid" };
  }

  const match = LOOPBACK_UPSTREAM_PATTERN.exec(upstream);
  if (!match) return { kind: "invalid" };
  const port = Number(match[1]);
  if (!Number.isInteger(port) || port < 1 || port > 65_535) {
    return { kind: "invalid" };
  }

  return {
    kind: "local",
    upstream: `http://127.0.0.1:${port}`,
    token,
  };
}

async function timingSafeTokenEqual(expected, provided) {
  if (!LOCAL_SCANNER_TOKEN_PATTERN.test(expected)
    || !LOCAL_SCANNER_TOKEN_PATTERN.test(provided)) {
    return false;
  }
  const encoder = new TextEncoder();
  const [expectedDigest, providedDigest] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(expected)),
    crypto.subtle.digest("SHA-256", encoder.encode(provided)),
  ]);
  const expectedBytes = new Uint8Array(expectedDigest);
  const providedBytes = new Uint8Array(providedDigest);
  let difference = 0;
  for (let index = 0; index < expectedBytes.length; index += 1) {
    difference |= expectedBytes[index] ^ providedBytes[index];
  }
  return difference === 0;
}

function copyHeaders(request) {
  const headers = new Headers(request.headers);
  headers.delete("host");
  headers.delete("cf-connecting-ip");
  headers.delete("cf-ipcountry");
  headers.delete("cf-ray");
  headers.delete("cf-visitor");
  headers.delete("x-forwarded-proto");
  headers.delete("x-real-ip");
  headers.delete("content-length");
  return headers;
}

function localScannerConfigurationError() {
  return json(
    { ok: false, error: LOCAL_SCANNER_CONFIGURATION_ERROR },
    503,
    { "cache-control": "no-store" },
  );
}

function localScannerRequestError() {
  return json(
    { ok: false, error: LOCAL_SCANNER_REQUEST_ERROR },
    400,
    { "cache-control": "no-store" },
  );
}

function appendFormDataValue(target, name, value) {
  if (typeof value === "string") {
    target.append(name, value);
    return;
  }
  target.append(name, value, value.name);
}

async function prepareLocalBody(request, headers) {
  if (!request.body) return { body: null };

  const contentType = (request.headers.get("content-type") || "").toLowerCase();
  if (contentType.startsWith("multipart/form-data;")) {
    let source;
    try {
      source = await request.formData();
    } catch {
      return { error: true };
    }
    const sanitized = new FormData();
    for (const [name, value] of source.entries()) {
      if (name.toLowerCase() !== "token") {
        appendFormDataValue(sanitized, name, value);
      }
    }
    headers.delete("content-type");
    return { body: sanitized };
  }

  if (contentType.startsWith("application/x-www-form-urlencoded")) {
    let source;
    try {
      source = new URLSearchParams(await request.text());
    } catch {
      return { error: true };
    }
    source.delete("token");
    headers.set("content-type", "application/x-www-form-urlencoded;charset=UTF-8");
    return { body: source.toString() };
  }

  if (contentType.startsWith("application/json")) {
    let source;
    try {
      source = JSON.parse(await request.text());
    } catch {
      return { error: true };
    }
    if (source === null || typeof source !== "object" || Array.isArray(source)) {
      return { error: true };
    }
    const sanitized = { ...source };
    delete sanitized.token;
    headers.set("content-type", "application/json");
    return { body: JSON.stringify(sanitized) };
  }

  return { error: true };
}

async function localUpstreamRequest(request, url, configuration) {
  const headers = copyHeaders(request);
  headers.delete("x-cheki-token");
  for (const name of LOCAL_CLIENT_SOURCE_HEADERS) headers.delete(name);
  const preparedBody = await prepareLocalBody(request, headers);
  if (preparedBody.error) return null;

  const upstreamUrl = new URL(configuration.upstream);
  upstreamUrl.pathname = url.pathname;
  upstreamUrl.search = url.search;
  upstreamUrl.searchParams.delete("token");
  if (isCurrentResultPartPath(url.pathname)) {
    upstreamUrl.searchParams.delete(DATE_ANNOTATION_QUERY);
  }

  return new Request(upstreamUrl.toString(), {
    method: request.method,
    headers,
    body: preparedBody.body,
    redirect: "manual",
  });
}

function isCurrentResultPartPath(pathname) {
  const segments = pathname.split("/");
  return segments.length === 5
    && segments[0] === ""
    && segments[1] === "api"
    && segments[2] === "result"
    && segments[3].length > 0
    && /^\d+$/u.test(segments[4]);
}

function requestsDateAnnotation(request, url) {
  const values = url.searchParams.getAll(DATE_ANNOTATION_QUERY);
  return request.method === "GET"
    && isCurrentResultPartPath(url.pathname)
    && values.length === 1
    && values[0] === "1";
}

function exposeDateHeaders(headers) {
  const existing = (headers.get("access-control-expose-headers") || "")
    .split(",")
    .map((value) => value.trim().toLowerCase())
    .filter(Boolean);
  headers.set(
    "access-control-expose-headers",
    [...new Set([...existing, ...DATE_RESPONSE_HEADERS])].join(","),
  );
}

function applyDateAnnotationHeaders(headers, annotation) {
  for (const name of DATE_RESPONSE_HEADERS) headers.delete(name);
  const status = annotation?.status === "detected"
    || annotation?.status === "not_detected"
    ? annotation.status
    : "unavailable";
  headers.set("x-cheki-date-status", status);
  if (status === "detected") {
    headers.set("x-cheki-date-text", annotation.text);
    headers.set("x-cheki-date-precision", annotation.precision);
    headers.set("x-cheki-date-bbox", annotation.bbox.join(","));
  } else if (status === "unavailable") {
    headers.set("x-cheki-date-error", annotation?.error || "internal_error");
  }
  headers.set("cache-control", "no-store");
  exposeDateHeaders(headers);
}

export async function handleRequest(request, env = {}, fetchImpl = fetch) {
  const url = new URL(request.url);
  const dateAnnotationRequested = requestsDateAnnotation(request, url);

  if (request.method === "OPTIONS") {
    const headers = (url.pathname === "/api/nl/interpret" || url.pathname === EVENT_ENDPOINT)
      ? { "cache-control": "no-store" }
      : {};
    if (isCurrentResultPartPath(url.pathname)
      && url.searchParams.getAll(DATE_ANNOTATION_QUERY).includes("1")) {
      headers["cache-control"] = "no-store";
      headers["access-control-expose-headers"] = DATE_RESPONSE_HEADERS.join(",");
    }
    return json({ ok: true }, 200, headers);
  }

  if (url.pathname === "/api/nl/interpret") {
    const result = await interpretNaturalLanguage(request, env, { fetchImpl });
    return json(result.body, result.status, { "cache-control": "no-store" });
  }

  if (url.pathname === EVENT_ENDPOINT) {
    const result = await extractWeiboCandidateRequest(request, env, { fetchImpl });
    return json(result.body, result.status, { "cache-control": "no-store" });
  }

  const scannerConfiguration = parseLocalScannerConfiguration(env);
  if (scannerConfiguration.kind === "invalid") {
    return localScannerConfigurationError();
  }

  let upstreamRequest;
  if (scannerConfiguration.kind === "local") {
    const providedToken = request.headers.get("x-cheki-token") || "";
    if (!await timingSafeTokenEqual(scannerConfiguration.token, providedToken)) {
      return json({ ok: false, error: "Token 无效或已过期" }, 401);
    }
    upstreamRequest = await localUpstreamRequest(request, url, scannerConfiguration);
    if (!upstreamRequest) return localScannerRequestError();
  } else {
    const podId = normalizePodId(getRequestToken(request, url));
    if (!podId) {
      return json({ ok: false, error: "Token 无效或已过期" }, 401);
    }

    const upstreamUrl = new URL(request.url);
    upstreamUrl.protocol = "https:";
    upstreamUrl.hostname = `${podId}-${RUNPOD_HTTP_PORT}.proxy.runpod.net`;
    upstreamUrl.port = "";
    if (isCurrentResultPartPath(url.pathname)) {
      upstreamUrl.searchParams.delete(DATE_ANNOTATION_QUERY);
    }

    upstreamRequest = new Request(upstreamUrl.toString(), {
      method: request.method,
      headers: copyHeaders(request),
      body: request.body,
      redirect: "manual",
    });
  }

  try {
    const upstreamResponse = await fetchImpl(upstreamRequest);
    let annotation = null;
    if (dateAnnotationRequested) {
      try {
        annotation = await annotateChekiDateResponse(request, upstreamResponse, env, {
          fetchImpl,
        });
      } catch {
        annotation = { status: "unavailable", error: "internal_error" };
      }
    }
    const responseHeaders = new Headers(upstreamResponse.headers);
    responseHeaders.set("access-control-allow-origin", "*");
    responseHeaders.set("access-control-allow-methods", "GET,POST,OPTIONS");
    responseHeaders.set("access-control-allow-headers", "content-type,x-cheki-token");
    if (dateAnnotationRequested) applyDateAnnotationHeaders(responseHeaders, annotation);

    return new Response(upstreamResponse.body, {
      status: upstreamResponse.status,
      statusText: upstreamResponse.statusText,
      headers: responseHeaders,
    });
  } catch (error) {
    if (scannerConfiguration.kind === "local") {
      return json(
        { ok: false, error: LOCAL_SCANNER_UPSTREAM_ERROR },
        502,
        { "cache-control": "no-store" },
      );
    }
    return json({ ok: false, error: `RunPod proxy failed: ${error.message}` }, 502);
  }
}

export default {
  async fetch(request, env = {}) {
    return handleRequest(request, env);
  },
};
