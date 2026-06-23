"""
图片处理服务 — 拍立得提取版
- SAM3 检测拍立得纸框 → 四边形拟合 → 透视矫正
- 分步处理，每步结果即时推送到前端
"""

import io, os, time, json, uuid, hashlib, threading, sys, gc, secrets, hmac, socket, traceback, smtplib
from datetime import datetime
from collections import defaultdict
from email.message import EmailMessage

import numpy as np
import torch
import cv2
from PIL import Image, ImageOps
from flask import Flask, request, send_file, jsonify
from flask_cors import CORS
from scipy.spatial import ConvexHull

# ===================================================================
# 配置加载
# ===================================================================
CONFIG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.json")
with open(CONFIG_PATH, "r", encoding="utf-8") as f:
    CONFIG = json.load(f)

ALLOWED_IPS = CONFIG.get("allowed_ips", ["127.0.0.1"])
MAX_IMAGE_BYTES = CONFIG.get("max_image_mb", 10) * 1024 * 1024
MAX_DIMENSIONS = CONFIG.get("max_dimensions", 4096)
MAX_IMAGE_PIXELS = MAX_DIMENSIONS * MAX_DIMENSIONS
RATE_LIMIT = CONFIG.get("rate_limit_per_minute", 10)
TASK_TTL = CONFIG.get("task_result_ttl_seconds", 600)
MAX_CONTACT_MESSAGE_CHARS = 1000
MAX_CONTACT_INFO_CHARS = 200
RUNPOD_POD_ID = os.environ.get("RUNPOD_POD_ID", "").strip()
ACCESS_TOKEN = os.environ.get("CHEKINANA_ACCESS_TOKEN") or RUNPOD_POD_ID or secrets.token_urlsafe(24)
if os.environ.get("CHEKINANA_ACCESS_TOKEN"):
    ACCESS_TOKEN_SOURCE = "env"
elif RUNPOD_POD_ID:
    ACCESS_TOKEN_SOURCE = "runpod_pod_id"
else:
    ACCESS_TOKEN_SOURCE = "generated"
CONTACT_EMAIL_TO = os.environ.get("CONTACT_EMAIL_TO", "").strip()

Image.MAX_IMAGE_PIXELS = MAX_IMAGE_PIXELS

# ===================================================================
# SAM3 模型（懒加载）
# ===================================================================
_sam3_model = None
_sam3_processor = None
_device = None
MODEL_LOAD_LOCK = threading.Lock()

def get_sam3():
    global _sam3_model, _sam3_processor, _device
    if _sam3_model is not None and _sam3_processor is not None:
        return _sam3_model, _sam3_processor, _device

    with MODEL_LOAD_LOCK:
        if _sam3_model is not None and _sam3_processor is not None:
            return _sam3_model, _sam3_processor, _device

        print("📦 正在加载 SAM3 模型（首次较慢）...", flush=True)
        try:
            from transformers import Sam3Model, Sam3Processor
            from modelscope import snapshot_download

            model_dir = snapshot_download('facebook/sam3', cache_dir='./sam3_model')
            model_dir_local = "./sam3_model/facebook/sam3"
            device = "cuda" if torch.cuda.is_available() else "cpu"

            model = Sam3Model.from_pretrained(model_dir_local).to(device)
            processor = Sam3Processor.from_pretrained(model_dir_local)

            _sam3_model = model
            _sam3_processor = processor
            _device = device
        except Exception:
            _sam3_model = None
            _sam3_processor = None
            _device = None
            raise

        print(f"✅ SAM3 就绪 (设备: {_device})", flush=True)
        return _sam3_model, _sam3_processor, _device

def preload_sam3_after_listen(port: int):
    connect_host = "127.0.0.1"
    while True:
        try:
            with socket.create_connection((connect_host, port), timeout=1):
                break
        except OSError:
            time.sleep(0.5)

    print("📦 端口已监听，开始预加载 SAM3 模型...", flush=True)
    try:
        get_sam3()
    except Exception as e:
        print(f"💥 SAM3 预加载失败: {type(e).__name__}: {e}", flush=True)
        traceback.print_exc()

# ===================================================================
# 四边形拟合工具
# ===================================================================
def points_inside_quad(points, quad):
    pts, q = np.asarray(points, dtype=np.float64), np.asarray(quad, dtype=np.float64)
    signed = sum(q[i,0]*q[(i+1)%4,1] - q[(i+1)%4,0]*q[i,1] for i in range(4))
    is_cw = signed > 0
    inside = np.ones(len(pts), dtype=bool)
    for i in range(4):
        p1, p2 = q[i], q[(i+1)%4]
        dx, dy = p2[0]-p1[0], p2[1]-p1[1]
        cross = dx*(pts[:,1]-p1[1]) - dy*(pts[:,0]-p1[0])
        inside &= (cross >= 0) if is_cw else (cross <= 0)
    return inside

def shrink_quad(vertices, factor=0.03):
    c = np.asarray(vertices, dtype=np.float64).mean(axis=0)
    return np.asarray(vertices) + factor * (c - vertices)

def fit_quadrilateral(points):
    from quadrilateral_fitter import QuadrilateralFitter
    hull = ConvexHull(points)
    hull_pts = points[hull.vertices]
    p1 = hull_pts[np.argmin(hull_pts[:,0])]
    p2 = hull_pts[np.argmax(np.sum((hull_pts-p1)**2, axis=1))]
    v = p2 - p1
    norm = np.linalg.norm(v)
    if norm < 1: return np.array([p1]*4)
    signed = (v[0]*(hull_pts[:,1]-p1[1]) - v[1]*(hull_pts[:,0]-p1[0])) / norm
    approx = np.array([p1, p2, hull_pts[np.argmax(signed)], hull_pts[np.argmin(signed)]])
    angles = np.arctan2(approx[:,1]-approx.mean(0)[1], approx[:,0]-approx.mean(0)[0])
    approx = approx[np.argsort(angles)]
    shrunk = shrink_quad(approx, 0.03)
    inside = points_inside_quad(points, shrunk)
    exterior = points[~inside]
    if len(exterior) < 4:
        return approx
    fitter = QuadrilateralFitter(polygon=exterior)
    vertices = np.array(fitter.fit(), dtype=np.float64)
    angles = np.arctan2(vertices[:,1]-vertices.mean(0)[1], vertices[:,0]-vertices.mean(0)[0])
    return vertices[np.argsort(angles)]

# ===================================================================
# IP / 速率限制
# ===================================================================
def is_ip_allowed(ip: str) -> bool:
    import ipaddress
    try:
        client = ipaddress.ip_address(ip)
        for entry in ALLOWED_IPS:
            if "/" in entry:
                if client in ipaddress.ip_network(entry, strict=False): return True
            elif client == ipaddress.ip_address(entry): return True
        return False
    except ValueError:
        return False

