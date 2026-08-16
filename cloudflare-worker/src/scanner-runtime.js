const STATE_KEY = "scanner-runtime-v1";
const RUNPOD_REST_ORIGIN = "https://rest.runpod.io/v1";
const RUNPOD_HTTP_PORT = 8080;
const IDLE_TIMEOUT_MS = 4 * 60 * 1000;
const EXPLICIT_STOP_DELAY_MS = 20 * 1000;
const ACTIVE_RECHECK_MS = 60 * 1000;
const START_RECHECK_MS = 10 * 1000;
const START_EXIT_GRACE_MS = 2 * 60 * 1000;
const STARTUP_DEADLINE_MS = 15 * 60 * 1000;
const IN_FLIGHT_LEASE_MS = 30 * 60 * 1000;
const CANCELED_TASK_TTL_MS = 30 * 60 * 1000;
const RUNPOD_TIMEOUT_MS = 8 * 1000;
const HEALTH_TIMEOUT_MS = 6 * 1000;
const MAX_RESPONSE_BYTES = 256 * 1024;
const DEFAULT_ACTIVE_TASK_CHECK_CONCURRENCY = 4;
const MAX_ACTIVE_TASK_CHECK_CONCURRENCY = 8;
const SLOW_PROXY_TIMING_MS = 250;
const STARTUP_PROGRESS_TOTAL = 3;
const TIMING_FIELD_NAMES = new Set([
  "kind",
  "status",
  "admission_ms",
  "upstream_ms",
  "adapt_ms",
  "total_ms",
  "jobs",
  "concurrency",
]);
const TASK_ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/u;
const POD_ID_PATTERN = /^[A-Za-z0-9]+$/u;
const CONFIGURATION_ID_PATTERN = /^[A-Za-z0-9_-]{3,128}$/u;
const TEMPORARY_POD_NAME_PATTERN = /^chekinana-scanner-temporary-[a-f0-9]{32}$/u;
const STARTUP_SOCKET_TAG = "scanner-runtime-startup";
const TERMINAL_TASK_STATES = new Set([
  "done",
  "succeeded",
  "failed",
  "canceled",
  "cancelled",
]);
const CLIENT_ONLY_HEADERS = [
  "authorization",
  "cookie",
  "cf-connecting-ip",
  "cf-ipcountry",
  "cf-pseudo-ipv4",
  "cf-ray",
  "cf-visitor",
  "forwarded",
  "origin",
  "referer",
  "true-client-ip",
  "x-client-ip",
  "x-cluster-client-ip",
  "x-forwarded-for",
  "x-forwarded-host",
  "x-forwarded-port",
  "x-forwarded-proto",
  "x-cheki-token",
  "x-real-ip",
];
const BACKEND_CONFIGURATION_ERROR = "scanner_backend_configuration_invalid";
const BACKEND_RESPONSE_ERROR = "scanner_backend_invalid_response";
const BACKEND_REJECTED_ERROR = "scanner_backend_rejected";
const BACKEND_NOT_FOUND_ERROR = "scanner_task_not_found";
const BACKEND_ROUTE_ERROR = "scanner_route_unsupported";
const BACKEND_JOB_STATES = new Set(["queued", "running", "succeeded", "failed"]);

const POD_MISSING_MESSAGE = "未找到已配置的 RunPod Pod。请更新 Worker 的 RunPod Pod 配置。";
const POD_TERMINATED_MESSAGE = "已配置的 RunPod Pod 已被终止。请更新 Worker 的 RunPod Pod 配置。";
const STATUS_FAILURE_MESSAGE = "暂时无法确认 RunPod 后端状态，请重试。";
const RUNPOD_CONFIGURATION_MESSAGE = "Worker 的 RunPod 状态查询配置缺失，请检查服务端配置。";
const RUNPOD_AUTHORIZATION_MESSAGE = "RunPod 状态查询鉴权失败，请检查服务端 API Key。";
const RUNPOD_RATE_LIMIT_MESSAGE = "RunPod 状态查询暂时受到限流，请稍后重试。";
const RUNPOD_STATUS_TIMEOUT_MESSAGE = "RunPod 状态查询超时，请稍后重试。";
const RUNPOD_STATUS_UNAVAILABLE_MESSAGE = "RunPod 状态服务暂时不可用，请稍后重试。";
const RUNPOD_INVALID_RESPONSE_MESSAGE = "RunPod 状态响应无法识别，请检查服务端 API 合同。";
const BACKEND_PREPARING_MESSAGE = "RunPod 已运行，后端仍在准备。";
const START_FAILURE_MESSAGE = "RunPod 后端启动失败，请稍后重试。";
const TEMPORARY_CONFIGURATION_MESSAGE = "临时 RunPod 的模板或网络卷配置缺失，请检查 Worker 配置。";
const TEMPORARY_CREATE_FAILURE_MESSAGE = null;
const TEMPORARY_CORRELATION_FAILURE_MESSAGE = "临时 RunPod 恢复匹配不唯一，已停止自动控制。";
const TEMPORARY_EXITED_MESSAGE = "临时 RunPod 未能保持运行，请重试启动。";
const STARTUP_TIMEOUT_MESSAGE = "RunPod 后端启动等待超时，请重试。";
const STARTUP_DISCONNECTED_MESSAGE = "启动连接已断开，已停止继续启动 RunPod。";
const STOP_FAILURE_MESSAGE = "关闭 RunPod 后端失败，请稍后重试。";
const STOP_BUSY_MESSAGE = "扫描请求或任务仍在进行，完成后才能关闭后端。";
const STOP_DELAY_MESSAGE = "RunPod GPU 将在 20 秒后关闭。";

class RunPodError extends Error {
  constructor(code, publicMessage, status = null) {
    super(code);
    this.code = code;
    this.publicMessage = publicMessage;
    this.status = status;
  }
}

function normalizePodId(value) {
  const normalized = typeof value === "string" ? value.trim() : "";
  return POD_ID_PATTERN.test(normalized) ? normalized : "";
}

function positiveInteger(value) {
  return Number.isInteger(value) && value > 0 ? value : null;
}

function boundedPositiveInteger(value, fallback, maximum) {
  const parsed = Number.parseInt(String(value ?? "").trim(), 10);
  if (!Number.isInteger(parsed) || parsed < 1) return fallback;
  return Math.min(parsed, maximum);
}

function podGPUCount(pod) {
  return positiveInteger(pod?.gpuCount) || positiveInteger(pod?.gpu?.count);
}

function iso(now) {
  return new Date(now).toISOString();
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    },
  });
}

function fixedError(error, status = 503) {
  return json({ ok: false, error }, status);
}

function canceledStatusResponse(taskId) {
  return json({
    task_id: taskId,
    status: "canceled",
    results_count: 0,
    extraction_complete: true,
    results: [],
  });
}

function canceledResultResponse(taskId) {
  return json({ ok: false, error: "scanner_task_canceled", task_id: taskId }, 410);
}

function taskStatusFromBody(body) {
  if (typeof body?.status === "string") return body.status.toLowerCase();
  if (typeof body?.task?.status === "string") return body.task.status.toLowerCase();
  return "";
}

function safeObject(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : null;
}

function copyProxyHeaders(request, backendToken) {
  const headers = new Headers(request.headers);
  for (const name of CLIENT_ONLY_HEADERS) headers.delete(name);
  headers.delete("host");
  headers.delete("expect");
  headers.delete("content-length");
  headers.delete("token");
  headers.set("authorization", `Bearer ${backendToken}`);
  return headers;
}

function productionRoute(request) {
  const url = new URL(request.url);
  if (url.pathname === "/api/process") {
    return request.method === "POST"
      ? { kind: "process", pathname: "/v1/jobs" }
      : { error: fixedError("method_not_allowed", 405) };
  }
  const status = /^\/api\/status\/([A-Za-z0-9_-]{1,128})$/u.exec(url.pathname);
  if (status) {
    return request.method === "GET"
      ? {
        kind: "status",
        taskId: status[1],
        pathname: `/v1/jobs/${encodeURIComponent(status[1])}`,
      }
      : { error: fixedError("method_not_allowed", 405) };
  }
  const result = /^\/api\/result\/([A-Za-z0-9_-]{1,128})\/([1-9]\d*)$/u.exec(url.pathname);
  if (result) {
    return request.method === "GET"
      ? {
        kind: "result",
        taskId: result[1],
        resultId: result[2],
        pathname: `/v1/jobs/${encodeURIComponent(result[1])}/results/${result[2]}`,
      }
      : { error: fixedError("method_not_allowed", 405) };
  }
  const cancel = /^\/api\/cancel\/([A-Za-z0-9_-]{1,128})$/u.exec(url.pathname);
  if (cancel) {
    return request.method === "POST"
      ? { kind: "cancel", taskId: cancel[1] }
      : { error: fixedError("method_not_allowed", 405) };
  }
  return { error: fixedError(BACKEND_ROUTE_ERROR, 404) };
}

function productionUpstreamRequest(request, podId, backendToken, route) {
  const url = new URL(
    `https://${podId}-${RUNPOD_HTTP_PORT}.proxy.runpod.net${route.pathname}`,
  );
  return new Request(url.toString(), {
    method: request.method,
    headers: copyProxyHeaders(request, backendToken),
    body: request.body,
    ...(request.body ? { duplex: "half" } : {}),
    redirect: "manual",
    signal: request.signal,
  });
}

function adaptedJSON(body, status) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    },
  });
}

function upstreamJobId(body) {
  for (const value of [body?.job_id, body?.job, body?.id]) {
    if (typeof value === "string" && TASK_ID_PATTERN.test(value)) return value;
  }
  return "";
}

function validSourceImage(value) {
  return safeObject(value)
    && Number.isInteger(value.width)
    && value.width > 0
    && Number.isInteger(value.height)
    && value.height > 0;
}

function publicSourceImage(value) {
  return { width: value.width, height: value.height };
}

function validCoordinateSystem(value) {
  return safeObject(value)
    && value.space === "exif_transposed_original_pixels"
    && value.origin === "top_left"
    && value.x_axis === "right"
    && value.y_axis === "down"
    && Array.isArray(value.quad_order)
    && value.quad_order.length === 4
    && value.quad_order[0] === "top_left"
    && value.quad_order[1] === "top_right"
    && value.quad_order[2] === "bottom_right"
    && value.quad_order[3] === "bottom_left";
}

function publicCoordinateSystem(value) {
  return {
    space: value.space,
    origin: value.origin,
    x_axis: value.x_axis,
    y_axis: value.y_axis,
    quad_order: ["top_left", "top_right", "bottom_right", "bottom_left"],
  };
}

function validQuadrilateral(value, sourceImage) {
  return Array.isArray(value)
    && value.length === 4
    && value.every((point) => Array.isArray(point)
      && point.length === 2
      && point.every((coordinate) => Number.isFinite(coordinate))
      && point[0] >= 0
      && point[0] <= sourceImage.width
      && point[1] >= 0
      && point[1] <= sourceImage.height);
}

function publicResult(value, expectedIndex, sourceImage) {
  if (!safeObject(value)
    || !Number.isInteger(value.index)
    || value.index !== expectedIndex
    || typeof value.filename !== "string"
    || !value.filename.trim()
    || !validQuadrilateral(value.quadrilateral, sourceImage)) return null;
  return {
    id: String(value.index),
    type: "polaroid",
    label: value.filename,
    quadrilateral: value.quadrilateral.map((point) => [point[0], point[1]]),
  };
}

