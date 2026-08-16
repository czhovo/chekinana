import { CHEKI_DATE_PROMPT } from "./cheki-date-prompt.js";

const DEFAULT_MODEL = "qwen3.7-plus";
const DEFAULT_IMAGE_READ_TIMEOUT_MS = 10_000;
const DEFAULT_QWEN_TIMEOUT_MS = 90_000;
const MAX_IMAGE_BYTES = 16 * 1024 * 1024;
const MAX_MODEL_RESPONSE_BYTES = 32_768;
const MAX_MODEL_NAME_CHARS = 200;
const MAX_SECRET_CHARS = 4_096;
const MIN_IMAGE_PIXELS = 65_536;
const MAX_IMAGE_PIXELS = 2_621_440;
const SUPPORTED_IMAGE_TYPES = new Set(["image/jpeg", "image/png", "image/webp"]);

function unavailable(error) {
  return { status: "unavailable", error };
}

function requestMediaType(headers) {
  return (headers.get("content-type") || "")
    .split(";", 1)[0].trim().toLowerCase();
}

function declaredImageLengthError(headers) {
  const declaredLength = headers.get("content-length");
  if (declaredLength === null) return null;
  const normalized = declaredLength.trim();
  if (!/^\d+$/u.test(normalized) || Number(normalized) <= 0) {
    return "image_read_failed";
  }
  return Number(normalized) > MAX_IMAGE_BYTES ? "image_too_large" : null;
}

function normalizeString(value, maximum) {
  if (typeof value !== "string") return null;
  const normalized = value.trim();
  if (!normalized || normalized.length > maximum) return null;
  return normalized;
}

function qwenEndpoint(env) {
  const raw = normalizeString(env?.CHEKI_DATE_QWEN_BASE_URL, 4_096);
  if (!raw) return null;
  try {
    const base = new URL(raw);
    if (base.protocol !== "https:" || base.username || base.password
      || base.search || base.hash) return null;
    const normalizedPath = base.pathname.replace(/\/+$/u, "");
    base.pathname = `${normalizedPath}/chat/completions`;
    return base.toString();
  } catch {
    return null;
  }
}

function qwenConfiguration(env) {
  const apiKey = normalizeString(env?.CHEKI_DATE_QWEN_API_KEY, MAX_SECRET_CHARS);
  const endpoint = qwenEndpoint(env);
  const model = normalizeString(
    env?.CHEKI_DATE_QWEN_MODEL || DEFAULT_MODEL,
    MAX_MODEL_NAME_CHARS,
  );
  return apiKey && endpoint && model ? { apiKey, endpoint, model } : null;
}

function cancelReader(reader, reason) {
  if (!reader) return;
  try {
    const cancellation = reader.cancel(reason);
    if (cancellation && typeof cancellation.catch === "function") {
      cancellation.catch(() => {});
    }
  } catch {
    // Best effort after a stream has already failed or detached.
  }
}

function cancelResponseBody(response, reason) {
  if (!response?.body || typeof response.body.cancel !== "function") return;
  try {
    const cancellation = response.body.cancel(reason);
    if (cancellation && typeof cancellation.catch === "function") {
      cancellation.catch(() => {});
    }
  } catch {
    // Best effort after a stream has already failed or detached.
  }
}

