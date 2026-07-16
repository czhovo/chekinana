from __future__ import annotations

import unittest

from nl_command_translator.benchmark import generate_cases, run
from nl_command_translator.registry import COMMAND_NAMES, quote_value, swift_parse, swift_tokenize, validate_command
from nl_command_translator.translator import DeepSeekClient, Translator


_MISSING = object()


class FakeClient:
    def __init__(self, value=_MISSING, error: Exception | None = None):
        self.value = {"command": "listidol", "intent": "listidol", "message": "ok"} if value is _MISSING else value
        self.error = error
        self.calls = 0
        self.last_candidates = None

    def translate(self, text, candidates):
        self.calls += 1
        self.last_candidates = candidates
        if self.error:
            raise self.error
        return self.value, {"prompt_tokens": 30, "completion_tokens": 8, "total_tokens": 38}


class StubDeepSeekClient(DeepSeekClient):
    def __init__(self, response):
        super().__init__(api_key="test-only-not-real")
        self.response = response

    def _request(self, url, payload=None):
        return self.response


class RegistryTests(unittest.TestCase):
    def test_registry_is_exactly_the_implemented_16_commands(self):
        self.assertEqual(
            COMMAND_NAMES,
            (
                "help", "confirm", "cancel", "clear", "addidol", "listidol", "showidol", "editidol",
                "deleteidol", "scancheki", "discardcheki", "addcheki", "addscancheki", "listcheki",
                "downloadcheki", "deletecheki",
            ),
        )

    def test_direct_code_becomes_confirm(self):
        result = validate_command("ABCD1234")
        self.assertTrue(result.valid)
        self.assertEqual(result.command, "confirm abcd1234")

    def test_injection_is_rejected(self):
        for value in ("addidol A; confirm", "listidol | help", "addidol $(id)", "help\nclear"):
            with self.subTest(value=value):
                self.assertFalse(validate_command(value).valid)

    def test_missing_required_values_are_rejected(self):
        for value in ("addidol", "deleteidol", "downloadcheki", "addcheki", "addscancheki temp", "editidol abc"):
            with self.subTest(value=value):
                self.assertFalse(validate_command(value).valid)

    def test_python_mirror_matches_swift_parser_contract(self):
        parsed = swift_parse('editidol idol-1 bio="A B" color=蓝色 note=A=B')
        self.assertEqual(parsed.name, "editidol")
        self.assertEqual(parsed.target, "idol-1")
        self.assertEqual(parsed.arguments, {"bio": "A B", "color": "蓝色", "note": "A=B"})
        self.assertEqual(swift_tokenize('addidol "Alice Trace"'), ["addidol", "Alice Trace"])

    def test_space_and_chinese_punctuation_round_trip_losslessly(self):
        for raw in ('addidol "Alice Trace"', "addidol 豹豹，seal", 'editidol idol-1 bio="舞台 担当"', "editidol idol-1 bio=纪念，日"):
            with self.subTest(raw=raw):
                checked = validate_command(raw)
                self.assertTrue(checked.valid, checked.message)
                before = swift_parse(raw)
                after = swift_parse(checked.command)
                self.assertEqual(before, after)

    def test_unrepresentable_slot_characters_are_rejected(self):
        for raw in ('addidol A"B"', r"addidol A\B", 'editidol idol-1 bio="A "B""'):
            with self.subTest(raw=raw):
                self.assertFalse(validate_command(raw).valid)
        for value in ('A "B"', r"A\B", "A\nB", "A\x00B"):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    quote_value(value, positional=True)


class OfflineBenchmarkTests(unittest.TestCase):
    def test_benchmark_is_large_and_all_cases_pass(self):
        cases = generate_cases()
        self.assertGreaterEqual(len(cases), 300)
        result = run(cases)
        self.assertEqual(result["failed"], 0, result["failures"][:3])
        self.assertEqual(result["clarification_safety"], 1.0)

    def test_fixture_inputs_are_unique_and_cover_all_commands(self):
        cases = generate_cases()
        self.assertEqual(len(cases), len({case.text for case in cases}))
        covered = {case.expected_command.split()[0] for case in cases if case.expected_command}
        self.assertEqual(covered, set(COMMAND_NAMES))