function publicStatusBody(body, taskId) {
  const upstreamStatus = typeof body?.status === "string"
    ? body.status.toLowerCase()
    : "";
  if (!BACKEND_JOB_STATES.has(upstreamStatus)) return null;
  const mappedStatus = {
    queued: "queued",
    running: "processing",
    succeeded: "done",
    failed: "failed",
  }[upstreamStatus];
  if (upstreamJobId(body) !== taskId) return null;
  let mappedResults = [];
  let resultCount = 0;
  let sourceImage = null;
  let coordinateSystem = null;
  if (upstreamStatus === "succeeded") {
    if (!validSourceImage(body.source_image)
      || !validCoordinateSystem(body.coordinate_system)
      || !Array.isArray(body.results)
      || !Number.isInteger(body.result_count)
      || body.result_count < 0
      || body.result_count !== body.results.length) return null;
    sourceImage = publicSourceImage(body.source_image);
    coordinateSystem = publicCoordinateSystem(body.coordinate_system);
    mappedResults = body.results.map((value, index) => publicResult(
      value,
      index + 1,
      sourceImage,
    ));
    if (mappedResults.some((item) => item === null)) return null;
    resultCount = mappedResults.length;
  }
  const result = {
    task_id: taskId,
    status: mappedStatus,
    results_count: resultCount,
    extraction_complete: upstreamStatus === "succeeded",
    results: mappedResults,
  };
  if (sourceImage) result.source_image = sourceImage;
  if (coordinateSystem) result.coordinate_system = coordinateSystem;
  return result;
}

async function discardResponseBody(response) {
  if (!response.body) return;
  try {
    await response.body.cancel("production upstream response discarded");
  } catch {
    // Best effort. The public response is fixed regardless of cancel support.
  }
}

function safeResultResponse(response) {
  const headers = new Headers({
    "content-type": "image/png",
    "cache-control": response.headers.get("cache-control") || "no-store",
  });
  const disposition = response.headers.get("content-disposition");
  if (disposition) headers.set("content-disposition", disposition);
  return new Response(response.body, { status: 200, headers });
}

async function adaptProductionResponse(route, response) {
  if (!response.ok) {
    await discardResponseBody(response);
    return {
      response: response.status === 404
        ? fixedError(BACKEND_NOT_FOUND_ERROR, 404)
        : fixedError(BACKEND_REJECTED_ERROR, 502),
      observation: response.status === 404 && route.kind === "status"
        ? { kind: "task_finished", taskId: route.taskId }
        : null,
    };
  }
  if (route.kind === "result") {
    const contentType = (response.headers.get("content-type") || "")
      .split(";", 1)[0]
      .trim()
      .toLowerCase();
    if (response.status !== 200 || contentType !== "image/png") {
      await discardResponseBody(response);
      return { response: fixedError(BACKEND_RESPONSE_ERROR, 502), observation: null };
    }
    return { response: safeResultResponse(response), observation: null };
  }
  const expectedStatus = route.kind === "process" ? 202 : 200;
  if (response.status !== expectedStatus) {
    await discardResponseBody(response);
    return { response: fixedError(BACKEND_RESPONSE_ERROR, 502), observation: null };
  }
  let body;
  try {
    body = await responseJSONBounded(response);
  } catch {
    return { response: fixedError(BACKEND_RESPONSE_ERROR, 502), observation: null };
  }
  if (route.kind === "process") {
    const taskId = upstreamJobId(body);
    const status = typeof body?.status === "string" ? body.status.toLowerCase() : "";
    if (!taskId || !["queued", "running"].includes(status)) {
      return { response: fixedError(BACKEND_RESPONSE_ERROR, 502), observation: null };
    }
    return {
      response: adaptedJSON({
        task_id: taskId,
        status: status === "running" ? "processing" : "queued",
      }, 202),
      observation: { kind: "task_started", taskId },
    };
  }
  const mapped = publicStatusBody(body, route.taskId);
  if (!mapped) {
    return { response: fixedError(BACKEND_RESPONSE_ERROR, 502), observation: null };
  }
  return {
    response: adaptedJSON(mapped, 200),
    observation: TERMINAL_TASK_STATES.has(mapped.status)
      ? { kind: "task_finished", taskId: route.taskId }
      : null,
  };
}

async function readBytesBounded(response, maximum = MAX_RESPONSE_BYTES) {
  if (!response.body) return new Uint8Array();
  const reader = response.body.getReader();
  const chunks = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!(value instanceof Uint8Array)) throw new TypeError("invalid response chunk");
      total += value.byteLength;
      if (total > maximum) {
        try { await reader.cancel("response too large"); } catch { /* Best effort. */ }
        throw new RangeError("response too large");
      }
      chunks.push(value);
    }
  } finally {
    try { reader.releaseLock(); } catch { /* Stream may be detached. */ }
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}

async function responseTextBounded(response, maximum = MAX_RESPONSE_BYTES) {
  return new TextDecoder("utf-8", { fatal: true }).decode(
    await readBytesBounded(response, maximum),
  );
}

async function responseJSONBounded(response, maximum = MAX_RESPONSE_BYTES) {
  return JSON.parse(await responseTextBounded(response, maximum));
}

function isExplicitPrimaryGPUCapacityFailure(status) {
  return status === 500;
}

function configurationId(value) {
  const normalized = typeof value === "string" ? value.trim() : "";
  return CONFIGURATION_ID_PATTERN.test(normalized) ? normalized : "";
}

function normalizeTemporaryPodName(value) {
  const normalized = typeof value === "string" ? value.trim() : "";
  return TEMPORARY_POD_NAME_PATTERN.test(normalized) ? normalized : "";
}

function configuredGPUTypeIds(value) {
  if (typeof value !== "string" || !value.trim()) return [];
  const values = value.split(",").map((item) => item.trim()).filter(Boolean);
  if (values.length < 1 || values.length > 8) return [];
  if (values.some((item) => item.length > 128 || /[\u0000-\u001f\u007f]/u.test(item))) {
    return [];
  }
  return [...new Set(values)];
}

function defaultSnapshot(now, configuredPodId) {
  return {
    version: 5,
    currentPodId: configuredPodId || null,
    currentPodKind: "primary",
    state: configuredPodId ? "preparing" : "closed",
    internalPhase: configuredPodId ? "status_unknown" : "runpod_configuration_missing",
    message: configuredPodId ? null : RUNPOD_CONFIGURATION_MESSAGE,
    updatedAt: iso(now),
    restartable: false,
    gpuCount: null,
    idleSince: null,
    lastActivityAt: null,
    activeTasks: {},
    canceledTasks: {},
    inFlightRequests: {},
    idleShutdownPending: false,
    shutdownRequest: null,
    startupStartedAt: null,
    startupDeadlineAt: null,
    startupControlPhase: null,
    primaryStartDispatched: false,
    temporaryCreateName: null,
    lastShutdownAttemptAt: null,
  };
}

function normalizeRecord(value) {
  return safeObject(value) || {};
}

function normalizeCanceledTasks(value, now) {
  const source = safeObject(value);
  if (!source) return {};
  const canceledTasks = {};
  for (const [taskId, expiresAt] of Object.entries(source)) {
    if (TASK_ID_PATTERN.test(taskId)
      && Number.isFinite(expiresAt)
      && expiresAt > now) {
      canceledTasks[taskId] = expiresAt;
    }
  }
  return canceledTasks;
}

function normalizeStoredSnapshot(value, now, configuredPodId) {
  if (!safeObject(value)) return defaultSnapshot(now, configuredPodId);
  const currentPodId = normalizePodId(value.currentPodId) || configuredPodId || null;
  const currentPodKind = value.currentPodKind === "temporary"
    && currentPodId
    && currentPodId !== configuredPodId
    ? "temporary"
    : "primary";
  let state;
  if ([3, 4, 5].includes(value.version)
    && ["closed", "preparing", "ready"].includes(value.state)) {
    state = value.state;
  } else if (value.state === "ready") {
    state = "ready";
  } else if (currentPodId) {
    state = "preparing";
  } else {
    state = "closed";
  }
  const legacyStop = safeObject(value.shutdownRequest)
    || safeObject(value.stopRequest)
    || safeObject(value.terminationRequest);
  const dueAt = Number(legacyStop?.dueAt);
  const shutdownKind = ["idle", "user", "startup_cleanup", "startup_primary_cleanup"]
    .includes(legacyStop?.kind)
    ? legacyStop.kind
    : "user";
  const shutdownRequest = Number.isFinite(dueAt)
    ? {
      kind: shutdownKind,
      dueAt,
      attempted: legacyStop.attempted === true,
    }
    : null;
  return {
    version: 5,
    currentPodId,
    currentPodKind,
    state: shutdownRequest && shutdownRequest.kind !== "idle" ? "preparing" : state,
    internalPhase: typeof value.internalPhase === "string"
      ? value.internalPhase
      : "status_unknown",
    message: typeof value.message === "string" ? value.message : null,
    updatedAt: typeof value.updatedAt === "string" ? value.updatedAt : iso(now),
    restartable: [3, 4, 5].includes(value.version) && value.restartable === true,
    gpuCount: positiveInteger(value.gpuCount) || positiveInteger(value.rebuildSpec?.gpuCount),
    idleSince: state === "ready" && Number.isFinite(value.idleSince)
      ? value.idleSince
      : null,
    lastActivityAt: Number.isFinite(value.lastActivityAt) ? value.lastActivityAt : null,
    activeTasks: normalizeRecord(value.activeTasks),
    canceledTasks: normalizeCanceledTasks(value.canceledTasks, now),
    inFlightRequests: normalizeRecord(value.inFlightRequests),
    idleShutdownPending: value.idleShutdownPending === true,
    shutdownRequest,
    startupStartedAt: Number.isFinite(value.startupStartedAt)
      ? value.startupStartedAt
      : null,
    startupDeadlineAt: Number.isFinite(value.startupDeadlineAt)
      ? value.startupDeadlineAt
      : null,
    startupControlPhase: [
      "inspect_primary",
      "primary_dispatch_intent",
      "primary_start",
      "temporary_create",
      "temporary_create_intent",
      "monitoring",
    ].includes(value.startupControlPhase)
      ? value.startupControlPhase
      : null,
    primaryStartDispatched: value.primaryStartDispatched === true,
    temporaryCreateName: normalizeTemporaryPodName(value.temporaryCreateName) || null,
    lastShutdownAttemptAt: Number.isFinite(value.lastShutdownAttemptAt)
      ? value.lastShutdownAttemptAt
      : null,
  };
}

function startupProgress(snapshot, options = {}) {
  if (snapshot.state !== "preparing" || options.error) return null;
  if (snapshot.shutdownRequest && snapshot.shutdownRequest.kind !== "idle") return null;
  switch (snapshot.internalPhase) {
    case "waiting_for_backend":
      return { current: 3, total: STARTUP_PROGRESS_TOTAL };
    case "waiting_for_pod":
    case "primary_dispatch_visibility_wait":
    case "temporary_create_visibility_wait":
      return { current: 2, total: STARTUP_PROGRESS_TOTAL };
    case "status_unknown":
    case "inspecting_primary":
    case "primary_dispatch_intent":
    case "temporary_create":
    case "temporary_create_intent":
      return { current: 1, total: STARTUP_PROGRESS_TOTAL };
    default:
      // Older snapshots may not have a recognized internal startup phase. A
      // message-less preparing snapshot safely restarts at the conservative
      // first public step without exposing or guessing a private phase.
      return snapshot.message === null
        ? { current: 1, total: STARTUP_PROGRESS_TOTAL }
        : null;
  }
}

function runtimeBody(snapshot, options = {}) {
  const hasActiveWork = Object.keys(snapshot.activeTasks).length > 0
    || Object.keys(snapshot.inFlightRequests).length > 0;
  const body = {
    ok: options.ok !== false,
    state: snapshot.state,
    phase: snapshot.state,
    message: options.error === "temporary_pod_create_failed" ? null : snapshot.message,
    retryAllowed: true,
    canStart: snapshot.state === "closed"
      && snapshot.restartable === true
      && snapshot.currentPodKind === "primary"
      && Boolean(normalizePodId(snapshot.currentPodId)),
    canTerminate: snapshot.state === "ready"
      && !snapshot.shutdownRequest
      && !hasActiveWork
      && Boolean(normalizePodId(snapshot.currentPodId)),
    updatedAt: snapshot.updatedAt,
  };
  const progress = startupProgress(snapshot, options);
  if (progress) body.progress = progress;
  if (options.error) body.error = options.error;
  return body;
}

function busyBody(snapshot) {
  return {
    ...runtimeBody(snapshot, { ok: false, error: "scanner_backend_busy" }),
    message: STOP_BUSY_MESSAGE,
  };
}

