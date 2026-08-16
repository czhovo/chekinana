import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

import { handleRequest } from "../src/worker.js";
import { ScannerRuntime, scannerRuntimeConstants } from "../src/scanner-runtime.js";

const POD_ID = "configuredpod";
const NEW_POD_ID = "updatedpod";
const TEMPORARY_POD_ID = "temporarypod";
const NOW = Date.parse("2026-08-05T12:00:00.000Z");

class FakeStorage {
  constructor(initialSnapshot = null) {
    this.values = new Map();
    if (initialSnapshot) this.values.set("scanner-runtime-v1", structuredClone(initialSnapshot));
    this.alarm = null;
    this.puts = 0;
  }

  async get(key) { return structuredClone(this.values.get(key)); }
  async put(key, value) {
    this.puts += 1;
    this.values.set(key, structuredClone(value));
  }
  async getAlarm() { return this.alarm; }
  async setAlarm(value) { this.alarm = value; }
}

class FakeContext {
  constructor(initialSnapshot) {
    this.storage = new FakeStorage(initialSnapshot);
    this.ready = Promise.resolve();
    this.background = [];
    this.startupSockets = [{ readyState: 1 }];
  }

  blockConcurrencyWhile(callback) { this.ready = callback(); }
  waitUntil(operation) { this.background.push(operation); }
  getWebSockets() { return this.startupSockets; }
}

function snapshot(overrides = {}) {
  return {
    version: 4,
    currentPodId: POD_ID,
    currentPodKind: "primary",
    state: "closed",
    internalPhase: "pod_exited",
    message: null,
    updatedAt: new Date(NOW).toISOString(),
    restartable: true,
    gpuCount: 1,
    idleSince: null,
    lastActivityAt: null,
    activeTasks: {},
    inFlightRequests: {},
    shutdownRequest: null,
    startupStartedAt: null,
    startupDeadlineAt: null,
    startupControlPhase: null,
    primaryStartDispatched: false,
    temporaryCreateName: null,
    lastShutdownAttemptAt: null,
    ...overrides,
  };
}

function createHarness(fetchImpl, options = {}) {
  let now = options.now ?? NOW;
  const ctx = new FakeContext(options.initialSnapshot || null);
  const env = {
    RUNPOD_API_KEY: "test-only-runpod-key",
    RUNPOD_POD_ID: POD_ID,
    RUNPOD_TEMPLATE_ID: "test-template",
    RUNPOD_NETWORK_VOLUME_ID: "test-volume",
    CHEKI_BACKEND_API_TOKEN: "test-only-backend-token",
    __TEST_FETCH: fetchImpl,
    __TEST_NOW: () => now,
    __TEST_UUID: () => "00000000-0000-4000-8000-000000000001",
    ...(options.runtimeEnv || {}),
  };
  const runtime = new ScannerRuntime(ctx, env);
  const performAlarm = runtime.alarm.bind(runtime);
  runtime.alarm = async (...arguments_) => {
    // Cloudflare consumes the current alarm before invoking the handler.
    ctx.storage.alarm = null;
    return performAlarm(...arguments_);
  };
  const binding = {
    idFromName(name) {
      assert.equal(name, "production");
      return "runtime";
    },
    get(id) {
      assert.equal(id, "runtime");
      return { fetch: async (request) => {
        await ctx.ready;
        return runtime.fetch(request);
      } };
    },
  };
  return {
    runtime,
    ctx,
    workerEnv: { SCANNER_RUNTIME: binding },
    now: () => now,
    setNow: (value) => { now = value; },
    advance: (value) => { now += value; },
    async flushBackground() {
      while (ctx.background.length > 0) {
        const operations = ctx.background.splice(0);
        await Promise.all(operations);
      }
    },
    async snapshot() {
      await ctx.ready;
      return ctx.storage.get("scanner-runtime-v1");
    },
  };
}

function requestDetails(value, init = {}) {
  const request = value instanceof Request ? value : null;
  return {
    url: new URL(request ? request.url : value),
    method: init.method || request?.method || "GET",
    headers: new Headers(init.headers || request?.headers),
    body: init.body,
  };
}

function runPodAction(request) {
  return /\/(start|stop)$/u.exec(request.url.pathname)?.[1] || null;
}

async function reconciledBody(harness) {
  const response = await handleRequest(
    new Request("https://api.chekinana.top/api/scanner/runtime"),
    harness.workerEnv,
  );
  return response.json();
}

async function startupSnapshotBody(harness, options = {}) {
  await harness.ctx.ready;
  let body = null;
  const sent = harness.runtime.sendStartupSnapshot({
    send(value) { body = JSON.parse(value); },
  }, options);
  assert.equal(sent, true);
  return body;
}

function exitedPod(overrides = {}) {
  return {
    id: POD_ID,
    desiredStatus: "EXITED",
    gpuCount: 2,
    machine: { gpuTypeId: "NVIDIA RTX A5000" },
    ...overrides,
  };
}

function backendCoordinateSystem(overrides = {}) {
  return {
    space: "exif_transposed_original_pixels",
    origin: "top_left",
    x_axis: "right",
    y_axis: "down",
    quad_order: ["top_left", "top_right", "bottom_right", "bottom_left"],
    ...overrides,
  };
}

function succeededJob(taskId, overrides = {}) {
  return {
    job_id: taskId,
    status: "succeeded",
    result_count: 1,
    source_image: { width: 1000, height: 800 },
    coordinate_system: backendCoordinateSystem(),
    results: [{
      index: 1,
      filename: "cheki_001.png",
      url: `/v1/jobs/${taskId}/results/1`,
      quadrilateral: [[1, 2], [101, 2], [101, 202], [1, 202]],
    }],
    ...overrides,
  };
}

test("runtime constants preserve twenty-second explicit delay and four-minute idle stop", () => {
  assert.equal(scannerRuntimeConstants.EXPLICIT_STOP_DELAY_MS, 20_000);
  assert.equal(scannerRuntimeConstants.IDLE_TIMEOUT_MS, 240_000);
});

test("GET maps EXITED to closed and restartable with one v1 Pod lookup", async () => {
  const harness = createHarness(async (value, init) => {
    const request = requestDetails(value, init);
    assert.equal(
      request.url.href,
      `https://rest.runpod.io/v1/pods/${POD_ID}?includeMachine=true`,
    );
    assert.equal(request.method, "GET");
    assert.equal(request.headers.get("authorization"), "Bearer test-only-runpod-key");
    return Response.json(exitedPod());
  });
  const body = await reconciledBody(harness);
  assert.deepEqual(body, {
    ok: true,
    state: "closed",
    phase: "closed",
    message: null,
    retryAllowed: true,
    canStart: true,
    canTerminate: false,
    updatedAt: new Date(NOW).toISOString(),
  });
  assert.equal(await harness.snapshot(), undefined);
});

test("GET maps RUNNING plus healthy backend to ready and accepts legacy gpu.count", async () => {
  const harness = createHarness(async (value, init) => {
    const request = requestDetails(value, init);
    if (request.url.origin === "https://rest.runpod.io") {
      return Response.json(exitedPod({
        desiredStatus: "RUNNING",
        gpuCount: undefined,
        gpu: { count: 3 },
      }));
    }
    assert.equal(request.url.pathname, "/health");
    assert.equal(request.headers.get("authorization"), "Bearer test-only-backend-token");
    assert.equal(request.headers.get("x-cheki-token"), null);
    return Response.json({ status: "ok", model_loaded: true, device: "cuda" });
  });
  const body = await reconciledBody(harness);
  assert.equal(body.state, "ready");
  assert.equal(body.phase, "ready");
  assert.equal(body.canStart, false);
  assert.equal(body.canTerminate, true);
  assert.equal(body.progress, undefined);
  assert.equal(await harness.snapshot(), undefined);
});

test("GET maps Pod provisioning to preparing step 2 with no extra lookup", async () => {
  let calls = 0;
  const harness = createHarness(async () => {
    calls += 1;
    return Response.json(exitedPod({ desiredStatus: "PROVISIONING" }));
  });
  const body = await reconciledBody(harness);
  assert.deepEqual(body.progress, { current: 2, total: 3 });
  assert.equal(calls, 1);
  assert.equal(await harness.snapshot(), undefined);
});

test("GET maps RUNNING with an unready backend to preparing", async () => {
  const harness = createHarness(async (value) => {
    const url = new URL(value instanceof Request ? value.url : value);
    if (url.origin === "https://rest.runpod.io") {
      return Response.json(exitedPod({ desiredStatus: "RUNNING" }));
    }
    return new Response(null, { status: 503 });
  });
  const body = await reconciledBody(harness);
  assert.equal(body.state, "preparing");
  assert.equal(body.phase, "preparing");
  assert.equal(body.canStart, false);
  assert.equal(body.canTerminate, false);
  assert.deepEqual(body.progress, { current: 3, total: 3 });
});

for (const [label, healthResponse] of [
  ["non-200", Response.json({ status: "ok", model_loaded: true, device: "cuda" }, { status: 201 })],
  ["model not loaded", Response.json({ status: "ok", model_loaded: false, device: "cuda" })],
  ["non-CUDA device", Response.json({ status: "ok", model_loaded: true, device: "cpu" })],
]) {
  test(`Backend readiness fails closed for ${label}`, async () => {
    const harness = createHarness(async (value) => {
      const url = new URL(value instanceof Request ? value.url : value);
      return url.origin === "https://rest.runpod.io"
        ? Response.json(exitedPod({ desiredStatus: "RUNNING" }))
        : healthResponse.clone();
    });
    const body = await reconciledBody(harness);
    assert.equal(body.state, "preparing");
    assert.equal(body.canTerminate, false);
    assert.deepEqual(body.progress, { current: 3, total: 3 });
  });
}

