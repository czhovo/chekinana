const X_MEDIA_ENDPOINT = "/api/event/x-media";
const X_MEDIA_PUBLIC_ORIGIN = "https://api.chekinana.top";
const X_MEDIA_SOURCE_HOST = "pbs.twimg.com";
const X_MEDIA_SOURCE_URL_MAX_CHARS = 2_048;
const X_MEDIA_MAX_BYTES = 12 * 1024 * 1024;
const X_MEDIA_TIMEOUT_MS = 8_000;
const X_MEDIA_MAX_REDIRECTS = 2;
const X_MEDIA_CACHE_CONTROL = "public, max-age=86400";
const X_MEDIA_CONTENT_TYPES = new Set([
  "image/avif",
  "image/gif",
  "image/jpeg",
  "image/png",
  "image/webp",
]);
const X_MEDIA_USER_AGENT = "Chekinana-Event-X-Media/1.0 (+https://chekinana.top)";

function normalizedXMediaSourceURL(value) {
  if (typeof value !== "string" || !value || value.length > X_MEDIA_SOURCE_URL_MAX_CHARS
    || value !== value.trim() || /[\u0000-\u001f\u007f\\]/u.test(value)) return "";
  try {
    const url = new URL(value);
    if (url.protocol !== "https:"
      || url.hostname.toLocaleLowerCase() !== X_MEDIA_SOURCE_HOST
      || url.username || url.password || url.port || url.hash
      || !url.pathname || url.pathname === "/") return "";
    url.hostname = X_MEDIA_SOURCE_HOST;
    const normalized = url.toString();
    return normalized.length <= X_MEDIA_SOURCE_URL_MAX_CHARS ? normalized : "";
  } catch {
    return "";
  }
}

function proxiedXMediaURL(value) {
  const sourceURL = normalizedXMediaSourceURL(value);
  if (!sourceURL) return "";
  const proxyURL = new URL(X_MEDIA_ENDPOINT, X_MEDIA_PUBLIC_ORIGIN);
  proxyURL.searchParams.set("url", sourceURL);
  return proxyURL.toString();
}

function mediaHeaders(contentType, byteLength) {
  return new Headers({
    "access-control-allow-origin": "*",
    "cache-control": X_MEDIA_CACHE_CONTROL,
    "content-length": String(byteLength),
    "content-type": contentType,
    "x-content-type-options": "nosniff",
  });
}

function mediaError(code, status) {
  return new Response(JSON.stringify({ version: 1, kind: "reject", code }), {
    status,
    headers: {
      "access-control-allow-origin": "*",
      "cache-control": "no-store",
      "content-type": "application/json; charset=utf-8",
      "x-content-type-options": "nosniff",
    },
  });
}

function timeoutPromise(signal) {
  return new Promise((_, reject) => {
    if (signal.aborted) {
      reject(new DOMException("Aborted", "AbortError"));
      return;
    }
    signal.addEventListener("abort", () => {
      reject(new DOMException("Aborted", "AbortError"));
    }, { once: true });
  });
}

function cancelWithoutWaiting(cancelable) {
  if (!cancelable || typeof cancelable.cancel !== "function") return;
  try {
    Promise.resolve(cancelable.cancel()).catch(() => {});
  } catch {
    // Best-effort cleanup must never delay or replace the public response.
  }
}

function deadlineExpired(signal, deadlineAt) {
  return signal.aborted || Date.now() >= deadlineAt;
}

