from __future__ import annotations

import json
from pathlib import Path
import unittest
from unittest import mock
import urllib.error

from event_weibo_extractor import (
    EventFields,
    _callback_json,
    _status_reference,
    extract_event_from_text,
    extract_ticket_url,
    resolve_ticket_url,
)


URL = "https://weibo.com/1234567890/AbC123"
CREATED = "Mon Jul 13 20:00:00 +0800 2026"


class EventWeiboExtractorTests(unittest.TestCase):
    def extract(self, text: str, *, links: tuple[str, ...] = ()) -> EventFields:
        return extract_event_from_text(text, weibo_url=URL, created_at=CREATED, structured_urls=links)

    def test_explicit_name_and_year_date(self) -> None:
        event = self.extract("活动名称：星光公演\n演出日期：2026年7月18日")
        self.assertEqual(event.name, "星光公演")
        self.assertEqual(event.date, "2026-07-18")

    def test_non_date_corner_bracket_title(self) -> None:
        event = self.extract("【Nocturnal Icon-频道特别篇】\n演出日期：7月17日")
        self.assertEqual(event.name, "Nocturnal Icon-频道特别篇")

    def test_generic_corner_bracket_header_is_rejected(self) -> None:
        event = self.extract("【主催情报解禁】\nUnique Fes ～ Voyage\n０７／０４（土）")
        self.assertEqual(event.name, "Unique Fes ～ Voyage")
        self.assertEqual(event.date, "2026-07-04")

    def test_adjacent_event_prefix_and_theme_are_joined(self) -> None:
        event = self.extract("卷卷生诞祭\n『Rot-borne Wings』\n7月18日")
        self.assertEqual(event.name, "卷卷生诞祭『Rot-borne Wings』")

    def test_edge_emoji_are_name_decoration(self) -> None:
        event = self.extract("🦋卷卷生诞祭🦋\n🦋『Rot-borne Wings』🦋\n7月18日")
        self.assertEqual(event.name, "卷卷生诞祭『Rot-borne Wings』")

    def test_weibo_literal_line_continuation_is_not_name_content(self) -> None:
        event = self.extract("\\卷卷生诞祭\\\n\\『Rot-borne Wings』\\\n7月18日")
        self.assertEqual(event.name, "卷卷生诞祭『Rot-borne Wings』")

    def test_inline_event_prefix_and_theme_are_preserved(self) -> None:
        event = self.extract("空色轨迹! 定期公演『全力全開』\n6月16日")
        self.assertEqual(event.name, "空色轨迹! 定期公演『全力全開』")

    def test_bracket_title_appends_adjacent_birthday_title(self) -> None:
        event = self.extract("【TriMoment Fes Vol.5「安然入梦」】\n安悦Anna生诞祭\n8月9日")
        self.assertEqual(event.name, "TriMoment Fes Vol.5「安然入梦」 安悦Anna生诞祭")

    def test_standalone_event_title_appends_adjacent_birthday_title(self) -> None:
        event = self.extract("TriMoment Fes Vol.5「安然入梦」\n安悦Anna生诞祭\n8月9日")
        self.assertEqual(event.name, "TriMoment Fes Vol.5「安然入梦」 安悦Anna生诞祭")

    def test_generic_header_prefix_is_removed_before_adjacent_title_join(self) -> None:
        event = self.extract("【公演情报解禁】霓虹信号NeonEyEs\n一周年one man live\n7月24日")
        self.assertEqual(event.name, "霓虹信号NeonEyEs 一周年one man live")

    def test_date_prefix_is_removed_before_adjacent_title_join(self) -> None:
        event = self.extract("7月24日（Fri） 霓虹信号NeonEyEs\n一周年one man live")
        self.assertEqual(event.name, "霓虹信号NeonEyEs 一周年one man live")

    def test_standalone_live_title_is_recognized(self) -> None:
        event = self.extract("SMO Idol Live Vol.4\n8月2日")
        self.assertEqual(event.name, "SMO Idol Live Vol.4")

    def test_standalone_anniversary_one_man_title_is_recognized(self) -> None:
        event = self.extract("霓虹信号NeonEyEs 一周年one man live\n7月24日")
        self.assertEqual(event.name, "霓虹信号NeonEyEs 一周年one man live")

    def test_timetable_is_not_a_name(self) -> None:
        event = self.extract("【Timetable公布】\n演出日期：7月18日")
        self.assertEqual(event.name, "")

    def test_lottery_prize_line_is_not_a_name(self) -> None:
        event = self.extract("【演出情报】\n转抽成员合影一张+场限礼包×3\n8月19日")
        self.assertEqual(event.name, "")

    def test_bracketed_lottery_prize_is_not_a_name(self) -> None:
        event = self.extract("【转抽成员合影一张+场限礼包×3】\n8月19日")
        self.assertEqual(event.name, "")

    def test_admission_term_is_not_a_name(self) -> None:
        event = self.extract("【演出情报】\n免费入场\n8月19日")
        self.assertEqual(event.name, "")

    def test_generic_host_information_is_not_a_name(self) -> None:
        event = self.extract("【主催情报】\n8月9日")
        self.assertEqual(event.name, "")

    def test_sale_date_is_rejected_in_favor_of_event_date(self) -> None:
        event = self.extract("【主催情报解禁】\nUnique Fes\n０７／０４（土）\n7.1 18:30开售")
        self.assertEqual(event.date, "2026-07-04")

    def test_ambiguous_month_day_does_not_infer_year(self) -> None:
        event = self.extract("公演候选：7/4 或 7/5")
        self.assertEqual(event.date, "")

    def test_ambiguous_full_dates_are_left_empty(self) -> None:
        event = self.extract("公演日期：2026-07-04 或 2026-07-05")
        self.assertEqual(event.date, "")

    def test_currency_decimal_is_not_a_second_date(self) -> None:
        event = self.extract("6/16 19:00\n特价￥9.9")
        self.assertEqual(event.date, "2026-06-16")

    def test_invalid_date_is_ignored(self) -> None:
        event = self.extract("演出日期：2026-02-30")
        self.assertEqual(event.date, "")

    def test_month_day_rolls_into_next_year_near_year_end(self) -> None:
        event = extract_event_from_text(
            "活动日期：1月2日",
            weibo_url=URL,
            created_at="Sun Dec 28 12:00:00 +0800 2025",
        )
        self.assertEqual(event.date, "2026-01-02")

    def test_city_comes_from_address(self) -> None:
        event = self.extract("演出地址：湖南省长沙市雨花区某商场")
        self.assertEqual(event.city, "长沙")

    def test_city_can_come_from_explicit_label(self) -> None:
        event = self.extract("城市：上海")
        self.assertEqual(event.city, "上海")

    def test_bare_city_body_line_is_allowed(self) -> None:
        event = self.extract("上海\n7月17日")
        self.assertEqual(event.city, "上海")

    def test_no_city_without_body_evidence(self) -> None:
        event = self.extract("某某公演\n7月4日")
        self.assertEqual(event.city, "")

    def test_city_name_inside_unrelated_title_is_not_city(self) -> None:
        event = self.extract("上海滩之夜\n7月4日")
        self.assertEqual(event.city, "")

    def test_address_parenthetical_venue(self) -> None:
        event = self.extract("演出地址：上海市长宁区某路100号（育音堂小镇C厅）")
        self.assertEqual(event.livehouse, "育音堂小镇C厅")

    def test_address_tail_returns_venue_only(self) -> None:
        event = self.extract("地点：湖南省长沙市雨花区吉联MALL 1层MAO Livehouse")
        self.assertEqual(event.livehouse, "MAO Livehouse")

    def test_branch_suffix_is_preserved(self) -> None:
        event = self.extract("场地：MAO Livehouse（中大二号馆）")
        self.assertEqual(event.livehouse, "MAO Livehouse（中大二号馆）")

    def test_emoji_only_venue_line(self) -> None:
        event = self.extract("⚓️ 新歌空间")
        self.assertEqual(event.livehouse, "新歌空间")

    def test_location_pin_allows_venue_without_suffix(self) -> None:
        event = self.extract("📍瓦肆VAS ear NC")
        self.assertEqual(event.livehouse, "瓦肆VAS ear NC")

    def test_location_pin_strips_add_label(self) -> None:
        event = self.extract("📍ADD：瓦肆VAS ear NC")
        self.assertEqual(event.livehouse, "瓦肆VAS ear NC")

    def test_explicit_label_allows_venue_without_suffix(self) -> None:
        event = self.extract("地点：791Crow")
        self.assertEqual(event.livehouse, "791Crow")

    def test_plain_detailed_address_is_not_a_venue(self) -> None:
        event = self.extract("演出地址：北京市朝阳区幸福路100号")
        self.assertEqual(event.livehouse, "")

    def test_store_suffix_is_preserved(self) -> None:
        event = self.extract("演出场地：声音共和新城店")
        self.assertEqual(event.livehouse, "声音共和新城店")

    def test_common_restaurant_word_is_not_a_venue(self) -> None:
        event = self.extract("演出后大家一起去餐厅")
        self.assertEqual(event.livehouse, "")

    def test_ordinary_sentence_ending_in_store_is_not_a_venue(self) -> None:
        event = self.extract("演出后一起去火锅店")
        self.assertEqual(event.livehouse, "")

    def test_note_is_always_empty(self) -> None:
        event = self.extract("活动名称：测试活动\n任意正文")
        self.assertEqual(event.note, "")

    def test_plain_text_ticket_hint_is_not_a_url(self) -> None:
        event = self.extract("票务秀动，见评论区\n秀动🔍某活动")
        self.assertEqual(event.ticketURL, "")

    def test_ticket_provider_allowlist(self) -> None:
        self.assertEqual(resolve_ticket_url("https://wap.showstart.com/pages/activity/detail/1"), "https://wap.showstart.com/pages/activity/detail/1")
        self.assertEqual(resolve_ticket_url("https://example.com/lottery"), "")
        self.assertEqual(resolve_ticket_url("https://user@showstart.com/event/1"), "")

    @mock.patch("event_weibo_extractor.urllib.request.build_opener")
    def test_shortener_ticket_redirect_is_returned_without_following(self, build_opener: mock.Mock) -> None:
        opener = build_opener.return_value
        opener.open.side_effect = urllib.error.HTTPError(
            "https://t.cn/abc",
            302,
            "Found",
            {"Location": "https://wap.showstart.com/event/1"},
            None,
        )
        self.assertEqual(resolve_ticket_url("https://t.cn/abc"), "https://wap.showstart.com/event/1")
        opener.open.assert_called_once()

    @mock.patch("event_weibo_extractor.urllib.request.build_opener")
    def test_shortener_non_ticket_redirect_is_rejected_without_following(self, build_opener: mock.Mock) -> None:
        opener = build_opener.return_value
        opener.open.side_effect = urllib.error.HTTPError(
            "https://t.cn/abc",
            302,
            "Found",
            {"Location": "http://127.0.0.1/private"},
            None,
        )
        self.assertEqual(resolve_ticket_url("https://t.cn/abc"), "")
        opener.open.assert_called_once()

    @mock.patch("event_weibo_extractor.urllib.request.build_opener")
    def test_shortener_non_http_ticket_host_redirect_is_rejected(self, build_opener: mock.Mock) -> None:
        opener = build_opener.return_value
        opener.open.side_effect = urllib.error.HTTPError(
            "https://t.cn/abc",
            302,
            "Found",
            {"Location": "file://showstart.com/private"},
            None,
        )
        self.assertEqual(resolve_ticket_url("https://t.cn/abc"), "")
        opener.open.assert_called_once()

    @mock.patch("event_weibo_extractor.resolve_ticket_url")
    def test_structured_urls_are_checked_in_order(self, resolve: mock.Mock) -> None:
        resolve.side_effect = ["", "https://www.damai.cn/event/1"]
        value = extract_ticket_url(("https://t.cn/lottery", "https://www.damai.cn/event/1"))
        self.assertEqual(value, "https://www.damai.cn/event/1")

    def test_status_url_validation(self) -> None:
        self.assertEqual(_status_reference(URL), ("1234567890", "AbC123"))
        for invalid in (
            "https://example.com/123/AbC123",
            "http://weibo.com/123/AbC123",
            "https://user@weibo.com/123/AbC123",
            "https://weibo.com/extra/123/AbC123",
            "https://weibo.com/123/AbC123?from=feed",
            "https://weibo.com/123/AbC123?",
            "https://weibo.com/123/AbC123#detail",
            "https://weibo.com/123/AbC123#",
        ):
            with self.subTest(url=invalid), self.assertRaises(ValueError):
                _status_reference(invalid)

    def test_shared_url_contract_fixtures(self) -> None:
        fixtures_path = Path(__file__).with_name("url_contract_fixtures.json")
        fixtures = json.loads(fixtures_path.read_text(encoding="utf-8"))
        for fixture in fixtures:
            with self.subTest(fixture=fixture["id"]):
                if fixture["valid"]:
                    self.assertEqual(
                        _status_reference(fixture["url"]),
                        (fixture["user"], fixture["status"]),
                    )
                else:
                    with self.assertRaises(ValueError):
                        _status_reference(fixture["url"])

    def test_status_user_length_uses_unicode_code_points(self) -> None:
        self.assertEqual(
            _status_reference(f"https://weibo.com/{'😀' * 200}/AbC"),
            ("😀" * 200, "AbC"),
        )
        with self.assertRaises(ValueError):
            _status_reference(f"https://weibo.com/{'😀' * 201}/AbC")

    def test_visitor_callback_accepts_network_bytes(self) -> None:
        payload = _callback_json(b'gen_callback({"retcode":20000000,"data":{}})', "gen_callback")
        self.assertEqual(payload["retcode"], 20000000)

    def test_output_has_exact_contract_fields(self) -> None:
        event = self.extract("活动名称：测试")
        self.assertEqual(
            list(event.as_dict()),
            ["name", "date", "city", "livehouse", "weiboURL", "ticketURL", "note"],
        )

    def test_shared_parity_fixtures(self) -> None:
        fixtures_path = Path(__file__).with_name("parity_fixtures.json")
        fixtures = json.loads(fixtures_path.read_text(encoding="utf-8"))
        for fixture in fixtures:
            with self.subTest(fixture=fixture["id"]):
                event = extract_event_from_text(
                    fixture["text"],
                    weibo_url=fixture["weiboURL"],
                    created_at=fixture.get("createdAt"),
                    structured_urls=fixture.get("structuredURLs", []),
                )
                self.assertEqual(event.as_dict(), fixture["expected"])


if __name__ == "__main__":
    unittest.main()
