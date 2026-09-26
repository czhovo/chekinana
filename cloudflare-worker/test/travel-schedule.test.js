import assert from "node:assert/strict";
import test from "node:test";

import {
  TRAVEL_AIRPORT_NAME_ENTRIES,
  handleTravelScheduleRequest,
  normalizeCode,
  parseChinaRailInfo,
  parseFlightPayloads,
} from "../src/travel-schedule.js";
import { handleRequest } from "../src/worker.js";

const endpoint = "https://api.chekinana.top/api/v1/schedule";

function flightLeg({
  departureCode,
  departureName,
  departureLocal,
  departureUtc,
  departureTerminal,
  arrivalCode,
  arrivalName,
  arrivalLocal,
  arrivalUtc,
  arrivalTerminal,
}) {
  return {
    departure: {
      airport: { iata: departureCode, name: departureName },
      scheduledTime: { local: departureLocal, utc: departureUtc },
      terminal: departureTerminal,
    },
    arrival: {
      airport: { iata: arrivalCode, name: arrivalName },
      scheduledTime: { local: arrivalLocal, utc: arrivalUtc },
      terminal: arrivalTerminal,
    },
  };
}

test("the recovered airport display-name table is complete", () => {
  assert.equal(TRAVEL_AIRPORT_NAME_ENTRIES.length, 122);
  assert.deepEqual(TRAVEL_AIRPORT_NAME_ENTRIES.find(([iata]) => iata === "PVG"), [
    "PVG",
    "上海浦东",
  ]);
  assert.deepEqual(TRAVEL_AIRPORT_NAME_ENTRIES.find(([iata]) => iata === "NRT"), [
    "NRT",
    "東京成田",
  ]);
});

test("normalizes accepted JR names without changing the public contract", () => {
  assert.equal(normalizeCode(" ｎｏｚｏｍｉ ３４３号 "), "のぞみ343");
  assert.equal(normalizeCode("Ｇ ７３２２"), "G7322");
});

test("rejects extra, missing, and duplicate query parameters", async () => {
  const cases = [
    [`${endpoint}?type=train&code=G7322&date=2026-08-27&extra=1`, "invalid_request"],
    [`${endpoint}?type=train&date=2026-08-27`, "invalid_code"],
    [`${endpoint}?type=train&type=flight&code=G7322&date=2026-08-27`, "invalid_type"],
  ];

  for (const [url, code] of cases) {
    const response = await handleRequest(new Request(url));
    assert.equal(response.status, 400);
    assert.equal((await response.json()).error.code, code);
  }
});

test("keeps the public CORS and no-store response contract", async () => {
  const response = await handleRequest(new Request(endpoint, { method: "OPTIONS" }));
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { ok: true });
  assert.equal(response.headers.get("content-type"), "application/json; charset=utf-8");
  assert.equal(response.headers.get("access-control-allow-origin"), "*");
  assert.equal(response.headers.get("access-control-allow-methods"), "GET,POST,OPTIONS");
  assert.equal(response.headers.get("access-control-allow-headers"), "content-type,x-cheki-token");
  assert.equal(response.headers.get("cache-control"), "no-store");
});

test("formats a two-leg flight and uses the recovered airport names", () => {
  const payloads = [[
    flightLeg({
      departureCode: "PVG",
      departureName: "Shanghai Pudong",
      departureLocal: "2026-08-27T08:00+08:00",
      departureUtc: "2026-08-27T00:00Z",
      departureTerminal: "2",
      arrivalCode: "NRT",
      arrivalName: "Narita",
      arrivalLocal: "2026-08-27T12:00+09:00",
      arrivalUtc: "2026-08-27T03:00Z",
      arrivalTerminal: "1",
    }),
  ], []];

  assert.deepEqual(parseFlightPayloads(payloads, "MU123", "2026-08-27"), {
    operator: "MU",
    stops: [
      { name: "上海浦东T2", departure: "2026-08-27T08:00:00+08:00" },
      { name: "東京成田T1", arrival: "2026-08-27T12:00:00+09:00" },
    ],
  });
});