def get_client_ip() -> str:
    for h in ["CF-Connecting-IP", "X-Real-IP"]:
        v = request.headers.get(h, "")
        if v: return v.strip()
    ff = request.headers.get("X-Forwarded-For", "")
    if ff: return ff.split(",")[0].strip()
    return request.remote_addr or "127.0.0.1"

rate_store: dict[str, list[float]] = defaultdict(list)
rate_lock = threading.Lock()

def check_rate_limit(ip: str) -> bool:
    now = time.time()
    with rate_lock:
        rate_store[ip] = [t for t in rate_store[ip] if now - t < 60]
        if len(rate_store[ip]) >= RATE_LIMIT: return False
        rate_store[ip].append(now)
        return True

def get_request_token() -> str:
    token = request.headers.get("X-Cheki-Token", "").strip()
    if token:
        return token
    token = request.args.get("token", "").strip()
    if token:
        return token
    if request.is_json:
        data = request.get_json(silent=True) or {}
        token = str(data.get("token", "")).strip()
        if token:
            return token
    return request.form.get("token", "").strip()

def is_token_valid(token: str) -> bool:
    return bool(token) and hmac.compare_digest(token, ACCESS_TOKEN)


def send_contact_email(message_text: str, contact_info: str, client_ip: str) -> tuple[bool, str]:
    smtp_host = os.environ.get("SMTP_HOST", "smtp.gmail.com").strip()
    try:
        smtp_port = int(os.environ.get("SMTP_PORT", "587"))
    except ValueError:
        return False, "邮件端口配置错误"
    smtp_username = os.environ.get("SMTP_USERNAME", "").strip()
    smtp_password = os.environ.get("SMTP_PASSWORD", "").strip()
    smtp_from = os.environ.get("SMTP_FROM", smtp_username).strip()

    if not CONTACT_EMAIL_TO:
        return False, "联系邮箱未配置"
    if not smtp_username or not smtp_password or not smtp_from:
        return False, "邮件服务未配置"

    msg = EmailMessage()
    msg["Subject"] = "Chekinana 联系作者"
    msg["From"] = smtp_from
    msg["To"] = CONTACT_EMAIL_TO
    contact_line = f"Contact: {contact_info}\n" if contact_info else ""
    msg.set_content(
        "用户在 Chekinana 小程序提交了联系内容。\n\n"
        f"IP: {client_ip}\n"
        f"Time: {datetime.now().isoformat()}\n"
        f"{contact_line}\n"
        f"{message_text}"
    )

    try:
        with smtplib.SMTP(smtp_host, smtp_port, timeout=15) as server:
            server.starttls()
            server.login(smtp_username, smtp_password)
            server.send_message(msg)
        print(
            f"[contact] email sent time={datetime.now().isoformat()} "
            f"to={CONTACT_EMAIL_TO} ip={client_ip} has_contact={bool(contact_info)}",
            flush=True,
        )
        return True, ""
    except Exception as exc:
        print(f"💥 contact email failed: {type(exc).__name__}: {exc}", flush=True)
        return False, "邮件发送失败"

# ===================================================================
# 魔数校验
# ===================================================================
MAGIC = {
    b"\xff\xd8\xff": "jpeg", b"\x89PNG\r\n\x1a\n": "png",
    b"GIF87a": "gif", b"GIF89a": "gif", b"RIFF": "webp", b"BM": "bmp",
}
ALLOWED_FMTS = {"jpeg", "png", "webp", "bmp", "gif"}

def detect_format(data: bytes) -> str | None:
    for magic, fmt in MAGIC.items():
        if data.startswith(magic):
            if fmt == "webp" and len(data) >= 12 and data[8:12] == b"WEBP": return "webp"
            if fmt == "webp": continue
            return fmt
    return None

def validate_image(data: bytes) -> tuple[bool, str]:
    if len(data) > MAX_IMAGE_BYTES: return False, f"图片过大(>{CONFIG['max_image_mb']}MB)"
    fmt = detect_format(data)
    if fmt is None: return False, "无法识别的格式"
    if fmt not in ALLOWED_FMTS: return False, f"不支持的格式: {fmt}"
    try:
        img = Image.open(io.BytesIO(data)); img.verify()
        img = Image.open(io.BytesIO(data))
        w, h = img.size
        if w > MAX_DIMENSIONS or h > MAX_DIMENSIONS: return False, "尺寸超限"
        if w * h > MAX_IMAGE_PIXELS: return False, "像素数超限"
    except Image.DecompressionBombError:
        return False, "解压炸弹"
    except Exception as e:
        return False, f"图片异常: {str(e)[:80]}"
    return True, ""

# ===================================================================
# 异步任务系统（支持中间结果）
# ===================================================================
task_store: dict[str, dict] = {}
task_lock = threading.Lock()
task_queue: list[str] = []
queue_lock = threading.Lock()
queue_event = threading.Event()
CANCELED_STATUS = "canceled"
active_task_id = ""
active_task_lock = threading.Lock()
canceled_upload_attempts: dict[str, float] = {}
canceled_upload_lock = threading.Lock()
MAX_UPLOAD_ATTEMPT_ID_CHARS = 128

POLAROID_SIZE_AUTO = "auto"
POLAROID_SIZE_MINI = "mini"
POLAROID_SIZE_WIDE = "wide"
POLAROID_SIZE_VALUES = {POLAROID_SIZE_AUTO, POLAROID_SIZE_MINI, POLAROID_SIZE_WIDE}
POLAROID_GEOMETRIES = {
    POLAROID_SIZE_MINI: {
        "width": 1200,
        "height": 1908,
        "image_area_vertices": np.array([[82,150],[1118,150],[1118,1533],[82,1533]], dtype=np.int32),
        "white_balance_block_size": 48,
        "white_balance_step": 24,
    },
    POLAROID_SIZE_WIDE: {
        "width": 2400,
        "height": 1908,
        "image_area_vertices": np.array([[82,150],[2318,150],[2318,1533],[82,1533]], dtype=np.int32),
        "white_balance_block_size": 48,
        "white_balance_step": 24,
    },
}
POLAROID_W = POLAROID_GEOMETRIES[POLAROID_SIZE_MINI]["width"]
POLAROID_H = POLAROID_GEOMETRIES[POLAROID_SIZE_MINI]["height"]
IMAGE_AREA_VERTICES = POLAROID_GEOMETRIES[POLAROID_SIZE_MINI]["image_area_vertices"]
COLORS = [(255,0,0),(0,200,0),(0,120,255),(255,165,0),(200,0,200),(0,200,200),
          (255,80,80),(80,255,80),(80,80,255),(255,200,0),(255,0,200),(0,255,200)]
