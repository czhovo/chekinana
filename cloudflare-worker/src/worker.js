import { interpretNaturalLanguage } from "./nl-interpreter.js";
import {
  EVENT_ENDPOINT,
  extractWeiboCandidateRequest,
} from "./event-weibo-extractor.js";
import {
  annotateChekiDateImageRequest,
  annotateChekiDateResponse,
} from "./cheki-date-annotator.js";
import { ScannerRuntime } from "./scanner-runtime.js";

export { ScannerRuntime };

const LOCAL_SCANNER_MODE = "CHEKINANA_SCANNER_LOCAL_MODE";
const LOCAL_SCANNER_UPSTREAM = "CHEKINANA_SCANNER_LOCAL_UPSTREAM";
const LOCAL_SCANNER_TOKEN = "CHEKINANA_SCANNER_LOCAL_TOKEN";
const LOCAL_SCANNER_CONFIGURATION_ERROR = "local_scanner_configuration_invalid";
const LOCAL_SCANNER_REQUEST_ERROR = "local_scanner_request_invalid";
const LOCAL_SCANNER_UPSTREAM_ERROR = "local_scanner_upstream_unavailable";
const PRODUCTION_SCANNER_UPSTREAM_ERROR = "scanner_upstream_unavailable";
const PRODUCTION_SCANNER_RUNTIME_ERROR = "scanner_runtime_unavailable";
const PRODUCTION_SCANNER_RUNTIME_MESSAGE = "暂时无法读取 RunPod 后端状态，请重试。";
const RUNTIME_STATUS_DEADLINE_MS = 16_000;
const RUNTIME_START_DEADLINE_MS = 45_000;
const RUNTIME_STOP_DEADLINE_MS = 20_000;
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
const DATE_ANNOTATION_ENDPOINT = "/api/cheki/date-annotation";
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
  headers.delete("expect");
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
    signal: request.signal,
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

function isScannerRuntimePath(pathname) {
  return pathname === "/api/scanner/runtime"
    || pathname === "/api/scanner/runtime/start"
    || pathname === "/api/scanner/runtime/stop";
}

function localRuntimeResponse(request, url) {
  const isStatus = url.pathname === "/api/scanner/runtime";
  const validMethod = isStatus ? request.method === "GET" : request.method === "POST";
  if (!validMethod) {
    return json(
      { ok: false, error: "method_not_allowed" },
      405,
      { "cache-control": "no-store" },
    );
  }
  if (url.pathname === "/api/scanner/runtime/stop") {
    return json({
      ok: false,
      state: "ready",
      phase: "ready",
      message: "本地 Scanner 进程需要在 Windows 主机上手动关闭。",
      retryAllowed: false,
      canStart: false,
      canTerminate: false,
      updatedAt: null,
      error: "local_scanner_stop_unavailable",
    }, 409, { "cache-control": "no-store" });
  }
  return json({
    ok: true,
    state: "ready",
    phase: "ready",
    message: null,
    retryAllowed: true,
    canStart: false,
    canTerminate: false,
    updatedAt: null,
  }, 200, { "cache-control": "no-store" });
}

function scannerRuntimeStub(env) {
  const binding = env?.SCANNER_RUNTIME;
  if (!binding || typeof binding.idFromName !== "function"
    || typeof binding.get !== "function") return null;
  return binding.get(binding.idFromName("production"));
}

function runtimeControlDeadline(request, env) {
  const testValue = env?.__TEST_SCANNER_RUNTIME_CONTROL_DEADLINE_MS;
  if (Number.isFinite(testValue) && testValue >= 1 && testValue <= 60_000) {
    return testValue;
  }
  const pathname = new URL(request.url).pathname;
  if (pathname === "/api/scanner/runtime/start") return RUNTIME_START_DEADLINE_MS;
  if (pathname === "/api/scanner/runtime/stop") return RUNTIME_STOP_DEADLINE_MS;
  return RUNTIME_STATUS_DEADLINE_MS;
}

function runtimeControlFailure(request) {
  const url = new URL(request.url);
  const isStatus = request.method === "GET"
    && url.pathname === "/api/scanner/runtime";
  return json({
    ok: true,
    state: "closed",
    phase: "closed",
    message: PRODUCTION_SCANNER_RUNTIME_MESSAGE,
    retryAllowed: true,
    canStart: false,
    canTerminate: false,
    updatedAt: null,
  }, isStatus ? 200 : 503, { "cache-control": "no-store" });
}

