"""
图片处理服务 — 拍立得提取版
- SAM3 检测拍立得纸框 → 四边形拟合 → 透视矫正
- 分步处理，每步结果即时推送到前端
"""

import io, os, time, json, uuid, hashlib, threading, sys, gc
from datetime import datetime
from collections import defaultdict

import numpy as np
import torch
import cv2
from PIL import Image, ImageOps
from flask import Flask, request, send_file, jsonify, render_template_string
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
    if _sam3_model is not None:
        return _sam3_model, _sam3_processor, _device

    with MODEL_LOAD_LOCK:
        if _sam3_model is not None:
            return _sam3_model, _sam3_processor, _device

        print("📦 正在加载 SAM3 模型（首次较慢）...", flush=True)
        from transformers import Sam3Model, Sam3Processor
        from modelscope import snapshot_download

        model_dir = snapshot_download('facebook/sam3', cache_dir='./sam3_model')
        model_dir_local = "./sam3_model/facebook/sam3"
        _device = "cuda" if torch.cuda.is_available() else "cpu"

        _sam3_model = Sam3Model.from_pretrained(model_dir_local).to(_device)
        _sam3_processor = Sam3Processor.from_pretrained(model_dir_local)
        print(f"✅ SAM3 就绪 (设备: {_device})", flush=True)
        return _sam3_model, _sam3_processor, _device

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

POLAROID_W, POLAROID_H = 800, 1272
COLORS = [(255,0,0),(0,200,0),(0,120,255),(255,165,0),(200,0,200),(0,200,200),
          (255,80,80),(80,255,80),(80,80,255),(255,200,0),(255,0,200),(0,255,200)]


def img_to_png_bytes(img_np: np.ndarray) -> bytes:
    """numpy BGR/RGB → PNG bytes"""
    if img_np.shape[-1] == 3 and img_np.dtype == np.uint8:
        ok, buf = cv2.imencode(".png", cv2.cvtColor(img_np, cv2.COLOR_RGB2BGR))
    else:
        ok, buf = cv2.imencode(".png", img_np)
    return buf.tobytes() if ok else b""


def add_intermediate(task_id: str, rtype: str, img_data: bytes, label: str):
    """向任务添加一个中间结果"""
    with task_lock:
        t = task_store.get(task_id)
        if not t: return
        if "results" not in t:
            t["results"] = []
        rid = len(t["results"])
        t["results"].append({
            "id": rid, "type": rtype, "label": label,
            "image_bytes": img_data, "mimetype": "image/png",
        })


