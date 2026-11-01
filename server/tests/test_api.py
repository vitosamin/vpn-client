"""Тесты HTTP API сервиса активации (без сети и без реальной панели)."""

from __future__ import annotations

import json
import os
import sqlite3
import unittest

from activation.config import Config, ConfigError
from activation.store import hash_code
from activation.xui import PanelUnavailable
from tests.helpers import ADMIN_TOKEN, PEPPER, ApiTestCase


class ConfigTest(unittest.TestCase):
    def setUp(self):
        import logging

        logging.disable(logging.CRITICAL)

    def tearDown(self):
        import logging

        logging.disable(logging.NOTSET)

    def test_real_mode_requires_panel_settings(self):
        with self.assertRaises(ConfigError):
            Config.from_env({"XUI_MODE": "real"})
        with self.assertRaises(ConfigError):
            Config.from_env(
                {"XUI_MODE": "real", "XUI_BASE_URL": "https://panel.example.com:2053"}
            )

    def test_sub_url_template_requires_sub_id(self):
        with self.assertRaises(ConfigError):
            Config.from_env(
                {"XUI_MODE": "mock", "SUB_URL_TEMPLATE": "https://vpn.example.com/sub/"}
            )

    def test_bad_boolean_and_number(self):
        with self.assertRaises(ConfigError):
            Config.from_env({"XUI_MODE": "mock", "XUI_VERIFY_TLS": "maybe"})
        with self.assertRaises(ConfigError):
            Config.from_env({"XUI_MODE": "mock", "APP_PORT": "not-a-port"})

    def test_admin_disabled_without_token(self):
        cfg = Config.from_env({"XUI_MODE": "mock", "CODE_PEPPER": PEPPER})
        self.assertFalse(cfg.admin_enabled)


class HealthTest(ApiTestCase):
    def test_health_ok_without_auth(self):
        status, body, _ = self.request("GET", "/health")
        self.assertEqual(status, 200)
        self.assertEqual(body["status"], "ok")
        self.assertEqual(body["mode"], "mock")
        self.assertEqual(body["time"], "2026-11-01T00:00:00Z")

    def test_unknown_path_and_method(self):
        status, body, _ = self.request("GET", "/v1/nope")
        self.assertEqual(status, 404)
        self.assertEqual(body["error"], "not_found")
        status, body, _ = self.request("PUT", "/v1/activate", {})
        self.assertEqual(status, 405)
        self.assertEqual(body["error"], "method_not_allowed")


class AdminAuthTest(ApiTestCase):
    def test_admin_requires_bearer(self):
        status, body, headers = self.request("POST", "/v1/codes", {"email": "a@b.cd"})
        self.assertEqual(status, 401)
        self.assertEqual(body["error"], "unauthorized")
        self.assertIn("WWW-Authenticate", headers)

    def test_admin_rejects_wrong_token(self):
        status, body, _ = self.request(
            "POST", "/v1/codes", {"email": "a@b.cd"}, token="wrong-token"
        )
        self.assertEqual(status, 401)
        self.assertEqual(body["error"], "unauthorized")

class AdminDisabledTest(ApiTestCase):
    EXTRA_ENV = {"ADMIN_TOKEN": ""}

    def test_admin_endpoints_disabled_without_token(self):
        status, body, _ = self.request("POST", "/v1/codes", {"email": "a@b.cd"})
        self.assertEqual(status, 503)
        self.assertEqual(body["error"], "admin_disabled")


