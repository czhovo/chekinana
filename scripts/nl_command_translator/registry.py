"""Command registry and strict canonical-command validation.

This module deliberately has no app/runtime dependency.  It validates syntax,
but never executes a Chekinana command.
"""

from __future__ import annotations

from dataclasses import dataclass
import re
from typing import Iterable


COMMAND_NAMES = (
    "help",
    "confirm",
    "cancel",
    "clear",
    "addidol",
    "listidol",
    "showidol",
    "editidol",
    "deleteidol",
    "scancheki",
    "discardcheki",
    "addcheki",
    "addscancheki",
    "listcheki",
    "downloadcheki",
    "deletecheki",
)

COMMAND_SCHEMAS = {
    "help": "help",
    "confirm": "confirm [8_hex_code]",
    "cancel": "cancel <8_hex_code|all>",
    "clear": "clear",
    "addidol": "addidol <idol_name>",
    "listidol": "listidol",
    "showidol": "showidol <idol_id|name>",
    "editidol": "editidol <candidate_code|idol_id> <field>=<value> [...]",
    "deleteidol": "deleteidol <idol_id>",
    "scancheki": "scancheki",
    "discardcheki": "discardcheki <temporary_cheki_id|all>",
    "addcheki": "addcheki <idol[,idol...]> [event=] [idx=] [user=] [size=] [note=]",
    "addscancheki": "addscancheki <temporary_id[,temporary_id...]|all> idol=<idol[,idol...]>",
    "listcheki": "listcheki [idol=] [event=]",
    "downloadcheki": "downloadcheki <cheki_id>",
    "deletecheki": "deletecheki <cheki_id>",
}

CODE_RE = re.compile(r"^[0-9a-fA-F]{8}$")
KEY_RE = re.compile(r"^[a-zA-Z_][a-zA-Z0-9_]*$")
UNSAFE_RE = re.compile(r"[\r\n;|&`<>]|\$\(")
UNREPRESENTABLE_SLOT_RE = re.compile(r'["\\\x00-\x1f\x7f]')


@dataclass(frozen=True)
class ValidationResult:
    valid: bool
    command: str | None = None
    intent: str | None = None
    message: str = ""


@dataclass(frozen=True)
class SwiftParsedCommand:
    name: str
    target: str | None
    arguments: dict[str, str]


def quote_value(value: str, *, positional: bool = False) -> str:
    """Quote one value in the subset accepted by the app command parser."""

    if not value:
        raise ValueError("参数不能为空")
    if UNSAFE_RE.search(value) or UNREPRESENTABLE_SLOT_RE.search(value):
        raise ValueError("参数包含 App parser 无法无损表示的字符")
    if positional and "=" in value:
        raise ValueError("位置参数不能包含 =")
    return f'"{value}"' if any(character.isspace() for character in value) else value


def swift_tokenize(raw: str) -> list[str]:
    """Mirror ChekinanaCommandParser.tokenize, with lossless quote guards."""

    if UNSAFE_RE.search(raw):
        raise ValueError("输入包含换行或命令控制字符")
    if "\\" in raw:
        raise ValueError("反斜杠无法由 App parser 无损处理")
    tokens: list[str] = []
    current: list[str] = []
    is_quoted = False
    just_closed_quote = False
    for character in raw:
        if character == '"':
            if not is_quoted:
                current_value = "".join(current)
                if current_value and not current_value.endswith("="):
                    raise ValueError("双引号只能包围完整参数值")
                if just_closed_quote:
                    raise ValueError("参数包含无法表示的双引号")
                is_quoted = True
            else:
                is_quoted = False
                just_closed_quote = True
            continue
        if character.isspace() and not is_quoted:
            if current:
                tokens.append("".join(current))
                current = []
            just_closed_quote = False
            continue
        if just_closed_quote and not character.isspace():
            raise ValueError("结束引号后必须是参数分隔空白")
        current.append(character)
    if is_quoted:
        raise ValueError("命令引号不完整")
    if current:
        tokens.append("".join(current))
    if not tokens:
        raise ValueError("输入为空")
    return tokens


def swift_parse(raw: str) -> SwiftParsedCommand:
    """Mirror the Swift parser's target/key split for contract tests."""

    tokens = swift_tokenize(raw)
    name = tokens[0].lower()
    target: str | None = None
    arguments: dict[str, str] = {}
    for token in tokens[1:]:
        if "=" in token:
            key, value = token.split("=", 1)
            key = key.lower()
            if not key:
                raise ValueError("字段名不能为空")
            if key in arguments:
                raise ValueError(f"字段重复：{key}")
            arguments[key] = value
        elif target is None:
            target = token
        else:
            raise ValueError(f"多余位置参数：{token}")
    return SwiftParsedCommand(name, target, arguments)