for (const [label, response, expectedMessage] of [
  ["404", new Response("private missing", { status: 404 }), "未找到已配置的 RunPod Pod。请更新 Worker 的 RunPod Pod 配置。"],
  ["TERMINATED", Response.json(exitedPod({ desiredStatus: "TERMINATED" })), "已配置的 RunPod Pod 已被终止。请更新 Worker 的 RunPod Pod 配置。"],
]) {
  test(`GET maps ${label} to non-restartable closed`, async () => {
    const harness = createHarness(async () => response.clone());
    const body = await reconciledBody(harness);
    assert.equal(body.state, "closed");
    assert.equal(body.phase, "closed");
    assert.equal(body.canStart, false);
    assert.equal(body.canTerminate, false);
    assert.equal(body.message, expectedMessage);
    assert.equal(JSON.stringify(body).includes("private"), false);
  });
}

for (const [label, value] of [
  ["empty object", {}],
  ["envelope", { pod: exitedPod() }],
  ["missing desiredStatus", { id: POD_ID }],
  ["blank desiredStatus", { id: POD_ID, desiredStatus: " " }],
  ["unknown desiredStatus", { id: POD_ID, desiredStatus: "PAUSED" }],
]) {
  test(`GET safely rejects ${label} without creating replacement state`, async () => {
    const harness = createHarness(async () => Response.json(value));
    const body = await reconciledBody(harness);
    assert.equal(body.state, "preparing");
    assert.equal(body.phase, "preparing");
    assert.equal(body.canStart, false);
    assert.equal(body.message, "RunPod 状态响应无法识别，请检查服务端 API 合同。");
    assert.equal(await harness.snapshot(), undefined);
  });
}

test("GET exposes fixed safe configuration and timeout messages", async (t) => {
  await t.test("configuration", async () => {
    let calls = 0;
    const harness = createHarness(async () => {
      calls += 1;
      throw new Error("must not fetch");
    }, { runtimeEnv: { RUNPOD_API_KEY: "" } });
    const body = await reconciledBody(harness);
    assert.equal(body.state, "closed");
    assert.equal(body.canStart, false);
    assert.equal(body.message, "Worker 的 RunPod 状态查询配置缺失，请检查服务端配置。");
    assert.equal(calls, 0);
  });
  await t.test("timeout", async () => {
    const harness = createHarness(async () => {
      throw new DOMException("private", "AbortError");
    });
    const body = await reconciledBody(harness);
    assert.equal(body.state, "preparing");
    assert.equal(body.message, "RunPod 状态查询超时，请稍后重试。");
    assert.equal(body.progress, undefined);
    assert.equal(JSON.stringify(body).includes("private"), false);
  });
});

test("public startup progress maps persisted primary, fallback, restore, and legacy phases", async () => {
  const cases = [
    ["primary inspection", snapshot({
      state: "preparing",
      internalPhase: "inspecting_primary",
      restartable: false,
    }), 1],
    ["primary dispatch", snapshot({
      state: "preparing",
      internalPhase: "primary_dispatch_intent",
      restartable: false,
      startupControlPhase: "primary_dispatch_intent",
    }), 1],
    ["fallback request", snapshot({
      state: "preparing",
      internalPhase: "temporary_create_intent",
      restartable: false,
      startupControlPhase: "temporary_create_intent",
    }), 1],
    ["primary provisioning", snapshot({
      state: "preparing",
      internalPhase: "waiting_for_pod",
      restartable: false,
    }), 2],
    ["fallback recovery", snapshot({
      state: "preparing",
      internalPhase: "temporary_create_visibility_wait",
      restartable: false,
    }), 2],
    ["backend health", snapshot({
      state: "preparing",
      internalPhase: "waiting_for_backend",
      message: "RunPod 已运行，后端仍在准备。",
      restartable: false,
    }), 3],
    ["version 3 restore", snapshot({
      version: 3,
      state: "preparing",
      internalPhase: "waiting_for_pod",
      restartable: false,
    }), 2],
    ["unknown legacy", snapshot({
      version: 2,
      state: "preparing",
      internalPhase: "legacy_starting_phase",
      message: null,
      restartable: false,
    }), 1],
  ];
  for (const [label, initialSnapshot, current] of cases) {
    const harness = createHarness(async () => new Response("unexpected"), { initialSnapshot });
    const body = await startupSnapshotBody(harness);
    assert.deepEqual(body.progress, { current, total: 3 }, label);
    assert.deepEqual(Object.keys(body.progress).sort(), ["current", "total"], label);
    assert.equal(JSON.stringify(body).includes(POD_ID), false, label);
  }
});

test("closed, ready, cleanup, and error snapshots omit startup progress", async () => {
  const cases = [
    snapshot({ state: "closed", internalPhase: "pod_exited" }),
    snapshot({ state: "ready", internalPhase: "ready", restartable: false }),
    snapshot({
      state: "preparing",
      internalPhase: "temporary_cleanup_pending",
      message: "fixed cleanup",
      restartable: false,
      shutdownRequest: { kind: "startup_cleanup", dueAt: NOW, attempted: false },
    }),
  ];
  for (const initialSnapshot of cases) {
    const harness = createHarness(async () => new Response("unexpected"), { initialSnapshot });
    assert.equal((await startupSnapshotBody(harness)).progress, undefined);
  }
  const harness = createHarness(async () => new Response("unexpected"), {
    initialSnapshot: snapshot({
      state: "preparing",
      internalPhase: "waiting_for_pod",
      restartable: false,
    }),
  });
  const body = await startupSnapshotBody(harness, {
    ok: false,
    error: "runpod_status_unavailable",
  });
  assert.equal(body.progress, undefined);
});

test("each persisted preparing transition broadcasts progress to all startup sockets", async () => {
  const harness = createHarness(async () => new Response("unexpected"), {
    initialSnapshot: snapshot({ state: "preparing", restartable: false }),
  });
  const messages = [[], []];
  harness.ctx.startupSockets = messages.map((socketMessages) => ({
    readyState: 1,
    send(value) { socketMessages.push(JSON.parse(value)); },
    close() {},
  }));
  await harness.ctx.ready;
  await harness.runtime.transition("preparing", "inspecting_primary", null);
  await harness.runtime.transition("preparing", "waiting_for_pod", null);
  await harness.runtime.transition(
    "preparing",
    "waiting_for_backend",
    "RunPod 已运行，后端仍在准备。",
  );
  for (const socketMessages of messages) {
    assert.deepEqual(
      socketMessages.map(({ progress }) => progress),
      [
        { current: 1, total: 3 },
        { current: 2, total: 3 },
        { current: 3, total: 3 },
      ],
    );
  }
});

test("a changed configured Pod ID replaces a persisted missing Pod without exposing either ID", async () => {
  const harness = createHarness(async (value) => {
    const url = new URL(value instanceof Request ? value.url : value);
    assert.equal(url.pathname, `/v1/pods/${NEW_POD_ID}`);
    return Response.json(exitedPod({ id: NEW_POD_ID }));
  }, {
    initialSnapshot: snapshot({
      currentPodId: POD_ID,
      internalPhase: "pod_not_found",
      restartable: false,
    }),
    runtimeEnv: { RUNPOD_POD_ID: NEW_POD_ID },
  });
  const body = await reconciledBody(harness);
  assert.equal(body.state, "closed");
  assert.equal(body.canStart, true);
  assert.equal(JSON.stringify(body).includes(POD_ID), false);
  assert.equal(JSON.stringify(body).includes(NEW_POD_ID), false);
});

test("reviewer P1 query failure before primary control never schedules stop", async () => {
  const calls = [];
  const harness = createHarness(async (value, init) => {
    const request = requestDetails(value, init);
    calls.push(`${request.method} ${request.url.pathname}`);
    return new Response("private upstream failure", { status: 503 });
  }, { initialSnapshot: snapshot() });
  await harness.ctx.ready;
  const outcome = await harness.runtime.start();
  assert.equal(outcome.error, "runpod_status_unavailable");
  const stored = await harness.snapshot();
  assert.equal(stored.state, "closed");
  assert.equal(stored.primaryStartDispatched, false);
  assert.equal(stored.shutdownRequest, null);
  assert.equal(harness.ctx.storage.alarm, null);
  assert.deepEqual(calls, [`GET /v1/pods/${POD_ID}`]);
});

test("reviewer P1 uncertain dispatched primary start schedules one stop", async () => {
  const calls = [];
  const harness = createHarness(async (value, init) => {
    const request = requestDetails(value, init);
    const action = runPodAction(request);
    calls.push({ method: request.method, path: request.url.pathname, action });
    if (request.method === "GET") {
      return Response.json({
        id: POD_ID, name: "chekinana", desiredStatus: "EXITED", gpu: { count: 1 },
      });
    }
    if (action === "start") throw new TypeError("private transport failure");
    assert.equal(action, "stop");
    return Response.json({ id: POD_ID, status: "EXITED" });
  }, { initialSnapshot: snapshot() });
  await harness.ctx.ready;
  const outcome = await harness.runtime.start();
  assert.equal(outcome.error, "runpod_status_unavailable");
  let stored = await harness.snapshot();
  assert.equal(stored.state, "preparing");
  assert.equal(stored.primaryStartDispatched, false);
  assert.equal(stored.shutdownRequest.kind, "startup_primary_cleanup");
  assert.equal(stored.shutdownRequest.attempted, false);
  await harness.runtime.alarm();
  stored = await harness.snapshot();
  assert.equal(stored.state, "closed");
  assert.equal(stored.shutdownRequest, null);
  await harness.runtime.alarm();
  assert.deepEqual(calls.map((call) => call.action), [null, "start", "stop"]);
});