test("cleans an unmapped airport name without falling back to another field", () => {
  const payloads = [[
    flightLeg({
      departureCode: "AAA",
      departureName: "Example International Airport",
      departureLocal: "2026-08-27T08:00+08:00",
      departureUtc: "2026-08-27T00:00Z",
      arrivalCode: "BBB",
      arrivalName: "Destination Airport",
      arrivalLocal: "2026-08-27T10:00+08:00",
      arrivalUtc: "2026-08-27T02:00Z",
    }),
  ], []];

  assert.deepEqual(parseFlightPayloads(payloads, "MU123", "2026-08-27"), {
    operator: "MU",
    stops: [
      { name: "Example", departure: "2026-08-27T08:00:00+08:00" },
      { name: "Destination", arrival: "2026-08-27T10:00:00+08:00" },
    ],
  });
});

test("rejects an unmapped airport with only shortName", () => {
  const leg = flightLeg({
    departureCode: "AAA",
    departureName: undefined,
    departureLocal: "2026-08-27T08:00+08:00",
    departureUtc: "2026-08-27T00:00Z",
    arrivalCode: "PVG",
    arrivalName: "Shanghai Pudong",
    arrivalLocal: "2026-08-27T10:00+08:00",
    arrivalUtc: "2026-08-27T02:00Z",
  });
  delete leg.departure.airport.name;
  leg.departure.airport.shortName = "Fallback";

  assert.throws(
    () => parseFlightPayloads([[leg], []], "MU123", "2026-08-27"),
    (error) => error.status === 502 && error.code === "upstream_invalid_response",
  );
});

test("rejects an unmapped airport name containing only the removable suffix", () => {
  const leg = flightLeg({
    departureCode: "AAA",
    departureName: "International Airport",
    departureLocal: "2026-08-27T08:00+08:00",
    departureUtc: "2026-08-27T00:00Z",
    arrivalCode: "PVG",
    arrivalName: "Shanghai Pudong",
    arrivalLocal: "2026-08-27T10:00+08:00",
    arrivalUtc: "2026-08-27T02:00Z",
  });

  assert.throws(
    () => parseFlightPayloads([[leg], []], "MU123", "2026-08-27"),
    (error) => error.status === 502 && error.code === "upstream_invalid_response",
  );
});

test("formats China Railway stops across midnight", () => {
  const payload = {
    data: {
      data: [
        { station_name: "上海虹桥", arrive_time: "----", start_time: "23:55" },
        { station_name: "杭州东", arrive_time: "00:40", start_time: "00:42" },
        { station_name: "宁波", arrive_time: "01:50", start_time: "----" },
      ],
    },
  };

  assert.deepEqual(parseChinaRailInfo(payload, "2026-08-27"), {
    operator: "cr",
    stops: [
      { name: "上海虹桥", departure: "2026-08-27T23:55:00+08:00" },
      {
        name: "杭州东",
        arrival: "2026-08-28T00:40:00+08:00",
        departure: "2026-08-28T00:42:00+08:00",
      },
      { name: "宁波", arrival: "2026-08-28T01:50:00+08:00" },
    ],
  });
});

