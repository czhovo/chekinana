"""Single-shot callback from the GPU backend to the Scanner Worker."""

from __future__ import annotations

import json
import os
import re
from datetime import date
from urllib.parse import urlsplit, urlunsplit
from urllib.request import Request, urlopen


CALLBACK_BASE_ENV = "CHEKINANA_DATE_CALLBACK_BASE_URL"
CALLBACK_TOKEN_ENV = "CHEKINANA_DATE_CALLBACK_TOKEN"
PRODUCTION_CALLBACK_BASE = "https://api.chekinana.top"
CALLBACK_PATH = "/api/internal/scanner/date-annotations"
MAX_RESULTS = 64
MAX_RESPONSE_BYTES = 64 * 1024
DEFAULT_TIMEOUT_SECONDS = 480.0
TASK_ID_PATTERN = re.compile(r"^[a-f0-9]{32}$")
TOKEN_PATTERN = re.compile(r"^[A-Za-z0-9._~-]{16,256}$")


class DateAnnotationUnavailable(RuntimeError):
    """Fixed, non-sensitive callback failure."""


def _failure():
    return DateAnnotationUnavailable("date_annotation_unavailable")


def _callback_url() -> str:
    raw = os.environ.get(
        CALLBACK_BASE_ENV,
        PRODUCTION_CALLBACK_BASE,
    ).strip()
    try:
        parsed = urlsplit(raw)
        if (
            parsed.username
            or parsed.password
            or parsed.query
            or parsed.fragment
            or parsed.path not in ("", "/")
        ):
            raise ValueError
        is_production = (
            parsed.scheme == "https"
            and parsed.hostname == "api.chekinana.top"
            and parsed.port is None
        )
        is_local = (
            parsed.scheme == "http"
            and parsed.hostname == "127.0.0.1"
            and parsed.port is not None
            and 1 <= parsed.port <= 65_535
        )
        if not (is_production or is_local):
            raise ValueError
        return urlunsplit((
            parsed.scheme,
            parsed.netloc,
            CALLBACK_PATH,
            "",
            "",
        ))
    except (TypeError, ValueError):
        raise _failure() from None


def _callback_token(access_token: str) -> str:
    token = os.environ.get(CALLBACK_TOKEN_ENV, "").strip() or access_token
    if not TOKEN_PATTERN.fullmatch(token or ""):
        raise _failure()
    return token


def _normalized_date(value) -> bool:
    if not isinstance(value, str):
        return False
    full = re.fullmatch(r"(\d{4})\.(\d{2})\.(\d{2})", value)
    month_day = re.fullmatch(r"(\d{2})\.(\d{2})", value)
    try:
        if full:
            date(*(int(part) for part in full.groups()))
            return True
        if month_day:
            month, day = (int(part) for part in month_day.groups())
            date(2000, month, day)
            return True
    except ValueError:
        return False
    return False


def _validate_annotation(value) -> dict:
    if (
        not isinstance(value, dict)
        or set(value) != {"id", "date", "bbox"}
        or isinstance(value["id"], bool)
        or not isinstance(value["id"], int)
        or value["id"] < 0
    ):
        raise _failure()
    annotation_date = value["date"]
    bbox = value["bbox"]
    if annotation_date is None and bbox is None:
        return {"id": value["id"], "date": None, "bbox": None}
    if not _normalized_date(annotation_date):
        raise _failure()
    if (
        not isinstance(bbox, list)
        or len(bbox) != 4
        or any(
            isinstance(coordinate, bool)
            or not isinstance(coordinate, int)
            for coordinate in bbox
        )
    ):
        raise _failure()
    x1, y1, x2, y2 = bbox
    if not (0 <= x1 < x2 and 0 <= y1 < y2):
        raise _failure()
    return {
        "id": value["id"],
        "date": annotation_date,
        "bbox": list(bbox),
    }


def request_task_date_annotations(
    task_id: str,
    recognition_results: list[dict],
    access_token: str,
    *,
    timeout: float = DEFAULT_TIMEOUT_SECONDS,
    urlopen_impl=urlopen,
) -> list[dict]:
    if (
        not TASK_ID_PATTERN.fullmatch(task_id or "")
        or not 1 <= len(recognition_results) <= MAX_RESULTS
    ):
        raise _failure()

    request_results = []
    logical_ids = set()
    artifact_ids = set()
    for result in recognition_results:
        logical_id = result.get("id")
        artifact_id = (
            result.get("ink_result_id")
            if result.get("ink_result_id") is not None
            else result.get("polaroid_result_id")
        )
        if (
            isinstance(logical_id, bool)
            or not isinstance(logical_id, int)
            or logical_id < 0
            or isinstance(artifact_id, bool)
            or not isinstance(artifact_id, int)
            or artifact_id < 0
            or logical_id in logical_ids
            or artifact_id in artifact_ids
        ):
            raise _failure()
        logical_ids.add(logical_id)
        artifact_ids.add(artifact_id)
        request_results.append({
            "id": logical_id,
            "artifact_id": artifact_id,
        })

    body = json.dumps(
        {"task_id": task_id, "results": request_results},
        separators=(",", ":"),
    ).encode("utf-8")
    callback_request = Request(
        _callback_url(),
        data=body,
        method="POST",
        headers={
            "content-type": "application/json",
            "x-cheki-token": _callback_token(access_token),
        },
    )
    try:
        with urlopen_impl(callback_request, timeout=timeout) as response:
            if response.status != 200:
                raise _failure()
            response_bytes = response.read(MAX_RESPONSE_BYTES + 1)
    except DateAnnotationUnavailable:
        raise
    except Exception:
        raise _failure() from None
    if len(response_bytes) > MAX_RESPONSE_BYTES:
        raise _failure()
    try:
        payload = json.loads(response_bytes.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise _failure() from None
    if (
        not isinstance(payload, dict)
        or set(payload) != {"status", "results"}
        or payload["status"] != "done"
        or not isinstance(payload["results"], list)
        or len(payload["results"]) != len(request_results)
    ):
        raise _failure()
    annotations = [_validate_annotation(item) for item in payload["results"]]
    if {item["id"] for item in annotations} != logical_ids:
        raise _failure()
    by_id = {item["id"]: item for item in annotations}
    return [by_id[item["id"]] for item in request_results]
