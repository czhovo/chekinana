#!/usr/bin/env python3
"""Deterministically extract Event fields from public Weibo status URLs.

The extractor deliberately does not use an LLM, image/OCR input, browser
automation, authenticated accounts, or persistent cookies. Weibo visitor
cookies live only in an in-memory CookieJar for the lifetime of the process.
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import email.utils
import html
from html.parser import HTMLParser
import http.cookiejar
import json
import re
import sys
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Iterable, Sequence


USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"
)

TICKET_PROVIDER_DOMAINS = frozenset(
    {
        "showstart.com",
        "damai.cn",
        "piaoxingqiu.com",
        "maoyan.com",
        "247tickets.com",
        "gewara.com",
        "motntickets.com",
        "cityline.com",
        "hkticketing.com",
    }
)
TRUSTED_SHORTENER_DOMAINS = frozenset({"t.cn", "sinaurl.cn"})

GENERIC_NAME_TERMS = (
    "演出信息",
    "公演信息",
    "活动信息",
    "演出情报",
    "公演情报",
    "活动情报",
    "情报解禁",
    "主催情报解禁",
    "主催情报",
    "timing公布",
    "timetable公布",
    "timetable",
    "时间表公布",
    "阵容公布",
    "参演阵容",
    "演出公告",
    "公演公告",
    "活动公告",
    "通知",
    "票务信息",
    "开售公告",
)
DATE_REJECT_TERMS = (
    "开售",
    "发售",
    "售票",
    "票价",
    "购票",
    "抢票",
    "售罄",
    "抽奖",
    "开奖",
    "转发",
    "截止",
)
NAME_REJECT_TERMS = (
    "转抽",
    "转发抽",
    "抽奖",
    "开奖",
    "中奖",
    "奖品",
    "参与方式",
    "礼包",
    "大合影",
    "免费入场",
    "免票",
    "票价",
    "售票",
    "开售",
)
NON_VENUE_NAMES = frozenset({"餐厅", "客厅", "大厅", "展厅", "食堂", "饭店", "酒店"})
EVENT_PREFIX_RE = re.compile(
    r"(?:生诞祭|生日祭|定期公演|周年公演|主催(?:公演)?|专场|演唱会|巡演|公演|"
    r"(?:FES|LIVE|PARTY))\s*[!！~～:：·・\-—]*$",
    re.IGNORECASE,
)
EVENT_NAME_SIGNAL_RE = re.compile(
    r"(?:生诞祭|生日祭|定期公演|周年|ONE\s*MAN|FES\b|LIVE\b|VOL\.?\s*\d+)",
    re.IGNORECASE,
)
THEME_RE = re.compile(r"^[『「《](.+)[』」》]$")
EXPLICIT_NAME_RE = re.compile(
    r"^(?:活动名称|演出名称|公演名称|活动名|演出名|公演名|标题|主题|event)\s*[:：]\s*(.+)$",
    re.IGNORECASE,
)
BRACKET_TITLE_RE = re.compile(r"^【(.+)】$")

VENUE_SUFFIX_PATTERN = (
    r"(?:Live\s*house|CLUB|SPACE|空间|音乐厅|剧场|艺术中心|文化中心|展演中心|"
    r"演艺中心|体育馆|体育场|会展中心|舞台|小镇C厅|小镇[A-Za-z0-9一二三四五六七八九十]+厅|厅|馆|店)"
)
VENUE_SUFFIX_RE = re.compile(VENUE_SUFFIX_PATTERN + r"$", re.IGNORECASE)
VENUE_ANY_RE = re.compile(
    r"([A-Za-z0-9\u4e00-\u9fff][A-Za-z0-9\u4e00-\u9fff·&.+!'’‘\- ]{0,38}"
    + VENUE_SUFFIX_PATTERN
    + r"(?:[（(][^）)]{1,24}[）)])?)",
    re.IGNORECASE,
)
VENUE_LABEL_RE = re.compile(
    r"^(?:演出场地|活动场地|公演场地|演出地址|活动地址|公演地址|场地|地点|会场|venue|add|address)\s*[:：]\s*(.+)$",
    re.IGNORECASE,
)
ADDRESS_MARKER_RE = re.compile(r"(?:省|市|区|县|自治州|路|街|道|号|楼|层|商场|MALL)", re.IGNORECASE)

CITY_NAMES = (
    "北京",
    "上海",
    "天津",
    "重庆",
    "广州",
    "深圳",
    "成都",
    "杭州",
    "南京",
    "武汉",
    "长沙",
    "苏州",
    "西安",
    "郑州",
    "济南",
    "青岛",
    "合肥",
    "南昌",
    "福州",
    "厦门",
    "昆明",
    "贵阳",
    "南宁",
    "沈阳",
    "大连",
    "长春",
    "哈尔滨",
    "石家庄",
    "太原",
    "兰州",
    "乌鲁木齐",
    "海口",
    "宁波",
    "无锡",
    "常州",
    "佛山",
    "东莞",
    "珠海",
    "温州",
    "嘉兴",
    "绍兴",
    "金华",
    "徐州",
    "南通",
    "扬州",
    "镇江",
    "泰州",
    "盐城",
    "淄博",
    "烟台",
    "潍坊",
    "临沂",
    "泉州",
    "中山",
    "惠州",
    "南宁",
    "呼和浩特",
    "银川",
    "西宁",
    "拉萨",
    "洛阳",
    "桂林",
    "台北",
    "香港",
    "澳门",
)
CITY_RE = re.compile("(" + "|".join(sorted(CITY_NAMES, key=len, reverse=True)) + r")(?:市)?")
CITY_LABEL_RE = re.compile(r"^(?:城市|演出城市|活动城市|公演城市)\s*[:：]\s*(.+)$")
LOCATION_CONTEXT_RE = re.compile(r"(?:地址|场地|地点|会场|venue|\baddress\b)", re.IGNORECASE)
LOCATION_LINE_SYMBOLS = ("📍", "📌", "🚩")
VENUE_SENTENCE_RE = re.compile(r"(?:演出后|结束后|散场后|一起|前往|去吃|去逛|聚餐|大家)")

FULL_DATE_RES = (
    re.compile(r"(?<!\d)(20\d{2})\s*[-/.]\s*(\d{1,2})\s*[-/.]\s*(\d{1,2})(?!\d)"),
    re.compile(r"(?<!\d)(20\d{2})\s*年\s*(\d{1,2})\s*月\s*(\d{1,2})\s*日?"),
)
MONTH_DAY_RES = (
    re.compile(r"(?<![\d.])(\d{1,2})\s*[-/.]\s*(\d{1,2})(?![\d.])"),
    re.compile(r"(?<!\d)(\d{1,2})\s*月\s*(\d{1,2})\s*日"),
)


@dataclasses.dataclass(frozen=True)
class EventFields:
    name: str = ""
    date: str = ""
    city: str = ""
    livehouse: str = ""
    weiboURL: str = ""
    ticketURL: str = ""
    note: str = ""

    def as_dict(self) -> dict[str, str]:
        return dataclasses.asdict(self)


@dataclasses.dataclass(frozen=True)
class _Line:
    raw: str
    normalized: str


class WeiboFetchError(RuntimeError):
    """Raised when public structured Weibo content cannot be fetched."""


class _TextHTMLParser(HTMLParser):
    BLOCK_TAGS = frozenset({"br", "p", "div", "li", "tr", "h1", "h2", "h3", "h4"})

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag.lower() in self.BLOCK_TAGS:
            self.parts.append("\n")

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() in self.BLOCK_TAGS:
            self.parts.append("\n")

    def handle_data(self, data: str) -> None:
        self.parts.append(data)

    def text(self) -> str:
        return "".join(self.parts)


def html_to_text(value: str) -> str:
    parser = _TextHTMLParser()
    parser.feed(value)
    parser.close()
    return html.unescape(parser.text())


def _strip_line(value: str) -> str:
    value = unicodedata.normalize("NFC", value)
    value = value.replace("\u200b", "").replace("\ufeff", "").replace("\xa0", " ")
    value = re.sub(r"[ \t]+", " ", value).strip()
    # Weibo long-text HTML sometimes exposes a literal continuation slash at
    # a rendered line boundary. It is transport decoration, not post content.
    value = value.strip("\\").strip()
    return value


def _content_lines(text: str) -> list[_Line]:
    lines: list[_Line] = []
    for raw in re.split(r"[\r\n]+", html_to_text(text)):
        raw = _strip_line(raw)
        if not raw:
            continue
        lines.append(_Line(raw=raw, normalized=unicodedata.normalize("NFKC", raw)))
    return lines


def _strip_leading_symbols(value: str) -> str:
    # Emoji are intentionally treated as decoration at rendered line edges.
    value = re.sub(r"^[\s\ufe0f#*•·▶►◆◇■□●○★☆⚓⛓🎫🎟📍📅🗓🕐🕒⏰✨🔥🎉💫🚩]+", "", value)
    while value and unicodedata.category(value[0]) in {"So", "Sk", "Mn"}:
        value = value[1:].lstrip()
    while value and unicodedata.category(value[-1]) in {"So", "Sk", "Mn"}:
        value = value[:-1].rstrip()
    value = value.lstrip("-—:：|｜")
    return value.strip()


def _is_generic_name(value: str) -> bool:
    normalized = unicodedata.normalize("NFKC", _strip_leading_symbols(value)).lower()
    normalized = re.sub(r"[\s:：!！~～·・\-—_]+", "", normalized)
    if not normalized:
        return True
    return any(term.lower().replace(" ", "") in normalized for term in GENERIC_NAME_TERMS + NAME_REJECT_TERMS)


def _looks_like_metadata(value: str) -> bool:
    normalized = unicodedata.normalize("NFKC", value).strip()
    if not normalized:
        return True
    if normalized.startswith(("http://", "https://", "@", "#")):
        return True
    if re.match(
        r"^(?:日期|时间|地点|场地|地址|票价|票务|阵容|出演|嘉宾|开场|入场|event|date|venue)\s*[:：]",
        normalized,
        re.IGNORECASE | re.ASCII,
    ):
        return True
    if _line_has_date(normalized):
        return True
    if any(term in normalized for term in NAME_REJECT_TERMS):
        return True
    return _is_generic_name(normalized)


def extract_name(lines: Sequence[_Line]) -> str:
    for line in lines:
        match = EXPLICIT_NAME_RE.match(line.normalized)
        if match:
            raw_match = EXPLICIT_NAME_RE.match(line.raw)
            value = _strip_leading_symbols((raw_match or match).group(1))
            if value and not _is_generic_name(value):
                return value

    for index, line in enumerate(lines):
        match = BRACKET_TITLE_RE.match(_strip_leading_symbols(line.raw))
        if match:
            value = _strip_leading_symbols(match.group(1)).strip()
            if value and not _is_generic_name(value) and not _line_has_date(value):
                if index + 1 < len(lines):
                    continuation = _strip_leading_symbols(lines[index + 1].raw)
                    if EVENT_PREFIX_RE.search(unicodedata.normalize("NFKC", continuation)) and not _looks_like_metadata(continuation):
                        return value + " " + continuation
                return value

    for index, line in enumerate(lines):
        current = _strip_leading_symbols(line.raw)
        current_norm = unicodedata.normalize("NFKC", current)
        inline_theme = re.match(r"^(.+?)([『「《].+[』」》])$", current)
        if inline_theme and EVENT_PREFIX_RE.search(unicodedata.normalize("NFKC", inline_theme.group(1))):
            if index + 1 < len(lines):
                continuation = _strip_leading_symbols(lines[index + 1].raw)
                if EVENT_PREFIX_RE.search(unicodedata.normalize("NFKC", continuation)) and not _looks_like_metadata(continuation):
                    return current + " " + continuation
            return current
        if EVENT_PREFIX_RE.search(current_norm) and index + 1 < len(lines):
            theme = _strip_leading_symbols(lines[index + 1].raw)
            if THEME_RE.match(theme):
                return current + theme

    for index in range(len(lines) - 1):
        first = _strip_generic_header_prefix(_strip_leading_symbols(lines[index].raw))
        second = _strip_leading_symbols(lines[index + 1].raw)
        if (
            first
            and not _looks_like_metadata(first)
            and EVENT_NAME_SIGNAL_RE.search(unicodedata.normalize("NFKC", second))
            and not _looks_like_metadata(second)
            and 3 <= len(first + second) <= 160
        ):
            return first + " " + second

    for line in lines:
        value = _strip_leading_symbols(line.raw)
        if EVENT_NAME_SIGNAL_RE.search(unicodedata.normalize("NFKC", value)) and not _looks_like_metadata(value):
            if 3 <= len(value) <= 160:
                return value

    for header_index, line in enumerate(lines):
        if not _is_generic_name(line.raw):
            continue
        date_index = next(
            (i for i in range(header_index + 1, len(lines)) if _line_has_eligible_date(lines[i].normalized)),
            None,
        )
        if date_index is None:
            continue
        for candidate in lines[header_index + 1 : date_index]:
            value = _strip_leading_symbols(candidate.raw)
            if not _looks_like_metadata(value) and 3 <= len(value) <= 160:
                return value

    return ""


def _strip_generic_header_prefix(value: str) -> str:
    match = re.match(r"^【([^】]+)】\s*(.+)$", value)
    if match and _is_generic_name(match.group(1)):
        value = _strip_leading_symbols(match.group(2))
    value = re.sub(
        r"^\s*\d{1,2}\s*月\s*\d{1,2}\s*日\s*(?:[（(][^）)]*[）)])?\s*",
        "",
        value,
    )
    return value.strip()


def _line_has_date(value: str) -> bool:
    normalized = unicodedata.normalize("NFKC", value)
    return any(regex.search(normalized) for regex in FULL_DATE_RES + MONTH_DAY_RES)


def _line_has_eligible_date(value: str) -> bool:
    normalized = unicodedata.normalize("NFKC", value)
    return _line_has_date(normalized) and not any(term in normalized for term in DATE_REJECT_TERMS)


def _valid_date(year: int, month: int, day: int) -> str | None:
    try:
        return dt.date(year, month, day).isoformat()
    except ValueError:
        return None


def extract_date(
    lines: Sequence[_Line],
    publish_year: int | None,
    publish_date: dt.date | None = None,
) -> str:
    full_candidates: list[tuple[int, int, str]] = []
    month_day_candidates: list[tuple[int, int, int, int]] = []
    for index, line in enumerate(lines):
        normalized = line.normalized
        if any(term in normalized for term in DATE_REJECT_TERMS):
            continue
        if re.search(r"(?:[￥¥$]\s*\d|\d\s*元|\bRMB\b)", normalized, re.IGNORECASE):
            continue
        context_score = 0
        if re.search(r"(?:活动|演出|公演)?日期\s*[:：]|(?:活动|演出|公演)时间\s*[:：]", normalized):
            context_score += 60
        if re.search(r"[（(](?:周?[一二三四五六日天]|Mon|Tue|Wed|Thu|Fri|Sat|Sun|月|火|水|木|金|土|日)[）)]", normalized, re.IGNORECASE):
            context_score += 25
        for regex in FULL_DATE_RES:
            for match in regex.finditer(normalized):
                value = _valid_date(int(match.group(1)), int(match.group(2)), int(match.group(3)))
                if value:
                    full_candidates.append((context_score, -index, value))
        normalized_without_full = normalized
        for regex in FULL_DATE_RES:
            normalized_without_full = regex.sub("", normalized_without_full)
        for regex in MONTH_DAY_RES:
            for match in regex.finditer(normalized_without_full):
                month, day = int(match.group(1)), int(match.group(2))
                if publish_year is not None and _valid_date(publish_year, month, day):
                    month_day_candidates.append((context_score, -index, month, day))

    if full_candidates:
        if len({candidate[2] for candidate in full_candidates}) > 1:
            return ""
        full_candidates.sort(reverse=True)
        return full_candidates[0][2]

    unique_month_days = {(candidate[2], candidate[3]) for candidate in month_day_candidates}
    if publish_year is not None and len(unique_month_days) == 1:
        month, day = next(iter(unique_month_days))
        value = _valid_date(publish_year, month, day)
        if value and publish_date and publish_date.year == publish_year:
            candidate_date = dt.date.fromisoformat(value)
            if candidate_date < publish_date - dt.timedelta(days=180):
                value = _valid_date(publish_year + 1, month, day)
        return value or ""
    return ""


def extract_city(lines: Sequence[_Line]) -> str:
    for line in lines:
        explicit = CITY_LABEL_RE.match(line.normalized)
        if explicit:
            match = CITY_RE.search(explicit.group(1))
            if match:
                return match.group(1)
    for line in lines:
        if LOCATION_CONTEXT_RE.search(line.normalized):
            match = CITY_RE.search(line.normalized)
            if match:
                return match.group(1)
    for line in lines:
        # A station marker is event body content, unlike Weibo's region_name.
        match = re.search(
            r"(" + "|".join(sorted(CITY_NAMES, key=len, reverse=True)) + r")(?:站|场)(?:$|[\s，,。])",
            line.normalized,
        )
        if match:
            return match.group(1)
    for line in lines:
        match = re.fullmatch(
            r"\s*(" + "|".join(sorted(CITY_NAMES, key=len, reverse=True)) + r")(?:市)?\s*",
            line.normalized,
        )
        if match:
            return match.group(1)
    return ""


def _trim_address_prefix(value: str) -> str:
    value = _strip_leading_symbols(value)
    label = VENUE_LABEL_RE.match(value)
    if label:
        value = _strip_leading_symbols(label.group(1))
    # Prefer a venue explicitly isolated in the final parenthetical of an address.
    parentheticals = re.findall(r"[（(]([^（）()]{2,50})[）)]", value)
    parenthetical_start = max(value.rfind("（"), value.rfind("("))
    address_prefix = value[:parenthetical_start] if parenthetical_start >= 0 else value
    if ADDRESS_MARKER_RE.search(address_prefix):
        for candidate in reversed(parentheticals):
            candidate = _strip_leading_symbols(candidate)
            if VENUE_SUFFIX_RE.search(candidate):
                return candidate

    if ADDRESS_MARKER_RE.search(address_prefix):
        # Detailed addresses typically end at 号/楼/层; the remaining tail is venue-only.
        pieces = re.split(r"^.*(?:号|楼|层)\s*", value, maxsplit=1)
        if len(pieces) == 2 and pieces[1]:
            value = pieces[1]
    return value.strip(" ,，;；")


def _venue_from_value(value: str) -> str:
    value = _trim_address_prefix(value)
    if not value:
        return ""
    if VENUE_SENTENCE_RE.search(value):
        return ""
    if any(value.endswith(non_venue) for non_venue in NON_VENUE_NAMES):
        return ""
    if len(value) <= 70 and VENUE_SUFFIX_RE.search(value) and not re.search(r"(?:票务|抽奖|开售)", value):
        return value
    matches = list(VENUE_ANY_RE.finditer(value))
    if not matches:
        return ""
    candidate = matches[-1].group(1).strip()
    candidate = _trim_address_prefix(candidate)
    return candidate if 2 <= len(candidate) <= 70 and candidate not in NON_VENUE_NAMES else ""


def extract_livehouse(lines: Sequence[_Line]) -> str:
    for line in lines:
        label = VENUE_LABEL_RE.match(line.raw)
        if label:
            candidate = _venue_from_value(label.group(1))
            if candidate:
                return candidate
            literal = _trim_address_prefix(label.group(1))
            if _safe_venue_literal(literal):
                return literal

    for line in lines:
        if line.raw.lstrip().startswith(LOCATION_LINE_SYMBOLS):
            literal = _trim_address_prefix(line.raw)
            candidate = _venue_from_value(literal)
            if candidate:
                return candidate
            if _safe_venue_literal(literal):
                return literal

    for line in lines:
        if LOCATION_CONTEXT_RE.search(line.normalized) and re.search(r"[（(][^）)]+[）)]", line.raw):
            candidate = _venue_from_value(line.raw)
            if candidate:
                return candidate

    for line in lines:
        candidate = _venue_from_value(line.raw)
        if candidate and not LOCATION_CONTEXT_RE.search(candidate):
            return candidate
    return ""


def _safe_venue_literal(value: str) -> bool:
    value = value.strip()
    return (
        2 <= len(value) <= 70
        and not ADDRESS_MARKER_RE.search(value)
        and not VENUE_SENTENCE_RE.search(value)
        and not _looks_like_metadata(value)
        and not any(value.endswith(non_venue) for non_venue in NON_VENUE_NAMES)
        and not value.startswith(("http://", "https://"))
    )


def _domain_matches(hostname: str, domains: Iterable[str]) -> bool:
    hostname = hostname.lower().rstrip(".")
    return any(hostname == domain or hostname.endswith("." + domain) for domain in domains)


class _NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(
        self,
        req: urllib.request.Request,
        fp: Any,
        code: int,
        msg: str,
        headers: Any,
        newurl: str,
    ) -> urllib.request.Request | None:
        return None


def resolve_ticket_url(url: str, timeout: float = 10.0) -> str:
    try:
        parsed = urllib.parse.urlsplit(url)
        port = parsed.port
    except ValueError:
        return ""
    hostname = parsed.hostname or ""
    if parsed.scheme not in {"http", "https"} or parsed.username or parsed.password:
        return ""
    if _domain_matches(hostname, TICKET_PROVIDER_DOMAINS):
        return url
    if not _domain_matches(hostname, TRUSTED_SHORTENER_DOMAINS) or port is not None:
        return ""
    opener = urllib.request.build_opener(_NoRedirectHandler())
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with opener.open(request, timeout=timeout) as response:
            # Automatic redirects are disabled. A 200 response from a
            # shortener does not prove a ticket-provider destination.
            response.read(1)
            return ""
    except urllib.error.HTTPError as exc:
        if exc.code not in {301, 302, 303, 307, 308}:
            return ""
        location = exc.headers.get("Location")
        if not location:
            return ""
        final_url = urllib.parse.urljoin(url, location)
    except (OSError, urllib.error.URLError, ValueError):
        return ""
    try:
        final_parsed = urllib.parse.urlsplit(final_url)
        final_parsed.port
    except ValueError:
        return ""
    final_host = final_parsed.hostname or ""
    return (
        final_url
        if final_parsed.scheme in {"http", "https"}
        and not final_parsed.username
        and not final_parsed.password
        and _domain_matches(final_host, TICKET_PROVIDER_DOMAINS)
        else ""
    )


def extract_ticket_url(structured_urls: Sequence[str]) -> str:
    for value in structured_urls:
        ticket_url = resolve_ticket_url(value)
        if ticket_url:
            return ticket_url
    return ""


def _publish_year(created_at: str | None) -> int | None:
    if not created_at:
        return None
    try:
        parsed = email.utils.parsedate_to_datetime(created_at)
        return parsed.year
    except (TypeError, ValueError, OverflowError):
        match = re.search(r"\b(20\d{2})\b", created_at)
        return int(match.group(1)) if match else None


def _publish_date(created_at: str | None) -> dt.date | None:
    if not created_at:
        return None
    try:
        return email.utils.parsedate_to_datetime(created_at).date()
    except (TypeError, ValueError, OverflowError):
        return None


def extract_event_from_text(
    text: str,
    *,
    weibo_url: str,
    created_at: str | None = None,
    structured_urls: Sequence[str] = (),
) -> EventFields:
    lines = _content_lines(text)
    publish_date = _publish_date(created_at)
    return EventFields(
        name=extract_name(lines),
        date=extract_date(lines, _publish_year(created_at), publish_date),
        city=extract_city(lines),
        livehouse=extract_livehouse(lines),
        weiboURL=weibo_url,
        ticketURL=extract_ticket_url(structured_urls),
        note="",
    )


def _status_reference(url: str) -> tuple[str, str]:
    if re.search(r"[\x00-\x1f\x7f]", url) or "\\" in url:
        raise ValueError("expected a public weibo.com status URL")
    raw_match = re.fullmatch(
        r"https://(?:weibo\.com|www\.weibo\.com)/([^/?#]+)/([^/?#]+)",
        url,
        re.IGNORECASE | re.ASCII,
    )
    if not raw_match:
        raise ValueError("expected a public weibo.com status URL")
    raw_parts = raw_match.groups()
    try:
        if any(re.search(r"%(?![0-9A-Fa-f]{2})", part) for part in raw_parts):
            raise ValueError("invalid percent escape")
        parts = [
            urllib.parse.unquote_to_bytes(part).decode("utf-8", errors="strict")
            for part in raw_parts
        ]
    except (UnicodeError, ValueError) as exc:
        raise ValueError("expected valid UTF-8 URL path segments") from exc
    if (
        len(parts) != 2
        or not re.fullmatch(r"[A-Za-z0-9]+", parts[-1])
        or parts[0] in {".", ".."}
        or len(parts[0]) > 200
        or re.search(r"[\x00-\x1f\x7f/?#\\]", parts[0])
    ):
        raise ValueError("expected URL path /<user-id>/<status-id>")
    return parts[0], parts[1]


def _callback_json(body: str | bytes, callback: str) -> dict[str, Any]:
    if isinstance(body, bytes):
        body = body.decode("utf-8")
    match = re.search(re.escape(callback) + r"\((.*)\)\s*;?\s*$", body, re.DOTALL)
    if not match:
        raise WeiboFetchError("unexpected Weibo visitor response")
    payload = json.loads(match.group(1))
    if not isinstance(payload, dict):
        raise WeiboFetchError("invalid Weibo visitor response")
    return payload


class WeiboVisitorClient:
    """Anonymous public Weibo reader backed by an in-memory visitor session."""

    def __init__(self, timeout: float = 20.0) -> None:
        self.timeout = timeout
        self._cookies = http.cookiejar.CookieJar()
        self._opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self._cookies))
        self._bootstrapped = False

    def _request(self, url: str, referer: str = "https://weibo.com/") -> bytes:
        request = urllib.request.Request(
            url,
            headers={
                "User-Agent": USER_AGENT,
                "Accept": "application/json,text/plain,*/*",
                "Referer": referer,
            },
        )
        with self._opener.open(request, timeout=self.timeout) as response:
            return response.read()

    def _bootstrap(self) -> None:
        fingerprint = json.dumps(
            {
                "os": "1",
                "browser": "Chrome70,0,3538,102",
                "fonts": "undefined",
                "screenInfo": "1920*1080*24",
                "plugins": "",
            },
            separators=(",", ":"),
        )
        gen_url = "https://passport.weibo.com/visitor/genvisitor?" + urllib.parse.urlencode(
            {"cb": "gen_callback", "fp": fingerprint}
        )
        try:
            generated = _callback_json(self._request(gen_url), "gen_callback")
            if generated.get("retcode") != 20000000:
                raise WeiboFetchError("Weibo visitor identity was rejected")
            tid = generated.get("data", {}).get("tid")
            if not isinstance(tid, str) or not tid:
                raise WeiboFetchError("Weibo visitor identity was missing")
            incarnate_url = "https://passport.weibo.com/visitor/visitor?" + urllib.parse.urlencode(
                {
                    "a": "incarnate",
                    "t": tid,
                    "w": "2",
                    "c": "100",
                    "gc": "",
                    "cb": "cross_domain",
                    "from": "weibo",
                }
            )
            self._request(incarnate_url)
            self._bootstrapped = True
        except (OSError, urllib.error.URLError, urllib.error.HTTPError, json.JSONDecodeError) as exc:
            raise WeiboFetchError(f"unable to establish anonymous Weibo visitor session: {exc}") from exc

    def _json_request(self, url: str, referer: str) -> dict[str, Any]:
        try:
            payload = json.loads(self._request(url, referer).decode("utf-8"))
        except (OSError, urllib.error.URLError, urllib.error.HTTPError, UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise WeiboFetchError(f"unable to fetch public Weibo data: {exc}") from exc
        if not isinstance(payload, dict):
            raise WeiboFetchError("unexpected public Weibo response")
        return payload

    def fetch_status(self, weibo_url: str) -> tuple[str, str | None, list[str]]:
        _, reference = _status_reference(weibo_url)
        parsed_referer = urllib.parse.urlsplit(weibo_url)
        referer = urllib.parse.urlunsplit(
            (
                parsed_referer.scheme,
                parsed_referer.netloc,
                urllib.parse.quote(parsed_referer.path, safe="/%"),
                "",
                "",
            )
        )
        if not self._bootstrapped:
            self._bootstrap()
        query = urllib.parse.urlencode({"id": reference})
        status = self._json_request("https://weibo.com/ajax/statuses/show?" + query, referer)
        if status.get("ok") == 0 or status.get("error"):
            raise WeiboFetchError("public Weibo status is unavailable")

        text = status.get("text_raw") or status.get("text") or ""
        if status.get("isLongText"):
            long_text = status.get("longTextContent")
            if not long_text:
                long_id = status.get("mblogid") or status.get("id") or reference
                long_payload = self._json_request(
                    "https://weibo.com/ajax/statuses/longtext?" + urllib.parse.urlencode({"id": long_id}),
                    referer,
                )
                data = long_payload.get("data") if isinstance(long_payload.get("data"), dict) else long_payload
                long_text = data.get("longTextContent") if isinstance(data, dict) else None
            if isinstance(long_text, str) and long_text:
                text = long_text
        if not isinstance(text, str) or not text:
            raise WeiboFetchError("public Weibo status did not contain text")

        structured_urls: list[str] = []
        url_struct = status.get("url_struct")
        if isinstance(url_struct, list):
            for entry in url_struct:
                if not isinstance(entry, dict):
                    continue
                for key in ("long_url", "ori_url", "short_url"):
                    value = entry.get(key)
                    if isinstance(value, str) and value.startswith(("http://", "https://")):
                        structured_urls.append(value)
                        break
        created_at = status.get("created_at") if isinstance(status.get("created_at"), str) else None
        return text, created_at, structured_urls


def extract_event(weibo_url: str, client: WeiboVisitorClient | None = None) -> EventFields:
    client = client or WeiboVisitorClient()
    text, created_at, structured_urls = client.fetch_status(weibo_url)
    return extract_event_from_text(
        text,
        weibo_url=weibo_url,
        created_at=created_at,
        structured_urls=structured_urls,
    )


def _parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("urls", nargs="+", help="public weibo.com status URLs")
    parser.add_argument("--timeout", type=float, default=20.0, help="network timeout in seconds")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = _parse_args(argv or sys.argv[1:])
    client = WeiboVisitorClient(timeout=args.timeout)
    results: list[dict[str, str]] = []
    errors: list[dict[str, str]] = []
    for url in args.urls:
        try:
            results.append(extract_event(url, client).as_dict())
        except (ValueError, WeiboFetchError) as exc:
            errors.append({"weiboURL": url, "error": str(exc)})
    output: Any = results[0] if len(args.urls) == 1 and results else results
    print(json.dumps(output, ensure_ascii=False, indent=2))
    if errors:
        print(json.dumps({"errors": errors}, ensure_ascii=False, indent=2), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