test("flight fetch keeps the two-day query and delay contract", async () => {
  const requested = [];
  const waits = [];
  const fetchImpl = async (url, init) => {
    requested.push({ url: String(url), init });
    return new Response("[]", {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  };
  const result = await handleTravelScheduleRequest(
    new Request(`${endpoint}?type=flight&code=MU2482&date=2026-08-27`),
    { RAPIDAPI_KEY: "test-only" },
    {
      fetchImpl,
      waitImpl: async (milliseconds) => waits.push(milliseconds),
    },
  );

  assert.equal(result.status, 404);
  assert.equal(result.body.error.code, "schedule_not_found");
  assert.equal(requested.length, 2);
  assert.match(requested[0].url, /\/MU2482\/2026-08-27\?/u);
  assert.match(requested[1].url, /\/MU2482\/2026-08-28\?/u);
  assert.deepEqual(waits, [1050]);
  assert.equal(requested[0].init.headers["X-RapidAPI-Key"], "test-only");
});

const scheduleDate = "2026-08-27";
const railSearch = JSON.stringify({ data: [{ station_train_code: "G1", train_no: "synthetic-train" }] });
const railDetail = JSON.stringify({ data: { data: [
  { station_name: "始发站", arrive_time: "----", start_time: "23:55" },
  { station_name: "终点站", arrive_time: "00:40", start_time: "----" },
] } });
const emptyEastGrid = '<table><tr class="tableTr_trainNumber"><td>1</td></tr><tr class="tableTr_trainName"><td>other</td></tr><tr class="tableTr_operatingDay"><td></td></tr></table>';
const emptyOdekake = '<select id="date"><option value="20260827" selected>date</option></select><div class="pc-time-tbl-wrap"></div>';
function scheduleRequest(code = "G1", type = "train") {
  return new Request(`${endpoint}?type=${type}&code=${encodeURIComponent(code)}&date=${scheduleDate}`);
}
function assertScheduleDeadline(result) {
  assert.deepEqual(result, {
    status: 502,
    body: { error: { code: "upstream_unavailable", message: "Upstream service is unavailable" } },
  });
}
function odekakeDetail(code) {
  return `<table><tbody class="train-details"><tr><td>列車名</td><td>${code}号</td></tr></tbody><tbody class="time-details"><tr><td>始发站</td><td>23:55発</td></tr><tr><td>终点站</td><td>0:40着</td></tr></tbody></table>`;
}

test("schedule deadline bounds finite late headers and cleans the late response", async () => {
  let calls = 0;
  let aborted = false;
  let cancelled = false;
  let arrived = false;
  let pending;
  const result = await handleTravelScheduleRequest(scheduleRequest(), {}, {
    totalTimeoutMs: 10,
    fetchImpl: (_url, init) => {
      calls += 1;
      init.signal.addEventListener("abort", () => { aborted = true; }, { once: true });
      pending = new Promise((resolve) => setTimeout(() => {
        arrived = true;
        resolve(new Response(new ReadableStream({ cancel() { cancelled = true; } })));
      }, 40));
      return pending;
    },
  });
  assertScheduleDeadline(result);
  assert.equal(aborted, true);
  assert.equal(arrived, false);
  await pending;
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(cancelled, true);
  assert.equal(calls, 1);
});

test("schedule body timeout cancels the reader and prevents the ChinaRail detail request", async () => {
  let calls = 0;
  let cancelled = false;
  let aborted = false;
  let timer;
  const result = await handleTravelScheduleRequest(scheduleRequest(), {}, {
    totalTimeoutMs: 10,
    fetchImpl: async (_url, init) => {
      calls += 1;
      init.signal.addEventListener("abort", () => { aborted = true; }, { once: true });
      return new Response(new ReadableStream({
        start(controller) {
          timer = setTimeout(() => {
            controller.enqueue(new TextEncoder().encode(railSearch));
            controller.close();
          }, 50);
        },
        cancel() { cancelled = true; clearTimeout(timer); },
      }));
    },
  });
  clearTimeout(timer);
  assertScheduleDeadline(result);
  assert.equal(cancelled, true);
  assert.equal(aborted, true);
  assert.equal(calls, 1);
});

test("a finite late fetch rejection is consumed after the schedule deadline", async () => {
  let calls = 0;
  let pending;
  let rejected = false;
  const result = await handleTravelScheduleRequest(scheduleRequest(), {}, {
    totalTimeoutMs: 10,
    fetchImpl: () => {
      calls += 1;
      pending = new Promise((_resolve, reject) => setTimeout(() => {
        rejected = true;
        reject(new Error("synthetic late upstream rejection"));
      }, 40));
      return pending;
    },
  });
  assertScheduleDeadline(result);
  assert.equal(rejected, false);
  await assert.rejects(pending, /synthetic late upstream rejection/u);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(calls, 1);
});

test("the real flight interval uses the same deadline and is cancelled before the second request", async () => {
  let calls = 0;
  const result = await handleTravelScheduleRequest(scheduleRequest("MU1", "flight"), { RAPIDAPI_KEY: "test-only" }, {
    totalTimeoutMs: 10,
    fetchImpl: async () => { calls += 1; return new Response("[]"); },
  });
  assertScheduleDeadline(result);
  assert.equal(calls, 1);
});

test("a finite injected flight wait cannot start a later request after deadline", async () => {
  let calls = 0;
  let pending;
  let finished = false;
  const result = await handleTravelScheduleRequest(scheduleRequest("MU1", "flight"), { RAPIDAPI_KEY: "test-only" }, {
    totalTimeoutMs: 10,
    fetchImpl: async () => { calls += 1; return new Response("[]"); },
    waitImpl: (milliseconds, signal) => {
      assert.equal(milliseconds, 1050);
      assert.equal(signal.aborted, false);
      pending = new Promise((resolve) => setTimeout(() => { finished = true; resolve(); }, 40));
      return pending;
    },
  });
  assertScheduleDeadline(result);
  assert.equal(finished, false);
  await pending;
  assert.equal(calls, 1);
});

test("ChinaRail serial calls share one absolute budget and valid calls preserve midnight dates", async (t) => {
  for (const exceedsBudget of [false, true]) {
    await t.test(String(exceedsBudget), async (t) => {
      let now = Date.now();
      t.mock.method(Date, "now", () => now);
      let calls = 0;
      const result = await handleTravelScheduleRequest(scheduleRequest(), {}, {
        totalTimeoutMs: 100,
        fetchImpl: async () => {
          calls += 1;
          now += exceedsBudget ? 60 : 20;
          return new Response(calls === 1 ? railSearch : railDetail);
        },
      });
      assert.equal(calls, 2);
      if (exceedsBudget) assertScheduleDeadline(result);
      else {
        assert.equal(result.status, 200);
        assert.equal(result.body.stops[1].arrival, "2026-08-28T00:40:00+08:00");
      }
    });
  }
});

test("internal schedule budget cannot exceed the 15-second service maximum", async (t) => {
  for (const allowance of [undefined, 15000, 15001, Infinity, NaN, 0, -1, "1"]) {
    await t.test(String(allowance), async (t) => {
      let now = Date.now();
      t.mock.method(Date, "now", () => now);
      let calls = 0;
      const result = await handleTravelScheduleRequest(scheduleRequest(), {}, {
        totalTimeoutMs: allowance,
        fetchImpl: async () => { calls += 1; now += 15001; return new Response(railSearch); },
      });
      assertScheduleDeadline(result);
      assert.equal(calls, 1);
    });
  }
});

test("every JR serial source uses the same budget before any subsequent request", async (t) => {
  const cases = [
    { code: "はやて1", maximum: 5 },
    { code: "あさま1", maximum: 6 },
    { code: "みずほ1", maximum: 13 },
  ];
  for (const { code, maximum } of cases) {
    for (let stopAt = 1; stopAt <= maximum; stopAt += 1) {
      await t.test(`${code}/${stopAt}`, async (t) => {
        let now = Date.now();
        t.mock.method(Date, "now", () => now);
        let calls = 0;
        let odekakeSeeds = 0;
        let aborted = false;
        let cancelled = false;
        const result = await handleTravelScheduleRequest(scheduleRequest(code), {}, {
          totalTimeoutMs: 100,
          fetchImpl: async (value, init) => {
            calls += 1;
            if (calls === stopAt) {
              init.signal.addEventListener("abort", () => { aborted = true; }, { once: true });
              now += 101;
              return new Response(new ReadableStream({ cancel() { cancelled = true; } }));
            }
            const url = new URL(value);
            if (url.hostname === "jrhokkaidonorikae.com") return new Response("date not covered");
            if (url.hostname === "timetables.jreast.co.jp") return new Response(
              url.pathname.endsWith("list1039.html") ? '<a href="../2608/timetable-v/003d1.html">issue</a>' : emptyEastGrid,
            );
            if (url.hostname === "www.jrkyushu-timetable.jp") return new Response("指定された日付に運行はありません");
            if (url.hostname === "timetable.jr-odekake.net") {
              if (url.pathname.includes("/train-timetable/")) return new Response(odekakeDetail(code));
              odekakeSeeds += 1;
              const lastSeed = code === "あさま1" ? 2 : 6;
              return new Response(odekakeSeeds === lastSeed
                ? `<a href="/train-timetable/synthetic?date=20260827">${code}号</a>` : emptyOdekake);
            }
            throw new Error("Unexpected synthetic JR source");
          },
        });
        assertScheduleDeadline(result);
        assert.equal(calls, stopAt);
        assert.equal(aborted, true);
        assert.equal(cancelled, true);
      });
    }
  }
});

test("JR fallback preserves success, error priority, and the non-fallback error set", async (t) => {
  for (const primary of ["coverage", "not-found", "invalid-json-shape", "http", "rate-limit"]) {
    await t.test(primary, async () => {
      let fallbackCalls = 0;
      const result = await handleTravelScheduleRequest(scheduleRequest("あさま1"), {}, {
        fetchImpl: async (value) => {
          const url = new URL(value);
          if (url.hostname === "timetables.jreast.co.jp") {
            if (primary === "http") return new Response("", { status: 503 });
            if (primary === "rate-limit") return new Response("", { status: 429 });
            if (primary === "invalid-json-shape") return new Response("invalid timetable structure");
            return new Response(url.pathname.endsWith("list1039.html")
              ? `<a href="../${primary === "coverage" ? "2501" : "2608"}/timetable-v/004d1.html">issue</a>`
              : emptyEastGrid);
          }
          fallbackCalls += 1;
          if (url.pathname.includes("/train-timetable/")) return new Response(odekakeDetail("あさま1"));
          return new Response('<a href="/train-timetable/synthetic?date=20260827">あさま1号</a>');
        },
      });
      if (["coverage", "not-found"].includes(primary)) {
        assert.equal(result.status, 200);
        assert.equal(result.body.stops[1].arrival, "2026-08-28T00:40:00+09:00");
        assert.equal(fallbackCalls, 2);
      } else {
        assert.equal(result.status, 502);
        assert.equal(result.body.error.code, {
          "invalid-json-shape": "upstream_invalid_response", http: "upstream_http_error", "rate-limit": "upstream_rate_limited",
        }[primary]);
        assert.equal(fallbackCalls, 0);
      }
    });
  }
  const result = await handleTravelScheduleRequest(scheduleRequest("あさま1"), {}, {
    fetchImpl: async (value) => new Response(new URL(value).hostname === "timetables.jreast.co.jp"
      ? '<a href="../2501/timetable-v/004d1.html">issue</a>' : emptyOdekake),
  });
  assert.equal(result.status, 502);
  assert.equal(result.body.error.code, "coverage_unavailable");
});

test("travel response cleanup never waits or changes HTTP and byte-limit errors", async (t) => {
  for (const kind of ["http", "rate-limit", "declared-size", "stream-size", "invalid-chunk"]) {
    for (const cleanup of ["slow", "reject"]) {
      await t.test(`${kind}/${cleanup}`, async () => {
        let finish;
        let finished = false;
        let cancels = 0;
        let calls = 0;
        const cancellation = new Promise((resolve) => { finish = resolve; }).then(() => { finished = true; });
        const timer = setTimeout(finish, 100);
        const body = new ReadableStream({
          start(controller) {
            if (kind === "stream-size") controller.enqueue(new Uint8Array(2 * 1024 * 1024 + 1));
            if (kind === "invalid-chunk") controller.enqueue("synthetic invalid chunk");
          },
          cancel() {
            cancels += 1;
            return cleanup === "reject" ? Promise.reject(new Error("synthetic cleanup failure")) : cancellation;
          },
        });
        try {
          const result = await handleTravelScheduleRequest(scheduleRequest(), {}, {
            totalTimeoutMs: 500,
            fetchImpl: async () => {
              calls += 1;
              return new Response(body, {
                status: kind === "http" ? 503 : kind === "rate-limit" ? 429 : 200,
                headers: kind === "declared-size" ? { "content-length": "2097153" } : {},
              });
            },
          });
          assert.equal(result.status, 502);
          assert.equal(result.body.error.code, kind === "http" ? "upstream_http_error"
            : kind === "rate-limit" ? "upstream_rate_limited" : "upstream_invalid_response");
          assert.equal(calls, 1);
          assert.equal(cancels, 1);
          assert.equal(finished, false);
          await new Promise((resolve) => setImmediate(resolve));
        } finally {
          clearTimeout(timer);
          finish();
          await cancellation;
        }
      });
    }
  }
});