export class ScannerRuntime {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env || {};
    this.fetchImpl = this.env.__TEST_FETCH || ((input, init) => fetch(input, init));
    this.now = this.env.__TEST_NOW || Date.now;
    this.monotonicNow = this.env.__TEST_MONOTONIC_NOW
      || (() => globalThis.performance?.now?.() ?? Date.now());
    this.uuid = this.env.__TEST_UUID || (() => crypto.randomUUID());
    this.snapshot = null;
    this.controlTail = Promise.resolve();
    this.primaryStartFetchInvoked = false;
    this.ctx.blockConcurrencyWhile(async () => {
      await this.load();
    });
  }

  primaryPodId() {
    return normalizePodId(this.env.RUNPOD_POD_ID);
  }

  temporaryTemplateId() {
    return configurationId(this.env.RUNPOD_TEMPLATE_ID);
  }

  temporaryNetworkVolumeId() {
    return configurationId(this.env.RUNPOD_NETWORK_VOLUME_ID);
  }

  temporaryGPUTypeIds() {
    return configuredGPUTypeIds(this.env.RUNPOD_TEMPORARY_GPU_TYPE_IDS);
  }

  apiKey() {
    return typeof this.env.RUNPOD_API_KEY === "string"
      ? this.env.RUNPOD_API_KEY.trim()
      : "";
  }

  backendAPIToken() {
    return typeof this.env.CHEKI_BACKEND_API_TOKEN === "string"
      ? this.env.CHEKI_BACKEND_API_TOKEN.trim()
      : "";
  }

  activeTaskCheckConcurrency() {
    return boundedPositiveInteger(
      this.env.SCANNER_ACTIVE_TASK_CHECK_CONCURRENCY,
      DEFAULT_ACTIVE_TASK_CHECK_CONCURRENCY,
      MAX_ACTIVE_TASK_CHECK_CONCURRENCY,
    );
  }

  timingLogsEnabled() {
    return String(this.env.SCANNER_TIMING_LOGS || "").trim().toLowerCase() === "true";
  }

  logTiming(stage, fields = {}) {
    if (!this.timingLogsEnabled()) return;
    const safeStage = /^[A-Za-z0-9_-]{1,32}$/u.test(stage) ? stage : "unknown";
    const values = [`stage=${safeStage}`];
    for (const [name, value] of Object.entries(fields)) {
      if (!TIMING_FIELD_NAMES.has(name)) continue;
      if (typeof value === "string" && /^[A-Za-z0-9_-]{1,32}$/u.test(value)) {
        values.push(`${name}=${value}`);
      } else if (Number.isFinite(value)) {
        values.push(`${name}=${Math.max(0, Math.round(value))}`);
      }
    }
    console.info(`[scanner-timing] ${values.join(" ")}`);
  }

  async load() {
    const stored = await this.ctx.storage.get(STATE_KEY);
    this.snapshot = normalizeStoredSnapshot(
      stored,
      this.now(),
      this.primaryPodId(),
    );
  }

  adoptUpdatedPrimaryPod() {
    const configured = this.primaryPodId();
    const current = normalizePodId(this.snapshot.currentPodId);
    const unavailable = ["pod_not_found", "pod_terminated", "runpod_configuration_missing"]
      .includes(this.snapshot.internalPhase);
    const shouldAdopt = configured && this.snapshot.currentPodKind !== "temporary"
      && (!current || current !== configured || unavailable);
    if (shouldAdopt) {
      this.snapshot.currentPodId = configured;
      this.snapshot.currentPodKind = "primary";
      this.snapshot.state = "preparing";
      this.snapshot.internalPhase = "status_unknown";
      this.snapshot.message = null;
      this.snapshot.restartable = false;
      this.snapshot.gpuCount = null;
      this.snapshot.idleSince = null;
      this.snapshot.shutdownRequest = null;
      this.snapshot.startupStartedAt = null;
      this.snapshot.startupDeadlineAt = null;
      this.snapshot.startupControlPhase = null;
      this.snapshot.primaryStartDispatched = false;
      this.snapshot.temporaryCreateName = null;
      this.snapshot.updatedAt = iso(this.now());
    }
  }

  async ensureLoaded() {
    if (!this.snapshot) await this.load();
  }

  async persist() {
    await this.ctx.storage.put(STATE_KEY, this.snapshot);
  }

  async withControl(operation) {
    const previous = this.controlTail;
    let release;
    this.controlTail = new Promise((resolve) => { release = resolve; });
    await previous;
    try {
      return await operation();
    } finally {
      release();
    }
  }

  async transition(state, internalPhase, message = null) {
    this.snapshot.state = state;
    this.snapshot.internalPhase = internalPhase;
    this.snapshot.message = message;
    this.snapshot.updatedAt = iso(this.now());
    await this.persist();
    if (state === "preparing" && this.hasStartupSockets()) {
      this.broadcastStartupSnapshot();
    }
  }

  async scheduleAlarm(time) {
    const current = typeof this.ctx.storage.getAlarm === "function"
      ? await this.ctx.storage.getAlarm()
      : null;
    if (Number.isFinite(current) && current <= time) return;
    await this.ctx.storage.setAlarm(time);
  }

  isPrimaryDispatchIntent() {
    return this.snapshot.currentPodKind === "primary"
      && this.snapshot.primaryStartDispatched === true
      && this.snapshot.startupControlPhase === "primary_dispatch_intent";
  }

  isTemporaryCreateIntent() {
    return this.snapshot.currentPodKind === "primary"
      && this.snapshot.startupControlPhase === "temporary_create_intent"
      && Boolean(normalizeTemporaryPodName(this.snapshot.temporaryCreateName));
  }

  async persistPrimaryDispatchIntent() {
    const recoveryAt = Math.min(
      this.snapshot.startupDeadlineAt,
      this.now() + START_RECHECK_MS,
    );
    // Establish the wakeup first. If execution stops before the following put,
    // the alarm is harmless; once the intent is durable, a watchdog is already
    // guaranteed to exist. No RunPod control fetch is allowed before both await.
    await this.scheduleAlarm(recoveryAt);
    await this.persist();
    if (this.hasStartupSockets()) this.broadcastStartupSnapshot();
  }

  async persistTemporaryCreateIntent() {
    const recoveryAt = Math.min(
      this.snapshot.startupDeadlineAt,
      this.now() + START_RECHECK_MS,
    );
    await this.scheduleAlarm(recoveryAt);
    await this.persist();
    if (this.hasStartupSockets()) this.broadcastStartupSnapshot();
  }

  clearStartupTracking() {
    this.snapshot.startupStartedAt = null;
    this.snapshot.startupDeadlineAt = null;
    this.snapshot.startupControlPhase = null;
  }

  startupInterruptionCode() {
    if (!this.hasStartupSockets()) return "startup_disconnected";
    if (Number.isFinite(this.snapshot.startupDeadlineAt)
      && this.now() >= this.snapshot.startupDeadlineAt) {
      return "startup_timeout";
    }
    return null;
  }

  async enterStartupFailure(code, message, {
    primaryIntentResolved = false,
    temporaryIntentResolved = false,
  } = {}) {
    if (this.isTemporaryCreateIntent() && !temporaryIntentResolved) {
      return this.recoverTemporaryCreateIntent({ failure: { code, message } });
    }
    if (this.isPrimaryDispatchIntent()
      && !this.primaryStartFetchInvoked
      && !primaryIntentResolved) {
      return this.recoverPrimaryDispatchIntent({ failure: { code, message } });
    }
    const temporaryCleanup = this.snapshot.currentPodKind === "temporary";
    const primaryCleanup = this.snapshot.currentPodKind === "primary"
      && this.snapshot.primaryStartDispatched === true;
    this.clearStartupTracking();
    this.primaryStartFetchInvoked = false;
    this.snapshot.primaryStartDispatched = false;
    this.snapshot.restartable = this.snapshot.currentPodKind === "primary"
      && !primaryCleanup;
    this.snapshot.idleSince = null;
    if (temporaryCleanup || primaryCleanup) {
      const now = this.now();
      this.snapshot.shutdownRequest = {
        kind: temporaryCleanup ? "startup_cleanup" : "startup_primary_cleanup",
        dueAt: now,
        attempted: false,
      };
      await this.transition(
        "preparing",
        temporaryCleanup ? "temporary_cleanup_pending" : "primary_cleanup_pending",
        message,
      );
      await this.scheduleAlarm(now);
    } else {
      this.snapshot.shutdownRequest = null;
      await this.transition("closed", code, message);
    }
    return { error: code };
  }

  async closeRecoveredPrimaryIntent(code, message, restartable) {
    this.primaryStartFetchInvoked = false;
    this.snapshot.primaryStartDispatched = false;
    this.snapshot.shutdownRequest = null;
    this.snapshot.restartable = restartable;
    this.snapshot.gpuCount = null;
    this.snapshot.idleSince = null;
    this.clearStartupTracking();
    await this.transition("closed", code, message);
    return { error: code };
  }

  async retainPrimaryDispatchIntentUntilDeadline() {
    if (!Number.isFinite(this.snapshot.startupDeadlineAt)
      || this.now() >= this.snapshot.startupDeadlineAt) return false;
    const nextProbeAt = Math.min(
      this.snapshot.startupDeadlineAt,
      this.now() + START_RECHECK_MS,
    );
    // The current alarm has already fired, so re-establish the next watchdog
    // before persisting the still-unresolved intent.
    await this.scheduleAlarm(nextProbeAt);
    this.snapshot.restartable = false;
    await this.transition("preparing", "primary_dispatch_visibility_wait", null);
    return true;
  }

  async deferOrCloseRecoveredPrimaryIntent(code, message, restartable) {
    if (await this.retainPrimaryDispatchIntentUntilDeadline()) {
      return { error: null, visibilityPending: true };
    }
    return this.closeRecoveredPrimaryIntent(code, message, restartable);
  }

  async recoverPrimaryDispatchIntent({ failure = null } = {}) {
    const podId = this.primaryPodId();
    if (!podId) {
      return this.closeRecoveredPrimaryIntent(
        "runpod_configuration_missing",
        RUNPOD_CONFIGURATION_MESSAGE,
        false,
      );
    }
    try {
      const pod = await this.getPod(podId);
      if (!pod) {
        return this.deferOrCloseRecoveredPrimaryIntent(
          "pod_not_found",
          POD_MISSING_MESSAGE,
          false,
        );
      }
      this.applyKnownGPUCount(pod);
      if (pod.desiredStatus === "TERMINATED") {
        return this.deferOrCloseRecoveredPrimaryIntent(
          "pod_terminated",
          POD_TERMINATED_MESSAGE,
          false,
        );
      }
      if (pod.desiredStatus === "EXITED") {
        return this.deferOrCloseRecoveredPrimaryIntent(
          "runpod_start_failed",
          START_FAILURE_MESSAGE,
          true,
        );
      }
      if (pod.desiredStatus === "ERROR") {
        return this.deferOrCloseRecoveredPrimaryIntent(
          "runpod_start_failed",
          START_FAILURE_MESSAGE,
          true,
        );
      }

      // The Pod has left a closed state, so the pre-dispatch crash window can no
      // longer be proven. Treat the intent as possibly accepted from here on.
      this.snapshot.startupControlPhase = "monitoring";
      await this.persist();
      const interruption = failure || (() => {
        const code = this.startupInterruptionCode();
        return code ? {
          code,
          message: code === "startup_timeout"
            ? STARTUP_TIMEOUT_MESSAGE
            : STARTUP_DISCONNECTED_MESSAGE,
        } : null;
      })();
      if (interruption) {
        return this.enterStartupFailure(
          interruption.code,
          interruption.message,
          { primaryIntentResolved: true },
        );
      }
      if (["PROVISIONING", "STARTING"].includes(pod.desiredStatus)) {
        this.snapshot.restartable = false;
        await this.transition("preparing", "waiting_for_pod", null);
        return { error: null };
      }
      if (!this.backendAPIToken()) {
        return this.enterStartupFailure(
          "backend_configuration_missing",
          "RunPod 后端鉴权配置缺失，请检查服务端配置。",
          { primaryIntentResolved: true },
        );
      }
      const backendReady = await this.backendIsReady(podId);
      const interruptedAfterHealth = this.startupInterruptionCode();
      if (interruptedAfterHealth) {
        return this.enterStartupFailure(
          interruptedAfterHealth,
          interruptedAfterHealth === "startup_timeout"
            ? STARTUP_TIMEOUT_MESSAGE
            : STARTUP_DISCONNECTED_MESSAGE,
          { primaryIntentResolved: true },
        );
      }
      if (backendReady) {
        this.snapshot.primaryStartDispatched = false;
        this.clearStartupTracking();
        await this.transition("ready", "ready", null);
      } else {
        await this.transition("preparing", "waiting_for_backend", BACKEND_PREPARING_MESSAGE);
      }
      return { error: null };
    } catch (error) {
      const classified = error instanceof RunPodError
        ? error
        : new RunPodError("runpod_status_unavailable", STATUS_FAILURE_MESSAGE);
      // The read could not prove the Pod is still closed. Preserve the
      // conservative at-most-once cleanup contract for an uncertain dispatch.
      return this.enterStartupFailure(
        failure?.code || classified.code,
        failure?.message || classified.publicMessage,
        { primaryIntentResolved: true },
      );
    }
  }

  async retainTemporaryCreateIntentUntilDeadline() {
    if (!Number.isFinite(this.snapshot.startupDeadlineAt)
      || this.now() >= this.snapshot.startupDeadlineAt) return false;
    const nextProbeAt = Math.min(
      this.snapshot.startupDeadlineAt,
      this.now() + START_RECHECK_MS,
    );
    await this.scheduleAlarm(nextProbeAt);
    this.snapshot.restartable = false;
    await this.transition("preparing", "temporary_create_visibility_wait", null);
    return true;
  }

  async failTemporaryCreateIntent(code, message, { retainName = false } = {}) {
    this.snapshot.primaryStartDispatched = false;
    this.snapshot.shutdownRequest = null;
    this.snapshot.restartable = false;
    this.snapshot.gpuCount = null;
    this.snapshot.idleSince = null;
    if (!retainName) this.snapshot.temporaryCreateName = null;
    this.clearStartupTracking();
    await this.transition("closed", code, message);
    return { error: code };
  }

  async recoverTemporaryCreateIntent({ failure = null } = {}) {
    const name = normalizeTemporaryPodName(this.snapshot.temporaryCreateName);
    if (!name) {
      return this.failTemporaryCreateIntent(
        "temporary_pod_create_failed",
        TEMPORARY_CREATE_FAILURE_MESSAGE,
      );
    }
    let temporaryPod;
    try {
      temporaryPod = await this.getTemporaryPodByExactName(name);
    } catch (error) {
      if (error instanceof RunPodError
        && error.code === "temporary_pod_correlation_ambiguous") {
        return this.failTemporaryCreateIntent(
          error.code,
          error.publicMessage,
          { retainName: true },
        );
      }
      if (await this.retainTemporaryCreateIntentUntilDeadline()) {
        return { error: null, visibilityPending: true };
      }
      const classified = error instanceof RunPodError
        ? error
        : new RunPodError("runpod_status_unavailable", STATUS_FAILURE_MESSAGE);
      return this.failTemporaryCreateIntent(classified.code, classified.publicMessage, {
        retainName: true,
      });
    }
    if (!temporaryPod) {
      if (await this.retainTemporaryCreateIntentUntilDeadline()) {
        return { error: null, visibilityPending: true };
      }
      return this.failTemporaryCreateIntent(
        failure?.code || "temporary_pod_create_failed",
        failure?.message || TEMPORARY_CREATE_FAILURE_MESSAGE,
      );
    }

    // Persist the recovered ID before interpreting status, socket state, or the
    // original transport failure. From this point every failure is terminable.
    this.snapshot.currentPodId = temporaryPod.id;
    this.snapshot.currentPodKind = "temporary";
    this.snapshot.restartable = false;
    this.snapshot.startupControlPhase = "monitoring";
    await this.persist();
    this.snapshot.temporaryCreateName = null;
    await this.persist();

    return this.enterStartupFailure(
      failure?.code || "temporary_pod_create_failed",
      failure?.message || TEMPORARY_CREATE_FAILURE_MESSAGE,
      { temporaryIntentResolved: true },
    );
  }

  async stopStartupIfInterrupted() {
    const code = this.startupInterruptionCode();
    if (!code) return null;
    return this.enterStartupFailure(
      code,
      code === "startup_timeout"
        ? STARTUP_TIMEOUT_MESSAGE
        : STARTUP_DISCONNECTED_MESSAGE,
    );
  }

  startupSockets() {
    if (typeof this.ctx.getWebSockets !== "function") return [];
    return this.ctx.getWebSockets(STARTUP_SOCKET_TAG)
      .filter((socket) => socket.readyState === 1);
  }

  hasStartupSockets() {
    return this.startupSockets().length > 0;
  }

  sendStartupSnapshot(socket, options = {}) {
    try {
      socket.send(JSON.stringify(runtimeBody(this.snapshot, options)));
      return true;
    } catch {
      return false;
    }
  }

  broadcastStartupSnapshot(options = {}) {
    const sockets = this.startupSockets();
    for (const socket of sockets) {
      const sent = this.sendStartupSnapshot(socket, options);
      if (sent && !options.close) continue;
      try {
        socket.close(
          options.error ? 1011 : 1000,
          options.error ? "startup_failed" : "ready",
        );
      } catch {
        // The client may already have closed the socket.
      }
    }
  }

  async openStartupSocket() {
    if (typeof WebSocketPair !== "function"
      || typeof this.ctx.acceptWebSocket !== "function") {
      return fixedError("websocket_unavailable", 501);
    }
    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    this.ctx.acceptWebSocket(server, [STARTUP_SOCKET_TAG]);
    this.sendStartupSnapshot(server);

    const operation = this.withControl(async () => {
      if (!this.hasStartupSockets()) return;
      const outcome = await this.start();
      if (outcome.error) {
        this.broadcastStartupSnapshot({ ok: false, error: outcome.error, close: true });
        return;
      }
      if (this.snapshot.state === "ready") {
        this.broadcastStartupSnapshot({ close: true });
        return;
      }
      this.broadcastStartupSnapshot();
      if (this.hasStartupSockets()) {
        await this.scheduleAlarm(this.now() + START_RECHECK_MS);
      }
    });
    if (typeof this.ctx.waitUntil === "function") this.ctx.waitUntil(operation);
    else operation.catch(() => {});

    return new Response(null, { status: 101, webSocket: client });
  }

  webSocketMessage() {
    // Server-push only. Client messages are intentionally ignored.
  }

  queueStartupDisconnectHandling() {
    const operation = this.withControl(async () => {
      if (this.snapshot.state !== "preparing"
        || !Number.isFinite(this.snapshot.startupDeadlineAt)
        || this.hasStartupSockets()) return;
      await this.enterStartupFailure(
        "startup_disconnected",
        STARTUP_DISCONNECTED_MESSAGE,
      );
    });
    if (typeof this.ctx.waitUntil === "function") this.ctx.waitUntil(operation);
    else operation.catch(() => {});
  }

  webSocketClose(socket, code, reason) {
    try { socket.close(code, reason); } catch { /* Already closed. */ }
    this.queueStartupDisconnectHandling();
  }

  webSocketError(socket) {
    try { socket.close(1011, "startup_socket_error"); } catch { /* Already closed. */ }
    this.queueStartupDisconnectHandling();
  }

  async authenticatedFetch(url, init = {}, { beforeFetch = null } = {}) {
    const apiKey = this.apiKey();
    if (!apiKey) {
      throw new RunPodError(
        "runpod_configuration_missing",
        RUNPOD_CONFIGURATION_MESSAGE,
      );
    }
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), RUNPOD_TIMEOUT_MS);
    try {
      if (beforeFetch) beforeFetch();
      return await this.fetchImpl(url, {
        ...init,
        headers: {
          authorization: `Bearer ${apiKey}`,
          accept: "application/json",
          ...(init.body ? { "content-type": "application/json" } : {}),
          ...(init.headers || {}),
        },
        signal: controller.signal,
      });
    } catch (error) {
      if (error instanceof RunPodError) throw error;
      if (error?.name === "AbortError") {
        throw new RunPodError("runpod_status_timeout", RUNPOD_STATUS_TIMEOUT_MESSAGE);
      }
      throw new RunPodError("runpod_status_unavailable", RUNPOD_STATUS_UNAVAILABLE_MESSAGE);
    } finally {
      clearTimeout(timeout);
    }
  }

  restURL(path) {
    return `${RUNPOD_REST_ORIGIN}${path}`;
  }

  async classifyRunPodResponse(response, { allowMissing = false } = {}) {
    if (response.status === 404) {
      try { await responseTextBounded(response); } catch { /* Fixed classification. */ }
      if (allowMissing) return null;
      throw new RunPodError("pod_not_found", POD_MISSING_MESSAGE, 404);
    }
    if ([401, 403].includes(response.status)) {
      try { await responseTextBounded(response); } catch { /* Fixed classification. */ }
      throw new RunPodError(
        "runpod_authorization_failed",
        RUNPOD_AUTHORIZATION_MESSAGE,
        response.status,
      );
    }
    if (response.status === 429) {
      try { await responseTextBounded(response); } catch { /* Fixed classification. */ }
      throw new RunPodError("runpod_rate_limited", RUNPOD_RATE_LIMIT_MESSAGE, 429);
    }
    if (!response.ok) {
      try { await responseTextBounded(response); } catch { /* Fixed classification. */ }
      throw new RunPodError(
        "runpod_status_unavailable",
        RUNPOD_STATUS_UNAVAILABLE_MESSAGE,
        response.status,
      );
    }
    return response;
  }

  normalizeRunPod(item) {
    const id = normalizePodId(item?.id);
    const rawStatus = typeof item?.desiredStatus === "string"
      ? item.desiredStatus
      : item?.status;
    if (!safeObject(item)
      || !id
      || typeof rawStatus !== "string"
      || !rawStatus.trim()) {
      throw new RunPodError("runpod_invalid_response", RUNPOD_INVALID_RESPONSE_MESSAGE);
    }
    const desiredStatus = rawStatus.trim().toUpperCase();
    if (!["PROVISIONING", "STARTING", "RUNNING", "EXITED", "ERROR", "TERMINATED"]
      .includes(desiredStatus)) {
      throw new RunPodError("runpod_invalid_response", RUNPOD_INVALID_RESPONSE_MESSAGE);
    }
    return {
      ...item,
      id,
      name: typeof item.name === "string" ? item.name.trim() : "",
      status: desiredStatus,
      desiredStatus,
    };
  }

  async listPods() {
    const response = await this.authenticatedFetch(this.restURL("/pods"));
    await this.classifyRunPodResponse(response);
    let body;
    try {
      body = await responseJSONBounded(response);
    } catch {
      throw new RunPodError("runpod_invalid_response", RUNPOD_INVALID_RESPONSE_MESSAGE);
    }
    if (!Array.isArray(body)) {
      throw new RunPodError("runpod_invalid_response", RUNPOD_INVALID_RESPONSE_MESSAGE);
    }
    return body.map((item) => this.normalizeRunPod(item));
  }

  async getPod(podId) {
    const response = await this.authenticatedFetch(
      this.restURL(`/pods/${encodeURIComponent(podId)}?includeMachine=true`),
    );
    if (!await this.classifyRunPodResponse(response, { allowMissing: true })) {
      return null;
    }
    let body;
    try {
      body = await responseJSONBounded(response);
    } catch {
      throw new RunPodError("runpod_invalid_response", RUNPOD_INVALID_RESPONSE_MESSAGE);
    }
    const pod = this.normalizeRunPod(body);
    if (pod.id !== podId) {
      throw new RunPodError("runpod_invalid_response", RUNPOD_INVALID_RESPONSE_MESSAGE);
    }
    return pod;
  }

  async getTemporaryPodByExactName(name) {
    const matches = (await this.listPods()).filter((item) => item.name === name);
    if (matches.length > 1) {
      throw new RunPodError(
        "temporary_pod_correlation_ambiguous",
        TEMPORARY_CORRELATION_FAILURE_MESSAGE,
      );
    }
    return matches[0] || null;
  }

  async backendIsReady(podId) {
    const backendToken = this.backendAPIToken();
    if (!backendToken) return false;
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), HEALTH_TIMEOUT_MS);
    try {
      const response = await this.fetchImpl(
        new Request(
          `https://${podId}-${RUNPOD_HTTP_PORT}.proxy.runpod.net/health`,
          {
            headers: { authorization: `Bearer ${backendToken}` },
            redirect: "manual",
          },
        ),
        { signal: controller.signal },
      );
      if (response.status !== 200) return false;
      const body = await responseJSONBounded(response);
      return body?.status === "ok"
        && body?.model_loaded === true
        && body?.device === "cuda";
    } catch {
      return false;
    } finally {
      clearTimeout(timeout);
    }
  }

  async readOnlyRuntimeProbe() {
    const captured = {
      ...this.snapshot,
      activeTasks: { ...this.snapshot.activeTasks },
      inFlightRequests: { ...this.snapshot.inFlightRequests },
      shutdownRequest: this.snapshot.shutdownRequest
        ? { ...this.snapshot.shutdownRequest }
        : null,
    };
    const podKind = captured.currentPodKind === "temporary"
      ? "temporary"
      : "primary";
    const podId = podKind === "temporary"
      ? normalizePodId(captured.currentPodId)
      : this.primaryPodId();
    const responseSnapshot = (
      state,
      message,
      restartable = false,
      internalPhase = captured.internalPhase,
    ) => ({
      ...captured,
      currentPodId: podId || null,
      currentPodKind: podKind,
      state,
      internalPhase,
      message,
      restartable,
      updatedAt: iso(this.now()),
    });

    if (!podId || !this.apiKey()) {
      return runtimeBody(responseSnapshot(
        "closed",
        RUNPOD_CONFIGURATION_MESSAGE,
      ));
    }

    try {
      const pod = await this.getPod(podId);
      if (!pod) {
        return runtimeBody(responseSnapshot(
          "closed",
          podKind === "temporary" ? TEMPORARY_EXITED_MESSAGE : POD_MISSING_MESSAGE,
        ));
      }
      if (pod.desiredStatus === "TERMINATED") {
        return runtimeBody(responseSnapshot(
          "closed",
          podKind === "temporary" ? TEMPORARY_EXITED_MESSAGE : POD_TERMINATED_MESSAGE,
        ));
      }
      if (pod.desiredStatus === "EXITED") {
        return runtimeBody(responseSnapshot(
          "closed",
          podKind === "temporary" ? TEMPORARY_EXITED_MESSAGE : null,
          podKind === "primary",
        ));
      }
      if (pod.desiredStatus === "ERROR") {
        return runtimeBody(responseSnapshot(
          "closed",
          START_FAILURE_MESSAGE,
          podKind === "primary",
        ));
      }
      if (pod.desiredStatus !== "RUNNING") {
        return runtimeBody(responseSnapshot(
          "preparing",
          BACKEND_PREPARING_MESSAGE,
          false,
          "waiting_for_pod",
        ));
      }
      if (!this.backendAPIToken()) {
        return runtimeBody(responseSnapshot(
          "preparing",
          "RunPod 后端鉴权配置缺失，请检查服务端配置。",
          false,
          "backend_configuration_missing",
        ));
      }
      const ready = await this.backendIsReady(podId);
      if (!ready) {
        return runtimeBody(responseSnapshot(
          "preparing",
          BACKEND_PREPARING_MESSAGE,
          false,
          "waiting_for_backend",
        ));
      }
      const pendingClose = captured.shutdownRequest?.kind === "user"
        || captured.shutdownRequest?.kind === "startup_cleanup"
        || captured.shutdownRequest?.kind === "startup_primary_cleanup";
      return runtimeBody(responseSnapshot(
        pendingClose ? "preparing" : "ready",
        pendingClose ? captured.message : null,
        false,
        pendingClose ? "shutdown_delay" : "ready",
      ));
    } catch (error) {
      const classified = error instanceof RunPodError
        ? error
        : new RunPodError("runpod_invalid_response", RUNPOD_INVALID_RESPONSE_MESSAGE);
      return runtimeBody(responseSnapshot(
        classified.code === "runpod_configuration_missing" ? "closed" : "preparing",
        classified.publicMessage,
        false,
        classified.code,
      ));
    }
  }

  applyKnownGPUCount(pod) {
    const count = podGPUCount(pod);
    if (count) this.snapshot.gpuCount = count;
  }

  async moveBackToPrimary() {
    this.snapshot.currentPodId = this.primaryPodId() || null;
    this.snapshot.currentPodKind = "primary";
    this.snapshot.gpuCount = null;
    this.snapshot.primaryStartDispatched = false;
    this.snapshot.temporaryCreateName = null;
    this.clearStartupTracking();
    this.snapshot.shutdownRequest = null;
  }

  async reconcileRuntime({ startup = false } = {}) {
    this.adoptUpdatedPrimaryPod();
    if (startup) {
      const interrupted = await this.stopStartupIfInterrupted();
      if (interrupted) return interrupted;
    }
    const podId = normalizePodId(this.snapshot.currentPodId);
    if (!podId) {
      this.snapshot.shutdownRequest = null;
      this.snapshot.restartable = false;
      this.snapshot.idleSince = null;
      if (startup) {
        return this.enterStartupFailure(
          "runpod_configuration_missing",
          RUNPOD_CONFIGURATION_MESSAGE,
        );
      }
      this.clearStartupTracking();
      await this.transition("closed", "runpod_configuration_missing", RUNPOD_CONFIGURATION_MESSAGE);
      return { error: null };
    }
    try {
      const pod = await this.getPod(podId);
      if (startup) {
        const interrupted = await this.stopStartupIfInterrupted();
        if (interrupted) return interrupted;
      }
      if (!pod) {
        const temporary = this.snapshot.currentPodKind === "temporary";
        if (temporary) await this.moveBackToPrimary();
        else {
          this.snapshot.shutdownRequest = null;
          this.snapshot.primaryStartDispatched = false;
        }
        this.snapshot.restartable = false;
        this.snapshot.gpuCount = null;
        this.snapshot.idleSince = null;
        this.clearStartupTracking();
        await this.transition(
          "closed",
          temporary ? "temporary_pod_missing" : "pod_not_found",
          temporary ? TEMPORARY_EXITED_MESSAGE : POD_MISSING_MESSAGE,
        );
        return { error: startup ? "pod_not_found" : null };
      }
      this.applyKnownGPUCount(pod);
      if (pod.desiredStatus === "TERMINATED") {
        const temporary = this.snapshot.currentPodKind === "temporary";
        if (temporary) await this.moveBackToPrimary();
        else {
          this.snapshot.shutdownRequest = null;
          this.snapshot.primaryStartDispatched = false;
        }
        this.snapshot.restartable = false;
        this.snapshot.gpuCount = null;
        this.snapshot.idleSince = null;
        this.clearStartupTracking();
        await this.transition(
          "closed",
          temporary ? "temporary_pod_terminated" : "pod_terminated",
          temporary ? TEMPORARY_EXITED_MESSAGE : POD_TERMINATED_MESSAGE,
        );
        return { error: startup ? "pod_terminated" : null };
      }
      if (pod.desiredStatus === "EXITED") {
        if (this.snapshot.currentPodKind === "temporary") {
          this.snapshot.restartable = false;
          this.snapshot.idleSince = null;
          if (startup) {
            return this.enterStartupFailure(
              "temporary_pod_exited",
              TEMPORARY_EXITED_MESSAGE,
            );
          }
          this.clearStartupTracking();
          await this.transition("closed", "temporary_pod_exited", TEMPORARY_EXITED_MESSAGE);
          return { error: null };
        }
        this.snapshot.shutdownRequest = null;
        const stillStarting = startup
          && Number.isFinite(this.snapshot.startupStartedAt)
          && this.now() - this.snapshot.startupStartedAt < START_EXIT_GRACE_MS;
        if (stillStarting) {
          this.snapshot.restartable = false;
          await this.transition("preparing", "waiting_for_pod", null);
          return { error: null };
        }
        this.snapshot.restartable = true;
        this.snapshot.idleSince = null;
        this.snapshot.primaryStartDispatched = false;
        this.clearStartupTracking();
        await this.transition(
          "closed",
          startup ? "runpod_start_failed" : "pod_exited",
          startup ? START_FAILURE_MESSAGE : null,
        );
        return { error: startup ? "runpod_start_failed" : null };
      }
      if (pod.desiredStatus === "ERROR") {
        if (this.snapshot.currentPodKind === "temporary" && startup) {
          return this.enterStartupFailure("runpod_start_failed", START_FAILURE_MESSAGE);
        }
        this.snapshot.restartable = this.snapshot.currentPodKind === "primary";
        if (this.snapshot.currentPodKind === "primary") {
          this.snapshot.primaryStartDispatched = false;
        }
        this.clearStartupTracking();
        await this.transition("closed", "runpod_start_failed", START_FAILURE_MESSAGE);
        return { error: startup ? "runpod_start_failed" : null };
      }
      if (pod.desiredStatus !== "RUNNING") {
        this.snapshot.restartable = false;
        await this.transition("preparing", "waiting_for_pod", null);
        return { error: null };
      }
      this.snapshot.restartable = false;
      if (!this.backendAPIToken()) {
        this.snapshot.idleSince = null;
        if (startup) {
          return this.enterStartupFailure(
            "backend_configuration_missing",
            "RunPod 后端鉴权配置缺失，请检查服务端配置。",
          );
        }
        await this.transition(
          "preparing",
          "backend_configuration_missing",
          "RunPod 后端鉴权配置缺失，请检查服务端配置。",
        );
        return { error: startup ? "backend_configuration_missing" : null };
      }
      const backendReady = await this.backendIsReady(podId);
      if (startup) {
        const interrupted = await this.stopStartupIfInterrupted();
        if (interrupted) return interrupted;
      }
      if (backendReady) {
        this.snapshot.primaryStartDispatched = false;
        this.clearStartupTracking();
        if (this.snapshot.shutdownRequest?.kind === "user") {
          await this.transition("preparing", "shutdown_delay", STOP_DELAY_MESSAGE);
        } else {
          await this.transition("ready", "ready", null);
        }
      } else {
        await this.transition("preparing", "waiting_for_backend", BACKEND_PREPARING_MESSAGE);
      }
      return { error: null };
    } catch (error) {
      const classified = error instanceof RunPodError
        ? error
        : new RunPodError("runpod_status_unavailable", STATUS_FAILURE_MESSAGE);
      if (startup) {
        return this.enterStartupFailure(classified.code, classified.publicMessage);
      }
      const state = classified.code === "runpod_configuration_missing"
        ? "closed"
        : "preparing";
      this.snapshot.restartable = false;
      this.snapshot.idleSince = null;
      await this.transition(state, classified.code, classified.publicMessage);
      return { error: null };
    }
  }

  async postRESTAction(podId, action, options = {}) {
    const response = await this.authenticatedFetch(
      this.restURL(`/pods/${encodeURIComponent(podId)}/${action}`),
      { method: "POST" },
      options,
    );
    return response;
  }

  async createTemporaryPod(primaryPod) {
    if (this.isTemporaryCreateIntent()) {
      return this.recoverTemporaryCreateIntent();
    }
    const templateId = this.temporaryTemplateId();
    const networkVolumeId = this.temporaryNetworkVolumeId();
    if (!templateId || !networkVolumeId) {
      throw new RunPodError(
        "temporary_pod_configuration_missing",
        TEMPORARY_CONFIGURATION_MESSAGE,
      );
    }
    const gpuTypeIds = this.temporaryGPUTypeIds();
    const temporaryName = normalizeTemporaryPodName(
      `chekinana-scanner-temporary-${String(this.uuid()).replace(/-/gu, "").toLowerCase()}`,
    );
    if (!temporaryName) {
      throw new RunPodError("temporary_pod_create_failed", TEMPORARY_CREATE_FAILURE_MESSAGE);
    }
    const requestBody = {
      name: temporaryName,
      templateId,
      networkVolumeId,
      computeType: "GPU",
      gpuCount: podGPUCount(primaryPod) || positiveInteger(this.snapshot.gpuCount) || 1,
      gpuTypePriority: "availability",
      interruptible: false,
      locked: false,
      ...(gpuTypeIds.length > 0 ? { gpuTypeIds } : {}),
    };
    this.snapshot.temporaryCreateName = temporaryName;
    this.snapshot.startupControlPhase = "temporary_create_intent";
    this.snapshot.internalPhase = "temporary_create_intent";
    this.snapshot.message = null;
    this.snapshot.updatedAt = iso(this.now());
    await this.persistTemporaryCreateIntent();
    const interruptedBeforeCreate = await this.stopStartupIfInterrupted();
    if (interruptedBeforeCreate) return interruptedBeforeCreate;

    const response = await this.authenticatedFetch(this.restURL("/pods"), {
      method: "POST",
      body: JSON.stringify(requestBody),
    });
    let body;
    try {
      body = JSON.parse(await responseTextBounded(response));
    } catch {
      return this.recoverTemporaryCreateIntent({
        failure: {
          code: "temporary_pod_create_failed",
          message: TEMPORARY_CREATE_FAILURE_MESSAGE,
        },
      });
    }
    const temporaryPodId = normalizePodId(body?.id);
    if (temporaryPodId && temporaryPodId !== this.primaryPodId()) {
      this.snapshot.currentPodId = temporaryPodId;
      this.snapshot.currentPodKind = "temporary";
      this.snapshot.restartable = false;
      this.snapshot.startupControlPhase = "monitoring";
      await this.persist();
      this.snapshot.temporaryCreateName = null;
      await this.persist();
      const interrupted = await this.stopStartupIfInterrupted();
      if (interrupted) return interrupted;
    }
    const createdStatus = String(body?.status || body?.desiredStatus || "").toUpperCase();
    if (response.status !== 201
      || !temporaryPodId
      || temporaryPodId === this.primaryPodId()
      || !["PROVISIONING", "STARTING", "RUNNING"].includes(createdStatus)) {
      if (this.snapshot.currentPodKind === "temporary") {
        return this.enterStartupFailure(
          "temporary_pod_create_failed",
          TEMPORARY_CREATE_FAILURE_MESSAGE,
        );
      }
      return this.recoverTemporaryCreateIntent({
        failure: {
          code: "temporary_pod_create_failed",
          message: TEMPORARY_CREATE_FAILURE_MESSAGE,
        },
      });
    }
    this.snapshot.gpuCount = podGPUCount(body) || requestBody.gpuCount;
    await this.persist();
    const interrupted = await this.stopStartupIfInterrupted();
    return interrupted || { error: null };
  }

  async start() {
    if (!this.hasStartupSockets()) return { error: "startup_disconnected" };
    const interruptedBeforeStart = await this.stopStartupIfInterrupted();
    if (interruptedBeforeStart) return interruptedBeforeStart;
    if (["startup_cleanup", "startup_primary_cleanup"]
      .includes(this.snapshot.shutdownRequest?.kind)) {
      return { error: "startup_cleanup_pending" };
    }
    if (this.isTemporaryCreateIntent()) {
      return this.recoverTemporaryCreateIntent();
    }
    if (this.isPrimaryDispatchIntent() && !this.primaryStartFetchInvoked) {
      return this.recoverPrimaryDispatchIntent();
    }
    if (this.snapshot.state === "preparing"
      && Number.isFinite(this.snapshot.startupStartedAt)
      && Number.isFinite(this.snapshot.startupDeadlineAt)) {
      return { error: null, attached: true };
    }
    if (this.snapshot.shutdownRequest && !this.snapshot.shutdownRequest.attempted) {
      this.snapshot.shutdownRequest = null;
    }
    const startupNow = this.now();
    this.snapshot.startupStartedAt = startupNow;
    this.snapshot.startupDeadlineAt = startupNow + STARTUP_DEADLINE_MS;
    this.snapshot.startupControlPhase = "inspect_primary";
    this.snapshot.primaryStartDispatched = false;
    this.snapshot.temporaryCreateName = null;
    this.primaryStartFetchInvoked = false;
    await this.transition("preparing", "inspecting_primary", null);
    const interruptedAfterRegistration = await this.stopStartupIfInterrupted();
    if (interruptedAfterRegistration) return interruptedAfterRegistration;
    if (this.snapshot.currentPodKind === "temporary") {
      this.snapshot.startupControlPhase = "monitoring";
      await this.persist();
      const interrupted = await this.stopStartupIfInterrupted();
      if (interrupted) return interrupted;
      return this.reconcileRuntime({ startup: true });
    }
    const podId = this.primaryPodId();
    if (!podId) {
      this.clearStartupTracking();
      this.snapshot.restartable = false;
      await this.transition("closed", "runpod_configuration_missing", RUNPOD_CONFIGURATION_MESSAGE);
      return { error: "runpod_configuration_missing" };
    }
    this.snapshot.currentPodId = podId;
    this.snapshot.currentPodKind = "primary";
    try {
      const primaryPod = await this.getPod(podId);
      const interruptedAfterPrimaryRead = await this.stopStartupIfInterrupted();
      if (interruptedAfterPrimaryRead) return interruptedAfterPrimaryRead;
      if (!primaryPod) {
        this.clearStartupTracking();
        this.snapshot.restartable = false;
        await this.transition("closed", "pod_not_found", POD_MISSING_MESSAGE);
        return { error: "pod_not_found" };
      }
      this.applyKnownGPUCount(primaryPod);
      if (primaryPod.desiredStatus === "TERMINATED") {
        this.clearStartupTracking();
        this.snapshot.restartable = false;
        await this.transition("closed", "pod_terminated", POD_TERMINATED_MESSAGE);
        return { error: "pod_terminated" };
      }
      if (["PROVISIONING", "STARTING"].includes(primaryPod.desiredStatus)) {
        this.snapshot.startupControlPhase = "monitoring";
        await this.transition("preparing", "waiting_for_pod", null);
        const interrupted = await this.stopStartupIfInterrupted();
        if (interrupted) return interrupted;
        return { error: null };
      }
      if (primaryPod.desiredStatus === "RUNNING") {
        if (!this.backendAPIToken()) {
          return this.enterStartupFailure(
            "backend_configuration_missing",
            "RunPod 后端鉴权配置缺失，请检查服务端配置。",
          );
        }
        this.snapshot.startupControlPhase = "monitoring";
        await this.persist();
        const interruptedBeforeHealth = await this.stopStartupIfInterrupted();
        if (interruptedBeforeHealth) return interruptedBeforeHealth;
        const backendReady = await this.backendIsReady(podId);
        const interruptedAfterHealth = await this.stopStartupIfInterrupted();
        if (interruptedAfterHealth) return interruptedAfterHealth;
        if (backendReady) {
          this.snapshot.primaryStartDispatched = false;
          this.clearStartupTracking();
          await this.transition("ready", "ready", null);
        } else {
          await this.transition("preparing", "waiting_for_backend", BACKEND_PREPARING_MESSAGE);
          const interruptedAfterPreparing = await this.stopStartupIfInterrupted();
          if (interruptedAfterPreparing) return interruptedAfterPreparing;
        }
        return { error: null };
      }

      this.snapshot.startupControlPhase = "primary_dispatch_intent";
      this.snapshot.primaryStartDispatched = true;
      this.snapshot.internalPhase = "primary_dispatch_intent";
      this.snapshot.message = null;
      this.snapshot.updatedAt = iso(this.now());
      await this.persistPrimaryDispatchIntent();
      const interruptedBeforePrimaryStart = await this.stopStartupIfInterrupted();
      if (interruptedBeforePrimaryStart) return interruptedBeforePrimaryStart;
      const response = await this.postRESTAction(podId, "start", {
        beforeFetch: () => { this.primaryStartFetchInvoked = true; },
      });
      const interruptedAfterPrimaryStart = await this.stopStartupIfInterrupted();
      if (interruptedAfterPrimaryStart) return interruptedAfterPrimaryStart;
      if (response.ok) {
        try { await responseTextBounded(response); } catch { /* Empty/opaque success is valid. */ }
        const interruptedAfterPrimaryBody = await this.stopStartupIfInterrupted();
        if (interruptedAfterPrimaryBody) return interruptedAfterPrimaryBody;
      } else {
        const text = await responseTextBounded(response);
        const interruptedAfterFailureBody = await this.stopStartupIfInterrupted();
        if (interruptedAfterFailureBody) return interruptedAfterFailureBody;
        if (!isExplicitPrimaryGPUCapacityFailure(response.status, text)) {
          await this.classifyRunPodResponse(new Response(text, {
            status: response.status,
            headers: response.headers,
          }));
        }
        this.primaryStartFetchInvoked = false;
        this.snapshot.primaryStartDispatched = false;
        this.snapshot.startupControlPhase = "temporary_create";
        await this.persist();
        const interruptedBeforeTemporaryCreate = await this.stopStartupIfInterrupted();
        if (interruptedBeforeTemporaryCreate) return interruptedBeforeTemporaryCreate;
        const temporaryOutcome = await this.createTemporaryPod(primaryPod);
        if (temporaryOutcome.error || temporaryOutcome.visibilityPending) {
          return temporaryOutcome;
        }
      }
      this.snapshot.restartable = false;
      this.snapshot.idleSince = null;
      this.primaryStartFetchInvoked = false;
      this.snapshot.startupControlPhase = "monitoring";
      await this.transition("preparing", "waiting_for_pod", null);
      const interruptedAfterMonitoring = await this.stopStartupIfInterrupted();
      if (interruptedAfterMonitoring) return interruptedAfterMonitoring;
      return { error: null };
    } catch (error) {
      const classified = error instanceof RunPodError
        ? error
        : new RunPodError("runpod_start_failed", START_FAILURE_MESSAGE);
      return this.enterStartupFailure(classified.code, classified.publicMessage);
    }
  }

  hasActiveWork() {
    return Object.keys(this.snapshot.activeTasks).length > 0
      || Object.keys(this.snapshot.inFlightRequests).length > 0;
  }

  async stop() {
    if (this.snapshot.state === "closed") return true;
    if (this.snapshot.shutdownRequest?.kind === "user"
      && !this.snapshot.shutdownRequest.attempted) return true;
    if (this.snapshot.state !== "ready" || this.hasActiveWork()) return false;
    const now = this.now();
    this.snapshot.shutdownRequest = {
      kind: "user",
      dueAt: now + EXPLICIT_STOP_DELAY_MS,
      attempted: false,
    };
    this.snapshot.idleSince = null;
    await this.transition("preparing", "shutdown_delay", STOP_DELAY_MESSAGE);
    await this.scheduleAlarm(this.snapshot.shutdownRequest.dueAt);
    return true;
  }

  async cancelPendingShutdownForActivity() {
    if (!this.snapshot.shutdownRequest || this.snapshot.shutdownRequest.attempted) return;
    if (["startup_cleanup", "startup_primary_cleanup"]
      .includes(this.snapshot.shutdownRequest.kind)) return;
    const wasUserRequest = this.snapshot.shutdownRequest.kind === "user";
    this.snapshot.shutdownRequest = null;
    this.snapshot.idleSince = null;
    if (wasUserRequest && this.snapshot.state === "preparing") {
      this.snapshot.state = "ready";
      this.snapshot.internalPhase = "ready";
      this.snapshot.message = null;
      this.snapshot.updatedAt = iso(this.now());
    }
    await this.persist();
  }

  async scheduleIdleShutdown({ allowInFlight = false } = {}) {
    const hasTasks = Object.keys(this.snapshot.activeTasks).length > 0;
    const hasRequests = Object.keys(this.snapshot.inFlightRequests).length > 0;
    if (this.snapshot.state !== "ready"
      || hasTasks
      || (hasRequests && !allowInFlight)) return;
    if (this.snapshot.shutdownRequest?.kind === "user") return;
    if (this.snapshot.shutdownRequest?.kind === "idle") return;
    const now = this.now();
    this.snapshot.idleSince = now;
    this.snapshot.shutdownRequest = {
      kind: "idle",
      dueAt: now + IDLE_TIMEOUT_MS,
      attempted: false,
    };
    await this.persist();
    await this.scheduleAlarm(this.snapshot.shutdownRequest.dueAt);
  }

  async executeShutdown(kind) {
    const podId = normalizePodId(this.snapshot.currentPodId);
    if (!podId) {
      this.snapshot.shutdownRequest = null;
      this.snapshot.restartable = false;
      await this.transition("closed", "runpod_configuration_missing", RUNPOD_CONFIGURATION_MESSAGE);
      await this.scheduleCanceledTaskCleanup();
      return;
    }
    if (this.hasActiveWork()) {
      await this.cancelPendingShutdownForActivity();
      return;
    }
    if (this.snapshot.shutdownRequest?.attempted) return;
    const podKind = this.snapshot.currentPodKind;
    this.snapshot.shutdownRequest = {
      kind,
      dueAt: this.snapshot.shutdownRequest?.dueAt || this.now(),
      attempted: true,
    };
    this.snapshot.lastShutdownAttemptAt = this.now();
    await this.persist();
    try {
      const response = podKind === "temporary"
        ? await this.authenticatedFetch(
          this.restURL(`/pods/${encodeURIComponent(podId)}`),
          { method: "DELETE" },
        )
        : await this.postRESTAction(podId, "stop");
      if (response.status === 404
        || (kind === "startup_primary_cleanup" && response.status === 409)) {
        try { await responseTextBounded(response); } catch { /* Fixed response. */ }
      } else {
        await this.classifyRunPodResponse(response);
        try { await responseTextBounded(response); } catch { /* Empty success is valid. */ }
      }
      this.snapshot.shutdownRequest = null;
      if (podKind === "temporary") await this.moveBackToPrimary();
      this.snapshot.restartable = podKind === "primary" && response.status !== 404;
      this.snapshot.idleSince = null;
      this.snapshot.primaryStartDispatched = false;
      this.snapshot.temporaryCreateName = null;
      this.clearStartupTracking();
      this.snapshot.activeTasks = {};
      this.snapshot.inFlightRequests = {};
      this.snapshot.idleShutdownPending = false;
      await this.transition(
        "closed",
        podKind === "temporary"
          ? (kind === "idle"
            ? "idle_terminated"
            : kind === "startup_cleanup"
              ? "startup_cleanup_terminated"
              : "user_terminated")
          : (kind === "idle"
            ? "idle_stopped"
            : kind === "startup_primary_cleanup"
              ? "startup_primary_cleanup_stopped"
              : "user_stopped"),
        null,
      );
      await this.scheduleCanceledTaskCleanup();
    } catch (error) {
      const classified = error instanceof RunPodError
        ? error
        : new RunPodError("runpod_stop_failed", STOP_FAILURE_MESSAGE);
      this.snapshot.shutdownRequest = null;
      this.snapshot.primaryStartDispatched = false;
      this.snapshot.temporaryCreateName = null;
      this.snapshot.restartable = false;
      this.snapshot.idleSince = null;
      await this.transition("ready", classified.code, classified.publicMessage);
      await this.scheduleCanceledTaskCleanup();
    }
  }

  async beginRequestActivity(resetsIdleCountdown) {
    const now = this.now();
    const leaseId = crypto.randomUUID();
    this.snapshot.lastActivityAt = now;
    if (resetsIdleCountdown) {
      this.snapshot.idleShutdownPending = false;
      await this.cancelPendingShutdownForActivity();
      this.snapshot.idleSince = null;
    }
    this.snapshot.inFlightRequests[leaseId] = {
      startedAt: now,
      scan: resetsIdleCountdown,
    };
    await this.persist();
    await this.scheduleAlarm(now + ACTIVE_RECHECK_MS);
    return leaseId;
  }

  async endRequestActivity(leaseId) {
    const lease = this.snapshot.inFlightRequests[leaseId];
    delete this.snapshot.inFlightRequests[leaseId];
    const now = this.now();
    this.snapshot.lastActivityAt = now;
    const shouldScheduleIdle = safeObject(lease)?.scan === true
      || this.snapshot.idleShutdownPending === true;
    if (!this.hasActiveWork() && shouldScheduleIdle) {
      this.snapshot.idleShutdownPending = false;
    }
    await this.persist();
    if (this.hasActiveWork()) {
      await this.scheduleAlarm(now + ACTIVE_RECHECK_MS);
    } else if (shouldScheduleIdle) {
      await this.scheduleIdleShutdown();
    }
  }

  pruneCanceledTasks() {
    const now = this.now();
    let changed = false;
    for (const [taskId, expiresAt] of Object.entries(this.snapshot.canceledTasks)) {
      if (!Number.isFinite(expiresAt) || expiresAt <= now) {
        delete this.snapshot.canceledTasks[taskId];
        changed = true;
      }
    }
    return changed;
  }

  isTaskCanceled(taskId) {
    return Number.isFinite(this.snapshot.canceledTasks[taskId])
      && this.snapshot.canceledTasks[taskId] > this.now();
  }

  nextCanceledTaskExpiration() {
    const expirations = Object.values(this.snapshot.canceledTasks)
      .filter((expiresAt) => Number.isFinite(expiresAt));
    return expirations.length > 0 ? Math.min(...expirations) : null;
  }

  async scheduleCanceledTaskCleanup() {
    const expiresAt = this.nextCanceledTaskExpiration();
    if (expiresAt) await this.scheduleAlarm(expiresAt);
  }

  canceledTaskResponse(route) {
    return route.kind === "status"
      ? canceledStatusResponse(route.taskId)
      : canceledResultResponse(route.taskId);
  }

  async cancelTask(taskId, canceledTasksPruned = false) {
    const alreadyCanceled = this.isTaskCanceled(taskId);
    const isActive = Object.prototype.hasOwnProperty.call(
      this.snapshot.activeTasks,
      taskId,
    );
    if (!alreadyCanceled && !isActive) {
      if (canceledTasksPruned) await this.persist();
      await this.scheduleCanceledTaskCleanup();
      return fixedError(BACKEND_NOT_FOUND_ERROR, 404);
    }
    if (!alreadyCanceled) {
      this.snapshot.canceledTasks[taskId] = this.now() + CANCELED_TASK_TTL_MS;
    }
    if (isActive) delete this.snapshot.activeTasks[taskId];
    const hasTasks = Object.keys(this.snapshot.activeTasks).length > 0;
    const hasRequests = Object.keys(this.snapshot.inFlightRequests).length > 0;
    if (!hasTasks && hasRequests && !this.snapshot.shutdownRequest) {
      this.snapshot.idleShutdownPending = true;
    }
    if (!alreadyCanceled || isActive || canceledTasksPruned) await this.persist();
    await this.scheduleCanceledTaskCleanup();
    if (!this.hasActiveWork()) {
      await this.scheduleIdleShutdown();
    } else {
      await this.scheduleAlarm(this.now() + ACTIVE_RECHECK_MS);
    }
    return json({
      ok: true,
      status: "canceled",
      task_id: taskId,
      upstream_cancel_supported: false,
    });
  }

  async applyProxyObservation(observation) {
    if (observation?.kind === "task_started") {
      if (this.isTaskCanceled(observation.taskId)) return;
      await this.cancelPendingShutdownForActivity();
      this.snapshot.activeTasks[observation.taskId] = this.now();
      this.snapshot.idleSince = null;
      await this.persist();
      await this.scheduleAlarm(this.now() + ACTIVE_RECHECK_MS);
    } else if (observation?.kind === "task_finished"
      && this.snapshot.activeTasks[observation.taskId]) {
      delete this.snapshot.activeTasks[observation.taskId];
      await this.persist();
      if (Object.keys(this.snapshot.activeTasks).length === 0) {
        await this.scheduleIdleShutdown({ allowInFlight: true });
      }
    }
  }

  releaseRequestLease(leaseId) {
    const operation = this.withControl(() => this.endRequestActivity(leaseId));
    if (typeof this.ctx.waitUntil === "function") this.ctx.waitUntil(operation);
    return operation;
  }

  responseWithLease(response, leaseId) {
    if (!response.body) return this.releaseRequestLease(leaseId).then(() => response);
    const reader = response.body.getReader();
    let released = false;
    const releaseOnce = async () => {
      if (released) return;
      released = true;
      await this.releaseRequestLease(leaseId);
    };
    const body = new ReadableStream({
      async pull(controller) {
        try {
          const { done, value } = await reader.read();
          if (done) {
            controller.close();
            await releaseOnce();
            return;
          }
          controller.enqueue(value);
        } catch (error) {
          controller.error(error);
          await releaseOnce();
        }
      },
      async cancel(reason) {
        try {
          await reader.cancel(reason);
        } finally {
          await releaseOnce();
        }
      },
    });
    return new Response(body, {
      status: response.status,
      statusText: response.statusText,
      headers: response.headers,
    });
  }

  async proxy(request) {
    const startedAt = this.monotonicNow();
    const pathname = new URL(request.url).pathname;
    const route = productionRoute(request);
    if (route.error) return route.error;
    const admission = await this.withControl(async () => {
      const canceledTasksPruned = this.pruneCanceledTasks();
      if (route.kind === "cancel") {
        return {
          response: await this.cancelTask(route.taskId, canceledTasksPruned),
        };
      }
      if ((route.kind === "status" || route.kind === "result")
        && this.isTaskCanceled(route.taskId)) {
        if (canceledTasksPruned) await this.persist();
        return { response: this.canceledTaskResponse(route) };
      }
      if (canceledTasksPruned) await this.persist();
      if (route.kind === "process") await this.cancelPendingShutdownForActivity();
      if (this.snapshot.state !== "ready" || this.snapshot.shutdownRequest?.attempted) {
        return { error: fixedError(
          this.snapshot.state === "closed"
            ? "scanner_backend_offline"
            : "scanner_backend_starting",
        ) };
      }
      const podId = normalizePodId(this.snapshot.currentPodId);
      if (!podId) return { error: fixedError("scanner_runtime_unavailable") };
      const backendToken = this.backendAPIToken();
      if (!backendToken) return { error: fixedError(BACKEND_CONFIGURATION_ERROR) };
      const leaseId = await this.beginRequestActivity(pathname === "/api/process");
      return { podId, backendToken, leaseId };
    });
    const admittedAt = this.monotonicNow();
    if (admission.error) return admission.error;
    if (admission.response) return admission.response;
    try {
      const upstreamStartedAt = this.monotonicNow();
      const upstreamResponse = await this.fetchImpl(
        productionUpstreamRequest(
          request,
          admission.podId,
          admission.backendToken,
          route,
        ),
      );
      const upstreamFinishedAt = this.monotonicNow();
      const { response, observation } = await adaptProductionResponse(
        route,
        upstreamResponse,
      );
      if (observation) await this.withControl(() => this.applyProxyObservation(observation));
      const finishedAt = this.monotonicNow();
      const totalMs = finishedAt - startedAt;
      if (route.kind !== "status"
        || observation?.kind === "task_finished"
        || response.status !== 200
        || totalMs >= SLOW_PROXY_TIMING_MS) {
        this.logTiming("proxy", {
          kind: route.kind,
          status: response.status,
          admission_ms: admittedAt - startedAt,
          upstream_ms: upstreamFinishedAt - upstreamStartedAt,
          adapt_ms: finishedAt - upstreamFinishedAt,
          total_ms: totalMs,
        });
      }
      // Process and status bodies are fully buffered and validated above. The
      // upstream request has finished, so holding a durable lease until the
      // client consumes a tiny JSON response only risks a stale 30-minute
      // lease when the client disconnects. Result images remain streaming and
      // retain their lease until EOF/cancel.
      if (route.kind !== "result") {
        await this.withControl(() => this.endRequestActivity(admission.leaseId));
        return response;
      }
      return this.responseWithLease(response, admission.leaseId);
    } catch {
      const clientCanceled = request.signal.aborted;
      const failedAt = this.monotonicNow();
      this.logTiming("proxy", {
        kind: route.kind,
        status: 502,
        admission_ms: admittedAt - startedAt,
        total_ms: failedAt - startedAt,
      });
      await this.withControl(async () => {
        await this.endRequestActivity(admission.leaseId);
        if (!clientCanceled) {
          await this.transition("preparing", "backend_unavailable", STATUS_FAILURE_MESSAGE);
        }
      });
      return fixedError("scanner_upstream_unavailable", 502);
    }
  }

  async checkActiveTask(podId, taskId) {
    const backendToken = this.backendAPIToken();
    if (!backendToken) return true;
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), HEALTH_TIMEOUT_MS);
    try {
      const response = await this.fetchImpl(new Request(
        `https://${podId}-${RUNPOD_HTTP_PORT}.proxy.runpod.net/v1/jobs/${encodeURIComponent(taskId)}`,
        {
          headers: { authorization: `Bearer ${backendToken}` },
          redirect: "manual",
        },
      ), { signal: controller.signal });
      if (response.status === 404) return false;
      if (!response.ok) return true;
      return !TERMINAL_TASK_STATES.has(
        taskStatusFromBody(await responseJSONBounded(response)),
      );
    } catch {
      return true;
    } finally {
      clearTimeout(timeout);
    }
  }

  async refreshActiveTasks(podId) {
    const startedAt = this.monotonicNow();
    this.pruneCanceledTasks();
    const taskIds = [];
    for (const taskId of Object.keys(this.snapshot.activeTasks)) {
      if (this.isTaskCanceled(taskId)) {
        delete this.snapshot.activeTasks[taskId];
        continue;
      }
      taskIds.push(taskId);
    }
    const concurrency = Math.min(
      this.activeTaskCheckConcurrency(),
      taskIds.length,
    );
    const activeTaskVersions = taskIds.map((taskId) => this.snapshot.activeTasks[taskId]);
    const activeResults = await this.checkActiveTasks(podId, taskIds, concurrency);
    this.applyActiveTaskChecks(taskIds, activeResults, activeTaskVersions);
    await this.persist();
    this.logTiming("active_task_refresh", {
      jobs: taskIds.length,
      concurrency,
      total_ms: this.monotonicNow() - startedAt,
    });
  }

  async checkActiveTasks(podId, taskIds, concurrency) {
    const activeResults = new Array(taskIds.length);
    let nextIndex = 0;
    const checkNext = async () => {
      while (nextIndex < taskIds.length) {
        const index = nextIndex;
        nextIndex += 1;
        activeResults[index] = await this.checkActiveTask(podId, taskIds[index]);
      }
    };
    await Promise.all(Array.from({ length: concurrency }, () => checkNext()));
    return activeResults;
  }

  applyActiveTaskChecks(taskIds, activeResults, activeTaskVersions) {
    for (let index = 0; index < taskIds.length; index += 1) {
      const taskId = taskIds[index];
      if (!activeResults[index]
        && this.snapshot.activeTasks[taskId] === activeTaskVersions[index]) {
        delete this.snapshot.activeTasks[taskId];
      }
    }
  }

  matchesShutdownRefreshSnapshot(action) {
    const current = this.snapshot.shutdownRequest;
    const expected = action.shutdownRequest;
    return safeObject(current)
      && current.kind === expected.kind
      && current.dueAt === expected.dueAt
      && current.attempted === expected.attempted
      && normalizePodId(this.snapshot.currentPodId) === action.podId
      && this.snapshot.currentPodKind === action.podKind;
  }

  async runAlarm() {
    const now = this.now();
    const canceledTasksPruned = this.pruneCanceledTasks();
    if (canceledTasksPruned) await this.persist();
    // A lifecycle alarm may intentionally run before canceled-task expiry.
    // Re-register the TTL candidate first; later lifecycle candidates use the
    // same minimum-deadline scheduler and may safely take precedence again.
    await this.scheduleCanceledTaskCleanup();
    if (this.snapshot.shutdownRequest) {
      if (this.snapshot.shutdownRequest.attempted) {
        await this.scheduleCanceledTaskCleanup();
        return;
      }
      if (now < this.snapshot.shutdownRequest.dueAt) {
        await this.scheduleAlarm(this.snapshot.shutdownRequest.dueAt);
        return;
      }
      const kind = this.snapshot.shutdownRequest.kind;
      const podId = normalizePodId(this.snapshot.currentPodId);
      if (podId && Object.keys(this.snapshot.activeTasks).length > 0) {
        const taskIds = Object.keys(this.snapshot.activeTasks);
        return {
          kind: "refresh_active_tasks_for_shutdown",
          podId,
          podKind: this.snapshot.currentPodKind,
          shutdownRequest: { ...this.snapshot.shutdownRequest },
          taskIds,
          activeTaskVersions: taskIds.map((taskId) => this.snapshot.activeTasks[taskId]),
          concurrency: Math.min(this.activeTaskCheckConcurrency(), taskIds.length),
          startedAt: this.monotonicNow(),
        };
      }
      if (this.hasActiveWork()) {
        await this.cancelPendingShutdownForActivity();
        await this.scheduleAlarm(now + ACTIVE_RECHECK_MS);
        return;
      }
      await this.executeShutdown(kind);
      return;
    }
    if (this.isTemporaryCreateIntent() || this.isPrimaryDispatchIntent()) {
      const outcome = this.isTemporaryCreateIntent()
        ? await this.recoverTemporaryCreateIntent()
        : await this.recoverPrimaryDispatchIntent();
      if (outcome.error) {
        this.broadcastStartupSnapshot({ ok: false, error: outcome.error, close: true });
      } else if (this.snapshot.state === "ready") {
        this.broadcastStartupSnapshot({ close: true });
      } else {
        this.broadcastStartupSnapshot();
        if (this.hasStartupSockets()) {
          await this.scheduleAlarm(now + START_RECHECK_MS);
        }
      }
      return;
    }
    if (this.snapshot.state === "preparing"
      && Number.isFinite(this.snapshot.startupDeadlineAt)
      && !this.hasStartupSockets()) {
      await this.enterStartupFailure(
        "startup_disconnected",
        STARTUP_DISCONNECTED_MESSAGE,
      );
      return;
    }
    if (this.snapshot.state === "preparing" && this.hasStartupSockets()) {
      const outcome = await this.reconcileRuntime({ startup: true });
      if (outcome.error) {
        this.broadcastStartupSnapshot({ ok: false, error: outcome.error, close: true });
      } else if (this.snapshot.state === "ready") {
        this.broadcastStartupSnapshot({ close: true });
      } else {
        this.broadcastStartupSnapshot();
        if (this.hasStartupSockets()) {
          await this.scheduleAlarm(now + START_RECHECK_MS);
        }
      }
      return;
    }
    if (this.snapshot.state !== "ready") {
      if (this.snapshot.state === "closed") await this.scheduleCanceledTaskCleanup();
      return;
    }
    for (const [leaseId, storedLease] of Object.entries(this.snapshot.inFlightRequests)) {
      const startedAt = Number.isFinite(storedLease)
        ? storedLease
        : Number(safeObject(storedLease)?.startedAt);
      if (!Number.isFinite(startedAt) || now - startedAt >= IN_FLIGHT_LEASE_MS) {
        delete this.snapshot.inFlightRequests[leaseId];
      }
    }
    if (Object.keys(this.snapshot.inFlightRequests).length > 0) {
      await this.persist();
      await this.scheduleAlarm(now + ACTIVE_RECHECK_MS);
      return;
    }
    if (this.snapshot.idleShutdownPending
      && Object.keys(this.snapshot.activeTasks).length === 0) {
      this.snapshot.idleShutdownPending = false;
      await this.scheduleIdleShutdown();
      return;
    }
    const podId = normalizePodId(this.snapshot.currentPodId);
    const hadActiveTasks = Object.keys(this.snapshot.activeTasks).length > 0;
    if (podId && hadActiveTasks) {
      const taskIds = Object.keys(this.snapshot.activeTasks);
      return {
        kind: "refresh_active_tasks",
        podId,
        taskIds,
        activeTaskVersions: taskIds.map((taskId) => this.snapshot.activeTasks[taskId]),
        concurrency: Math.min(this.activeTaskCheckConcurrency(), taskIds.length),
        startedAt: this.monotonicNow(),
      };
    }
    if (Object.keys(this.snapshot.activeTasks).length > 0) {
      await this.scheduleAlarm(now + ACTIVE_RECHECK_MS);
      return;
    }
    if (hadActiveTasks) {
      await this.scheduleIdleShutdown();
    }
  }

  async alarm() {
    await this.ensureLoaded();
    const action = await this.withControl(() => this.runAlarm());
    if (action?.kind !== "refresh_active_tasks"
      && action?.kind !== "refresh_active_tasks_for_shutdown") return action;

    // Recovery status reads can each wait up to HEALTH_TIMEOUT_MS. Perform the
    // bounded I/O outside the lifecycle control queue so uploads, polling, and
    // result downloads are not stalled behind recovery-only network waits.
    const activeResults = await this.checkActiveTasks(
      action.podId,
      action.taskIds,
      action.concurrency,
    );
    return this.withControl(async () => {
      this.applyActiveTaskChecks(
        action.taskIds,
        activeResults,
        action.activeTaskVersions,
      );
      await this.persist();
      this.logTiming("active_task_refresh", {
        jobs: action.taskIds.length,
        concurrency: action.concurrency,
        total_ms: this.monotonicNow() - action.startedAt,
      });
      if (action.kind === "refresh_active_tasks_for_shutdown") {
        // A cleared/replaced shutdown request is a tombstone for this stale
        // recovery result. Pod identity and the full request tuple provide the
        // version guard without letting a late status check stop a newer target.
        if (!this.matchesShutdownRefreshSnapshot(action)) return;
        if (this.hasActiveWork()) {
          await this.cancelPendingShutdownForActivity();
          await this.scheduleAlarm(this.now() + ACTIVE_RECHECK_MS);
          return;
        }
        await this.executeShutdown(action.shutdownRequest.kind);
        return;
      }
      if (this.snapshot.state !== "ready") return;
      if (Object.keys(this.snapshot.activeTasks).length > 0) {
        await this.scheduleAlarm(this.now() + ACTIVE_RECHECK_MS);
      } else {
        await this.scheduleIdleShutdown();
      }
    });
  }

  async fetch(request) {
    await this.ensureLoaded();
    const url = new URL(request.url);
    if (url.pathname === "/api/scanner/runtime") {
      if (request.method !== "GET") return fixedError("method_not_allowed", 405);
      return json(await this.readOnlyRuntimeProbe());
    }
    if (url.pathname === "/api/scanner/runtime/start") {
      const isWebSocket = request.method === "GET"
        && request.headers.get("upgrade")?.toLowerCase() === "websocket";
      if (isWebSocket) return this.openStartupSocket();
      return fixedError("websocket_upgrade_required", 426);
    }
    if (url.pathname === "/api/scanner/runtime/stop") {
      if (request.method !== "POST") return fixedError("method_not_allowed", 405);
      return this.withControl(async () => {
        const accepted = await this.stop();
        if (!accepted) return json(busyBody(this.snapshot), 409);
        const body = runtimeBody(this.snapshot);
        return json(body, body.state === "preparing" ? 202 : 200);
      });
    }
    return this.proxy(request);
  }
}

export const scannerRuntimeConstants = {
  IDLE_TIMEOUT_MS,
  EXPLICIT_STOP_DELAY_MS,
  ACTIVE_RECHECK_MS,
  START_RECHECK_MS,
  DEFAULT_ACTIVE_TASK_CHECK_CONCURRENCY,
  MAX_ACTIVE_TASK_CHECK_CONCURRENCY,
};
