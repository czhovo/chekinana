"""Bounded real-API fallback benchmark.

Synthetic phrases only.  The script never logs the API key and never executes
translated Chekinana commands.
"""

from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path

from .translator import DeepSeekClient, Translator


@dataclass(frozen=True)
class LiveCase:
    text: str
    expected_command: str | None
    expected_clarification: bool = False


CASES = (
    LiveCase("把爱豆花名册摊开给我看", "listidol"),
    LiveCase("上一笔可以落锤了", "confirm"),
    LiveCase("刚才那笔别算了", None, True),
    LiveCase("把新来的XX登记进爱豆册", "addidol XX"),
    LiveCase("让我看看Eriko的个人资料", "showidol Eriko"),
    LiveCase("把Eriko的应援色换成蓝色", "editidol Eriko color=蓝色"),
    LiveCase("相册里挑几张给Eriko做切己", "addcheki Eriko"),
    LiveCase("扫描留下的tmp1归到Eriko名下", "addscancheki tmp1 idol=Eriko"),
    LiveCase("看看Eriko拍过的切己", "listcheki idol=Eriko"),
    LiveCase("c001这张切己存进系统相册", "downloadcheki c001"),
    LiveCase("c001这张切己不要了", "deletecheki c001"),
    LiveCase("擦掉屏幕上的对话", "clear"),
)


def run() -> dict:
    client = DeepSeekClient(timeout=30.0)
    model_check = {"checked": True, "target": client.model, "available": False, "error": None}
    try:
        models = client.available_models()
        model_check["available"] = client.model in models
        model_check["returned_model_count"] = len(models)
    except RuntimeError as exc:
        model_check["error"] = str(exc)

    translator = Translator(llm_client=client, cache_size=32)
    results = []
    totals = {"calls": 0, "prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0, "api_responses": 0, "passed": 0}
    # Even if /models omits the target, make one bounded completion request to
    # distinguish a stale model list from a rejected model.  Do not spend on
    # another 11 known-invalid requests.
    cases = CASES if model_check["available"] or model_check["error"] else CASES[:1]
    for case in cases:
        offline = translator.translate(case.text, allow_llm=False)
        if offline.command is not None:
            results.append({
                "input": case.text,
                "expected": case.expected_command,
                "status": "invalid_fixture_rule_matched",
                "actual": offline.command,
            })
            continue
        result = translator.translate(case.text, allow_llm=True)
        totals["calls"] += 1
        if result.llm_usage:
            totals["api_responses"] += 1
        for key in ("prompt_tokens", "completion_tokens", "total_tokens"):
            totals[key] += int(result.llm_usage.get(key, 0))
        passed = result.command == case.expected_command and result.needs_clarification == case.expected_clarification
        totals["passed"] += int(passed)
        results.append({
            "input": case.text,
            "expected": case.expected_command,
            "expected_clarification": case.expected_clarification,
            "actual": result.command,
            "intent": result.intent,
            "source": result.source,
            "needs_clarification": result.needs_clarification,
            "message": result.message,
            "usage": result.llm_usage,
            "passed": passed,
        })
        if totals["calls"] == 1 and not result.llm_usage and not model_check["available"]:
            break
    totals["attempted_cases"] = len(results)
    totals["accuracy"] = totals["passed"] / totals["attempted_cases"] if totals["attempted_cases"] else 0.0
    return {
        "model_check": model_check,
        "response_model": client.last_response_model,
        "limits": {"max_cases": len(CASES), "max_tokens_per_call": 192, "calls_per_case": 1, "history": False, "thinking": "disabled"},
        "totals": totals,
        "results": results,
    }


def write_report(result: dict, output_dir: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "live-results.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    totals = result["totals"]
    check = result["model_check"]
    lines = [
        "# Bounded DeepSeek fallback benchmark",
        "",
        f"- Target model: `{check['target']}`",
        f"- `/models` target available: {check['available']}",
        f"- Response model: `{result['response_model'] or 'none'}`",
        f"- Calls: {totals['calls']}",
        f"- Structured API JSON responses with usage: {totals['api_responses']}",
        f"- Passed: {totals['passed']}/{totals['attempted_cases']}",
        f"- Prompt tokens: {totals['prompt_tokens']}",
        f"- Completion tokens: {totals['completion_tokens']}",
        f"- Total tokens: {totals['total_tokens']}",
        "- No generated command was executed.",
        "- No credential is included in this report.",
        "",
        "| Input | Expected | Actual | Source | Result |",
        "|---|---|---|---|---|",
    ]
    for item in result["results"]:
        safe_input = item["input"].replace("|", "\\|")
        lines.append(
            f"| {safe_input} | `{item.get('expected')}` | `{item.get('actual')}` | {item.get('source', item.get('status'))} | {'pass' if item.get('passed') else 'fail'} |"
        )
    if check.get("error"):
        lines.extend(["", f"Model discovery error: {check['error']}"])
    (output_dir / "live-report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    root = Path(__file__).resolve().parents[2]
    result = run()
    write_report(result, root / "outputs" / "nl-command-translator-20260711")
    totals = result["totals"]
    print(json.dumps({
        "target_model_available": result["model_check"]["available"],
        "response_model": result["response_model"],
        "calls": totals["calls"],
        "api_responses": totals["api_responses"],
        "passed": totals["passed"],
        "attempted_cases": totals["attempted_cases"],
        "total_tokens": totals["total_tokens"],
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