POSTPROCESS_MODE_OFF = "off"
POSTPROCESS_MODE_DENOISE = "denoise"
POSTPROCESS_MODE_SHARPEN = "sharpen"
POSTPROCESS_MODE_VALUES = {POSTPROCESS_MODE_OFF, POSTPROCESS_MODE_DENOISE, POSTPROCESS_MODE_SHARPEN}
WHITE_BALANCE_COLOR_SPACE = "linear_rgb"
LAB_DENOISE_L_H = 3.5
LAB_DENOISE_AB_H = 6.0
LAB_DENOISE_TEMPLATE_WINDOW = 7
LAB_DENOISE_SEARCH_WINDOW = 21
LAB_SHARPEN_SIGMA = 1.0
LAB_SHARPEN_AMOUNT = 0.45
LAB_SHARPEN_THRESHOLD = 3.0


def img_to_png_bytes(img_np: np.ndarray) -> bytes:
    """numpy BGR/RGB → PNG bytes"""
    if img_np.shape[-1] == 3 and img_np.dtype == np.uint8:
        ok, buf = cv2.imencode(".png", cv2.cvtColor(img_np, cv2.COLOR_RGB2BGR))
    else:
        ok, buf = cv2.imencode(".png", img_np)
    return buf.tobytes() if ok else b""


def parse_bool(value, default=False) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in {"1", "true", "yes", "on"}


def parse_positive_int(*values) -> int:
    for value in values:
        if value is None:
            continue
        try:
            parsed = int(str(value).strip())
        except (TypeError, ValueError):
            continue
        if parsed > 0:
            return parsed
    return 0


def parse_rotation_degrees(value) -> int:
    try:
        degrees = int(str(value or "0").strip())
    except (TypeError, ValueError):
        return 0
    return degrees % 360


def parse_polaroid_size(value) -> str:
    normalized = str(value or "").strip().lower()
    if normalized in POLAROID_SIZE_VALUES:
        return normalized
    return POLAROID_SIZE_MINI


def parse_postprocess_mode(value, legacy_denoise=True) -> str:
    if value is not None:
        normalized = str(value).strip().lower()
        if normalized in POSTPROCESS_MODE_VALUES:
            return normalized
        return POSTPROCESS_MODE_DENOISE
    return POSTPROCESS_MODE_DENOISE if legacy_denoise else POSTPROCESS_MODE_OFF


def get_polaroid_geometry(polaroid_size: str) -> dict:
    return POLAROID_GEOMETRIES.get(polaroid_size, POLAROID_GEOMETRIES[POLAROID_SIZE_MINI])


def quad_horizontal_vertical_ratio(vertices: np.ndarray) -> float:
    verts = np.asarray(vertices, dtype=np.float32).reshape(4, 2)
    horizontal_lengths = [
        float(np.linalg.norm(verts[1] - verts[0])),
        float(np.linalg.norm(verts[2] - verts[3])),
    ]
    vertical_lengths = [
        float(np.linalg.norm(verts[2] - verts[1])),
        float(np.linalg.norm(verts[3] - verts[0])),
    ]
    vertical_avg = float(np.mean(vertical_lengths))
    if vertical_avg <= 0:
        return float("inf")
    return float(np.mean(horizontal_lengths) / vertical_avg)


def resolve_polaroid_size(requested_size: str, vertices: np.ndarray) -> str:
    if requested_size == POLAROID_SIZE_AUTO:
        return (
            POLAROID_SIZE_WIDE
            if quad_horizontal_vertical_ratio(vertices) > 1
            else POLAROID_SIZE_MINI
        )
    if requested_size == POLAROID_SIZE_WIDE:
        return POLAROID_SIZE_WIDE
    return POLAROID_SIZE_MINI


def quad_area(vertices: np.ndarray) -> float:
    return float(abs(cv2.contourArea(np.asarray(vertices, dtype=np.float32))))


def build_detection_candidates(masks: list[np.ndarray]) -> list[dict]:
    candidates = []
    for mask in masks:
        contours, _ = cv2.findContours(mask.astype(np.uint8), cv2.RETR_EXTERNAL,
                                        cv2.CHAIN_APPROX_NONE)
        if not contours:
            continue
        pts = np.vstack([c.reshape(-1, 2) for c in contours])
        try:
            verts = fit_quadrilateral(pts)
        except Exception:
            continue
        candidates.append({
            "vertices": verts,
            "area": quad_area(verts),
        })
    return candidates


def srgb_u8_to_linear_rgb(image: np.ndarray) -> np.ndarray:
    srgb = image.astype(np.float32) / 255.0
    return np.where(srgb <= 0.04045, srgb / 12.92, ((srgb + 0.055) / 1.055) ** 2.4)


def srgb_channel_to_linear(value: float) -> float:
    value = float(np.clip(value, 0.0, 1.0))
    if value <= 0.04045:
        return value / 12.92
    return ((value + 0.055) / 1.055) ** 2.4


def linear_rgb_to_srgb_u8(linear: np.ndarray) -> np.ndarray:
    linear = np.clip(linear, 0.0, 1.0)
    srgb = np.where(linear <= 0.0031308, linear * 12.92, 1.055 * (linear ** (1.0 / 2.4)) - 0.055)
    return np.clip(np.rint(srgb * 255.0), 0, 255).astype(np.uint8)


