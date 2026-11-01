"""Тесты клиента 3x-ui на фейковой панели (без сети и без реального 3x-ui)."""

from __future__ import annotations

import json
import ssl
import threading
import time
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from activation.config import Config
from activation.xui import PanelAuthError, XuiPanel, _norm_client


class Fake3xui:
    """Мини-панель 3x-ui: legacy (/inbounds/*) или modern (/clients/*) API."""

    def __init__(self, *, mode: str = "legacy", username: str = "admin",
                 password: str = "secret", api_token: str = "api-token",
                 web_path: str = "/panel"):
        self.mode = mode
        self.username = username
        self.password = password
        self.api_token = api_token
        self.web_path = web_path
        self.clients: dict[str, dict] = {}
        self.requests: list[tuple[str, str]] = []
        self.request_headers: dict[tuple[str, str], dict] = {}
        self.logins = 0
        self.drop_session_once = False
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), self._make_handler())
        self.httpd.daemon_threads = True
        self.base = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        self.thread = threading.Thread(
            target=lambda: self.httpd.serve_forever(poll_interval=0.02), daemon=True
        )
        self.thread.start()

    def close(self) -> None:
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(timeout=5)

    # ------------------------------------------------------------- HTTP
    def _make_handler(self):
        fake = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):  # noqa: D401 - тишина в тестах
                pass

            def do_GET(self):  # noqa: N802
                fake._handle(self, "GET")

            def do_POST(self):  # noqa: N802
                fake._handle(self, "POST")

        return Handler

    def _send(self, handler, status: int, payload=None, headers: dict | None = None) -> None:
        body = b"" if payload is None else json.dumps(payload).encode()
        handler.send_response(status)
        handler.send_header("Content-Type", "application/json")
        handler.send_header("Content-Length", str(len(body)))
        for key, value in (headers or {}).items():
            handler.send_header(key, value)
        handler.end_headers()
        if body:
            handler.wfile.write(body)

    def _authorized(self, handler) -> bool:
        cookie = handler.headers.get("Cookie", "")
        if self.drop_session_once and "3x-ui=ok" in cookie:
            self.drop_session_once = False
            return False
        if "3x-ui=ok" in cookie:
            return True
        return handler.headers.get("Authorization") == "Bearer " + self.api_token

    def _handle(self, handler, method: str) -> None:
        parsed = urllib.parse.urlsplit(handler.path)
        path = parsed.path
        self.requests.append((method, path))
        self.request_headers[(method, path)] = dict(handler.headers)
        length = int(handler.headers.get("Content-Length") or 0)
        raw = handler.rfile.read(length) if length else b""
        prefix = self.web_path
        if not path.startswith(prefix + "/"):
            return self._send(handler, 404, {"success": False, "msg": "not found"})
        rel = path[len(prefix):]

        if rel == "/login" and method == "POST":
            creds = self._credentials(handler, raw)
            if creds.get("username") == self.username and creds.get("password") == self.password:
                self.logins += 1
                return self._send(
                    handler, 200, {"success": True, "msg": "Logged in successfully"},
                    {"Set-Cookie": "3x-ui=ok; Path=/"},
                )
            return self._send(handler, 200, {"success": False, "msg": "Wrong username or password"})

        if rel == "/csrf-token" and method == "GET":
            if self.mode == "modern":
                return self._send(handler, 200, {"success": True, "obj": "csrf-token-123"})
            return self._send(handler, 404, {})

        if not self._authorized(handler):
            # классический 3x-ui отдаёт 404 неавторизованным (прячет API)
            return self._send(handler, 404 if self.mode == "legacy" else 401, {})

        if self.mode == "legacy":
            self._handle_legacy(handler, method, rel, raw)
        else:
            self._handle_modern(handler, method, rel, raw)

    @staticmethod
    def _credentials(handler, raw: bytes) -> dict:
        content_type = handler.headers.get("Content-Type", "")
        if "json" in content_type:
            try:
                return json.loads(raw or b"{}")
            except ValueError:
                return {}
        return {key: values[0] for key, values in urllib.parse.parse_qs(raw.decode()).items()}

    def _stats(self, email: str) -> dict:
        client = self.clients[email]
        return {
            "id": 1,
            "inboundId": client["inbound_id"],
            "enable": True,
            "email": email,
            "up": 0,
            "down": 0,
            "total": client["client"].get("totalGB", 0),
            "expiryTime": client["client"].get("expiryTime", 0),
            "subId": client["client"].get("subId", ""),
            "uuid": client["client"].get("id", ""),
        }

    def _handle_legacy(self, handler, method: str, rel: str, raw: bytes) -> None:
        if rel == "/panel/api/inbounds/list" and method == "GET":
            payload = {
                "success": True,
                "obj": [
                    {
                        "id": 1,
                        "settings": json.dumps(
                            {"clients": [item["client"] for item in self.clients.values()]}
                        ),
                        "clientStats": [self._stats(email) for email in self.clients],
                    }
                ],
            }
            return self._send(handler, 200, payload)
        if rel == "/panel/api/inbounds/addClient" and method == "POST":
            body = json.loads(raw or b"{}")
            settings = json.loads(body.get("settings") or "{}")
            client = settings["clients"][0]
            if client["email"] in self.clients:
                return self._send(
                    handler, 200,
                    {"success": False, "msg": f"Duplicate email: {client['email']}"},
                )
            self.clients[client["email"]] = {"client": client, "inbound_id": int(body["id"])}
            return self._send(handler, 200, {"success": True, "msg": "Client added successfully"})
        if rel.startswith("/panel/api/inbounds/getClientTraffics/") and method == "GET":
            email = urllib.parse.unquote(rel.rsplit("/", 1)[1])
            if email not in self.clients:
                return self._send(handler, 200, {"success": False, "msg": "not found"})
            return self._send(handler, 200, {"success": True, "obj": self._stats(email)})
        return self._send(handler, 404, {})

    def _handle_modern(self, handler, method: str, rel: str, raw: bytes) -> None:
        if rel.startswith("/panel/api/clients/get/") and method == "GET":
            email = urllib.parse.unquote(rel.rsplit("/", 1)[1])
            item = self.clients.get(email)
            if not item:
                return self._send(handler, 200, {"success": False, "msg": "record not found"})
            client = item["client"]
            return self._send(handler, 200, {"success": True, "obj": {
                "id": 1, "inboundIds": [item["inbound_id"]], "email": email,
                "uuid": client["id"], "subId": client["subId"],
                "totalGB": client.get("totalGB", 0), "expiryTime": client.get("expiryTime", 0),
                "enable": True, "traffic": {"up": 0, "down": 0, "enable": True},
            }})
        if rel == "/panel/api/clients/add" and method == "POST":
            body = json.loads(raw or b"{}")
            client = body["client"]
            self.clients[client["email"]] = {
                "client": client, "inbound_id": int(body["inboundIds"][0])
            }
            return self._send(handler, 200, {"success": True, "obj": None})
        if rel.startswith("/panel/api/clients/traffic/") and method == "GET":
            email = urllib.parse.unquote(rel.rsplit("/", 1)[1])
            if email not in self.clients:
                return self._send(handler, 200, {"success": False, "msg": "not found"})
            return self._send(handler, 200, {"success": True, "obj": self._stats(email)})
        return self._send(handler, 404, {})