async function readLimitedImage(response, signal, maximumBytes) {
  const length = response.headers.get("content-length");
  if (length !== null
    && (!/^\d+$/u.test(length.trim()) || Number(length) > maximumBytes)) {
    cancelWithoutWaiting(response.body);
    throw new RangeError("image response exceeds byte limit");
  }
  if (!response.body) return new Uint8Array();
  const reader = response.body.getReader();
  const aborted = timeoutPromise(signal);
  const chunks = [];
  let total = 0;
  try {
    while (true) {
      const result = await Promise.race([reader.read(), aborted]);
      if (result.done) break;
      if (!(result.value instanceof Uint8Array)) throw new TypeError("invalid image stream");
      total += result.value.byteLength;
      if (total > maximumBytes) throw new RangeError("image response exceeds byte limit");
      chunks.push(result.value);
    }
  } catch (error) {
    cancelWithoutWaiting(reader);
    throw error;
  } finally {
    try { reader.releaseLock(); } catch { /* Best effort. */ }
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}

function parsedMediaRequestURL(request) {
  let url;
  try {
    url = new URL(request.url);
  } catch {
    return null;
  }
  if (url.pathname !== X_MEDIA_ENDPOINT || url.hash
    || [...url.searchParams.keys()].some((key) => key !== "url")
    || url.searchParams.getAll("url").length !== 1) return null;
  const sourceURL = normalizedXMediaSourceURL(url.searchParams.get("url"));
  if (!sourceURL) return null;
  return { requestURL: proxiedXMediaURL(sourceURL), sourceURL };
}

async function cachedResponse(cache, cacheKey) {
  if (!cache || typeof cache.match !== "function") return null;
  try {
    const response = await cache.match(cacheKey);
    return response instanceof Response ? response : null;
  } catch {
    return null;
  }
}

async function storeCachedResponse(cache, cacheKey, response, waitUntil) {
  if (!cache || typeof cache.put !== "function") return;
  const operation = Promise.resolve()
    .then(() => cache.put(cacheKey, response))
    .catch(() => {});
  if (typeof waitUntil === "function") {
    try {
      waitUntil(operation);
      return;
    } catch {
      // Fall through and await the best-effort cache write.
    }
  }
  await operation;
}

async function proxyXMediaRequest(request, options = {}) {
  if (request.method !== "GET") return mediaError("method_not_allowed", 405);
  const parsed = parsedMediaRequestURL(request);
  if (!parsed) return mediaError("invalid_x_media_url", 400);

  const cache = options.cache ?? globalThis.caches?.default ?? null;
  const cacheKey = new Request(parsed.requestURL, { method: "GET" });
  const hit = await cachedResponse(cache, cacheKey);
  if (hit) return hit;

  const controller = new AbortController();
  const timeoutMs = Number.isFinite(options.timeoutMs) && options.timeoutMs >= 1
    ? options.timeoutMs
    : X_MEDIA_TIMEOUT_MS;
  const maximumBytes = Number.isFinite(options.maximumBytes) && options.maximumBytes >= 1
    ? options.maximumBytes
    : X_MEDIA_MAX_BYTES;
  const deadlineAt = Date.now() + timeoutMs;
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  const fetchImpl = options.fetchImpl ?? fetch;
  let current = new URL(parsed.sourceURL);
  let upstream = null;
  try {
    for (let redirectCount = 0; redirectCount <= X_MEDIA_MAX_REDIRECTS; redirectCount += 1) {
      if (deadlineExpired(controller.signal, deadlineAt)) {
        return mediaError("x_media_upstream_timeout", 504);
      }
      const normalizedCurrent = normalizedXMediaSourceURL(current.toString());
      if (!normalizedCurrent) return mediaError("invalid_x_media_response", 502);
      if (deadlineExpired(controller.signal, deadlineAt)) {
        return mediaError("x_media_upstream_timeout", 504);
      }
      upstream = await Promise.race([
        Promise.resolve().then(() => fetchImpl(normalizedCurrent, {
          method: "GET",
          headers: new Headers({
            accept: "image/avif,image/webp,image/png,image/jpeg,image/gif",
            "user-agent": X_MEDIA_USER_AGENT,
          }),
          redirect: "manual",
          cache: "no-store",
          signal: controller.signal,
        })),
        timeoutPromise(controller.signal),
      ]);
      if (deadlineExpired(controller.signal, deadlineAt)) {
        cancelWithoutWaiting(upstream?.body);
        return mediaError("x_media_upstream_timeout", 504);
      }
      if (!(upstream instanceof Response)) {
        return mediaError("x_media_upstream_unavailable", 502);
      }
      if ([301, 302, 303, 307, 308].includes(upstream.status)) {
        const location = upstream.headers.get("location");
        cancelWithoutWaiting(upstream.body);
        if (!location || redirectCount === X_MEDIA_MAX_REDIRECTS) {
          return mediaError("invalid_x_media_response", 502);
        }
        try {
          current = new URL(location, current);
        } catch {
          return mediaError("invalid_x_media_response", 502);
        }
        if (deadlineExpired(controller.signal, deadlineAt)) {
          return mediaError("x_media_upstream_timeout", 504);
        }
        continue;
      }
      break;
    }
    if (!(upstream instanceof Response) || !upstream.ok) {
      cancelWithoutWaiting(upstream?.body);
      return mediaError("x_media_upstream_unavailable", 502);
    }
    const contentType = (upstream.headers.get("content-type") || "")
      .split(";", 1)[0]
      .trim()
      .toLocaleLowerCase();
    if (!X_MEDIA_CONTENT_TYPES.has(contentType)) {
      cancelWithoutWaiting(upstream.body);
      return mediaError("invalid_x_media_response", 502);
    }
    if (deadlineExpired(controller.signal, deadlineAt)) {
      cancelWithoutWaiting(upstream.body);
      return mediaError("x_media_upstream_timeout", 504);
    }
    const bytes = await readLimitedImage(upstream, controller.signal, maximumBytes);
    if (deadlineExpired(controller.signal, deadlineAt)) {
      return mediaError("x_media_upstream_timeout", 504);
    }
    if (bytes.byteLength === 0) return mediaError("invalid_x_media_response", 502);
    const response = new Response(bytes, {
      status: 200,
      headers: mediaHeaders(contentType, bytes.byteLength),
    });
    await storeCachedResponse(cache, cacheKey, response.clone(), options.waitUntil);
    return response;
  } catch (error) {
    if (controller.signal.aborted || error?.name === "AbortError") {
      return mediaError("x_media_upstream_timeout", 504);
    }
    if (error instanceof RangeError || error instanceof TypeError) {
      return mediaError("invalid_x_media_response", 502);
    }
    return mediaError("x_media_upstream_unavailable", 502);
  } finally {
    clearTimeout(timer);
  }
}

export {
  X_MEDIA_ENDPOINT,
  X_MEDIA_MAX_BYTES,
  normalizedXMediaSourceURL,
  proxiedXMediaURL,
  proxyXMediaRequest,
};