test("reviewer P1 persists dispatch intent and watchdog before primary start fetch", async () => {
  const calls = [];
  let harness;
  harness = createHarness(async (value, init) => {
    const request = requestDetails(value, init);
    const action = runPodAction(request);
    calls.push(action);
    if (request.method === "GET") {
      return Response.json({
        id: POD_ID, name: "chekinana", desiredStatus: "EXITED", gpu: { count: 1 },
      });
    }
    assert.equal(action, "start");
    const storedBeforeFetch = await harness.snapshot();
    assert.equal(storedBeforeFetch.state, "preparing");
    assert.equal(storedBeforeFetch.startupControlPhase, "primary_dispatch_intent");
    assert.equal(storedBeforeFetch.primaryStartDispatched, true);
    assert.equal(harness.ctx.storage.alarm, NOW + scannerRuntimeConstants.START_RECHECK_MS);
    return new Response(null, { status: 200 });
  }, { initialSnapshot: snapshot() });
  await harness.ctx.ready;
  const outcome = await harness.runtime.start();
  assert.equal(outcome.error, null);
  const stored = await harness.snapshot();
  assert.equal(stored.startupControlPhase, "monitoring");
  assert.equal(stored.primaryStartDispatched, true);
  assert.deepEqual(calls, [null, "start"]);
});

test("reviewer P1 no-client crash recovery retains closed intent until deadline without stop", async () => {
  const calls = [];
  const harness = createHarness(async (value, init) => {
    const request = requestDetails(value, init);
    const action = runPodAction(request);
    calls.push({ method: request.method, path: request.url.pathname, action });
    assert.equal(request.method, "GET");
    return Response.json({
      id: POD_ID, name: "chekinana", desiredStatus: "EXITED", gpu: { count: 1 },
    });
  }, {
    initialSnapshot: snapshot({
      state: "preparing",
      internalPhase: "primary_dispatch_intent",
      restartable: false,
      startupStartedAt: NOW - 1_000,
      startupDeadlineAt: NOW + 60_000,
      startupControlPhase: "primary_dispatch_intent",
      primaryStartDispatched: true,
    }),
  });
  harness.ctx.startupSockets = [];
  harness.ctx.storage.alarm = NOW;
  await harness.ctx.ready;
  await harness.runtime.alarm();
  let stored = await harness.snapshot();
  assert.equal(stored.state, "preparing");
  assert.equal(stored.restartable, false);
  assert.equal(stored.primaryStartDispatched, true);
  assert.equal(stored.shutdownRequest, null);
  assert.equal(stored.startupDeadlineAt, NOW + 60_000);
  assert.equal(harness.ctx.storage.alarm, NOW + 10_000);

  harness.setNow(NOW + 60_000);
  await harness.runtime.alarm();
  stored = await harness.snapshot();
  assert.equal(stored.state, "closed");
  assert.equal(stored.restartable, true);
  assert.equal(stored.primaryStartDispatched, false);
  assert.equal(stored.shutdownRequest, null);
  assert.equal(stored.startupStartedAt, null);
  assert.equal(stored.startupDeadlineAt, null);
  assert.deepEqual(calls, [
    { method: "GET", path: `/v1/pods/${POD_ID}`, action: null },
    { method: "GET", path: `/v1/pods/${POD_ID}`, action: null },
  ]);
});

test("reviewer P1 delayed primary visibility becomes no-client at-most-once stop", async () => {
  const calls = [];
  let probeCount = 0;
  const harness = createHarness(async (value, init) => {
    const request = requestDetails(value, init);
    const action = runPodAction(request);
    calls.push({ method: request.method, path: request.url.pathname, action });
    if (request.method === "GET") {
      probeCount += 1;
      return Response.json({
        id: POD_ID,
        name: "chekinana",
        desiredStatus: probeCount === 1 ? "EXITED" : "STARTING",
        gpu: { count: 1 },
      });
    }
    assert.equal(action, "stop");
    return Response.json({ status: "EXITED" });
  }, {
    initialSnapshot: snapshot({
      state: "preparing",
      internalPhase: "primary_dispatch_intent",
      restartable: false,
      startupStartedAt: NOW - 1_000,
      startupDeadlineAt: NOW + 60_000,
      startupControlPhase: "primary_dispatch_intent",
      primaryStartDispatched: true,
    }),
  });
  harness.ctx.startupSockets = [];
  await harness.ctx.ready;
  await harness.runtime.alarm();
  assert.equal((await harness.snapshot()).primaryStartDispatched, true);
  harness.advance(10_000);
  await harness.runtime.alarm();
  let stored = await harness.snapshot();
  assert.equal(stored.shutdownRequest.kind, "startup_primary_cleanup");
  assert.equal(stored.shutdownRequest.attempted, false);
  await harness.runtime.alarm();
  stored = await harness.snapshot();
  assert.equal(stored.state, "closed");
  await harness.runtime.alarm();
  assert.deepEqual(calls.map((call) => call.action), [null, null, "stop"]);
});

test("reviewer P2 persisted ready still performs live Pod and strict health reads", async () => {
  const calls = [];
  const harness = createHarness(async (value, init) => {
    const request = requestDetails(value, init);
    calls.push(`${request.method} ${request.url.origin}${request.url.pathname}`);
    if (request.url.origin === "https://rest.runpod.io") {
      return Response.json({
        id: POD_ID, name: "chekinana", desiredStatus: "RUNNING", gpu: { count: 1 },
      });
    }
    assert.equal(request.url.pathname, "/health");
    return Response.json({ status: "ok", model_loaded: true, device: "cuda" });
  }, {
    initialSnapshot: snapshot({
      state: "ready",
      restartable: false,
      startupStartedAt: NOW - 1_000,
      startupDeadlineAt: NOW + 60_000,
      startupControlPhase: "monitoring",
    }),
  });
  await harness.ctx.ready;
  const outcome = await harness.runtime.start();
  assert.equal(outcome.error, null);
  assert.equal((await harness.snapshot()).state, "ready");
  assert.deepEqual(calls, [
    `GET https://rest.runpod.io/v1/pods/${POD_ID}`,
    `GET https://${POD_ID}-8080.proxy.runpod.net/health`,
  ]);
});

test("start single-flight reads and starts the fixed primary Pod before preparing", async () => {
  const calls = [];
  const sent = [];
  const harness = createHarness(async (value, init) => {
    const request = requestDetails(value, init);
    calls.push(`${request.method} ${request.url.origin}${request.url.pathname}`);
    if (request.method === "GET") return Response.json(exitedPod());
    return new Response(null, { status: 200 });
  }, { initialSnapshot: snapshot() });
  harness.ctx.startupSockets = [{
    readyState: 1,
    send(value) { sent.push(JSON.parse(value)); },
    close() {},
  }];
  await harness.ctx.ready;
  assert.equal((await harness.runtime.start()).error, null);
  assert.equal((await harness.snapshot()).state, "preparing");
  assert.deepEqual(calls, [
    `GET https://rest.runpod.io/v1/pods/${POD_ID}`,
    `POST https://rest.runpod.io/v1/pods/${POD_ID}/start`,
  ]);
  assert.equal(calls.some((call) => call === "POST https://rest.runpod.io/v1/pods"), false);
  assert.equal(calls.some((call) => call.startsWith("DELETE ")), false);
  assert.deepEqual(sent.map(({ progress }) => progress), [
    { current: 1, total: 3 },
    { current: 1, total: 3 },
    { current: 2, total: 3 },
  ]);
});

test("primary start HTTP 500 creates one temporary template Pod", async () => {
  const calls = [];
  const sent = [];
  const harness = createHarness(async (value, init) => {
    const request = requestDetails(value, init);
    calls.push(`${request.method} ${request.url.pathname}`);
    if (request.method === "GET") return Response.json(exitedPod());
    if (request.url.pathname.endsWith("/start")) {
      assert.equal(request.body, undefined);
      return new Response("Your Pod's GPUs are no longer available.", { status: 500 });
    }
    assert.equal(request.url.pathname, "/v1/pods");
    assert.deepEqual(JSON.parse(request.body), {
      name: "chekinana-scanner-temporary-00000000000040008000000000000001",
      templateId: "test-template",
      networkVolumeId: "test-volume",
      computeType: "GPU",
      gpuCount: 2,
      gpuTypePriority: "availability",
      interruptible: false,
      locked: false,
    });
    return Response.json({
      id: TEMPORARY_POD_ID,
      desiredStatus: "RUNNING",
      gpuCount: 2,
    }, { status: 201 });
  }, { initialSnapshot: snapshot() });
  harness.ctx.startupSockets = [{
    readyState: 1,
    send(value) { sent.push(JSON.parse(value)); },
    close() {},
  }];
  await harness.ctx.ready;
  assert.equal((await harness.runtime.start()).error, null);
  assert.equal((await harness.snapshot()).state, "preparing");
  assert.deepEqual(calls, [
    `GET /v1/pods/${POD_ID}`,
    `POST /v1/pods/${POD_ID}/start`,
    "POST /v1/pods",
  ]);
  const stored = await harness.snapshot();
  assert.equal(stored.currentPodKind, "temporary");
  assert.equal(stored.currentPodId, TEMPORARY_POD_ID);
  assert.equal(stored.internalPhase, "waiting_for_pod");
  assert.deepEqual(sent.at(-1).progress, { current: 2, total: 3 });
  assert.equal(sent.some(({ progress }) => progress?.current === 1), true);
});

test("temporary create failure exposes only the stable error signal", async () => {
  const sent = [];
  const harness = createHarness(async (value, init) => {
    const request = requestDetails(value, init);
    if (request.method === "GET") return Response.json(exitedPod());
    if (request.url.pathname.endsWith("/start")) {
      return new Response(null, { status: 500 });
    }
    assert.equal(request.method, "POST");
    assert.equal(request.url.pathname, "/v1/pods");
    return Response.json({
      id: TEMPORARY_POD_ID,
      desiredStatus: "EXITED",
    }, { status: 201 });
  }, { initialSnapshot: snapshot() });
  harness.ctx.startupSockets = [{
    readyState: 1,
    send(value) { sent.push(JSON.parse(value)); },
    close() {},
  }];
  await harness.ctx.ready;

  const outcome = await harness.runtime.start();
  assert.equal(outcome.error, "temporary_pod_create_failed");
  assert.equal((await harness.snapshot()).message, null);

  harness.runtime.broadcastStartupSnapshot({
    ok: false,
    error: outcome.error,
    close: true,
  });
  assert.ok(sent.length > 1);
  const terminal = sent.at(-1);
  assert.equal(terminal.error, "temporary_pod_create_failed");
  assert.equal(terminal.message, null);
  assert.equal(terminal.progress, undefined);
});

