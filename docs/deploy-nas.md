# Развёртывание API активации на NAS

Статус: прототип развёрнут на NAS в **mock-режиме** (без реальной панели 3x-ui),
сквозной e2e-прогон пройден 2026-10-31. Реальная панель не подключена — секретов
3x-ui в репозитории нет; чек-лист для боевого запуска — в конце.

- Каталог: `/root/MyHome/vpn-client/server`
- Порт: `127.0.0.1:8089` (в `.env`: `APP_PORT=8089`)
- Режим: `XUI_MODE=mock` (фейковая панель, sub-ссылка `https://vpn.example.com/sub/<sub_id>`)
- Реализация: Python 3.13.5, только stdlib, внешних зависимостей нет
- API-контракт: [`activation-api.md`](activation-api.md)

Артефакты развёртывания в `server/`:

| Файл | Что это |
|---|---|
| `.env` | настройки + сгенерированные `ADMIN_TOKEN`/`CODE_PEPPER` (chmod 600, в git не попадает) |
| `run.sh` | start/stop/status/foreground/logs, pid-файл `run.pid` |
| `logs/app.log` | stdout/stderr сервиса (chmod 600, коды/токены/sub-ссылки не пишутся) |
| `data/activation.db` | SQLite: коды и аудит (создаётся при старте; в git не попадает) |

---

## 1. Подготовка (один раз)

```bash
cd /root/MyHome/vpn-client/server
cp .env.example .env
chmod 600 .env

# сгенерировать секреты:
python3 - <<'PY'
import secrets
print("ADMIN_TOKEN=" + secrets.token_urlsafe(32))
print("CODE_PEPPER=" + secrets.token_urlsafe(32))
PY
# вписать их в .env (ADMIN_TOKEN, CODE_PEPPER). XUI_MODE=mock оставить,
# пока не подключена реальная панель; real-режим — см. activation-api.md §11.
```

`run.py` сам подхватывает `.env` из своего каталога; переменные окружения имеют
приоритет над файлом (удобно для разовых проверок: `APP_PORT=18089 ./run.sh start`).

---

## 2. Вариант A — локальный процесс через `run.sh` (рекомендуется для NAS)

```bash
cd /root/MyHome/vpn-client/server
./run.sh start       # nohup; ждёт /health; пишет run.pid
./run.sh status      # pid + ответ /health
./run.sh logs        # tail -f logs/app.log
./run.sh stop        # SIGTERM, при необходимости SIGKILL; удаляет run.pid
./run.sh foreground  # на переднем плане (отладка), без pid-файла
./run.sh restart
```

Что делает `start`: проверяет наличие `.env`, запускает `python3 run.py` через
`nohup` с дозаписью в `logs/app.log`, кладёт PID в `run.pid`, ждёт до 10 с ответа
`/health`; при неудаче печатает хвост лога и останавливает процесс. `umask 077` —
лог и pid-файл создаются с правами 600. Секреты из `.env` в stdout не выводятся.
`stop` сначала шлёт `SIGTERM` (в `run.py` он обрабатывается как штатное
завершение), через 5 с — `SIGKILL`, если процесс не завершился.

Проверенный вывод (e2e, 2026-10-31):

```
$ ./run.sh start
запущен: pid=84566, http://127.0.0.1:8089/health, лог /root/MyHome/vpn-client/server/logs/app.log
$ ./run.sh status
работает: pid=84566, http://127.0.0.1:8089/health
{"status": "ok", "service": "vpn-activation", "version": "1.0.0", "mode": "mock", "db": "ok", ...}
$ ./run.sh stop
остановлен: pid=84566
```

Ограничение: `run.sh` не переживает перезагрузку NAS — для «постоянного» сервиса
используй systemd (вариант B) и не запускай одновременно оба варианта (займут
один порт).

---

## 3. Вариант B — systemd (текст юнита, **не установлен**)

Файл `/etc/systemd/system/vpn-activation.service`:

```ini
[Unit]
Description=VPN activation API (3x-ui codes)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root/MyHome/vpn-client/server
EnvironmentFile=/root/MyHome/vpn-client/server/.env
ExecStart=/usr/bin/python3 /root/MyHome/vpn-client/server/run.py
Restart=on-failure
RestartSec=3
UMask=0077

[Install]
WantedBy=multi-user.target
```

Установка (команды для владельца; в рамках task-5 не выполнялись):

```bash
systemctl daemon-reload
systemctl enable --now vpn-activation
systemctl status vpn-activation
journalctl -u vpn-activation -f
```

Примечания:

- Юнит не использует `run.sh` (systemd сам управляет процессом и pid-файлом).
  Перед первым запуском убедись, что `run.sh`-процесс остановлен;
- `User=root` — потому что каталог лаборатории принадлежит root. Если захочешь
  отдельного пользователя: создать его, дать права на `server/` (каталог
  `data/`, `logs/`) и указать в `User=`/`Group=`;
- `EnvironmentFile` читает `.env`; `run.py` тоже умеет читать `.env`, дублирование
  безвредно (окружение важнее файла);
- логи systemd — в journald; при этом `run.py` пишет и в stdout, так что
  `journalctl -u vpn-activation` показывает те же строки, что `logs/app.log` у
  варианта A.

---

## 4. Вариант C — публикация через Caddy (инструкция, **не выполнялась**)

На этом NAS наружу открыт один порт: `9443` на LAN-адресе `192.168.35.30` →
Caddy в контейнере (`:3080`). Сервисы публикуются **путём**, не новым портом.
Инструкция для владельца (меняет `/etc/caddy/Caddyfile`, нужны права/approval —
из задачи не выполнялось):

```bash
cd /root/MyHome
tools/caddy_publish.py add vpn-activation 8089
tools/caddy_publish.py list          # проверить маршрут
# убрать, когда сервис не нужен:  tools/caddy_publish.py remove vpn-activation
```

Результат: `http://192.168.35.30:9443/vpn-activation/`.

Что делает инструмент (важно для понимания префикса): он добавляет в Caddyfile

```
redir /vpn-activation /vpn-activation/ 308
handle_path /vpn-activation/* {
    reverse_proxy 127.0.0.1:8089
}
```

`handle_path` **срезает** префикс перед проксированием, поэтому бэкенд получает
привычные пути `/v1/...` и `/health`. То есть после публикации curl выглядит так:

```bash
BASE=http://192.168.35.30:9443/vpn-activation
curl -sS $BASE/health
curl -sS -X POST $BASE/v1/codes -H "Authorization: Bearer $ADMIN_TOKEN" ...
curl -sS -X POST $BASE/v1/activate -d '{"code":"...","device_id":"..."}'
```

Ограничения и как правильно для мобильного приложения:

1. **HTTPS обязателен.** `9443` — LAN-адрес и HTTP; мобильному клиенту нужен
   валидный HTTPS. Этот путь публикации годится только для curl-проверок из
   лаборатории.
2. **Префикс пути.** Если публиковать по пути на публичном домене, то либо
   reverse proxy должен срезать префикс (`handle_path` в Caddy, `location /...`
   с `proxy_pass http://127.0.0.1:8089/` в nginx), либо клиентский base URL
   должен включать префикс (`https://host/vpn-activation`). Сам сервис про
   префикс не знает — его маршруты абсолютные (`/v1/activate`).
3. **Рекомендуемый боевой вариант** — отдельный поддомен:
   `vpn-api.<домен>` → TLS (Caddy/nginx) → `reverse_proxy 127.0.0.1:8089`.
   Приложение ходит на `https://vpn-api.<домен>/v1/activate`, префиксов нет.
4. При работе за прокси выставить в `.env` `TRUST_PROXY=1`, чтобы rate-limit
   считался по реальному IP клиента (прокси должен перезаписывать
   `X-Forwarded-For`, а не добавлять к пользовательскому).
5. Маршрут Caddy живёт в `/etc/caddy/Caddyfile`; при пересоздании контейнера
   Caddyfile может отрендериться из шаблона и потерять добавленные вручную
   маршруты — тогда повторить `add`. Когда сервис остановлен, путь отдаёт 502 —
   убрать маршрут через `remove`.
