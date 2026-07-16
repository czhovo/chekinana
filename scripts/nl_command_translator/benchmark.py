"""Deterministic offline benchmark (no network, no command execution)."""

from __future__ import annotations

from collections import defaultdict
from dataclasses import asdict, dataclass
import json
from pathlib import Path
from typing import Iterable

from .registry import quote_value
from .translator import Translator


@dataclass(frozen=True)
class BenchmarkCase:
    category: str
    text: str
    expected_command: str | None
    expected_clarification: bool = False


NAMES = ("Eriko", "星野爱", "豹豹seal", "Alice Trace", "偶像-07", "小雨")
IDS = ("a1b2c3d4", "deadbeef", "1234abcd", "cafe2026")
CHEKI_IDS = ("c001", "cheki-77", "8F3A", "photo_2026")
TEMP_IDS = ("tmp001", "scan-77", "a9f2", "临时01")


def _case(category: str, text: str, command: str | None, clarify: bool = False) -> BenchmarkCase:
    return BenchmarkCase(category, text, command, clarify)


def _passthrough_cases() -> list[BenchmarkCase]:
    cases = [
        _case("passthrough", "help", "help"),
        _case("passthrough", "clear", "clear"),
        _case("passthrough", "confirm", "confirm"),
        _case("passthrough", "cancel all", "cancel all"),
        _case("passthrough", "listidol", "listidol"),
        _case("passthrough", "scancheki", "scancheki"),
        _case("passthrough", "listcheki", "listcheki"),
    ]
    for code in IDS:
        cases.extend(
            [
                _case("passthrough", code.upper(), f"confirm {code}"),
                _case("passthrough", f"confirm {code.upper()}", f"confirm {code}"),
                _case("passthrough", f"cancel {code.upper()}", f"cancel {code}"),
            ]
        )
    for name in NAMES:
        q = quote_value(name)
        cases.extend(
            [
                _case("passthrough", f"addidol {q}", f"addidol {q}"),
                _case("passthrough", f"showidol {q}", f"showidol {q}"),
                _case("passthrough", f"deleteidol {q}", f"deleteidol {q}"),
                _case("passthrough", f"addcheki {q}", f"addcheki {q}"),
                _case("passthrough", f"listcheki idol={q}", f"listcheki idol={q}"),
            ]
        )
    for target in CHEKI_IDS:
        cases.extend(
            [
                _case("passthrough", f"downloadcheki {target}", f"downloadcheki {target}"),
                _case("passthrough", f"deletecheki {target}", f"deletecheki {target}"),
            ]
        )
    for target in TEMP_IDS:
        q = quote_value(target)
        cases.extend(
            [
                _case("passthrough", f"discardcheki {q}", f"discardcheki {q}"),
                _case("passthrough", f"addscancheki {q} idol=Eriko", f"addscancheki {q} idol=Eriko"),
            ]
        )
    cases.extend(
        [
            _case("passthrough", "discardcheki all", "discardcheki all"),
            _case("passthrough", 'editidol idol-1 color=蓝色 bio="舞台 担当"', 'editidol idol-1 color=蓝色 bio="舞台 担当"'),
            _case("passthrough", 'addcheki Eriko event=ev1 idx=2 user=true size=wide note="hello world"', 'addcheki Eriko event=ev1 idx=2 user=true size=wide note="hello world"'),
            _case("passthrough", "listcheki event=?", "listcheki event=?"),
        ]
    )
    return cases


