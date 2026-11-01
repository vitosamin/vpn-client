# Реализация: активация по коду, deep-link `vpn://activate`, RU→direct

**Статус: готово.** Ветка `feat/activation-onboarding` в worktree
`/root/MyHome/vpn-client/app-feat` (основной `app/` не трогался).

| | |
|---|---|
| Коммиты | `277883b` feat(activation): activate a profile by code and the vpn://activate link<br>`4ae99d5` feat(settings): default the region to Russia |
| `flutter analyze` | **No issues found** (0 errors / 0 warnings / 0 infos) |
| Тесты | **266 passed**, из них 9 новых в `test/features/activation/activation_test.dart` |
| Debug APK | `app-feat/build/app/outputs/flutter-apk/app-debug.apk` (251 МБ, universal debug, 3 ABI) |
| Сборка | `flutter build apk --debug` → `BUILD_EXIT=0` |
| Контракт API | проверен вживую против mock-сервиса (см. §4) |

---

## 1. Что сделано

### 1.1. Клиент API активации (пункт 1)

Новый модуль `lib/features/activation/`, по структуре как `lib/features/app_update/`:

| Файл | Что |
|---|---|
| `activation_constants.dart` | `ActivationConst.apiBaseUrl` = `String.fromEnvironment('activation_api', defaultValue: 'https://activation.invalid')`, ключ `activation_device_id`, regex кода `^[A-Za-z0-9_-]{8,256}$`, границы авторетрая; `ActivationLink.scheme='vpn'`, `activateHost='activate'` |
| `model/activation_result.dart` | freezed-модель ответа: `sub_url`, `profile_name`, `expire`/`expire_unix`, `traffic{}`, `client_uuid`, `idempotent`, `activated_at`; геттеры `preferredName`, `expireDate`, `traffic.remaining/isUnlimited` |
| `model/activation_failure.dart` | sealed-фейлы по машинным кодам + `present(TranslationsEn)` |
| `data/activation_repository.dart` | `POST {base}/v1/activate {code, device_id}`, маппинг статусов, `Retry-After` |
| `data/activation_data_providers.dart` | `activationRepositoryProvider`, `deviceIdProvider` |
| `notifier/activation_notifier.dart` | state-машина: idle / loading / result / error; автоповтор только для `409 activation_in_progress`; после успеха — добавление профиля |
| `overview/activation_page.dart` | экран активации |

Маппинг ошибок (`activation_repository.dart`, метод `_mapError`):

| Статус API | Машинный код | Фейл в приложении |
|---|---|---|
| 400 / 413 | — | `invalidRequest` |
| 403 | `code_revoked` | `codeRevoked` |
| 404 | `code_not_found` | `codeNotFound` |
| 409 | `activation_in_progress` | `activationInProgress(retryAfter)` → один автоповтор |
| 409 | `code_already_used` | `codeAlreadyUsed` |
| 410 | `code_expired` | `codeExpired` |
| 423 | `code_locked` | `codeLocked` |
| 429 | `rate_limited` | `rateLimited(retryAfter)` |
| 502 | `panel_unavailable` | `panelUnavailable` |
| 503 | — | `serviceUnavailable` |
| ответа нет | — | `network` (офлайн/DNS/TLS/timeout) |

Секреты не логируются: в лог уходят только HTTP-статус и машинный код
(`loggy.warning('activation request failed: $status $machineCode')`), ни код активации, ни `sub_url`.

`device_id`: стабильный UUID v4 установки в `SharedPreferences` (ключ `activation_device_id`),
генерируется один раз; это не hardware id. API считает повтор с тем же id идемпотентным
(`docs/activation-api.md` §3), поэтому значение переживает перезапуски.

В `lib/core/http_client/dio_http_client.dart` добавлен `post()` — JSON-POST в том же стиле, что
`get()`: тот же UA/прокси-режим, но **с выключенным общим retry** (`Options.disableRetry`), потому
что POST не идемпотентен и повторы решает вызывающий код.

### 1.2. Экран ввода кода (пункт 2)

`lib/features/activation/overview/activation_page.dart` — route `/activate`, параметр `code`:

- поле кода (`CustomTextFormField`) с валидацией (пусто / не тот формат), кнопка «Вставить» из
  буфера (если пусто — тост «в буфере нет кода»);
- кнопка «Активировать», состояние загрузки со спиннером, карточка ошибки с кнопкой повтора;
- экран успеха: «Профиль “…” добавлен и активен», срок действия, остаток трафика, кнопка «Готово»;
- если код пришёл из deep-link — подставляется и активация стартует сразу (один тап экономится).

Точки входа (FixBtns не трогал, счётчик кнопок не менялся):
- иконка ключа в AppBar главного экрана (`lib/features/home/widget/home_page.dart`);
- ссылка «Уже есть код?» на экране онбординга (`lib/features/intro/widget/intro_page.dart`);
- deep-link (§1.3).

Локализация: строки добавлены в `assets/translations/en.i18n.json` и `ru.i18n.json`
(`pages.activation.*`, `errors.activation.*`), сгенерировано `dart run slang`; остальные 9 локалей
наследуют английский (slang fallback base_locale), т.е. пустых строк не будет.