async function readLimitedBytes(response, maximum, timeoutMs) {
  if (!response.body || typeof response.body.getReader !== "function") {
    return { kind: "invalid" };
  }
  let reader;
  try {
    reader = response.body.getReader();
  } catch {
    return { kind: "invalid" };
  }

  const timeoutSentinel = Symbol("timeout");
  let timer;
  const timeoutPromise = new Promise((resolve) => {
    timer = setTimeout(() => resolve(timeoutSentinel), timeoutMs);
  });
  const chunks = [];
  let totalBytes = 0;
  try {
    while (true) {
      const readPromise = Promise.resolve().then(() => reader.read()).then(
        (result) => ({ kind: "read", result }),
        () => ({ kind: "invalid" }),
      );
      const outcome = await Promise.race([readPromise, timeoutPromise]);
      if (outcome === timeoutSentinel) {
        cancelReader(reader, "image read deadline exceeded");
        return { kind: "timeout" };
      }
      if (outcome.kind !== "read" || !outcome.result
        || typeof outcome.result.done !== "boolean") {
        cancelReader(reader, "invalid image body");
        return { kind: "invalid" };
      }
      if (outcome.result.done) break;
      const chunk = outcome.result.value;
      if (!(chunk instanceof Uint8Array)) {
        cancelReader(reader, "invalid image chunk");
        return { kind: "invalid" };
      }
      totalBytes += chunk.byteLength;
      if (totalBytes > maximum) {
        cancelReader(reader, "image body too large");
        return { kind: "too_large" };
      }
      chunks.push(chunk);
    }

    if (totalBytes === 0) return { kind: "invalid" };
    const bytes = new Uint8Array(totalBytes);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.byteLength;
    }
    return { kind: "ok", bytes };
  } finally {
    clearTimeout(timer);
    try {
      reader.releaseLock();
    } catch {
      // A cancelled stream may already be detached.
    }
  }
}

function bytesToBase64(bytes) {
  // Encode independent 24 KiB blocks. The block size is divisible by three,
  // so padding is emitted only for the final block. This avoids retaining a
  // second full-size binary string before btoa builds the Base64 payload.
  const chunkSize = 3 * 0x2000;
  const parts = [];
  for (let offset = 0; offset < bytes.length; offset += chunkSize) {
    parts.push(btoa(String.fromCharCode(
      ...bytes.subarray(offset, offset + chunkSize),
    )));
  }
  return parts.join("");
}

function validCalendarDate(year, month, day) {
  if (!Number.isInteger(year) || !Number.isInteger(month) || !Number.isInteger(day)
    || year < 1 || year > 9_999 || month < 1 || month > 12 || day < 1) {
    return false;
  }
  const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  return day <= days[month - 1];
}

function normalizeDateText(value) {
  if (typeof value !== "string") return null;
  const fullDate = /^(\d{4})\.(\d{2})\.(\d{2})$/u.exec(value);
  if (fullDate) {
    const [year, month, day] = fullDate.slice(1).map(Number);
    return validCalendarDate(year, month, day)
      ? { text: value, precision: "full_date" }
      : null;
  }
  const monthDay = /^(\d{2})\.(\d{2})$/u.exec(value);
  if (monthDay) {
    const [month, day] = monthDay.slice(1).map(Number);
    return validCalendarDate(2_000, month, day)
      ? { text: value, precision: "month_day" }
      : null;
  }
  return null;
}

function isPlainObject(value) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

export function normalizeQwenDateOutput(value) {
  if (!isPlainObject(value)) return null;
  const keys = Object.keys(value);
  if (keys.length !== 2 || !keys.includes("reasoning") || !keys.includes("Date")
    || typeof value.reasoning !== "string") return null;
  if (value.Date === null) return { status: "not_detected" };
  if (!isPlainObject(value.Date)) return null;
  const dateKeys = Object.keys(value.Date);
  if (dateKeys.length !== 2 || !dateKeys.includes("bbox") || !dateKeys.includes("text")) {
    return null;
  }

  const bbox = value.Date.bbox;
  if (!Array.isArray(bbox) || bbox.length !== 4
    || bbox.some((coordinate) => !Number.isInteger(coordinate))) return null;
  const [x1, y1, x2, y2] = bbox;
  if (!(0 <= x1 && x1 < x2 && x2 <= 1_000
    && 0 <= y1 && y1 < y2 && y2 <= 1_000)) return null;
  const date = normalizeDateText(value.Date.text);
  if (!date) return null;
  return {
    status: "detected",
    text: date.text,
    precision: date.precision,
    bbox: [...bbox],
  };
}

