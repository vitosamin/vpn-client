"""Клиент API панели 3x-ui и mock-адаптер.

Реальные эндпоинты (классика, 3x-ui 2.x–3.x):
    POST /login                                   — форма username/password, cookie-сессия
    GET  /panel/api/inbounds/list                 — список инбаундов с clientStats
    POST /panel/api/inbounds/addClient            — {"id": inbound, "settings": "<json>"}
    POST /panel/api/inbounds/updateClient/<uuid>  — тот же формат, что addClient
    GET  /panel/api/inbounds/getClientTraffics/<email>

Свежие 3.x: те же операции через /panel/api/clients/{add,get/<email>,traffic/<email>}
и Bearer API Token. Режим XUI_CLIENT_API=auto сам определяет, какие эндпоинты есть.

3x-ui не генерирует subId для клиентов, созданных через API (issue #3237),
поэтому subId генерируем сами и передаём в addClient.
"""

from __future__ import annotations

import json
import logging
import secrets
import ssl
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

from . import timeutil

log = logging.getLogger("activation.xui")

GIB = 1024**3
MAX_RESPONSE = 4 * 1024 * 1024


class PanelError(Exception):
    """Ошибка панели, при которой активацию можно повторить позже."""

    retryable = True


class PanelAuthError(PanelError):
    """Не удалось войти в панель (неверные креды/2FA/нет прав)."""

    retryable = False


class PanelUnavailable(PanelError):
    """Панель недоступна (сеть, TLS, 5xx)."""


class PanelClientNotFound(PanelError):
    """Клиента с таким email нет в панели."""


class _EndpointMissing(Exception):
    """HTTP 404 на эндпоинт панели (панель другой версии или сессия истекла)."""


def _norm_modern_client(obj: dict) -> dict:
    traffic = obj.get("traffic") if isinstance(obj.get("traffic"), dict) else {}
    return {
        "email": obj.get("email") or "",
        "uuid": str(obj.get("uuid") or obj.get("id") or ""),
        "sub_id": obj.get("subId") or "",
        "up": int(traffic.get("up") or 0),
        "down": int(traffic.get("down") or 0),
        "total": int(obj.get("totalGB") or traffic.get("total") or 0),
        "expiry_time_ms": int(obj.get("expiryTime") or traffic.get("expiryTime") or 0),
        "enable": bool(obj.get("enable", True)),
    }


def _norm_client(client: dict, stats: dict | None, inbound_id=None) -> dict:
    stats = stats or {}
    return {
        "email": client.get("email") or stats.get("email") or "",
        "uuid": stats.get("uuid") or client.get("id") or "",
        "sub_id": client.get("subId") or stats.get("subId") or "",
        "up": int(stats.get("up") or 0),
        "down": int(stats.get("down") or 0),
        "total": int(stats.get("total") or client.get("totalGB") or 0),
        "expiry_time_ms": int(stats.get("expiryTime") or client.get("expiryTime") or 0),
        "enable": bool(stats.get("enable", client.get("enable", True))),
        "inbound_id": inbound_id,
    }


def _norm_traffic(obj: dict) -> dict:
    return {
        "email": obj.get("email") or "",
        "uuid": obj.get("uuid") or "",
        "sub_id": obj.get("subId") or "",
        "up": int(obj.get("up") or 0),
        "down": int(obj.get("down") or 0),
        "total": int(obj.get("total") or 0),
        "expiry_time_ms": int(obj.get("expiryTime") or 0),
        "enable": bool(obj.get("enable", True)),
    }


