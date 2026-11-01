#!/usr/bin/env python3
"""Запуск сервиса активации VPN-клиента.

    cd /root/MyHome/vpn-client/server
    cp .env.example .env            # и прописать секреты
    python3 run.py

Настройки берутся из окружения; если рядом с run.py есть .env, он подхватывается
автоматически (значения из настоящего окружения имеют приоритет).
"""

from __future__ import annotations

import logging
import os
import signal
import sys

from activation.api import ActivationApi
from activation.config import Config, ConfigError

HERE = os.path.dirname(os.path.abspath(__file__))


def load_dotenv(path: str = os.path.join(HERE, ".env")) -> None:
    """Минимальный загрузчик .env: KEY=VALUE, # комментарии. Окружение важнее файла."""
    if not os.path.exists(path):
        return
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip().strip('"').strip("'")
            if key and key not in os.environ:
                os.environ[key] = value


def _graceful_stop(signum, frame):
    """SIGTERM от run.sh/systemd → штатное завершение, а не обрыв."""
    raise KeyboardInterrupt


def main() -> int:
    load_dotenv()
    try:
        cfg = Config.from_env()
    except ConfigError as error:
        print(f"Ошибка конфигурации: {error}", file=sys.stderr)
        return 2

    logging.basicConfig(
        level=getattr(logging, cfg.log_level, logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    log = logging.getLogger("activation")
    log.info("конфигурация: %s", cfg.describe())
    api = ActivationApi(cfg)
    signal.signal(signal.SIGTERM, _graceful_stop)
    try:
        api.serve_forever()
    except KeyboardInterrupt:
        log.info("сервис остановлен вручную")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