async function readLimitedModelText(
  response,
  deadlinePromise,
  timeoutSentinel,
  controller,
) {
  if (!response.body || typeof response.body.getReader !== "function") {
    return { kind: "invalid" };
  }
  let reader;
  try {
    reader = response.body.getReader();
  } catch {
    return { kind: "invalid" };
  }

  const chunks = [];
  let totalBytes = 0;
  try {
    while (true) {
      const readPromise = Promise.resolve().then(() => reader.read()).then(
        (result) => ({ kind: "read", result }),
        () => ({ kind: "invalid" }),
      );
      const outcome = await Promise.race([readPromise, deadlinePromise]);
      if (outcome === timeoutSentinel) {
        controller.abort();
        cancelReader(reader, "Qwen deadline exceeded");
        return { kind: "timeout" };
      }
      if (outcome.kind !== "read" || !outcome.result
        || typeof outcome.result.done !== "boolean") {
        controller.abort();
        cancelReader(reader, "invalid Qwen response body");
        return { kind: "invalid" };
      }
      if (outcome.result.done) break;
      const chunk = outcome.result.value;
      if (!(chunk instanceof Uint8Array)) {
        controller.abort();
        cancelReader(reader, "invalid Qwen response chunk");
        return { kind: "invalid" };
      }
      totalBytes += chunk.byteLength;
      if (totalBytes > MAX_MODEL_RESPONSE_BYTES) {
        controller.abort();
        cancelReader(reader, "Qwen response body too large");
        return { kind: "too_large" };
      }
      chunks.push(chunk);
    }

    const bytes = new Uint8Array(totalBytes);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.byteLength;
    }
    try {
      return {
        kind: "ok",
        text: new TextDecoder("utf-8", { fatal: true }).decode(bytes),
      };
    } catch {
      return { kind: "invalid" };
    }
  } finally {
    try {
      reader.releaseLock();
    } catch {
      // A cancelled stream may already be detached.
    }
  }
}

async function callQwen(
  bytes,
  mediaType,
  configuration,
  fetchImpl,
  timeoutMs,
  requestSignal = null,
) {
  const controller = new AbortController();
  const timeoutSentinel = Symbol("timeout");
  let timer;
  const deadlinePromise = new Promise((resolve) => {
    timer = setTimeout(() => {
      controller.abort();
      resolve(timeoutSentinel);
    }, timeoutMs);
  });
  const dataURL = `data:${mediaType};base64,${bytesToBase64(bytes)}`;
  const body = JSON.stringify({
    model: configuration.model,
    messages: [
      { role: "system", content: CHEKI_DATE_PROMPT },
      {
        role: "user",
        content: [
          {
            type: "image_url",
            image_url: { url: dataURL },
            min_pixels: MIN_IMAGE_PIXELS,
            max_pixels: MAX_IMAGE_PIXELS,
          },
        ],
      },
    ],
    max_tokens: 1_024,
    stream: false,
    enable_thinking: false,
  });
  const abortUpstream = () => controller.abort(requestSignal?.reason);
  requestSignal?.addEventListener("abort", abortUpstream, { once: true });
  if (requestSignal?.aborted) controller.abort(requestSignal.reason);

  try {
    const fetchPromise = Promise.resolve().then(() => fetchImpl(configuration.endpoint, {
      method: "POST",
      headers: {
        authorization: `Bearer ${configuration.apiKey}`,
        "content-type": "application/json",
      },
      body,
      redirect: "manual",
      signal: controller.signal,
    })).then((response) => ({ response }), () => ({ error: true }));
    const outcome = await Promise.race([fetchPromise, deadlinePromise]);
    if (outcome === timeoutSentinel) return unavailable("qwen_timeout");
    if (outcome.error || !outcome.response) {
      controller.abort();
      return unavailable("qwen_unavailable");
    }
    if (outcome.response.status !== 200) {
      controller.abort();
      cancelResponseBody(outcome.response, "Qwen HTTP error");
      return unavailable("qwen_unavailable");
    }

    const bodyResult = await readLimitedModelText(
      outcome.response,
      deadlinePromise,
      timeoutSentinel,
      controller,
    );
    if (bodyResult.kind === "timeout") return unavailable("qwen_timeout");
    if (bodyResult.kind !== "ok") return unavailable("invalid_model_output");

    try {
      const envelope = JSON.parse(bodyResult.text);
      const content = envelope?.choices?.[0]?.message?.content;
      if (typeof content !== "string" || content.length > MAX_MODEL_RESPONSE_BYTES) {
        return unavailable("invalid_model_output");
      }
      const candidate = JSON.parse(content);
      return normalizeQwenDateOutput(candidate)
        ?? unavailable("invalid_model_output");
    } catch {
      return unavailable("invalid_model_output");
    }
  } finally {
    clearTimeout(timer);
    requestSignal?.removeEventListener("abort", abortUpstream);
  }
}

