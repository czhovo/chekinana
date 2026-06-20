import io
import sys
import time
import types
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
BACKEND = ROOT / "backend"
sys.path.insert(0, str(BACKEND))

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")

if "torch" not in sys.modules:
    class FakeNoGrad:
        def __enter__(self):
            return None

        def __exit__(self, *_args):
            return False

    sys.modules["torch"] = types.SimpleNamespace(
        no_grad=lambda: FakeNoGrad(),
        cuda=types.SimpleNamespace(is_available=lambda: False, empty_cache=lambda: None),
    )

sys.modules.setdefault("flask_cors", types.SimpleNamespace(CORS=lambda *_args, **_kwargs: None))
sys.modules.setdefault("scipy", types.ModuleType("scipy"))
sys.modules.setdefault(
    "scipy.spatial",
    types.SimpleNamespace(ConvexHull=lambda *_args, **_kwargs: None),
)

import app as backend_app  # noqa: E402


def make_png(width=48, height=48, color=(220, 220, 220)) -> bytes:
    image = Image.new("RGB", (width, height), color)
    buf = io.BytesIO()
    image.save(buf, format="PNG")
    return buf.getvalue()


def post_process(client, upload_attempt_id="large-route-fresh"):
    return client.post(
        "/api/process",
        headers={"X-Cheki-Token": backend_app.ACCESS_TOKEN},
        data={
            "image": (io.BytesIO(make_png()), "fresh.png"),
            "upload_attempt_id": upload_attempt_id,
        },
        content_type="multipart/form-data",
    )


def main():
    client = backend_app.app.test_client()
    headers = {"X-Cheki-Token": backend_app.ACCESS_TOKEN}
    task_id = "large-result-route-smoke"
    now = time.time()
    results = []
    for idx in range(60):
        results.append({
            "id": idx,
            "type": "polaroid",
            "label": f"polaroid #{idx + 1}",
            "image_bytes": make_png(color=((idx * 3) % 255, 220, 220)),
            "mimetype": "image/png",
        })

    backend_app.task_store[task_id] = {
        "status": "processing",
        "phase": "extracting",
        "filename": "large.png",
        "created_at": now,
        "started_at": now,
        "results": results,
        "expected_polaroids": 60,
        "total_polaroids": 60,
        "requested_polaroids": 60,
        "detected_polaroids": 60,
        "warning": "",
        "extraction_complete": False,
    }

    status = client.get(f"/api/status/{task_id}", headers=headers)
    assert status.status_code == 200, status.get_data(as_text=True)
    status_json = status.get_json()
    assert status_json["results_count"] == 60
    assert len(status_json["results"]) == 60
    assert status_json["results"][0]["id"] == 0
    assert status_json["results"][39]["id"] == 39
    assert status_json["results"][40]["id"] == 40
    assert status_json["results"][59]["id"] == 59

    for result_id in (0, 39, 40, 59):
        response = client.get(f"/api/result/{task_id}/{result_id}", headers=headers)
        assert response.status_code == 200, (result_id, response.status_code)
        assert response.mimetype == "image/png"
        assert len(response.data) > 0

    fresh = post_process(client)
    assert fresh.status_code == 200, fresh.get_data(as_text=True)
    fresh_json = fresh.get_json()
    assert fresh_json["status"] == "queued"
    assert fresh_json["task_id"] in backend_app.task_store
    assert fresh_json["task_id"] in backend_app.task_queue

    print("large result route checks passed")
    print("status_results_count", status_json["results_count"])
    print("downloaded_result_ids", [0, 39, 40, 59])
    print("fresh_upload", fresh.status_code, fresh_json["status"])


if __name__ == "__main__":
    main()