def _split_tokens(tokens: Iterable[str]) -> tuple[list[str], dict[str, str]]:
    positional: list[str] = []
    values: dict[str, str] = {}
    for token in tokens:
        if "=" not in token:
            positional.append(token)
            continue
        key, value = token.split("=", 1)
        key = key.lower()
        if not KEY_RE.fullmatch(key) or not value:
            raise ValueError("字段必须使用 field=value，且 value 不能为空")
        if key in values:
            raise ValueError(f"字段重复：{key}")
        values[key] = value
    return positional, values


def _canonical(name: str, positional: list[str], values: dict[str, str]) -> str:
    parts = [name]
    parts.extend(quote_value(item, positional=True) for item in positional)
    parts.extend(f"{key}={quote_value(value)}" for key, value in values.items())
    return " ".join(parts)


def validate_command(raw: str) -> ValidationResult:
    """Validate and canonicalize one command without executing it."""

    try:
        tokens = swift_tokenize(raw.strip())
        if len(tokens) == 1 and CODE_RE.fullmatch(tokens[0]):
            code = tokens[0].lower()
            return ValidationResult(True, f"confirm {code}", "confirm", "八位确认码已规范化")

        name = tokens[0].lower()
        if name not in COMMAND_NAMES:
            return ValidationResult(False, message=f"未注册命令：{name}")
        positional, values = _split_tokens(tokens[1:])

        if name in {"help", "clear", "listidol", "scancheki"}:
            if positional or values:
                raise ValueError(f"{name} 不接受参数")

        elif name == "confirm":
            if values or len(positional) > 1:
                raise ValueError("confirm 只接受一个可选的八位确认码")
            if positional and not CODE_RE.fullmatch(positional[0]):
                raise ValueError("确认码必须是八位十六进制字符")
            positional = [item.lower() for item in positional]

        elif name == "cancel":
            if values or len(positional) != 1:
                raise ValueError("cancel 需要八位确认码或 all")
            if positional[0].lower() == "all":
                positional = ["all"]
            elif CODE_RE.fullmatch(positional[0]):
                positional = [positional[0].lower()]
            else:
                raise ValueError("cancel 需要八位确认码或 all")

        elif name in {"addidol", "showidol", "deleteidol", "discardcheki", "downloadcheki", "deletecheki"}:
            if values or len(positional) != 1:
                raise ValueError(f"{name} 需要且只接受一个目标")
            if name == "discardcheki" and not positional[0].strip():
                raise ValueError("临时 Cheki ID 不能为空")

        elif name == "editidol":
            allowed = {"name", "group", "birthday", "color", "verification", "bio", "avatar", "avatar_url"}
            if len(positional) != 1 or not values:
                raise ValueError("editidol 需要目标和至少一个 field=value")
            unsupported = set(values) - allowed
            if unsupported:
                raise ValueError("editidol 不支持字段：" + ", ".join(sorted(unsupported)))

        elif name == "addcheki":
            allowed = {"idol", "idols", "event", "idx", "user", "userappears", "size", "note"}
            if len(positional) > 1 or set(values) - allowed:
                raise ValueError("addcheki 参数不符合注册表")
            if positional and ("idol" in values or "idols" in values):
                raise ValueError("Idol 不能同时使用位置参数和字段参数")
            if "idol" in values and "idols" in values:
                raise ValueError("idol/idols 不能重复")
            if not positional and not ({"idol", "idols"} & set(values)):
                raise ValueError("addcheki 缺少 Idol")
            if "idx" in values and values["idx"] not in {"?", "-"}:
                try:
                    int(values["idx"])
                except ValueError as exc:
                    raise ValueError("idx 必须是整数、? 或 -") from exc
            if "user" in values and values["user"].lower() not in {"true", "false", "?", "-"}:
                raise ValueError("user 必须是 true、false、? 或 -")
            if "userappears" in values and values["userappears"].lower() not in {"true", "false", "?", "-"}:
                raise ValueError("userAppears 必须是 true、false、? 或 -")
            if "size" in values and values["size"].lower() not in {"mini", "wide", "else", "?", "-"}:
                raise ValueError("size 必须是 mini、wide、else、? 或 -")

        elif name == "addscancheki":
            if len(positional) != 1 or set(values) - {"idol", "idols"}:
                raise ValueError("addscancheki 需要临时 Cheki 目标和 idol 字段")
            if "idol" in values and "idols" in values:
                raise ValueError("idol/idols 不能重复")
            if not ({"idol", "idols"} & set(values)):
                raise ValueError("addscancheki 缺少 Idol")

        elif name == "listcheki":
            if positional or set(values) - {"idol", "event"}:
                raise ValueError("listcheki 只接受 idol/event 字段")

        return ValidationResult(True, _canonical(name, positional, values), name, "命令有效")
    except ValueError as exc:
        return ValidationResult(False, message=str(exc))


def compact_schemas(candidates: Iterable[str] | None = None) -> dict[str, str]:
    names = list(candidates or COMMAND_NAMES)
    return {name: COMMAND_SCHEMAS[name] for name in names if name in COMMAND_SCHEMAS}
