# Vitosamin — клиент доступа (Android, форк Hiddify App)

Мобильный клиент сервиса **Vitosamin** на панели **3x-ui** (VLESS/Reality; AWG — вторая
версия). Пользователь получает код активации, приложение само подтягивает подписку,
выбирает первый рабочий сервер и держит его, пока он отвечает, а русские сайты пускает
напрямую, мимо туннеля.

Это **публичный форк** [Hiddify App](https://github.com/hiddify/hiddify-app) 5.3.0
(Flutter + sing-box): [vitosamin/vpn-client](https://github.com/vitosamin/vpn-client). Лицензия и обязательства форка — [LICENSE.md](LICENSE.md) и
[docs/adr-001-base-and-license.md](docs/adr-001-base-and-license.md).

## Что уже работает

- активация по одноразовому коду и по deep-link, подписка из 3x-ui;
- брендинг Vitosamin, без остатков Hiddify в интерфейсе;
- RU-трафик напрямую, встроенные RU-списки, регион `ru` по умолчанию;
- выбор сервера: первый живой по порядку подписки, переключение **только** когда
  выбранный перестал отвечать (три таймаута подряд, кулдаун между переключениями);
  ручной выбор и выбор группы уважаются и не «отбиваются» автоселектом;
- главный экран: статус, кнопка подключения, сервер, остаток трафика, Telegram;
- обновления прямо с телефона: приложение проверяет GitHub Releases форка и
  предлагает скачать новый APK — без магазина приложений.

## Установка

Готовые подписанные APK — в [Releases](https://github.com/vitosamin/vpn-client/releases):
универсальный `vitosamin-<версия>-release.apk` или компактный
`…-arm64.apk`. Ставится поверх прошлой версии, настройки сохраняются.

## Сборка APK

Требуется Flutter **3.38.5** (Dart 3.10.4), JDK **17**, Android SDK **36**,
NDK **28.2.13676358**. Go не нужен: ядро `hiddify-core` приходит готовым AAR.

```bash
export PATH=/path/to/flutter/bin:/path/to/jdk/bin:$PATH
export ANDROID_HOME=/path/to/android-sdk ANDROID_SDK_ROOT=/path/to/android-sdk

flutter pub get
dart run slang
dart run build_runner build --delete-conflicting-outputs
make android-libs CHANNEL=prod      # hiddify-lib-android.tar.gz v5.3.0 → android/app/libs/

# подпись: android/key.properties (в git не попадает)
flutter build apk --release                          # универсальный
flutter build apk --release --target-platform android-arm64   # компактный
```

Подробности, тайминги и грабли — [docs/build-android.md](docs/build-android.md),
подпись и keystore — [docs/android-release.md](docs/android-release.md).

## Обновления без магазина

Релиз собирается и подписывается в GitHub Actions по тегу `vX.Y.Z` и публикуется в
Releases (этого требует лицензия Hiddify). Приложение раз в 12 часов спрашивает
`api.github.com/repos/vitosamin/vpn-client/releases`; если версия новее — предлагает
«Обновить», кнопка скачивает APK релиза прямо в браузер телефона. Настройки и профили
при установке поверх сохраняются (та же подпись `CN=Vitosamin`).

Как выпустить версию — [docs/RELEASING.md](docs/RELEASING.md).

## Сервер активации

[`server/`](server/) — API активации (Python 3, stdlib, SQLite, мок-режим,
36 тестов): одноразовый код → sub-ссылка 3x-ui.

```bash
cd server
cp .env.example .env
python3 -m unittest discover -v
./run.sh start
```

## Структура

| Путь | Что |
|---|---|
| корень репозитория | форк Hiddify App 5.3.0 (Flutter-приложение) |
| [`server/`](server/) | API активации: код → sub-ссылка 3x-ui |
| [`docs/`](docs/) | архитектура, ADR, активация, сборка, брендинг, отчёты по фичам |
| [`ROADMAP.md`](ROADMAP.md) | план: AWG, iOS, сторы |
| `.github/workflows/release-apk.yml` | сборка и публикация подписанного APK |

## Лицензия

GPLv3 с дополнительными условиями Hiddify (см. [LICENSE.md](LICENSE.md)). Форк
публичный, релизы — только через GitHub Actions, атрибуция Hiddify сохранена.
Коммерческое использование требует письменного согласия Hiddify — черновик письма в
[docs/letter-to-hiddify.md](docs/letter-to-hiddify.md).

Исходный README Hiddify App сохранён в
[docs/README-upstream-hiddify.md](docs/README-upstream-hiddify.md).
