import json
import os
import sys
import time
from pathlib import Path

import cv2
import numpy as np

APP_ROOT = Path(__file__).resolve().parents[1]
CHEKI_ROOT = APP_ROOT.parent / "cheki"
BACKEND = APP_ROOT / "backend"
OUT_ROOT = CHEKI_ROOT / "pipeline_test_outputs" / "local_backend"
INPUT = CHEKI_ROOT / "imgs" / "IMG_9227.jpg"

os.chdir(CHEKI_ROOT)
sys.path.insert(0, str(BACKEND))

import app as backend_app  # noqa: E402


def decode_png(data: bytes) -> np.ndarray:
    arr = np.frombuffer(data, dtype=np.uint8)
    bgr = cv2.imdecode(arr, cv2.IMREAD_COLOR)
    return cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)


def border_mean_rgb(image: np.ndarray) -> list[float]:
    h, w = image.shape[:2]
    mask = np.ones((h, w), dtype=np.uint8)
    cv2.fillPoly(mask, [backend_app.IMAGE_AREA_VERTICES], 0)
    pixels = image[mask.astype(bool)]
    return [round(float(v), 2) for v in pixels.mean(axis=0)]


def run_case(raw: bytes, wb_enabled: bool) -> dict:
    task_id = f"local_{'wb1' if wb_enabled else 'wb0'}_{int(time.time() * 1000)}"
    backend_app.task_store[task_id] = {
        "status": "processing",
        "phase": "manual",
        "filename": INPUT.name,
        "size": len(raw),
        "raw_data": raw,
        "created_at": time.time(),
        "ip": "127.0.0.1",
        "results": [],
        "white_balance": wb_enabled,
    }
    backend_app.do_process_extraction(raw, task_id)
    task = backend_app.task_store[task_id]

    case_dir = OUT_ROOT / ("wb_on" if wb_enabled else "wb_off")
    case_dir.mkdir(parents=True, exist_ok=True)
    summary = {
        "task_id": task_id,
        "status": task.get("status"),
        "total_polaroids": task.get("total_polaroids"),
        "results": [],
    }

    for result in task.get("results", []):
        path = case_dir / f"result_{result['id']}_{result['type']}.png"
        path.write_bytes(result["image_bytes"])
        item = {
            "id": result["id"],
            "type": result["type"],
            "label": result["label"],
            "file": str(path),
            "bytes": len(result["image_bytes"]),
        }
        if result["type"] == "polaroid":
            item["border_mean_rgb"] = border_mean_rgb(decode_png(result["image_bytes"]))
        summary["results"].append(item)

    task.pop("raw_data", None)
    return summary


def main():
    OUT_ROOT.mkdir(parents=True, exist_ok=True)
    raw = INPUT.read_bytes()

    started = time.time()
    summaries = [
        run_case(raw, wb_enabled=False),
        run_case(raw, wb_enabled=True),
    ]
    report = {
        "input": str(INPUT),
        "elapsed_seconds": round(time.time() - started, 2),
        "cases": summaries,
    }
    report_path = OUT_ROOT / "report.json"
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
