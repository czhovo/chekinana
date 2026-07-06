import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ASSET_ROOT = ROOT / "cloudflare-pages" / "assets" / "lianliankan" / "v1"
MANIFEST_PATH = ASSET_ROOT / "manifest.json"
IMAGES_DIR = ASSET_ROOT / "images"
AUDIO_DIR = ASSET_ROOT / "audio"
HEADERS_PATH = ROOT / "cloudflare-pages" / "_headers"
VICTORY_AUDIO = {
    "id": "victory",
    "file": "muguang.m4a",
    "path": "audio/muguang.m4a",
    "url": "https://chekinana.top/assets/lianliankan/v1/audio/muguang.m4a",
    "bytes": 5779308,
    "sha256": "b7fdfe23dc16fe1fef0d1ea9acdbe622242c59bd570394493186c3caf39234ec",
    "contentType": "audio/mp4",
}

EXPECTED_FILES = {
    1: "pattern1r.png",
    2: "pattern2p.png",
    3: "pattern3s.png",
    4: "pattern4g.png",
    5: "pattern5k.png",
    6: "pattern6b.png",
    7: "pattern7w.png",
    8: "pattern8g.png",
    9: "pattern9s.png",
    10: "pattern10p.png",
    11: "pattern11y.png",
    12: "pattern12k.png",
    13: "pattern13r.png",
    14: "pattern14w.png",
}


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fail(message):
    raise SystemExit(f"lianliankan asset check failed: {message}")


def main():
    if not MANIFEST_PATH.exists():
        fail(f"missing manifest: {MANIFEST_PATH}")
    if not IMAGES_DIR.is_dir():
        fail(f"missing images directory: {IMAGES_DIR}")
    if not AUDIO_DIR.is_dir():
        fail(f"missing audio directory: {AUDIO_DIR}")
    if not HEADERS_PATH.exists():
        fail(f"missing Pages _headers file: {HEADERS_PATH}")

    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    if manifest.get("schemaVersion") != 1:
        fail("manifest schemaVersion must be 1")
    if manifest.get("category") != "lianliankan":
        fail("manifest category must be lianliankan")
    if manifest.get("version") != "v1":
        fail("manifest version must be v1")
    if manifest.get("baseUrl") != "https://chekinana.top/assets/lianliankan/v1/":
        fail("manifest baseUrl is not the expected public URL prefix")

    images = manifest.get("images")
    if not isinstance(images, list) or len(images) != len(EXPECTED_FILES):
        fail("manifest must contain exactly 14 images")

    seen_ids = set()
    seen_files = set()
    for entry in images:
        image_id = entry.get("id")
        expected_file = EXPECTED_FILES.get(image_id)
        if not expected_file:
            fail(f"unexpected image id: {image_id}")
        if entry.get("file") != expected_file:
            fail(f"id {image_id} file mismatch: {entry.get('file')} != {expected_file}")

        expected_path = f"images/{expected_file}"
        expected_url = f"https://chekinana.top/assets/lianliankan/v1/{expected_path}"
        if entry.get("path") != expected_path:
            fail(f"id {image_id} path mismatch")
        if entry.get("url") != expected_url:
            fail(f"id {image_id} url mismatch")

        image_path = IMAGES_DIR / expected_file
        if not image_path.exists():
            fail(f"missing image file: {image_path}")
        if image_path.stat().st_size != entry.get("bytes"):
            fail(f"id {image_id} byte size mismatch")
        if sha256_file(image_path) != entry.get("sha256"):
            fail(f"id {image_id} sha256 mismatch")

        seen_ids.add(image_id)
        seen_files.add(expected_file)

    actual_files = {path.name for path in IMAGES_DIR.glob("*.png")}
    if seen_ids != set(EXPECTED_FILES):
        fail("manifest image ids are incomplete")
    if actual_files != seen_files:
        fail(f"image directory does not match manifest: {sorted(actual_files ^ seen_files)}")

    victory_audio = (manifest.get("audio") or {}).get("victory")
    if victory_audio != VICTORY_AUDIO:
        fail("manifest audio.victory does not match expected muguang.m4a metadata")
    audio_path = AUDIO_DIR / VICTORY_AUDIO["file"]
    if not audio_path.exists():
        fail(f"missing audio file: {audio_path}")
    if audio_path.stat().st_size != VICTORY_AUDIO["bytes"]:
        fail("victory audio byte size mismatch")
    if sha256_file(audio_path) != VICTORY_AUDIO["sha256"]:
        fail("victory audio sha256 mismatch")

    headers = HEADERS_PATH.read_text(encoding="utf-8")
    for required in (
        "/assets/lianliankan/v1/manifest.json",
        "/assets/lianliankan/v1/images/*",
        "/assets/lianliankan/v1/audio/*",
        "Content-Type: audio/mp4",
        "Access-Control-Allow-Origin: *",
    ):
        if required not in headers:
            fail(f"_headers missing required entry: {required}")

    print("lianliankan asset check passed: 14 images, victory audio, and manifest v1")


if __name__ == "__main__":
    main()
