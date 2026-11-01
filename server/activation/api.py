"""HTTP API сервиса активации (только stdlib: http.server + sqlite3).

Публичный эндпоинт:  POST /v1/activate   {code, device_id}
Админ-эндпоинты:      POST /v1/codes      {email, plan?, ttl_seconds?}
                      GET  /v1/codes/<code>
Служебный:            GET  /health

Безопасность: код в открытом виде не хранится и не логируется; админка —
Bearer-токен; rate-limit по IP; лимит неудачных попыток на код; ответы
с Cache-Control: no-store.
"""

from __future__ import annotations

import hmac
import json
import logging
import re
import secrets
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import __version__
from .config import Config
from .store import Store, code_id_from_hash, hash_code
from .timeutil import iso_age_seconds, iso_from_ms
from .xui import PanelError, build_panel

log = logging.getLogger("activation.api")

CODE_RE = re.compile(r"^[A-Za-z0-9_-]{8,256}$")
DEVICE_RE = re.compile(r"^[A-Za-z0-9._:\-]{1,128}$")
EMAIL_RE = re.compile(r"^[^\s@]{1,64}@[^\s@]{1,190}$")
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
SUB_ID_RE = re.compile(r"^[A-Za-z0-9_-]{8,64}$")
ACTOR_RE = re.compile(r"^[A-Za-z0-9_.\-]{1,32}$")


class _HttpError(Exception):
    def __init__(self, status: int, code: str, message: str, headers: dict | None = None):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.headers = headers or {}


class RateLimiter:
    """Простой скользящий лимит в памяти процесса."""

    def __init__(self):
        self._hits: dict[str, list[float]] = {}
        self._lock = threading.Lock()

    def hit(self, key: str, limit: int, window: int) -> tuple[bool, int]:
        now = time.monotonic()
        with self._lock:
            if len(self._hits) > 10000:
                self._hits = {k: v for k, v in self._hits.items() if v and v[-1] > now - window}
            hits = [item for item in self._hits.get(key, []) if item > now - window]
            if len(hits) >= limit:
                retry_after = max(1, int(window - (now - hits[0])) + 1)
                self._hits[key] = hits
                return False, retry_after
            hits.append(now)
            self._hits[key] = hits
            return True, 0


class ActivationApi:
    def __init__(self, cfg: Config, store: Store | None = None, panel=None):
        self.cfg = cfg
        self.store = store or Store(cfg.db_path)
        self.panel = panel or build_panel(cfg, self.store.now_iso)
        self.limiter = RateLimiter()
        self._handler_cls = type("ActivationHandler", (ApiHandler,), {"app": self})
        self._httpd: ThreadingHTTPServer | None = None

    def make_server(self, host: str | None = None, port: int | None = None) -> ThreadingHTTPServer:
        self._httpd = ThreadingHTTPServer(
            (host or self.cfg.host, self.cfg.port if port is None else port),
            self._handler_cls,
        )
        self._httpd.daemon_threads = True
        return self._httpd

    def serve_forever(self, host: str | None = None, port: int | None = None) -> None:
        httpd = self.make_server(host, port)
        log.info("сервис активации слушает http://%s:%s", *httpd.server_address[:2])
        try:
            httpd.serve_forever()
        finally:
            httpd.server_close()
            self.close()

    def close(self) -> None:
        self.store.close()


