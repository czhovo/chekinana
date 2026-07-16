import { interpretNaturalLanguage } from "./nl-interpreter.js";
import {
  EVENT_ENDPOINT,
  extractWeiboCandidateRequest,
} from "./event-weibo-extractor.js";

const RUNPOD_HTTP_PORT = 8080;

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

export async function handleRequest(request, env = {}, fetchImpl = fetch) {
  const url = new URL(request.url);

  if (request.method === "OPTIONS") {
    const headers = (url.pathname === "/api/nl/interpret" || url.pathname === EVENT_ENDPOINT)
      ? { "cache-control": "no-store" }
      : {};
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

  const podId = normalizePodId(getRequestToken(request, url));
  if (!podId) {
    return json({ ok: false, error: "Token 无效或已过期" }, 401);
  }

  const upstreamUrl = new URL(request.url);
  upstreamUrl.protocol = "https:";
  upstreamUrl.hostname = `${podId}-${RUNPOD_HTTP_PORT}.proxy.runpod.net`;
  upstreamUrl.port = "";

  const upstreamRequest = new Request(upstreamUrl.toString(), {
    method: request.method,
    headers: copyHeaders(request),
    body: request.body,
    redirect: "manual",
  });

  try {
    const upstreamResponse = await fetchImpl(upstreamRequest);
    const responseHeaders = new Headers(upstreamResponse.headers);
    responseHeaders.set("access-control-allow-origin", "*");
    responseHeaders.set("access-control-allow-methods", "GET,POST,OPTIONS");
    responseHeaders.set("access-control-allow-headers", "content-type,x-cheki-token");

    return new Response(upstreamResponse.body, {
      status: upstreamResponse.status,
      statusText: upstreamResponse.statusText,
      headers: responseHeaders,
    });
  } catch (error) {
    return json({ ok: false, error: `RunPod proxy failed: ${error.message}` }, 502);
  }
}

export default {
  async fetch(request, env = {}) {
    return handleRequest(request, env);
  },
};
