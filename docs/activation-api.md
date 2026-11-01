# API активации VPN-сервиса (v1)

Спецификация серверной части активации для продукта на панели **3x-ui
(VLESS/Reality)** и мобильного клиента. Реализация — прототип в
[`vpn-client/server/`](../server/README.md): Python 3 stdlib, SQLite, mock-адаптер
3x-ui, 35 тестов без сети.

Схема продукта:

```
клиент оплатил
  → бот создаёт код (POST /v1/codes, admin-token) и отправляет его пользователю
  → пользователь вводит код в приложении
  → приложение: POST /v1/activate {code, device_id}
  → сервис: находит/создаёт клиента в 3x-ui, собирает sub-ссылку
  → приложение получает {sub_url, profile_name, expire, traffic}, добавляет профиль,
    поднимает туннель; дальше обновляет подписку по sub-ссылке
```

Код одноразовый, с TTL, привязан к email клиента в панели и к одному
устройству (device_id). Повторная активация тем же device_id идемпотентна.

---

## 1. Общие положения

| Параметр | Значение |
|---|---|
| Base URL (dev) | `http://127.0.0.1:8089` |
| Base URL (prod) | `https://<домен-API>/v1/...` — TLS обязателен, см. §11 |
| Формат | JSON, UTF-8, `Content-Type: application/json` |
| Версия | префикс `/v1`; ломающие изменения → `/v2` |
| Время | UTC, ISO-8601 `YYYY-MM-DDTHH:MM:SSZ`; также `*_unix` в секундах |
| Размер тела | ≤ 8 КБ (`MAX_BODY_BYTES`) |
| Ответы | `Cache-Control: no-store`, `X-Content-Type-Options: nosniff` |
| Секреты | admin-token и коды не попадают в логи; sub-ссылка — секрет, не логируется |

Формат ошибки (всегда):

```json
{"error": "code_expired", "message": "Срок действия кода истёк"}
```

`error` — стабильный машинный код (для логики приложения), `message` — текст для
показа человеку (можно заменить своей локализацией по `error`). У `429` есть
заголовок `Retry-After` (секунды).

Сводка статусов: `200 OK`, `201 Created` (создан код), `400` — неверный запрос,
`401` — нет/неверный admin-token, `403` — код отозван, `404` — не найдено,
`405` — метод, `409` — конфликт/код уже активирован/идёт активация,
`410` — код истёк, `413` — тело больше лимита, `423` — код заблокирован,
`429` — rate-limit, `500` — внутренняя ошибка, `502` — панель 3x-ui недоступна,
`503` — админка не настроена.

## 2. Аутентификация

- **Публичные** эндпоинты: `GET /health`, `POST /v1/activate` (сам код — и есть
  аутентификация).
- **Админские** (для бота и админа): `POST /v1/codes`, `GET /v1/codes/{code}`.
  Заголовок `Authorization: Bearer <ADMIN_TOKEN>`. Сравнение токена —
  constant-time (`hmac.compare_digest`). Если `ADMIN_TOKEN` в конфиге пуст,
  админ-эндпоинты отвечают `503 admin_disabled` (осознанно, чтобы не открыть
  выдачу кодов случайно).
- Необязательный заголовок `X-Admin-Actor: bot` попадает в аудит вместо `admin`.
- Мобильное приложение не хранит admin-token: ему доступен только `/v1/activate`.

## 3. `POST /v1/activate` — активация кода (публичный)

Запрос:

```json
{
  "code": "Yq3k9Zc2mS1xT7pR4wB6vA",
  "device_id": "6f1c2a9e-1b2d-4c3f-8a9b-0d1e2f3a4b5c"
}
```

| Поле | Тип | Обяз. | Ограничения |
|---|---|---|---|
| `code` | string | да | 8–256 символов `[A-Za-z0-9_-]` (формат `secrets.token_urlsafe`) |
| `device_id` | string | да | 1–128 символов `[A-Za-z0-9._:-]`; стабильный идентификатор установки приложения (UUID, хранится в защищённом хранилище; **не** IMEI/IDFA) |

Успех `200`:

```json
{
  "sub_url": "https://<sub-host>:2096/<subPath>/i7tvdpeffi0hvvf1",
  "profile_name": "client@example.com",
  "expire": "2026-12-01T00:00:00Z",
  "expire_unix": 1796083200,
  "traffic": {
    "up_bytes": 0,
    "down_bytes": 0,
    "used_bytes": 0,
    "total_bytes": 10737418240,
    "remaining_bytes": 10737418240,
    "unlimited": false
  },
  "client_uuid": "e18c9a96-71bf-48d4-933f-8b9a46d4290c",
  "idempotent": false,
  "activated_at": "2026-11-01T00:00:00Z"
}
```

| Поле | Смысл |
|---|---|
| `sub_url` | суб-ссылка 3x-ui; приложение добавляет её как профиль/подписку |
| `profile_name` | имя профиля (`PROFILE_NAME_TEMPLATE`, по умолчанию email) |
| `expire` | срок действия в ISO UTC или `null` (бессрочно) |
| `expire_unix` | то же в Unix-секундах или `null` |
| `traffic` | снимок трафика клиента на момент активации; `total_bytes=0` и `unlimited=true` — без лимита |
| `client_uuid` | UUID клиента в Xray (для поддержки/диагностики) |
| `idempotent` | `true` — это повторная активация того же устройства, ответ идентичен первому |
| `activated_at` | когда код был активирован |

Поведение:

| Ситуация | Ответ |
|---|---|
| код не найден | `404 code_not_found` |
| код истёк (TTL) | `410 code_expired`; статус кода становится `expired` |
| код отозван (перевыпуск/бан) | `403 code_revoked` |
| код уже активирован этим `device_id` | `200`, поле `idempotent: true`, та же `sub_url`; в панель не ходим (отдаём сохранённый снимок) |
| код уже активирован другим `device_id` | `409 code_already_used`; попытка засчитывается в лимит `MAX_CODE_ATTEMPTS`, после — `423 code_locked` |
| идёт активация другого/того же устройства (свежая) | `409 activation_in_progress` + `Retry-After: 5`; приложение повторяет через 3–5 с |
| активация «зависла» (> `PROVISIONING_STALE_SECONDS`) | то же устройство может повторить: код перезабирается и активация продолжается |
| панель 3x-ui недоступна | `502 panel_unavailable`; код возвращается в `pending`, можно повторить позже |
| слишком много запросов с IP | `429 rate_limited` + `Retry-After` |

Приложение должно повторять запрос только при `409 activation_in_progress`,
`429` и `502`; на `404/403/410/423` — показывать сообщение, код не повторять.

## 4. `POST /v1/codes` — создать код (админ, для бота)

Запрос:

```json
{
  "email": "client@example.com",
  "plan": {"days": 30, "total_gb": 100},
  "ttl_seconds": 86400,
  "note": "заказ #123"
}
```

| Поле | Тип | Обяз. | По умолчанию / ограничения |
|---|---|---|---|
| `email` | string | да | уникальный email клиента в 3x-ui (≤254, формат `x@y`) |
| `client_uuid` | string | нет | UUID клиента; иначе панель найдёт клиента по email или сгенерирует UUID при активации |
| `sub_id` | string | нет | Sub ID для sub-ссылки; 8–64 `[A-Za-z0-9_-]`; иначе сгенерируется |
| `ttl_seconds` | int | нет | TTL кода, `CODE_TTL_SECONDS` (60…2592000, т.е. до 30 суток) |
| `plan.days` | int | нет | `PLAN_DAYS` (0 = без срока, 0…3650) |
| `plan.total_gb` | number | нет | `PLAN_TOTAL_GB` (0 = без лимита, 0…1e6) |
| `note` | string | нет | ≤200, для админа (в аудит) |

Ответ `201` (код в открытом виде — **единственный раз**, сохраните его до отправки
пользователю):

```json
{
  "code": "Yq3k9Zc2mS1xT7pR4wB6vA",
  "code_id": "2f0d3c1a8b7e",
  "client_email": "client@example.com",
  "client_uuid": null,
  "expires_at": "2026-11-02T00:00:00Z",
  "ttl_seconds": 86400,
  "plan": {"days": 30, "total_gb": 100}
}
```

Особенности:

- При создании нового кода для того же email прежние **неиспользованные** коды
  этого email отзываются (`revoked`), чтобы «потерянный» код не остался рабочим.
  Уже активированные коды не затрагиваются.