def apply_fixed_border_white_balance(image: np.ndarray, geometry: dict | None = None) -> tuple[np.ndarray, dict]:
    """White-balance a rectified polaroid using its fixed border area."""
    geometry = geometry or get_polaroid_geometry(POLAROID_SIZE_MINI)
    if image.dtype != np.uint8 or image.ndim != 3 or image.shape[2] != 3:
        return image, {"applied": False, "reason": "unsupported_image_shape", "color_space": WHITE_BALANCE_COLOR_SPACE}
    h, w = image.shape[:2]
    border_mask = np.ones((h, w), dtype=np.uint8)
    cv2.fillPoly(border_mask, [geometry["image_area_vertices"]], 0)
    border_mask = border_mask.astype(bool)

    linear = srgb_u8_to_linear_rgb(image)
    bright_threshold = srgb_channel_to_linear(170.0 / 255.0)
    neutral_threshold = 25.0 / 255.0
    is_bright = np.all(linear > bright_threshold, axis=2)
    is_neutral = np.std(linear, axis=2) < neutral_threshold
    is_white = is_bright & is_neutral & border_mask

    blocks = []
    block_size = int(geometry.get("white_balance_block_size") or max(1, round(min(h, w) / 16)))
    step = int(geometry.get("white_balance_step") or max(1, round(block_size / 2)))
    for y in range(0, h - block_size, step):
        for x in range(0, w - block_size, step):
            block = is_white[y:y+block_size, x:x+block_size]
            if np.sum(block) / (block_size * block_size) > 0.8:
                pixels = linear[y:y+block_size, x:x+block_size][block]
                blocks.append({
                    "mean": pixels.mean(axis=0),
                    "var": pixels.var(axis=0).mean(),
                })

    if not blocks:
        return image, {"applied": False, "reason": "no_white_reference_blocks", "color_space": WHITE_BALANCE_COLOR_SPACE}

    blocks.sort(key=lambda b: b["var"])
    best = blocks[:10]
    ref_white = np.mean([b["mean"] for b in best], axis=0)
    target = srgb_channel_to_linear(240.0 / 255.0)
    gains = np.array([
        target / max(ref_white[0], 1e-6),
        target / max(ref_white[1], 1e-6),
        target / max(ref_white[2], 1e-6),
    ], dtype=np.float32)
    balanced = linear_rgb_to_srgb_u8(linear * gains)
    return balanced, {
        "applied": True,
        "color_space": WHITE_BALANCE_COLOR_SPACE,
        "blocks": len(blocks),
        "used_blocks": len(best),
        "ref_white": [round(float(v), 5) for v in ref_white],
        "gains": [round(float(v), 4) for v in gains],
    }


def denoise_extracted_polaroid(image: np.ndarray) -> tuple[np.ndarray, dict]:
    """Reduce scan/print noise with conservative LAB-channel NLM."""
    if image.dtype != np.uint8 or image.ndim != 3 or image.shape[2] != 3:
        return image, {"applied": False, "reason": "unsupported_image_shape"}

    lab = cv2.cvtColor(image, cv2.COLOR_RGB2LAB)
    l_channel, a_channel, b_channel = cv2.split(lab)
    denoised_l = cv2.fastNlMeansDenoising(
        l_channel,
        None,
        h=LAB_DENOISE_L_H,
        templateWindowSize=LAB_DENOISE_TEMPLATE_WINDOW,
        searchWindowSize=LAB_DENOISE_SEARCH_WINDOW,
    )
    denoised_a = cv2.fastNlMeansDenoising(
        a_channel,
        None,
        h=LAB_DENOISE_AB_H,
        templateWindowSize=LAB_DENOISE_TEMPLATE_WINDOW,
        searchWindowSize=LAB_DENOISE_SEARCH_WINDOW,
    )
    denoised_b = cv2.fastNlMeansDenoising(
        b_channel,
        None,
        h=LAB_DENOISE_AB_H,
        templateWindowSize=LAB_DENOISE_TEMPLATE_WINDOW,
        searchWindowSize=LAB_DENOISE_SEARCH_WINDOW,
    )
    denoised_lab = cv2.merge([denoised_l, denoised_a, denoised_b])
    rgb = cv2.cvtColor(denoised_lab, cv2.COLOR_LAB2RGB)
    return rgb, {
        "applied": True,
        "method": "lab_fastNlMeansDenoising",
        "h": LAB_DENOISE_L_H,
        "l_h": LAB_DENOISE_L_H,
        "ab_h": LAB_DENOISE_AB_H,
        "templateWindowSize": LAB_DENOISE_TEMPLATE_WINDOW,
        "searchWindowSize": LAB_DENOISE_SEARCH_WINDOW,
    }


def sharpen_extracted_polaroid(image: np.ndarray) -> tuple[np.ndarray, dict]:
    """Apply reduced USM low sharpen on the LAB L channel only."""
    if image.dtype != np.uint8 or image.ndim != 3 or image.shape[2] != 3:
        return image, {"applied": False, "reason": "unsupported_image_shape"}

    lab = cv2.cvtColor(image, cv2.COLOR_RGB2LAB)
    l_channel, a_channel, b_channel = cv2.split(lab)
    l_float = l_channel.astype(np.float32)
    blurred = cv2.GaussianBlur(l_float, (0, 0), sigmaX=LAB_SHARPEN_SIGMA, sigmaY=LAB_SHARPEN_SIGMA)
    detail = l_float - blurred
    sharpened_l = l_float.copy()
    edge_mask = np.abs(detail) >= LAB_SHARPEN_THRESHOLD
    sharpened_l[edge_mask] = l_float[edge_mask] + LAB_SHARPEN_AMOUNT * detail[edge_mask]
    sharpened_l = np.clip(np.rint(sharpened_l), 0, 255).astype(np.uint8)
    sharpened_lab = cv2.merge([sharpened_l, a_channel, b_channel])
    rgb = cv2.cvtColor(sharpened_lab, cv2.COLOR_LAB2RGB)
    return rgb, {
        "applied": True,
        "method": "lab_l_channel_usm",
        "sigma": LAB_SHARPEN_SIGMA,
        "amount": LAB_SHARPEN_AMOUNT,
        "threshold": LAB_SHARPEN_THRESHOLD,
    }


def apply_postprocess_mode(image: np.ndarray, mode: str) -> tuple[np.ndarray, dict]:
    if mode == POSTPROCESS_MODE_OFF:
        return image, {"mode": POSTPROCESS_MODE_OFF, "applied": False, "steps": []}

    denoised, denoise_info = denoise_extracted_polaroid(image)
    steps = [{"name": POSTPROCESS_MODE_DENOISE, **denoise_info}]
    if mode == POSTPROCESS_MODE_SHARPEN and denoise_info.get("applied"):
        sharpened, sharpen_info = sharpen_extracted_polaroid(denoised)
        steps.append({"name": POSTPROCESS_MODE_SHARPEN, **sharpen_info})
        return sharpened, {"mode": POSTPROCESS_MODE_SHARPEN, "applied": bool(sharpen_info.get("applied")), "steps": steps}

    return denoised, {"mode": POSTPROCESS_MODE_DENOISE, "applied": bool(denoise_info.get("applied")), "steps": steps}


def add_intermediate(task_id: str, rtype: str, img_data: bytes, label: str):
    """向任务添加一个中间结果"""
    with task_lock:
        t = task_store.get(task_id)
        if not t: return
        if t.get("cancel_requested") or t.get("status") == CANCELED_STATUS:
            return
        if "results" not in t:
            t["results"] = []
        rid = len(t["results"])
        t["results"].append({
            "id": rid, "type": rtype, "label": label,
            "image_bytes": img_data, "mimetype": "image/png",
        })