class MockPanel:
    """Фейковая панель: тесты и локальная разработка без 3x-ui."""

    mode = "mock"

    def __init__(self, cfg, clock=None):
        self.cfg = cfg
        self._clients: dict[str, dict] = {}
        self._lock = threading.Lock()
        self._clock = clock or timeutil.utcnow_iso

    # для тестов и ручной настройки
    def seed(self, email: str, *, client_uuid: str | None = None, sub_id: str | None = None,
             plan_days: int = 0, total_gb: float = 0.0) -> dict:
        with self._lock:
            client = self._make(email, client_uuid, sub_id, plan_days, total_gb)
            self._clients[email] = client
            return dict(client)

    def _make(self, email, client_uuid, sub_id, plan_days, total_gb) -> dict:
        expiry_ms = 0
        if plan_days > 0:
            expiry_ms = (timeutil.epoch_from_iso(self._clock()) + plan_days * 86400) * 1000
        return {
            "email": email,
            "uuid": client_uuid or str(uuid.uuid4()),
            "sub_id": sub_id or secrets.token_hex(8),
            "up": 0,
            "down": 0,
            "total": int(round(float(total_gb) * GIB)),
            "expiry_time_ms": expiry_ms,
            "enable": True,
        }

    def ensure_client(self, *, email, client_uuid=None, sub_id=None, plan_days=0, total_gb=0.0):
        with self._lock:
            if email not in self._clients:
                self._clients[email] = self._make(email, client_uuid, sub_id, plan_days, total_gb)
            return dict(self._clients[email])

    def get_traffic(self, email: str) -> dict:
        with self._lock:
            client = self._clients.get(email)
        if not client:
            raise PanelClientNotFound(f"клиент {email} не найден в mock-панели")
        return dict(client)

    def sub_url(self, sub_id: str) -> str:
        return self.cfg.sub_url_template.format(sub_id=sub_id)


