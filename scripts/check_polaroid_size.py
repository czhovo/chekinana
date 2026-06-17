import io
import sys
import time
import types
from pathlib import Path

import numpy as np
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


MINI_VERTS = np.array([[0, 0], [100, 0], [100, 200], [0, 200]], dtype=np.float32)
WIDE_VERTS = np.array([[0, 0], [220, 0], [220, 100], [0, 100]], dtype=np.float32)


class FakeInputs(dict):
    def to(self, _device):
        return self


class FakeMask:
    def cpu(self):
        return self

    def numpy(self):
        return np.ones((4, 4), dtype=np.uint8)


class FakeProcessor:
    def __call__(self, **_kwargs):
        return FakeInputs()

    def post_process_instance_segmentation(self, *_args, **_kwargs):
        return [{"masks": [FakeMask()]}]


class FakeModel:
    def __call__(self, **_kwargs):
        return object()


def make_png(width=320, height=240) -> bytes:
    image = Image.new("RGB", (width, height), (220, 220, 220))
    buf = io.BytesIO()
    image.save(buf, format="PNG")
    return buf.getvalue()


def decode_result_size(task_id: str) -> tuple[int, int]:
    result = backend_app.task_store[task_id]["results"][0]
    return Image.open(io.BytesIO(result["image_bytes"])).size


def run_extraction_case(polaroid_size: str, vertices: np.ndarray) -> tuple[int, int]:
    raw = make_png()
    task_id = f"size_check_{polaroid_size}_{int(time.time() * 1000)}"
    backend_app.task_store[task_id] = {
        "status": "processing",
        "phase": "manual",
        "filename": "check.png",
        "size": len(raw),
        "raw_data": raw,
        "created_at": time.time(),
        "ip": "127.0.0.1",
        "results": [],
        "white_balance": False,
        "denoise": False,
        "requested_polaroids": 1,
        "polaroid_size": polaroid_size,
    }
    original_get_sam3 = backend_app.get_sam3
    original_build_candidates = backend_app.build_detection_candidates
    backend_app.get_sam3 = lambda: (FakeModel(), FakeProcessor(), "cpu")
    backend_app.build_detection_candidates = lambda _masks: [{"vertices": vertices, "area": 1.0}]
    try:
        backend_app.do_process_extraction(raw, task_id)
    finally:
        backend_app.get_sam3 = original_get_sam3
        backend_app.build_detection_candidates = original_build_candidates
    return decode_result_size(task_id)


def post_process(polaroid_size=None):
    image = (io.BytesIO(make_png()), "check.png")
    data = {"image": image, "token": backend_app.ACCESS_TOKEN}
    if polaroid_size is not None:
        data["polaroid_size"] = polaroid_size
    return backend_app.app.test_client().post(
        "/api/process",
        data=data,
        content_type="multipart/form-data",
    )


def main():
    assert backend_app.parse_polaroid_size(None) == backend_app.POLAROID_SIZE_MINI
    assert backend_app.parse_polaroid_size("bad") == backend_app.POLAROID_SIZE_MINI
    assert backend_app.parse_polaroid_size("wide") == backend_app.POLAROID_SIZE_WIDE

    mini_geometry = backend_app.get_polaroid_geometry(backend_app.POLAROID_SIZE_MINI)
    wide_geometry = backend_app.get_polaroid_geometry(backend_app.POLAROID_SIZE_WIDE)
    assert (mini_geometry["width"], mini_geometry["height"]) == (1600, 2544)
    assert mini_geometry["image_area_vertices"].tolist() == [[110, 200], [1490, 200], [1490, 2044], [110, 2044]]
    assert (wide_geometry["width"], wide_geometry["height"]) == (3200, 2544)
    assert wide_geometry["image_area_vertices"].tolist() == [[110, 200], [3090, 200], [3090, 2044], [110, 2044]]

    assert backend_app.resolve_polaroid_size("mini", WIDE_VERTS) == "mini"
    assert backend_app.resolve_polaroid_size("wide", MINI_VERTS) == "wide"
    assert backend_app.resolve_polaroid_size("auto", MINI_VERTS) == "mini"
    assert backend_app.resolve_polaroid_size("auto", WIDE_VERTS) == "wide"

    assert run_extraction_case("mini", WIDE_VERTS) == (1600, 2544)
    assert run_extraction_case("wide", MINI_VERTS) == (3200, 2544)
    assert run_extraction_case("auto", MINI_VERTS) == (1600, 2544)
    assert run_extraction_case("auto", WIDE_VERTS) == (3200, 2544)

    default_response = post_process()
    assert default_response.status_code == 200, default_response.get_data(as_text=True)
    default_task_id = default_response.get_json()["task_id"]
    assert backend_app.task_store[default_task_id]["polaroid_size"] == "mini"

    invalid_response = post_process("invalid")
    assert invalid_response.status_code == 200, invalid_response.get_data(as_text=True)
    invalid_task_id = invalid_response.get_json()["task_id"]
    assert backend_app.task_store[invalid_task_id]["polaroid_size"] == "mini"

    print("polaroid size checks passed")


if __name__ == "__main__":
    main()