def mark_task_canceled(task_id: str, *, drop_raw_data: bool = False) -> bool:
    now = time.time()
    with task_lock:
        t = task_store.get(task_id)
        if not t:
            return False
        t["cancel_requested"] = True
        t["status"] = CANCELED_STATUS
        t["phase"] = CANCELED_STATUS
        t["error"] = "Task canceled"
        t["extraction_complete"] = True
        t["finished_at"] = now
        if t.get("started_at") and "elapsed" not in t:
            t["elapsed"] = now - t["started_at"]
        if drop_raw_data:
            t.pop("raw_data", None)
        return True


def is_task_cancel_requested(task_id: str) -> bool:
    with task_lock:
        t = task_store.get(task_id)
        return bool(t and (t.get("cancel_requested") or t.get("status") == CANCELED_STATUS))


def cancel_if_requested(task_id: str) -> bool:
    if not is_task_cancel_requested(task_id):
        return False
    mark_task_canceled(task_id)
    return True


def set_active_task(task_id: str):
    global active_task_id
    with active_task_lock:
        active_task_id = task_id


def clear_active_task(task_id: str):
    global active_task_id
    with active_task_lock:
        if active_task_id == task_id:
            active_task_id = ""


def get_active_task_id() -> str:
    with active_task_lock:
        return active_task_id


def normalize_upload_attempt_id(value) -> str:
    if value is None:
        return ""
    attempt_id = str(value).strip()
    if len(attempt_id) > MAX_UPLOAD_ATTEMPT_ID_CHARS:
        return ""
    return attempt_id


def get_upload_attempt_id() -> str:
    attempt_id = normalize_upload_attempt_id(request.form.get("upload_attempt_id"))
    if attempt_id:
        return attempt_id
    attempt_id = normalize_upload_attempt_id(request.form.get("uploadAttemptId"))
    if attempt_id:
        return attempt_id
    attempt_id = normalize_upload_attempt_id(request.args.get("upload_attempt_id"))
    if attempt_id:
        return attempt_id
    if request.is_json:
        data = request.get_json(silent=True) or {}
        attempt_id = normalize_upload_attempt_id(data.get("upload_attempt_id"))
        if attempt_id:
            return attempt_id
        attempt_id = normalize_upload_attempt_id(data.get("uploadAttemptId"))
        if attempt_id:
            return attempt_id
    return ""


def cleanup_canceled_upload_attempts(now: float | None = None):
    now = now or time.time()
    with canceled_upload_lock:
        for attempt_id, canceled_at in list(canceled_upload_attempts.items()):
            if now - canceled_at > TASK_TTL:
                del canceled_upload_attempts[attempt_id]


def mark_upload_attempt_canceled(upload_attempt_id: str) -> bool:
    attempt_id = normalize_upload_attempt_id(upload_attempt_id)
    if not attempt_id:
        return False
    cleanup_canceled_upload_attempts()
    with canceled_upload_lock:
        canceled_upload_attempts[attempt_id] = time.time()
    return True


def is_upload_attempt_canceled(upload_attempt_id: str) -> bool:
    attempt_id = normalize_upload_attempt_id(upload_attempt_id)
    if not attempt_id:
        return False
    cleanup_canceled_upload_attempts()
    with canceled_upload_lock:
        return attempt_id in canceled_upload_attempts