class XuiPanel:
    """Реальный клиент панели 3x-ui (REST API)."""

    mode = "real"

    def __init__(self, cfg):
        self.cfg = cfg
        self._root = cfg.xui_base_url.rstrip("/") + cfg.xui_web_base_path.rstrip("/")
        self._style = None if cfg.xui_client_api == "auto" else cfg.xui_client_api
        self._logged_in = bool(cfg.xui_api_token)
        self._csrf: str | None = None
        self._lock = threading.Lock()
        self._jar = urllib.request.HTTPCookieProcessor()
        self._ssl_context = ssl.create_default_context()
        if not cfg.xui_verify_tls:
            self._ssl_context.check_hostname = False
            self._ssl_context.verify_mode = ssl.CERT_NONE
        self._opener = urllib.request.build_opener(
            urllib.request.HTTPSHandler(context=self._ssl_context), self._jar
        )

    # --------------------------------------------------------------- низкий уровень
    def _raw(self, method: str, url: str, data: bytes | None = None, headers=None):
        request = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
        try:
            with self._opener.open(request, timeout=self.cfg.xui_timeout) as response:
                return response.status, response.read(MAX_RESPONSE)
        except urllib.error.HTTPError as error:
            try:
                body = error.read(MAX_RESPONSE)
            except Exception:  # noqa: BLE001 - тело ошибки не критично
                body = b""
            return error.code, body
        except (urllib.error.URLError, TimeoutError, ssl.SSLError, OSError) as error:
            raise PanelUnavailable(f"панель недоступна: {error.__class__.__name__}") from None

    def _headers(self, json_body: bool = False) -> dict:
        headers = {"Accept": "application/json", "User-Agent": "vpn-activation/1.0"}
        if self.cfg.xui_api_token:
            headers["Authorization"] = "Bearer " + self.cfg.xui_api_token
        if self._csrf:
            headers["X-CSRF-Token"] = self._csrf
        if json_body:
            headers["Content-Type"] = "application/json"
        return headers

    @staticmethod
    def _json(raw: bytes):
        try:
            return json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            return None

    def _login(self) -> None:
        if self._logged_in:
            return
        with self._lock:
            if self._logged_in:
                return
            creds = {"username": self.cfg.xui_username, "password": self.cfg.xui_password}
            # Классические панели ждут form-urlencoded, свежие принимают JSON.
            data = urllib.parse.urlencode(creds).encode()
            headers = {"Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"}
            status, raw = self._raw("POST", self._root + "/login", data, headers)
            payload = self._json(raw)
            if not (payload and payload.get("success")):
                body = json.dumps(creds).encode()
                headers = {"Content-Type": "application/json", "Accept": "application/json"}
                status, raw = self._raw("POST", self._root + "/login", body, headers)
                payload = self._json(raw)
            if not (payload and payload.get("success")):
                msg = (payload or {}).get("msg") or f"HTTP {status}"
                raise PanelAuthError(f"вход в панель не удался: {str(msg)[:200]}")
            self._logged_in = True
            self._csrf = self._fetch_csrf()
            log.info("3x-ui: вход в панель выполнен")

    def _relogin(self) -> None:
        with self._lock:
            self._logged_in = False
            self._csrf = None
        self._login()

    def _fetch_csrf(self) -> str | None:
        """CSRF-токен нужен свежим 3.x для cookie-сессии; в старых панелях его нет."""
        try:
            status, raw = self._raw("GET", self._root + "/csrf-token", headers=self._headers())
        except PanelError:
            return None
        if status != 200:
            return None
        payload = self._json(raw)
        token = payload.get("obj") if isinstance(payload, dict) and payload.get("success") else None
        return token if isinstance(token, str) and token else None

    def _request(self, method: str, url: str, json_body=None) -> dict:
        data = json.dumps(json_body, ensure_ascii=False).encode() if json_body is not None else None
        status, raw = self._raw(method, url, data, self._headers(json_body is not None))
        if status in (401, 403):
            raise PanelAuthError(f"панель отклонила запрос: HTTP {status}")
        if status == 404:
            raise _EndpointMissing(url)
        if status >= 500:
            raise PanelUnavailable(f"панель вернула HTTP {status}")
        if status >= 400:
            raise PanelError(f"панель вернула HTTP {status}")
        payload = self._json(raw)
        if payload is None:
            raise PanelUnavailable("панель вернула не-JSON ответ")
        return payload

    def _ensure_style(self, email: str) -> None:
        """Определить раскладку API панели: legacy /inbounds/* или modern /clients/*."""
        if self._style:
            return
        self._login()
        probe = urllib.parse.quote(email, safe="")
        try:
            self._request("GET", f"{self._root}/panel/api/clients/get/{probe}")
        except _EndpointMissing:
            self._style = "legacy"
        else:
            self._style = "modern"
        log.info("3x-ui: используется API-раскладка %s", self._style)

    def _api(self, method: str, path: str, json_body=None) -> dict:
        self._login()
        try:
            return self._request(method, self._root + path, json_body)
        except _EndpointMissing:
            # Сессия могла истечь: старые панели отвечают 404 вместо 401.
            if self.cfg.xui_api_token:
                raise
            self._relogin()
            return self._request(method, self._root + path, json_body)

    # --------------------------------------------------------------- операции
    def find_client(self, email: str) -> dict | None:
        self._login()
        self._ensure_style(email)
        if self._style == "modern":
            try:
                payload = self._api(
                    "GET", f"/panel/api/clients/get/{urllib.parse.quote(email, safe='')}"
                )
            except _EndpointMissing:
                self._style = "legacy"
            else:
                obj = payload.get("obj") if isinstance(payload, dict) else None
                if payload.get("success") and isinstance(obj, dict) and obj.get("email"):
                    return _norm_modern_client(obj)
                return None
        try:
            payload = self._api("GET", "/panel/api/inbounds/list")
        except _EndpointMissing:
            raise PanelUnavailable(
                "API панели не найдено: проверь XUI_BASE_URL, XUI_WEB_BASE_PATH и XUI_CLIENT_API"
            ) from None
        if not isinstance(payload, dict) or not payload.get("success"):
            msg = (payload or {}).get("msg") if isinstance(payload, dict) else ""
            raise PanelError(f"панель не отдала список инбаундов: {str(msg)[:200]}")
        for inbound in payload.get("obj") or []:
            settings = inbound.get("settings")
            if isinstance(settings, str):
                try:
                    settings = json.loads(settings or "{}")
                except ValueError:
                    settings = {}
            for client in (settings or {}).get("clients") or []:
                if isinstance(client, dict) and client.get("email") == email:
                    stats = next(
                        (item for item in inbound.get("clientStats") or []
                         if item.get("email") == email),
                        {},
                    )
                    return _norm_client(client, stats, inbound.get("id"))
        return None

    def add_client(self, *, email: str, client_uuid: str, sub_id: str,
                   plan_days: int, total_gb: float) -> None:
        self._login()
        self._ensure_style(email)
        expiry_ms = 0
        if plan_days > 0:
            expiry_ms = (int(time.time()) + plan_days * 86400) * 1000
        client = {
            "id": client_uuid,
            "email": email,
            "subId": sub_id,
            "flow": self.cfg.xui_client_flow,
            "limitIp": 0,
            "totalGB": int(round(float(total_gb) * GIB)),
            "expiryTime": expiry_ms,
            "enable": True,
            "tgId": 0,
            "reset": 0,
        }
        try:
            if self._style == "modern":
                payload = self._api(
                    "POST",
                    "/panel/api/clients/add",
                    {"client": client, "inboundIds": [self.cfg.xui_inbound_id]},
                )
            else:
                payload = self._api(
                    "POST",
                    "/panel/api/inbounds/addClient",
                    {
                        "id": self.cfg.xui_inbound_id,
                        "settings": json.dumps({"clients": [client]}, ensure_ascii=False),
                    },
                )
        except _EndpointMissing:
            raise PanelUnavailable(
                "эндпоинт создания клиента не найден: проверь XUI_CLIENT_API/версию панели"
            ) from None
        if not isinstance(payload, dict) or not payload.get("success"):
            msg = (payload or {}).get("msg") if isinstance(payload, dict) else ""
            raise PanelError(f"панель не создала клиента: {str(msg)[:200] or 'unknown error'}")

    def get_traffic(self, email: str) -> dict:
        self._login()
        self._ensure_style(email)
        quoted = urllib.parse.quote(email, safe="")
        try:
            if self._style == "modern":
                payload = self._api("GET", f"/panel/api/clients/traffic/{quoted}")
                obj = payload.get("obj") if isinstance(payload, dict) else None
                if payload.get("success") and isinstance(obj, dict) and obj.get("email"):
                    return _norm_traffic(obj)
                raise PanelClientNotFound(f"клиент {email} не найден в панели")
            payload = self._api("GET", f"/panel/api/inbounds/getClientTraffics/{quoted}")
        except _EndpointMissing:
            raise PanelUnavailable(
                "эндпоинт трафика не найден: проверь XUI_CLIENT_API/версию панели"
            ) from None
        obj = payload.get("obj") if isinstance(payload, dict) else None
        if payload.get("success") and isinstance(obj, dict):
            return _norm_traffic(obj)
        raise PanelClientNotFound(f"клиент {email} не найден в панели")

    def ensure_client(self, *, email, client_uuid=None, sub_id=None, plan_days=0, total_gb=0.0):
        found = self.find_client(email)
        if found:
            return found
        client_uuid = client_uuid or str(uuid.uuid4())
        sub_id = sub_id or secrets.token_hex(8)
        try:
            self.add_client(
                email=email, client_uuid=client_uuid, sub_id=sub_id,
                plan_days=plan_days, total_gb=total_gb,
            )
        except PanelError as error:
            if "duplicate" in str(error).lower():
                found = self.find_client(email)
                if found:
                    return found
            raise
        try:
            traffic = self.get_traffic(email)
        except PanelClientNotFound:
            traffic = {}
        return {
            "email": email,
            "uuid": traffic.get("uuid") or client_uuid,
            "sub_id": traffic.get("sub_id") or sub_id,
            "up": int(traffic.get("up") or 0),
            "down": int(traffic.get("down") or 0),
            "total": int(traffic.get("total") or 0),
            "expiry_time_ms": int(traffic.get("expiry_time_ms") or 0),
            "enable": traffic.get("enable", True),
        }

    def sub_url(self, sub_id: str) -> str:
        return self.cfg.sub_url_template.format(sub_id=sub_id)


def build_panel(cfg, clock=None):
    if cfg.xui_mode == "mock":
        return MockPanel(cfg, clock=clock)
    return XuiPanel(cfg)