class CreateCodeTest(ApiTestCase):
    def test_create_code_returns_plaintext_once_and_stores_hash(self):
        info = self.create_code("user@example.com", plan={"days": 30, "total_gb": 10})
        code = info["code"]
        self.assertGreaterEqual(len(code), 16)
        self.assertEqual(info["client_email"], "user@example.com")
        self.assertEqual(info["plan"], {"days": 30, "total_gb": 10})
        self.assertEqual(info["expires_at"], "2026-11-02T00:00:00Z")

        # В БД нет ни открытого кода, ни pepper, ни admin-token.
        connection = sqlite3.connect(self.cfg.db_path)
        try:
            dump = "\n".join(
                str(row)
                for table in ("codes", "audit")
                for row in connection.execute(f"SELECT * FROM {table}")
            )
        finally:
            connection.close()
        self.assertNotIn(code, dump)
        self.assertNotIn(PEPPER, dump)
        self.assertNotIn(ADMIN_TOKEN, dump)
        self.assertIn(hash_code(code, PEPPER), dump)

    def test_new_code_revokes_previous_pending_code(self):
        first = self.create_code("dup@example.com")
        second = self.create_code("dup@example.com")
        status, body, _ = self.activate(first["code"])
        self.assertEqual(status, 403)
        self.assertEqual(body["error"], "code_revoked")
        status, body, _ = self.activate(second["code"])
        self.assertEqual(status, 200, body)

    def test_get_code_status_by_code(self):
        info = self.create_code()
        status, body, _ = self.request("GET", "/v1/codes/" + info["code"], token=ADMIN_TOKEN)
        self.assertEqual(status, 200)
        self.assertEqual(body["status"], "pending")
        self.assertEqual(body["attempts"], 0)
        self.assertNotIn("sub_url", body)

    def test_get_unknown_code_404(self):
        status, body, _ = self.request("GET", "/v1/codes/UNKNOWNCODE123", token=ADMIN_TOKEN)
        self.assertEqual(status, 404)
        self.assertEqual(body["error"], "code_not_found")

    def test_create_code_validation(self):
        cases = [
            ({}, 400),
            ({"email": "not-an-email"}, 400),
            ({"email": "a@b.cd", "plan": {"days": -1}}, 400),
            ({"email": "a@b.cd", "plan": {"days": 99999}}, 400),
            ({"email": "a@b.cd", "ttl_seconds": 5}, 400),
            ({"email": "a@b.cd", "ttl_seconds": 10 * 24 * 60 * 60 * 30}, 400),
            ({"email": "a@b.cd", "client_uuid": "not-a-uuid"}, 400),
        ]
        for payload, expected in cases:
            status, body, _ = self.request("POST", "/v1/codes", payload, token=ADMIN_TOKEN)
            self.assertEqual(status, expected, (payload, body))


class ActivateTest(ApiTestCase):
    def test_activation_returns_sub_url_and_plan(self):
        info = self.create_code("client@example.com", plan={"days": 30, "total_gb": 10})
        status, body, _ = self.activate(info["code"], "device-1")
        self.assertEqual(status, 200, body)
        self.assertFalse(body["idempotent"])
        self.assertIn("/subpath/", body["sub_url"])
        self.assertEqual(body["profile_name"], "client@example.com")
        self.assertEqual(body["expire"], "2026-12-01T00:00:00Z")
        self.assertEqual(body["traffic"]["total_bytes"], 10 * 1024**3)
        self.assertFalse(body["traffic"]["unlimited"])
        self.assertEqual(body["traffic"]["used_bytes"], 0)
        self.assertTrue(body["client_uuid"])

        # статус кода теперь active
        status, status_body, _ = self.request(
            "GET", "/v1/codes/" + info["code"], token=ADMIN_TOKEN
        )
        self.assertEqual(status_body["status"], "active")
        self.assertEqual(status_body["device_id"], "device-1")

    def test_unlimited_traffic(self):
        info = self.create_code(plan={"days": 0, "total_gb": 0})
        status, body, _ = self.activate(info["code"])
        self.assertEqual(status, 200, body)
        self.assertIsNone(body["expire"])
        self.assertTrue(body["traffic"]["unlimited"])
        self.assertEqual(body["traffic"]["total_bytes"], 0)

    def test_idempotent_activation_same_device(self):
        info = self.create_code()
        status, first, _ = self.activate(info["code"], "device-1")
        self.assertEqual(status, 200)
        status, second, _ = self.activate(info["code"], "device-1")
        self.assertEqual(status, 200)
        self.assertTrue(second["idempotent"])
        self.assertEqual(second["sub_url"], first["sub_url"])
        self.assertEqual(second["client_uuid"], first["client_uuid"])

    def test_activation_from_other_device_conflict(self):
        info = self.create_code()
        self.assertEqual(self.activate(info["code"], "device-1")[0], 200)
        status, body, _ = self.activate(info["code"], "device-2")
        self.assertEqual(status, 409)
        self.assertEqual(body["error"], "code_already_used")
        # первое устройство по-прежнему получает ту же ссылку
        status, body, _ = self.activate(info["code"], "device-1")
        self.assertEqual(status, 200)
        self.assertTrue(body["idempotent"])

    def test_unknown_code_404(self):
        status, body, _ = self.activate("UNKNOWNCODE123")
        self.assertEqual(status, 404)
        self.assertEqual(body["error"], "code_not_found")

    def test_expired_code_410(self):
        info = self.create_code()
        self.clock.advance(86400)  # TTL истёк
        status, body, _ = self.activate(info["code"])
        self.assertEqual(status, 410)
        self.assertEqual(body["error"], "code_expired")
        status, status_body, _ = self.request(
            "GET", "/v1/codes/" + info["code"], token=ADMIN_TOKEN
        )
        self.assertEqual(status_body["status"], "expired")

    def test_malformed_requests(self):
        for payload in ({}, {"code": "x"}, {"code": "x" * 300, "device_id": "d"}):
            status, body, _ = self.request("POST", "/v1/activate", payload)
            self.assertEqual(status, 400, (payload, body))
            self.assertEqual(body["error"], "invalid_request")

    def test_activation_retries_after_panel_failure(self):
        info = self.create_code()
        self.api.panel = FlakyPanel(self.api.panel, failing=True)
        status, body, _ = self.activate(info["code"], "device-1")
        self.assertEqual(status, 502)
        self.assertEqual(body["error"], "panel_unavailable")
        # код остался доступным для повтора
        status, status_body, _ = self.request(
            "GET", "/v1/codes/" + info["code"], token=ADMIN_TOKEN
        )
        self.assertEqual(status_body["status"], "pending")
        self.api.panel.failing = False
        status, body, _ = self.activate(info["code"], "device-1")
        self.assertEqual(status, 200, body)

    def test_stale_activation_can_be_retried(self):
        info = self.create_code()
        row = self.api.store.get_by_hash(hash_code(info["code"], PEPPER))
        self.assertTrue(self.api.store.claim(row["id"], "device-1", self.clock()))
        status, body, _ = self.activate(info["code"], "device-1")
        self.assertEqual(status, 409)
        self.assertEqual(body["error"], "activation_in_progress")
        self.clock.advance(self.cfg.provisioning_stale_seconds + 1)
        status, body, _ = self.activate(info["code"], "device-1")
        self.assertEqual(status, 200, body)

    def test_preprovisioned_client_is_reused(self):
        email = "already@example.com"
        seeded = self.api.panel.seed(
            email, client_uuid="11111111-2222-3333-4444-555555555555", sub_id="seedsubid12345678"
        )
        info = self.create_code(email)
        status, body, _ = self.activate(info["code"])
        self.assertEqual(status, 200, body)
        self.assertEqual(body["client_uuid"], seeded["uuid"])
        self.assertTrue(body["sub_url"].endswith(seeded["sub_id"]))


