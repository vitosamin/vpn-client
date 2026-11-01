"""SQLite-хранилище кодов активации и аудита.

Код активации в открытом виде НЕ хранится: только HMAC-SHA256(pepper, code).
По открытому коду считается тот же хэш — так работает идемпотентный поиск.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import sqlite3
import threading

from . import timeutil

SCHEMA = """
PRAGMA journal_mode=WAL;

CREATE TABLE IF NOT EXISTS codes (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    code_hash      TEXT NOT NULL UNIQUE,
    client_email   TEXT NOT NULL,
    client_uuid    TEXT,
    sub_id         TEXT,
    plan_days      INTEGER NOT NULL DEFAULT 0,
    plan_total_gb  REAL NOT NULL DEFAULT 0,
    created_at     TEXT NOT NULL,
    expires_at     TEXT NOT NULL,
    used_at        TEXT,
    device_id      TEXT,
    status         TEXT NOT NULL DEFAULT 'pending',  -- pending|activating|active|expired|locked|revoked
    attempts       INTEGER NOT NULL DEFAULT 0,
    result_json    TEXT,
    note           TEXT
);

CREATE INDEX IF NOT EXISTS idx_codes_email ON codes(client_email);
CREATE INDEX IF NOT EXISTS idx_codes_status ON codes(status);

CREATE TABLE IF NOT EXISTS audit (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    ts        TEXT NOT NULL,
    actor     TEXT NOT NULL,
    action    TEXT NOT NULL,
    code_id   INTEGER,
    device_id TEXT,
    ip        TEXT,
    detail    TEXT
);

CREATE INDEX IF NOT EXISTS idx_audit_ts ON audit(ts);
"""


def hash_code(code: str, pepper: str) -> str:
    """HMAC-SHA256 от кода активации. Детерминированно, без хранения секрета в БД."""
    return hmac.new(pepper.encode("utf-8"), code.encode("utf-8"), hashlib.sha256).hexdigest()


def code_id_from_hash(code_hash: str) -> str:
    """Короткий идентификатор кода для логов/аудита (не позволяет восстановить код)."""
    return code_hash[:12]


class Store:
    def __init__(self, path: str, clock=None):
        self.path = path
        self._clock = clock or timeutil.utcnow_iso
        directory = os.path.dirname(os.path.abspath(path))
        if directory:
            os.makedirs(directory, exist_ok=True)
        self._lock = threading.RLock()
        self._conn = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self._conn.row_factory = sqlite3.Row
        self._conn.executescript(SCHEMA)

    # ------------------------------------------------------------- время
    def now_iso(self) -> str:
        return self._clock()

    # ------------------------------------------------------------- коды
    def create_code(
        self,
        *,
        client_email: str,
        code_hash: str,
        plan_days: int,
        plan_total_gb: float,
        ttl_seconds: int,
        client_uuid: str | None = None,
        sub_id: str | None = None,
        note: str | None = None,
    ) -> dict:
        now = self.now_iso()
        expires_at = timeutil.iso_add_seconds(now, ttl_seconds)
        with self._lock:
            cur = self._conn.execute(
                """
                INSERT INTO codes (code_hash, client_email, client_uuid, sub_id,
                                   plan_days, plan_total_gb, created_at, expires_at,
                                   status, note)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?)
                """,
                (
                    code_hash,
                    client_email,
                    client_uuid,
                    sub_id,
                    plan_days,
                    plan_total_gb,
                    now,
                    expires_at,
                    note,
                ),
            )
            row = self._conn.execute(
                "SELECT * FROM codes WHERE id = ?", (cur.lastrowid,)
            ).fetchone()
        return dict(row)

    def get_by_hash(self, code_hash: str) -> dict | None:
        with self._lock:
            row = self._conn.execute(
                "SELECT * FROM codes WHERE code_hash = ?", (code_hash,)
            ).fetchone()
        return dict(row) if row else None

    def claim(self, code_id: int, device_id: str, now: str) -> bool:
        """Атомарно перевести pending → activating (CAS)."""
        with self._lock:
            cur = self._conn.execute(
                """
                UPDATE codes
                   SET status = 'activating', device_id = ?, used_at = ?
                 WHERE id = ? AND status = 'pending'
                """,
                (device_id, now, code_id),
            )
        return cur.rowcount == 1

    def retry_stale_claim(self, code_id: int, device_id: str, now: str) -> bool:
        """Повторно взять зависшую активацию того же устройства."""
        with self._lock:
            cur = self._conn.execute(
                """
                UPDATE codes
                   SET status = 'activating', used_at = ?
                 WHERE id = ? AND status = 'activating' AND device_id = ?
                """,
                (now, code_id, device_id),
            )
        return cur.rowcount == 1

    def revert_claim(self, code_id: int) -> None:
        with self._lock:
            self._conn.execute(
                """
                UPDATE codes
                   SET status = 'pending', device_id = NULL, used_at = NULL
                 WHERE id = ? AND status = 'activating'
                """,
                (code_id,),
            )

    def finalize(
        self,
        code_id: int,
        *,
        device_id: str,
        now: str,
        client_uuid: str,
        sub_id: str,
        result_json: str,
    ) -> bool:
        with self._lock:
            cur = self._conn.execute(
                """
                UPDATE codes
                   SET status = 'active', device_id = ?, used_at = ?,
                       client_uuid = ?, sub_id = ?, result_json = ?
                 WHERE id = ? AND status = 'activating'
                """,
                (device_id, now, client_uuid, sub_id, result_json, code_id),
            )
        return cur.rowcount == 1

    def revoke_pending_for_email(self, email: str) -> int:
        """Отозвать неиспользованные коды этого email (перевыпуск кода)."""
        with self._lock:
            cur = self._conn.execute(
                "UPDATE codes SET status = 'revoked' WHERE client_email = ? AND status = 'pending'",
                (email,),
            )
        return cur.rowcount

    def mark_expired(self, code_id: int) -> None:
        with self._lock:
            self._conn.execute(
                "UPDATE codes SET status = 'expired' WHERE id = ? AND status = 'pending'",
                (code_id,),
            )

    def lock_code(self, code_id: int) -> None:
        with self._lock:
            self._conn.execute(
                "UPDATE codes SET status = 'locked' WHERE id = ? AND status IN ('pending','active')",
                (code_id,),
            )

    def inc_attempts(self, code_id: int) -> int:
        with self._lock:
            self._conn.execute(
                "UPDATE codes SET attempts = attempts + 1 WHERE id = ?", (code_id,)
            )
            row = self._conn.execute(
                "SELECT attempts FROM codes WHERE id = ?", (code_id,)
            ).fetchone()
        return int(row["attempts"]) if row else 0

    # ------------------------------------------------------------- аудит
    def audit(
        self,
        actor: str,
        action: str,
        *,
        code_id: int | None = None,
        device_id: str | None = None,
        ip: str | None = None,
        detail: dict | None = None,
    ) -> None:
        """Журнал действий. Секреты (коды, токены, sub-ссылки) сюда не попадают."""
        payload = json.dumps(detail or {}, ensure_ascii=False)[:1000]
        with self._lock:
            self._conn.execute(
                """
                INSERT INTO audit (ts, actor, action, code_id, device_id, ip, detail)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (self.now_iso(), actor, action, code_id, device_id, ip, payload),
            )

    def ping(self) -> bool:
        with self._lock:
            self._conn.execute("SELECT 1").fetchone()
        return True

    def close(self) -> None:
        with self._lock:
            self._conn.close()