test("temporary create response loss recovers exact unique name and deletes once", async () => {
  const calls = [];
  let temporaryName = "";
  const harness = createHarness(async (value, init) => {
    const request = requestDetails(value, init);
    const body = request.body ? JSON.parse(request.body) : null;
    calls.push({ method: request.method, path: request.url.pathname, body });
    if (request.method === "GET" && request.url.pathname !== "/v1/pods") {
      return Response.json(exitedPod());
    }
    if (request.method === "GET") {
      return Response.json([
        exitedPod(),
        {
          id: TEMPORARY_POD_ID,
          name: temporaryName,
          desiredStatus: "STARTING",
          gpu: { count: 2 },
        },
      ]);
    }
    if (request.url.pathname.endsWith("/start")) {
      assert.equal(body, null);
      return new Response("temporary fallback", { status: 500 });
    }
    if (request.method === "POST" && request.url.pathname === "/v1/pods") {
      temporaryName = body.name;
      assert.equal(
        temporaryName,
        "chekinana-scanner-temporary-00000000000040008000000000000001",
      );
      assert.equal(body.templateId, "test-template");
      assert.equal(body.networkVolumeId, "test-volume");
      const storedBeforeCreate = await harness.snapshot();
      assert.equal(storedBeforeCreate.temporaryCreateName, temporaryName);
      assert.equal(storedBeforeCreate.startupControlPhase, "temporary_create_intent");
      assert.equal(harness.ctx.storage.alarm, NOW + scannerRuntimeConstants.START_RECHECK_MS);
      throw new TypeError("private response loss");
    }
    assert.equal(request.method, "DELETE");
    assert.equal(request.url.pathname, `/v1/pods/${TEMPORARY_POD_ID}`);
    return new Response(null, { status: 204 });
  }, { initialSnapshot: snapshot() });
  await harness.ctx.ready;
  const outcome = await harness.runtime.start();
  assert.equal(outcome.error, "runpod_status_unavailable");
  let stored = await harness.snapshot();
  assert.equal(stored.currentPodKind, "temporary");
  assert.equal(stored.currentPodId, TEMPORARY_POD_ID);
  assert.equal(stored.temporaryCreateName, null);
  assert.equal(stored.shutdownRequest.kind, "startup_cleanup");
  await harness.runtime.alarm();
  stored = await harness.snapshot();
  assert.equal(stored.state, "closed");
  assert.equal(stored.currentPodKind, "primary");
  await harness.runtime.alarm();
  assert.equal(calls.filter((call) => call.method === "DELETE").length, 1);
});

test("temporary create no-client recovery waits for exact-name visibility then deletes", async () => {
  const temporaryName = "chekinana-scanner-temporary-00000000000040008000000000000001";
  const calls = [];
  let probeCount = 0;
  const harness = createHarness(async (value, init) => {
    const request = requestDetails(value, init);
    calls.push(`${request.method} ${request.url.pathname}`);
    if (request.method === "GET") {
      probeCount += 1;
      return Response.json(probeCount === 1
        ? [exitedPod()]
        : [
          exitedPod(),
          { id: TEMPORARY_POD_ID, name: temporaryName, desiredStatus: "STARTING" },
        ]);
    }
    assert.equal(request.method, "DELETE");
    assert.equal(request.url.pathname, `/v1/pods/${TEMPORARY_POD_ID}`);
    return new Response(null, { status: 204 });
  }, {
    initialSnapshot: snapshot({
      state: "preparing",
      internalPhase: "temporary_create_intent",
      restartable: false,
      startupStartedAt: NOW - 1_000,
      startupDeadlineAt: NOW + 60_000,
      startupControlPhase: "temporary_create_intent",
      temporaryCreateName: temporaryName,
    }),
  });
  harness.ctx.startupSockets = [];
  await harness.ctx.ready;
  await harness.runtime.alarm();
  let stored = await harness.snapshot();
  assert.equal(stored.startupControlPhase, "temporary_create_intent");
  assert.equal(stored.temporaryCreateName, temporaryName);
  assert.equal(stored.shutdownRequest, null);
  harness.advance(scannerRuntimeConstants.START_RECHECK_MS);
  await harness.runtime.alarm();
  stored = await harness.snapshot();
  assert.equal(stored.currentPodKind, "temporary");
  assert.equal(stored.currentPodId, TEMPORARY_POD_ID);
  assert.equal(stored.shutdownRequest.kind, "startup_cleanup");
  await harness.runtime.alarm();
  await harness.runtime.alarm();
  assert.deepEqual(calls, [
    "GET /v1/pods",
    "GET /v1/pods",
    `DELETE /v1/pods/${TEMPORARY_POD_ID}`,
  ]);
});

test("temporary create recovery refuses ambiguous exact-name matches", async () => {
  const temporaryName = "chekinana-scanner-temporary-00000000000040008000000000000001";
  const calls = [];
  const harness = createHarness(async (value, init) => {
    const request = requestDetails(value, init);
    calls.push(`${request.method} ${request.url.pathname}`);
    assert.equal(request.method, "GET");
    return Response.json([
      exitedPod(),
      { id: "temporarypoda", name: temporaryName, desiredStatus: "STARTING" },
      { id: "temporarypodb", name: temporaryName, desiredStatus: "RUNNING" },
    ]);
  }, {
    initialSnapshot: snapshot({
      state: "preparing",
      internalPhase: "temporary_create_intent",
      restartable: false,
      startupStartedAt: NOW - 1_000,
      startupDeadlineAt: NOW + 60_000,
      startupControlPhase: "temporary_create_intent",
      temporaryCreateName: temporaryName,
    }),
  });
  harness.ctx.startupSockets = [];
  await harness.ctx.ready;
  await harness.runtime.alarm();
  const stored = await harness.snapshot();
  assert.equal(stored.state, "closed");
  assert.equal(stored.internalPhase, "temporary_pod_correlation_ambiguous");
  assert.equal(stored.temporaryCreateName, temporaryName);
  assert.equal(stored.shutdownRequest, null);
  await harness.runtime.alarm();
  assert.deepEqual(calls, ["GET /v1/pods"]);
});

test("non-capacity start errors do not create a temporary Pod or leak bodies", async () => {
  const calls = [];
  const harness = createHarness(async (value, init) => {
    const request = requestDetails(value, init);
    calls.push(`${request.method} ${request.url.pathname}`);
    if (request.method === "GET") return Response.json(exitedPod());
    if (request.url.pathname.endsWith("/stop")) return new Response(null, { status: 200 });
    return new Response("private validation failure", { status: 422 });
  }, { initialSnapshot: snapshot() });
  await harness.ctx.ready;
  const outcome = await harness.runtime.start();
  assert.equal(outcome.error, "runpod_status_unavailable");
  assert.equal((await harness.snapshot()).state, "preparing");
  assert.deepEqual(calls, [
    `GET /v1/pods/${POD_ID}`,
    `POST /v1/pods/${POD_ID}/start`,
  ]);
  await harness.runtime.alarm();
  assert.deepEqual(calls, [
    `GET /v1/pods/${POD_ID}`,
    `POST /v1/pods/${POD_ID}/start`,
    `POST /v1/pods/${POD_ID}/stop`,
  ]);
});

test("explicit primary shutdown waits twenty seconds and sends exactly one stop", async () => {
  const calls = [];
  const harness = createHarness(async (value, init) => {
    const request = requestDetails(value, init);
    calls.push(`${request.method} ${request.url.origin}${request.url.pathname}`);
    return new Response(null, { status: 200 });
  }, { initialSnapshot: snapshot({ state: "ready", restartable: false, idleSince: NOW }) });
  const response = await handleRequest(new Request(
    "https://api.chekinana.top/api/scanner/runtime/stop",
    { method: "POST" },
  ), harness.workerEnv);
  assert.equal(response.status, 202);
  const responseBody = await response.json();
  assert.equal(responseBody.state, "preparing");
  assert.equal(responseBody.message, "RunPod GPU 将在 20 秒后关闭。");
  assert.deepEqual(calls, []);
  harness.advance(scannerRuntimeConstants.EXPLICIT_STOP_DELAY_MS - 1);
  await harness.runtime.alarm();
  assert.deepEqual(calls, []);
  harness.advance(1);
  await harness.runtime.alarm();
  assert.deepEqual(calls, [`POST https://rest.runpod.io/v1/pods/${POD_ID}/stop`]);
  assert.equal((await harness.snapshot()).state, "closed");
  await harness.runtime.alarm();
  assert.deepEqual(calls, [`POST https://rest.runpod.io/v1/pods/${POD_ID}/stop`]);
  assert.equal(calls.some((call) => call.startsWith("DELETE ")), false);
});

test("idle primary shutdown recovers the four-minute deadline and stops once", async () => {
  const calls = [];
  const harness = createHarness(async (value, init) => {
    const request = requestDetails(value, init);
    calls.push(`${request.method} ${request.url.origin}${request.url.pathname}`);
    return new Response(null, { status: 200 });
  }, { initialSnapshot: snapshot({
    state: "ready",
    restartable: false,
    idleSince: NOW,
    shutdownRequest: {
      kind: "idle",
      dueAt: NOW + scannerRuntimeConstants.IDLE_TIMEOUT_MS,
      attempted: false,
    },
  }) });
  harness.advance(scannerRuntimeConstants.IDLE_TIMEOUT_MS - 1);
  await harness.runtime.alarm();
  assert.deepEqual(calls, []);
  harness.advance(1);
  await harness.runtime.alarm();
  assert.deepEqual(calls, [`POST https://rest.runpod.io/v1/pods/${POD_ID}/stop`]);
  assert.equal((await harness.snapshot()).state, "closed");
  await harness.runtime.alarm();
  assert.equal(calls.length, 1);
});