def real_config(fake: Fake3xui, **overrides) -> Config:
    env = {
        "XUI_MODE": "real",
        "XUI_BASE_URL": fake.base,
        "XUI_WEB_BASE_PATH": "/panel/",
        "XUI_INBOUND_ID": "1",
        "XUI_USERNAME": "admin",
        "XUI_PASSWORD": "secret",
        "CODE_PEPPER": "test-pepper-0123456789abcdef",
        "ADMIN_TOKEN": "test-admin-token-0123456789abcdef",
        "SUB_URL_TEMPLATE": "https://sub.example.com:2096/xyz/{sub_id}",
        "XUI_VERIFY_TLS": "0",
        "XUI_TIMEOUT": "5",
    }
    env.update(overrides)
    return Config.from_env(env)


class LegacyApiTest(unittest.TestCase):
    def setUp(self) -> None:
        self.fake = Fake3xui(mode="legacy")
        self.addCleanup(self.fake.close)
        self.cfg = real_config(self.fake)
        self.panel = XuiPanel(self.cfg)

    def test_auto_detects_legacy_and_creates_client(self):
        result = self.panel.ensure_client(
            email="user@example.com", plan_days=30, total_gb=10
        )
        self.assertEqual(self.fake.logins, 1)
        self.assertRegex(result["sub_id"], r"^[0-9a-f]{16}$")
        self.assertIn(
            ("GET", "/panel/panel/api/clients/get/user%40example.com"), self.fake.requests
        )

        saved = self.fake.clients["user@example.com"]["client"]
        self.assertEqual(saved["email"], "user@example.com")
        self.assertEqual(saved["id"], result["uuid"])
        self.assertEqual(saved["subId"], result["sub_id"])
        self.assertEqual(saved["totalGB"], 10 * 1024**3)
        expected_expiry = (int(time.time()) + 30 * 86400) * 1000
        self.assertAlmostEqual(saved["expiryTime"], expected_expiry, delta=5000)
        self.assertTrue(saved["enable"])

        self.assertEqual(result["total"], 10 * 1024**3)
        self.assertEqual(result["expiry_time_ms"], saved["expiryTime"])
        self.assertTrue(self.panel.sub_url(result["sub_id"]).endswith(result["sub_id"]))

    def test_second_ensure_reuses_existing_client(self):
        first = self.panel.ensure_client(email="user@example.com", plan_days=30, total_gb=10)
        second = self.panel.ensure_client(email="user@example.com", plan_days=30, total_gb=10)
        self.assertEqual(first["uuid"], second["uuid"])
        self.assertEqual(first["sub_id"], second["sub_id"])
        add_calls = [item for item in self.fake.requests
                     if item[1].endswith("/inbounds/addClient")]
        self.assertEqual(len(add_calls), 1)

    def test_expired_cookie_session_triggers_relogin(self):
        self.panel.find_client("nobody@example.com")  # первичный логин + определение стиля
        self.assertEqual(self.fake.logins, 1)
        self.fake.drop_session_once = True  # сессия «истекла»: 404 до повторного логина
        self.assertIsNone(self.panel.find_client("nobody@example.com"))
        self.assertEqual(self.fake.logins, 2)

    def test_wrong_password_raises_auth_error(self):
        cfg = real_config(self.fake, XUI_PASSWORD="wrong-password")
        with self.assertRaises(PanelAuthError):
            XuiPanel(cfg).ensure_client(email="user@example.com")

    def test_self_signed_tls_option(self):
        self.assertEqual(self.panel._ssl_context.verify_mode, ssl.CERT_NONE)
        strict = XuiPanel(real_config(self.fake, XUI_VERIFY_TLS="1"))
        self.assertEqual(strict._ssl_context.verify_mode, ssl.CERT_REQUIRED)


