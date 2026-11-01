"""Конфигурация сервиса активации.

Все настройки берутся из переменных окружения (см. .env.example).
Секреты помечены repr=False и не попадают в repr/log при случайном выводе.
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass, field

SERVER_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

log = logging.getLogger("activation.config")

MAX_TTL_SECONDS = 30 * 24 * 60 * 60  # 30 дней


class ConfigError(ValueError):
    """Некорректная конфигурация сервиса."""


def _get(env, name: str, default: str = "") -> str:
    value = env.get(name)
    if value is None or not str(value).strip():
        return default
    return str(value).strip()


def _int(env, name: str, default: int, *, minimum=None, maximum=None) -> int:
    raw = _get(env, name)
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        raise ConfigError(f"{name}: ожидается целое число, получено {raw!r}") from None
    if minimum is not None and value < minimum:
        raise ConfigError(f"{name}: значение должно быть >= {minimum}, получено {value}")
    if maximum is not None and value > maximum:
        raise ConfigError(f"{name}: значение должно быть <= {maximum}, получено {value}")
    return value


def _float(env, name: str, default: float, *, minimum=None, maximum=None) -> float:
    raw = _get(env, name)
    if not raw:
        return default
    try:
        value = float(raw)
    except ValueError:
        raise ConfigError(f"{name}: ожидается число, получено {raw!r}") from None
    if minimum is not None and value < minimum:
        raise ConfigError(f"{name}: значение должно быть >= {minimum}, получено {value}")
    if maximum is not None and value > maximum:
        raise ConfigError(f"{name}: значение должно быть <= {maximum}, получено {value}")
    return value


_TRUE = {"1", "true", "yes", "on"}
_FALSE = {"0", "false", "no", "off"}


def _bool(env, name: str, default: bool) -> bool:
    raw = _get(env, name)
    if not raw:
        return default
    if raw.lower() in _TRUE:
        return True
    if raw.lower() in _FALSE:
        return False
    raise ConfigError(f"{name}: ожидается 1/0 (true/false), получено {raw!r}")


def _web_base_path(env) -> str:
    """Нормализовать webBasePath: '' или '/path/'."""
    raw = _get(env, "XUI_WEB_BASE_PATH")
    if not raw or raw == "/":
        return ""
    if not raw.startswith("/"):
        raw = "/" + raw
    return raw.rstrip("/") + "/"


@dataclass(frozen=True)
class Config:
    # --- сервис ---
    host: str = "127.0.0.1"
    port: int = 8089
    db_path: str = field(default_factory=lambda: os.path.join(SERVER_DIR, "data", "activation.db"))
    log_level: str = "INFO"
    max_body_bytes: int = 8192
    trust_proxy: bool = False

    # --- безопасность / коды ---
    admin_token: str = field(default="", repr=False)
    code_pepper: str = field(default="", repr=False)
    code_ttl_seconds: int = 86400
    max_code_attempts: int = 10
    rate_activate_per_min: int = 10
    rate_admin_per_min: int = 60
    provisioning_stale_seconds: int = 120

    # --- тариф по умолчанию ---
    plan_days: int = 30
    plan_total_gb: float = 0.0

    # --- 3x-ui ---
    xui_mode: str = "mock"  # mock | real
    xui_base_url: str = ""
    xui_username: str = ""
    xui_password: str = field(default="", repr=False)
    xui_api_token: str = field(default="", repr=False)
    xui_web_base_path: str = ""
    xui_inbound_id: int = 1
    xui_verify_tls: bool = True
    xui_timeout: float = 10.0
    xui_client_api: str = "auto"  # auto | legacy | modern
    xui_client_flow: str = ""
    sub_url_template: str = "https://vpn.example.com/sub/{sub_id}"
    profile_name_template: str = "{email}"

    @property
    def admin_enabled(self) -> bool:
        return bool(self.admin_token)

    @classmethod
    def from_env(cls, env=None) -> "Config":
        env = os.environ if env is None else env

        mode = _get(env, "XUI_MODE", "mock").lower()
        if mode not in ("mock", "real"):
            raise ConfigError("XUI_MODE: допустимо mock или real")

        web_base_path = _web_base_path(env)
        base_url = _get(env, "XUI_BASE_URL").rstrip("/")
        inbound_id = _int(env, "XUI_INBOUND_ID", 1, minimum=1)
        username = _get(env, "XUI_USERNAME")
        password = _get(env, "XUI_PASSWORD")
        api_token = _get(env, "XUI_API_TOKEN")

        if mode == "real":
            if not base_url.startswith(("http://", "https://")):
                raise ConfigError("XUI_BASE_URL: нужен http(s)://... в режиме real")
            if not (api_token or (username and password)):
                raise ConfigError(
                    "Режим real: задай XUI_API_TOKEN либо XUI_USERNAME и XUI_PASSWORD"
                )

        sub_url_template = _get(env, "SUB_URL_TEMPLATE")
        if not sub_url_template:
            sub_url_template = (
                "https://vpn.example.com/sub/{sub_id}"
                if mode == "mock"
                else base_url + "/sub/{sub_id}"
            )
        if "{sub_id}" not in sub_url_template:
            raise ConfigError("SUB_URL_TEMPLATE: должен содержать плейсхолдер {sub_id}")

        profile_name_template = _get(env, "PROFILE_NAME_TEMPLATE", "{email}")
        if "{email}" not in profile_name_template:
            raise ConfigError("PROFILE_NAME_TEMPLATE: должен содержать плейсхолдер {email}")

        code_pepper = _get(env, "CODE_PEPPER")
        if not code_pepper:
            log.warning(
                "CODE_PEPPER не задан: использую временный. "
                "После перезапуска старые коды перестанут находиться — задай CODE_PEPPER в .env"
            )
            import secrets

            code_pepper = secrets.token_urlsafe(32)

        admin_token = _get(env, "ADMIN_TOKEN")
        if not admin_token:
            log.warning("ADMIN_TOKEN не задан: админ-эндпоинты отключены (503)")

        client_api = _get(env, "XUI_CLIENT_API", "auto").lower()
        if client_api not in ("auto", "legacy", "modern"):
            raise ConfigError("XUI_CLIENT_API: допустимо auto, legacy или modern")

        return cls(
            host=_get(env, "APP_HOST", "127.0.0.1"),
            port=_int(env, "APP_PORT", 8089, minimum=1, maximum=65535),
            db_path=_get(env, "DB_PATH", os.path.join(SERVER_DIR, "data", "activation.db")),
            log_level=_get(env, "LOG_LEVEL", "INFO").upper(),
            max_body_bytes=_int(env, "MAX_BODY_BYTES", 8192, minimum=512, maximum=1048576),
            trust_proxy=_bool(env, "TRUST_PROXY", False),
            admin_token=admin_token,
            code_pepper=code_pepper,
            code_ttl_seconds=_int(env, "CODE_TTL_SECONDS", 86400, minimum=60, maximum=MAX_TTL_SECONDS),
            max_code_attempts=_int(env, "MAX_CODE_ATTEMPTS", 10, minimum=1, maximum=1000),
            rate_activate_per_min=_int(env, "RATE_ACTIVATE_PER_MIN", 10, minimum=1, maximum=100000),
            rate_admin_per_min=_int(env, "RATE_ADMIN_PER_MIN", 60, minimum=1, maximum=100000),
            provisioning_stale_seconds=_int(
                env, "PROVISIONING_STALE_SECONDS", 120, minimum=10, maximum=3600
            ),
            plan_days=_int(env, "PLAN_DAYS", 30, minimum=0, maximum=3650),
            plan_total_gb=_float(env, "PLAN_TOTAL_GB", 0.0, minimum=0.0, maximum=1_000_000.0),
            xui_mode=mode,
            xui_base_url=base_url,
            xui_username=username,
            xui_password=password,
            xui_api_token=api_token,
            xui_web_base_path=web_base_path,
            xui_inbound_id=inbound_id,
            xui_verify_tls=_bool(env, "XUI_VERIFY_TLS", True),
            xui_timeout=_float(env, "XUI_TIMEOUT", 10.0, minimum=1.0, maximum=120.0),
            xui_client_api=client_api,
            xui_client_flow=_get(env, "XUI_CLIENT_FLOW"),
            sub_url_template=sub_url_template,
            profile_name_template=profile_name_template,
        )

    def describe(self) -> dict:
        """Безопасное описание конфигурации для логов (без секретов)."""
        return {
            "mode": self.xui_mode,
            "db_path": self.db_path,
            "listen": f"{self.host}:{self.port}",
            "admin_enabled": self.admin_enabled,
            "xui_base_url": self.xui_base_url,
            "xui_inbound_id": self.xui_inbound_id,
            "xui_client_api": self.xui_client_api,
            "xui_verify_tls": self.xui_verify_tls,
            "code_ttl_seconds": self.code_ttl_seconds,
            "plan_days": self.plan_days,
            "plan_total_gb": self.plan_total_gb,
            "trust_proxy": self.trust_proxy,
        }