- Клиент в 3x-ui создаётся **в момент активации** (find-or-create):
  экономит панель, не плодит клиентов для неактивированных кодов. Если клиент с
  таким email уже есть (например, бот создал заранее), используется он, sub-ссылка
  не меняется.
- Плата/проверка оплаты — на стороне бота; сервис кодов ничего не знает про деньги.

## 5. `GET /v1/codes/{code}` — статус кода (админ, для бота/поддержки)

`200`:

```json
{
  "code_id": "2f0d3c1a8b7e",
  "client_email": "client@example.com",
  "client_uuid": null,
  "status": "pending",
  "created_at": "2026-11-01T00:00:00Z",
  "expires_at": "2026-11-02T00:00:00Z",
  "used_at": null,
  "device_id": null,
  "attempts": 0,
  "plan": {"days": 30, "total_gb": 100}
}
```

- `status`: `pending` | `activating` | `active` | `expired` | `locked` | `revoked`.
  Для просроченного `pending` в ответе отдаётся `expired` (без изменения записи).
- `sub_url` и sub-id в ответе **не отдаются** (это доступ к VPN); админ может
  посмотреть клиента в панели.
- Код в URL — секрет; в логах путь маскируется (`/v1/codes/<redacted>`).

## 6. `GET /health` — живость

`200`:

```json
{"status": "ok", "service": "vpn-activation", "version": "1.0.0", "mode": "mock", "db": "ok", "time": "2026-11-01T00:00:00Z"}
```

`mode`: `mock` (без панели) или `real`. Панель не опрашивается (health не должен
зависеть от 3x-ui); `status=degraded`, если БД недоступна.

---

## 7. Коды ошибок

| HTTP | `error` | Когда | Что делать приложению |
|---|---|---|---|
| 400 | `invalid_request` | нет/неверные поля, неверный JSON, неверный формат кода/device_id | показать ошибку, не повторять |
| 401 | `unauthorized` | нет/неверный admin-token | проверить токен бота/админа |
| 403 | `code_revoked` | код отозван (перевыпуск) | «код устарел, запросите новый» |
| 404 | `code_not_found` | код не существует | «код не найден, проверьте ввод» |
| 404 | `not_found` | нет такого эндпоинта | ошибка клиента |
| 405 | `method_not_allowed` | неверный HTTP-метод | ошибка клиента |
| 409 | `code_already_used` | код активирован другим устройством | «код уже использован» |
| 409 | `activation_in_progress` | параллельная активация/зависла | повторить через 3–5 с (`Retry-After`) |
| 410 | `code_expired` | TTL истёк | «код истёк, запросите новый» |
| 413 | `payload_too_large` | тело > `MAX_BODY_BYTES` | ошибка клиента |
| 423 | `code_locked` | исчерпаны `MAX_CODE_ATTEMPTS` | «код заблокирован, обратитесь в поддержку» |
| 429 | `rate_limited` | превышен лимит запросов с IP | повторить после `Retry-After` |
| 500 | `internal_error` | баг/сбой БД | повторить, сообщить админу |
| 502 | `panel_unavailable` | 3x-ui недоступна/ошибка API | повторить позже (код не сгорает) |
| 503 | `admin_disabled` | `ADMIN_TOKEN` не задан | ошибка конфигурации сервиса |

---

## 8. Rate-limit и лимиты

| Лимит | Переменная | Значение по умолчанию |
|---|---|---|
| `/v1/activate` с одного IP | `RATE_ACTIVATE_PER_MIN` | 10 / 60 с |
| админ-эндпоинты с одного IP | `RATE_ADMIN_PER_MIN` | 60 / 60 с |
| неудачных активаций на код | `MAX_CODE_ATTEMPTS` | 10 → `423` |
| «зависшая» активация | `PROVISIONING_STALE_SECONDS` | 120 с |
| тело запроса | `MAX_BODY_BYTES` | 8192 байт |
| TTL кода | `CODE_TTL_SECONDS` | 86400 с (24 ч) |

Счётчики хранятся в памяти процесса (прототип, один процесс). При нескольких
воркерах/репликах нужен общий лимитер (Redis и т.п.). IP берётся из соединения;
при работе за reverse proxy включить `TRUST_PROXY=1` (тогда используется первый
`X-Forwarded-For`; прокси обязан перезаписывать заголовок).

---

## 9. Идемпотентность и состояния