export async function annotateChekiDateResponse(
  request,
  upstreamResponse,
  env = {},
  options = {},
) {
  if (upstreamResponse.status !== 200) {
    return unavailable("image_unavailable");
  }
  const mediaType = requestMediaType(upstreamResponse.headers);
  if (!SUPPORTED_IMAGE_TYPES.has(mediaType)) {
    return unavailable("unsupported_image_type");
  }

  const declaredLengthError = declaredImageLengthError(upstreamResponse.headers);
  if (declaredLengthError) return unavailable(declaredLengthError);

  const configuration = qwenConfiguration(env);
  if (!configuration) return unavailable("service_unavailable");

  let annotationResponse;
  try {
    annotationResponse = upstreamResponse.clone();
  } catch {
    return unavailable("image_read_failed");
  }
  const requestedImageTimeout = options.imageReadTimeoutMs;
  const imageReadTimeoutMs = Number.isFinite(requestedImageTimeout)
    && requestedImageTimeout > 0
    ? requestedImageTimeout
    : DEFAULT_IMAGE_READ_TIMEOUT_MS;
  const imageResult = await readLimitedBytes(
    annotationResponse,
    MAX_IMAGE_BYTES,
    imageReadTimeoutMs,
  );
  if (imageResult.kind === "too_large") return unavailable("image_too_large");
  if (imageResult.kind === "timeout") return unavailable("image_read_timeout");
  if (imageResult.kind !== "ok") return unavailable("image_read_failed");

  const requestedQwenTimeout = options.qwenTimeoutMs;
  const qwenTimeoutMs = Number.isFinite(requestedQwenTimeout)
    && requestedQwenTimeout > 0
    ? requestedQwenTimeout
    : DEFAULT_QWEN_TIMEOUT_MS;
  return callQwen(
    imageResult.bytes,
    mediaType,
    configuration,
    options.fetchImpl || fetch,
    qwenTimeoutMs,
    request.signal,
  );
}

export async function annotateChekiDateImageRequest(
  request,
  env = {},
  options = {},
) {
  const mediaType = requestMediaType(request.headers);
  if (!SUPPORTED_IMAGE_TYPES.has(mediaType)) {
    return unavailable("unsupported_image_type");
  }
  const declaredLengthError = declaredImageLengthError(request.headers);
  if (declaredLengthError) return unavailable(declaredLengthError);

  const configuration = qwenConfiguration(env);
  if (!configuration) return unavailable("service_unavailable");
  const requestedImageTimeout = options.imageReadTimeoutMs;
  const imageReadTimeoutMs = Number.isFinite(requestedImageTimeout)
    && requestedImageTimeout > 0
    ? requestedImageTimeout
    : DEFAULT_IMAGE_READ_TIMEOUT_MS;
  const imageResult = await readLimitedBytes(
    request,
    MAX_IMAGE_BYTES,
    imageReadTimeoutMs,
  );
  if (imageResult.kind === "too_large") return unavailable("image_too_large");
  if (imageResult.kind === "timeout") return unavailable("image_read_timeout");
  if (imageResult.kind !== "ok") return unavailable("image_read_failed");

  const requestedQwenTimeout = options.qwenTimeoutMs;
  const qwenTimeoutMs = Number.isFinite(requestedQwenTimeout)
    && requestedQwenTimeout > 0
    ? requestedQwenTimeout
    : DEFAULT_QWEN_TIMEOUT_MS;
  return callQwen(
    imageResult.bytes,
    mediaType,
    configuration,
    options.fetchImpl || fetch,
    qwenTimeoutMs,
    request.signal,
  );
}

export const CHEKI_DATE_MAX_IMAGE_BYTES = MAX_IMAGE_BYTES;
export const CHEKI_DATE_QWEN_TIMEOUT_MS = DEFAULT_QWEN_TIMEOUT_MS;