async function productionRuntimeControlRequest(request, env) {
  const stub = scannerRuntimeStub(env);
  if (!stub || typeof stub.fetch !== "function") {
    return runtimeControlFailure(request);
  }
  const timeoutSentinel = Symbol("scanner-runtime-control-timeout");
  let timeout;
  try {
    const deadline = new Promise((resolve) => {
      timeout = setTimeout(
        () => resolve(timeoutSentinel),
        runtimeControlDeadline(request, env),
      );
    });
    const operation = Promise.resolve().then(() => stub.fetch(request)).then(
      (response) => ({ response }),
      () => ({ response: null }),
    );
    const outcome = await Promise.race([operation, deadline]);
    if (outcome === timeoutSentinel || !(outcome?.response instanceof Response)) {
      return runtimeControlFailure(request);
    }
    return outcome.response;
  } finally {
    clearTimeout(timeout);
  }
}

async function productionRuntimeRequest(request, env) {
  const stub = scannerRuntimeStub(env);
  if (!stub || typeof stub.fetch !== "function") {
    return json(
      { ok: false, error: PRODUCTION_SCANNER_RUNTIME_ERROR },
      503,
      { "cache-control": "no-store" },
    );
  }
  try {
    return await stub.fetch(request);
  } catch {
    return json(
      { ok: false, error: PRODUCTION_SCANNER_RUNTIME_ERROR },
      503,
      { "cache-control": "no-store" },
    );
  }
}

export async function handleRequest(request, env = {}, fetchImpl = fetch) {
  const url = new URL(request.url);
  const dateAnnotationRequested = requestsDateAnnotation(request, url);

  if (request.method === "OPTIONS") {
    const headers = (url.pathname === "/api/nl/interpret"
      || url.pathname === EVENT_ENDPOINT
      || url.pathname === DATE_ANNOTATION_ENDPOINT)
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

  if (url.pathname === DATE_ANNOTATION_ENDPOINT) {
    if (request.method !== "POST") {
      return json(
        { status: "unavailable", error: "method_not_allowed" },
        405,
        { "cache-control": "no-store" },
      );
    }
    const annotation = await annotateChekiDateImageRequest(request, env, {
      fetchImpl,
      imageReadTimeoutMs: env?.__TEST_CHEKI_DATE_IMAGE_TIMEOUT_MS,
      qwenTimeoutMs: env?.__TEST_CHEKI_DATE_QWEN_TIMEOUT_MS,
    });
    return json(annotation, 200, { "cache-control": "no-store" });
  }

  const scannerConfiguration = parseLocalScannerConfiguration(env);
  if (scannerConfiguration.kind === "invalid") {
    return localScannerConfigurationError();
  }

  if (isScannerRuntimePath(url.pathname)) {
    const runtimeResponse = scannerConfiguration.kind === "local"
      ? localRuntimeResponse(request, url)
      : await productionRuntimeControlRequest(request, env);
    if (runtimeResponse.status === 101) return runtimeResponse;
    const runtimeHeaders = new Headers(runtimeResponse.headers);
    runtimeHeaders.set("access-control-allow-origin", "*");
    runtimeHeaders.set("access-control-allow-methods", "GET,POST,OPTIONS");
    runtimeHeaders.set("access-control-allow-headers", "content-type,x-cheki-token");
    runtimeHeaders.set("cache-control", "no-store");
    return new Response(runtimeResponse.body, {
      status: runtimeResponse.status,
      statusText: runtimeResponse.statusText,
      headers: runtimeHeaders,
    });
  }

  let upstreamRequest;
  let upstreamResponse;
  if (scannerConfiguration.kind === "local") {
    const providedToken = request.headers.get("x-cheki-token") || "";
    if (!await timingSafeTokenEqual(scannerConfiguration.token, providedToken)) {
      return json({ ok: false, error: "Token 无效或已过期" }, 401);
    }
    upstreamRequest = await localUpstreamRequest(request, url, scannerConfiguration);
    if (!upstreamRequest) return localScannerRequestError();
  } else {
    upstreamResponse = await productionRuntimeRequest(request, env);
  }

  try {
    if (!upstreamResponse) upstreamResponse = await fetchImpl(upstreamRequest);
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
  } catch {
    if (scannerConfiguration.kind === "local") {
      return json(
        { ok: false, error: LOCAL_SCANNER_UPSTREAM_ERROR },
        502,
        { "cache-control": "no-store" },
      );
    }
    return json(
      { ok: false, error: PRODUCTION_SCANNER_UPSTREAM_ERROR },
      502,
      { "cache-control": "no-store" },
    );
  }
}

export default {
  async fetch(request, env = {}) {
    return handleRequest(request, env);
  },
};