def do_process_extraction(raw_data: bytes, task_id: str):
    """主处理流程：SAM3 检测 → 四边形标注 → 逐个提取"""
    model, processor, device = get_sam3()

    # --- 步骤 0: 加载图片 ---
    with task_lock:
        task_store[task_id]["phase"] = "loading"
    image = Image.open(io.BytesIO(raw_data)).convert("RGB")
    image = ImageOps.exif_transpose(image)
    img_np = np.array(image)
    print(f"🖼️  图片: {image.size[0]}x{image.size[1]}", flush=True)

    # --- 步骤 1: SAM3 检测纸框 ---
    with task_lock:
        task_store[task_id]["phase"] = "detecting"
    print("🔍 SAM3 检测拍立得纸框...", flush=True)
    t0 = time.time()
    inputs = processor(images=image, text="polaroid photo paper frame",
                       return_tensors="pt").to(device)
    with torch.no_grad():
        outputs = model(**inputs)
    results = processor.post_process_instance_segmentation(
        outputs, threshold=0.4, mask_threshold=0.5,
        target_sizes=[image.size[::-1]]
    )[0]
    masks = [m.cpu().numpy() for m in results["masks"]]
    del inputs, outputs, results
    torch.cuda.empty_cache() if device == "cuda" else None
    print(f"   检测到 {len(masks)} 张拍立得 (耗时 {time.time()-t0:.1f}s)", flush=True)

    if len(masks) == 0:
        with task_lock:
            task_store[task_id]["status"] = "failed"
            task_store[task_id]["error"] = "未检测到拍立得纸框"
        return

    # --- 步骤 2: 绘制四边形标注 ---
    with task_lock:
        task_store[task_id]["phase"] = "annotating"
    print("📐 绘制四边形标注...", flush=True)
    annotated = img_np.copy()
    overlay = annotated.copy()
    all_vertices = []

    for midx, mask in enumerate(masks):
        contours, _ = cv2.findContours(mask.astype(np.uint8), cv2.RETR_EXTERNAL,
                                        cv2.CHAIN_APPROX_NONE)
        if not contours: continue
        pts = np.vstack([c.reshape(-1, 2) for c in contours])
        try:
            verts = fit_quadrilateral(pts)
        except Exception:
            continue
        all_vertices.append(verts)
        color = COLORS[midx % len(COLORS)]
        # 半透明填充
        cv2.fillPoly(overlay, [verts.astype(np.int32)], color)
        # 边框 + 顶点
        cv2.polylines(annotated, [verts.astype(np.int32)], True, color, 3)
        for v in verts:
            cv2.circle(annotated, (int(v[0]), int(v[1])), 8, color, -1)

    # 混合半透明覆盖层 (alpha=0.3)
    annotated = cv2.addWeighted(overlay, 0.3, annotated, 0.7, 0)

    # 在混合后的图上绘制带背景色块的编号
    for midx, verts in enumerate(all_vertices):
        color = COLORS[midx % len(COLORS)]
        cx, cy = int(verts[:, 0].mean()), int(verts[:, 1].mean())
        # 大字号带彩色背景的编号
        font_scale = 2.0
        (tw, th), _ = cv2.getTextSize(f"#{midx+1}", cv2.FONT_HERSHEY_SIMPLEX, font_scale, 4)
        x1, y1 = cx - tw//2 - 12, cy - th//2 - 10
        x2, y2 = cx + tw//2 + 12, cy + th//2 + 10
        cv2.rectangle(annotated, (x1, y1), (x2, y2), color, -1)
        cv2.rectangle(annotated, (x1, y1), (x2, y2), (255,255,255), 3)
        cv2.putText(annotated, f"#{midx+1}", (cx - tw//2, cy + th//2),
                    cv2.FONT_HERSHEY_SIMPLEX, font_scale, (255,255,255), 4)

    add_intermediate(task_id, "annotated", img_to_png_bytes(annotated),
                     "四边形标注")
    print(f"   ✓ 四边形标注图已生成 ({len(all_vertices)} 张)", flush=True)

    # --- 步骤 3: 逐个提取 ---
    with task_lock:
        task_store[task_id]["phase"] = "extracting"
    for pidx, verts in enumerate(all_vertices):
        print(f"📸 提取拍立得 {pidx+1}/{len(all_vertices)}...", flush=True)
        src = verts.astype(np.float32)
        dst = np.array([[0,0],[POLAROID_W,0],[POLAROID_W,POLAROID_H],
                        [0,POLAROID_H]], dtype=np.float32)
        M = cv2.getPerspectiveTransform(src, dst)
        rectified = cv2.warpPerspective(img_np, M, (POLAROID_W, POLAROID_H))
        add_intermediate(task_id, "polaroid", img_to_png_bytes(rectified),
                         f"拍立得 #{pidx+1}")
        print(f"   ✓ 拍立得 #{pidx+1} 提取完成", flush=True)

    # --- 完成 ---
    with task_lock:
        task_store[task_id]["status"] = "done"
        task_store[task_id]["phase"] = "complete"
        task_store[task_id]["total_polaroids"] = len(all_vertices)
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
            t["status"] = "processing"
            t["started_at"] = time.time()

        print(f"\n{'='*40}\n🔧 task={task_id[:8]} 开始", flush=True)
        try:
            do_process_extraction(t["raw_data"], task_id)
            with task_lock:
                if task_id in task_store:
                    task_store[task_id]["elapsed"] = time.time() - task_store[task_id]["started_at"]
                    task_store[task_id]["finished_at"] = time.time()
        except Exception as e:
            print(f"💥 task={task_id[:8]} 崩溃: {type(e).__name__}: {e}", flush=True)
            with task_lock:
                if task_id in task_store:
                    task_store[task_id]["status"] = "failed"
                    task_store[task_id]["error"] = str(e)[:200]

        # 清理 raw_data 释放内存
        with task_lock:
            if task_id in task_store:
                task_store[task_id].pop("raw_data", None)
        gc.collect()
        global _device
        if _device == "cuda":
            torch.cuda.empty_cache()

# ===================================================================
# Flask 应用
# ===================================================================
app = Flask(__name__)
CORS(app)

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
    if request.path.startswith("/api/") and not check_rate_limit(ip):
        return jsonify({"error": "请求过于频繁"}), 429

# ---- 静态文件 ----
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
FP = os.path.join(BASE_DIR, "frontend", "index.html")
if not os.path.exists(FP):
    FP = os.path.join(BASE_DIR, "..", "frontend", "index.html")
with open(FP, "r", encoding="utf-8") as f:
    HTML = f.read()

@app.route("/")
def index():
    return render_template_string(HTML)

@app.route("/api/health")
def health():
    return jsonify({"status": "ok", "time": datetime.now().isoformat()})

# ---- 提交任务 ----
@app.route("/api/process", methods=["POST"])
def submit_task():
    ip = get_client_ip()
    print(f"🟢 提交 | IP: {ip}", flush=True)
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

    tid = uuid.uuid4().hex
    now = time.time()
    with task_lock:
        task_store[tid] = {
            "status": "queued", "phase": "waiting", "filename": file.filename,
            "size": len(raw), "raw_data": raw, "created_at": now, "ip": ip,
            "results": [],
        }
        # 清理过期
        for k in list(task_store.keys()):
            t = task_store[k]
            if t["status"] in ("done","failed") and now - t.get("finished_at", t["created_at"]) > TASK_TTL:
                del task_store[k]

    with queue_lock:
        task_queue.append(tid)
    queue_event.set()
    print(f"📋 task={tid[:8]} queued (队列: {len(task_queue)})", flush=True)
    return jsonify({"task_id": tid, "status": "queued"})

# ---- 查询状态（含中间结果列表） ----
@app.route("/api/status/<task_id>")
def task_status(task_id):
    with task_lock:
        t = task_store.get(task_id)
    if not t:
        return jsonify({"error": "任务不存在"}), 404

    pos = 0
    if t["status"] == "queued":
        with queue_lock:
            try: pos = task_queue.index(task_id) + 1
            except ValueError: pos = 0

    results_meta = []
    for r in t.get("results", []):
        results_meta.append({"id": r["id"], "type": r["type"], "label": r["label"]})

    return jsonify({
        "task_id": task_id,
        "status": t["status"],
        "phase": t.get("phase", ""),
        "queue_position": pos,
        "results_count": len(results_meta),
        "results": results_meta,
        "total_polaroids": t.get("total_polaroids", 0),
        "elapsed": t.get("elapsed", 0),
        "error": t.get("error", ""),
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

    # 启动时预加载 SAM3 模型（避免首次请求等待）
    print("📦 预加载 SAM3 模型...", flush=True)
    get_sam3()

    try:
        from waitress import serve
        host = os.environ.get("HOST", "0.0.0.0")
        port = int(os.environ.get("PORT", "8080"))
        threads = int(os.environ.get("THREADS", "6"))
        print(f"🚀 http://{host}:{port} (threads={threads})", flush=True)
        print(f"📋 白名单: {ALLOWED_IPS}", flush=True)
        serve(app, host=host, port=port, threads=threads)
    except ImportError:
        app.run(host="0.0.0.0", port=8080, debug=False)
