"""Six unique post-calibration live cases; total live budget stays at 18 calls."""

from __future__ import annotations

import json
from pathlib import Path

from .live_benchmark import LiveCase
from .translator import DeepSeekClient, Translator


CASES = (
    LiveCase("把偶像清单展示出来", "listidol"),
    LiveCase("就按刚才的操作执行", "confirm"),
    LiveCase("登记爱豆泡泡", "addidol 泡泡"),
    LiveCase("把Eriko的代表色改为蓝色", "editidol Eriko color=蓝色"),
    LiveCase("从手机相册选择照片为Eriko制作cheki", "addcheki Eriko"),
    LiveCase("把切己c002保存进相册", "downloadcheki c002"),
)


def main() -> int:
    root = Path(__file__).resolve().parents[2]
    output_dir = root / "outputs" / "nl-command-translator-20260711"
    client = DeepSeekClient(timeout=30.0)
    translator = Translator(llm_client=client, cache_size=16)
    totals = {"calls": 0, "api_responses": 0, "passed": 0, "prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}
    results = []
    for case in CASES:
        offline = translator.translate(case.text, allow_llm=False)
        if offline.command is not None:
            raise RuntimeError(f"follow-up fixture unexpectedly matched a local rule: {case.text}")
        result = translator.translate(case.text, allow_llm=True)
        totals["calls"] += 1
        totals["api_responses"] += int(bool(result.llm_usage))
        totals["passed"] += int(result.command == case.expected_command and not result.needs_clarification)
        for key in ("prompt_tokens", "completion_tokens", "total_tokens"):
            totals[key] += int(result.llm_usage.get(key, 0))
        results.append({
            "input": case.text,
            "expected": case.expected_command,
            "actual": result.command,
            "intent": result.intent,
            "source": result.source,
            "needs_clarification": result.needs_clarification,
            "message": result.message,
            "usage": result.llm_usage,
            "passed": result.command == case.expected_command and not result.needs_clarification,
        })
    followup = {"phase": "post-calibration", "response_model": client.last_response_model, "totals": totals, "results": results}
    (output_dir / "live-followup-results.json").write_text(json.dumps(followup, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    calibration = json.loads((output_dir / "live-results.json").read_text(encoding="utf-8"))
    before = calibration["totals"]
    combined = {
        "total_calls": before["calls"] + totals["calls"],
        "total_prompt_tokens": before["prompt_tokens"] + totals["prompt_tokens"],
        "total_completion_tokens": before["completion_tokens"] + totals["completion_tokens"],
        "total_tokens": before["total_tokens"] + totals["total_tokens"],
        "calibration_passed": before["passed"],
        "calibration_cases": before["attempted_cases"],
        "followup_passed": totals["passed"],
        "followup_cases": len(CASES),
        "target_model_available": calibration["model_check"]["available"],
        "response_model": client.last_response_model or calibration.get("response_model"),
    }
    (output_dir / "live-summary.json").write_text(json.dumps(combined, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    lines = [
        "# Live DeepSeek benchmark summary",
        "",
        f"- Model discovery: target available = {combined['target_model_available']}",
        f"- Response model: `{combined['response_model']}`",
        f"- Calibration: {combined['calibration_passed']}/{combined['calibration_cases']} exact/safe expected outputs",
        f"- Post-calibration unique validation: {combined['followup_passed']}/{combined['followup_cases']}",
        f"- Total model calls: {combined['total_calls']}",
        f"- Prompt/completion/total tokens: {combined['total_prompt_tokens']}/{combined['total_completion_tokens']}/{combined['total_tokens']}",
        "- Every translation used one model request at most, no history, max_tokens=192, and thinking disabled.",
        "- Failures became clarification or registry-valid but semantically incorrect commands; no command was executed.",
        "- No API credential or user data is present in the reports.",
        "",
        "The 12-case calibration exposed weak handling of optional arguments, value preservation, and album wording. The prompt was shortened and tightened around those points; the six follow-up inputs are new phrases, not retries.",
    ]
    (output_dir / "live-summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(json.dumps(combined, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