class IntentSafetyTests(unittest.TestCase):
    def test_independent_actions_with_broad_connectors_require_clarification(self):
        inputs = (
            "添加idol A，删除idol B",
            "添加idol A, 删除idol B",
            "添加idol A；删除idol B",
            "添加idol A、删除idol B",
            "添加idol A。删除idol B",
            "添加idol A. 删除idol B",
            "添加idol A然后删除idol B",
            "添加idol A同时删除idol B",
            "添加idol A以及删除idol B",
            "添加idol A还是删除idol B",
            "添加idol A再删除idol B",
            "添加idol A并删除idol B",
            "下载cheki c1并删除cheki c1",
            "下载并删除cheki c1",
            "下载cheki c1 or 删除cheki c1",
        )
        for text in inputs:
            with self.subTest(text=text):
                result = Translator().translate(text)
                self.assertIsNone(result.command)
                self.assertTrue(result.needs_clarification)
                self.assertIn("一次只能", result.message)

    def test_addscancheki_compound_is_one_action(self):
        for text in (
            "扫描临时cheki tmp1并添加给idol Eriko",
            "扫描临时cheki tmp1，添加给idol Eriko",
            "扫描临时cheki tmp1同时添加给idol Eriko",
            "扫描临时cheki tmp1然后添加给idol Eriko",
            "扫描临时cheki tmp1以及添加给idol Eriko",
        ):
            with self.subTest(text=text):
                result = Translator().translate(text)
                self.assertEqual(result.command, "addscancheki tmp1 idol=Eriko")
                self.assertFalse(result.needs_clarification)

    def test_scan_then_add_idol_is_two_actions_even_with_llm_enabled(self):
        inputs = (
            "扫描临时cheki tmp1，添加idol Eriko",
            "扫描临时cheki tmp1, 添加idol Eriko",
            "扫描临时cheki tmp1；然后添加一个idol Eriko",
            "扫描临时cheki tmp1。再添加idol Eriko",
            "扫描临时cheki tmp1然后添加一个idol Eriko",
            "扫描临时cheki tmp1同时添加idol Eriko",
        )
        for text in inputs:
            with self.subTest(text=text):
                client = FakeClient({"command": "scancheki", "intent": "scancheki", "message": "ok"})
                result = Translator(llm_client=client).translate(text, allow_llm=True)
                self.assertIsNone(result.command)
                self.assertTrue(result.needs_clarification)
                self.assertIn("一次只能", result.message)
                self.assertEqual(client.calls, 0)

    def test_objectless_action_pair_fuzz_stops_before_llm(self):
        pairs = (
            ("下载c1", "删除c1"),
            ("添加A", "删除A"),
            ("查看A", "删除A"),
            ("确认", "取消全部"),
        )
        connectors = ("并", "，", ",", "；", ";", "。", ".", "然后", "再", "同时", "以及", "还是")
        for left, right in pairs:
            for connector in connectors:
                text = f"{left}{connector}{right}"
                with self.subTest(text=text):
                    client = FakeClient({"command": "downloadcheki c1", "intent": "downloadcheki", "message": "ok"})
                    result = Translator(llm_client=client).translate(text, allow_llm=True)
                    self.assertIsNone(result.command)
                    self.assertTrue(result.needs_clarification)
                    self.assertIn("一次只能", result.message)
                    self.assertEqual(client.calls, 0)

    def test_objectless_action_words_inside_single_fixed_phrase_are_not_split(self):
        for text in ("查看删除记录", "确认取消操作", "保存到相册c1"):
            with self.subTest(text=text):
                self.assertNotIn("一次只能", Translator().translate(text).message)

    def test_explicit_scanned_cheki_to_idol_relations_stay_single_intent(self):
        inputs = (
            "把扫描的临时cheki tmp1添加给idol Eriko",
            "扫描临时cheki tmp1然后添加到idol Eriko",
            "扫描临时cheki tmp1同时绑定给idol Eriko",
            "扫描临时cheki tmp1，放到Eriko名下",
        )
        for text in inputs:
            with self.subTest(text=text):
                result = Translator().translate(text)
                self.assertEqual(result.command, "addscancheki tmp1 idol=Eriko")
                self.assertFalse(result.needs_clarification)

    def test_addscancheki_lists_do_not_turn_commas_into_action_separators(self):
        cases = {
            "扫描临时cheki tmp1,tmp2并添加给idol A,B": "addscancheki tmp1,tmp2 idol=A,B",
            "扫描临时cheki tmp1，tmp2并添加给idol A，B": "addscancheki tmp1,tmp2 idol=A,B",
            "扫描临时cheki tmp1、tmp2然后添加到idol A、B": "addscancheki tmp1,tmp2 idol=A,B",
        }
        for text, expected in cases.items():
            with self.subTest(text=text):
                result = Translator().translate(text)
                self.assertEqual(result.command, expected)
                self.assertFalse(result.needs_clarification)

    def test_natural_slots_with_quote_or_backslash_clarify(self):
        for text in ('添加一个名为A "B"的idol', r"添加idol A\B"):
            with self.subTest(text=text):
                result = Translator().translate(text)
                self.assertIsNone(result.command)
                self.assertTrue(result.needs_clarification)


