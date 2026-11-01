"""UTC-время в ISO-8601 и преобразования. Только stdlib."""

from __future__ import annotations

import time
from datetime import datetime, timedelta, timezone

ISO_FMT = "%Y-%m-%dT%H:%M:%SZ"


def utcnow_iso() -> str:
    return datetime.now(timezone.utc).strftime(ISO_FMT)


def iso_add_seconds(iso: str, seconds: int) -> str:
    moment = _parse(iso) + timedelta(seconds=seconds)
    return moment.strftime(ISO_FMT)


def iso_age_seconds(now_iso: str, then_iso: str) -> float:
    return (_parse(now_iso) - _parse(then_iso)).total_seconds()


def epoch_from_iso(iso: str) -> int:
    return int(_parse(iso).timestamp())


def iso_from_epoch(epoch: int | float) -> str:
    return datetime.fromtimestamp(float(epoch), tz=timezone.utc).strftime(ISO_FMT)


def iso_from_ms(ms: int | float) -> str:
    return iso_from_epoch(float(ms) / 1000.0)


def _parse(iso: str) -> datetime:
    return datetime.strptime(iso, ISO_FMT).replace(tzinfo=timezone.utc)
