import he from "he";

const EVENT_ENDPOINT = "/api/event/weibo-candidate";
const DEFAULT_DEADLINE_MS = 15_000;
const MAX_REQUEST_CHARS = 4_096;
const MAX_UPSTREAM_BYTES = 1_048_576;
const MAX_CANDIDATE_RESPONSE_BYTES = 16_384;
const MAX_STATUS_TEXT_CHARS = 262_144;
const MAX_STRUCTURED_URLS = 20;

const USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36";
const WEIBO_HOSTS = new Set(["weibo.com", "www.weibo.com", "passport.weibo.com"]);
const TICKET_PROVIDER_DOMAINS = new Set([
  "showstart.com",
  "damai.cn",
  "piaoxingqiu.com",
  "maoyan.com",
  "247tickets.com",
  "gewara.com",
  "motntickets.com",
  "cityline.com",
  "hkticketing.com",
]);
const TRUSTED_SHORTENER_DOMAINS = new Set(["t.cn", "sinaurl.cn"]);

const GENERIC_NAME_TERMS = [
  "演出信息", "公演信息", "活动信息", "演出情报", "公演情报", "活动情报",
  "情报解禁", "主催情报解禁", "主催情报", "timing公布", "timetable公布",
  "timetable", "时间表公布", "阵容公布", "参演阵容", "演出公告", "公演公告",
  "活动公告", "通知", "票务信息", "开售公告",
];
const DATE_REJECT_TERMS = ["开售", "发售", "售票", "票价", "购票", "抢票", "售罄", "抽奖", "开奖", "转发", "截止"];
const NAME_REJECT_TERMS = ["转抽", "转发抽", "抽奖", "开奖", "中奖", "奖品", "参与方式", "礼包", "大合影", "免费入场", "免票", "票价", "售票", "开售"];
const NON_VENUE_NAMES = new Set(["餐厅", "客厅", "大厅", "展厅", "食堂", "饭店", "酒店"]);

const EVENT_PREFIX_RE = /(?:生诞祭|生日祭|定期公演|周年公演|主催(?:公演)?|专场|演唱会|巡演|公演|(?:FES|LIVE|PARTY))\s*[!！~～:：·・\-—]*$/iu;
const EVENT_NAME_SIGNAL_RE = /(?:生诞祭|生日祭|定期公演|周年|ONE\s*MAN|FES\b|LIVE\b|VOL\.?\s*\d+)/iu;
const THEME_RE = /^[『「《](.+)[』」》]$/u;
const EXPLICIT_NAME_RE = /^(?:活动名称|演出名称|公演名称|活动名|演出名|公演名|标题|主题|event)\s*[:：]\s*(.+)$/iu;
const BRACKET_TITLE_RE = /^【(.+)】$/u;

const VENUE_SUFFIX_PATTERN = String.raw`(?:Live\s*house|CLUB|SPACE|空间|音乐厅|剧场|艺术中心|文化中心|展演中心|演艺中心|体育馆|体育场|会展中心|舞台|小镇C厅|小镇[A-Za-z0-9一二三四五六七八九十]+厅|厅|馆|店)`;
const VENUE_SUFFIX_RE = new RegExp(`${VENUE_SUFFIX_PATTERN}$`, "iu");
const VENUE_ANY_RE = new RegExp(
  `([A-Za-z0-9\\u4e00-\\u9fff][A-Za-z0-9\\u4e00-\\u9fff·&.+!'’‘\\- ]{0,38}${VENUE_SUFFIX_PATTERN}(?:[（(][^）)]{1,24}[）)])?)`,
  "iu",
);
const VENUE_LABEL_RE = /^(?:演出场地|活动场地|公演场地|演出地址|活动地址|公演地址|场地|地点|会场|venue|add|address)\s*[:：]\s*(.+)$/iu;
const ADDRESS_MARKER_RE = /(?:省|市|区|县|自治州|路|街|道|号|楼|层|商场|MALL)/iu;

const CITY_NAMES = [
  "北京", "上海", "天津", "重庆", "广州", "深圳", "成都", "杭州", "南京", "武汉", "长沙",
  "苏州", "西安", "郑州", "济南", "青岛", "合肥", "南昌", "福州", "厦门", "昆明", "贵阳",
  "南宁", "沈阳", "大连", "长春", "哈尔滨", "石家庄", "太原", "兰州", "乌鲁木齐", "海口",
  "宁波", "无锡", "常州", "佛山", "东莞", "珠海", "温州", "嘉兴", "绍兴", "金华", "徐州",
  "南通", "扬州", "镇江", "泰州", "盐城", "淄博", "烟台", "潍坊", "临沂", "泉州", "中山",
  "惠州", "呼和浩特", "银川", "西宁", "拉萨", "洛阳", "桂林", "台北", "香港", "澳门",
];
const CITY_PATTERN = [...new Set(CITY_NAMES)].sort((left, right) => right.length - left.length).join("|");
const CITY_RE = new RegExp(`(${CITY_PATTERN})(?:市)?`, "u");
const CITY_LABEL_RE = /^(?:城市|演出城市|活动城市|公演城市)\s*[:：]\s*(.+)$/u;
const LOCATION_CONTEXT_RE = /(?:地址|场地|地点|会场|venue|\baddress\b)/iu;
const LOCATION_LINE_SYMBOLS = ["📍", "📌", "🚩"];
const VENUE_SENTENCE_RE = /(?:演出后|结束后|散场后|一起|前往|去吃|去逛|聚餐|大家)/u;

const FULL_DATE_PATTERNS = [
  String.raw`(?<!\d)(20\d{2})\s*[-/.]\s*(\d{1,2})\s*[-/.]\s*(\d{1,2})(?!\d)`,
  String.raw`(?<!\d)(20\d{2})\s*年\s*(\d{1,2})\s*月\s*(\d{1,2})\s*日?`,
];
const MONTH_DAY_PATTERNS = [
  String.raw`(?<![\d.])(\d{1,2})\s*[-/.]\s*(\d{1,2})(?![\d.])`,
  String.raw`(?<!\d)(\d{1,2})\s*月\s*(\d{1,2})\s*日`,
];