test("idle temporary shutdown waits four minutes, deletes once, and never stops", async () => {
  const calls = [];
  const harness = createHarness(async (value, init) => {
    const request = requestDetails(value, init);
    calls.push(`${request.method} ${request.url.pathname}`);
    return new Response(null, { status: 204 });
  }, { initialSnapshot: snapshot({
    currentPodId: TEMPORARY_POD_ID,
    currentPodKind: "temporary",
    state: "ready",
    restartable: false,
    idleSince: NOW,
    shutdownRequest: {
      kind: "idle",
      dueAt: NOW + scannerRuntimeConstants.IDLE_TIMEOUT_MS,
      attempted: false,
    },
  }) });
  harness.advance(scannerRuntimeConstants.IDLE_TIMEOUT_MS - 1);
  await harness.runtime.alarm();
  assert.deepEqual(calls, []);
  harness.advance(1);
  await harness.runtime.alarm();
  await harness.runtime.alarm();
  assert.deepEqual(calls, [`DELETE /v1/pods/${TEMPORARY_POD_ID}`]);
  assert.equal(calls.some((call) => call.endsWith("/stop")), false);
});

test("new Scanner activity cancels idle shutdown and starts a fresh four-minute window", async () => {
  const harness = createHarness(async () => new Response(), {
    initialSnapshot: snapshot({
      state: "ready",
      restartable: false,
      idleSince: NOW,
      shutdownRequest: {
        kind: "idle",
        dueAt: NOW + scannerRuntimeConstants.IDLE_TIMEOUT_MS,
        attempted: false,
      },
    }),
  });
  await harness.ctx.ready;
  const leaseId = await harness.runtime.beginRequestActivity(true);
  let stored = await harness.snapshot();
  assert.equal(stored.shutdownRequest, null);
  assert.equal(stored.idleSince, null);

  await harness.runtime.endRequestActivity(leaseId);
  stored = await harness.snapshot();
  assert.equal(stored.idleSince, NOW);
  assert.deepEqual(stored.shutdownRequest, {
    kind: "idle",
    dueAt: NOW + scannerRuntimeConstants.IDLE_TIMEOUT_MS,
    attempted: false,
  });
});

for (const [label, earlierDelay] of [
  ["startup", scannerRuntimeConstants.START_RECHECK_MS],
  ["active", scannerRuntimeConstants.ACTIVE_RECHECK_MS],
]) {
  test(`four-minute idle scheduling preserves an earlier ${label} alarm`, async () => {
    const harness = createHarness(async () => new Response(), {
      initialSnapshot: snapshot({ state: "ready", restartable: false }),
    });
    await harness.ctx.ready;
    harness.ctx.storage.alarm = NOW + earlierDelay;
    await harness.runtime.scheduleIdleShutdown();
    assert.equal(harness.ctx.storage.alarm, NOW + earlierDelay);
    assert.equal(
      (await harness.snapshot()).shutdownRequest.dueAt,
      NOW + scannerRuntimeConstants.IDLE_TIMEOUT_MS,
    );
  });
}

test("four-minute idle scheduling never replaces a pending user shutdown", async () => {
  const userShutdown = {
    kind: "user",
    dueAt: NOW + scannerRuntimeConstants.EXPLICIT_STOP_DELAY_MS,
    attempted: false,
  };
  const harness = createHarness(async () => new Response(), {
    initialSnapshot: snapshot({
      state: "preparing",
      restartable: false,
      shutdownRequest: userShutdown,
    }),
  });
  await harness.ctx.ready;
  harness.ctx.storage.alarm = userShutdown.dueAt;
  await harness.runtime.scheduleIdleShutdown();
  assert.deepEqual((await harness.snapshot()).shutdownRequest, userShutdown);
  assert.equal(harness.ctx.storage.alarm, userShutdown.dueAt);
});

test("temporary shutdown terminates once and never sends stop", async () => {
  const calls = [];
  const harness = createHarness(async (value, init) => {
    const request = requestDetails(value, init);
    calls.push(`${request.method} ${request.url.pathname}`);
    return new Response(null, { status: 204 });
  }, { initialSnapshot: snapshot({
    currentPodId: TEMPORARY_POD_ID,
    currentPodKind: "temporary",
    state: "ready",
    restartable: false,
  }) });
  await handleRequest(new Request(
    "https://api.chekinana.top/api/scanner/runtime/stop",
    { method: "POST" },
  ), harness.workerEnv);
  harness.advance(scannerRuntimeConstants.EXPLICIT_STOP_DELAY_MS);
  await harness.runtime.alarm();
  await harness.runtime.alarm();
  assert.deepEqual(calls, [`DELETE /v1/pods/${TEMPORARY_POD_ID}`]);
  assert.equal((await harness.snapshot()).currentPodKind, "primary");
});

test("an active task blocks explicit stop", async () => {
  let calls = 0;
  const harness = createHarness(async () => {
    calls += 1;
    throw new Error("must not call RunPod");
  }, {
    initialSnapshot: snapshot({
      state: "ready",
      restartable: false,
      activeTasks: { active: NOW },
    }),
  });
  const response = await handleRequest(new Request(
    "https://api.chekinana.top/api/scanner/runtime/stop",
    { method: "POST" },
  ), harness.workerEnv);
  assert.equal(response.status, 409);
  assert.equal((await response.json()).error, "scanner_backend_busy");
  assert.equal(calls, 0);
});

test("a preparing runtime stop error omits startup progress", async () => {
  const harness = createHarness(async () => new Response("unexpected"), {
    initialSnapshot: snapshot({
      state: "preparing",
      internalPhase: "waiting_for_pod",
      restartable: false,
    }),
  });
  const response = await handleRequest(new Request(
    "https://api.chekinana.top/api/scanner/runtime/stop",
    { method: "POST" },
  ), harness.workerEnv);
  assert.equal(response.status, 409);
  const body = await response.json();
  assert.equal(body.error, "scanner_backend_busy");
  assert.equal(body.progress, undefined);
});

test("production adapter streams v1.2 upload and maps successful status metadata", async () => {
  const taskId = "task_test";
  const boundary = "scanner-v12-test-boundary";
  const multipart = [
    `--${boundary}\r\n`,
    'Content-Disposition: form-data; name="sleeve"\r\n\r\n',
    "1\r\n",
    `--${boundary}\r\n`,
    'Content-Disposition: form-data; name="file"; filename="source.jpg"\r\n',
    "Content-Type: image/jpeg\r\n\r\n",
    "streamed-image-bytes\r\n",
    `--${boundary}--\r\n`,
  ].join("");
  const quadrilateral = [[1, 2], [101, 2], [101, 202], [1, 202]];
  let scannerCalls = 0;
  const harness = createHarness(async (value) => {
    const request = value instanceof Request ? value : new Request(value);
    const url = new URL(request.url);
    assert.equal(url.hostname, `${POD_ID}-8080.proxy.runpod.net`);
    assert.equal(url.search, "");
    assert.equal(request.headers.get("x-cheki-token"), null);
    assert.equal(request.headers.get("authorization"), "Bearer test-only-backend-token");
    assert.equal(request.headers.get("cookie"), null);
    assert.equal(request.headers.get("origin"), null);
    scannerCalls += 1;
    if (url.pathname === "/v1/jobs") {
      assert.equal(request.method, "POST");
      assert.equal(
        request.headers.get("content-type"),
        `multipart/form-data; boundary=${boundary}`,
      );
      assert.equal(await request.text(), multipart);
      return Response.json({ job_id: taskId, status: "queued" }, { status: 202 });
    }
    assert.equal(url.pathname, `/v1/jobs/${taskId}`);
    return Response.json({
      job_id: taskId,
      status: "succeeded",
      result_count: 1,
      source_image: { width: 1000, height: 800 },
      coordinate_system: {
        space: "exif_transposed_original_pixels",
        origin: "top_left",
        x_axis: "right",
        y_axis: "down",
        quad_order: ["top_left", "top_right", "bottom_right", "bottom_left"],
      },
      results: [{
        index: 1,
        filename: "cheki_001.png",
        url: "/v1/jobs/task_test/results/1",
        quadrilateral,
      }],
    });
  }, { initialSnapshot: snapshot({ state: "ready", restartable: false, idleSince: NOW }) });
  const uploadRequest = new Request(
    "https://api.chekinana.top/api/process",
    {
      method: "POST",
      headers: {
        authorization: "client-private",
        cookie: "private-cookie",
        origin: "https://client.example",
        "content-type": `multipart/form-data; boundary=${boundary}`,
      },
      body: new ReadableStream({
        start(controller) {
          controller.enqueue(new TextEncoder().encode(multipart));
          controller.close();
        },
      }),
      duplex: "half",
    },
  );
  uploadRequest.formData = async () => {
    throw new Error("production upload must remain streaming");
  };
  const processResponse = await handleRequest(uploadRequest, harness.workerEnv);
  assert.equal(processResponse.status, 202);
  assert.deepEqual(await processResponse.json(), { task_id: taskId, status: "queued" });
  await harness.flushBackground();
  assert.deepEqual(Object.keys((await harness.snapshot()).activeTasks), [taskId]);
  const statusResponse = await handleRequest(new Request(
    `https://api.chekinana.top/api/status/${taskId}`,
  ), harness.workerEnv);
  assert.deepEqual(await statusResponse.json(), {
    task_id: taskId,
    status: "done",
    results_count: 1,
    extraction_complete: true,
    results: [{
      id: "1",
      type: "polaroid",
      label: "cheki_001.png",
      quadrilateral,
    }],
    source_image: { width: 1000, height: 800 },
    coordinate_system: {
      space: "exif_transposed_original_pixels",
      origin: "top_left",
      x_axis: "right",
      y_axis: "down",
      quad_order: ["top_left", "top_right", "bottom_right", "bottom_left"],
    },
  });
  await harness.flushBackground();
  assert.deepEqual((await harness.snapshot()).activeTasks, {});
  assert.equal(scannerCalls, 2);
});