def _rule_cases() -> list[BenchmarkCase]:
    cases: list[BenchmarkCase] = []
    for phrase in ("帮助", "显示帮助", "打开帮助", "使用说明", "命令说明", "有哪些命令", "都有哪些命令", "怎么用", "如何使用"):
        cases.append(_case("rule_help", phrase, "help"))
    for phrase in ("确认", "确认上一步", "确认上一条", "确认刚才的操作", "执行刚才的操作", "同意刚才的操作"):
        cases.append(_case("rule_confirm", phrase, "confirm"))
    for code in IDS:
        cases.extend(
            [
                _case("rule_confirm", f"确认 {code}", f"confirm {code}"),
                _case("rule_confirm", f"执行确认码{code.upper()}", f"confirm {code}"),
                _case("rule_cancel", f"取消确认码 {code}", f"cancel {code}"),
                _case("rule_cancel", f"撤销操作 {code.upper()}", f"cancel {code}"),
            ]
        )
    for phrase in ("取消全部", "取消所有操作", "撤销全部待确认操作", "撤销所有待确认操作"):
        cases.append(_case("rule_cancel", phrase, "cancel all"))
    for phrase in ("清屏", "清空屏幕", "清空界面", "清空输出", "清空聊天", "清空聊天记录", "清除屏幕", "清除显示记录"):
        cases.append(_case("rule_clear", phrase, "clear"))

    for name in NAMES:
        q = quote_value(name)
        for template in (
            "添加一个名为{}的idol",
            "新增一位叫{}的偶像",
            "加入idol {}",
            "录入爱豆 {}",
            "把{}加入我的名册",
        ):
            cases.append(_case("rule_addidol", template.format(name), f"addidol {q}"))
        for template in ("查看idol {}", "显示{}这位偶像的资料", "{} idol详情", "查一下idol {}"):
            cases.append(_case("rule_showidol", template.format(name), f"showidol {q}"))
        for template in ("删除idol {}", "移除{}这位偶像", "把{}这个idol删除掉"):
            cases.append(_case("rule_deleteidol", template.format(name), f"deleteidol {q}"))
    for phrase in ("列出idol", "列出所有idol", "显示我的偶像列表", "查看已添加的爱豆", "打开idol名册", "查看所有偶像清单"):
        cases.append(_case("rule_listidol", phrase, "listidol"))

    fields = (("颜色", "color", "蓝色"), ("生日", "birthday", "7月11日"), ("团体", "group", "New Group"), ("简介", "bio", "主唱担当"), ("认证", "verification", "官方成员"), ("头像", "avatar", "https://example.com/a.jpg"))
    for name in NAMES[:4]:
        for label, field, value in fields:
            cases.append(
                _case(
                    "rule_editidol",
                    f"把{name}的{label}改成{value}",
                    f"editidol {quote_value(name)} {field}={quote_value(value)}",
                )
            )

    for phrase in ("扫描", "扫描选中的照片", "扫描已选照片", "创建临时cheki", "创建扫描临时cheki", "把选中照片变成临时cheki", "识别选中的照片"):
        cases.append(_case("rule_scancheki", phrase, "scancheki"))
    for target in TEMP_IDS:
        q = quote_value(target)
        for template in ("丢弃临时cheki {}", "删除扫描得到的cheki {}", "清除{}这个临时cheki"):
            cases.append(_case("rule_discardcheki", template.format(target), f"discardcheki {q}"))
    for word in ("全部", "所有", "全都"):
        cases.append(_case("rule_discardcheki", f"丢弃临时cheki {word}", "discardcheki all"))

    for temp in TEMP_IDS:
        for name in NAMES[:4]:
            cases.append(
                _case(
                    "rule_addscancheki",
                    f"把临时cheki {temp}添加给idol {name}",
                    f"addscancheki {quote_value(temp)} idol={quote_value(name)}",
                )
            )
    for name in NAMES[:4]:
        cases.append(_case("rule_addscancheki", f"把扫描得到的临时cheki 全部添加给{name}", f"addscancheki all idol={quote_value(name)}"))

    for name in NAMES:
        q = quote_value(name)
        for template in ("从相册给{}添加cheki", "为{}从相册创建cheki", "添加相册cheki给{}"):
            cases.append(_case("rule_addcheki", template.format(name), f"addcheki {q}"))
        cases.append(_case("rule_addcheki", f"从相册给{name}添加cheki note=纪念", f"addcheki {q} note=纪念"))
        cases.append(_case("rule_listcheki", f"查看{name}的cheki", f"listcheki idol={q}"))
        cases.append(_case("rule_listcheki", f"列出idol {name}的所有cheki", f"listcheki idol={q}"))
    for phrase in ("列出cheki", "列出所有cheki", "显示我的cheki列表", "查看已添加的切己", "打开cheki清单"):
        cases.append(_case("rule_listcheki", phrase, "listcheki"))
    for target in CHEKI_IDS:
        q = quote_value(target)
        for template in ("下载cheki {}", "保存到相册cheki {}", "存到相册cheki {}"):
            cases.append(_case("rule_downloadcheki", template.format(target), f"downloadcheki {q}"))
        for template in ("删除cheki {}", "移除切己 {}", "把{}这个cheki删除掉"):
            cases.append(_case("rule_deletecheki", template.format(target), f"deletecheki {q}"))
    return cases