def do_process_extraction(raw_data: bytes, task_id: str):
    """主处理流程：SAM3 检测 → 四边形拟合 → 逐个提取"""
    if cancel_if_requested(task_id):
        return
    model, processor, device = get_sam3()
    if cancel_if_requested(task_id):
        return
    with task_lock:
        white_balance_enabled = bool(task_store.get(task_id, {}).get("white_balance", True))
        postprocess_mode = parse_postprocess_mode(
            task_store.get(task_id, {}).get("postprocess_mode"),
            bool(task_store.get(task_id, {}).get("denoise", True)),
        )
        denoise_enabled = postprocess_mode != POSTPROCESS_MODE_OFF
        requested_polaroids = int(task_store.get(task_id, {}).get("requested_polaroids", 0) or 0)
        rotation_degrees = int(task_store.get(task_id, {}).get("rotation_degrees", 0) or 0)
        requested_polaroid_size = parse_polaroid_size(task_store.get(task_id, {}).get("polaroid_size"))

    # --- 步骤 0: 加载图片 ---
    if cancel_if_requested(task_id):
        return
    with task_lock:
        task_store[task_id]["phase"] = "loading"
    image = Image.open(io.BytesIO(raw_data)).convert("RGB")
    image = ImageOps.exif_transpose(image)
    if rotation_degrees:
        image = image.rotate(rotation_degrees, expand=True)
    img_np = np.array(image)
    print(f"🖼️  图片: {image.size[0]}x{image.size[1]} (rotation={rotation_degrees})", flush=True)

    # --- 步骤 1: SAM3 检测纸框 ---
    if cancel_if_requested(task_id):
        return
    with task_lock:
        task_store[task_id]["phase"] = "detecting"
    print(f"🔍 SAM3 检测拍立得纸框... (目标: {requested_polaroids or '自动'})", flush=True)
    t0 = time.time()
    inputs = processor(images=image, text="polaroid photo paper frame",
                       return_tensors="pt").to(device)
    with torch.no_grad():
        outputs = model(**inputs)

    def detect_with_threshold(threshold: float) -> tuple[list[np.ndarray], list[dict]]:
        results = processor.post_process_instance_segmentation(
            outputs, threshold=threshold, mask_threshold=0.5,
            target_sizes=[image.size[::-1]]
        )[0]
        masks_for_threshold = [m.cpu().numpy() for m in results["masks"]]
        return masks_for_threshold, build_detection_candidates(masks_for_threshold)

    threshold_used = 0.5
    masks, candidates = detect_with_threshold(threshold_used)
    should_retry = (
        requested_polaroids > 0 and len(candidates) < requested_polaroids
    ) or (
        requested_polaroids == 0 and len(candidates) == 0
    )
    if should_retry:
        print(f"   阈值 {threshold_used:.1f} 检测到 {len(candidates)} 张，降低到 0.3 重试", flush=True)
        threshold_used = 0.3
        masks, candidates = detect_with_threshold(threshold_used)

    del inputs, outputs
    torch.cuda.empty_cache() if device == "cuda" else None
    if cancel_if_requested(task_id):
        return
    detected_count = len(candidates)
    detection_warning = ""
    print(f"   检测到 {detected_count} 张拍立得 (阈值 {threshold_used:.1f}, 耗时 {time.time()-t0:.1f}s)", flush=True)

    if requested_polaroids > 0 and detected_count < requested_polaroids:
        detection_warning = f"只检测到 {detected_count}/{requested_polaroids} 张拍立得，已按检测结果继续处理"
        print(f"   ⚠ {detection_warning}", flush=True)

    if requested_polaroids > 0 and detected_count > requested_polaroids:
        drop_count = detected_count - requested_polaroids
        candidates.sort(key=lambda item: item["area"], reverse=True)
        dropped = candidates[requested_polaroids:]
        candidates = candidates[:requested_polaroids]
        smallest_dropped = [round(item["area"], 1) for item in sorted(dropped, key=lambda item: item["area"])[:3]]
        print(f"   检测到 {detected_count} 张，高于目标 {requested_polaroids} 张，已按四边形面积丢弃最小 {drop_count} 张: {smallest_dropped}", flush=True)

    if not candidates:
        if cancel_if_requested(task_id):
            return
        with task_lock:
            task_store[task_id]["status"] = "done" if requested_polaroids else "failed"
            task_store[task_id]["phase"] = "complete"
            task_store[task_id]["error"] = "" if requested_polaroids else "未检测到拍立得纸框"
            task_store[task_id]["warning"] = detection_warning
            task_store[task_id]["detection_threshold"] = threshold_used
            task_store[task_id]["detected_polaroids"] = detected_count
            task_store[task_id]["expected_polaroids"] = 0
            task_store[task_id]["total_polaroids"] = 0
            task_store[task_id]["extraction_complete"] = True
        return

    all_vertices = [item["vertices"] for item in candidates]

    # Sort detected polaroids from left to right for stable labels and downloads.
    all_vertices.sort(key=lambda verts: float(verts[:, 0].mean()))

    # --- 步骤 2: 逐个提取 ---
    if cancel_if_requested(task_id):
        return
    with task_lock:
        task_store[task_id]["phase"] = "extracting"
        task_store[task_id]["expected_polaroids"] = len(all_vertices)
        task_store[task_id]["total_polaroids"] = len(all_vertices)
        task_store[task_id]["detected_polaroids"] = detected_count
        task_store[task_id]["detection_threshold"] = threshold_used
        task_store[task_id]["warning"] = detection_warning
        task_store[task_id]["extraction_complete"] = False
    for pidx, verts in enumerate(all_vertices):
        if cancel_if_requested(task_id):
            return
        print(f"📸 提取拍立得 {pidx+1}/{len(all_vertices)}...", flush=True)
        output_polaroid_size = resolve_polaroid_size(requested_polaroid_size, verts)
        geometry = get_polaroid_geometry(output_polaroid_size)
        output_width = geometry["width"]
        output_height = geometry["height"]
        print(f"   size={output_polaroid_size}", flush=True)
        src = verts.astype(np.float32)
        dst = np.array([[0,0],[output_width,0],[output_width,output_height],
                        [0,output_height]], dtype=np.float32)
        M = cv2.getPerspectiveTransform(src, dst)
        rectified = cv2.warpPerspective(
            img_np,
            M,
            (output_width, output_height),
            flags=cv2.INTER_CUBIC,
        )
        if white_balance_enabled:
            rectified, wb_info = apply_fixed_border_white_balance(rectified, geometry)
            if wb_info["applied"]:
                print(f"   ✓ 白平衡 #{pidx+1}: gains={wb_info['gains']} blocks={wb_info['used_blocks']}/{wb_info['blocks']}", flush=True)
            else:
                print(f"   ⚠ 白平衡 #{pidx+1}: {wb_info['reason']}", flush=True)
        if denoise_enabled:
            rectified, denoise_info = denoise_extracted_polaroid(rectified)
            if denoise_info["applied"]:
                print(f"   ✓ 降噪 #{pidx+1}: {denoise_info['method']} h={denoise_info['h']}", flush=True)
            else:
                print(f"   ⚠ 降噪 #{pidx+1}: {denoise_info['reason']}", flush=True)
        if cancel_if_requested(task_id):
            return
        if postprocess_mode == POSTPROCESS_MODE_SHARPEN:
            rectified, sharpen_info = sharpen_extracted_polaroid(rectified)
            if sharpen_info["applied"]:
                print(f"   sharpen #{pidx+1}: {sharpen_info['method']} amount={sharpen_info['amount']}", flush=True)
            else:
                print(f"   sharpen #{pidx+1}: {sharpen_info['reason']}", flush=True)
        add_intermediate(task_id, "polaroid", img_to_png_bytes(rectified),
                         f"拍立得 #{pidx+1}")
        print(f"   ✓ 拍立得 #{pidx+1} 提取完成", flush=True)

    # --- 完成 ---
    if cancel_if_requested(task_id):
        return
    with task_lock:
        task_store[task_id]["status"] = "done"
        task_store[task_id]["phase"] = "complete"
        task_store[task_id]["total_polaroids"] = len(all_vertices)
        task_store[task_id]["expected_polaroids"] = len(all_vertices)
        task_store[task_id]["detected_polaroids"] = detected_count
        task_store[task_id]["detection_threshold"] = threshold_used
        task_store[task_id]["warning"] = detection_warning
        task_store[task_id]["extraction_complete"] = True
    print(f"✅ 全部完成: 共 {len(all_vertices)} 张拍立得", flush=True)


# ===================================================================
# Worker 线程
# ===================================================================
worker_running = True

def worker_loop():
    global worker_running
    print("🔧 Worker 启动", flush=True)
    while worker_running:
        task_id = None
        with queue_lock:
            if task_queue:
                task_id = task_queue.pop(0)
        if task_id is None:
            queue_event.wait(timeout=5)
            queue_event.clear()
            continue

        with task_lock:
            t = task_store.get(task_id)
            if not t: continue
            if t.get("cancel_requested") or t.get("status") == CANCELED_STATUS:
                continue
            set_active_task(task_id)
            t["status"] = "processing"
            t["started_at"] = time.time()

        print(f"\n{'='*40}\n🔧 task={task_id[:8]} 开始", flush=True)
        try:
            do_process_extraction(t["raw_data"], task_id)
            with task_lock:
                if task_id in task_store and task_store[task_id].get("status") != CANCELED_STATUS:
                    task_store[task_id]["elapsed"] = time.time() - task_store[task_id]["started_at"]
                    task_store[task_id]["finished_at"] = time.time()
        except Exception as e:
            print(f"💥 task={task_id[:8]} 崩溃: {type(e).__name__}: {e}", flush=True)
            traceback.print_exc()
            with task_lock:
                if task_id in task_store:
                    if task_store[task_id].get("status") != CANCELED_STATUS:
                        task_store[task_id]["status"] = "failed"
                        task_store[task_id]["error"] = str(e)[:200]

        # 清理 raw_data 释放内存
        with task_lock:
            if task_id in task_store:
                task_store[task_id].pop("raw_data", None)
        clear_active_task(task_id)
        gc.collect()
        global _device
        if _device == "cuda":
            torch.cuda.empty_cache()