### 1.3. Deep-link `vpn://activate?code=...` (пункт 3)

| Где | Что |
|---|---|
| `android/app/src/main/AndroidManifest.xml` | `<data android:scheme="vpn"/>` в существующий VIEW intent-filter |
| `ios/Runner/Info.plist` | `vpn` в `CFBundleURLSchemes` (`FlutterDeepLinkingEnabled` уже true) |
| `lib/core/router/go_router/routing_config_notifier.dart` | ветка в `redirect`: `scheme=='vpn'` → принимается **только** host `activate`, код берётся из `code` и редирект на `/activate`; любой другой `vpn://…` → `/home` (никаких произвольных URL/route); route `/activate` рядом с `/intro` |

Защита: схема не открывает произвольные маршруты и не загружает внешние URL — только свой экран;
страница активации разрешена до завершения онбординга (человек после оплаты не должен искать кнопку),
выход с неё — `/home` или `/intro` по флагу `introCompleted`.

### 1.4. Код → профиль (пункт 4)

`ActivationNotifier._storeProfile` вызывает
`ProfileRepository.upsertRemote(sub_url, userOverride: UserOverride(name: profile_name))`.
`ProfileDao.insert` при `active=true` снимает active с остальных, поэтому новый профиль сразу
активный; подписка обновляется штатным механизмом (заголовки 3x-ui `subscription-userinfo` и т.д.).
Если API ответил, а профиль добавить не удалось — отдельный фейл `profileFailed` (код не «сгорает»:
повторная активация тем же device_id идемпотентна).

### 1.5. RU→direct по умолчанию (пункт 5)

`lib/features/settings/data/config_option_repository.dart`: default `ConfigOptions.region` —
`Region.ru` вместо `Region.other` (единственная содержательная строка + комментарий). Правило
`bypassRegion` (`rules_notifier.dart`) уже включено по умолчанию и для `region=ru` даёт
`geosite-ru + geoip-ru → direct` + direct DNS. Логика других регионов не менялась; интро по-прежнему
переопределяет регион по таймзоне.

---

## 2. Файлы

Новые (8):

```
lib/features/activation/activation_constants.dart
lib/features/activation/data/activation_data_providers.dart
lib/features/activation/data/activation_repository.dart
lib/features/activation/model/activation_failure.dart
lib/features/activation/model/activation_result.dart
lib/features/activation/notifier/activation_notifier.dart
lib/features/activation/overview/activation_page.dart
test/features/activation/activation_test.dart
```

Изменённые (9):

```
android/app/src/main/AndroidManifest.xml          +3
ios/Runner/Info.plist                             +1
assets/translations/en.i18n.json                  +36
assets/translations/ru.i18n.json                  +36
lib/core/http_client/dio_http_client.dart         +30 (post)
lib/core/router/go_router/routing_config_notifier.dart +21
lib/features/home/widget/home_page.dart           +10
lib/features/intro/widget/intro_page.dart         +8
lib/features/settings/data/config_option_repository.dart +5/-1
```

Сгенерированное (`lib/gen/translations*.g.dart`, `*.freezed.dart`, `*.g.dart`) в git не попадает —
оно в `.gitignore`, воспроизводится `dart run slang` и
`dart run build_runner build --delete-conflicting-outputs`.

---

## 3. Как проверить

### 3.1. Сборка

```bash
export JAVA_HOME=/opt/jdk ANDROID_SDK_ROOT=/opt/android-sdk ANDROID_HOME=/opt/android-sdk
export PATH=/opt/flutter/bin:/opt/jdk/bin:$PATH
cd /root/MyHome/vpn-client/app-feat
flutter pub get
dart run slang
dart run build_runner build --delete-conflicting-outputs
make CHANNEL=prod android-libs          # hiddify-core.aar v5.3.0 → android/app/libs/
flutter analyze                          # No issues found
flutter test                             # 266 passed
flutter build apk --debug \
  --dart-define=activation_api=http://10.0.2.2:8089   # эмулятор; для телефона — IP NAS в LAN
# → build/app/outputs/flutter-apk/app-debug.apk
```

Проверено на собранном APK: `aapt2 dump xmltree --file AndroidManifest.xml …` содержит
`scheme="vpn"`; в `assets/flutter_assets/kernel_blob.bin` есть код активации
(`activation_device_id`, `defaultValue: 'https://activation.invalid'`) — т.е. APK действительно
собран из этой ветки, а не из кеша.

### 3.2. Mock-сервис активации

```bash
cd /root/MyHome/vpn-client/server
ADMIN_TOKEN=devtoken CODE_PEPPER=devpepper XUI_MODE=mock \
  DB_PATH=/tmp/activation.db python3 run.py        # 127.0.0.1:8089

curl -sS -X POST http://127.0.0.1:8089/v1/codes \
  -H "Authorization: Bearer devtoken" -H 'Content-Type: application/json' \
  -d '{"email":"client@example.com","plan":{"days":30,"total_gb":100}}'
```