class EventWeiboError extends Error {
  constructor(code, status) {
    super(code);
    this.code = code;
    this.status = status;
  }
}

function isPlainObject(value) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function hasOnlyKeys(value, allowed) {
  return Object.keys(value).every((key) => allowed.has(key));
}

function reject(code, status) {
  return { status, body: { version: 1, kind: "reject", code } };
}

function decodeHTMLEntities(value) {
  // Python's HTMLParser(convert_charrefs=True) decodes once and html.unescape
  // decodes the resulting text a second time. `he` bundles the complete HTML5
  // named-entity table, including legacy semicolon-less boundary behavior.
  return he.decode(he.decode(value));
}

function htmlToText(value) {
  return decodeHTMLEntities(
    value
      .replace(/<(?:br|p|div|li|tr|h[1-4])\b[^>]*>/giu, "\n")
      .replace(/<\/(?:p|div|li|tr|h[1-4])\s*>/giu, "\n")
      .replace(/<[^>]*>/gu, ""),
  );
}

function stripLine(value) {
  return value
    .normalize("NFC")
    .replace(/[\u200b\ufeff]/gu, "")
    .replace(/\u00a0/gu, " ")
    .replace(/[ \t]+/gu, " ")
    .trim()
    .replace(/^\\+|\\+$/gu, "")
    .trim();
}

function contentLines(text) {
  return htmlToText(text).split(/[\r\n]+/u).map(stripLine).filter(Boolean).map((raw) => ({
    raw,
    normalized: raw.normalize("NFKC"),
  }));
}