test("concurrent status polling parses each validated upstream response only once", async () => {
  const taskIds = Array.from({ length: 12 }, (_, index) => `poll_task_${index + 1}`);
  let releaseFetches;
  const allFetchesStarted = new Promise((resolve) => { releaseFetches = resolve; });
  let fetchesStarted = 0;
  let cloneCalls = 0;
  const originalClone = Response.prototype.clone;
  const harness = createHarness(async (value) => {
    const request = value instanceof Request ? value : new Request(value);
    const taskId = new URL(request.url).pathname.split("/").at(-1);
    fetchesStarted += 1;
    if (fetchesStarted === taskIds.length) releaseFetches();
    await allFetchesStarted;
    return Response.json({ job_id: taskId, status: "running" });
  }, {
    initialSnapshot: snapshot({
      state: "ready",
      restartable: false,
      activeTasks: Object.fromEntries(taskIds.map((taskId) => [taskId, NOW])),
    }),
  });

  Response.prototype.clone = function countedClone(...arguments_) {
    cloneCalls += 1;
    return originalClone.apply(this, arguments_);
  };
  try {
    const responses = await Promise.all(taskIds.map((taskId) => handleRequest(
      new Request(`https://api.chekinana.top/api/status/${taskId}`),
      harness.workerEnv,
    )));
    assert.deepEqual((await harness.snapshot()).inFlightRequests, {});
    const bodies = await Promise.all(responses.map((response) => response.json()));
    await harness.flushBackground();
    assert.equal(fetchesStarted, taskIds.length);
    assert.equal(cloneCalls, 0);
    assert.deepEqual(
      bodies.map(({ task_id: taskId, status }) => ({ taskId, status })),
      taskIds.map((taskId) => ({ taskId, status: "processing" })),
    );
    assert.deepEqual(
      Object.keys((await harness.snapshot()).activeTasks).sort(),
      [...taskIds].sort(),
    );
  } finally {
    Response.prototype.clone = originalClone;
  }
});

test("client cancellation aborts the in-flight production Scanner request and releases its lease", async () => {
  const taskId = "aborted_status_task";
  let upstreamSignal;
  let notifyStarted;
  const started = new Promise((resolve) => { notifyStarted = resolve; });
  const harness = createHarness(async (value) => {
    const request = value instanceof Request ? value : new Request(value);
    upstreamSignal = request.signal;
    notifyStarted();
    return new Promise((resolve, reject) => {
      request.signal.addEventListener("abort", () => reject(request.signal.reason), {
        once: true,
      });
    });
  }, {
    initialSnapshot: snapshot({
      state: "ready",
      internalPhase: "ready",
      restartable: false,
      activeTasks: { [taskId]: NOW },
    }),
  });
  const controller = new AbortController();
  const pending = handleRequest(new Request(
    `https://api.chekinana.top/api/status/${taskId}`,
    { signal: controller.signal },
  ), harness.workerEnv);
  await started;
  assert.equal(upstreamSignal.aborted, false);
  controller.abort("client canceled");
  const response = await pending;
  await harness.flushBackground();
  assert.equal(upstreamSignal.aborted, true);
  assert.equal(response.status, 502);
  assert.deepEqual(await response.json(), {
    ok: false,
    error: "scanner_upstream_unavailable",
  });
  const stored = await harness.snapshot();
  assert.deepEqual(stored.inFlightRequests, {});
  assert.equal(stored.state, "ready");
  assert.equal(stored.internalPhase, "ready");
});

test("production result route maps to v1.2 PNG endpoint and strips Worker-only query", async () => {
  const taskId = "result_task";
  const expected = new Uint8Array([137, 80, 78, 71, 1, 2, 3]);
  const harness = createHarness(async (value) => {
    const request = value instanceof Request ? value : new Request(value);
    const url = new URL(request.url);
    assert.equal(url.pathname, `/v1/jobs/${taskId}/results/2`);
    assert.equal(url.search, "");
    assert.equal(request.headers.get("authorization"), "Bearer test-only-backend-token");
    return new Response(expected, { headers: {
      "content-type": "image/png",
      "content-disposition": 'attachment; filename="cheki_002.png"',
      "cache-control": "private, max-age=30",
      "set-cookie": "private-cookie=value",
      "x-debug-secret": "private-debug-value",
    } });
  }, { initialSnapshot: snapshot({ state: "ready", restartable: false }) });
  const response = await handleRequest(new Request(
    `https://api.chekinana.top/api/result/${taskId}/2?date_annotation=0&token=private`,
  ), harness.workerEnv);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("content-type"), "image/png");
  assert.equal(
    response.headers.get("content-disposition"),
    'attachment; filename="cheki_002.png"',
  );
  assert.equal(response.headers.get("cache-control"), "private, max-age=30");
  assert.equal(response.headers.get("set-cookie"), null);
  assert.equal(response.headers.get("x-debug-secret"), null);
  assert.deepEqual(new Uint8Array(await response.arrayBuffer()), expected);
});

test("production cancel is local, idempotent, and prevents later status or result proxying", async () => {
  const taskId = "cancel_task";
  let calls = 0;
  const harness = createHarness(async () => {
    calls += 1;
    return new Response("unexpected");
  }, {
    initialSnapshot: snapshot({
      state: "ready",
      restartable: false,
      activeTasks: { [taskId]: NOW },
    }),
  });

  const cancel = () => handleRequest(new Request(
    `https://api.chekinana.top/api/cancel/${taskId}`,
    { method: "POST" },
  ), harness.workerEnv);
  assert.deepEqual(await (await cancel()).json(), {
    ok: true,
    status: "canceled",
    task_id: taskId,
    upstream_cancel_supported: false,
  });
  assert.deepEqual(await (await cancel()).json(), {
    ok: true,
    status: "canceled",
    task_id: taskId,
    upstream_cancel_supported: false,
  });
  const stored = await harness.snapshot();
  assert.deepEqual(stored.activeTasks, {});
  assert.equal(typeof stored.canceledTasks[taskId], "number");

  const status = await handleRequest(new Request(
    `https://api.chekinana.top/api/status/${taskId}`,
  ), harness.workerEnv);
  assert.deepEqual(await status.json(), {
    task_id: taskId,
    status: "canceled",
    results_count: 0,
    extraction_complete: true,
    results: [],
  });
  const result = await handleRequest(new Request(
    `https://api.chekinana.top/api/result/${taskId}/1`,
  ), harness.workerEnv);
  assert.equal(result.status, 410);
  assert.deepEqual(await result.json(), {
    ok: false,
    error: "scanner_task_canceled",
    task_id: taskId,
  });
  assert.equal(calls, 0);
});

for (const [label, existingDelay] of [
  ["near startup recheck", 2_000],
  ["startup deadline", 15 * 60 * 1000],
]) {
  test(`repeated cancel during preparing preserves the earlier ${label} alarm`, async () => {
    const taskId = `already_canceled_${existingDelay}`;
    const expiresAt = NOW + (30 * 60 * 1000);
    const harness = createHarness(async () => new Response("unexpected"), {
      initialSnapshot: snapshot({
        state: "preparing",
        internalPhase: "waiting_for_pod",
        restartable: false,
        startupStartedAt: NOW,
        startupDeadlineAt: NOW + (15 * 60 * 1000),
        startupControlPhase: "monitoring",
        canceledTasks: { [taskId]: expiresAt },
      }),
    });
    await harness.ctx.ready;
    harness.ctx.storage.alarm = NOW + existingDelay;
    const putsBefore = harness.ctx.storage.puts;
    const response = await handleRequest(new Request(
      `https://api.chekinana.top/api/cancel/${taskId}`,
      { method: "POST" },
    ), harness.workerEnv);
    assert.equal(response.status, 200);
    assert.equal(harness.ctx.storage.alarm, NOW + existingDelay);
    assert.equal((await harness.snapshot()).canceledTasks[taskId], expiresAt);
    assert.equal(harness.ctx.storage.puts, putsBefore);
  });
}

test("unknown cancel IDs return a fixed 404 without growing persistent state", async () => {
  const harness = createHarness(async () => new Response("unexpected"), {
    initialSnapshot: snapshot({ state: "closed", restartable: false }),
  });
  await harness.ctx.ready;
  const putsBefore = harness.ctx.storage.puts;
  for (let index = 0; index < 128; index += 1) {
    const response = await handleRequest(new Request(
      `https://api.chekinana.top/api/cancel/unknown_${index}`,
      { method: "POST" },
    ), harness.workerEnv);
    assert.equal(response.status, 404);
    assert.deepEqual(await response.json(), {
      ok: false,
      error: "scanner_task_not_found",
    });
  }
  assert.deepEqual((await harness.snapshot()).canceledTasks ?? {}, {});
  assert.equal(harness.ctx.storage.puts, putsBefore);
  assert.equal(harness.ctx.storage.alarm, null);
});