Состояния кода:

```
pending ──claim──▶ activating ──успех панели──▶ active
   │                  │
   │                  └─ошибка панели──▶ pending (можно повторить)
   ├──TTL истёк──────▶ expired
   ├──перевыпуск─────▶ revoked
   └──attempts≥N─────▶ locked   (active тоже можно залочить попытками)
```

Правила:

1. **Один код — одно устройство.** Повтор с тем же `device_id` → `200` и тот же
   ответ (`idempotent: true`), без обращения к панели. Другой `device_id` →
   `409`, каждая такая попытка увеличивает счётчик и может довести до `423`.
2. **Конкурентные запросы.** Победитель атомарно переводит код
   `pending → activating` (`UPDATE ... WHERE status='pending'`). Остальные
   получают `409 activation_in_progress` c `Retry-After`.
3. **Сбой панели.** Код возвращается в `pending` (claim откатывается), клиенту
   `502`; повтор безопасен.
4. **Снимок ответа.** Успешный ответ сохраняется в `codes.result_json`; повторная
   активация того же устройства отдаёт его без запросов в 3x-ui.
5. **TTL.** Активировать можно только код в `pending` и до `expires_at`;
   активация, начатая до истечения TTL, доводится до конца.
6. **Перевыпуск.** Новый код для того же email отзывает неиспользованные старые
   (`revoked`), чтобы утёкший/потерянный код не остался рабочим.

---

## 10. Безопасность

**Код активации**

- генерируется `secrets.token_urlsafe(16)` (~128 бит энтропии, 22 символа
  `[A-Za-z0-9_-]`); подбор нереален, rate-limit — дополнительный барьер;
- в БД хранится только `HMAC-SHA256(CODE_PEPPER, code)`; открытый код
  возвращается **ровно один раз** — в ответе `POST /v1/codes` — и не хранится;
- компромисс: если пользователь потерял код до активации, показать его повторно
  нельзя (в БД нет открытого значения) — бот/админ выпускает новый код, старый
  при этом отзывается. Это осознанная плата за то, что утечка БД не даёт готовых
  кодов;
- `CODE_PEPPER` — серверный секрет (`.env`, `chmod 600`); его смена
  инвалидирует все выданные коды; pepper не хранится в БД;
- TTL ограничен (по умолчанию 24 ч, максимум 30 суток);
- коды не пишутся в логи и аудит (в аудите — только `code_id` = первые 12 hex
  символов хэша). Тест `LogPrivacyTest` проверяет отсутствие кода, admin-token и
  sub-ссылки в логах;
- аудит в SQLite: создание/активация/конфликт/ошибка панели/отзыв (без секретов).

**Устройство**

- `device_id` генерирует приложение (UUID) при первой установке и хранит локально
  в защищённом хранилище; сервер привязывает код к одному `device_id`;
- это ограничение **на уровне кода активации**, а не подписки: одна и та же
  sub-ссылка технически может быть импортирована на нескольких устройствах.
  Для жёсткого ограничения устройств использовать возможности 3x-ui
  (`limitIp`, HWID-лимиты подписки) или отдельный device-bound flow — вне MVP;
- при переустановке приложения device_id меняется → нужен новый код
  (старый вернёт `409`), это ожидаемо.

**Транспорт и доступ**

- прод: только HTTPS (TLS на reverse proxy), API не публиковать по HTTP;
- админ-эндпоинты доступны только боту/админу по Bearer-токену; mobile-приложение
  их не использует;
- сервис слушает `127.0.0.1`; наружу — один reverse proxy;
- в ответах нет CORS-заголовков (нативному приложению не нужны; для web-клиента
  добавить отдельно и явно).

**Чего нет в прототипе (следующие шаги)**

- эндпоинта отзыва/перевыпуска кода по API (сейчас — новый код отзывает старые;
  ручной отзыв — через БД/будущий `POST /v1/codes/{code}/revoke`);
- продления подписки (`POST /panel/api/inbounds/updateClient/<uuid>` /
  `/panel/api/clients/update/<email>`) — тариф задаётся при создании кода;
- метрик/Prometheus, уведомлений админу о 5xx;
- общей БД rate-limit для нескольких воркеров.

---

## 11. Интеграция с 3x-ui

