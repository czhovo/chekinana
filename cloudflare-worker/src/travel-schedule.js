import he from "he";

const __name = (value) => value;

// src/travel-airport-names.js
var TRAVEL_AIRPORT_NAME_GROUPS = Object.freeze({
  mainland: Object.freeze([
    Object.freeze(["PEK", "\u5317\u4EAC\u9996\u90FD"]),
    Object.freeze(["PKX", "\u5317\u4EAC\u5927\u5174"]),
    Object.freeze(["TSN", "\u5929\u6D25\u6EE8\u6D77"]),
    Object.freeze(["SJW", "\u77F3\u5BB6\u5E84\u6B63\u5B9A"]),
    Object.freeze(["TYN", "\u592A\u539F\u6B66\u5BBF"]),
    Object.freeze(["HET", "\u547C\u548C\u6D69\u7279\u767D\u5854"]),
    Object.freeze(["DSN", "\u9102\u5C14\u591A\u65AF\u4F0A\u91D1\u970D\u6D1B"]),
    Object.freeze(["SHE", "\u6C88\u9633\u6843\u4ED9"]),
    Object.freeze(["DLC", "\u5927\u8FDE\u5468\u6C34\u5B50"]),
    Object.freeze(["CGQ", "\u957F\u6625\u9F99\u5609"]),
    Object.freeze(["HRB", "\u54C8\u5C14\u6EE8\u592A\u5E73"]),
    Object.freeze(["YNJ", "\u5EF6\u5409\u671D\u9633\u5DDD"]),
    Object.freeze(["MDG", "\u7261\u4E39\u6C5F\u6D77\u6D6A"]),
    Object.freeze(["PVG", "\u4E0A\u6D77\u6D66\u4E1C"]),
    Object.freeze(["SHA", "\u4E0A\u6D77\u8679\u6865"]),
    Object.freeze(["NKG", "\u5357\u4EAC\u7984\u53E3"]),
    Object.freeze(["HGH", "\u676D\u5DDE\u8427\u5C71"]),
    Object.freeze(["NGB", "\u5B81\u6CE2\u680E\u793E"]),
    Object.freeze(["WNZ", "\u6E29\u5DDE\u9F99\u6E7E"]),
    Object.freeze(["WUX", "\u82CF\u5357\u7855\u653E"]),
    Object.freeze(["HFE", "\u5408\u80A5\u65B0\u6865"]),
    Object.freeze(["KHN", "\u5357\u660C\u660C\u5317"]),
    Object.freeze(["FOC", "\u798F\u5DDE\u957F\u4E50"]),
    Object.freeze(["XMN", "\u53A6\u95E8\u9AD8\u5D0E"]),
    Object.freeze(["JJN", "\u6CC9\u5DDE\u664B\u6C5F"]),
    Object.freeze(["TAO", "\u9752\u5C9B\u80F6\u4E1C"]),
    Object.freeze(["TNA", "\u6D4E\u5357\u9065\u5899"]),
    Object.freeze(["YNT", "\u70DF\u53F0\u84EC\u83B1"]),
    Object.freeze(["WEH", "\u5A01\u6D77\u5927\u6C34\u6CCA"]),
    Object.freeze(["RIZ", "\u65E5\u7167\u5C71\u5B57\u6CB3"]),
    Object.freeze(["CGO", "\u90D1\u5DDE\u65B0\u90D1"]),
    Object.freeze(["WUH", "\u6B66\u6C49\u5929\u6CB3"]),
    Object.freeze(["CSX", "\u957F\u6C99\u9EC4\u82B1"]),
    Object.freeze(["YIH", "\u5B9C\u660C\u4E09\u5CE1"]),
    Object.freeze(["DYG", "\u5F20\u5BB6\u754C\u8377\u82B1"]),
    Object.freeze(["CAN", "\u5E7F\u5DDE\u767D\u4E91"]),
    Object.freeze(["SZX", "\u6DF1\u5733\u5B9D\u5B89"]),
    Object.freeze(["ZUH", "\u73E0\u6D77\u91D1\u6E7E"]),
    Object.freeze(["SWA", "\u63ED\u9633\u6F6E\u6C55"]),
    Object.freeze(["HAK", "\u6D77\u53E3\u7F8E\u5170"]),
    Object.freeze(["SYX", "\u4E09\u4E9A\u51E4\u51F0"]),
    Object.freeze(["NNG", "\u5357\u5B81\u5434\u5729"]),
    Object.freeze(["KWL", "\u6842\u6797\u4E24\u6C5F"]),
    Object.freeze(["CKG", "\u91CD\u5E86\u6C5F\u5317"]),
    Object.freeze(["CTU", "\u6210\u90FD\u53CC\u6D41"]),
    Object.freeze(["TFU", "\u6210\u90FD\u5929\u5E9C"]),
    Object.freeze(["KWE", "\u8D35\u9633\u9F99\u6D1E\u5821"]),
    Object.freeze(["KMG", "\u6606\u660E\u957F\u6C34"]),
    Object.freeze(["DLU", "\u5927\u7406\u51E4\u4EEA"]),
    Object.freeze(["LJG", "\u4E3D\u6C5F\u4E09\u4E49"]),
    Object.freeze(["JHG", "\u897F\u53CC\u7248\u7EB3\u560E\u6D12"]),
    Object.freeze(["LXA", "\u62C9\u8428\u8D21\u560E"]),
    Object.freeze(["ENH", "\u6069\u65BD\u8BB8\u5BB6\u576A"]),
    Object.freeze(["JZH", "\u4E5D\u5BE8\u9EC4\u9F99"]),
    Object.freeze(["XIY", "\u897F\u5B89\u54B8\u9633"]),
    Object.freeze(["LHW", "\u5170\u5DDE\u4E2D\u5DDD"]),
    Object.freeze(["XNN", "\u897F\u5B81\u66F9\u5BB6\u5821"]),
    Object.freeze(["INC", "\u94F6\u5DDD\u6CB3\u4E1C"]),
    Object.freeze(["URC", "\u4E4C\u9C81\u6728\u9F50\u5929\u5C71"]),
    Object.freeze(["KHG", "\u5580\u4EC0\u5F95\u5B81"]),
    Object.freeze(["KRL", "\u5E93\u5C14\u52D2\u68A8\u57CE"]),
    Object.freeze(["AKU", "\u963F\u514B\u82CF\u7EA2\u65D7\u5761"]),
    Object.freeze(["HTN", "\u548C\u7530\u6606\u5188"]),
    Object.freeze(["YIN", "\u4F0A\u7281\u4F0A\u5B81"]),
    Object.freeze(["DNH", "\u6566\u714C\u83AB\u9AD8"])
  ]),
  hongKongMacauTaiwan: Object.freeze([
    Object.freeze(["HKG", "\u9999\u6E2F"]),
    Object.freeze(["MFM", "\u6FB3\u95E8"]),
    Object.freeze(["TPE", "\u53F0\u6E7E\u6843\u56ED"]),
    Object.freeze(["TSA", "\u53F0\u5317\u677E\u5C71"]),
    Object.freeze(["KHH", "\u9AD8\u96C4"]),
    Object.freeze(["RMQ", "\u53F0\u4E2D"]),
    Object.freeze(["TNN", "\u53F0\u5357"]),
    Object.freeze(["HUN", "\u82B1\u83B2"]),
    Object.freeze(["MZG", "\u6F8E\u6E56"]),
    Object.freeze(["KNH", "\u91D1\u95E8"]),
    Object.freeze(["TTT", "\u53F0\u4E1C"]),
    Object.freeze(["CYI", "\u5609\u4E49"]),
    Object.freeze(["LZN", "\u9A6C\u7956\u5357\u7AFF"]),
    Object.freeze(["MFK", "\u9A6C\u7956\u5317\u7AFF"]),
    Object.freeze(["KYD", "\u5170\u5C7F"])
  ]),
  japan: Object.freeze([
    Object.freeze(["NRT", "\u6771\u4EAC\u6210\u7530"]),
    Object.freeze(["HND", "\u6771\u4EAC\u7FBD\u7530"]),
    Object.freeze(["KIX", "\u5927\u962A\u95A2\u897F"]),
    Object.freeze(["ITM", "\u5927\u962A"]),
    Object.freeze(["NGO", "\u540D\u53E4\u5C4B\u4E2D\u90E8\u56FD\u969B"]),
    Object.freeze(["NKM", "\u540D\u53E4\u5C4B"]),
    Object.freeze(["CTS", "\u672D\u5E4C\u65B0\u5343\u6B73"]),
    Object.freeze(["OKD", "\u672D\u5E4C\u4E18\u73E0"]),
    Object.freeze(["AKJ", "\u65ED\u5DDD"]),
    Object.freeze(["HKD", "\u51FD\u9928"]),
    Object.freeze(["KUH", "\u91E7\u8DEF"]),
    Object.freeze(["OBO", "\u5E2F\u5E83"]),
    Object.freeze(["MMB", "\u5973\u6E80\u5225"]),
    Object.freeze(["AOJ", "\u9752\u68EE"]),
    Object.freeze(["HNA", "\u3044\u308F\u3066\u82B1\u5DFB"]),
    Object.freeze(["AXT", "\u79CB\u7530"]),
    Object.freeze(["SDJ", "\u4ED9\u53F0"]),
    Object.freeze(["FKS", "\u798F\u5CF6"]),
    Object.freeze(["IBR", "\u8328\u57CE"]),
    Object.freeze(["KIJ", "\u65B0\u6F5F"]),
    Object.freeze(["TOY", "\u5BCC\u5C71\u304D\u3068\u304D\u3068"]),
    Object.freeze(["KMQ", "\u5C0F\u677E"]),
    Object.freeze(["FSZ", "\u5BCC\u58EB\u5C71\u9759\u5CA1"]),
    Object.freeze(["UKB", "\u795E\u6238"]),
    Object.freeze(["OKJ", "\u5CA1\u5C71\u6843\u592A\u90CE"]),
    Object.freeze(["HIJ", "\u5E83\u5CF6"]),
    Object.freeze(["TAK", "\u9AD8\u677E"]),
    Object.freeze(["MYJ", "\u677E\u5C71"]),
    Object.freeze(["KCZ", "\u9AD8\u77E5\u9F8D\u99AC"]),
    Object.freeze(["FUK", "\u798F\u5CA1"]),
    Object.freeze(["KKJ", "\u5317\u4E5D\u5DDE"]),
    Object.freeze(["HSG", "\u4E5D\u5DDE\u4F50\u8CC0"]),
    Object.freeze(["NGS", "\u9577\u5D0E"]),
    Object.freeze(["KMJ", "\u963F\u8607\u304F\u307E\u3082\u3068"]),
    Object.freeze(["OIT", "\u5927\u5206"]),
    Object.freeze(["KMI", "\u5BAE\u5D0E\u30D6\u30FC\u30B2\u30F3\u30D3\u30EA\u30A2"]),
    Object.freeze(["KOJ", "\u9E7F\u5150\u5CF6"]),
    Object.freeze(["OKA", "\u90A3\u8987"]),
    Object.freeze(["MMY", "\u5BAE\u53E4"]),
    Object.freeze(["SHI", "\u4E0B\u5730\u5CF6"]),
    Object.freeze(["ISG", "\u5357\u306C\u5CF6\u77F3\u57A3"]),
    Object.freeze(["ASJ", "\u5944\u7F8E"])
  ])
});
var TRAVEL_AIRPORT_NAME_ENTRIES = Object.freeze(
  Object.values(TRAVEL_AIRPORT_NAME_GROUPS).flat()
);
var TRAVEL_AIRPORT_NAMES_BY_IATA = Object.freeze(
  Object.fromEntries(TRAVEL_AIRPORT_NAME_ENTRIES)
);

