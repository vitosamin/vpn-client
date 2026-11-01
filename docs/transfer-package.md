# TRANSFER — как забрать проект Vitosamin на другую машину

Пакет для переноса проекта в другое окружение (например, рабочий Harness) с
возможностью собрать APK и опубликовать репозиторий на GitHub.

## Что внутри

| Путь | Что |
|---|---|
| `vitosamin.bundle` | Git-репозиторий форка со всей историей (`main` + теги + ветки фич). Разворачивается командой `git clone vitosamin.bundle app` |
| `docs/` | Вся документация проекта: архитектура, ADR по лицензии, разведка форка, API активации, сборка Android, брендинг, store-listing, отчёты по фичам |
| `server/` | Серверная часть активации (Python 3, stdlib, SQLite, 36 тестов, mock-режим) + `run.sh` |
| `tools/` | `make-transfer.sh` (сборка этого пакета), `serve-dist.sh` (раздача APK), `update-geo-rules.sh` (обновление встроенных RU-списков) |
| `secrets/` | **Отдельно, не в git:** `release.jks` (ключ подписи) и `keystore-password.txt`. Без них нельзя выпускать обновления приложения |
| `dist/` | Собранный release-APK (universal + arm64), SHA256SUMS |
| `README.md`, `ROADMAP.md` | Обзор проекта и план |

## Быстрый старт на новой машине

Требования: Linux/macOS, Flutter **3.38.5** (Dart 3.10.4), JDK **17**,
Android SDK **36**, NDK **28.2.13676358**, ~20 ГБ свободного места, Go не нужен
(ядро приходит готовым AAR).

```bash
# 1. Развернуть репозиторий из bundle
git clone /path/to/vitosamin.bundle app
cd app
git remote remove origin            # origin указывал на hiddify-app
git remote add upstream https://github.com/hiddify/hiddify-app.git
git remote add origin git@github.com:<ваш-аккаунт>/vitosamin.git   # свой будущий форк

# 2. Окружение
export PATH=/opt/flutter/bin:/opt/jdk/bin:$PATH
export ANDROID_HOME=/opt/android-sdk ANDROID_SDK_ROOT=/opt/android-sdk

# 3. Сгенерировать код и скачать ядро
flutter pub get
dart run slang
dart run build_runner build --delete-conflicting-outputs
make android-libs CHANNEL=prod        # AAR hiddify-core v5.3.0 → android/app/libs/

# 4. Подпись (кит из secrets/)
cat > android/key.properties <<EOF
storePassword=<из secrets/keystore-password.txt>
keyPassword=<то же>
keyAlias=vitosamin
storeFile=<абсолютный путь>/secrets/release.jks
EOF
chmod 600 android/key.properties

# 5. Сборка
flutter analyze && flutter test
flutter build apk --release                          # universal
flutter build apk --release --target-platform android-arm64
```

Точные версии, encountered issues и тайминги — в `docs/build-android.md`.

## Сервер активации

```bash
cd server
cp .env.example .env        # XUI_MODE=mock для старта, сгенерировать ADMIN_TOKEN/CODE_PEPPER
python3 -m unittest discover -v   # 36 тестов
./run.sh start                    # http://127.0.0.1:8089
```

Подключение к живой панели 3x-ui (API Token, webBasePath, inbound, sub-шаблон) —
чек-лист в `docs/deploy-nas.md` §7 и `docs/activation-api.md` §11.

## Секреты и то, что в git не попадает

- `secrets/release.jks`, `secrets/keystore-password.txt` — **хранить в двух
  местах**, потеря = невозможность обновить приложение в сторах;
- `android/key.properties` — создаётся на машине, в git не коммитится;
- `.env` сервера активации — генерируется, в git не коммитится;
- APK, build-артефакты, `.dart_tool` — в git не нужны.

## Публикация на GitHub (важно по лицензии)

Hiddify распространяется под **GPLv3 + дополнительными условиями** (см.
`app/LICENSE.md`, разбор в `docs/adr-001-base-and-license.md`):

1. **Публичный форк обязателен**: репозиторий должен быть форком
   `https://github.com/hiddify/hiddify-app` (п. 1 лицензии). Создайте форк
   через GitHub UI, затем `git remote set-url origin git@github.com:<вы>/<форк>.git`
   и запушьте `main` + теги.
2. **Релизы — только через GitHub Actions** (п. 2). В репозитории уже есть
   workflow Hiddify (`.github/workflows/`); туда переносятся secrets: keystore
   (base64), пароли, `key.properties`. Имя приложения и applicationId уже наши.
3. **Атрибуция** (п. 3): в About оставлена строка про Hiddify и ссылка на
   лицензию — не удалять.
4. **Имя/UI не похожи на Hiddify** (п. 5): уже соблюдено (Vitosamin).
5. **ShareAlike** (п. 7): ваши изменения распространяются под этой же лицензией.
6. **NonCommercial** (п. 6): перед платным релизом нужно **письменное согласие
   Hiddify**. Черновик письма — `docs/letter-to-hiddify.md`; отправить до
   публикации платного сервиса. Без него можно вести разработку и тестовые
   сборки, но не продавать.

## Что осталось до продукта

- **iOS**: нужен Apple Developer Program + macOS-сборка. Публичный форк даёт
  бесплатные macOS-раннеры GitHub Actions — сборку можно вести в CI.
- **AWG**: вторая версия (amneziawg-go + сервер). Решение зафиксировано в
  `ROADMAP.md`, этап 2.
- **API активации в проде**: HTTPS-домен (мобильному клиенту нужен TLS),
  публикация за reverse proxy, подключение к живой 3x-ui.
- **Бот поддержки**: ссылка на канал уже в приложении; для отдельных обращений
  нужен бот (создать у @BotFather, токен в конфиг).
- **Сторы**: RuStore / Google Play / APK с сайта; keystore готов.
- **Скриншоты витрины** и страницы privacy/terms/help на сайте.

## Где что менять

| Что | Где |
|---|---|
| Ссылка Telegram | `lib/core/model/constants.dart` → `telegramGroupUrl` |
| Адрес API активации | `--dart-define=activation_api=https://...` (по умолчанию `https://activation.invalid`) |
| Регион по умолчанию (RU) | `lib/features/settings/data/config_option_repository.dart` |
| RU-списки правил | `assets/geo/` (встроены), обновление — `tools/update-geo-rules.sh` |
| applicationId / версия | `android/app/build.gradle`, `pubspec.yaml` |
| Параметры 3x-ui | `server/.env` (`XUI_*`) |