# ===================================================================
# Flask 应用
# ===================================================================
app = Flask(__name__)
CORS(app)

@app.errorhandler(413)
def request_entity_too_large(error):
    return jsonify({"error": f"图片过大(>{CONFIG['max_image_mb']}MB)"}), 413

@app.errorhandler(Exception)
def handle_unexpected_error(error):
    print(f"💥 request failed: {type(error).__name__}: {error}", flush=True)
    return jsonify({"error": f"服务器错误: {type(error).__name__}"}), 500

@app.after_request
def security_headers(response):
    for k, v in {
        "X-Content-Type-Options": "nosniff",
        "X-Frame-Options": "DENY",
        "Referrer-Policy": "strict-origin-when-cross-origin",
        "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
        "Content-Security-Policy": "default-src 'self'; script-src 'self' 'unsafe-inline'; "
                                    "style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; "
                                    "connect-src 'self'; form-action 'self'",
    }.items():
        response.headers[k] = v
    return response

@app.before_request
def access_control():
    ip = get_client_ip()
    if not is_ip_allowed(ip):
        return jsonify({"error": "拒绝访问"}), 403
    if request.path in ("/api/process", "/api/contact") and request.method == "POST" and not check_rate_limit(ip):
        return jsonify({"error": "请求过于频繁"}), 429
    if request.method == "OPTIONS":
        return None
    if request.path in ("/api/health", "/api/auth/verify"):
        return None
    if request.path.startswith("/api/") and not is_token_valid(get_request_token()):
        return jsonify({"error": "Token 无效或已过期"}), 401

@app.route("/")
def index():
    return jsonify({"status": "ok", "service": "chekinana-api"})

@app.route("/api/health")
def health():
    return jsonify({
        "status": "ok",
        "time": datetime.now().isoformat(),
        "pod_id": RUNPOD_POD_ID,
        "token_source": ACCESS_TOKEN_SOURCE,
    })

@app.route("/api/auth/verify", methods=["POST"])
def verify_token():
    if not is_token_valid(get_request_token()):
        return jsonify({"ok": False, "error": "Token 无效或已过期"}), 401
    return jsonify({"ok": True, "status": "ok"})


@app.route("/api/cancel/<task_id>", methods=["POST"])
def cancel_task(task_id):
    queue_removed = False
    with queue_lock:
        while task_id in task_queue:
            task_queue.remove(task_id)
            queue_removed = True

    with task_lock:
        t = task_store.get(task_id)
        if not t:
            return jsonify({"ok": False, "error": "Task not found"}), 404
        previous_status = t.get("status", "")

    if previous_status in ("done", "failed"):
        return jsonify({
            "ok": False,
            "status": previous_status,
            "error": "Task already finished",
        }), 409

    mark_task_canceled(task_id, drop_raw_data=queue_removed or previous_status == "queued")
    print(f"[cancel] task={task_id[:8]} canceled (previous={previous_status}, queue_removed={queue_removed})", flush=True)
    return jsonify({
        "ok": True,
        "task_id": task_id,
        "status": CANCELED_STATUS,
        "previous_status": previous_status,
        "queue_removed": queue_removed,
    })


@app.route("/api/upload-cancel", methods=["POST"])
@app.route("/api/upload-cancel/<upload_attempt_id>", methods=["POST"])
def cancel_upload_attempt(upload_attempt_id=""):
    attempt_id = normalize_upload_attempt_id(upload_attempt_id) or get_upload_attempt_id()
    if not attempt_id:
        return jsonify({"ok": False, "error": "upload_attempt_id is required"}), 400
    mark_upload_attempt_canceled(attempt_id)
    print(f"[upload-cancel] attempt={attempt_id} canceled", flush=True)
    return jsonify({
        "ok": True,
        "status": CANCELED_STATUS,
        "upload_attempt_id": attempt_id,
    })


@app.route("/api/contact", methods=["POST"])
def contact_author():
    data = request.get_json(silent=True) or {}
    message_value = data.get("message", "")
    contact_value = data.get("contact", "")
    message_text = "" if message_value is None else str(message_value).strip()
    contact_info = "" if contact_value is None else str(contact_value).strip()
    if not message_text:
        return jsonify({"ok": False, "error": "请输入内容"}), 400
    if len(message_text) > MAX_CONTACT_MESSAGE_CHARS:
        return jsonify({"ok": False, "error": "内容过长，请控制在1000字以内"}), 400

    if len(contact_info) > MAX_CONTACT_INFO_CHARS:
        return jsonify({"ok": False, "error": "Contact info is too long (max 200 characters)"}), 400

    ok, error = send_contact_email(message_text, contact_info, get_client_ip())
    if not ok:
        return jsonify({"ok": False, "error": error}), 503
    return jsonify({"ok": True, "status": "sent"})