class AttemptsLockTest(ApiTestCase):
    EXTRA_ENV = {"MAX_CODE_ATTEMPTS": "3"}

    def test_code_locked_after_attempts_from_other_devices(self):
        info = self.create_code()
        self.assertEqual(self.activate(info["code"], "device-1")[0], 200)
        self.assertEqual(self.activate(info["code"], "device-2")[0], 409)
        self.assertEqual(self.activate(info["code"], "device-3")[0], 409)
        status, body, _ = self.activate(info["code"], "device-4")
        self.assertEqual(status, 423)
        self.assertEqual(body["error"], "code_locked")
        # даже владелец устройства больше не пройдёт
        self.assertEqual(self.activate(info["code"], "device-1")[0], 423)


class RateLimitTest(ApiTestCase):
    EXTRA_ENV = {"RATE_ACTIVATE_PER_MIN": "2"}

    def test_activate_rate_limited(self):
        self.assertEqual(self.activate("UNKNOWNCODE123")[0], 404)
        self.assertEqual(self.activate("UNKNOWNCODE124")[0], 404)
        status, body, headers = self.activate("UNKNOWNCODE125")
        self.assertEqual(status, 429)
        self.assertEqual(body["error"], "rate_limited")
        self.assertIn("Retry-After", headers)


class LogPrivacyTest(ApiTestCase):
    def test_logs_do_not_leak_code_token_or_sub_url(self):
        info = self.create_code()
        code = info["code"]
        with self.assertLogs("activation", level="INFO") as captured:
            self.activate(code)
            self.request("GET", "/v1/codes/" + code, token=ADMIN_TOKEN)
        text = "\n".join(captured.output)
        self.assertNotIn(code, text)
        self.assertNotIn(ADMIN_TOKEN, text)
        self.assertNotIn("https://vpn.example.com", text)


class FlakyPanel:
    """Обёртка над mock-панелью, которая умеет «падать»."""

    def __init__(self, inner, *, failing: bool = False):
        self.inner = inner
        self.failing = failing

    def ensure_client(self, **kwargs):
        if self.failing:
            raise PanelUnavailable("тестовая ошибка панели")
        return self.inner.ensure_client(**kwargs)

    def get_traffic(self, email):
        return self.inner.get_traffic(email)

    def sub_url(self, sub_id):
        return self.inner.sub_url(sub_id)
