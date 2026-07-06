import hashlib
import http.client
import ipaddress
import json
import socket
import ssl
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parents[1]
LOCAL_MANIFEST = ROOT / "cloudflare-pages" / "assets" / "lianliankan" / "v1" / "manifest.json"
PUBLIC_MANIFEST_URL = "https://chekinana.top/assets/lianliankan/v1/manifest.json"
API_HEALTH_URL = "https://api.chekinana.top/api/health"
TIMEOUT_SECONDS = 180

NON_PUBLIC_NETWORKS = [
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("127.0.0.0/8"),
    ipaddress.ip_network("169.254.0.0/16"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
    ipaddress.ip_network("198.18.0.0/15"),
    ipaddress.ip_network("224.0.0.0/4"),
    ipaddress.ip_network("::1/128"),
    ipaddress.ip_network("fc00::/7"),
    ipaddress.ip_network("fe80::/10"),
]


def fail(message):
    print(f"FAIL {message}")
    return False


def is_public_ip(value):
    ip = ipaddress.ip_address(value)
    return not any(ip in network for network in NON_PUBLIC_NETWORKS)


def resolve_host(host):
    addresses = sorted({info[4][0] for info in socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)})
    public_addresses = [address for address in addresses if is_public_ip(address)]
    print(f"DNS {host} addresses={','.join(addresses) or 'none'} public={','.join(public_addresses) or 'none'}")
    return addresses, public_addresses


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def fetch_bytes(url):
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "chekinana-asset-check/1.0",
            "Cache-Control": "no-cache",
            "Pragma": "no-cache",
        },
    )
    context = ssl.create_default_context()
    with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS, context=context) as response:
        return {
            "status": response.status,
            "content_type": response.headers.get("Content-Type", ""),
            "body": response.read(),
        }


def check_asset(entry):
    url = entry["url"]
    try:
        response = fetch_bytes(url)
    except (urllib.error.URLError, TimeoutError, ssl.SSLError, OSError, http.client.IncompleteRead) as exc:
        return fail(f"asset id={entry['id']} url={url} error={exc}")

    body = response["body"]
    digest = sha256_bytes(body)
    content_type = response["content_type"]
    ok = True
    if response["status"] < 200 or response["status"] >= 300:
        ok = fail(f"asset id={entry['id']} status={response['status']} url={url}") and ok
    if "image/png" not in content_type.lower():
        ok = fail(f"asset id={entry['id']} content-type={content_type} url={url}") and ok
    if len(body) != entry["bytes"]:
        ok = fail(f"asset id={entry['id']} bytes={len(body)} expected={entry['bytes']} url={url}") and ok
    if digest != entry["sha256"]:
        ok = fail(f"asset id={entry['id']} sha256={digest} expected={entry['sha256']} url={url}") and ok

    print(
        "ASSET id={id} status={status} content-type={content_type} bytes={bytes} sha256={sha256} ok={ok} url={url}".format(
            id=entry["id"],
            status=response["status"],
            content_type=content_type,
            bytes=len(body),
            sha256=digest,
            ok=ok,
            url=url,
        )
    )
    return ok


def check_audio(entry):
    url = entry["url"]
    try:
        response = fetch_bytes(url)
    except (urllib.error.URLError, TimeoutError, ssl.SSLError, OSError, http.client.IncompleteRead) as exc:
        return fail(f"audio id={entry['id']} url={url} error={exc}")

    body = response["body"]
    digest = sha256_bytes(body)
    content_type = response["content_type"]
    ok = True
    if response["status"] < 200 or response["status"] >= 300:
        ok = fail(f"audio id={entry['id']} status={response['status']} url={url}") and ok
    if not content_type.lower().startswith("audio/"):
        ok = fail(f"audio id={entry['id']} content-type={content_type} url={url}") and ok
    if len(body) != entry["bytes"]:
        ok = fail(f"audio id={entry['id']} bytes={len(body)} expected={entry['bytes']} url={url}") and ok
    if digest != entry["sha256"]:
        ok = fail(f"audio id={entry['id']} sha256={digest} expected={entry['sha256']} url={url}") and ok

    print(
        "AUDIO id={id} status={status} content-type={content_type} bytes={bytes} sha256={sha256} ok={ok} url={url}".format(
            id=entry["id"],
            status=response["status"],
            content_type=content_type,
            bytes=len(body),
            sha256=digest,
            ok=ok,
            url=url,
        )
    )
    return ok


def check_manifest(local_manifest):
    try:
        response = fetch_bytes(PUBLIC_MANIFEST_URL)
    except (urllib.error.URLError, TimeoutError, ssl.SSLError, OSError, http.client.IncompleteRead) as exc:
        return fail(f"manifest url={PUBLIC_MANIFEST_URL} error={exc}"), None

    body = response["body"]
    digest = sha256_bytes(body)
    with tempfile.NamedTemporaryFile(delete=False) as handle:
        handle.write(body)
    ok = True
    if response["status"] < 200 or response["status"] >= 300:
        ok = fail(f"manifest status={response['status']}") and ok
    if "json" not in response["content_type"].lower():
        ok = fail(f"manifest content-type={response['content_type']}") and ok
    if json.loads(body.decode("utf-8")) != local_manifest:
        ok = fail("manifest body does not match local manifest") and ok

    print(
        "MANIFEST status={status} content-type={content_type} bytes={bytes} sha256={sha256} ok={ok} url={url}".format(
            status=response["status"],
            content_type=response["content_type"],
            bytes=len(body),
            sha256=digest,
            ok=ok,
            url=PUBLIC_MANIFEST_URL,
        )
    )
    return ok, json.loads(body.decode("utf-8"))


def check_api_route():
    try:
        response = fetch_bytes(API_HEALTH_URL)
        body_preview = response["body"][:160].decode("utf-8", errors="replace").replace("\n", " ")
        print(
            f"API status={response['status']} content-type={response['content_type']} body={body_preview}"
        )
        return response["status"] != 404
    except urllib.error.HTTPError as exc:
        body_preview = exc.read(160).decode("utf-8", errors="replace").replace("\n", " ")
        print(f"API status={exc.code} content-type={exc.headers.get('Content-Type', '')} body={body_preview}")
        return exc.code != 404
    except (urllib.error.URLError, TimeoutError, ssl.SSLError, OSError, http.client.IncompleteRead) as exc:
        return fail(f"api route url={API_HEALTH_URL} error={exc}")


def main():
    local_manifest = json.loads(LOCAL_MANIFEST.read_text(encoding="utf-8"))
    ok = True

    for host in (urlparse(PUBLIC_MANIFEST_URL).hostname, urlparse(API_HEALTH_URL).hostname):
        _, public_addresses = resolve_host(host)
        if not public_addresses:
            print(f"WARN {host} local resolver returned no public DNS address; continuing with HTTPS checks")

    manifest_ok, public_manifest = check_manifest(local_manifest)
    ok = manifest_ok and ok
    manifest_for_images = public_manifest or local_manifest

    images = manifest_for_images.get("images", [])
    if len(images) != 14:
        ok = fail(f"public manifest image count is {len(images)}, expected 14") and ok
    for entry in images:
        ok = check_asset(entry) and ok

    victory_audio = (manifest_for_images.get("audio") or {}).get("victory")
    if not victory_audio:
        ok = fail("public manifest missing audio.victory") and ok
    else:
        ok = check_audio(victory_audio) and ok

    ok = check_api_route() and ok
    if not ok:
        raise SystemExit(1)
    print("public lianliankan asset check passed")


if __name__ == "__main__":
    main()