# ---- 提交任务 ----
@app.route("/api/process", methods=["POST"])
def submit_task():
    ip = get_client_ip()
    print(f"🟢 提交 | IP: {ip}", flush=True)
    upload_attempt_id = get_upload_attempt_id()
    if upload_attempt_id and is_upload_attempt_canceled(upload_attempt_id):
        print(f"[upload-cancel] rejected late upload attempt={upload_attempt_id} ip={ip}", flush=True)
        return jsonify({
            "ok": False,
            "status": CANCELED_STATUS,
            "error": "Upload attempt canceled",
            "upload_attempt_id": upload_attempt_id,
        }), 409
    if "image" not in request.files:
        return jsonify({"error": "请上传图片"}), 400
    file = request.files["image"]
    if not file.filename:
        return jsonify({"error": "文件名为空"}), 400
    raw = file.read()
    print(f"📷 {file.filename} | {len(raw):,}B", flush=True)
    ok, err = validate_image(raw)
    if not ok:
        return jsonify({"error": err}), 400

    white_balance = parse_bool(request.form.get("wb"), default=True)
    legacy_denoise = parse_bool(request.form.get("denoise"), default=True)
    postprocess_mode = parse_postprocess_mode(request.form.get("postprocess_mode"), legacy_denoise)
    denoise = postprocess_mode != POSTPROCESS_MODE_OFF
    requested_polaroids = parse_positive_int(
        request.form.get("expected_polaroids"),
        request.form.get("polaroid_count"),
    )
    rotation_degrees = parse_rotation_degrees(request.form.get("rotation_degrees"))
    polaroid_size = parse_polaroid_size(request.form.get("polaroid_size"))
    tid = uuid.uuid4().hex
    now = time.time()
    cleanup_canceled_upload_attempts(now)
    with task_lock:
        task_store[tid] = {
            "status": "queued", "phase": "waiting", "filename": file.filename,
            "size": len(raw), "raw_data": raw, "created_at": now, "ip": ip,
            "results": [], "white_balance": white_balance, "denoise": denoise,
            "postprocess_mode": postprocess_mode,
            "white_balance_color_space": WHITE_BALANCE_COLOR_SPACE if white_balance else "",
            "upload_attempt_id": upload_attempt_id,
            "requested_polaroids": requested_polaroids,
            "polaroid_size": polaroid_size,
            "rotation_degrees": rotation_degrees,
            "expected_polaroids": requested_polaroids,
            "total_polaroids": 0,
            "detected_polaroids": 0,
            "detection_threshold": 0,
            "warning": "",
            "extraction_complete": False,
        }
        # 清理过期
        for k in list(task_store.keys()):
            t = task_store[k]
            if t["status"] in ("done", "failed", CANCELED_STATUS) and now - t.get("finished_at", t["created_at"]) > TASK_TTL:
                del task_store[k]

    with queue_lock:
        task_queue.append(tid)
    queue_event.set()
    print(f"📋 task={tid[:8]} queued (队列: {len(task_queue)}, wb={white_balance}, postprocess_mode={postprocess_mode}, target={requested_polaroids or 'auto'}, rotation={rotation_degrees}, polaroid_size={polaroid_size})", flush=True)
    return jsonify({
        "task_id": tid,
        "status": "queued",
        "white_balance": white_balance,
        "denoise": denoise,
        "postprocess_mode": postprocess_mode,
        "white_balance_color_space": WHITE_BALANCE_COLOR_SPACE if white_balance else "",
        "requested_polaroids": requested_polaroids,
        "rotation_degrees": rotation_degrees,
        "expected_polaroids": requested_polaroids,
        "upload_attempt_id": upload_attempt_id,
    })

# ---- 查询状态（含中间结果列表） ----
@app.route("/api/status/<task_id>")
def task_status(task_id):
    with task_lock:
        t = task_store.get(task_id)
        if not t:
            return jsonify({"error": "任务不存在"}), 404

        status = t["status"]
        phase = t.get("phase", "")
        results_meta = [
            {"id": r["id"], "type": r["type"], "label": r["label"]}
            for r in t.get("results", [])
        ]
        total_polaroids = t.get("total_polaroids", 0)
        expected_polaroids = t.get("expected_polaroids", total_polaroids)
        requested_polaroids = t.get("requested_polaroids", 0)
        rotation_degrees = t.get("rotation_degrees", 0)
        denoise = bool(t.get("denoise", True))
        postprocess_mode = parse_postprocess_mode(t.get("postprocess_mode"), denoise)
        white_balance = bool(t.get("white_balance", True))
        white_balance_color_space = t.get("white_balance_color_space", WHITE_BALANCE_COLOR_SPACE if white_balance else "")
        detected_polaroids = t.get("detected_polaroids", 0)
        detection_threshold = t.get("detection_threshold", 0)
        warning = t.get("warning", "")
        extraction_complete = bool(t.get("extraction_complete", False))
        elapsed = t.get("elapsed", 0)
        error = t.get("error", "")
        upload_attempt_id = t.get("upload_attempt_id", "")
        current_active_task_id = get_active_task_id()

    pos = 0
    if status == "queued":
        with queue_lock:
            try: pos = task_queue.index(task_id) + 1
            except ValueError: pos = 0

    return jsonify({
        "task_id": task_id,
        "status": status,
        "phase": phase,
        "active_task_id": current_active_task_id,
        "processing_task_id": current_active_task_id,
        "queue_position": pos,
        "results_count": len(results_meta),
        "results": results_meta,
        "total_polaroids": total_polaroids,
        "expected_polaroids": expected_polaroids,
        "requested_polaroids": requested_polaroids,
        "rotation_degrees": rotation_degrees,
        "denoise": denoise,
        "postprocess_mode": postprocess_mode,
        "white_balance": white_balance,
        "white_balance_color_space": white_balance_color_space,
        "detected_polaroids": detected_polaroids,
        "detection_threshold": detection_threshold,
        "warning": warning,
        "extraction_complete": extraction_complete,
        "elapsed": elapsed,
        "error": error,
        "upload_attempt_id": upload_attempt_id,
    })

# ---- 获取某一步的结果图片 ----
@app.route("/api/result/<task_id>/<int:result_id>")
def task_result_part(task_id, result_id):
    with task_lock:
        t = task_store.get(task_id)
    if not t:
        return jsonify({"error": "任务不存在"}), 404
    results = t.get("results", [])
    if result_id >= len(results):
        return jsonify({"error": "结果尚未生成"}), 202
    r = results[result_id]
    return send_file(io.BytesIO(r["image_bytes"]), mimetype=r["mimetype"])

# ---- 兼容旧接口：获取最终结果 ----
@app.route("/api/result/<task_id>")
def task_result(task_id):
    with task_lock:
        t = task_store.get(task_id)
    if not t: return jsonify({"error": "任务不存在"}), 404
    if t["status"] in ("queued", "processing"):
        return jsonify({"error": "任务未完成"}), 202
    if t["status"] == "failed":
        return jsonify({"error": t.get("error", "")}), 500
    results = t.get("results", [])
    if not results:
        return jsonify({"error": "无结果"}), 404
    # 返回最后一步结果
    last = results[-1]
    return send_file(io.BytesIO(last["image_bytes"]), mimetype=last["mimetype"])

# ===================================================================
# 启动
# ===================================================================
_worker_started = False

if __name__ == "__main__":
    if not _worker_started:
        threading.Thread(target=worker_loop, daemon=True).start()
        _worker_started = True

    try:
        from waitress import serve
        host = os.environ.get("HOST", "0.0.0.0")
        port = int(os.environ.get("PORT", "8080"))
        threads = int(os.environ.get("THREADS", "6"))
        print(f"🚀 http://{host}:{port} (threads={threads})", flush=True)
        print(f"📋 白名单: {ALLOWED_IPS}", flush=True)
        print(f"🔐 访问 Token ({ACCESS_TOKEN_SOURCE}): {ACCESS_TOKEN}", flush=True)
        threading.Thread(target=preload_sam3_after_listen, args=(port,), daemon=True).start()
        serve(app, host=host, port=port, threads=threads)
    except ImportError:
        port = int(os.environ.get("PORT", "8080"))
        threading.Thread(target=preload_sam3_after_listen, args=(port,), daemon=True).start()
        app.run(host="0.0.0.0", port=port, debug=False)
