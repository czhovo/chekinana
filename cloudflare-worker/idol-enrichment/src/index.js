import {
  CURRENT_CATALOGUE_JSON,
  CURRENT_IDOL_PATTERN_MAP_JSON,
  CURRENT_MANIFEST_JSON,
  LEGACY_IDOL_PATTERN_MAP_JSON,
  LEGACY_MANIFEST_JSON,
  PROTOTYPES_JSON,
} from "./generated-pattern-assets.js";

const idols = JSON.parse(CURRENT_CATALOGUE_JSON);
const idolPatternMap = JSON.parse(CURRENT_IDOL_PATTERN_MAP_JSON);

const JSON_HEADERS = {
  "content-type": "application/json; charset=utf-8",
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET, OPTIONS",
  "access-control-allow-headers": "content-type",
};
const MAX_LIMIT = 200;
const STATIC_JSON_BY_PATH = new Map([
  ["/assets/pattern-recognition/v1/manifest.json", LEGACY_MANIFEST_JSON],
  ["/assets/pattern-recognition/v1/prototypes.json", PROTOTYPES_JSON],
  ["/assets/pattern-recognition/v1/idol-pattern-map.json", LEGACY_IDOL_PATTERN_MAP_JSON],
  [
    "/assets/pattern-recognition/v1/catalogue-b462a208c0d75264/manifest.json",
    CURRENT_MANIFEST_JSON,
  ],
  [
    "/assets/pattern-recognition/v1/catalogue-b462a208c0d75264/idol-pattern-map.json",
    CURRENT_IDOL_PATTERN_MAP_JSON,
  ],
]);

function json(data, init = {}) {
  return new Response(JSON.stringify(data), {
    ...init,
    headers: {
      ...JSON_HEADERS,
      ...(init.headers || {}),
    },
  });
}

function rawJson(body, init = {}) {
  return new Response(body, {
    ...init,
    headers: {
      ...JSON_HEADERS,
      "cache-control": "public, max-age=31536000, immutable",
      ...(init.headers || {}),
    },
  });
}

function normalizeText(value) {
  return String(value || "")
    .toLocaleLowerCase("zh-CN")
    .normalize("NFKC")
    .replace(/[\s_\-·・.。/／|｜]+/g, "")
    .trim();
}

function parseLimit(value, fallback = 50) {
  const parsed = Number.parseInt(value || "", 10);
  if (!Number.isFinite(parsed) || parsed <= 0) return fallback;
  return Math.min(parsed, MAX_LIMIT);
}

function withAvatarUrl(record, origin) {
  const avatarPath = record.avatarPath || "";
  return {
    ...record,
    avatarUrl: avatarPath ? new URL(avatarPath, origin).toString() : "",
  };
}

function withSearchPatternIds(record, origin) {
  return {
    ...withAvatarUrl(record, origin),
    patternIds: idolPatternMap.idolPatternIDs[record.id] ?? [],
  };
}

function scoreByField(record, field, normalizedQuery) {
  const value = normalizeText(record[field]);
  if (!normalizedQuery || !value) return 0;
  if (value === normalizedQuery) return 100;
  if (value.startsWith(normalizedQuery)) return 80;
  if (value.includes(normalizedQuery)) return 60;
  if (normalizedQuery.includes(value)) return 40;
  return 0;
}

function searchByField(field, query, limit) {
  const normalizedQuery = normalizeText(query);
  if (!normalizedQuery) return [];
  const matches = idols
    .map((record) => ({ record, score: scoreByField(record, field, normalizedQuery) }))
    .filter((item) => item.score > 0);
  const exactMatches = matches.filter((item) => item.score === 100);
  return (exactMatches.length > 0 ? exactMatches : matches)
    .sort((a, b) => {
      if (b.score !== a.score) return b.score - a.score;
      return Number(a.record._sourceIndex || 0) - Number(b.record._sourceIndex || 0);
    })
    .slice(0, limit)
    .map((item) => item.record);
}

function searchGroups(query, limit) {
  const normalizedQuery = normalizeText(query);
  if (!normalizedQuery) return [];
  const groups = new Map();
  for (const record of idols) {
    const score = scoreByField(record, "groupName", normalizedQuery);
    if (score <= 0) continue;
    const groupName = record.groupName || "";
    if (!groups.has(groupName)) groups.set(groupName, { groupName, score, idols: [] });
    const group = groups.get(groupName);
    group.score = Math.max(group.score, score);
    group.idols.push(record);
  }
  const matches = [...groups.values()];
  const exactMatches = matches.filter((group) => group.score === 100);
  return (exactMatches.length > 0 ? exactMatches : matches)
    .sort((a, b) => {
      if (b.score !== a.score) return b.score - a.score;
      return a.groupName.localeCompare(b.groupName, "zh-CN");
    })
    .slice(0, limit);
}

function help(origin) {
  return {
    service: "idol-enrichment-api",
    records: idols.length,
    endpoints: {
      health: `${origin}/api/health`,
      allIdols: `${origin}/api/idols?limit=50`,
      idolSearch: `${origin}/api/search/idol?q=四季`,
      groupSearch: `${origin}/api/search/group?q=2592`,
      idolById: `${origin}/api/idols/idol_000001`,
      rawJson: `${origin}/idols.json`,
      avatar: `${origin}/avatars/idol_000001.jpg`,
    },
  };
}

export default {
  async fetch(request, env = {}) {
    if (request.method === "OPTIONS") {
      return new Response(null, { headers: JSON_HEADERS });
    }

    const url = new URL(request.url);
    const pathname = url.pathname.replace(/\/+$/, "") || "/";
    const origin = url.origin;

    if (STATIC_JSON_BY_PATH.has(pathname)) {
      return rawJson(STATIC_JSON_BY_PATH.get(pathname));
    }
    if (pathname === "/" || pathname === "/api") {
      return json(help(origin));
    }
    if (pathname === "/api/health") {
      return json({ ok: true, records: idols.length });
    }
    if (pathname === "/api/idols") {
      const limit = parseLimit(url.searchParams.get("limit"), 50);
      const offset = Math.max(Number.parseInt(url.searchParams.get("offset") || "0", 10) || 0, 0);
      const items = idols.slice(offset, offset + limit).map((record) => withAvatarUrl(record, origin));
      return json({ query: { offset, limit }, total: idols.length, count: items.length, items });
    }
    if (pathname.startsWith("/api/idols/")) {
      const id = decodeURIComponent(pathname.slice("/api/idols/".length));
      const record = idols.find((item) => item.id === id);
      if (!record) return json({ error: "not_found", id }, { status: 404 });
      return json({ item: withAvatarUrl(record, origin) });
    }
    if (pathname === "/api/search/idol") {
      const q = url.searchParams.get("q") || url.searchParams.get("idolName") || "";
      const limit = parseLimit(url.searchParams.get("limit"), 50);
      const items = searchByField("idolName", q, limit)
        .map((record) => withSearchPatternIds(record, origin));
      return json({ query: { q, limit }, count: items.length, items });
    }
    if (pathname === "/api/search/group") {
      const q = url.searchParams.get("q") || url.searchParams.get("groupName") || "";
      const limit = parseLimit(url.searchParams.get("limit"), 20);
      const groups = searchGroups(q, limit).map((group) => ({
        groupName: group.groupName,
        count: group.idols.length,
        idols: group.idols.map((record) => withAvatarUrl(record, origin)),
      }));
      return json({ query: { q, limit }, count: groups.length, groups });
    }
    if (env.ASSETS) {
      return env.ASSETS.fetch(request);
    }
    return json({ error: "not_found" }, { status: 404 });
  },
};
