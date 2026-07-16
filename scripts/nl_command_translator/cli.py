"""CLI for translation only; it never executes Chekinana commands."""

from __future__ import annotations

import argparse
import json
import sys

from .translator import translate


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="将中文需求转换为 Chekinana 命令（不执行）")
    parser.add_argument("text", nargs="*", help="自然语言或已有命令；留空时从 stdin 读取")
    parser.add_argument("--allow-llm", action="store_true", help="规则无法确定时允许一次 DeepSeek fallback")
    parser.add_argument("--json", action="store_true", help="输出结构化 JSON")
    args = parser.parse_args(argv)
    raw = " ".join(args.text) if args.text else sys.stdin.read()
    result = translate(raw, allow_llm=args.allow_llm)
    if args.json:
        print(json.dumps(result.to_dict(), ensure_ascii=False, sort_keys=True))
    elif result.command:
        print(result.command)
    else:
        print(f"needs_clarification: {result.message}")
    return 2 if result.needs_clarification else 0


if __name__ == "__main__":
    raise SystemExit(main())
