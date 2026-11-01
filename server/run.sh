#!/usr/bin/env bash
# run.sh — запуск и остановка сервиса активации на NAS.
#
#   ./run.sh start       запустить в фоне: logs/app.log + run.pid (порт из .env)
#   ./run.sh stop        остановить по pid-файлу (SIGTERM, потом SIGKILL)
#   ./run.sh restart     stop + start
#   ./run.sh status      pid и ответ /health
#   ./run.sh foreground  запустить на переднем плане (отладка)
#   ./run.sh logs        tail -f logs/app.log
#
# Настройки сервис читает сам из .env (run.py). Переменные окружения важнее .env,
# поэтому можно временно переопределить, например:
#   APP_PORT=18089 ./run.sh start
# Секреты (ADMIN_TOKEN, CODE_PEPPER, пароль панели) в stdout и лог не печатаются.

set -euo pipefail
umask 077

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$HERE/.env"
PID_FILE="$HERE/run.pid"
LOG_DIR="$HERE/logs"
LOG_FILE="$LOG_DIR/app.log"
PYTHON="${PYTHON:-python3}"
START_TIMEOUT="${START_TIMEOUT:-10}"

# Значение настройки: сначала настоящее окружение, потом .env, потом default.
env_value() {
  local key="$1" default="${2:-}"
  if declare -p "$key" >/dev/null 2>&1; then
    printf '%s' "${!key}"
    return
  fi
  "$PYTHON" - "$ENV_FILE" "$key" "$default" <<'PY'
import sys

path, key, default = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            name, _, value = line.partition("=")
            if name.strip() == key:
                print(value.strip().strip('"').strip("'"), end="")
                raise SystemExit
except OSError:
    pass
print(default, end="")
PY
}

health_url() {
  printf 'http://%s:%s/health' "$(env_value APP_HOST 127.0.0.1)" "$(env_value APP_PORT 8089)"
}

is_running() {
  local pid
  [[ -f "$PID_FILE" ]] || return 1
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

wait_health() {
  local url="${1:-$(health_url)}" attempt
  for attempt in $(seq 1 "$((START_TIMEOUT * 10))"); do
    if curl -fsS --max-time 1 "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

start() {
  mkdir -p "$LOG_DIR"
  chmod 700 "$LOG_DIR" 2>/dev/null || true
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "нет $ENV_FILE — выполни: cp .env.example .env и заполни ADMIN_TOKEN/CODE_PEPPER" >&2
    return 1
  fi
  if is_running; then
    echo "уже запущен: pid=$(cat "$PID_FILE"), $(health_url)"
    return 0
  fi
  rm -f "$PID_FILE"
  (
    cd "$HERE"
    nohup "$PYTHON" "$HERE/run.py" >>"$LOG_FILE" 2>&1 &
    echo $! >"$PID_FILE"
  )
  local pid
  pid="$(cat "$PID_FILE")"
  if wait_health; then
    echo "запущен: pid=$pid, $(health_url), лог $LOG_FILE"
  else
    echo "ошибка: сервис не ответил на $(health_url) за ${START_TIMEOUT} с" >&2
    tail -n 20 "$LOG_FILE" >&2 || true
    stop >/dev/null 2>&1 || true
    return 1
  fi
}

stop() {
  local pid attempt
  if ! is_running; then
    rm -f "$PID_FILE"
    echo "не запущен"
    return 0
  fi
  pid="$(cat "$PID_FILE")"
  kill -TERM "$pid" 2>/dev/null || true
  for attempt in $(seq 1 50); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    sleep 0.2
  fi
  rm -f "$PID_FILE"
  echo "остановлен: pid=$pid"
}

status() {
  if is_running; then
    echo "работает: pid=$(cat "$PID_FILE"), $(health_url)"
    curl -fsS --max-time 2 "$(health_url)" || true
    echo
  else
    echo "не запущен (pid-файл: $PID_FILE)"
  fi
}

foreground() {
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "нет $ENV_FILE — выполни: cp .env.example .env и заполни ADMIN_TOKEN/CODE_PEPPER" >&2
    return 1
  fi
  cd "$HERE"
  exec "$PYTHON" "$HERE/run.py"
}

logs() {
  tail -n 100 -f "$LOG_FILE"
}

case "${1:-start}" in
  start) start ;;
  stop) stop ;;
  restart) stop; start ;;
  status) status ;;
  foreground) foreground ;;
  logs) logs ;;
  *)
    echo "использование: $0 {start|stop|restart|status|foreground|logs}" >&2
    exit 2
    ;;
esac
