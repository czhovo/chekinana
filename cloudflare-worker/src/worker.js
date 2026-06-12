const RUNPOD_HTTP_PORT = 8080;

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "access-control-allow-origin": "*",
      "access-control-allow-methods": "GET,POST,OPTIONS",
      "access-control-allow-headers": "content-type,x-cheki-token",
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

export default {
  async fetch(request) {
    const url = new URL(request.url);

    if (request.method === "OPTIONS") {
      return json({ ok: true });
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
      const upstreamResponse = await fetch(upstreamRequest);
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
  },
};
