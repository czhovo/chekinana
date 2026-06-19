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


def make_png(width=64, height=64) -> bytes:
    image = Image.new("RGB", (width, height), (220, 220, 220))
    buf = io.BytesIO()
    image.save(buf, format="PNG")
    return buf.getvalue()


def post_process(client, **fields):
    data = {"image": (io.BytesIO(make_png()), "postprocess.png")}
    data.update(fields)
    return client.post(
        "/api/process",
        headers={"X-Cheki-Token": backend_app.ACCESS_TOKEN},
        data=data,
        content_type="multipart/form-data",
    )


def make_noisy_rgb() -> np.ndarray:
    rng = np.random.default_rng(7)
    base = np.zeros((64, 64, 3), dtype=np.uint8)
    base[:, :, 0] = np.linspace(40, 220, 64, dtype=np.uint8)
    base[:, :, 1] = 130
    base[:, :, 2] = np.linspace(220, 40, 64, dtype=np.uint8)[:, None]
    noise = rng.normal(0, 6, base.shape).astype(np.int16)
    return np.clip(base.astype(np.int16) + noise, 0, 255).astype(np.uint8)


def check_parsing():
    assert backend_app.parse_postprocess_mode(None, True) == "denoise"
    assert backend_app.parse_postprocess_mode(None, False) == "off"
    assert backend_app.parse_postprocess_mode("off", True) == "off"
    assert backend_app.parse_postprocess_mode("denoise", False) == "denoise"
    assert backend_app.parse_postprocess_mode("sharpen", False) == "sharpen"
    assert backend_app.parse_postprocess_mode("bad", False) == "denoise"


def check_white_balance():
    image = np.full((64, 64, 3), [210, 200, 190], dtype=np.uint8)
    image[16:48, 16:48] = [70, 80, 90]
    geometry = {
        "image_area_vertices": np.array([[16, 16], [48, 16], [48, 48], [16, 48]], dtype=np.int32),
        "scale": 0.125,
    }
    balanced, info = backend_app.apply_fixed_border_white_balance(image, geometry)
    assert info["applied"] is True
    assert info["color_space"] == "linear_rgb"
    assert balanced.dtype == np.uint8
    assert balanced.shape == image.shape
    assert np.mean(balanced[0:8, 0:8]) > np.mean(image[0:8, 0:8])


def check_postprocessing_steps():
    image = make_noisy_rgb()
    off, off_info = backend_app.apply_postprocess_mode(image.copy(), "off")
    assert np.array_equal(off, image)
    assert off_info["mode"] == "off"

    denoised, denoise_info = backend_app.apply_postprocess_mode(image.copy(), "denoise")
    assert denoise_info["mode"] == "denoise"
    assert denoise_info["steps"][0]["method"] == "lab_fastNlMeansDenoising"
    assert denoise_info["steps"][0]["l_h"] == 3.5
    assert denoise_info["steps"][0]["ab_h"] == 6.0
    assert denoised.shape == image.shape

    sharpened, sharpen_info = backend_app.apply_postprocess_mode(image.copy(), "sharpen")
    assert sharpen_info["mode"] == "sharpen"
    assert [step["name"] for step in sharpen_info["steps"]] == ["denoise", "sharpen"]
    assert sharpen_info["steps"][1]["method"] == "lab_l_channel_usm"
    assert sharpen_info["steps"][1]["sigma"] == 1.0
    assert sharpen_info["steps"][1]["amount"] == 0.45
    assert sharpen_info["steps"][1]["threshold"] == 3.0
    assert sharpened.shape == image.shape


def check_api_contract():
    client = backend_app.app.test_client()

    unauthorized = client.post("/api/process")
    assert unauthorized.status_code == 401

    default_response = post_process(client)
    assert default_response.status_code == 200, default_response.get_data(as_text=True)
    default_json = default_response.get_json()
    assert default_json["postprocess_mode"] == "denoise"
    assert default_json["denoise"] is True
    assert default_json["white_balance_color_space"] == "linear_rgb"

    off_response = post_process(client, denoise="0")
    assert off_response.status_code == 200, off_response.get_data(as_text=True)
    off_json = off_response.get_json()
    assert off_json["postprocess_mode"] == "off"
    assert off_json["denoise"] is False

    invalid_response = post_process(client, postprocess_mode="bad", denoise="0")
    assert invalid_response.status_code == 200, invalid_response.get_data(as_text=True)
    invalid_json = invalid_response.get_json()
    assert invalid_json["postprocess_mode"] == "denoise"
    assert invalid_json["denoise"] is True

    sharpen_response = post_process(client, postprocess_mode="sharpen", wb="0")
    assert sharpen_response.status_code == 200, sharpen_response.get_data(as_text=True)
    sharpen_json = sharpen_response.get_json()
    assert sharpen_json["postprocess_mode"] == "sharpen"
    assert sharpen_json["denoise"] is True
    assert sharpen_json["white_balance_color_space"] == ""

    status_response = client.get(
        f"/api/status/{sharpen_json['task_id']}",
        headers={"X-Cheki-Token": backend_app.ACCESS_TOKEN},
    )
    assert status_response.status_code == 200
    status_json = status_response.get_json()
    assert status_json["postprocess_mode"] == "sharpen"
    assert status_json["white_balance"] is False
    assert status_json["white_balance_color_space"] == ""


def main():
    started = time.time()
    check_parsing()
    check_white_balance()
    check_postprocessing_steps()
    check_api_contract()
    print(f"postprocessing mode checks passed in {time.time() - started:.2f}s")


if __name__ == "__main__":
    main()