test("cancel schedules idle shutdown after the final non-scan request lease releases", async () => {
  const taskId = "cancel_with_status_lease";
  let calls = 0;
  const harness = createHarness(async () => {
    calls += 1;
    return new Response("unexpected");
  }, {
    initialSnapshot: snapshot({
      state: "ready",
      restartable: false,
      activeTasks: { [taskId]: NOW },
    }),
  });
  await harness.ctx.ready;
  const leaseId = await harness.runtime.beginRequestActivity(false);

  const response = await handleRequest(new Request(
    `https://api.chekinana.top/api/cancel/${taskId}`,
    { method: "POST" },
  ), harness.workerEnv);
  assert.equal(response.status, 200);
  let stored = await harness.snapshot();
  assert.equal(stored.idleShutdownPending, true);
  assert.equal(stored.shutdownRequest, null);
  assert.equal(
    harness.ctx.storage.alarm,
    NOW + scannerRuntimeConstants.ACTIVE_RECHECK_MS,
  );

  await harness.runtime.endRequestActivity(leaseId);
  stored = await harness.snapshot();
  assert.equal(stored.idleShutdownPending, false);
  assert.equal(stored.idleSince, NOW);
  assert.deepEqual(stored.shutdownRequest, {
    kind: "idle",
    dueAt: NOW + scannerRuntimeConstants.IDLE_TIMEOUT_MS,
    attempted: false,
  });
  assert.equal(
    harness.ctx.storage.alarm,
    NOW + scannerRuntimeConstants.ACTIVE_RECHECK_MS,
  );
  harness.advance(scannerRuntimeConstants.ACTIVE_RECHECK_MS);
  await harness.runtime.alarm();
  assert.equal(
    harness.ctx.storage.alarm,
    NOW + scannerRuntimeConstants.IDLE_TIMEOUT_MS,
  );
  assert.equal(typeof stored.canceledTasks[taskId], "number");
  assert.equal(calls, 0);
});

test("a late process observation cannot restore a canceled task to active tracking", async () => {
  const taskId = "late_cancel_task";
  const harness = createHarness(async () => Response.json({
    job_id: taskId,
    status: "queued",
  }, { status: 202 }), {
    initialSnapshot: snapshot({
      state: "ready",
      restartable: false,
      canceledTasks: { [taskId]: NOW + (30 * 60 * 1000) },
    }),
  });
  const response = await handleRequest(new Request(
    "https://api.chekinana.top/api/process",
    { method: "POST", body: new FormData() },
  ), harness.workerEnv);
  assert.equal(response.status, 202);
  await harness.flushBackground();
  assert.deepEqual((await harness.snapshot()).activeTasks, {});
});

test("production cancel validates method and task id without calling an upstream", async () => {
  let calls = 0;
  const harness = createHarness(async () => {
    calls += 1;
    return new Response("unexpected");
  }, { initialSnapshot: snapshot({ state: "ready", restartable: false }) });
  const wrongMethod = await handleRequest(new Request(
    "https://api.chekinana.top/api/cancel/task_test",
  ), harness.workerEnv);
  assert.equal(wrongMethod.status, 405);
  assert.deepEqual(await wrongMethod.json(), { ok: false, error: "method_not_allowed" });
  const invalidTask = await handleRequest(new Request(
    "https://api.chekinana.top/api/cancel/not%20valid",
    { method: "POST" },
  ), harness.workerEnv);
  assert.equal(invalidTask.status, 404);
  assert.deepEqual(await invalidTask.json(), { ok: false, error: "scanner_route_unsupported" });
  const unknownTask = await handleRequest(new Request(
    "https://api.chekinana.top/api/cancel/task_test",
    { method: "POST" },
  ), harness.workerEnv);
  assert.equal(unknownTask.status, 404);
  assert.deepEqual(await unknownTask.json(), {
    ok: false,
    error: "scanner_task_not_found",
  });
  assert.equal(calls, 0);
});

test("canceled task signals expire and are removed from Durable Object state", async () => {
  const taskId = "expired_cancel_task";
  const harness = createHarness(async () => new Response("unexpected"), {
    initialSnapshot: snapshot({
      state: "closed",
      restartable: false,
      activeTasks: { [taskId]: NOW },
    }),
  });
  const response = await handleRequest(new Request(
    `https://api.chekinana.top/api/cancel/${taskId}`,
    { method: "POST" },
  ), harness.workerEnv);
  assert.equal(response.status, 200);
  assert.equal(typeof (await harness.snapshot()).canceledTasks[taskId], "number");
  assert.equal(harness.ctx.storage.alarm, NOW + (30 * 60 * 1000));
  harness.advance(30 * 60 * 1000);
  await harness.runtime.alarm();
  assert.deepEqual((await harness.snapshot()).canceledTasks, {});
});

for (const [label, status, expectedStatus, expectedError] of [
  ["404", 404, 404, "scanner_task_not_found"],
  ["Backend 4xx", 422, 502, "scanner_backend_rejected"],
  ["Backend 5xx", 503, 502, "scanner_backend_rejected"],
]) {
  test(`production adapter fixes and scrubs ${label} responses`, async () => {
    let canceled = false;
    const harness = createHarness(async () => new Response(new ReadableStream({
      start(controller) {
        controller.enqueue(new TextEncoder().encode("private upstream body"));
      },
      cancel() { canceled = true; },
    }), {
      status,
      headers: {
        "content-type": "text/plain",
        "set-cookie": "private-cookie=value",
        "x-debug-secret": "private-debug-value",
      },
    }), { initialSnapshot: snapshot({ state: "ready", restartable: false }) });
    const response = await handleRequest(new Request(
      "https://api.chekinana.top/api/status/task_test",
    ), harness.workerEnv);
    assert.equal(response.status, expectedStatus);
    assert.deepEqual(await response.json(), { ok: false, error: expectedError });
    assert.equal(response.headers.get("set-cookie"), null);
    assert.equal(response.headers.get("x-debug-secret"), null);
    assert.equal(canceled, true);
  });
}

test("production adapter fixes malformed JSON without copying upstream headers or body", async () => {
  const harness = createHarness(async () => new Response("private malformed JSON", {
    status: 200,
    headers: {
      "content-type": "application/json",
      "set-cookie": "private-cookie=value",
      "x-debug-secret": "private-debug-value",
    },
  }), { initialSnapshot: snapshot({ state: "ready", restartable: false }) });
  const response = await handleRequest(new Request(
    "https://api.chekinana.top/api/status/task_test",
  ), harness.workerEnv);
  const text = await response.text();
  assert.equal(response.status, 502);
  assert.deepEqual(JSON.parse(text), {
    ok: false,
    error: "scanner_backend_invalid_response",
  });
  assert.doesNotMatch(text, /private/u);
  assert.equal(response.headers.get("set-cookie"), null);
  assert.equal(response.headers.get("x-debug-secret"), null);
});

test("production result rejects a non-PNG success and cancels its body", async () => {
  let canceled = false;
  const harness = createHarness(async () => new Response(new ReadableStream({
    start(controller) { controller.enqueue(new Uint8Array([1, 2, 3])); },
    cancel() { canceled = true; },
  }), {
    status: 200,
    headers: {
      "content-type": "image/jpeg",
      "set-cookie": "private-cookie=value",
      "x-debug-secret": "private-debug-value",
    },
  }), { initialSnapshot: snapshot({ state: "ready", restartable: false }) });
  const response = await handleRequest(new Request(
    "https://api.chekinana.top/api/result/task_test/1",
  ), harness.workerEnv);
  assert.equal(response.status, 502);
  assert.deepEqual(await response.json(), {
    ok: false,
    error: "scanner_backend_invalid_response",
  });
  assert.equal(response.headers.get("set-cookie"), null);
  assert.equal(response.headers.get("x-debug-secret"), null);
  assert.equal(canceled, true);
});

for (const [label, mutate] of [
  ["missing source image", (body) => { delete body.source_image; }],
  ["non-positive source size", (body) => { body.source_image.width = 0; }],
  ["missing coordinate system", (body) => { delete body.coordinate_system; }],
  ["wrong coordinate axis", (body) => { body.coordinate_system.x_axis = "left"; }],
  ["wrong quadrilateral order", (body) => { body.coordinate_system.quad_order = ["top_left", "bottom_left", "bottom_right", "top_right"]; }],
  ["mismatched job id", (body) => { body.job_id = "different_task"; }],
  ["mismatched result count", (body) => { body.result_count = 2; }],
  ["duplicate result index", (body) => {
    body.result_count = 2;
    body.results.push({ ...body.results[0], filename: "cheki_002.png" });
  }],
  ["gapped result index", (body) => {
    body.result_count = 2;
    body.results.push({ ...body.results[0], index: 3, filename: "cheki_003.png" });
  }],
  ["out-of-bounds quadrilateral", (body) => {
    body.results[0].quadrilateral[1][0] = body.source_image.width + 1;
  }],
]) {
  test(`production status rejects succeeded contract with ${label}`, async () => {
    const taskId = "task_test";
    const body = succeededJob(taskId);
    mutate(body);
    const harness = createHarness(async () => Response.json(body, {
      headers: { "x-debug-secret": "private-debug-value" },
    }), { initialSnapshot: snapshot({ state: "ready", restartable: false }) });
    const response = await handleRequest(new Request(
      `https://api.chekinana.top/api/status/${taskId}`,
    ), harness.workerEnv);
    assert.equal(response.status, 502);
    assert.deepEqual(await response.json(), {
      ok: false,
      error: "scanner_backend_invalid_response",
    });
    assert.equal(response.headers.get("x-debug-secret"), null);
  });
}

test("production status maps a successful zero-result job without inventing metadata", async () => {
  const taskId = "empty_task";
  const harness = createHarness(async () => Response.json({
    job_id: taskId,
    status: "succeeded",
    result_count: 0,
    source_image: { width: 1200, height: 900 },
    coordinate_system: {
      space: "exif_transposed_original_pixels",
      origin: "top_left",
      x_axis: "right",
      y_axis: "down",
      quad_order: ["top_left", "top_right", "bottom_right", "bottom_left"],
    },
    results: [],
  }), { initialSnapshot: snapshot({ state: "ready", restartable: false }) });
  const response = await handleRequest(new Request(
    `https://api.chekinana.top/api/status/${taskId}`,
  ), harness.workerEnv);
  const body = await response.json();
  assert.equal(body.status, "done");
  assert.equal(body.results_count, 0);
  assert.equal(body.extraction_complete, true);
  assert.deepEqual(body.results, []);
});

