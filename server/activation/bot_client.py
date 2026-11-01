"""Клиент API активации для Telegram-бота (только stdlib).

Бот после подтверждения оплаты создаёт код и отправляет его пользователю:

    from activation.bot_client import create_activation_code, format_code_message
    info = create_activation_code(email="client@example.com", plan_days=30)
    send(chat_id, format_code_message(info))

Адрес сервиса и токен берутся из аргументов или из ACTIVATION_API_URL /
ACTIVATION_ADMIN_TOKEN. CLI (из каталога server/):

    python3 -m activation.bot_client create --email client@example.com --days 30
    python3 -m activation.bot_client status --code <код>
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_API_URL = "http://127.0.0.1:8089"
DEFAULT_TOKEN = ""
USER_AGENT = "vpn-bot/1.0"


class ActivationApiError(RuntimeError):
    """Ошибка сервиса активации (HTTP-статус + машинный код)."""

    def __init__(self, status: int, code: str, message: str):
        super().__init__(f"{code}: {message}")
        self.status = status
        self.code = code
        self.message = message


def _request(api_base: str, method: str, path: str, *, token: str = "", payload=None, timeout: float = 10.0) -> dict:
    url = api_base.rstrip("/") + path
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8") if payload is not None else None
    headers = {"Accept": "application/json", "User-Agent": USER_AGENT}
    if data is not None:
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = "Bearer " + token
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        body = {}
        try:
            body = json.loads(error.read().decode("utf-8"))
        except Exception:  # noqa: BLE001 - тело ошибки может быть не-JSON
            pass
        raise ActivationApiError(
            error.code,
            body.get("error", "http_error"),
            body.get("message", f"HTTP {error.code}"),
        ) from None
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        raise ActivationApiError(0, "unavailable", f"сервис активации недоступен: {error}") from None


def create_activation_code(
    *,
    email: str,
    api_base: str = "",
    admin_token: str = "",
    plan_days: int | None = None,
    total_gb: float | None = None,
    ttl_seconds: int | None = None,
    note: str | None = None,
    timeout: float = 10.0,
) -> dict:
    """Создать одноразовый код для клиента. Возвращает ответ API (включая code)."""
    payload: dict = {"email": email}
    plan: dict = {}
    if plan_days is not None:
        plan["days"] = plan_days
    if total_gb is not None:
        plan["total_gb"] = total_gb
    if plan:
        payload["plan"] = plan
    if ttl_seconds is not None:
        payload["ttl_seconds"] = ttl_seconds
    if note:
        payload["note"] = note
    return _request(
        api_base or os.environ.get("ACTIVATION_API_URL", DEFAULT_API_URL),
        "POST",
        "/v1/codes",
        token=admin_token or os.environ.get("ACTIVATION_ADMIN_TOKEN", DEFAULT_TOKEN),
        payload=payload,
        timeout=timeout,
    )


def get_activation_status(*, code: str, api_base: str = "", admin_token: str = "", timeout: float = 10.0) -> dict:
    """Статус кода активации (pending/active/expired/locked/revoked)."""
    return _request(
        api_base or os.environ.get("ACTIVATION_API_URL", DEFAULT_API_URL),
        "GET",
        "/v1/codes/" + urllib.parse.quote(code.strip(), safe=""),
        token=admin_token or os.environ.get("ACTIVATION_ADMIN_TOKEN", DEFAULT_TOKEN),
        timeout=timeout,
    )


def format_code_message(info: dict, *, service_name: str = "VPN") -> str:
    """Текст сообщения пользователю с кодом активации."""
    plan = info.get("plan") or {}
    days = plan.get("days")
    total_gb = plan.get("total_gb")
    if days:
        plan_line = f"Тариф: {days} дн."
    else:
        plan_line = "Тариф: без срока"
    if total_gb:
        plan_line += f", {total_gb:g} ГБ трафика"
    else:
        plan_line += ", трафик без ограничения"
    expires = _human_datetime(info.get("expires_at"))
    return (
        f"🎟 Код активации {service_name}\n\n"
        f"{info.get('code', '')}\n\n"
        f"Введи этот код в приложении в поле «Код активации».\n"
        f"Код одноразовый, действует до {expires}.\n"
        f"{plan_line}."
    )


def _human_datetime(iso: str | None) -> str:
    if not iso:
        return "—"
    try:
        date, moment = iso.split("T")
        year, month, day = date.split("-")
        hour, minute, _ = moment.split(":")
        return f"{day}.{month}.{year} {hour}:{minute} UTC"
    except ValueError:
        return iso


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Клиент API активации VPN (для бота и админа)")
    parser.add_argument("--api", default=os.environ.get("ACTIVATION_API_URL", DEFAULT_API_URL),
                        help="базовый URL сервиса активации")
    parser.add_argument("--token", default=os.environ.get("ACTIVATION_ADMIN_TOKEN", DEFAULT_TOKEN),
                        help="admin-token (по умолчанию ACTIVATION_ADMIN_TOKEN)")
    parser.add_argument("--json", action="store_true", help="вывести JSON вместо текста")
    sub = parser.add_subparsers(dest="command", required=True)

    create = sub.add_parser("create", help="создать код активации")
    create.add_argument("--email", required=True)
    create.add_argument("--days", type=int, default=None, help="срок тарифа в днях")
    create.add_argument("--gb", type=float, default=None, help="трафик в ГБ (0 = без лимита)")
    create.add_argument("--ttl", type=int, default=None, help="TTL кода в секундах")
    create.add_argument("--note", default=None)

    status = sub.add_parser("status", help="статус кода активации")
    status.add_argument("--code", required=True)

    args = parser.parse_args(argv)
    try:
        if args.command == "create":
            info = create_activation_code(
                email=args.email, api_base=args.api, admin_token=args.token,
                plan_days=args.days, total_gb=args.gb, ttl_seconds=args.ttl, note=args.note,
            )
            if args.json:
                print(json.dumps(info, ensure_ascii=False, indent=1))
            else:
                print(format_code_message(info))
        else:
            info = get_activation_status(code=args.code, api_base=args.api, admin_token=args.token)
            print(json.dumps(info, ensure_ascii=False, indent=1))
    except ActivationApiError as error:
        print(f"Ошибка: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
