"""Общая обвязка тестов: запуск API на свободном порту + HTTP-клиент."""

from __future__ import annotations

import json
import logging
import os
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

SERVER_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if SERVER_DIR not in sys.path:
    sys.path.insert(0, SERVER_DIR)

from activation.api import ActivationApi  # noqa: E402
from activation.config import Config  # noqa: E402
from activation.timeutil import ISO_FMT  # noqa: E402

ADMIN_TOKEN = "test-admin-token-0123456789abcdef"
PEPPER = "test-pepper-0123456789abcdef"

DEFAULT_ENV = {
    "ADMIN_TOKEN": ADMIN_TOKEN,
    "CODE_PEPPER": PEPPER,
    "XUI_MODE": "mock",
    "SUB_URL_TEMPLATE": "https://vpn.example.com:2096/subpath/{sub_id}",
    "CODE_TTL_SECONDS": "86400",
    "PLAN_DAYS": "30",
    "PLAN_TOTAL_GB": "10",
    "MAX_CODE_ATTEMPTS": "10",
    "RATE_ACTIVATE_PER_MIN": "100",
    "RATE_ADMIN_PER_MIN": "100",
    "LOG_LEVEL": "ERROR",
}


class FakeClock:
    """Управляемые «часы» для проверки TTL и протухания кодов."""

    def __init__(self, iso: str = "2026-11-01T00:00:00Z"):
        self.iso = iso

    def __call__(self) -> str:
        return self.iso

    def advance(self, seconds: int) -> None:
        moment = datetime.strptime(self.iso, ISO_FMT).replace(tzinfo=timezone.utc)
        self.iso = (moment + timedelta(seconds=seconds)).strftime(ISO_FMT)


class ApiTestCase(unittest.TestCase):
    EXTRA_ENV: dict = {}

    def setUp(self) -> None:
        logging.getLogger("activation").setLevel(logging.ERROR)
        self.tmp = tempfile.TemporaryDirectory(prefix="activation-test-")
        env = dict(DEFAULT_ENV)
        env["DB_PATH"] = os.path.join(self.tmp.name, "test.db")
        env.update(self.EXTRA_ENV)
        self.cfg = Config.from_env(env)
        self.api = ActivationApi(self.cfg)
        self.clock = FakeClock()
        self.api.store._clock = self.clock  # управляемое время
        self.httpd = self.api.make_server("127.0.0.1", 0)
        self.base = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        self._thread = threading.Thread(
            target=lambda: self.httpd.serve_forever(poll_interval=0.02), daemon=True
        )
        self._thread.start()
        # ждём, пока сервер начнёт принимать соединения
        deadline = time.time() + 5
        while time.time() < deadline:
            try:
                self.request("GET", "/health")
                break
            except (urllib.error.URLError, OSError):
                time.sleep(0.02)

    def tearDown(self) -> None:
        self.httpd.shutdown()
        self.httpd.server_close()
        self._thread.join(timeout=5)
        self.api.close()
        self.tmp.cleanup()

    # ------------------------------------------------------------- HTTP
    def request(self, method, path, payload=None, *, token=None, headers=None, timeout=5):
        url = self.base + path
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8") if payload is not None else None
        request_headers = {"Accept": "application/json"}
        if data is not None:
            request_headers["Content-Type"] = "application/json"
        if token is not None:
            request_headers["Authorization"] = "Bearer " + token
        request_headers.update(headers or {})
        request = urllib.request.Request(url, data=data, headers=request_headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                raw = response.read()
                return response.status, (json.loads(raw.decode()) if raw else {}), dict(response.headers)
        except urllib.error.HTTPError as error:
            raw = error.read()
            try:
                body = json.loads(raw.decode()) if raw else {}
            except ValueError:
                body = {"raw": raw.decode("utf-8", "replace")}
            return error.code, body, dict(error.headers)

    # ------------------------------------------------------------- сценарии
    def create_code(self, email: str = "client@example.com", **extra) -> dict:
        payload = {"email": email}
        payload.update(extra)
        status, body, _ = self.request("POST", "/v1/codes", payload, token=ADMIN_TOKEN)
        self.assertEqual(status, 201, body)
        return body

    def activate(self, code: str, device_id: str = "device-aaa-111"):
        return self.request("POST", "/v1/activate", {"code": code, "device_id": device_id})