test("active-task refresh polls v1.2 status with Backend authorization", async () => {
  const taskId = "active_task";
  let calls = 0;
  const harness = createHarness(async (value) => {
    calls += 1;
    const request = value instanceof Request ? value : new Request(value);
    const url = new URL(request.url);
    assert.equal(url.pathname, `/v1/jobs/${taskId}`);
    assert.equal(request.headers.get("authorization"), "Bearer test-only-backend-token");
    assert.equal(request.headers.get("x-cheki-token"), null);
    return Response.json({ job_id: taskId, status: "succeeded", result_count: 0, results: [] });
  }, {
    initialSnapshot: snapshot({
      state: "ready",
      restartable: false,
      idleSince: null,
      activeTasks: { [taskId]: NOW },
    }),
  });
  await harness.runtime.alarm();
  assert.equal(calls, 1);
  assert.deepEqual((await harness.snapshot()).activeTasks, {});
});

test("active-task recovery checks use bounded parallelism and isolate failures", async () => {
  const taskIds = Array.from({ length: 7 }, (_, index) => `active_${index + 1}`);
  let currentChecks = 0;
  let maximumChecks = 0;
  const harness = createHarness(async (value) => {
    const request = value instanceof Request ? value : new Request(value);
    const taskId = request.url.split("/").at(-1);
    currentChecks += 1;
    maximumChecks = Math.max(maximumChecks, currentChecks);
    await new Promise((resolve) => setTimeout(resolve, 5));
    currentChecks -= 1;
    if (taskId === "active_3") throw new Error("isolated mock failure");
    const terminal = ["active_2", "active_5"].includes(taskId);
    return Response.json({
      job_id: taskId,
      status: terminal ? "succeeded" : "running",
    });
  }, {
    initialSnapshot: snapshot({
      state: "ready",
      restartable: false,
      idleSince: null,
      activeTasks: Object.fromEntries(taskIds.map((taskId) => [taskId, NOW])),
    }),
    runtimeEnv: { SCANNER_ACTIVE_TASK_CHECK_CONCURRENCY: "3" },
  });

  await harness.ctx.ready;
  await harness.runtime.refreshActiveTasks(POD_ID);

  assert.equal(maximumChecks, 3);
  assert.deepEqual(Object.keys((await harness.snapshot()).activeTasks), [
    "active_1",
    "active_3",
    "active_4",
    "active_6",
    "active_7",
  ]);
});

test("active-task recovery network waits do not hold the proxy control queue", async () => {
  let releaseChecks;
  let checksStarted;
  const started = new Promise((resolve) => { checksStarted = resolve; });
  const blocked = new Promise((resolve) => { releaseChecks = resolve; });
  const harness = createHarness(async () => {
    checksStarted();
    await blocked;
    return Response.json({ job_id: "active_task", status: "running" });
  }, {
    initialSnapshot: snapshot({
      state: "ready",
      restartable: false,
      activeTasks: { active_task: NOW },
    }),
  });

  const alarm = harness.runtime.alarm();
  await started;
  const stop = await Promise.race([
    handleRequest(new Request(
      "https://api.chekinana.top/api/scanner/runtime/stop",
      { method: "POST" },
    ), harness.workerEnv),
    new Promise((_, reject) => setTimeout(
      () => reject(new Error("control queue remained blocked")),
      50,
    )),
  ]);
  assert.equal(stop.status, 409);
  releaseChecks();
  await alarm;
});

test("shutdown recovery checks release control for proxy admission and honor a shutdown tombstone", async () => {
  const oldTaskId = "shutdown_old_task";
  const newTaskId = "shutdown_new_task";
  let releaseCheck;
  let checkStarted;
  const started = new Promise((resolve) => { checkStarted = resolve; });
  const blocked = new Promise((resolve) => { releaseCheck = resolve; });
  const calls = [];
  const harness = createHarness(async (value, init) => {
    const request = requestDetails(value, init);
    calls.push(`${request.method} ${request.url.origin}${request.url.pathname}`);
    if (request.method === "GET" && request.url.pathname === `/v1/jobs/${oldTaskId}`) {
      checkStarted();
      await blocked;
      return Response.json({ job_id: oldTaskId, status: "succeeded" });
    }
    if (request.method === "POST" && request.url.pathname === "/v1/jobs") {
      return Response.json({ job_id: newTaskId, status: "queued" }, { status: 202 });
    }
    throw new Error("unexpected mock request");
  }, {
    initialSnapshot: snapshot({
      state: "preparing",
      internalPhase: "shutdown_delay",
      restartable: false,
      activeTasks: { [oldTaskId]: NOW },
      shutdownRequest: { kind: "user", dueAt: NOW, attempted: false },
    }),
  });

  const alarm = harness.runtime.alarm();
  await started;
  const processResponse = await Promise.race([
    handleRequest(new Request(
      "https://api.chekinana.top/api/process",
      { method: "POST", body: new FormData() },
    ), harness.workerEnv),
    new Promise((_, reject) => setTimeout(
      () => reject(new Error("shutdown recovery held the control queue")),
      50,
    )),
  ]);
  assert.equal(processResponse.status, 202);
  assert.deepEqual(await processResponse.json(), {
    task_id: newTaskId,
    status: "queued",
  });
  await harness.flushBackground();

  releaseCheck();
  await alarm;
  const stored = await harness.snapshot();
  assert.equal(stored.shutdownRequest, null);
  assert.equal(stored.state, "ready");
  assert.deepEqual(Object.keys(stored.activeTasks), [newTaskId]);
  assert.deepEqual(calls, [
    `GET https://${POD_ID}-8080.proxy.runpod.net/v1/jobs/${oldTaskId}`,
    `POST https://${POD_ID}-8080.proxy.runpod.net/v1/jobs`,
  ]);
});

test("shutdown recovery stops once after its versioned active tasks are terminal", async () => {
  const taskId = "shutdown_terminal_task";
  const calls = [];
  const harness = createHarness(async (value, init) => {
    const request = requestDetails(value, init);
    calls.push(`${request.method} ${request.url.origin}${request.url.pathname}`);
    if (request.url.pathname === `/v1/jobs/${taskId}`) {
      return Response.json({ job_id: taskId, status: "succeeded" });
    }
    return new Response(null, { status: 200 });
  }, {
    initialSnapshot: snapshot({
      state: "ready",
      restartable: false,
      activeTasks: { [taskId]: NOW },
      shutdownRequest: { kind: "idle", dueAt: NOW, attempted: false },
    }),
  });

  await harness.runtime.alarm();
  await harness.runtime.alarm();
  assert.deepEqual(calls, [
    `GET https://${POD_ID}-8080.proxy.runpod.net/v1/jobs/${taskId}`,
    `POST https://rest.runpod.io/v1/pods/${POD_ID}/stop`,
  ]);
  assert.equal((await harness.snapshot()).state, "closed");
});

test("active-task recovery concurrency is defaulted and capped", async () => {
  const defaultHarness = createHarness(async () => new Response(), {
    runtimeEnv: { SCANNER_ACTIVE_TASK_CHECK_CONCURRENCY: "invalid" },
  });
  const cappedHarness = createHarness(async () => new Response(), {
    runtimeEnv: { SCANNER_ACTIVE_TASK_CHECK_CONCURRENCY: "999" },
  });
  await Promise.all([defaultHarness.ctx.ready, cappedHarness.ctx.ready]);
  assert.equal(
    defaultHarness.runtime.activeTaskCheckConcurrency(),
    scannerRuntimeConstants.DEFAULT_ACTIVE_TASK_CHECK_CONCURRENCY,
  );
  assert.equal(
    cappedHarness.runtime.activeTaskCheckConcurrency(),
    scannerRuntimeConstants.MAX_ACTIVE_TASK_CHECK_CONCURRENCY,
  );
});

test("timing diagnostics expose only fixed aggregate fields", async () => {
  const harness = createHarness(async () => new Response(), {
    runtimeEnv: { SCANNER_TIMING_LOGS: "true" },
  });
  await harness.ctx.ready;
  const messages = [];
  const originalInfo = console.info;
  console.info = (message) => messages.push(String(message));
  try {
    harness.runtime.logTiming("proxy", {
      kind: "process",
      status: 202,
      total_ms: 18.6,
      task_id: "private_task_identifier",
      pod_id: "private_pod_identifier",
    });
  } finally {
    console.info = originalInfo;
  }
  assert.deepEqual(messages, [
    "[scanner-timing] stage=proxy kind=process status=202 total_ms=19",
  ]);
});

test("production Scanner proxy fails closed when backend API token is missing", async () => {
  let calls = 0;
  const harness = createHarness(async () => {
    calls += 1;
    return new Response("unexpected");
  }, {
    initialSnapshot: snapshot({ state: "ready", restartable: false }),
    runtimeEnv: { CHEKI_BACKEND_API_TOKEN: "" },
  });
  const response = await handleRequest(new Request(
    "https://api.chekinana.top/api/status/task_test",
  ), harness.workerEnv);
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), {
    ok: false,
    error: "scanner_backend_configuration_invalid",
  });
  assert.equal(calls, 0);
});

test("runtime source keeps temporary lifecycle separate from primary lifecycle", async () => {
  const source = await readFile(new URL("../src/scanner-runtime.js", import.meta.url), "utf8");
  assert.match(source, /method:\s*["']DELETE["']/u);
  assert.match(source, /authenticatedFetch\(this\.restURL\(["'`]\/pods["'`]\)/u);
  assert.match(source, /\/pods\/\$\{encodeURIComponent\(podId\)\}\/\$\{action\}/u);
  assert.match(source, /name:\s*temporaryName/u);
  assert.match(source, /templateId,\s*\n\s*networkVolumeId,/u);
  assert.doesNotMatch(source, /podResume|RUNPOD_GRAPHQL_URL/u);
});
