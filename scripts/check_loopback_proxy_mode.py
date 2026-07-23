import sys
import types
from pathlib import Path

REPOSITORY_ROOT = str(Path(__file__).resolve().parents[1])
if REPOSITORY_ROOT not in sys.path:
    sys.path.insert(0, REPOSITORY_ROOT)

try:
    import flask_cors  # noqa: F401
except ModuleNotFoundError:
    flask_cors_stub = types.ModuleType("flask_cors")
    flask_cors_stub.CORS = lambda app: app
    sys.modules["flask_cors"] = flask_cors_stub

import backend.app as backend_app


def request_status(client, remote_addr: str, headers=None):
    return client.get(
        "/api/status/not-a-real-task",
        environ_base={"REMOTE_ADDR": remote_addr},
        headers=headers or {},
    )


def main() -> None:
    original_mode = backend_app.TRUST_LOOPBACK_PROXY
    original_allowed_ips = backend_app.ALLOWED_IPS
    original_check_rate_limit = backend_app.check_rate_limit
    try:
        client = backend_app.app.test_client()

        backend_app.TRUST_LOOPBACK_PROXY = False
        with backend_app.app.test_request_context(
            "/api/status/not-a-real-task",
            environ_base={"REMOTE_ADDR": "127.0.0.1"},
            headers={"CF-Connecting-IP": "192.0.2.30"},
        ):
            assert backend_app.effective_client_ip() == "192.0.2.30"
        response = request_status(client, "127.0.0.1")
        assert response.status_code == 401

        backend_app.TRUST_LOOPBACK_PROXY = True
        with backend_app.app.test_request_context(
            "/api/status/not-a-real-task",
            environ_base={"REMOTE_ADDR": "127.0.0.1"},
            headers={
                "CF-Connecting-IP": "192.0.2.31",
                "X-Forwarded-For": "192.0.2.32",
            },
        ):
            assert backend_app.effective_client_ip() == "127.0.0.1"
        backend_app.ALLOWED_IPS = ["127.0.0.1"]
        response = request_status(
            client,
            "127.0.0.1",
            headers={
                "CF-Connecting-IP": "192.0.2.10",
                "Forwarded": "for=192.0.2.11",
                "X-Forwarded-For": "192.0.2.12",
                "X-Real-IP": "192.0.2.13",
            },
        )
        assert response.status_code == 404

        response = request_status(
            client,
            "192.0.2.20",
            headers={"CF-Connecting-IP": "127.0.0.1"},
        )
        assert response.status_code == 401

        response = client.post(
            "/api/auth/verify",
            environ_base={"REMOTE_ADDR": "127.0.0.1"},
        )
        assert response.status_code == 200
        assert response.get_json() == {"ok": True, "status": "ok"}

        rate_limit_keys = []

        def local_rate_limit(key: str) -> bool:
            rate_limit_keys.append(key)
            return len(rate_limit_keys) == 1

        backend_app.check_rate_limit = local_rate_limit
        response = client.post(
            "/api/process",
            environ_base={"REMOTE_ADDR": "127.0.0.1"},
            headers={
                "CF-Connecting-IP": "192.0.2.21",
                "X-Forwarded-For": "192.0.2.22",
                "X-Real-IP": "192.0.2.23",
            },
        )
        assert response.status_code == 400
        response = client.post(
            "/api/process",
            environ_base={"REMOTE_ADDR": "127.0.0.1"},
            headers={
                "CF-Connecting-IP": "198.51.100.21",
                "X-Forwarded-For": "198.51.100.22",
                "X-Real-IP": "198.51.100.23",
            },
        )
        assert response.status_code == 429
        assert rate_limit_keys == ["127.0.0.1", "127.0.0.1"]

        backend_app.validate_bind_host("127.0.0.1")
        try:
            backend_app.validate_bind_host("0.0.0.0")
        except RuntimeError:
            pass
        else:
            raise AssertionError("loopback proxy mode accepted a non-loopback bind")
    finally:
        backend_app.TRUST_LOOPBACK_PROXY = original_mode
        backend_app.ALLOWED_IPS = original_allowed_ips
        backend_app.check_rate_limit = original_check_rate_limit

    print("loopback proxy mode checks passed")


if __name__ == "__main__":
    main()