class ModernApiTest(unittest.TestCase):
    def setUp(self) -> None:
        self.fake = Fake3xui(mode="modern")
        self.addCleanup(self.fake.close)

    def test_bearer_token_and_modern_endpoints(self):
        cfg = real_config(
            self.fake,
            XUI_API_TOKEN="api-token",
            XUI_CLIENT_API="auto",
        )
        panel = XuiPanel(cfg)
        result = panel.ensure_client(email="user@example.com", plan_days=0, total_gb=0)
        self.assertEqual(self.fake.logins, 0)  # Bearer вместо логина
        paths = [path for _, path in self.fake.requests]
        self.assertIn("/panel/panel/api/clients/get/user%40example.com", paths)
        self.assertIn("/panel/panel/api/clients/add", paths)
        self.assertNotIn("/panel/panel/api/inbounds/addClient", paths)
        saved = self.fake.clients["user@example.com"]["client"]
        headers = self.fake.request_headers[("POST", "/panel/panel/api/clients/add")]
        self.assertEqual(headers.get("Authorization"), "Bearer api-token")
        self.assertEqual(saved["id"], result["uuid"])
        self.assertEqual(saved["subId"], result["sub_id"])

    def test_cookie_login_and_csrf_header(self):
        cfg = real_config(self.fake, XUI_CLIENT_API="auto")
        panel = XuiPanel(cfg)
        panel.ensure_client(email="csrf@example.com")
        self.assertEqual(self.fake.logins, 1)
        headers = self.fake.request_headers[("POST", "/panel/panel/api/clients/add")]
        headers = {key.lower(): value for key, value in headers.items()}
        self.assertEqual(headers.get("x-csrf-token"), "csrf-token-123")

    def test_modern_style_is_cached(self):
        cfg = real_config(self.fake, XUI_API_TOKEN="api-token")
        panel = XuiPanel(cfg)
        panel.ensure_client(email="cache@example.com")
        detection_calls = [path for _, path in self.fake.requests
                           if path.endswith("/clients/get/cache%40example.com")]
        self.assertEqual(len(detection_calls), 2)  # определение стиля + поиск клиента
        panel.ensure_client(email="cache@example.com")
        detection_calls = [path for _, path in self.fake.requests
                           if path.endswith("/clients/get/cache%40example.com")]
        self.assertEqual(len(detection_calls), 3)  # второй ensure: только поиск


class NormClientTest(unittest.TestCase):
    def test_legacy_norm_prefers_stats_and_keeps_client_fields(self):
        client = {"id": "uuid-1", "email": "a@b.cd", "subId": "sub-1", "totalGB": 10, "enable": True}
        stats = {"uuid": "uuid-1", "subId": "sub-1", "up": 100, "down": 50,
                 "total": 1000, "expiryTime": 1790000000000, "enable": True}
        result = _norm_client(client, stats, inbound_id=7)
        self.assertEqual(result["up"], 100)
        self.assertEqual(result["down"], 50)
        self.assertEqual(result["total"], 1000)
        self.assertEqual(result["expiry_time_ms"], 1790000000000)
        self.assertEqual(result["inbound_id"], 7)


if __name__ == "__main__":
    unittest.main()
