# Сервер активации VPN-клиента (код → sub-ссылка 3x-ui)

Промежуточный сервис между Telegram-ботом (выдаёт код после оплаты) и мобильным
приложением (вводит код, получает sub-ссылку). Прототип на **чистом Python 3
stdout/stdlib**: `http.server` + `sqlite3`, без внешних зависимостей и без pip —
разворачивается на NAS одной командой.

```
клиент платит
   ↓
бот  ──POST /v1/codes (admin-token)──▶  сервис активации  ──addClient──▶  3x-ui
   ↓  отправляет код в Telegram                                              │
клиент вводит код в приложении                                              │
   ↓                                                                        │
приложение ──POST /v1/activate {code, device_id}──▶ сервис ──getClientTraffics──┘
                                                        │
                                     ◀── {sub_url, profile_name, expire, traffic}
   ↓
приложение добавляет профиль по sub-ссылке и поднимает туннель
```

Полная спецификация API: [`../docs/activation-api.md`](../docs/activation-api.md).
Развёртывание на NAS (run.sh, systemd, Caddy, e2e-прогон): [`../docs/deploy-nas.md`](../docs/deploy-nas.md).

## Быстрый старт (mock-панель, без 3x-ui)

```bash
cd /root/MyHome/vpn-client/server
cp .env.example .env && chmod 600 .env
# сгенерировать секреты и вписать их в .env (ADMIN_TOKEN, CODE_PEPPER):
python3 - <<'PY'
import secrets
print("ADMIN_TOKEN=" + secrets.token_urlsafe(32))
print("CODE_PEPPER=" + secrets.token_urlsafe(32))
PY
# XUI_MODE=mock уже стоит в .env.example
./run.sh start        # лог: logs/app.log, pid: run.pid, порт 8089
./run.sh status
```

В другом терминале:

```bash
export ADMIN_TOKEN='...'  # из .env
export API=http://127.0.0.1:8089

# 1) health
curl -sS $API/health

# 2) бот создаёт код для оплатившего клиента
curl -sS -X POST $API/v1/codes \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"email":"client@example.com","plan":{"days":30,"total_gb":100}}'
# → {"code":"...","code_id":"...","client_email":"...","expires_at":"...","ttl_seconds":86400,...}

# 3) приложение активирует код (device_id — стабильный UUID установки приложения)
curl -sS -X POST $API/v1/activate \
  -H 'Content-Type: application/json' \
  -d '{"code":"<код>","device_id":"6f1c2a9e-..."}'
# → {"sub_url":"https://vpn.example.com/sub/...","profile_name":"client@example.com",
#    "expire":"2026-12-01T00:00:00Z","traffic":{...},"client_uuid":"...","idempotent":false}

# 4) повторная активация с того же device_id — идемпотентно, та же ссылка
curl -sS -X POST $API/v1/activate \
  -H 'Content-Type: application/json' \
  -d '{"code":"<код>","device_id":"6f1c2a9e-..."}'
# → {"idempotent":true, "sub_url":"...та же..."}

# 5) проверка статуса кода (бот/админ)
curl -sS -H "Authorization: Bearer $ADMIN_TOKEN" $API/v1/codes/<код>
```

Остановка/логи: `./run.sh stop`, `./run.sh logs`, `./run.sh foreground` (на переднем
плане вместо `start`, для отладки).

## Тесты

```bash
cd /root/MyHome/vpn-client/server
python3 -m unittest discover -v
# Ran 34 tests ... OK
```

Тесты не ходят в сеть и не трогают реальную панель: mock-адаптер 3x-ui +
фейковая HTTP-панель для проверки legacy/modern API, self-signed TLS, CSRF,
логина по cookie и Bearer-токену. Проверяются: создание кода, активация,
идемпотентность, 409 на чужое устройство, 410 на истёкший код, 404, 423 после
лимита попыток, 429 rate-limit, 502 при недоступной панели (и повтор после неё),
отсутствие кодов/токенов в БД и логах.

## Подключение реальной панели 3x-ui

1. В панели создать **API Token**: Settings → Security → API Token (или дать
   сервису логин/пароль). Токен — `XUI_API_TOKEN`, для `real`-режима достаточно его.
2. Заполнить `.env`:

   ```ini
   XUI_MODE=real
   XUI_BASE_URL=https://msk.vitosamintm.ru:34473
   XUI_WEB_BASE_PATH=/TWgF94jug3/
   XUI_API_TOKEN=<токен из панели>
   XUI_INBOUND_ID=<ID инбаунда VLESS/Reality>
   XUI_VERIFY_TLS=1          # 0 — если сертификат самоподписанный
   XUI_CLIENT_FLOW=          # для Reality-инбаунда с flow: xtls-rprx-vision
   SUB_URL_TEMPLATE=https://<sub-host>:2096/<subPath>/{sub_id}
   ```