// src/travel-schedule.js
var TRAVEL_SCHEDULE_ENDPOINT = "/api/v1/schedule";
var MAX_UPSTREAM_BYTES2 = 2 * 1024 * 1024;
const TRAVEL_SERVICE_TIMEOUT_MS = 15_000;
var FLIGHT_REQUEST_INTERVAL_MS = 1050;
var FLIGHT_HOST = "aerodatabox.p.rapidapi.com";
var FLIGHT_BASE = `https://${FLIGHT_HOST}`;
var CHINA_RAIL_SEARCH = "https://search.12306.cn/search/v1/train/search";
var CHINA_RAIL_INFO = "https://kyfw.12306.cn/otn/queryTrainInfo/query";
var JR_EAST_INDEX = "https://timetables.jreast.co.jp/timetable/list1039.html";
var JR_HOKKAIDO_GRIDS = [
  "https://jrhokkaidonorikae.com/vtime/vtime.php?s=30",
  "https://jrhokkaidonorikae.com/vtime/vtime.php?s=31"
];
var JR_KYUSHU_BASE = "https://www.jrkyushu-timetable.jp";
var JR_ODEKAKE_BASE = "https://timetable.jr-odekake.net";
var JR_NAMES = [
  "\u306E\u305E\u307F",
  "\u3072\u304B\u308A",
  "\u3053\u3060\u307E",
  "\u307F\u305A\u307B",
  "\u3055\u304F\u3089",
  "\u306F\u3084\u3076\u3055",
  "\u3084\u307E\u3073\u3053",
  "\u306A\u3059\u306E",
  "\u3053\u307E\u3061",
  "\u3064\u3070\u3055",
  "\u3068\u304D",
  "\u305F\u306B\u304C\u308F",
  "\u304B\u304C\u3084\u304D",
  "\u306F\u304F\u305F\u304B",
  "\u3064\u308B\u304E",
  "\u3042\u3055\u307E",
  "\u306F\u3084\u3066",
  "\u304B\u3082\u3081",
  "\u3064\u3070\u3081"
];
var JR_ROMAJI = /* @__PURE__ */ new Map([
  ["NOZOMI", "\u306E\u305E\u307F"],
  ["HIKARI", "\u3072\u304B\u308A"],
  ["KODAMA", "\u3053\u3060\u307E"],
  ["MIZUHO", "\u307F\u305A\u307B"],
  ["SAKURA", "\u3055\u304F\u3089"],
  ["HAYABUSA", "\u306F\u3084\u3076\u3055"],
  ["YAMABIKO", "\u3084\u307E\u3073\u3053"],
  ["NASUNO", "\u306A\u3059\u306E"],
  ["KOMACHI", "\u3053\u307E\u3061"],
  ["TSUBASA", "\u3064\u3070\u3055"],
  ["TOKI", "\u3068\u304D"],
  ["TANIGAWA", "\u305F\u306B\u304C\u308F"],
  ["KAGAYAKI", "\u304B\u304C\u3084\u304D"],
  ["HAKUTAKA", "\u306F\u304F\u305F\u304B"],
  ["TSURUGI", "\u3064\u308B\u304E"],
  ["ASAMA", "\u3042\u3055\u307E"],
  ["HAYATE", "\u306F\u3084\u3066"],
  ["KAMOME", "\u304B\u3082\u3081"],
  ["TSUBAME", "\u3064\u3070\u3081"]
]);
var JR_EAST_GROUPS = /* @__PURE__ */ new Map([
  ["tokaido", /* @__PURE__ */ new Set(["\u306E\u305E\u307F", "\u3072\u304B\u308A", "\u3053\u3060\u307E"])],
  ["tohoku", /* @__PURE__ */ new Set(["\u306F\u3084\u3076\u3055", "\u306F\u3084\u3066", "\u3084\u307E\u3073\u3053", "\u306A\u3059\u306E", "\u3053\u307E\u3061", "\u3064\u3070\u3055"])],
  ["joetsu", /* @__PURE__ */ new Set(["\u3068\u304D", "\u305F\u306B\u304C\u308F", "\u3042\u3055\u307E", "\u306F\u304F\u305F\u304B", "\u304B\u304C\u3084\u304D", "\u3064\u308B\u304E"])]
]);
var JR_ODEKAKE_SEEDS = {
  west: [
    "2784005001",
    "2784005002",
    "2815002001",
    "2815002002",
    "4102002001",
    "4102002002"
  ],
  hokuriku: ["2663006001", "2663006002"]
};
var JR_KYUSHU_SEEDS = {
  kyushu: [
    "/cgi-bin/sp/sp-tt_dep.cgi/2828300/",
    "/cgi-bin/sp/sp-tt_dep.cgi/2900700/",
    "/cgi-bin/sp/sp-tt_dep.cgi/2862600/",
    "/cgi-bin/sp/sp-tt_dep.cgi/2862601/",
    "/cgi-bin/sp/sp-tt_dep.cgi/2939500/",
    "/cgi-bin/sp/sp-tt_dep.cgi/2939501/"
  ],
  nishikyushu: [
    "/cgi-bin/sp/sp-tt_dep.cgi/2839500/1000",
    "/cgi-bin/sp/sp-tt_dep.cgi/2853300/1000",
    "/cgi-bin/sp/sp-tt_dep.cgi/1122700/",
    "/cgi-bin/sp/sp-tt_dep.cgi/1122701/"
  ]
};
var TravelScheduleError = class extends Error {
  static {
    __name(this, "TravelScheduleError");
  }
  constructor(status, code, message) {
    super(message);
    this.name = "TravelScheduleError";
    this.status = status;
    this.code = code;
  }
};
function fail(status, code, message) {
  throw new TravelScheduleError(status, code, message);
}
__name(fail, "fail");
function isPlainObject4(value) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}
__name(isPlainObject4, "isPlainObject");
function pad(value) {
  return String(value).padStart(2, "0");
}
__name(pad, "pad");
function dateKey(year, month, day) {
  return `${year}-${pad(month)}-${pad(day)}`;
}
__name(dateKey, "dateKey");
function parseDate(value) {
  if (typeof value !== "string") return null;
  const match = /^(\d{4})-(\d{2})-(\d{2})$/u.exec(value);
  if (!match) return null;
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const epoch = Date.UTC(year, month - 1, day);
  const parsed = new Date(epoch);
  if (parsed.getUTCFullYear() !== year || parsed.getUTCMonth() !== month - 1 || parsed.getUTCDate() !== day) return null;
  return { year, month, day, epoch, iso: value };
}
__name(parseDate, "parseDate");
function dateFromEpoch(epoch) {
  return new Date(epoch).toISOString().slice(0, 10);
}
__name(dateFromEpoch, "dateFromEpoch");
function addDays(date, count) {
  const parsed = parseDate(date);
  if (!parsed) fail(400, "invalid_date", "date must use YYYY-MM-DD");
  return dateFromEpoch(parsed.epoch + count * 864e5);
}
__name(addDays, "addDays");
function fullIso(date, time, offset) {
  if (!parseDate(date) || !validClock(time)) {
    fail(502, "upstream_invalid_response", "Upstream schedule time is invalid");
  }
  return `${date}T${time}:00${offset}`;
}
__name(fullIso, "fullIso");
function validClock(value) {
  if (typeof value !== "string") return false;
  const match = /^(\d{2}):(\d{2})$/u.exec(value);
  return Boolean(match && Number(match[1]) < 24 && Number(match[2]) < 60);
}
__name(validClock, "validClock");
function clockMinutes(value) {
  if (!validClock(value)) return null;
  return Number(value.slice(0, 2)) * 60 + Number(value.slice(3));
}
__name(clockMinutes, "clockMinutes");
function normalizeCode(value) {
  if (typeof value !== "string") fail(400, "invalid_code", "code is required");
  const normalized = value.normalize("NFKC").trim().replace(/\s+/gu, "");
  if (!normalized) fail(400, "invalid_code", "code is required");
  const upper = normalized.toUpperCase();
  const roman = /^([A-Z]+)(\d+)号?$/u.exec(upper);
  if (roman && JR_ROMAJI.has(roman[1])) return `${JR_ROMAJI.get(roman[1])}${roman[2]}`;
  const japanese = new RegExp(`^(${JR_NAMES.join("|")})(\\d+)\u53F7?$`, "u").exec(normalized);
  if (japanese) return `${japanese[1]}${japanese[2]}`;
  return upper;
}
__name(normalizeCode, "normalizeCode");
function jrCodeParts(code) {
  const match = /^(.+?)(\d+)$/u.exec(code);
  if (!match || !JR_NAMES.includes(match[1])) return null;
  return { name: match[1], number: match[2] };
}
__name(jrCodeParts, "jrCodeParts");
function normalizeLocalIso(value) {
  if (typeof value !== "string") return null;
  const match = /^(\d{4}-\d{2}-\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?(Z|[+-]\d{2}:\d{2})$/u.exec(value);
  if (!match || !parseDate(match[1])) return null;
  const hour = Number(match[2]);
  const minute = Number(match[3]);
  const second = match[4] === void 0 ? 0 : Number(match[4]);
  if (hour > 23 || minute > 59 || second > 59) return null;
  let offset = match[5];
  if (offset === "Z") offset = "+00:00";
  if (offset !== "+00:00" && offset !== "-00:00") {
    const offsetHour = Number(offset.slice(1, 3));
    const offsetMinute = Number(offset.slice(4));
    if (offsetHour > 23 || offsetMinute > 59) return null;
  }
  return {
    date: match[1],
    iso: `${match[1]}T${match[2]}:${match[3]}:${pad(second)}${offset}`
  };
}
__name(normalizeLocalIso, "normalizeLocalIso");
function utcMillis(value) {
  const parsed = normalizeLocalIso(value);
  if (!parsed) fail(502, "upstream_invalid_response", "Flight scheduled UTC is invalid");
  const epoch = Date.parse(value.replace(" ", "T"));
  if (!Number.isFinite(epoch)) fail(502, "upstream_invalid_response", "Flight scheduled UTC is invalid");
  return epoch;
}
__name(utcMillis, "utcMillis");
function cancelTravelBody(body, reason) {
  if (!body || typeof body.cancel !== "function") return;
  try {
    Promise.resolve(body.cancel(reason)).catch(() => {});
  } catch {
    // Cleanup must not delay or replace the schedule result.
  }
}

class TravelRequestBudget {
  constructor(milliseconds) {
    const allowance = Number.isFinite(milliseconds) && milliseconds >= 1
      && milliseconds <= TRAVEL_SERVICE_TIMEOUT_MS ? milliseconds : TRAVEL_SERVICE_TIMEOUT_MS;
    this.expiresAt = Date.now() + allowance;
    this.controller = new AbortController();
    this.expired = false;
    this.closed = false;
    this.deadline = new Promise((resolve) => { this.resolveDeadline = resolve; });
    this.timer = setTimeout(() => this.expire(), allowance);
  }

  expire() {
    if (this.expired) return;
    this.expired = true;
    this.controller.abort();
    this.resolveDeadline();
  }

  check() {
    if (this.closed || this.expired || Date.now() >= this.expiresAt) {
      this.expire();
      fail(502, "upstream_unavailable", "Upstream service is unavailable");
    }
  }

  async run(operation) {
    this.check();
    const pending = Promise.resolve().then(() => {
      this.check();
      return operation();
    }).then(
      (value) => {
        if (value instanceof Response && (this.closed || this.expired || Date.now() >= this.expiresAt)) {
          cancelTravelBody(value.body, "schedule response arrived after its deadline");
        }
        return { ok: true, value };
      },
      (error) => ({ ok: false, error }),
    );
    const outcome = await Promise.race([pending, this.deadline]);
    try {
      this.check();
    } catch (error) {
      if (outcome?.ok && outcome.value instanceof Response) {
        cancelTravelBody(outcome.value.body, "schedule response deadline elapsed");
      }
      throw error;
    }
    if (!outcome.ok) throw outcome.error;
    return outcome.value;
  }

  dispose() {
    this.closed = true;
    clearTimeout(this.timer);
    this.controller.abort();
  }
}

async function readBoundedText(response, budget, maximum = MAX_UPSTREAM_BYTES2) {
  budget.check();
  const declared = response.headers.get("content-length");
  if (declared !== null && (!/^\d+$/u.test(declared) || Number(declared) > maximum)) {
    fail(502, "upstream_invalid_response", "Upstream response is too large");
  }
  if (!response.body || typeof response.body.getReader !== "function") return "";
  const reader = response.body.getReader();
  const chunks = [];
  let total = 0;
  let completed = false;
  try {
    while (true) {
      const part = await budget.run(() => reader.read());
      if (part.done) {
        completed = true;
        break;
      }
      if (!(part.value instanceof Uint8Array)) {
        fail(502, "upstream_invalid_response", "Upstream response stream is invalid");
      }
      total += part.value.byteLength;
      if (total > maximum) {
        fail(502, "upstream_invalid_response", "Upstream response is too large");
      }
      chunks.push(part.value);
    }
  } catch (error) {
    if (error instanceof TravelScheduleError) throw error;
    fail(502, "upstream_unavailable", "Upstream response could not be read");
  } finally {
    if (!completed) cancelTravelBody(reader, "schedule response read failed or timed out");
    try {
      reader.releaseLock();
    } catch {
    }
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  let text;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    fail(502, "upstream_invalid_response", "Upstream response is not valid UTF-8");
  }
  budget.check();
  return text;
}
__name(readBoundedText, "readBoundedText");
async function upstreamResponse(url, init, fetchImpl, budget) {
  let response;
  try {
    response = await budget.run(() => fetchImpl(url, { ...init, signal: budget.controller.signal }));
  } catch (error) {
    if (error instanceof TravelScheduleError) throw error;
    fail(502, "upstream_unavailable", "Upstream service is unavailable");
  }
  if (!(response instanceof Response)) {
    fail(502, "upstream_invalid_response", "Upstream response is invalid");
  }
  if (response.status === 429) {
    cancelTravelBody(response.body, "schedule upstream rate limited");
    fail(502, "upstream_rate_limited", "Upstream rate limit was exceeded");
  }
  return response;
}
__name(upstreamResponse, "upstreamResponse");
async function getText(url, fetchImpl, budget) {
  const response = await upstreamResponse(url, {
    method: "GET",
    headers: { accept: "text/html,*/*" }
  }, fetchImpl, budget);
  try {
    if (!response.ok) fail(502, "upstream_http_error", "Upstream request failed");
    return await readBoundedText(response, budget);
  } finally {
    cancelTravelBody(response.body, "schedule text response finished");
  }
}
__name(getText, "getText");
async function getJson(url, fetchImpl, budget, options = {}) {
  const response = await upstreamResponse(url, {
    method: "GET",
    headers: options.headers || { accept: "application/json" }
  }, fetchImpl, budget);
  try {
    if (response.status === 204 && options.allowNoContent === true) return [];
    if (!response.ok) fail(502, "upstream_http_error", "Upstream request failed");
    const text = await readBoundedText(response, budget);
    let value;
    try {
      value = JSON.parse(text);
    } catch {
      fail(502, "upstream_invalid_response", "Upstream returned invalid JSON");
    }
    budget.check();
    return value;
  } finally {
    cancelTravelBody(response.body, "schedule JSON response finished");
  }
}
__name(getJson, "getJson");
async function defaultWait(milliseconds, signal) {
  await new Promise((resolve, reject) => {
    let timer;
    const finish = (error) => {
      clearTimeout(timer);
      signal.removeEventListener("abort", onAbort);
      if (error) reject(error);
      else resolve();
    };
    const onAbort = () => finish(new DOMException("Schedule wait cancelled", "AbortError"));
    if (signal.aborted) { onAbort(); return; }
    signal.addEventListener("abort", onAbort, { once: true });
    timer = setTimeout(() => finish(), milliseconds);
  });
}
__name(defaultWait, "defaultWait");
function outputSchedule(operator, fullStops) {
  if (!Array.isArray(fullStops) || fullStops.length < 2) {
    fail(502, "upstream_invalid_response", "Schedule has no usable stops");
  }
  const stops = fullStops.map((stop) => ({
    name: typeof stop.name === "string" ? stop.name : "",
    arrival: typeof stop.arrival === "string" ? stop.arrival : null,
    departure: typeof stop.departure === "string" ? stop.departure : null
  }));
  stops[0].arrival = null;
  stops.at(-1).departure = null;
  if (stops.some((stop, index) => !stop.name || index === 0 && stop.departure === null || index === stops.length - 1 && stop.arrival === null || index > 0 && index < stops.length - 1 && (stop.arrival === null || stop.departure === null))) {
    fail(502, "upstream_invalid_response", "Schedule endpoints or stops are incomplete");
  }
  return {
    operator,
    stops: stops.map((stop, index) => ({
      name: stop.name,
      ...index > 0 ? { arrival: stop.arrival } : {},
      ...index < stops.length - 1 ? { departure: stop.departure } : {}
    }))
  };
}
__name(outputSchedule, "outputSchedule");
function normalizedAirportIata(value) {
  if (typeof value !== "string") return null;
  const normalized = value.normalize("NFKC").trim().toUpperCase();
  return normalized || null;
}
__name(normalizedAirportIata, "normalizedAirportIata");
function airportName(airport, iata) {
  const mapped = Object.hasOwn(TRAVEL_AIRPORT_NAMES_BY_IATA, iata) ? TRAVEL_AIRPORT_NAMES_BY_IATA[iata] : null;
  if (mapped !== null) return mapped;
  if (typeof airport.name !== "string") {
    fail(502, "upstream_invalid_response", "Flight airport name is invalid");
  }
  const withoutSuffix = airport.name.replace(/\s*International Airport\s*$/iu, "").replace(/\s*Airport\s*$/iu, "");
  const normalized = withoutSuffix.normalize("NFKC").replace(/\s+/gu, "");
  if (!normalized) {
    fail(502, "upstream_invalid_response", "Flight airport name is invalid");
  }
  return normalized;
}
__name(airportName, "airportName");
function normalizedTerminal(value) {
  if (typeof value !== "string") return null;
  const compact = value.normalize("NFKC").trim().replace(/\s+/gu, "");
  if (!compact) return null;
  if (/^\d+[A-Z]?$/iu.test(compact)) return `T${compact.toUpperCase()}`;
  const prefixed = /^(?:TERMINAL|T)(.+)$/iu.exec(compact);
  if (prefixed) return `T${prefixed[1].toUpperCase()}`;
  return compact;
}
__name(normalizedTerminal, "normalizedTerminal");
function materializeFlightStopName(stop) {
  const terminals = [...stop.terminals];
  return terminals.length > 0 ? `${stop.name}${terminals.join("/")}` : stop.name;
}
__name(materializeFlightStopName, "materializeFlightStopName");
function flightLeg(item) {
  if (!isPlainObject4(item) || !isPlainObject4(item.departure) || !isPlainObject4(item.arrival)) {
    fail(502, "upstream_invalid_response", "Flight leg omitted endpoints");
  }
  const departure = item.departure;
  const arrival = item.arrival;
  if (!isPlainObject4(departure.airport) || !isPlainObject4(arrival.airport) || !isPlainObject4(departure.scheduledTime) || !isPlainObject4(arrival.scheduledTime)) {
    fail(502, "upstream_invalid_response", "Flight leg structure is invalid");
  }
  const depCode = normalizedAirportIata(departure.airport.iata);
  const arrCode = normalizedAirportIata(arrival.airport.iata);
  if (!depCode || !arrCode) {
    fail(502, "upstream_invalid_response", "Flight leg omitted airport code");
  }
  const depUtc = utcMillis(departure.scheduledTime.utc);
  const arrUtc = utcMillis(arrival.scheduledTime.utc);
  if (arrUtc < depUtc) fail(502, "upstream_invalid_response", "Flight arrival precedes departure");
  const depLocal = normalizeLocalIso(departure.scheduledTime.local);
  const arrLocal = normalizeLocalIso(arrival.scheduledTime.local);
  if (!depLocal || !arrLocal) {
    fail(502, "upstream_invalid_response", "Flight scheduled local time is invalid");
  }
  return {
    departure,
    arrival,
    depAirport: departure.airport,
    arrAirport: arrival.airport,
    depCode,
    arrCode,
    depUtc,
    arrUtc,
    depLocal,
    arrLocal
  };
}
__name(flightLeg, "flightLeg");
function parseFlightPayloads(payloads, code, date) {
  if (!Array.isArray(payloads) || payloads.length !== 2) {
    fail(502, "upstream_invalid_response", "Flight response collection is invalid");
  }
  const rawLegs = [];
  for (const payload of payloads) {
    if (!Array.isArray(payload)) fail(502, "upstream_invalid_response", "Flight response must be an array");
    for (const item of payload) rawLegs.push(item);
  }
  if (rawLegs.length === 0) fail(404, "schedule_not_found", "No flight schedule found");
  const seen = /* @__PURE__ */ new Set();
  const records = [];
  for (const item of rawLegs) {
    const record = flightLeg(item);
    const key = `${record.depCode}\0${record.arrCode}\0${record.depUtc}\0${record.arrUtc}`;
    if (!seen.has(key)) {
      seen.add(key);
      records.push(record);
    }
  }
  records.sort((left, right) => left.depUtc - right.depUtc);
  const successors = records.map(() => []);
  const predecessors = records.map(() => []);
  for (let left = 0; left < records.length; left += 1) {
    for (let right = 0; right < records.length; right += 1) {
      if (left === right || records[left].arrCode !== records[right].depCode) continue;
      const wait = records[right].depUtc - records[left].arrUtc;
      if (wait >= 0 && wait <= 864e5) {
        successors[left].push(right);
        predecessors[right].push(left);
      }
    }
  }
  const origins = records.map((record, index) => ({ record, index })).filter(({ record, index }) => record.depLocal.date === date && predecessors[index].length === 0).map(({ index }) => index);
  if (origins.length === 0) fail(404, "schedule_not_found", "No flight originates on the requested date");
  if (origins.length !== 1) {
    fail(502, "upstream_ambiguous_schedule", "Flight response contains multiple schedules");
  }
  const chain = [];
  const visited = /* @__PURE__ */ new Set();
  let current = origins[0];
  while (!visited.has(current)) {
    visited.add(current);
    chain.push(records[current]);
    const next = successors[current].filter((index) => !visited.has(index));
    if (next.length > 1) fail(502, "upstream_ambiguous_schedule", "Flight schedule branches");
    if (next.length === 0) break;
    current = next[0];
  }
  const fullStops = [];
  for (const leg of chain) {
    if (fullStops.length === 0) {
      fullStops.push({
        name: airportName(leg.depAirport, leg.depCode),
        code: leg.depCode,
        terminals: new Set([normalizedTerminal(leg.departure.terminal)].filter(Boolean)),
        arrival: null,
        departure: leg.depLocal.iso
      });
    } else {
      if (fullStops.at(-1).code !== leg.depCode) {
        fail(502, "upstream_invalid_response", "Flight chain is discontinuous");
      }
      const departureTerminal = normalizedTerminal(leg.departure.terminal);
      if (departureTerminal) fullStops.at(-1).terminals.add(departureTerminal);
      fullStops.at(-1).departure = leg.depLocal.iso;
    }
    fullStops.push({
      name: airportName(leg.arrAirport, leg.arrCode),
      code: leg.arrCode,
      terminals: new Set([normalizedTerminal(leg.arrival.terminal)].filter(Boolean)),
      arrival: leg.arrLocal.iso,
      departure: null
    });
  }
  for (const stop of fullStops) stop.name = materializeFlightStopName(stop);
  return outputSchedule(code.slice(0, 2), fullStops);
}
__name(parseFlightPayloads, "parseFlightPayloads");
async function queryFlight(code, date, rapidApiKey, fetchImpl, waitImpl, budget) {
  budget.check();
  if (typeof rapidApiKey !== "string" || !rapidApiKey) {
    fail(503, "configuration_error", "Flight schedule service is not configured");
  }
  const payloads = [];
  for (let index = 0; index < 2; index += 1) {
    budget.check();
    if (index > 0) await budget.run(() => waitImpl(FLIGHT_REQUEST_INTERVAL_MS, budget.controller.signal));
    const requestedDate = addDays(date, index);
    const url = `${FLIGHT_BASE}/flights/number/${encodeURIComponent(code)}/${requestedDate}?withAircraftImage=false&withLocation=false&withFlightPlan=false&dateLocalRole=Both`;
    payloads.push(await getJson(url, fetchImpl, budget, {
      allowNoContent: true,
      headers: {
        accept: "application/json",
        "X-RapidAPI-Key": rapidApiKey,
        "X-RapidAPI-Host": FLIGHT_HOST
      }
    }));
  }
  return parseFlightPayloads(payloads, code, date);
}
__name(queryFlight, "queryFlight");
function parseNonNegativeInteger(value) {
  if (typeof value === "number" && Number.isInteger(value) && value >= 0) return value;
  if (typeof value === "string" && /^\d+$/u.test(value)) return Number(value);
  return null;
}
__name(parseNonNegativeInteger, "parseNonNegativeInteger");
function parseChinaRailInfo(payload, date) {
  const rows = isPlainObject4(payload) && isPlainObject4(payload.data) ? payload.data.data : null;
  if (!Array.isArray(rows)) fail(502, "upstream_invalid_response", "12306 stop response is invalid");
  if (rows.length === 0) fail(404, "schedule_not_found", "No China Railway stops found");
  const fullStops = [];
  let previousOffset = 0;
  let previousMinutes = null;
  for (const row of rows) {
    if (!isPlainObject4(row) || typeof row.station_name !== "string" || !row.station_name) continue;
    const arrivalText = typeof row.arrive_time === "string" ? row.arrive_time.trim() : "";
    const departureText = typeof row.start_time === "string" ? row.start_time.trim() : "";
    const arrivalPresent = !["", "----", "--:--"].includes(arrivalText);
    const departurePresent = !["", "----", "--:--"].includes(departureText);
    const arrivalMinutes = arrivalPresent ? clockMinutes(arrivalText) : null;
    const departureMinutes = departurePresent ? clockMinutes(departureText) : null;
    if (arrivalPresent && arrivalMinutes === null || departurePresent && departureMinutes === null) {
      fail(502, "upstream_invalid_response", "12306 stop time is invalid");
    }
    let arrivalOffset = parseNonNegativeInteger(row.arrive_day_diff);
    if (arrivalOffset === null) arrivalOffset = previousOffset;
    arrivalOffset = Math.max(arrivalOffset, previousOffset);
    if (arrivalMinutes !== null && previousMinutes !== null && arrivalOffset === previousOffset && arrivalMinutes < previousMinutes) arrivalOffset += 1;
    let departureOffset = parseNonNegativeInteger(row.start_day_diff);
    const departureBase = arrivalPresent ? arrivalOffset : previousOffset;
    if (departureOffset === null) {
      departureOffset = departureBase;
      if (arrivalMinutes !== null && departureMinutes !== null && departureMinutes < arrivalMinutes) {
        departureOffset += 1;
      }
    }
    departureOffset = Math.max(departureOffset, departureBase, previousOffset);
    if (departurePresent) {
      previousOffset = departureOffset;
      previousMinutes = departureMinutes;
    } else if (arrivalPresent) {
      previousOffset = arrivalOffset;
      previousMinutes = arrivalMinutes;
    }
    const stationCode = row.station_telecode || row.station_code || null;
    fullStops.push({
      name: row.station_name,
      code: typeof stationCode === "string" && stationCode ? stationCode : null,
      arrival: arrivalPresent ? fullIso(addDays(date, arrivalOffset), arrivalText, "+08:00") : null,
      departure: departurePresent ? fullIso(addDays(date, departureOffset), departureText, "+08:00") : null
    });
  }
  return outputSchedule("cr", fullStops);
}
__name(parseChinaRailInfo, "parseChinaRailInfo");
async function queryChinaRail(code, date, fetchImpl, budget) {
  budget.check();
  const searchUrl = new URL(CHINA_RAIL_SEARCH);
  searchUrl.searchParams.set("keyword", code);
  searchUrl.searchParams.set("date", date.replaceAll("-", ""));
  const search = await getJson(searchUrl.toString(), fetchImpl, budget);
  if (!isPlainObject4(search) || !Array.isArray(search.data)) {
    fail(502, "upstream_invalid_response", "12306 search response is invalid");
  }
  if (search.data.length === 0) fail(404, "schedule_not_found", "No China Railway schedule found");
  const train = search.data.find((item) => isPlainObject4(item) && String(item.station_train_code || "").replace(/\s+/gu, "").toUpperCase() === code);
  if (!train) fail(404, "schedule_not_found", "No China Railway schedule found");
  if (typeof train.train_no !== "string" || !train.train_no) {
    fail(502, "upstream_invalid_response", "12306 omitted train number");
  }
  const infoUrl = new URL(CHINA_RAIL_INFO);
  infoUrl.searchParams.set("leftTicketDTO.train_no", train.train_no);
  infoUrl.searchParams.set("leftTicketDTO.train_date", date);
  infoUrl.searchParams.set("rand_code", "");
  return parseChinaRailInfo(await getJson(infoUrl.toString(), fetchImpl, budget), date);
}
__name(queryChinaRail, "queryChinaRail");
function attributeValue(attributes, name) {
  const expression = new RegExp(`(?:^|\\s)${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s>]+))`, "iu");
  const match = expression.exec(attributes || "");
  return match ? he.decode(match[1] ?? match[2] ?? match[3] ?? "") : null;
}
__name(attributeValue, "attributeValue");
function classSet(attributes) {
  return new Set((attributeValue(attributes, "class") || "").split(/\s+/u).filter(Boolean));
}
__name(classSet, "classSet");
function htmlText(fragment) {
  const withAlt = String(fragment || "").replace(/<img\b([^>]*)>/giu, (_, attributes) => attributeValue(attributes, "alt") || "");
  const withoutMarkup = withAlt.replace(/<script\b[\s\S]*?<\/script>/giu, "").replace(/<style\b[\s\S]*?<\/style>/giu, "").replace(/<[^>]+>/gu, "");
  return he.decode(he.decode(withoutMarkup)).replace(/\s+/gu, "");
}
__name(htmlText, "htmlText");
function parseCells(rowBody) {
  const cells = [];
  const expression = /<(td|th)\b([^>]*)>([\s\S]*?)<\/\1>/giu;
  let match;
  while ((match = expression.exec(rowBody)) !== null) {
    const links = parseAnchors(match[3]).map((anchor) => anchor.href);
    cells.push({
      text: htmlText(match[3]),
      classes: classSet(match[2]),
      links
    });
  }
  return cells;
}
__name(parseCells, "parseCells");
function parseRows(html) {
  const rows = [];
  const expression = /<tbody\b[^>]*>|<\/tbody>|<tr\b[^>]*>[\s\S]*?<\/tr>/giu;
  let tbodyClasses = /* @__PURE__ */ new Set();
  let match;
  while ((match = expression.exec(html)) !== null) {
    const token = match[0];
    if (/^<tbody\b/iu.test(token)) {
      tbodyClasses = classSet(token.slice(6, token.indexOf(">")));
      continue;
    }
    if (/^<\/tbody/iu.test(token)) {
      tbodyClasses = /* @__PURE__ */ new Set();
      continue;
    }
    const open = /^<tr\b([^>]*)>/iu.exec(token);
    if (!open) continue;
    const body = token.slice(open[0].length, token.toLowerCase().lastIndexOf("</tr>"));
    const cells = parseCells(body);
    if (cells.length > 0) {
      rows.push({ classes: classSet(open[1]), tbodyClasses: new Set(tbodyClasses), cells });
    }
  }
  return rows;
}
__name(parseRows, "parseRows");
function parseAnchors(html) {
  const anchors = [];
  const expression = /<a\b([^>]*)>([\s\S]*?)<\/a>/giu;
  let match;
  while ((match = expression.exec(html)) !== null) {
    const href = attributeValue(match[1], "href") || "";
    anchors.push({ href, text: htmlText(match[2]) });
  }
  return anchors;
}
__name(parseAnchors, "parseAnchors");
function gridTime(value) {
  const match = /^[^0-9]*(\d{1,2}):?(\d{2})[^0-9]*$/u.exec(value || "");
  if (!match || Number(match[1]) > 23 || Number(match[2]) > 59) return null;
  return `${pad(match[1])}:${match[2]}`;
}
__name(gridTime, "gridTime");
function nthMonday(year, month, firstPossibleDay) {
  const start = Date.UTC(year, month - 1, firstPossibleDay);
  const weekday = new Date(start).getUTCDay();
  const delta = (8 - weekday) % 7;
  return dateFromEpoch(start + delta * 864e5);
}
__name(nthMonday, "nthMonday");
function japanesePublicHolidays(date) {
  const value = parseDate(date);
  const year = value.year;
  const vernal = Math.floor(20.8431 + 0.242194 * (year - 1980) - Math.floor((year - 1980) / 4));
  const autumn = Math.floor(23.2488 + 0.242194 * (year - 1980) - Math.floor((year - 1980) / 4));
  const holidays = /* @__PURE__ */ new Set([
    dateKey(year, 1, 1),
    nthMonday(year, 1, 8),
    dateKey(year, 2, 11),
    dateKey(year, 2, 23),
    dateKey(year, 3, vernal),
    dateKey(year, 4, 29),
    dateKey(year, 5, 3),
    dateKey(year, 5, 4),
    dateKey(year, 5, 5),
    nthMonday(year, 7, 15),
    dateKey(year, 8, 11),
    nthMonday(year, 9, 15),
    dateKey(year, 9, autumn),
    nthMonday(year, 10, 8),
    dateKey(year, 11, 3),
    dateKey(year, 11, 23)
  ]);
  for (const holiday of [...holidays].sort()) {
    const parsed = parseDate(holiday);
    if (new Date(parsed.epoch).getUTCDay() === 0) {
      let substitute = addDays(holiday, 1);
      while (holidays.has(substitute)) substitute = addDays(substitute, 1);
      holidays.add(substitute);
    }
  }
  for (let cursor = Date.UTC(year, 0, 2); new Date(cursor).getUTCFullYear() === year; cursor += 864e5) {
    const candidate = dateFromEpoch(cursor);
    const weekday = new Date(cursor).getUTCDay();
    if (weekday >= 1 && weekday <= 5 && !holidays.has(candidate) && holidays.has(dateFromEpoch(cursor - 864e5)) && holidays.has(dateFromEpoch(cursor + 864e5))) holidays.add(candidate);
  }
  return holidays;
}
__name(japanesePublicHolidays, "japanesePublicHolidays");
function listedJapaneseDates(note, year) {
  const dates = /* @__PURE__ */ new Set();
  let currentMonth = null;
  const cleaned = note.replaceAll("\u301C", "\uFF5E").replaceAll("\uFF0D", "\uFF5E").replaceAll("\u30FB", " ");
  const expression = /(?:(\d{1,2})月)?(\d{1,2})日?(?:～(?:(\d{1,2})月)?(\d{1,2})日?)?/gu;
  let match;
  while ((match = expression.exec(cleaned)) !== null) {
    if (match[1] !== void 0) currentMonth = Number(match[1]);
    if (currentMonth === null) continue;
    const start = parseDate(dateKey(year, currentMonth, Number(match[2])));
    if (!start) continue;
    dates.add(start.iso);
    if (match[4] !== void 0) {
      const endMonth = match[3] === void 0 ? currentMonth : Number(match[3]);
      const endYear = year + (endMonth < currentMonth ? 1 : 0);
      const end = parseDate(dateKey(endYear, endMonth, Number(match[4])));
      if (!end || end.epoch - start.epoch > 366 * 864e5) continue;
      for (let cursor = start.epoch + 864e5; cursor <= end.epoch; cursor += 864e5) {
        dates.add(dateFromEpoch(cursor));
      }
      currentMonth = endMonth;
    }
  }
  return dates;
}
__name(listedJapaneseDates, "listedJapaneseDates");
function listedJapaneseDatesAround(note, date) {
  const parsed = parseDate(date);
  return /* @__PURE__ */ new Set([
    ...listedJapaneseDates(note, parsed.year),
    ...listedJapaneseDates(note, parsed.year - 1)
  ]);
}
__name(listedJapaneseDatesAround, "listedJapaneseDatesAround");
function noteDeadline(date, monthText, dayText) {
  const value = parseDate(date);
  const month = Number(monthText);
  const year = value.year + (value.month === 12 && month === 1 ? 1 : 0);
  return parseDate(dateKey(year, month, Number(dayText)));
}
__name(noteDeadline, "noteDeadline");
function operatesOnDate(note, date) {
  const compact = String(note || "").replace(/\s+/gu, "").replace(/[★☆◆◇※＊*]/gu, "");
  if (["", "\u5168\u65E5", "\u6BCE\u65E5", "\u6BCE\u65E5\u904B\u8EE2"].includes(compact)) return true;
  let match = /(\d{1,2})月(\d{1,2})日まで(運転|運休)/u.exec(compact);
  if (match) {
    const deadline = noteDeadline(date, match[1], match[2]);
    if (!deadline) return null;
    return match[3] === "\u904B\u8EE2" ? date <= deadline.iso : date > deadline.iso;
  }
  match = /(\d{1,2})月(\d{1,2})日まで(?:は)?この時刻に変更/u.exec(compact);
  if (match) {
    const deadline = noteDeadline(date, match[1], match[2]);
    return deadline ? date <= deadline.iso : null;
  }
  const listed = listedJapaneseDatesAround(compact, date);
  const parsed = parseDate(date);
  const weekday = new Date(parsed.epoch).getUTCDay();
  const publicHoliday = japanesePublicHolidays(date).has(date);
  const holiday = weekday === 0 || publicHoliday;
  const saturdayOrHoliday = weekday === 6 || holiday;
  if (compact.includes("\u571F\u66DC\u30FB\u4F11\u65E5") || compact.includes("\u571F\u4F11\u65E5")) {
    if (compact.includes("\u904B\u4F11")) return !(saturdayOrHoliday || listed.has(date));
    if (compact.includes("\u904B\u8EE2")) return saturdayOrHoliday || listed.has(date);
  } else if (compact.includes("\u4F11\u65E5")) {
    if (compact.includes("\u904B\u4F11")) return !(holiday || listed.has(date));
    if (compact.includes("\u904B\u8EE2")) return holiday || listed.has(date);
  }
  if (compact.includes("\u3053\u306E\u6642\u523B\u306B\u5909\u66F4")) return listed.has(date);
  if (compact.includes("\u904B\u4F11") && listed.size > 0) return !listed.has(date);
  if (compact.includes("\u904B\u8EE2") && listed.size > 0) return listed.has(date);
  return null;
}
__name(operatesOnDate, "operatesOnDate");
function jrIsoStops(rawStops, date) {
  if (!Array.isArray(rawStops) || rawStops.length < 2) {
    fail(502, "upstream_invalid_response", "JR timetable has no usable stops");
  }
  let currentDay = 0;
  let previousMinutes = null;
  function eventIso(value) {
    if (value === null || value === void 0) return null;
    const minutes = clockMinutes(value);
    if (minutes === null) fail(502, "upstream_invalid_response", "JR timetable time is invalid");
    if (previousMinutes !== null && minutes + 720 < previousMinutes) currentDay += 1;
    previousMinutes = minutes;
    return fullIso(addDays(date, currentDay), value, "+09:00");
  }
  __name(eventIso, "eventIso");
  return rawStops.map((stop) => ({
    name: stop.name,
    code: typeof stop.code === "string" ? stop.code : null,
    arrival: eventIso(stop.arrival),
    departure: eventIso(stop.departure)
  }));
}
__name(jrIsoStops, "jrIsoStops");
function mergeJrSegments(segments) {
  const chains = segments.map(({ raw, operational }) => ({
    raw: raw.map((stop) => ({ ...stop })),
    operational
  }));
  function join(left, right) {
    if (left.length === 0 || right.length === 0 || left.at(-1).name !== right[0].name) return null;
    const boundary = { ...left.at(-1) };
    for (const field of ["arrival", "departure"]) boundary[field] ||= right[0][field];
    return [...left.slice(0, -1), boundary, ...right.slice(1)];
  }
  __name(join, "join");
  let changed = true;
  while (changed && chains.length > 1) {
    changed = false;
    outer: for (let left = 0; left < chains.length; left += 1) {
      for (let right = 0; right < chains.length; right += 1) {
        if (left === right) continue;
        const merged = join(chains[left].raw, chains[right].raw);
        if (!merged) continue;
        const operational = chains[left].raw.length >= chains[right].raw.length ? chains[left].operational : chains[right].operational;
        chains[left] = { raw: merged, operational };
        chains.splice(right, 1);
        changed = true;
        break outer;
      }
    }
  }
  return chains.reduce((best, item) => item.raw.length > best.raw.length ? item : best);
}
__name(mergeJrSegments, "mergeJrSegments");
function eastColumnStops(rows, column, companionColumn, couplingNames) {
  const stationRows = rows.filter((row) => row.cells.length > column && row.cells.length >= 2 && ["\u7740", "\u767A"].includes(row.cells[1].text));
  let couplingBounds = null;
  if (couplingNames) {
    const matching = stationRows.map((row, index) => couplingNames.includes(row.cells[0].text) ? index : null).filter((index) => index !== null);
    if (matching.length >= 2) couplingBounds = [Math.min(...matching), Math.max(...matching)];
  }
  const raw = [];
  const positions = /* @__PURE__ */ new Map();
  stationRows.forEach((row, sequence) => {
    const station = row.cells[0].text;
    const event = row.cells[1].text;
    let value = gridTime(row.cells[column].text);
    if (value === null && companionColumn !== null && companionColumn < row.cells.length && couplingBounds && sequence >= couplingBounds[0] && sequence <= couplingBounds[1]) {
      value = gridTime(row.cells[companionColumn].text);
    }
    if (value === null) return;
    if (!positions.has(station)) {
      positions.set(station, raw.length);
      raw.push({ name: station, arrival: null, departure: null });
    }
    raw[positions.get(station)][event === "\u7740" ? "arrival" : "departure"] = value;
  });
  return raw;
}
__name(eastColumnStops, "eastColumnStops");
function parseJrEastGrid(html, code, date) {
  const rows = parseRows(html);
  const numberRow = rows.find((row) => row.classes.has("tableTr_trainNumber"));
  const nameRow = rows.find((row) => row.classes.has("tableTr_trainName"));
  const operatingRow = rows.find((row) => row.classes.has("tableTr_operatingDay"));
  const articleRow = rows.find((row) => row.classes.has("tableTr_article")) || null;
  if (!numberRow || !nameRow || !operatingRow) {
    fail(502, "upstream_invalid_response", "JR East timetable structure is invalid");
  }
  const targetColumns = nameRow.cells.map((cell, index) => cell.text === code ? index : null).filter((index) => index !== null);
  if (targetColumns.length === 0) return null;
  const candidates = [];
  let unknownNote = false;
  for (const column of targetColumns) {
    if (column >= operatingRow.cells.length) continue;
    const note = operatingRow.cells[column].text;
    const operates = operatesOnDate(note, date);
    if (operates === null) {
      unknownNote = true;
      continue;
    }
    if (!operates) continue;
    let companionColumn = null;
    let couplingNames = null;
    const article = articleRow && column < articleRow.cells.length ? articleRow.cells[column].text : "";
    const coupling = /^.*?(.+?)[－-](.+?)間?は([0-9A-Z]+).*?に併結/u.exec(
      article.replace(/^[★☆◆◇※＊*]+/u, "")
    );
    if (coupling) {
      const start = coupling[1].replace(/^[★☆◆◇※＊*]+/u, "").replace(/間$/u, "");
      const end = coupling[2].replace(/^[★☆◆◇※＊*]+/u, "").replace(/間$/u, "");
      companionColumn = numberRow.cells.findIndex((cell) => cell.text === coupling[3]);
      if (companionColumn < 0) companionColumn = null;
      couplingNames = [start, end];
    }
    const raw = eastColumnStops(rows, column, companionColumn, couplingNames);
    if (raw.length < 2) continue;
    candidates.push({
      priority: note.includes("\u5909\u66F4") || listedJapaneseDatesAround(note, date).size > 0 ? 2 : 1,
      raw,
      operational: column < numberRow.cells.length ? numberRow.cells[column].text : code
    });
  }
  if (candidates.length === 0) {
    if (unknownNote) fail(502, "coverage_unavailable", "JR operating-day note is unsupported");
    return null;
  }
  const bestPriority = Math.max(...candidates.map((item) => item.priority));
  return mergeJrSegments(candidates.filter((item) => item.priority === bestPriority));
}
__name(parseJrEastGrid, "parseJrEastGrid");
function discoverJrEastIssue(html) {
  const issues = [...html.matchAll(/\.\.\/(\d{4})\/timetable-v\/(?:001|003|004)[du][12]\.html/gu)].map((match) => match[1]);
  if (issues.length === 0) fail(502, "upstream_invalid_response", "JR East issue is unavailable");
  return issues.sort().at(-1);
}
__name(discoverJrEastIssue, "discoverJrEastIssue");
function jrEastIssueCovers(issue, date) {
  const year = 2e3 + Number(issue.slice(0, 2));
  const month = Number(issue.slice(2));
  if (!Number.isInteger(month) || month < 1 || month > 12) return false;
  const issueStart = Date.UTC(year, month - 1, 1);
  const coverageStart = issueStart - 7 * 864e5;
  const coverageEnd = Date.UTC(year, month + 2, 1);
  const query = parseDate(date).epoch;
  return query >= coverageStart && query < coverageEnd;
}
__name(jrEastIssueCovers, "jrEastIssueCovers");
async function queryJrEast(code, date, fetchImpl, budget) {
  budget.check();
  const parts = jrCodeParts(code);
  const group = [...JR_EAST_GROUPS].find(([, names]) => names.has(parts.name))?.[0];
  if (!group) fail(404, "schedule_not_found", "JR East does not cover this train");
  const issue = discoverJrEastIssue(await getText(JR_EAST_INDEX, fetchImpl, budget));
  if (!jrEastIssueCovers(issue, date)) fail(502, "coverage_unavailable", "JR East date is unavailable");
  const line = { tokaido: "001", tohoku: "003", joetsu: "004" }[group];
  const parsed = parseDate(date);
  const weekday = new Date(parsed.epoch).getUTCDay();
  const suffix = weekday === 0 || weekday === 6 || japanesePublicHolidays(date).has(date) ? "2" : "1";
  for (const direction of ["d", "u"]) {
    budget.check();
    const url = `https://timetables.jreast.co.jp/${issue}/timetable-v/${line}${direction}${suffix}.html`;
    const result = parseJrEastGrid(await getText(url, fetchImpl, budget), code, date);
    if (result) return outputSchedule("jr", jrIsoStops(result.raw, date));
  }
  fail(404, "schedule_not_found", "No JR East Shinkansen schedule found");
}
__name(queryJrEast, "queryJrEast");
function parseJrHokkaidoGrid(html, code, date) {
  const compact = date.replaceAll("-", "");
  if (!new RegExp(`value=["']${compact}["']`, "u").test(html)) {
    fail(502, "coverage_unavailable", "JR Hokkaido date is unavailable");
  }
  const rows = parseRows(html);
  const numberIndex = rows.findIndex((row) => row.classes.has("B01") && row.cells.length > 10);
  if (numberIndex < 0 || numberIndex + 2 >= rows.length) {
    fail(502, "upstream_invalid_response", "JR Hokkaido timetable is invalid");
  }
  const numberRow = rows[numberIndex];
  const nameRow = rows[numberIndex + 1];
  const serviceRow = rows[numberIndex + 2];
  if (numberRow.cells.length === 0 || numberRow.cells.length !== nameRow.cells.length || numberRow.cells.length !== serviceRow.cells.length) {
    fail(502, "upstream_invalid_response", "JR Hokkaido header columns are invalid");
  }
  const targetColumns = nameRow.cells.map((cell, index) => `${cell.text}${serviceRow.cells[index].text}` === code ? index : null).filter((index) => index !== null);
  if (targetColumns.length === 0) return null;
  const labelStart = rows.findIndex((row) => row.cells.length === 2 && row.cells[0].text === "\u524D\u306E\u533A\u9593");
  const dataStart = rows.findIndex((row, index) => labelStart >= 0 && index > labelStart && row.cells.length > 10 && row.classes.has("B11"));
  if (labelStart < 0 || dataStart < 0) fail(502, "upstream_invalid_response", "JR Hokkaido rows are invalid");
  const candidates = [];
  for (const column of targetColumns) {
    const raw = [];
    const positions = /* @__PURE__ */ new Map();
    for (let labelIndex = labelStart; labelIndex < dataStart; labelIndex += 1) {
      const label = rows[labelIndex].cells;
      if (label.length < 2 || !["\u7740", "\u767A"].includes(label[1].text)) continue;
      const dataIndex = dataStart + (labelIndex - labelStart);
      if (dataIndex >= rows.length || column >= rows[dataIndex].cells.length) continue;
      const value = gridTime(rows[dataIndex].cells[column].text);
      if (value === null) continue;
      const station = label[0].text;
      if (!positions.has(station)) {
        positions.set(station, raw.length);
        raw.push({ name: station, arrival: null, departure: null });
      }
      raw[positions.get(station)][label[1].text === "\u7740" ? "arrival" : "departure"] = value;
    }
    if (raw.length >= 2) candidates.push(raw);
  }
  if (candidates.length === 0) return null;
  return candidates.reduce((best, item) => item.length > best.length ? item : best);
}
__name(parseJrHokkaidoGrid, "parseJrHokkaidoGrid");
async function queryJrHokkaido(code, date, fetchImpl, budget) {
  budget.check();
  let coverageError = null;
  for (const base of JR_HOKKAIDO_GRIDS) {
    budget.check();
    try {
      const raw = parseJrHokkaidoGrid(
        await getText(`${base}&d=${date.replaceAll("-", "")}`, fetchImpl, budget),
        code,
        date
      );
      if (raw) return outputSchedule("jr", jrIsoStops(raw, date));
    } catch (error) {
      if (error instanceof TravelScheduleError && error.code === "coverage_unavailable") {
        coverageError = error;
        continue;
      }
      throw error;
    }
  }
  if (coverageError) throw coverageError;
  fail(404, "schedule_not_found", "No JR Hokkaido Shinkansen schedule found");
}
__name(queryJrHokkaido, "queryJrHokkaido");
function parseJrKyushuDetail(html, code, date) {
  const rows = parseRows(html);
  const nameRow = rows.find((row) => row.cells[0]?.text === "\u5217\u8ECA\u540D");
  const numberRow = rows.find((row) => row.cells[0]?.text === "\u5217\u8ECA\u756A\u53F7");
  const headerIndex = rows.findIndex((row) => row.cells[0]?.text === "\u99C5\u540D");
  if (!nameRow || !numberRow || headerIndex < 0) fail(502, "upstream_invalid_response", "JR Kyushu detail is invalid");
  const target = `${code}\u53F7`;
  const serviceIndex = nameRow.cells.slice(1).findIndex((cell) => cell.text === target);
  if (serviceIndex < 0) fail(502, "upstream_invalid_response", "JR Kyushu detail did not match train");
  const timeColumn = 1 + serviceIndex * 2;
  const raw = [];
  for (const row of rows.slice(headerIndex + 1)) {
    if (row.cells.length <= timeColumn || !row.cells[0].text) continue;
    const text = row.cells[timeColumn].text;
    const arrival = /(\d{1,2}:\d{2})着/u.exec(text)?.[1] || null;
    const departure = /(\d{1,2}:\d{2})発/u.exec(text)?.[1] || null;
    if (!arrival && !departure) {
      if (row.cells[0].text === "\u65E5") break;
      continue;
    }
    raw.push({
      name: row.cells[0].text,
      arrival: arrival ? arrival.padStart(5, "0") : null,
      departure: departure ? departure.padStart(5, "0") : null
    });
  }
  return outputSchedule("jr", jrIsoStops(raw, date));
}
__name(parseJrKyushuDetail, "parseJrKyushuDetail");
async function queryJrKyushu(code, date, fetchImpl, budget) {
  budget.check();
  const parts = jrCodeParts(code);
  const group = parts.name === "\u304B\u3082\u3081" ? "nishikyushu" : "kyushu";
  const compact = date.replaceAll("-", "");
  const target = `${code}\u53F7`;
  let validPages = 0;
  for (const path of JR_KYUSHU_SEEDS[group]) {
    budget.check();
    const stationUrl = new URL(path, JR_KYUSHU_BASE);
    stationUrl.searchParams.set("d", compact);
    const stationHtml = await getText(stationUrl.toString(), fetchImpl, budget);
    const links = parseAnchors(stationHtml).filter((anchor) => anchor.href.includes(`d=${compact}`));
    if (links.length > 0 || stationHtml.includes("\u6307\u5B9A\u3055\u308C\u305F\u65E5\u4ED8\u306B\u904B\u884C\u306F\u3042\u308A\u307E\u305B\u3093")) validPages += 1;
    const match = links.find((anchor) => anchor.text.includes(target));
    if (match) {
      const detailUrl = new URL(match.href, JR_KYUSHU_BASE).toString();
      return parseJrKyushuDetail(await getText(detailUrl, fetchImpl, budget), code, date);
    }
  }
  if (validPages === 0) fail(502, "coverage_unavailable", "JR Kyushu date is unavailable");
  fail(404, "schedule_not_found", "No JR Kyushu Shinkansen schedule found");
}
__name(queryJrKyushu, "queryJrKyushu");
function parseJrOdekakeDetail(html, code, date) {
  const rows = parseRows(html);
  const target = `${code}\u53F7`;
  let serviceNames = [];
  let trainNumbers = [];
  let couplingNotes = [];
  for (const row of rows) {
    if (!row.tbodyClasses.has("train-details") || row.cells.length < 2) continue;
    const values = row.cells.slice(1).map((cell) => cell.text || "");
    if (row.cells[0].text === "\u5217\u8ECA\u540D") serviceNames = values;
    else if (row.cells[0].text === "\u5217\u8ECA\u756A\u53F7") trainNumbers = values;
    else if (row.cells[0].text === "\u4F75\u7D50\u904B\u8EE2") couplingNotes = values;
  }
  if (serviceNames.length === 0) fail(502, "upstream_invalid_response", "JR detail omitted train name");
  const serviceIndex = serviceNames.indexOf(target);
  if (serviceIndex < 0) fail(502, "upstream_invalid_response", "JR detail did not match train");
  const timeRows = rows.filter((row) => row.tbodyClasses.has("time-details") && !row.tbodyClasses.has("time-details-ttl") && row.cells.length > 0 && !row.cells[0].classes.has("remarks"));
  let companionIndex = null;
  let couplingRange = null;
  if (serviceIndex < couplingNotes.length) {
    const coupling = /(.+?)[－-](.+?)は([0-9A-Z]+)(?:を併結|に併結)/u.exec(couplingNotes[serviceIndex]);
    if (coupling) {
      companionIndex = trainNumbers.indexOf(coupling[3]);
      if (companionIndex < 0) companionIndex = null;
      const first = timeRows.findIndex((row) => row.cells[0].text === coupling[1]);
      const last = timeRows.findIndex((row) => row.cells[0].text === coupling[2]);
      if (first >= 0 && last >= 0) couplingRange = [Math.min(first, last), Math.max(first, last)];
    }
  }
  const raw = [];
  timeRows.forEach((row, rowIndex) => {
    const station = row.cells[0].text;
    const timeIndex = 1 + serviceIndex * 2;
    if (!station || timeIndex >= row.cells.length) return;
    let ownText = row.cells[timeIndex].text;
    let companionText = "";
    if (companionIndex !== null && couplingRange && rowIndex >= couplingRange[0] && rowIndex <= couplingRange[1]) {
      const companionTime = 1 + companionIndex * 2;
      if (companionTime < row.cells.length) companionText = row.cells[companionTime].text;
    }
    if (!/\d{1,2}:\d{2}/u.test(ownText + companionText)) return;
    const arrival = /(\d{1,2}:\d{2})着/u.exec(ownText)?.[1] || /(\d{1,2}:\d{2})着/u.exec(companionText)?.[1] || null;
    const departure = /(\d{1,2}:\d{2})発/u.exec(ownText)?.[1] || /(\d{1,2}:\d{2})発/u.exec(companionText)?.[1] || null;
    raw.push({
      name: station,
      arrival: arrival ? arrival.padStart(5, "0") : null,
      departure: departure ? departure.padStart(5, "0") : null
    });
  });
  return outputSchedule("jr", jrIsoStops(raw, date));
}
__name(parseJrOdekakeDetail, "parseJrOdekakeDetail");
async function queryJrOdekake(code, date, fetchImpl, budget) {
  budget.check();
  const parts = jrCodeParts(code);
  const seeds = ["\u304B\u304C\u3084\u304D", "\u306F\u304F\u305F\u304B", "\u3064\u308B\u304E", "\u3042\u3055\u307E"].includes(parts.name) ? JR_ODEKAKE_SEEDS.hokuriku : JR_ODEKAKE_SEEDS.west;
  const compact = date.replaceAll("-", "");
  const target = `${code}\u53F7`;
  let validPages = 0;
  let structuredPages = 0;
  for (const seed of seeds) {
    budget.check();
    const stationUrl = `${JR_ODEKAKE_BASE}/station-timetable/${seed}?date=${compact}`;
    const stationHtml = await getText(stationUrl, fetchImpl, budget);
    const links = parseAnchors(stationHtml).filter((anchor) => anchor.href.includes("/train-timetable/") && anchor.href.includes(`date=${compact}`));
    const selected = new RegExp(`<option(?=[^>]*value=["']${compact}["'])(?=[^>]*selected)[^>]*>`, "u").test(stationHtml);
    const structured = /id=["']date["']/u.test(stationHtml) && stationHtml.includes("pc-time-tbl-wrap");
    if (structured) structuredPages += 1;
    if (links.length > 0 || selected && structured) validPages += 1;
    const match = links.find((anchor) => anchor.text.includes(target));
    if (match) {
      return parseJrOdekakeDetail(
        await getText(new URL(match.href, JR_ODEKAKE_BASE).toString(), fetchImpl, budget),
        code,
        date
      );
    }
  }
  if (validPages > 0) fail(404, "schedule_not_found", "No JR Shinkansen schedule found");
  if (structuredPages > 0) fail(502, "coverage_unavailable", "JR timetable date is unavailable");
  fail(502, "upstream_invalid_response", "JR station timetable structure is invalid");
}
__name(queryJrOdekake, "queryJrOdekake");
async function withOdekakeFallback(primary, code, date, fetchImpl, budget) {
  budget.check();
  let firstError;
  try {
    return await primary();
  } catch (error) {
    if (!(error instanceof TravelScheduleError) || error.status !== 404 && error.code !== "coverage_unavailable") throw error;
    firstError = error;
  }
  budget.check();
  try {
    return await queryJrOdekake(code, date, fetchImpl, budget);
  } catch (error) {
    if (error instanceof TravelScheduleError && error.status === 404 && firstError.code === "coverage_unavailable") throw firstError;
    throw error;
  }
}
__name(withOdekakeFallback, "withOdekakeFallback");
async function queryJr(code, date, fetchImpl, budget) {
  budget.check();
  const { name } = jrCodeParts(code);
  if (["\u306F\u3084\u3076\u3055", "\u306F\u3084\u3066"].includes(name)) {
    let firstError;
    try {
      return await queryJrHokkaido(code, date, fetchImpl, budget);
    } catch (error) {
      if (!(error instanceof TravelScheduleError) || error.status !== 404 && error.code !== "coverage_unavailable") throw error;
      firstError = error;
    }
    budget.check();
    try {
      return await queryJrEast(code, date, fetchImpl, budget);
    } catch (error) {
      if (error instanceof TravelScheduleError && error.status === 404 && firstError.code === "coverage_unavailable") throw firstError;
      throw error;
    }
  }
  if (["\u3084\u307E\u3073\u3053", "\u306A\u3059\u306E", "\u3053\u307E\u3061", "\u3064\u3070\u3055", "\u3068\u304D", "\u305F\u306B\u304C\u308F"].includes(name)) {
    return queryJrEast(code, date, fetchImpl, budget);
  }
  if (["\u3042\u3055\u307E", "\u306F\u304F\u305F\u304B", "\u304B\u304C\u3084\u304D", "\u3064\u308B\u304E"].includes(name)) {
    return withOdekakeFallback(() => queryJrEast(code, date, fetchImpl, budget), code, date, fetchImpl, budget);
  }
  if (["\u307F\u305A\u307B", "\u3055\u304F\u3089", "\u3064\u3070\u3081"].includes(name)) {
    return withOdekakeFallback(() => queryJrKyushu(code, date, fetchImpl, budget), code, date, fetchImpl, budget);
  }
  if (name === "\u304B\u3082\u3081") return queryJrKyushu(code, date, fetchImpl, budget);
  if (["\u3072\u304B\u308A", "\u3053\u3060\u307E"].includes(name)) {
    return withOdekakeFallback(() => queryJrEast(code, date, fetchImpl, budget), code, date, fetchImpl, budget);
  }
  return queryJrOdekake(code, date, fetchImpl, budget);
}
__name(queryJr, "queryJr");
function validateQuery(url) {
  const allowed = /* @__PURE__ */ new Set(["type", "code", "date"]);
  if ([...url.searchParams.keys()].some((key) => !allowed.has(key))) {
    fail(400, "invalid_request", "Only type, code, and date are allowed");
  }
  for (const key of allowed) {
    if (url.searchParams.getAll(key).length !== 1) {
      fail(400, `invalid_${key}`, `${key} is required exactly once`);
    }
  }
  const type = url.searchParams.get("type");
  if (!(/* @__PURE__ */ new Set(["flight", "train"])).has(type)) {
    fail(400, "invalid_type", "type must be flight or train");
  }
  const date = url.searchParams.get("date");
  if (!parseDate(date)) fail(400, "invalid_date", "date must use YYYY-MM-DD");
  return { type, code: normalizeCode(url.searchParams.get("code")), date };
}
__name(validateQuery, "validateQuery");
async function handleTravelScheduleRequest(request, env = {}, options = {}) {
  const budget = new TravelRequestBudget(options.totalTimeoutMs);
  try {
    if (request.method !== "GET") fail(405, "method_not_allowed", "Only GET is supported");
    const url = new URL(request.url);
    const { type, code, date } = validateQuery(url);
    const fetchImpl = options.fetchImpl || fetch;
    const waitImpl = options.waitImpl || defaultWait;
    let body;
    if (type === "flight") {
      if (!/^[A-Z0-9]{2}\d{1,4}[A-Z]?$/u.test(code)) {
        fail(400, "invalid_code", "code is not a valid flight number");
      }
      body = await queryFlight(code, date, env.RAPIDAPI_KEY, fetchImpl, waitImpl, budget);
    } else {
      const jr = jrCodeParts(code);
      if (jr) body = await queryJr(code, date, fetchImpl, budget);
      else if (/^(?:[ACDGZTKSYL]\d{1,5}|\d{1,5})$/u.test(code)) {
        body = await queryChinaRail(code, date, fetchImpl, budget);
      } else {
        fail(400, "invalid_code", "code is not a supported train number");
      }
    }
    budget.check();
    return { status: 200, body };
  } catch (error) {
    if (error instanceof TravelScheduleError) {
      return {
        status: error.status,
        body: { error: { code: error.code, message: error.message } }
      };
    }
    console.error(JSON.stringify({ event: "travel_schedule_error", error: "internal_error" }));
    return {
      status: 500,
      body: { error: { code: "internal_error", message: "Internal schedule error" } }
    };
  } finally {
    budget.dispose();
  }
}
__name(handleTravelScheduleRequest, "handleTravelScheduleRequest");

export {
  TRAVEL_AIRPORT_NAME_ENTRIES,
  TRAVEL_AIRPORT_NAMES_BY_IATA,
  TRAVEL_SCHEDULE_ENDPOINT,
  handleTravelScheduleRequest,
  normalizeCode,
  parseDate,
  parseFlightPayloads,
  parseChinaRailInfo,
  validateQuery,
};