Официальная документация панели: [API Reference](https://docs.sanaei.dev/docs/reference/api/),
[Authentication](https://docs.sanaei.dev/docs/reference/api/authentication/),
[Inbounds](https://docs.sanaei.dev/docs/reference/api/inbounds/),
[Clients](https://docs.sanaei.dev/docs/reference/api/clients/),
[Subscription server](https://docs.sanaei.dev/docs/reference/api/subscription-server/),
[Subscription config](https://docs.sanaei.dev/docs/config/subscription/).

Используются REST-эндпоинты панели (все — под `webBasePath`, если он задан):
`POST /login`, `POST /panel/api/inbounds/addClient`,
`POST /panel/api/inbounds/updateClient/<uuid>` (продление, в MVP не используется),
`GET /panel/api/inbounds/getClientTraffics/<email>`, а в свежих 3.x — аналоги
`POST /panel/api/clients/add`, `GET /panel/api/clients/get/<email>`,
`GET /panel/api/clients/traffic/<email>`.

### 11.1 Авторизация

| Способ | Как | Когда |
|---|---|---|
| Cookie-сессия | `POST {root}/login` (`username`,`password`; классика — form-urlencoded, свежие — JSON), cookie `3x-ui`; для POST в новых 3.x нужен `X-CSRF-Token` из `GET {root}/csrf-token` | есть логин/пароль панели |
| Bearer API Token | `Authorization: Bearer <token>` (Settings → Security → API Token в панели) | рекомендуется, если версия панели поддерживает |

`root` = `XUI_BASE_URL` + `XUI_WEB_BASE_PATH` (например
`https://<panel-host>:34473/<webBasePath>`). Таймауты (`XUI_TIMEOUT`), self-signed
TLS (`XUI_VERIFY_TLS=0`), повторный логин при истёкшей сессии — реализованы в
`activation/xui.py`. Ошибка входа → `PanelAuthError` → сервис вернёт `502`.

### 11.2 Клиенты: legacy и modern API

Версии 3x-ui отличаются раскладкой эндпоинтов; `XUI_CLIENT_API=auto` определяет
по первому `GET /panel/api/clients/get/<email>`:

| Действие | Legacy (классика, 2.x–3.x) | Modern (свежие 3.x) |
|---|---|---|
| найти клиента | `GET /panel/api/inbounds/list` → `settings.clients[]` по email | `GET /panel/api/clients/get/<email>` |
| создать клиента | `POST /panel/api/inbounds/addClient` `{"id": <inbound>, "settings": "<json-строка>"}` | `POST /panel/api/clients/add` `{"client": {...}, "inboundIds": [<inbound>]}` |
| трафик | `GET /panel/api/inbounds/getClientTraffics/<email>` | `GET /panel/api/clients/traffic/<email>` |
| обновить (продление) | `POST /panel/api/inbounds/updateClient/<uuid>` | `POST /panel/api/clients/update/<email>` |

Пример legacy `addClient` (поля клиента — как в панели):

```json
{
  "id": 1,
  "settings": "{\"clients\":[{\"id\":\"<uuid>\",\"flow\":\"xtls-rprx-vision\",\"email\":\"client@example.com\",\"limitIp\":0,\"totalGB\":107374182400,\"expiryTime\":1796083200000,\"enable\":true,\"tgId\":0,\"subId\":\"i7tvdpeffi0hvvf1\",\"reset\":0}]}"
}
```

| Поле клиента | Смысл |
|---|---|
| `id` | UUID клиента Xray (VLESS/VMess); для Trojan/SS — пароль |
| `email` | уникальный идентификатор клиента в панели; используем как ключ |
| `subId` | Sub ID подписки; **панель не генерирует его при создании через API** (issue [#3237](https://github.com/MHSanaei/3x-ui/issues/3237)) — генерируем сами (16 hex) |
| `expiryTime` | срок в **миллисекундах**; `0` — бессрочно |
| `totalGB` | лимит трафика в **байтах**; `0` — без лимита |
| `limitIp` | лимит IP (0 — без лимита) |
| `flow` | для VLESS+Reality/TLS обычно `xtls-rprx-vision` (`XUI_CLIENT_FLOW`), иначе пусто |
| `enable` | `true` |
| `tgId`, `reset` | `0` |

### 11.3 Sub-ссылка

Формат зависит от версии панели:

- **классический** 3x-ui: отдельный порт подписок (`subPort`, по умолчанию
  `2096`) и путь `/sub/<subId>`; `webBasePath` к этому пути не применяется:
  `https://<sub-host>:2096/sub/<subId>`;
- **свежие 3.x**: отдельный subscription-сервер, у каждой панели свой случайный
  `subPath`, URL вида `https://<sub-host>:<sub-port>/<subPath>/<subId>`
  (см. [Subscription](https://docs.sanaei.dev/docs/config/subscription/)).

Поэтому базовый формат `{base}/sub/{subId}` из постановки учтён, а конкретный URL
задаётся шаблоном `XUI_SUB_URL_TEMPLATE` (плейсхолдер `{sub_id}`), например:

```ini
# классика
SUB_URL_TEMPLATE=https://msk.example.com:2096/sub/{sub_id}
# новый subscription-сервер (subPort/subPath — из Settings → Subscription)
SUB_URL_TEMPLATE=https://sub.example.com:2096/AbCdEf123/{sub_id}
```

Если шаблон не задан в `real`-режиме, собирается
`{XUI_BASE_URL}/sub/{sub_id}` (классический вариант). Проверка после настройки:
`curl -sI '<sub_url с реальным subId>'` → `200` и заголовок
`Subscription-Userinfo: upload=...; download=...; total=...; expire=...`
(в приложении эта ссылка — источник обновления профиля).

### 11.4 Чек-лист «поставить на панель» (без паролей в репозитории)

1. Создать API Token в панели (или отдельного админа) — только для сервиса.
2. Определить раскладку API: `curl -sk -H "Authorization: Bearer <token>"
   '<panel-root>/panel/api/clients/list'` — если `200`/JSON, панель modern;
   если `404` — legacy (для legacy: `/panel/api/inbounds/list`).
3. Узнать `XUI_INBOUND_ID` инбаунда VLESS/Reality (Inbounds в панели).
4. Узнать `subPort` и `subPath` в Settings → Subscription и прописать
   `SUB_URL_TEMPLATE`.
5. Проверить, нужен ли `flow` (для Reality-инбаунда с `xtls-rprx-vision` —
   `XUI_CLIENT_FLOW=xtls-rprx-vision`).
6. `XUI_VERIFY_TLS=1`, если сертификат панели валиден; `0` — self-signed.
7. Прогнать сценарий: создать код → активировать → открыть sub-ссылку →
   импортировать в тестовый Xray/приложение → туннель поднялся.

Прод-серверы (`msk.vitosamintm.ru`, `pl.vitosamintm.ru`) из этого репозитория не
трогаются: в прототипе нет паролей, все тесты — на mock/fake-панели.

---

## 12. Интеграция с ботом

Текущий бот — `/root/MyHome/telegram-agent/bot.py` (stdlib, long polling). Его
**не нужно переписывать**: после подтверждения оплаты он вызывает готовую функцию
из `server/activation/bot_client.py`.

Добавить в `telegram-agent/.env`:

```ini
ACTIVATION_API_URL=http://127.0.0.1:8089
ACTIVATION_ADMIN_TOKEN=<тот же ADMIN_TOKEN, что у сервиса>
```

Функция (готовая, в `server/activation/bot_client.py`):

```python
from activation.bot_client import (
    ActivationApiError, create_activation_code, format_code_message,
)

def send_activation_code(chat_id: int, email: str, plan_days: int = 30, total_gb: float = 0.0) -> None:
    try:
        info = create_activation_code(
            email=email, plan_days=plan_days, total_gb=total_gb,
        )
    except ActivationApiError as error:
        log(f"активация: ошибка {error.code}: {error.message}")
        send(chat_id, f"Не удалось выдать код: {error.message}")
        return
    send(chat_id, format_code_message(info))
```

Минимальный патч `bot.py` (импорт + вызов в обработчике подтверждения оплаты;
сейчас платежей в боте нет — точку вызова определяет сценарий оплаты):

```python
# в начало bot.py, после импортов
import sys
sys.path.insert(0, "/root/MyHome/vpn-client/server")
from activation.bot_client import (  # noqa: E402
    ActivationApiError, create_activation_code, format_code_message,
)

# ... в том месте, где подтверждена оплата (webhook/проверка/команда админа):
if payment_confirmed and user_email:
    try:
        info = create_activation_code(email=user_email, plan_days=30, total_gb=100)
        send(chat_id, format_code_message(info))
    except ActivationApiError as error:
        log(f"активация: {error.code}: {error.message}")
        send(chat_id, "Оплата прошла, но выдача кода не удалась — поддержка уже уведомлена.")
```

Этот патч в репозиторий не применён (бот рабочий, интеграция — по согласованию).
Если платежи приходят вручную, тот же вызов можно повесить на админ-команду
`/paid <email>` (проверка `allowed(chat_id)` в боте уже есть).

CLI для проверки/ручной выдачи (из каталога `server/`):

```bash
python3 -m activation.bot_client create --email client@example.com --days 30 --gb 100
python3 -m activation.bot_client status --code '<код>'
```

Пример сообщения пользователю (`format_code_message`):

```
🎟 Код активации VPN

Yq3k9Zc2mS1xT7pR4wB6vA

Введи этот код в приложении в поле «Код активации».
Код одноразовый, действует до 02.11.2026 00:00 UTC.
Тариф: 30 дн., 100 ГБ трафика.
```

Сценарий бот ↔ сервис:

1. оплата подтверждена (в боте);
2. `POST /v1/codes` с `email` и тарифом → бот получает `code` (открытый код
   больше нигде не сохраняется);
3. бот отправляет код в Telegram;
4. пользователь вводит код в приложении → `POST /v1/activate`;
5. бот при необходимости проверяет статус: `GET /v1/codes/<code>`.

---

## 13. Развёртывание

- Сервис: `python3 run.py` (см. [server/README](../server/README.md)); `.env`
  `chmod 600`; systemd-юнит — в README.
- Порт `127.0.0.1:8089`; наружу — reverse proxy с TLS (Caddy/nginx).
  Публичная точка для приложения: `https://<домен-API>/v1/activate`.
  Для тестов в лаборатории допустима публикация по пути
  `http://192.168.35.30:9443/vpn-activate/` (`tools/caddy_publish.py add
  vpn-activate 8089`), но приложение на телефоне должно ходить по HTTPS-домену.
- SQLite `data/activation.db`: бэкапить вместе с аудитом; WAL-режим.
- Логи — stdout/journald; в них нет секретов.
- Мониторинг: `GET /health` + алерт на 5xx/502 (панель).
- При публикации за прокси: `TRUST_PROXY=1` для корректного rate-limit по IP.

End-to-end проверка после подключения панели:

```bash
# 1. код
CODE=$(curl -sS -X POST https://<домен-API>/v1/codes \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"email":"test@example.com","plan":{"days":1,"total_gb":1}}' | jq -r .code)
# 2. активация
curl -sS -X POST https://<домен-API>/v1/activate -H 'Content-Type: application/json' \
  -d "{\"code\":\"$CODE\",\"device_id\":\"e2e-test-device-01\"}" | jq .
# 3. sub-ссылка отвечает
curl -sI '<sub_url из ответа>' | head
# 4. повтор идемпотентен, другое устройство → 409
```

---

## 14. Открытые вопросы / следующие шаги

1. **Оплата** — как бот узнаёт о подтверждении (провайдер, вебхук, ручная
   команда) и кто выдаёт код: это решается в боте, сервис уже готов.
2. **Продление/смена тарифа** — нужен `updateClient` (`expiryTime`, `totalGB`)
   и, вероятно, отдельный эндпоинт `POST /v1/subscriptions/renew`; схема кодов
   уже хранит тариф.
3. **Отзыв кода/подписки** — добавить `POST /v1/codes/{code}/revoke` и,
   при необходимости, удаление/отключение клиента в панели.
4. **Ограничение устройств** — решить, достаточно ли `device_id`-привязки или
   нужны `limitIp`/HWID в 3x-ui; от этого зависит UX переустановки приложения.
5. **Реальные креды панели** — API Token (рекомендуется) или админ; хранится
   только в `.env` на NAS, не в git.
6. **Домен/TLS для API** — приложению нужен стабильный HTTPS-адрес.
7. **Наблюдаемость** — метрики активаций/ошибок панели, алерты.
8. **Мультипроцесс** — общий rate-limit (Redis) и внешняя БД, если появятся
   реплики; текущий прототип рассчитан на один процесс.