6. **Безопасность:** публикация по пути открывает и админские эндпоинты
   (`/v1/codes`, `/v1/codes/<code>`) всем в LAN. Они защищены Bearer-токеном, но
   для боевого запуска лучше не публиковать админку шире, чем нужно (бот ходит
   на `127.0.0.1:8089`), либо ограничить доступ на уровне reverse proxy/firewall.
   Токен и коды передавать только по HTTPS.

---

## 5. Сквозной e2e в mock-режиме (выполнен на NAS)

Условия: 2026-10-31 21:57–21:58 UTC, NAS, Python 3.13.5, `./run.sh start`,
`.env` с `XUI_MODE=mock`, порт 8089, админ-токен из `.env` (в отчёте не показан).
Сервис запущен фоново через `run.sh`, все запросы — обычным `curl`.

| № | Шаг | HTTP | Результат (без секретов) |
|---|---|---|---|
| 1 | `GET /health` | **200** | `{"status":"ok","mode":"mock","db":"ok","version":"1.0.0"}` |
| 2 | `POST /v1/codes` (admin): email `e2e@example.com`, 30 дней / 100 ГБ, TTL 86400 | **201** | `code_id=…`, `expires_at=2026-11-01T21:57:40Z`, `plan={"days":30,"total_gb":100}`; код показан один раз |
| 3 | `POST /v1/activate` (устройство `e2e-device-11111111`) | **200** | `sub_url=https://vpn.example.com/sub/<sub_id>`, `profile_name=e2e@example.com`, `expire=2026-11-30T21:57:40Z`, `traffic.total_bytes=107374182400` (100 ГБ), `idempotent=false` |
| 4 | Повтор активации с тем же `device_id` | **200** | та же `sub_url`, `client_uuid` тот же, `idempotent=true` |
| 5 | Активация с другим `device_id` | **409** | `{"error":"code_already_used","message":"Код уже активирован на другом устройстве"}` |
| 6 | Неверный код | **404** | `{"error":"code_not_found","message":"Код активации не найден"}` |
| 7 | Истёкший код (создан с `ttl_seconds=60`, пауза 61 с) | **410** | `{"error":"code_expired","message":"Срок действия кода истёк"}` |

Дополнительно проверено в том же прогоне:

- идемпотентность подтверждена сравнением: `same_sub_url: True`, `idempotent: True`;
- в `logs/app.log` нет ни кода активации, ни admin-token, ни sub-id
  (`grep` по фактическим значениям — «OK: секретов нет»); в логе только строки
  вида `POST /v1/activate -> 200`, `GET /v1/codes/<redacted>`;
- после прогона `./run.sh stop` → процесс завершился штатно (в логе
  «сервис остановлен вручную»), `run.pid` удалён, порт 8089 свободен,
  runaway-процессов нет;
- тестовая mock-БД (`data/activation.db` с кодами e2e) удалена, чтобы
  развёртывание начиналось с чистой; `.env` (mock) и `logs/app.log` оставлены как
  конфигурация и журнал проверки;
- права: `.env` — 600, `logs/` — 700, `logs/app.log` — 600.

Замечание про TTL: в постановке был «TTL 1 сек», но по контракту минимальный TTL
кода — 60 с (защита от случайных опечаток; `POST /v1/codes` с `ttl_seconds=1`
вернёт 400 `invalid_request`). Поэтому сценарий 410 проверен на минимально
допустимых 60 с с реальным ожиданием — поведение то же. Если для демо/тестов нужен
TTL 1 с, это меняется одной строкой (минимум в `config.py` + `api.py`) с правкой
спеки.

Воспроизвести (коды/токены не печатать в общий лог):

```bash
cd /root/MyHome/vpn-client/server
./run.sh start
ADMIN_TOKEN=$(grep -E '^ADMIN_TOKEN=' .env | cut -d= -f2-)
API=http://127.0.0.1:8089
curl -sS $API/health
CODE=$(curl -sS -X POST $API/v1/codes -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"email":"e2e@example.com","plan":{"days":30,"total_gb":100}}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["code"])')
curl -sS -X POST $API/v1/activate -H 'Content-Type: application/json' \
  -d "{\"code\":\"$CODE\",\"device_id\":\"demo-device-1\"}"
# повтор → idempotent:true; другое устройство → 409; неизвестный код → 404
./run.sh stop
```