Дальше в приложении: иконка ключа → ввести код → «Активировать». Либо deep-link на устройстве:

```bash
adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb shell am start -a android.intent.action.VIEW \
  -d "vpn://activate?code=<КОД>" ru.vitosamin.app
```

Приложение с 01.11.2026 брендировано: `applicationId ru.vitosamin.app`, label
«Vitosamin» (см. [branding.md](branding.md)). Старый `app.hiddify.com` больше не
используется — старую сборку удалите (`adb uninstall app.hiddify.com`), иначе на
устройстве будут две копии. Схема `hiddify://` из регистрации удалена: принимается
только `vpn://activate` (активация) и нейтральные схемы подписок
(`v2ray/v2rayn/v2rayng/clash/clashmeta/sing-box`).

Быстрая проверка API без приложения:

```bash
curl -sS -X POST http://127.0.0.1:8089/v1/activate -H 'Content-Type: application/json' \
  -d '{"code":"<КОД>","device_id":"11111111-2222-4333-8444-555555555555"}'
```

---

## 4. Что проверено вживую (mock-сервис, `XUI_MODE=mock`)

| Проверка | Результат |
|---|---|
| `POST /v1/activate` новый код | `200`, `application/json; charset=utf-8`, `Cache-Control: no-store`; поля `sub_url`, `profile_name`, `expire`, `expire_unix`, `traffic{up,down,used,total,remaining,unlimited}`, `client_uuid`, `idempotent:false`, `activated_at` — все парсятся моделью |
| повтор с тем же `device_id` | `200`, `idempotent:true`, та же `sub_url` |
| другой `device_id` | `409 {"error":"code_already_used"}` → `codeAlreadyUsed` |
| неизвестный код | `404 {"error":"code_not_found"}` → `codeNotFound` |
| 7 запросов за минуту | `429`, заголовок `Retry-After: 57`, `{"error":"rate_limited"}` → `rateLimited(retryAfter:57)` |
| `Retry-After` в 409 | разбирается (`_retryAfter`), fallback 5 c, авторетрай зажат в 3…15 c |

Сервер запускался с `DB_PATH=/tmp/…` — каталог `server/` не менялся.

---

## 5. Допущения (зафиксированы, не блокируют)

1. **API_BASE по умолчанию — плейсхолдер** `https://activation.invalid` (зарезервированный TLD,
   заведомо не резолвится). Реальный адрес задаётся на сборке: `--dart-define=activation_api=…`.
   Так же задаётся `http://` для локального mock; для прод-сборки нужен HTTPS-домен.
2. **Автоповтор только для `409 activation_in_progress`** (по контракту приложение повторяет при
   409/429/502). Для 429/502 уважается `Retry-After`, но повтор не автоматический — показывается
   ошибка с кнопкой «Активировать» ещё раз: `Retry-After` для 429 в mock был 57 c, автоматическое
   ожидание в UI было бы хуже ручного. Если нужно автоповторять 502 — это +5 строк в
   `_activateWithRetry`.
3. **Точки входа**: иконка на главном + ссылка в онбординге. `FixBtns` в шторке добавления профиля
   не менялся, чтобы не пересчитывать константы раскладки (`fixBtnsItemCount`), как и советовал
   отчёт по разведке.
4. **`device_id` — UUID установки**, а не идентификатор железа (ТЗ и контракт запрещают IMEI/IDFA).
   После переустановки приложения это новый id; код при этом уже привязан к старому устройству
   (409) — на этот случай нужен сценарий «перенос/support» на стороне сервиса (см. §6).
5. **Регион по умолчанию `ru`** — продуктовое решение для РФ-рынка; интро по-прежнему переопределяет
   его по таймзоне, пользователь может выбрать другой регион вручную.

---

## 6. Что осталось / ограничения

- **E2E на реальном устройстве** не делала: нет Android-устройства/эмулятора в этой сессии.
  APK собран, схема `vpn` и код активации в нём проверены, контракт API сверен; остался прогон
  «установить → ввести код → подключиться» на телефоне и проверка, что RU-сайты идут direct.
- **iOS** не собирался (нужен macOS): схема в `Info.plist` и код платформенно-независимы, но
  сборку должен подтвердить отдельный этап.
- **HTTPS/пиннинг**: для dev достаточно `http://IP:8089`; для прода — HTTPS-домен, при желании
  certificate pinning (`DioHttpClient` позволяет).
- **Сценарий «код уже активирован на другом устройстве»** пока только сообщает об ошибке.
  Перенос подписки (release по device_id) — вопрос к API (в контракте помечен как открытый в §14).
- **Подключение после активации** остаётся ручным (кнопка на главном) — это ожидаемо для MVP.
- **Брендинг** (имя, applicationId, иконки, splash) и **автоселект** — не входили в задачу и не
  трогались. `pubspec name`, `hiddify-core` тоже не менялись.
- **Экран не проверялся визуально** (скриншотов нет): вёрстка простая (иконка/описание/поле/кнопка/
  карточки), но перед релизом стоит посмотреть в RU и EN, светлую и тёмную тему.