def _safety_cases() -> list[BenchmarkCase]:
    missing = (
        "添加idol",
        "查看idol",
        "删除idol",
        "修改idol",
        "下载cheki",
        "删除cheki",
        "丢弃临时cheki",
        "从相册添加cheki",
        "把临时cheki添加给idol",
        "取消",
    )
    cases = [_case("missing_parameter", text, None, True) for text in missing]
    cases.extend(
        _case("multi_intent", text, None, True)
        for text in (
            "添加idol A，然后删除idol B",
            "列出idol并且删除idol A",
            "确认上一步；然后清屏",
            "扫描照片同时添加idol A",
            "下载cheki c1，接着删除cheki c1",
            "查看idol A然后修改idol A",
            "清屏再帮我确认",
            "取消全部随后列出cheki",
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
            "扫描临时cheki tmp1，添加idol Eriko",
            "扫描临时cheki tmp1, 添加idol Eriko",
            "扫描临时cheki tmp1；然后添加一个idol Eriko",
            "扫描临时cheki tmp1。再添加idol Eriko",
            "扫描临时cheki tmp1然后添加一个idol Eriko",
            "扫描临时cheki tmp1同时添加idol Eriko",
        )
    )
    cases.extend(
        _case("injection", text, None, True)
        for text in (
            "addidol A; deleteidol B",
            "addidol A | confirm",
            "addidol A && confirm",
            "addidol `whoami`",
            "addidol $(whoami)",
            "addidol A\nconfirm",
            "listidol > out.txt",
            "deletecheki abc < input",
        )
    )
    cases.extend(
        _case("unknown", text, None, True)
        for text in (
            "今天天气怎么样",
            "给我讲一个故事",
            "播放音乐",
            "打开地图",
            "帮我订餐",
            "把界面变成红色",
            "同步云端数据库",
            "导出所有数据为CSV",
            "创建一个活动",
            "登录账号",
            "这是谁",
            "你好",
        )
    )
    cases.extend(
        _case("invalid_passthrough", text, None, True)
        for text in (
            "confirm xyz",
            "cancel",
            "clear now",
            "scancheki abc",
            "addidol",
            "editidol abc",
            "addcheki",
            "addscancheki temp",
            "listcheki bad=x",
            "deleteidol a b",
        )
    )
    cases.extend(
        _case("parser_unrepresentable", text, None, True)
        for text in (
            '添加一个名为A "B"的idol',
            r"添加idol A\B",
        )
    )
    cases.extend(
        (
            _case("single_compound_intent", "扫描临时cheki tmp1并添加给idol Eriko", "addscancheki tmp1 idol=Eriko"),
            _case("single_compound_intent", "扫描临时cheki tmp1，添加给idol Eriko", "addscancheki tmp1 idol=Eriko"),
            _case("single_compound_intent", "扫描临时cheki tmp1同时添加给idol Eriko", "addscancheki tmp1 idol=Eriko"),
            _case("single_compound_intent", "扫描临时cheki tmp1然后添加给idol Eriko", "addscancheki tmp1 idol=Eriko"),
            _case("single_compound_intent", "扫描临时cheki tmp1以及添加给idol Eriko", "addscancheki tmp1 idol=Eriko"),
            _case("single_compound_intent", "把扫描的临时cheki tmp1添加给idol Eriko", "addscancheki tmp1 idol=Eriko"),
            _case("single_compound_intent", "扫描临时cheki tmp1然后添加到idol Eriko", "addscancheki tmp1 idol=Eriko"),
            _case("single_compound_intent", "扫描临时cheki tmp1同时绑定给idol Eriko", "addscancheki tmp1 idol=Eriko"),
            _case("single_compound_intent", "扫描临时cheki tmp1，放到Eriko名下", "addscancheki tmp1 idol=Eriko"),
            _case("single_compound_intent", "扫描临时cheki tmp1,tmp2并添加给idol A,B", "addscancheki tmp1,tmp2 idol=A,B"),
            _case("single_compound_intent", "扫描临时cheki tmp1，tmp2并添加给idol A，B", "addscancheki tmp1,tmp2 idol=A,B"),
            _case("single_compound_intent", "扫描临时cheki tmp1、tmp2然后添加到idol A、B", "addscancheki tmp1,tmp2 idol=A,B"),
        )
    )
    objectless_pairs = (
        ("下载c1", "删除c1"),
        ("添加A", "删除A"),
        ("查看A", "删除A"),
        ("确认", "取消全部"),
    )
    objectless_connectors = ("并", "，", ",", "；", ";", "。", ".", "然后", "再", "同时", "以及", "还是")
    cases.extend(
        _case("objectless_multi_intent", f"{left}{connector}{right}", None, True)
        for left, right in objectless_pairs
        for connector in objectless_connectors
    )
    return cases