function stripLeadingSymbols(value) {
  let result = value.replace(/^[\s\ufe0f#*•·▶►◆◇■□●○★☆⚓⛓🎫🎟📍📅🗓🕐🕒⏰✨🔥🎉💫🚩]+/u, "");
  while (result) {
    const first = [...result][0];
    if (!/[\p{So}\p{Sk}\p{Mn}]/u.test(first)) break;
    result = result.slice(first.length).trimStart();
  }
  while (result) {
    const characters = [...result];
    const last = characters.at(-1);
    if (!/[\p{So}\p{Sk}\p{Mn}]/u.test(last)) break;
    result = result.slice(0, -last.length).trimEnd();
  }
  return result.replace(/^[-—:：|｜]+/u, "").trim();
}

function isGenericName(value) {
  const normalized = stripLeadingSymbols(value).normalize("NFKC").toLocaleLowerCase()
    .replace(/[\s:：!！~～·・\-—_]+/gu, "");
  if (!normalized) return true;
  return [...GENERIC_NAME_TERMS, ...NAME_REJECT_TERMS].some((term) => normalized.includes(term.toLocaleLowerCase().replaceAll(" ", "")));
}

function regexMatches(pattern, value) {
  return new RegExp(pattern, "giu").test(value);
}

function lineHasDate(value) {
  const normalized = value.normalize("NFKC");
  return [...FULL_DATE_PATTERNS, ...MONTH_DAY_PATTERNS].some((pattern) => regexMatches(pattern, normalized));
}

function lineHasEligibleDate(value) {
  const normalized = value.normalize("NFKC");
  return lineHasDate(normalized) && !DATE_REJECT_TERMS.some((term) => normalized.includes(term));
}

function looksLikeMetadata(value) {
  const normalized = value.normalize("NFKC").trim();
  if (!normalized) return true;
  if (/^(?:https?:\/\/|@|#)/iu.test(normalized)) return true;
  if (/^(?:日期|时间|地点|场地|地址|票价|票务|阵容|出演|嘉宾|开场|入场|event|date|venue)\s*[:：]/iu.test(normalized)) return true;
  if (lineHasDate(normalized)) return true;
  if (NAME_REJECT_TERMS.some((term) => normalized.includes(term))) return true;
  return isGenericName(normalized);
}

function stripGenericHeaderPrefix(value) {
  let result = value;
  const bracket = /^【([^】]+)】\s*(.+)$/u.exec(result);
  if (bracket && isGenericName(bracket[1])) result = stripLeadingSymbols(bracket[2]);
  return result.replace(/^\s*\d{1,2}\s*月\s*\d{1,2}\s*日\s*(?:[（(][^）)]*[）)])?\s*/u, "").trim();
}

function extractName(lines) {
  for (const line of lines) {
    const match = EXPLICIT_NAME_RE.exec(line.raw);
    if (match) {
      const value = stripLeadingSymbols(match[1]);
      if (value && !isGenericName(value)) return value;
    }
  }

  for (let index = 0; index < lines.length; index += 1) {
    const match = BRACKET_TITLE_RE.exec(stripLeadingSymbols(lines[index].raw));
    if (!match) continue;
    const value = stripLeadingSymbols(match[1]);
    if (!value || isGenericName(value) || lineHasDate(value)) continue;
    if (index + 1 < lines.length) {
      const continuation = stripLeadingSymbols(lines[index + 1].raw);
      if (EVENT_PREFIX_RE.test(continuation.normalize("NFKC")) && !looksLikeMetadata(continuation)) {
        return `${value} ${continuation}`;
      }
    }
    return value;
  }

  for (let index = 0; index < lines.length; index += 1) {
    const current = stripLeadingSymbols(lines[index].raw);
    const inlineTheme = /^(.+?)([『「《].+[』」》])$/u.exec(current);
    if (inlineTheme && EVENT_PREFIX_RE.test(inlineTheme[1].normalize("NFKC"))) {
      if (index + 1 < lines.length) {
        const continuation = stripLeadingSymbols(lines[index + 1].raw);
        if (EVENT_PREFIX_RE.test(continuation.normalize("NFKC")) && !looksLikeMetadata(continuation)) {
          return `${current} ${continuation}`;
        }
      }
      return current;
    }
    if (EVENT_PREFIX_RE.test(current.normalize("NFKC")) && index + 1 < lines.length) {
      const theme = stripLeadingSymbols(lines[index + 1].raw);
      if (THEME_RE.test(theme)) return current + theme;
    }
  }

  for (let index = 0; index + 1 < lines.length; index += 1) {
    const first = stripGenericHeaderPrefix(stripLeadingSymbols(lines[index].raw));
    const second = stripLeadingSymbols(lines[index + 1].raw);
    if (first && !looksLikeMetadata(first) && EVENT_NAME_SIGNAL_RE.test(second.normalize("NFKC"))
      && !looksLikeMetadata(second) && first.length + second.length >= 3 && first.length + second.length <= 160) {
      return `${first} ${second}`;
    }
  }

  for (const line of lines) {
    const value = stripLeadingSymbols(line.raw);
    if (EVENT_NAME_SIGNAL_RE.test(value.normalize("NFKC")) && !looksLikeMetadata(value)
      && value.length >= 3 && value.length <= 160) return value;
  }

  for (let headerIndex = 0; headerIndex < lines.length; headerIndex += 1) {
    if (!isGenericName(lines[headerIndex].raw)) continue;
    const dateIndex = lines.findIndex((line, index) => index > headerIndex && lineHasEligibleDate(line.normalized));
    if (dateIndex < 0) continue;
    for (const candidate of lines.slice(headerIndex + 1, dateIndex)) {
      const value = stripLeadingSymbols(candidate.raw);
      if (!looksLikeMetadata(value) && value.length >= 3 && value.length <= 160) return value;
    }
  }
  return "";
}

function validDate(year, month, day) {
  const parsed = new Date(Date.UTC(year, month - 1, day));
  if (parsed.getUTCFullYear() !== year || parsed.getUTCMonth() !== month - 1 || parsed.getUTCDate() !== day) return "";
  return `${String(year).padStart(4, "0")}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
}

function publishYear(createdAt) {
  if (!createdAt) return null;
  const explicit = /\b(20\d{2})\b/u.exec(createdAt);
  if (explicit) return Number(explicit[1]);
  const parsed = new Date(createdAt);
  if (!Number.isNaN(parsed.valueOf())) return parsed.getUTCFullYear();
  return null;
}

function publishDate(createdAt) {
  if (!createdAt) return null;
  const weiboDate = /\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(\d{1,2})\s+\d{2}:\d{2}:\d{2}\s+[+-]\d{4}\s+(20\d{2})\b/iu.exec(createdAt);
  if (weiboDate) {
    const months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
    return new Date(Date.UTC(Number(weiboDate[3]), months.indexOf(weiboDate[1].toLocaleLowerCase()), Number(weiboDate[2])));
  }
  const parsed = new Date(createdAt);
  if (Number.isNaN(parsed.valueOf())) return null;
  return new Date(Date.UTC(parsed.getUTCFullYear(), parsed.getUTCMonth(), parsed.getUTCDate()));
}

function extractDate(lines, createdAt) {
  const year = publishYear(createdAt);
  const posted = publishDate(createdAt);
  const fullCandidates = [];
  const monthDayCandidates = [];

  for (let index = 0; index < lines.length; index += 1) {
    const normalized = lines[index].normalized;
    if (DATE_REJECT_TERMS.some((term) => normalized.includes(term))) continue;
    if (/(?:[￥¥$]\s*\d|\d\s*元|\bRMB\b)/iu.test(normalized)) continue;
    let score = 0;
    if (/(?:活动|演出|公演)?日期\s*[:：]|(?:活动|演出|公演)时间\s*[:：]/u.test(normalized)) score += 60;
    if (/[（(](?:周?[一二三四五六日天]|Mon|Tue|Wed|Thu|Fri|Sat|Sun|月|火|水|木|金|土|日)[）)]/iu.test(normalized)) score += 25;

    let withoutFull = normalized;
    for (const pattern of FULL_DATE_PATTERNS) {
      for (const match of normalized.matchAll(new RegExp(pattern, "gu"))) {
        const value = validDate(Number(match[1]), Number(match[2]), Number(match[3]));
        if (value) fullCandidates.push({ score, index, value });
      }
      withoutFull = withoutFull.replace(new RegExp(pattern, "gu"), "");
    }
    for (const pattern of MONTH_DAY_PATTERNS) {
      for (const match of withoutFull.matchAll(new RegExp(pattern, "gu"))) {
        const month = Number(match[1]);
        const day = Number(match[2]);
        if (year !== null && validDate(year, month, day)) monthDayCandidates.push({ month, day });
      }
    }
  }

  if (fullCandidates.length > 0) {
    const values = new Set(fullCandidates.map((candidate) => candidate.value));
    if (values.size > 1) return "";
    fullCandidates.sort((left, right) => right.score - left.score || left.index - right.index || right.value.localeCompare(left.value));
    return fullCandidates[0].value;
  }

  const uniqueMonthDays = new Map(monthDayCandidates.map(({ month, day }) => [`${month}-${day}`, { month, day }]));
  if (year !== null && uniqueMonthDays.size === 1) {
    const { month, day } = uniqueMonthDays.values().next().value;
    let value = validDate(year, month, day);
    if (value && posted && posted.getUTCFullYear() === year) {
      const candidate = new Date(`${value}T00:00:00Z`);
      if ((posted.valueOf() - candidate.valueOf()) / 86_400_000 > 180) value = validDate(year + 1, month, day);
    }
    return value;
  }
  return "";
}

function extractCity(lines) {
  for (const line of lines) {
    const explicit = CITY_LABEL_RE.exec(line.normalized);
    if (explicit) {
      const match = CITY_RE.exec(explicit[1]);
      if (match) return match[1];
    }
  }
  for (const line of lines) {
    if (!LOCATION_CONTEXT_RE.test(line.normalized)) continue;
    const match = CITY_RE.exec(line.normalized);
    if (match) return match[1];
  }
  const station = new RegExp(`(${CITY_PATTERN})(?:站|场)(?:$|[\\s，,。])`, "u");
  for (const line of lines) {
    const match = station.exec(line.normalized);
    if (match) return match[1];
  }
  const standalone = new RegExp(`^\\s*(${CITY_PATTERN})(?:市)?\\s*$`, "u");
  for (const line of lines) {
    const match = standalone.exec(line.normalized);
    if (match) return match[1];
  }
  return "";
}

function trimAddressPrefix(value) {
  let result = stripLeadingSymbols(value);
  const label = VENUE_LABEL_RE.exec(result);
  if (label) result = stripLeadingSymbols(label[1]);
  const parentheticals = [...result.matchAll(/[（(]([^（）()]{2,50})[）)]/gu)].map((match) => match[1]);
  const parentheticalStart = Math.max(result.lastIndexOf("（"), result.lastIndexOf("("));
  const addressPrefix = parentheticalStart >= 0 ? result.slice(0, parentheticalStart) : result;
  if (ADDRESS_MARKER_RE.test(addressPrefix)) {
    for (const rawCandidate of parentheticals.reverse()) {
      const candidate = stripLeadingSymbols(rawCandidate);
      if (VENUE_SUFFIX_RE.test(candidate)) return candidate;
    }
    const tail = result.replace(/^.*(?:号|楼|层)\s*/u, "");
    if (tail) result = tail;
  }
  return result.replace(/^[ ,，;；]+|[ ,，;；]+$/gu, "");
}

function venueFromValue(value) {
  let result = trimAddressPrefix(value);
  if (!result || VENUE_SENTENCE_RE.test(result)) return "";
  if ([...NON_VENUE_NAMES].some((name) => result.endsWith(name))) return "";
  if (result.length <= 70 && VENUE_SUFFIX_RE.test(result) && !/(?:票务|抽奖|开售)/u.test(result)) return result;
  const match = VENUE_ANY_RE.exec(result);
  if (!match) return "";
  result = trimAddressPrefix(match[1].trim());
  return result.length >= 2 && result.length <= 70 && !NON_VENUE_NAMES.has(result) ? result : "";
}

function safeVenueLiteral(value) {
  const result = value.trim();
  return result.length >= 2 && result.length <= 70
    && !ADDRESS_MARKER_RE.test(result)
    && !VENUE_SENTENCE_RE.test(result)
    && !looksLikeMetadata(result)
    && ![...NON_VENUE_NAMES].some((name) => result.endsWith(name))
    && !/^https?:\/\//iu.test(result);
}

function extractLivehouse(lines) {
  for (const line of lines) {
    const label = VENUE_LABEL_RE.exec(line.raw);
    if (!label) continue;
    const candidate = venueFromValue(label[1]);
    if (candidate) return candidate;
    const literal = trimAddressPrefix(label[1]);
    if (safeVenueLiteral(literal)) return literal;
  }
  for (const line of lines) {
    if (!LOCATION_LINE_SYMBOLS.some((symbol) => line.raw.trimStart().startsWith(symbol))) continue;
    const literal = trimAddressPrefix(line.raw);
    const candidate = venueFromValue(literal);
    if (candidate) return candidate;
    if (safeVenueLiteral(literal)) return literal;
  }
  for (const line of lines) {
    if (!LOCATION_CONTEXT_RE.test(line.normalized) || !/[（(][^）)]+[）)]/u.test(line.raw)) continue;
    const candidate = venueFromValue(line.raw);
    if (candidate) return candidate;
  }
  for (const line of lines) {
    const candidate = venueFromValue(line.raw);
    if (candidate && !LOCATION_CONTEXT_RE.test(candidate)) return candidate;
  }
  return "";
}

function domainMatches(hostname, domains) {
  const normalized = hostname.toLocaleLowerCase().replace(/\.$/u, "");
  return [...domains].some((domain) => normalized === domain || normalized.endsWith(`.${domain}`));
}

async function resolveTicketURL(value, fetchShortener) {
  let url;
  try {
    url = new URL(value);
  } catch {
    return "";
  }
  if (!new Set(["http:", "https:"]).has(url.protocol) || url.username || url.password) return "";
  if (domainMatches(url.hostname, TICKET_PROVIDER_DOMAINS)) return value;
  if (!domainMatches(url.hostname, TRUSTED_SHORTENER_DOMAINS) || url.port || !fetchShortener) return "";
  let response;
  try {
    response = await fetchShortener(value);
    if (![301, 302, 303, 307, 308].includes(response.status)) return "";
    const location = response.headers.get("location");
    if (!location) return "";
    const destination = new URL(location, value);
    return new Set(["http:", "https:"]).has(destination.protocol)
      && !destination.username
      && !destination.password
      && domainMatches(destination.hostname, TICKET_PROVIDER_DOMAINS)
      ? destination.toString()
      : "";
  } catch (error) {
    if (error instanceof EventWeiboError && error.code === "upstream_timeout") throw error;
    return "";
  } finally {
    try { await response?.body?.cancel(); } catch { /* Best effort. */ }
  }
}

async function extractTicketURL(values, fetchShortener) {
  for (const value of values) {
    const result = await resolveTicketURL(value, fetchShortener);
    if (result) return result;
  }
  return "";
}

export async function extractEventFieldsFromText(text, options) {
  const lines = contentLines(text);
  return {
    name: extractName(lines),
    date: extractDate(lines, options.createdAt ?? null),
    city: extractCity(lines),
    livehouse: extractLivehouse(lines),
    weiboURL: options.weiboURL,
    ticketURL: await extractTicketURL(options.structuredURLs ?? [], options.fetchShortener),
    note: "",
  };
}

export function statusReference(value) {
  if (/[\u0000-\u001f\u007f\\]/u.test(value)) {
    throw new EventWeiboError("invalid_weibo_url", 422);
  }
  for (const character of value) {
    const codePoint = character.codePointAt(0);
    if (codePoint >= 0xd800 && codePoint <= 0xdfff) {
      throw new EventWeiboError("invalid_weibo_url", 422);
    }
  }
  const rawMatch = /^https:\/\/(?:weibo\.com|www\.weibo\.com)\/([^/?#]+)\/([^/?#]+)$/iu.exec(value);
  if (!rawMatch) {
    throw new EventWeiboError("invalid_weibo_url", 422);
  }
  const rawParts = rawMatch.slice(1);
  let parts;
  try {
    if (rawParts.some((part) => /%(?![0-9A-Fa-f]{2})/u.test(part))) {
      throw new URIError("invalid percent escape");
    }
    parts = rawParts.map(decodeURIComponent);
  } catch {
    throw new EventWeiboError("invalid_weibo_url", 422);
  }
  if (parts.length !== 2 || !parts[0] || !/^[A-Za-z0-9]+$/u.test(parts[1])) {
    throw new EventWeiboError("invalid_weibo_url", 422);
  }
  const userCodePoints = [...parts[0]].length;
  if (userCodePoints < 1 || userCodePoints > 200 || new Set([".", ".."]).has(parts[0])
    || /[\u0000-\u001f\u007f/?#\\]/u.test(parts[0])) {
    throw new EventWeiboError("invalid_weibo_url", 422);
  }
  return { user: parts[0], reference: parts[1] };
}

function setCookieValues(headers) {
  if (typeof headers.getSetCookie === "function") {
    try {
      const values = headers.getSetCookie();
      if (Array.isArray(values)) return values;
    } catch {
      // Some Worker runtimes expose the method but disallow reading Set-Cookie.
    }
  }
  if (typeof headers.getAll === "function") {
    try {
      const values = headers.getAll("set-cookie");
      if (Array.isArray(values)) return values;
    } catch {
      // Fall through to the combined header representation.
    }
  }
  const combined = headers.get("set-cookie");
  return combined ? combined.split(/,(?=\s*[^=;,\s]+=[^;,]*)/u) : [];
}

export class RequestCookieJar {
  constructor(now = () => Date.now()) {
    this.cookies = new Map();
    this.now = now;
  }

  absorb(headers, sourceURL) {
    const source = new URL(sourceURL);
    const receivedAt = this.now();
    for (const rawValue of setCookieValues(headers)) {
      const segments = rawValue.split(";").map((segment) => segment.trim()).filter(Boolean);
      const separator = segments[0]?.indexOf("=") ?? -1;
      if (separator <= 0) continue;
      const name = segments[0].slice(0, separator).trim();
      const value = segments[0].slice(separator + 1).trim();
      if (!/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/u.test(name) || name.length > 128
        || value.length > 4_096 || /[\u0000-\u001f\u007f]/u.test(value)) continue;
      let domain = source.hostname.toLocaleLowerCase();
      let hostOnly = true;
      const lastSlash = source.pathname.lastIndexOf("/");
      let path = lastSlash <= 0 ? "/" : source.pathname.slice(0, lastSlash);
      let secure = false;
      let invalid = false;
      let expired = false;
      let maxAgeSeconds = null;
      let expiresAt = null;
      for (const segment of segments.slice(1)) {
        const [rawKey, ...rawRest] = segment.split("=");
        const key = rawKey.toLocaleLowerCase();
        const attributeValue = rawRest.join("=").trim();
        if (key === "domain" && attributeValue) {
          const candidate = attributeValue.toLocaleLowerCase().replace(/^\./u, "").replace(/\.$/u, "");
          if (source.hostname.toLocaleLowerCase() !== candidate
            && !source.hostname.toLocaleLowerCase().endsWith(`.${candidate}`)) {
            invalid = true;
            break;
          }
          if (candidate !== "weibo.com" && candidate !== source.hostname.toLocaleLowerCase()) {
            invalid = true;
            break;
          }
          domain = candidate;
          hostOnly = false;
        } else if (key === "path" && attributeValue.startsWith("/")) {
          path = attributeValue;
        } else if (key === "secure") {
          secure = true;
        } else if (key === "max-age" && /^[+-]?\d+$/u.test(attributeValue)) {
          const parsed = Number(attributeValue);
          if (Number.isFinite(parsed)) maxAgeSeconds = parsed;
        } else if (key === "expires") {
          const expiry = Date.parse(attributeValue);
          if (!Number.isNaN(expiry)) expiresAt = expiry;
        }
      }
      if (maxAgeSeconds !== null) {
        expiresAt = maxAgeSeconds <= 0
          ? receivedAt
          : Math.min(Number.MAX_SAFE_INTEGER, receivedAt + maxAgeSeconds * 1_000);
      }
      if (invalid) continue;
      if (expiresAt !== null && expiresAt <= receivedAt) expired = true;
      const storageKey = `${name}\n${domain}\n${path}`;
      if (expired) this.cookies.delete(storageKey);
      else if (this.cookies.size < 50 || this.cookies.has(storageKey)) {
        this.cookies.set(storageKey, {
          name,
          value,
          domain,
          hostOnly,
          path,
          secure,
          expiresAt,
        });
      }
    }
  }

  header(targetURL) {
    const target = new URL(targetURL);
    const host = target.hostname.toLocaleLowerCase();
    const values = [];
    const now = this.now();
    for (const [storageKey, cookie] of this.cookies) {
      if (cookie.expiresAt !== null && cookie.expiresAt <= now) {
        this.cookies.delete(storageKey);
        continue;
      }
      const domainAllowed = cookie.hostOnly ? host === cookie.domain : host === cookie.domain || host.endsWith(`.${cookie.domain}`);
      const pathAllowed = target.pathname === cookie.path
        || target.pathname.startsWith(cookie.path.endsWith("/") ? cookie.path : `${cookie.path}/`)
        || cookie.path === "/";
      if (domainAllowed && pathAllowed && (!cookie.secure || target.protocol === "https:")) {
        values.push(`${cookie.name}=${cookie.value}`);
      }
    }
    return values.join("; ");
  }
}

function makeDeadline(milliseconds) {
  const controller = new AbortController();
  const sentinel = Symbol("deadline");
  let timer;
  const promise = new Promise((resolve) => {
    timer = setTimeout(() => {
      controller.abort();
      resolve(sentinel);
    }, milliseconds);
  });
  return { controller, sentinel, promise, clear: () => clearTimeout(timer) };
}

async function raceDeadline(promise, deadline) {
  const wrapped = Promise.resolve(promise).then(
    (value) => ({ ok: true, value }),
    (error) => ({ ok: false, error }),
  );
  const outcome = await Promise.race([wrapped, deadline.promise]);
  if (outcome === deadline.sentinel) throw new EventWeiboError("upstream_timeout", 504);
  return outcome;
}

function cancelReader(reader, reason) {
  try {
    const cancellation = reader.cancel(reason);
    if (cancellation && typeof cancellation.catch === "function") cancellation.catch(() => {});
  } catch {
    // Cancellation is best-effort after the request has already failed.
  }
}

async function readLimitedRequestText(request, deadline, maximum = MAX_REQUEST_CHARS) {
  if (!request.body) return "";
  let reader;
  try {
    reader = request.body.getReader();
  } catch {
    throw new EventWeiboError("invalid_request", 400);
  }
  const chunks = [];
  let total = 0;
  try {
    while (true) {
      let outcome;
      try {
        outcome = await raceDeadline(reader.read(), deadline);
      } catch {
        cancelReader(reader, "invalid or timed out request body");
        throw new EventWeiboError("invalid_request", 400);
      }
      if (!outcome.ok || !outcome.value || typeof outcome.value.done !== "boolean") {
        cancelReader(reader, "invalid request body");
        throw new EventWeiboError("invalid_request", 400);
      }
      if (outcome.value.done) break;
      if (!(outcome.value.value instanceof Uint8Array)) {
        cancelReader(reader, "invalid request body chunk");
        throw new EventWeiboError("invalid_request", 400);
      }
      total += outcome.value.value.byteLength;
      if (total > maximum) {
        deadline.controller.abort();
        cancelReader(reader, "request body too large");
        throw new EventWeiboError("invalid_request", 400);
      }
      chunks.push(outcome.value.value);
    }
    const combined = new Uint8Array(total);
    let offset = 0;
    for (const chunk of chunks) {
      combined.set(chunk, offset);
      offset += chunk.byteLength;
    }
    try {
      return new TextDecoder("utf-8", { fatal: true }).decode(combined);
    } catch {
      throw new EventWeiboError("invalid_request", 400);
    }
  } finally {
    try { reader.releaseLock(); } catch { /* Reader can already be detached. */ }
  }
}

async function readLimitedText(response, deadline, maximum = MAX_UPSTREAM_BYTES) {
  if (!response.body) return "";
  let reader;
  try {
    reader = response.body.getReader();
  } catch {
    throw new EventWeiboError("invalid_upstream_response", 502);
  }
  const chunks = [];
  let total = 0;
  try {
    while (true) {
      const outcome = await raceDeadline(reader.read(), deadline);
      if (!outcome.ok || !outcome.value || typeof outcome.value.done !== "boolean") {
        throw new EventWeiboError("invalid_upstream_response", 502);
      }
      if (outcome.value.done) break;
      if (!(outcome.value.value instanceof Uint8Array)) throw new EventWeiboError("invalid_upstream_response", 502);
      total += outcome.value.value.byteLength;
      if (total > maximum) {
        deadline.controller.abort();
        try { await reader.cancel(); } catch { /* Best effort. */ }
        throw new EventWeiboError("invalid_upstream_response", 502);
      }
      chunks.push(outcome.value.value);
    }
    const combined = new Uint8Array(total);
    let offset = 0;
    for (const chunk of chunks) {
      combined.set(chunk, offset);
      offset += chunk.byteLength;
    }
    try {
      return new TextDecoder("utf-8", { fatal: true }).decode(combined);
    } catch {
      throw new EventWeiboError("invalid_upstream_response", 502);
    }
  } finally {
    try { reader.releaseLock(); } catch { /* Reader can already be detached. */ }
  }
}

class WeiboVisitorClient {
  constructor(fetchImpl, deadline) {
    this.fetchImpl = fetchImpl;
    this.deadline = deadline;
    this.cookies = new RequestCookieJar();
    this.bootstrapped = false;
    this.diagnosticStage = "client_init";
  }

  async requestText(value, referer, { statusRequest = false } = {}) {
    this.diagnosticStage = "request_url";
    let current = new URL(value);
    for (let redirectCount = 0; redirectCount <= 3; redirectCount += 1) {
      if (current.protocol !== "https:" || !WEIBO_HOSTS.has(current.hostname.toLocaleLowerCase())) {
        throw new EventWeiboError("invalid_upstream_response", 502);
      }
      const headers = new Headers({
        "user-agent": USER_AGENT,
        accept: "application/json,text/plain,*/*",
        referer,
      });
      this.diagnosticStage = "cookie_header";
      const cookie = this.cookies.header(current.toString());
      if (cookie) headers.set("cookie", cookie);
      this.diagnosticStage = "upstream_fetch";
      const fetchImpl = this.fetchImpl;
      const outcome = await raceDeadline(Promise.resolve().then(() => fetchImpl(current.toString(), {
        method: "GET",
        headers,
        redirect: "manual",
        cache: "no-store",
        signal: this.deadline.controller.signal,
      })), this.deadline);
      if (!outcome.ok || !(outcome.value instanceof Response)) {
        throw new EventWeiboError("weibo_upstream_unavailable", 502);
      }
      const response = outcome.value;
      this.diagnosticStage = "cookie_absorb";
      this.cookies.absorb(response.headers, current.toString());
      if ([301, 302, 303, 307, 308].includes(response.status)) {
        const location = response.headers.get("location");
        try { await response.body?.cancel(); } catch { /* Best effort. */ }
        if (!location || redirectCount === 3) throw new EventWeiboError("invalid_upstream_response", 502);
        try {
          current = new URL(location, current);
        } catch {
          throw new EventWeiboError("invalid_upstream_response", 502);
        }
        continue;
      }
      if (!response.ok) {
        try { await response.body?.cancel(); } catch { /* Best effort. */ }
        if (statusRequest && [400, 401, 403, 404, 410].includes(response.status)) {
          throw new EventWeiboError("status_unavailable", 422);
        }
        throw new EventWeiboError("weibo_upstream_unavailable", 502);
      }
      this.diagnosticStage = "upstream_body";
      return readLimitedText(response, this.deadline);
    }
    throw new EventWeiboError("invalid_upstream_response", 502);
  }

  async bootstrap() {
    const fingerprint = JSON.stringify({
      os: "1",
      browser: "Chrome70,0,3538,102",
      fonts: "undefined",
      screenInfo: "1920*1080*24",
      plugins: "",
    });
    const generatedURL = new URL("https://passport.weibo.com/visitor/genvisitor");
    generatedURL.search = new URLSearchParams({ cb: "gen_callback", fp: fingerprint }).toString();
    this.diagnosticStage = "bootstrap_generate";
    const generatedText = await this.requestText(generatedURL.toString(), "https://weibo.com/");
    this.diagnosticStage = "bootstrap_parse";
    const match = /gen_callback\((.*)\)\s*;?\s*$/su.exec(generatedText);
    if (!match) throw new EventWeiboError("invalid_upstream_response", 502);
    let generated;
    try {
      generated = JSON.parse(match[1]);
    } catch {
      throw new EventWeiboError("invalid_upstream_response", 502);
    }
    const tid = generated?.data?.tid;
    if (generated?.retcode !== 20000000 || typeof tid !== "string" || !tid || tid.length > 512
      || /[\u0000-\u001f\u007f]/u.test(tid)) {
      throw new EventWeiboError("weibo_upstream_unavailable", 502);
    }
    const incarnateURL = new URL("https://passport.weibo.com/visitor/visitor");
    incarnateURL.search = new URLSearchParams({
      a: "incarnate",
      t: tid,
      w: "2",
      c: "100",
      gc: "",
      cb: "cross_domain",
      from: "weibo",
    }).toString();
    this.diagnosticStage = "bootstrap_incarnate";
    await this.requestText(incarnateURL.toString(), "https://weibo.com/");
    this.bootstrapped = true;
  }

  async fetchStatus(weiboURL) {
    const { reference } = statusReference(weiboURL);
    const referer = new URL(weiboURL).toString();
    if (!this.bootstrapped) await this.bootstrap();
    this.diagnosticStage = "status_request";
    const statusURL = new URL("https://weibo.com/ajax/statuses/show");
    statusURL.search = new URLSearchParams({ id: reference }).toString();
    const statusText = await this.requestText(statusURL.toString(), referer, { statusRequest: true });
    this.diagnosticStage = "status_parse";
    let status;
    try {
      status = JSON.parse(statusText);
    } catch {
      throw new EventWeiboError("invalid_upstream_response", 502);
    }
    if (!isPlainObject(status)) throw new EventWeiboError("invalid_upstream_response", 502);
    if (status.ok === 0 || status.error) throw new EventWeiboError("status_unavailable", 422);

    let text = status.text_raw || status.text || "";
    if (status.isLongText) {
      let longText = status.longTextContent;
      if (!longText) {
        const longID = status.mblogid || status.id || reference;
        if ((typeof longID !== "string" && typeof longID !== "number")
          || String(longID).length > 512 || /[\u0000-\u001f\u007f]/u.test(String(longID))) {
          throw new EventWeiboError("invalid_upstream_response", 502);
        }
        const longURL = new URL("https://weibo.com/ajax/statuses/longtext");
        longURL.search = new URLSearchParams({ id: String(longID) }).toString();
        const longBody = await this.requestText(longURL.toString(), referer, { statusRequest: true });
        let longPayload;
        try {
          longPayload = JSON.parse(longBody);
        } catch {
          throw new EventWeiboError("invalid_upstream_response", 502);
        }
        const data = isPlainObject(longPayload?.data) ? longPayload.data : longPayload;
        longText = isPlainObject(data) ? data.longTextContent : null;
      }
      if (typeof longText === "string" && longText) text = longText;
    }
    if (typeof text !== "string" || !text) throw new EventWeiboError("status_unavailable", 422);
    if (text.length > MAX_STATUS_TEXT_CHARS) throw new EventWeiboError("invalid_upstream_response", 502);

    const structuredURLs = [];
    if (Array.isArray(status.url_struct)) {
      for (const entry of status.url_struct.slice(0, 100)) {
        if (!isPlainObject(entry)) continue;
        for (const key of ["long_url", "ori_url", "short_url"]) {
          const value = entry[key];
          if (typeof value === "string" && value.length <= 2_048 && /^https?:\/\//iu.test(value)) {
            if (!structuredURLs.includes(value)) structuredURLs.push(value);
            break;
          }
        }
        if (structuredURLs.length >= MAX_STRUCTURED_URLS) break;
      }
    }
    return {
      text,
      createdAt: typeof status.created_at === "string" && status.created_at.length <= 200
        ? status.created_at
        : null,
      structuredURLs,
    };
  }

  async fetchShortener(value) {
    let url;
    try {
      url = new URL(value);
    } catch {
      return new Response(null, { status: 400 });
    }
    if (!new Set(["http:", "https:"]).has(url.protocol) || !domainMatches(url.hostname, TRUSTED_SHORTENER_DOMAINS)) {
      return new Response(null, { status: 400 });
    }
    const fetchImpl = this.fetchImpl;
    const outcome = await raceDeadline(Promise.resolve().then(() => fetchImpl(url.toString(), {
      method: "GET",
      headers: new Headers({ "user-agent": USER_AGENT, accept: "*/*" }),
      redirect: "manual",
      cache: "no-store",
      signal: this.deadline.controller.signal,
    })), this.deadline);
    if (!outcome.ok || !(outcome.value instanceof Response)) throw new EventWeiboError("weibo_upstream_unavailable", 502);
    return outcome.value;
  }
}

function clientIP(request) {
  const cloudflareIP = request.headers.get("cf-connecting-ip");
  if (cloudflareIP) return cloudflareIP.trim().slice(0, 128);
  const forwarded = request.headers.get("x-forwarded-for");
  if (forwarded) return forwarded.split(",", 1)[0].trim().slice(0, 128);
  return "unknown";
}

async function rateLimitDecision(request, env) {
  if (!env?.EVENT_WEIBO_RATE_LIMITER || typeof env.EVENT_WEIBO_RATE_LIMITER.limit !== "function") {
    return "unavailable";
  }
  try {
    const result = await env.EVENT_WEIBO_RATE_LIMITER.limit({ key: clientIP(request) });
    if (!result || typeof result.success !== "boolean") return "unavailable";
    return result.success ? "allowed" : "denied";
  } catch {
    return "unavailable";
  }
}

function boundedCandidate(candidate) {
  const exactKeys = ["name", "date", "city", "livehouse", "weiboURL", "ticketURL", "note"];
  if (!isPlainObject(candidate) || Object.keys(candidate).length !== exactKeys.length
    || !exactKeys.every((key) => Object.prototype.hasOwnProperty.call(candidate, key) && typeof candidate[key] === "string")) {
    throw new EventWeiboError("internal_error", 500);
  }
  const maximums = { name: 300, date: 10, city: 100, livehouse: 300, weiboURL: 2_048, ticketURL: 2_048, note: 500 };
  if (exactKeys.some((key) => candidate[key].length > maximums[key])) {
    throw new EventWeiboError("invalid_upstream_response", 502);
  }
  const body = { version: 1, kind: "candidate", candidate };
  if (new TextEncoder().encode(JSON.stringify(body)).byteLength > MAX_CANDIDATE_RESPONSE_BYTES) {
    throw new EventWeiboError("invalid_upstream_response", 502);
  }
  return body;
}

export async function extractWeiboCandidateRequest(request, env = {}, options = {}) {
  if (request.method !== "POST") return reject("method_not_allowed", 405);
  const contentType = request.headers.get("content-type") || "";
  if (contentType.split(";", 1)[0].trim().toLocaleLowerCase() !== "application/json") {
    return reject("invalid_request", 400);
  }
  const contentLengthHeader = request.headers.get("content-length");
  if (contentLengthHeader !== null
    && (!/^\d+$/u.test(contentLengthHeader.trim()) || Number(contentLengthHeader) > MAX_REQUEST_CHARS)) {
    return reject("invalid_request", 400);
  }

  if (!options.skipRateLimit) {
    const rateLimit = await rateLimitDecision(request, env);
    if (rateLimit === "unavailable") return reject("rate_limit_unavailable", 503);
    if (rateLimit === "denied") return reject("rate_limited", 429);
  }

  const deadline = makeDeadline(options.deadlineMs ?? DEFAULT_DEADLINE_MS);
  let diagnosticStage = "request_body";
  let client = null;
  try {
    const rawBody = await readLimitedRequestText(request, deadline);
    let input;
    try {
      input = JSON.parse(rawBody);
    } catch {
      throw new EventWeiboError("invalid_request", 400);
    }
    if (!isPlainObject(input) || !hasOnlyKeys(input, new Set(["version", "weiboURL"]))
      || Object.keys(input).length !== 2 || input.version !== 1 || typeof input.weiboURL !== "string"
      || !input.weiboURL.trim() || input.weiboURL.length > 2_048 || input.weiboURL !== input.weiboURL.trim()) {
      throw new EventWeiboError("invalid_request", 400);
    }
    diagnosticStage = "validate_url";
    statusReference(input.weiboURL);
    client = new WeiboVisitorClient(options.fetchImpl ?? fetch, deadline);
    diagnosticStage = "fetch_status";
    const status = await client.fetchStatus(input.weiboURL);
    diagnosticStage = "extract_fields";
    const candidate = await extractEventFieldsFromText(status.text, {
      weiboURL: input.weiboURL,
      createdAt: status.createdAt,
      structuredURLs: status.structuredURLs,
      fetchShortener: (value) => client.fetchShortener(value),
    });
    diagnosticStage = "bound_candidate";
    return { status: 200, body: boundedCandidate(candidate) };
  } catch (error) {
    if (error instanceof EventWeiboError) return reject(error.code, error.status);
    console.error(`event_weibo_internal:${client?.diagnosticStage ?? diagnosticStage}`);
    return reject("internal_error", 500);
  } finally {
    deadline.clear();
  }
}

export { EVENT_ENDPOINT };