class ApiHandler(BaseHTTPRequestHandler):
    app: ActivationApi  # подставляется в ActivationApi
    server_version = "vpn-activation/" + __version__
    sys_version = ""
    protocol_version = "HTTP/1.1"

    # ------------------------------------------------------------------ роутинг
    def do_GET(self):  # noqa: N802 - имена задаёт BaseHTTPRequestHandler
        self._dispatch("GET")

    def do_POST(self):  # noqa: N802
        self._dispatch("POST")

    def do_PUT(self):  # noqa: N802
        self._dispatch("PUT")

    def do_PATCH(self):  # noqa: N802
        self._dispatch("PATCH")

    def do_DELETE(self):  # noqa: N802
        self._dispatch("DELETE")

    def do_HEAD(self):  # noqa: N802
        self._dispatch("HEAD")

    def do_OPTIONS(self):  # noqa: N802
        self._dispatch("OPTIONS")

    def log_message(self, fmt, *args):  # noqa: A003 - заглушаем дефолтный лог
        pass

    def _dispatch(self, method: str) -> None:
        started = time.monotonic()
        path = urllib.parse.urlsplit(self.path).path
        self._status = 500
        try:
            self._route(method, path)
        except _HttpError as error:
            self._send_error(error.status, error.code, error.message, error.headers)
        except Exception:  # noqa: BLE001 - последний рубеж, наружу не отдаём детали
            log.exception("необработанная ошибка на %s %s", method, self._redact(path))
            self._send_error(500, "internal_error", "Внутренняя ошибка сервера")
        finally:
            log.info(
                "%s %s -> %s за %.3f с, ip=%s",
                method,
                self._redact(path),
                self._status,
                time.monotonic() - started,
                self._client_ip(),
            )

    def _route(self, method: str, path: str) -> None:
        if path == "/health":
            self._allow(method, "GET")
            self._health()
        elif path == "/v1/activate":
            self._allow(method, "POST")
            self._activate()
        elif path == "/v1/codes":
            self._allow(method, "POST")
            self._create_code()
        elif path.startswith("/v1/codes/"):
            self._allow(method, "GET")
            self._get_code(urllib.parse.unquote(path[len("/v1/codes/"):]))
        else:
            raise _HttpError(404, "not_found", "Эндпоинт не найден")

    def _allow(self, method: str, expected: str) -> None:
        if method == expected:
            return
        if method == "OPTIONS":
            raise _HttpError(204, "ok", "", {"Allow": f"{expected}, OPTIONS"})
        raise _HttpError(405, "method_not_allowed", "Метод не поддерживается", {"Allow": expected})

    # ------------------------------------------------------------------ ответы
    def _send_json(self, status: int, payload: dict, headers: dict | None = None) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self._status = status
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if status != 204:
            self.wfile.write(body)

    def _send_error(self, status: int, code: str, message: str, headers: dict | None = None) -> None:
        if status in (204, 304):
            self._status = status
            self.send_response(status)
            for key, value in (headers or {}).items():
                self.send_header(key, value)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self._send_json(
            status,
            {"error": code, "message": message},
            headers=headers,
        )
        if status in (400, 411, 413):
            self.close_connection = True

    # ------------------------------------------------------------------ утилиты запроса
    def _client_ip(self) -> str:
        cfg = self.app.cfg
        if cfg.trust_proxy:
            forwarded = self.headers.get("X-Forwarded-For", "")
            if forwarded:
                raw = forwarded.split(",")[0].strip()
                return re.sub(r"[^0-9a-fA-F:.\-]", "", raw)[:64] or "unknown"
        return self.client_address[0]

    @staticmethod
    def _redact(path: str) -> str:
        if path.startswith("/v1/codes/"):
            return "/v1/codes/<redacted>"
        return path

    def _read_json(self) -> dict:
        cfg = self.app.cfg
        length = self.headers.get("Content-Length")
        if length is None:
            raise _HttpError(400, "invalid_request", "Нужен заголовок Content-Length")
        try:
            size = int(length)
        except ValueError:
            raise _HttpError(400, "invalid_request", "Некорректный Content-Length") from None
        if size <= 0:
            raise _HttpError(400, "invalid_request", "Пустое тело запроса")
        if size > cfg.max_body_bytes:
            raise _HttpError(413, "payload_too_large", "Тело запроса слишком большое")
        raw = self.rfile.read(size)
        try:
            payload = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            raise _HttpError(400, "invalid_request", "Тело запроса должно быть JSON-объектом") from None
        if not isinstance(payload, dict):
            raise _HttpError(400, "invalid_request", "Тело запроса должно быть JSON-объектом")
        return payload

    @staticmethod
    def _required_str(body: dict, name: str, max_len: int) -> str:
        value = body.get(name)
        if not isinstance(value, str) or not value.strip():
            raise _HttpError(400, "invalid_request", f"Поле {name} обязательно и должно быть строкой")
        value = value.strip()
        if len(value) > max_len:
            raise _HttpError(400, "invalid_request", f"Поле {name} длиннее {max_len} символов")
        return value

    @staticmethod
    def _optional_str(body: dict, name: str, max_len: int) -> str | None:
        value = body.get(name)
        if value is None:
            return None
        if not isinstance(value, str):
            raise _HttpError(400, "invalid_request", f"Поле {name} должно быть строкой")
        value = value.strip()
        if not value:
            return None
        if len(value) > max_len:
            raise _HttpError(400, "invalid_request", f"Поле {name} длиннее {max_len} символов")
        return value

    @staticmethod
    def _int_value(value, name: str, *, default: int, minimum: int, maximum: int) -> int:
        if value is None:
            return default
        if isinstance(value, bool) or not isinstance(value, int):
            raise _HttpError(400, "invalid_request", f"Поле {name} должно быть целым числом")
        if value < minimum or value > maximum:
            raise _HttpError(400, "invalid_request", f"Поле {name} должно быть в диапазоне {minimum}..{maximum}")
        return value

    @staticmethod
    def _float_value(value, name: str, *, default: float, minimum: float, maximum: float) -> float:
        if value is None:
            return default
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise _HttpError(400, "invalid_request", f"Поле {name} должно быть числом")
        value = float(value)
        if value < minimum or value > maximum:
            raise _HttpError(400, "invalid_request", f"Поле {name} должно быть в диапазоне {minimum}..{maximum}")
        return value

    # ------------------------------------------------------------------ auth
    def _require_admin(self) -> None:
        cfg = self.app.cfg
        if not cfg.admin_enabled:
            raise _HttpError(503, "admin_disabled", "Админ-доступ не настроен: задай ADMIN_TOKEN")
        header = self.headers.get("Authorization", "")
        if not header.startswith("Bearer "):
            raise _HttpError(
                401, "unauthorized", "Нужен заголовок Authorization: Bearer <admin-token>",
                {"WWW-Authenticate": "Bearer"},
            )
        token = header[len("Bearer "):].strip()
        if not hmac.compare_digest(token, cfg.admin_token):
            raise _HttpError(401, "unauthorized", "Неверный admin-token", {"WWW-Authenticate": "Bearer"})

    def _admin_rate_limit(self) -> None:
        allowed, retry_after = self.app.limiter.hit(
            "admin:" + self._client_ip(), self.app.cfg.rate_admin_per_min, 60
        )
        if not allowed:
            raise _HttpError(
                429, "rate_limited", "Слишком много запросов, попробуйте позже",
                {"Retry-After": str(retry_after)},
            )

    # ------------------------------------------------------------------ public
    def _health(self) -> None:
        try:
            self.app.store.ping()
            db_status = "ok"
        except Exception:  # noqa: BLE001 - health не должен падать
            log.exception("health: ошибка БД")
            db_status = "error"
        self._send_json(
            200,
            {
                "status": "ok" if db_status == "ok" else "degraded",
                "service": "vpn-activation",
                "version": __version__,
                "mode": self.app.cfg.xui_mode,
                "db": db_status,
                "time": self.app.store.now_iso(),
            },
        )

    def _activate(self) -> None:
        cfg = self.app.cfg
        store = self.app.store
        ip = self._client_ip()
        allowed, retry_after = self.app.limiter.hit(
            "activate:" + ip, cfg.rate_activate_per_min, 60
        )
        if not allowed:
            raise _HttpError(
                429, "rate_limited", "Слишком много попыток активации, попробуйте позже",
                {"Retry-After": str(retry_after)},
            )

        body = self._read_json()
        code = self._required_str(body, "code", 256)
        device_id = self._required_str(body, "device_id", 128)
        if not CODE_RE.match(code):
            raise _HttpError(400, "invalid_request", "Код активации имеет неверный формат")
        if not DEVICE_RE.match(device_id):
            raise _HttpError(400, "invalid_request", "device_id содержит недопустимые символы")

        code_hash = hash_code(code, cfg.code_pepper)
        code_id = code_id_from_hash(code_hash)
        row = store.get_by_hash(code_hash)
        now = store.now_iso()
        if row is None:
            store.audit("app", "activate_unknown_code", ip=ip, detail={"code_id": code_id})
            raise _HttpError(404, "code_not_found", "Код активации не найден")

        status = row["status"]
        if status == "pending" and row["expires_at"] <= now:
            store.mark_expired(row["id"])
            store.audit("app", "activate_expired_code", code_id=row["id"], ip=ip, detail={"code_id": code_id})
            raise _HttpError(410, "code_expired", "Срок действия кода истёк")
        if status == "expired":
            raise _HttpError(410, "code_expired", "Срок действия кода истёк")
        if status == "locked":
            raise _HttpError(423, "code_locked", "Код заблокирован из-за слишком большого числа попыток")
        if status == "revoked":
            raise _HttpError(403, "code_revoked", "Код отозван")

        if status == "active":
            if row["device_id"] == device_id:
                try:
                    payload = self._idempotent_result(row, code_id=code_id, device_id=device_id, ip=ip)
                except PanelError as error:
                    log.warning("код %s: идемпотентный ответ без панели: %s", code_id, str(error)[:200])
                    raise _HttpError(
                        502, "panel_unavailable", "Панель временно недоступна, повторите позже"
                    ) from None
                self._send_json(200, payload)
                return
            attempts = store.inc_attempts(row["id"])
            store.audit(
                "app", "activate_other_device", code_id=row["id"], device_id=device_id, ip=ip,
                detail={"code_id": code_id, "attempts": attempts},
            )
            if attempts >= cfg.max_code_attempts:
                store.lock_code(row["id"])
                raise _HttpError(423, "code_locked", "Код заблокирован из-за слишком большого числа попыток")
            raise _HttpError(409, "code_already_used", "Код уже активирован на другом устройстве")

        if status == "activating":
            if row["device_id"] != device_id:
                raise _HttpError(
                    409, "activation_in_progress", "Код активируется, повторите через несколько секунд",
                    {"Retry-After": "5"},
                )
            age = iso_age_seconds(now, row["used_at"]) if row["used_at"] else 0
            if age < cfg.provisioning_stale_seconds:
                raise _HttpError(
                    409, "activation_in_progress", "Активация уже идёт, повторите через несколько секунд",
                    {"Retry-After": "5"},
                )
            claimed = store.retry_stale_claim(row["id"], device_id, now)
            if not claimed:
                raise _HttpError(409, "activation_in_progress", "Активация уже идёт, повторите позже")
        elif status == "pending":
            claimed = store.claim(row["id"], device_id, now)
            if not claimed:
                raise _HttpError(409, "activation_in_progress", "Код уже активируется, повторите позже")
        else:
            raise _HttpError(500, "internal_error", "Неизвестное состояние кода")

        # Код заклеймлен (pending → activating). Создаём/находим клиента в панели.
        try:
            result = self.app.panel.ensure_client(
                email=row["client_email"],
                client_uuid=row["client_uuid"],
                sub_id=row["sub_id"],
                plan_days=row["plan_days"],
                total_gb=row["plan_total_gb"],
            )
            sub_url = self.app.panel.sub_url(result["sub_id"])
            payload = self._build_payload(row, result, sub_url)
            payload["activated_at"] = now
            finalized = store.finalize(
                row["id"],
                device_id=device_id,
                now=now,
                client_uuid=result["uuid"],
                sub_id=result["sub_id"],
                result_json=json.dumps(payload, ensure_ascii=False),
            )
            if not finalized:
                # Кто-то успел изменить статус между claim и finalize: отдаём реальное состояние.
                fresh = store.get_by_hash(code_hash)
                if fresh and fresh["status"] == "active" and fresh["device_id"] == device_id:
                    payload = self._idempotent_result(
                        fresh, code_id=code_id, device_id=device_id, ip=ip
                    )
                    self._send_json(200, payload)
                    return
                log.error("код %s: не удалось зафиксировать активацию (гонка статусов)", code_id)
                raise PanelError("не удалось зафиксировать активацию")
        except PanelError as error:
            store.revert_claim(row["id"])
            store.audit(
                "app", "activate_panel_error", code_id=row["id"], device_id=device_id, ip=ip,
                detail={"code_id": code_id, "error": str(error)[:200]},
            )
            log.warning("код %s: ошибка панели 3x-ui: %s", code_id, str(error)[:300])
            raise _HttpError(
                502, "panel_unavailable", "Панель временно недоступна, повторите активацию позже"
            ) from None

        store.audit(
            "app", "activate_ok", code_id=row["id"], device_id=device_id, ip=ip,
            detail={"code_id": code_id, "client_uuid": result["uuid"]},
        )
        self._send_json(200, payload)

    def _build_payload(self, row: dict, result: dict, sub_url: str) -> dict:
        cfg = self.app.cfg
        expiry_ms = int(result.get("expiry_time_ms") or 0)
        total = int(result.get("total") or 0)
        up = int(result.get("up") or 0)
        down = int(result.get("down") or 0)
        used = up + down
        return {
            "sub_url": sub_url,
            "profile_name": cfg.profile_name_template.format(email=row["client_email"]),
            "expire": iso_from_ms(expiry_ms) if expiry_ms > 0 else None,
            "expire_unix": expiry_ms // 1000 if expiry_ms > 0 else None,
            "traffic": {
                "up_bytes": up,
                "down_bytes": down,
                "used_bytes": used,
                "total_bytes": total,
                "remaining_bytes": max(total - used, 0) if total > 0 else 0,
                "unlimited": total == 0,
            },
            "client_uuid": result.get("uuid") or row.get("client_uuid") or "",
            "idempotent": False,
        }

    def _idempotent_result(self, row: dict, *, code_id: str, device_id: str, ip: str) -> dict:
        payload = None
        if row.get("result_json"):
            try:
                payload = json.loads(row["result_json"])
            except ValueError:
                payload = None
        if not isinstance(payload, dict):
            # Крайне редкий случай: запись активна, но снимок ответа потерян.
            result = self.app.panel.ensure_client(
                email=row["client_email"],
                client_uuid=row["client_uuid"],
                sub_id=row["sub_id"],
                plan_days=row["plan_days"],
                total_gb=row["plan_total_gb"],
            )
            payload = self._build_payload(row, result, self.app.panel.sub_url(result["sub_id"]))
        payload = dict(payload)
        payload["idempotent"] = True
        payload.setdefault("activated_at", row.get("used_at"))
        self.app.store.audit(
            "app", "activate_idempotent", code_id=row["id"], device_id=device_id, ip=ip,
            detail={"code_id": code_id},
        )
        return payload

    # ------------------------------------------------------------------ admin
    def _create_code(self) -> None:
        self._require_admin()
        self._admin_rate_limit()
        cfg = self.app.cfg
        body = self._read_json()

        email = self._required_str(body, "email", 254)
        if not EMAIL_RE.match(email):
            raise _HttpError(400, "invalid_request", "email: некорректный адрес")
        client_uuid = self._optional_str(body, "client_uuid", 36)
        if client_uuid and not UUID_RE.match(client_uuid):
            raise _HttpError(400, "invalid_request", "client_uuid: ожидается UUID")
        sub_id = self._optional_str(body, "sub_id", 64)
        if sub_id and not SUB_ID_RE.match(sub_id):
            raise _HttpError(400, "invalid_request", "sub_id: 8–64 символа [A-Za-z0-9_-]")
        note = self._optional_str(body, "note", 200)

        ttl = self._int_value(
            body.get("ttl_seconds"), "ttl_seconds",
            default=cfg.code_ttl_seconds, minimum=60, maximum=30 * 24 * 60 * 60,
        )
        plan = body.get("plan") or {}
        if not isinstance(plan, dict):
            raise _HttpError(400, "invalid_request", "plan: ожидается объект {days, total_gb}")
        days = self._int_value(
            plan.get("days"), "plan.days", default=cfg.plan_days, minimum=0, maximum=3650
        )
        total_gb = self._float_value(
            plan.get("total_gb"), "plan.total_gb",
            default=cfg.plan_total_gb, minimum=0.0, maximum=1_000_000.0,
        )

        code = secrets.token_urlsafe(16)
        code_hash = hash_code(code, cfg.code_pepper)
        superseded = self.app.store.revoke_pending_for_email(email)
        row = self.app.store.create_code(
            client_email=email,
            code_hash=code_hash,
            plan_days=days,
            plan_total_gb=total_gb,
            ttl_seconds=ttl,
            client_uuid=client_uuid,
            sub_id=sub_id,
            note=note,
        )
        actor = self._actor()
        self.app.store.audit(
            actor, "code_created", code_id=row["id"], ip=self._client_ip(),
            detail={
                "code_id": code_id_from_hash(code_hash),
                "client_email": email,
                "ttl_seconds": ttl,
                "plan_days": days,
                "plan_total_gb": total_gb,
                "superseded_pending": superseded,
            },
        )
        self._send_json(
            201,
            {
                "code": code,
                "code_id": code_id_from_hash(code_hash),
                "client_email": email,
                "client_uuid": row["client_uuid"],
                "expires_at": row["expires_at"],
                "ttl_seconds": ttl,
                "plan": {"days": days, "total_gb": total_gb},
            },
            headers={"X-Code-Shown-Once": "true"},
        )

    def _get_code(self, code: str) -> None:
        self._require_admin()
        self._admin_rate_limit()
        code = code.strip()
        if not CODE_RE.match(code):
            raise _HttpError(400, "invalid_request", "Код активации имеет неверный формат")
        code_hash = hash_code(code, self.app.cfg.code_pepper)
        row = self.app.store.get_by_hash(code_hash)
        if row is None:
            raise _HttpError(404, "code_not_found", "Код активации не найден")
        status = row["status"]
        if status == "pending" and row["expires_at"] <= self.app.store.now_iso():
            status = "expired"
        self._send_json(
            200,
            {
                "code_id": code_id_from_hash(code_hash),
                "client_email": row["client_email"],
                "client_uuid": row["client_uuid"],
                "status": status,
                "created_at": row["created_at"],
                "expires_at": row["expires_at"],
                "used_at": row["used_at"],
                "device_id": row["device_id"],
                "attempts": row["attempts"],
                "plan": {"days": row["plan_days"], "total_gb": row["plan_total_gb"]},
            },
        )

    def _actor(self) -> str:
        raw = (self.headers.get("X-Admin-Actor") or "").strip()
        return raw if ACTOR_RE.match(raw) else "admin"