def _live_regression_cases() -> list[BenchmarkCase]:
    """Promote bounded-live discoveries into zero-cost deterministic coverage."""

    values = (
        ("把爱豆花名册摊开给我看", "listidol", False),
        ("上一笔可以落锤了", "confirm", False),
        ("刚才那笔别算了", None, True),
        ("把新来的XX登记进爱豆册", "addidol XX", False),
        ("让我看看Eriko的个人资料", "showidol Eriko", False),
        ("把Eriko的应援色换成蓝色", "editidol Eriko color=蓝色", False),
        ("相册里挑几张给Eriko做切己", "addcheki Eriko", False),
        ("扫描留下的tmp1归到Eriko名下", "addscancheki tmp1 idol=Eriko", False),
        ("看看Eriko拍过的切己", "listcheki idol=Eriko", False),
        ("c001这张切己存进系统相册", "downloadcheki c001", False),
        ("c001这张切己不要了", "deletecheki c001", False),
        ("擦掉屏幕上的对话", "clear", False),
        ("把偶像清单展示出来", "listidol", False),
        ("就按刚才的操作执行", "confirm", False),
        ("登记爱豆泡泡", "addidol 泡泡", False),
        ("把Eriko的代表色改为蓝色", "editidol Eriko color=蓝色", False),
        ("从手机相册选择照片为Eriko制作cheki", "addcheki Eriko", False),
        ("把切己c002保存进相册", "downloadcheki c002", False),
    )
    return [_case("live_regression", text, command, clarify) for text, command, clarify in values]


def generate_cases() -> list[BenchmarkCase]:
    return _passthrough_cases() + _rule_cases() + _safety_cases() + _live_regression_cases()


def run(cases: Iterable[BenchmarkCase] | None = None) -> dict:
    translator = Translator()
    actual_cases = list(cases or generate_cases())
    categories: dict[str, dict[str, int]] = defaultdict(lambda: {"total": 0, "passed": 0, "failed": 0})
    failures = []
    for case in actual_cases:
        result = translator.translate(case.text, allow_llm=False)
        passed = result.command == case.expected_command and result.needs_clarification == case.expected_clarification
        metric = categories[case.category]
        metric["total"] += 1
        metric["passed" if passed else "failed"] += 1
        if not passed:
            failures.append(
                {
                    "category": case.category,
                    "input": case.text,
                    "expected_command": case.expected_command,
                    "expected_clarification": case.expected_clarification,
                    "actual": result.to_dict(),
                }
            )
    passed_count = len(actual_cases) - len(failures)
    clarification_cases = [case for case in actual_cases if case.expected_clarification]
    clarification_safe = sum(
        1
        for case in clarification_cases
        if translator.translate(case.text, allow_llm=False).needs_clarification
        and translator.translate(case.text, allow_llm=False).command is None
    )
    return {
        "total": len(actual_cases),
        "passed": passed_count,
        "failed": len(failures),
        "accuracy": passed_count / len(actual_cases) if actual_cases else 0.0,
        "clarification_total": len(clarification_cases),
        "clarification_safe": clarification_safe,
        "clarification_safety": clarification_safe / len(clarification_cases) if clarification_cases else 1.0,
        "categories": dict(sorted(categories.items())),
        "failures": failures,
    }


def write_report(result: dict, output_dir: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "offline-results.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    lines = [
        "# Offline natural-language command benchmark",
        "",
        f"- Total: {result['total']}",
        f"- Passed: {result['passed']}",
        f"- Accuracy: {result['accuracy']:.2%}",
        f"- Clarification safety: {result['clarification_safe']}/{result['clarification_total']} ({result['clarification_safety']:.2%})",
        "",
        "| Category | Passed | Total | Accuracy |",
        "|---|---:|---:|---:|",
    ]
    for name, metric in result["categories"].items():
        accuracy = metric["passed"] / metric["total"] if metric["total"] else 1.0
        lines.append(f"| {name} | {metric['passed']} | {metric['total']} | {accuracy:.2%} |")
    if result["failures"]:
        lines.extend(["", "## Failures", ""])
        for failure in result["failures"]:
            lines.append(f"- `{failure['category']}`: {failure['input']!r}")
    (output_dir / "offline-report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    root = Path(__file__).resolve().parents[2]
    result = run()
    write_report(result, root / "outputs" / "nl-command-translator-20260711")
    print(json.dumps({key: result[key] for key in ("total", "passed", "failed", "accuracy", "clarification_safety")}, ensure_ascii=False))
    return 1 if result["failed"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