class LLMFallbackTests(unittest.TestCase):
    def test_clear_rule_does_not_call_model(self):
        client = FakeClient()
        result = Translator(llm_client=client).translate("我想要添加一个名为XX的idol", allow_llm=True)
        self.assertEqual(result.command, "addidol XX")
        self.assertEqual(result.source, "rule")
        self.assertEqual(client.calls, 0)

    def test_low_confidence_uses_exactly_one_model_call(self):
        client = FakeClient()
        result = Translator(llm_client=client).translate("翻开我的收藏册", allow_llm=True)
        self.assertEqual(client.calls, 1)
        self.assertEqual(result.command, "listidol")
        self.assertEqual(result.source, "llm")
        self.assertEqual(result.llm_usage["total_tokens"], 38)

    def test_model_hallucinated_command_is_rejected(self):
        client = FakeClient({"command": "dropdatabase now", "intent": "dropdatabase", "message": "bad"})
        result = Translator(llm_client=client).translate("做个数据库维护", allow_llm=True)
        self.assertEqual(client.calls, 1)
        self.assertIsNone(result.command)
        self.assertTrue(result.needs_clarification)

    def test_model_injection_is_rejected(self):
        client = FakeClient({"command": "addidol A; confirm", "intent": "addidol", "message": "bad"})
        result = Translator(llm_client=client).translate("把某人收进册子", allow_llm=True)
        self.assertIsNone(result.command)
        self.assertTrue(result.needs_clarification)

    def test_model_translated_or_invented_value_is_rejected(self):
        client = FakeClient({"command": "editidol Eriko color=blue", "intent": "editidol", "message": "bad"})
        result = Translator(llm_client=client).translate("把Eriko的应援颜色调成蓝色", allow_llm=True)
        self.assertIsNone(result.command)
        self.assertTrue(result.needs_clarification)

    def test_model_cannot_select_a_lower_ranked_intent(self):
        client = FakeClient({"command": "deletecheki c1", "intent": "deletecheki", "message": "bad"})
        result = Translator(llm_client=client).translate("列出c1相关的切己收藏", allow_llm=True)
        self.assertIsNone(result.command)
        self.assertTrue(result.needs_clarification)

    def test_model_cannot_infer_sensitive_operation_without_local_signal(self):
        client = FakeClient({"command": "deleteidol Eriko", "intent": "deleteidol", "message": "已删除"})
        result = Translator(llm_client=client).translate("处理一下Eriko", allow_llm=True)
        self.assertIsNone(result.command)
        self.assertTrue(result.needs_clarification)
        self.assertNotIn("已删除", result.message)

    def test_model_cannot_issue_implicit_confirm(self):
        client = FakeClient({"command": "confirm", "intent": "confirm", "message": "已执行"})
        result = Translator(llm_client=client).translate("关于上一笔确认请处理一下", allow_llm=True)
        self.assertIsNone(result.command)
        self.assertTrue(result.needs_clarification)
        self.assertNotIn("已执行", result.message)

    def test_null_and_malformed_model_results_use_fixed_safe_message(self):
        malformed = (
            [],
            "not an object",
            None,
            {},
            {"command": [], "intent": "listidol", "message": "已执行"},
            {"command": "listidol", "intent": [], "message": "已执行"},
            {"command": "listidol", "intent": "listidol", "message": None},
            {"command": "", "intent": "listidol", "message": "已执行"},
            {"command": None, "intent": None, "message": "已删除"},
        )
        for value in malformed:
            with self.subTest(value=value):
                result = Translator(llm_client=FakeClient(value)).translate("翻开我的收藏册", allow_llm=True)
                self.assertIsNone(result.command)
                self.assertTrue(result.needs_clarification)
                self.assertEqual(result.message, "模型未能安全确定命令，请补充明确的操作、目标和必要编号")

    def test_malformed_api_json_never_escapes_public_translate(self):
        contents = ("[]", '"text"', "null", "{}", "", "{not-json", None)
        for content in contents:
            response = {
                "model": "deepseek-v4-pro",
                "choices": [{"message": {"content": content}}],
                "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
            }
            with self.subTest(content=content):
                result = Translator(llm_client=StubDeepSeekClient(response)).translate("翻开我的收藏册", allow_llm=True)
                self.assertIsNone(result.command)
                self.assertTrue(result.needs_clarification)
                self.assertEqual(result.message, "模型未能安全确定命令，请补充明确的操作、目标和必要编号")

    def test_untrusted_usage_never_escapes_or_accepts_model_command(self):
        valid_content = '{"command":"listidol","intent":"listidol","message":"ok"}'
        invalid_usages = (
            {"prompt_tokens": float("1e309"), "completion_tokens": 1, "total_tokens": 2},
            {"prompt_tokens": float("inf"), "completion_tokens": 1, "total_tokens": 2},
            {"prompt_tokens": float("nan"), "completion_tokens": 1, "total_tokens": 2},
            {"prompt_tokens": -1, "completion_tokens": 1, "total_tokens": 0},
            {"prompt_tokens": True, "completion_tokens": 1, "total_tokens": 2},
            {"prompt_tokens": "1", "completion_tokens": 1, "total_tokens": 2},
            {"prompt_tokens": 1_000_001, "completion_tokens": 1, "total_tokens": 1_000_002},
            {"completion_tokens": 1, "total_tokens": 1},
            {"prompt_tokens": 1, "completion_tokens": 1},
            {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 3},
            None,
        )
        for usage in invalid_usages:
            response = {
                "model": "deepseek-v4-pro",
                "choices": [{"message": {"content": valid_content}}],
            }
            if usage is not None:
                response["usage"] = usage
            with self.subTest(usage=usage):
                result = Translator(llm_client=StubDeepSeekClient(response)).translate("翻开我的收藏册", allow_llm=True)
                self.assertIsNone(result.command)
                self.assertTrue(result.needs_clarification)
                self.assertEqual(result.llm_usage, {})
                self.assertEqual(result.message, "模型未能安全确定命令，请补充明确的操作、目标和必要编号")

    def test_normal_integer_usage_is_accepted_without_coercion(self):
        response = {
            "model": "deepseek-v4-pro",
            "choices": [{"message": {"content": '{"command":"listidol","intent":"listidol","message":"ok"}'}}],
            "usage": {"prompt_tokens": 10, "completion_tokens": 2, "total_tokens": 12},
        }
        result = Translator(llm_client=StubDeepSeekClient(response)).translate("翻开我的收藏册", allow_llm=True)
        self.assertEqual(result.command, "listidol")
        self.assertFalse(result.needs_clarification)
        self.assertEqual(result.llm_usage, {"prompt_tokens": 10, "completion_tokens": 2, "total_tokens": 12})

    def test_network_failure_returns_clarification(self):
        client = FakeClient(error=RuntimeError("DeepSeek API 网络或响应错误"))
        result = Translator(llm_client=client).translate("翻开我的收藏册", allow_llm=True)
        self.assertEqual(client.calls, 1)
        self.assertIsNone(result.command)
        self.assertTrue(result.needs_clarification)
        self.assertEqual(result.message, "模型未能安全确定命令，请补充明确的操作、目标和必要编号")


if __name__ == "__main__":
    unittest.main()