---

## 6. Проверка конфигурации и документации

- `.env.example` покрывает все переменные конфигурации из `activation/config.py`
  (28 ключей; проверено сравнением списков — недостающих нет);
- `server/README.md` ссылается на этот файл и описывает `run.sh`;
- тесты после добавления `run.sh`/SIGTERM-обработчика: `python3 -m unittest
  discover` → **Ran 36 tests … OK** (exit 0);
- `bash -n run.sh` — синтаксис ок; `./run.sh bogus` → usage, exit 2.

---

## 7. Что нужно от владельца для боевого запуска

1. **Доступ к панели 3x-ui**: API Token (Settings → Security → API Token) или
   логин/пароль админа. В `.env`: `XUI_MODE=real`, `XUI_BASE_URL`,
   `XUI_WEB_BASE_PATH`, `XUI_API_TOKEN` (или `XUI_USERNAME`/`XUI_PASSWORD`).
2. **Инбаунд**: `XUI_INBOUND_ID` VLESS/Reality, к которому добавлять клиентов;
   при необходимости `XUI_CLIENT_FLOW=xtls-rprx-vision`; `XUI_VERIFY_TLS`
   (1 или 0 для self-signed).
3. **Sub-ссылка**: `SUB_URL_TEMPLATE` из Settings → Subscription панели
   (`https://<sub-host>:2096/sub/{sub_id}` для классики или
   `https://<sub-host>:2096/<subPath>/{sub_id}` для свежих 3.x), проверить
   `curl -sI` → 200 + `Subscription-Userinfo`.
4. **Публичный HTTPS-адрес API** для мобильного приложения: отдельный поддомен +
   TLS (рекомендуется) либо путь с `handle_path`; при работе за прокси —
   `TRUST_PROXY=1`.
5. **Выбор способа автозапуска**: установить systemd-юнит (вариант B) — или
   оставить `run.sh` и запускать вручную после ребута.
6. **Публикация Caddy** (если нужна LAN-проверка): выполнить
   `tools/caddy_publish.py add vpn-activation 8089` самому (меняет `/etc/caddy`).
7. **Бот**: прописать `ACTIVATION_API_URL=http://127.0.0.1:8089` и
   `ACTIVATION_ADMIN_TOKEN` (тот же, что `ADMIN_TOKEN`) в `telegram-agent/.env`;
   хук после подтверждения оплаты — см. `activation-api.md` §12.
8. **Тарифы**: значения по умолчанию (`PLAN_DAYS`, `PLAN_TOTAL_GB`) и решение по
   продлению/отзыву (сейчас тариф задаётся при создании кода).

---

## 8. Диагностика

| Симптом | Что проверить |
|---|---|
| `./run.sh start` → «сервис не ответил» | `tail -n 50 logs/app.log`; занят ли порт: `ss -ltnp \| grep 8089`; есть ли `.env` |
| `{"error":"admin_disabled"}` | в `.env` пуст `ADMIN_TOKEN` |
| `/health` не отвечает | процесс жив? `./run.sh status`; не слушает ли сервис другой порт (`.env` `APP_PORT`) |
| `502 panel_unavailable` при активации | 3x-ui недоступна/неверные креды/`webBasePath`/self-signed TLS; смотри лог (`activation: ошибка панели 3x-ui`) |
| `409 activation_in_progress` | повторная активация идёт; подождать 5 с и повторить (код не сгорел) |
| `address already in use` | остался старый процесс: `pgrep -af run.py`, `./run.sh stop`; либо параллельно запущен systemd-юнит |
| Caddy: `/vpn-activation/` → 502 | сервис не слушает 8089 или маршрут потерян после пересоздания Caddy (повторить `add`) |
| лог растёт | ротация не настроена (по задаче не нужна); для боевого режима — logrotate или journald (systemd) |