3. Сначала проверить, как отдаёт API именно эта версия 3x-ui (в 3.11.0 уже есть
   новые `/panel/api/clients/*`, в старых — `/inbounds/addClient`). Режим
   `XUI_CLIENT_API=auto` определит сам; принудительно — `legacy` или `modern`.
4. Взять `subPort` и `subPath` из Settings → Subscription панели и прописать
   `SUB_URL_TEMPLATE`. Проверить: `curl -sI '<sub_url>'` → 200 и заголовок
   `Subscription-Userinfo`.
5. Перезапустить сервис и повторить сценарий из curl-примеров. E2E: выдать код,
   активировать, импортировать ссылку в приложении, поднять туннель.

Чего не хватает для боевого запуска (осознанно не входит в прототип):

- реальных секретов панели (в проекте их нет — только mock-тесты);
- публичного HTTPS-домена для API: приложение должно ходить на
  `https://api.<домен>/v1/activate`. LAN-публикация через Caddy по пути
  (`http://192.168.35.30:9443/vpn-activation/`, префикс срезается `handle_path`)
  годится только для curl-тестов — мобильному клиенту нужен HTTPS;
- шага «подтверждение оплаты» в боте — сервис и готовая функция для бота уже есть;
- решения по тарифам/продлению (сейчас тариф задаётся при создании кода,
  продление через `updateClient` не реализовано).

## Что внутри

| Файл | Назначение |
|---|---|
| `run.py` | запуск сервиса (подхватывает `.env`) |
| `run.sh` | start/stop/status/foreground/logs, pid-файл, лог `logs/app.log` |
| `activation/config.py` | конфиг из env, секреты не попадают в repr |
| `activation/store.py` | SQLite: `codes`, `audit`; HMAC-хэши кодов |
| `activation/xui.py` | клиент 3x-ui (cookie/CSRF/Bearer, legacy+modern, self-signed TLS) + mock-панель |
| `activation/api.py` | HTTP API, Bearer-авторизация, rate-limit, идемпотентность |
| `activation/bot_client.py` | готовая функция/CLI для бота (`create_activation_code`, `format_code_message`) |
| `activation/timeutil.py` | UTC/ISO-время |
| `tests/` | unittest-тесты (API + fake 3x-ui) |

## Эксплуатация на NAS

Вариант «одной командой» — `./run.sh start` (nohup + `run.pid` + `logs/app.log`),
остановка — `./run.sh stop`. Подробно про оба варианта, systemd и публикацию
через Caddy — в [`deploy-nas.md`](../docs/deploy-nas.md). Ниже — unit для systemd
(текст, установка — по желанию владельца):

```ini
# /etc/systemd/system/vpn-activation.service
[Unit]
Description=VPN activation API
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root/MyHome/vpn-client/server
EnvironmentFile=/root/MyHome/vpn-client/server/.env
ExecStart=/usr/bin/python3 /root/MyHome/vpn-client/server/run.py
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl enable --now vpn-activation
journalctl -u vpn-activation -f
```

- Сервис слушает `127.0.0.1:8089`; наружу — только через reverse proxy с TLS.
- `.env` — `chmod 600`; бэкапить `data/activation.db` (в ней коды и аудит).
- Логи не содержат кодов, токенов и sub-ссылок — это проверяется тестом.
- rate-limit хранится в памяти процесса: при нескольких воркерах/репликах нужен
  общий лимитер (Redis) — для прототипа достаточно одного процесса.
- Бот интегрируется через `activation/bot_client.py`; инструкция и патч —
  в [спецификации, раздел «Интеграция с ботом»](../docs/activation-api.md#12-интеграция-с-ботом).

## Безопасность коротко

- код: `secrets.token_urlsafe(16)` (~128 бит), в БД только `HMAC-SHA256(CODE_PEPPER, code)`;
- код показывается один раз (в ответе `POST /v1/codes`) и никогда не пишется в логи/аудит;
- админка — `Authorization: Bearer <ADMIN_TOKEN>` (сравнение constant-time);
- одно устройство на код: повтор с тем же `device_id` идемпотентен, с другим — `409`;
- лимит попыток на код (`423`), rate-limit по IP (`429`), `Cache-Control: no-store`;
- при недоступной панели код возвращается в `pending`, клиент получает `502` и может повторить.
