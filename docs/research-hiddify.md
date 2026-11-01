# Разведка форка Hiddify v5.3.0: точки интеграции под наш продукт

Дата: 2026-10-31. Только чтение кода; `app/` не менялся. База: hiddify-app `5919a4f` «release: version 5.3.0».
Ядро `app/hiddify-core/` — сабмодуль на `db79454` (v5.3.0), источник присутствует, всё по ядру проверено
по Go-коду. `app/hiddify-core/hiddify-sing-box/` **пуст** — выводы о внутренностях sing-box помечены.
Пути от `app/`. Смежное: `docs/android-release.md`, `docs/architecture.md`.

## 0. Главное

1. **Добавление профиля по sub-ссылке уже есть целиком** (скачивание, заголовки, валидация ядром, запись в
   БД, автоактивация). Нет только: активации по коду, клиента к нашему API, схемы `vpn://`.
2. **«Первый живой по приоритету» в ядре отсутствует.** Ядро строит selector `select` с `Default=balance`
   и балансеры `lowest` (lowest-delay) / `balance` (по умолчанию round-robin). Приоритетов нет → делается
   в приложении через `SelectOutbound` (**M**), своим конфигом через `enable_raw_config` (**M-L**, риск)
   или патчем ядра (**L**).
3. **RU → direct работает из коробки при `region=ru`**: builtin-правило `bypassRegion` включено по
   умолчанию и разворачивается в `geosite-ru.srs + geoip-ru.srs → direct` (DNS тоже direct). Интро само
   ставит `region=ru` по таймзоне/локали.
4. **Брендинг/сборка**: точки найдены. Сборка на Linux без macOS реальна: Flutter 3.38.5, JDK 17, SDK 36,
   NDK 28.2.13676358, обязательная кодогенерация и AAR ядра v5.3.0; fastforge для debug APK не нужен.

---

## A. Профили/подписки и вход «активация по коду»

**Как добавляется.** `AddProfileModal(url)` (`lib/features/profile/add/add_profile_modal.dart:15`) при
открытии с URL вызывает `addClipboard(url)` (`:33-39`); ручной ввод → `addManual` (`:90-249`, `:227-236`).
`AddProfileNotifier.addClipboard` (`lib/features/profile/notifier/profile_notifier.dart:64-95`):
`LinkParser.parse` → `upsertRemote(url)`, иначе `addLocal(base64)`. `upsertRemote`
(`lib/features/profile/data/profile_repository.dart:136-200`): id по uuid, скачивание в temp,
`ProfileParser.addRemote`, `validateConfig` (`:277-287` — `changeOptions` + `validateConfigByPath`), insert.
`ProfileParser` (`lib/features/profile/data/profile_parser.dart`): `addRemote` `:94-122`, `_downloadProfile`
`:154-182` (DioHttpClient, UA `"HiddifyNext/<ver> (<os>) like ClashMeta v2ray sing-box"`,
`lib/core/model/app_info_entity.dart:20`), заголовки `:53-63` (`profile-title`, `subscription-userinfo`,
`profile-update-interval`, `support-url`, `profile-web-page-url`, `ipinfo-url`, `fragment`), `subInfo`
`:410-413` (трафик/срок на карточке), автообновление подписок —
`lib/features/profile/notifier/profiles_update_notifier.dart:19-28` (15 мин).

**Форматы sub в Dart не парсятся** — содержимое отдаётся ядру (`validateConfigByPath`,
`lib/hiddifycore/hiddify_core_service.dart:70-82`; gRPC `Parse`, `hiddify-core/v2/hcore/buildconfighelper.go:50-82`),
поэтому проходят base64-список v2ray, raw-список, clash yaml, sing-box json.

**Активность:** `ProfileDao.insert` (`lib/features/profile/data/profile_data_source.dart:87-100`) при
`active=true` снимает active у остальных → новый профиль сразу активен; смена активного →
переподключение (`lib/features/connection/notifier/connection_notifier.dart:49-56`).

**Deep link сейчас.** `lib/features/deep_link/notifier/deep_link_notifier.dart:1-40` — весь файл
закомментирован (мёртвый код). Живая реализация: `lib/core/router/deep_linking/my_app_links.dart:9-17`
(app_links 6.4.0, `uriLinkStream`) → `refresh_listenable.dart:7-18` (`newUrlFromAppLink`) →
`routing_config_notifier.dart:71-115` `redirect`: scheme из `LinkParser.protocols` → url = uri
(`:74-76`); host `import` → `bottomSheetsNotifier.showAddProfile(url:, triggeredByDeepLink: true)`
(`:92-104`), внутри — подтверждение для защиты от zero-click SSRF
(`bottom_sheets_notifier.dart:52-74`) → `AddProfileModal(url)`. Парсер: `LinkParser.deep`
(`lib/utils/link_parsers.dart:29-48`), схемы `:17` (`hiddify, v2ray, v2rayn, v2rayng, clash, clashmeta,
sing-box`). Регистрация схем: `AndroidManifest.xml:71-90`; iOS `Info.plist:27-44`.

**Чего нет (проверено grep по `lib/`):** схемы `vpn`, host `activate`, ввода кода, вызовов нашего API;
все исходящие HTTP — sub-ссылки, GitHub-релизы (`app_update_repository.dart:32`), ipinfo
(`proxy_repository.dart:59-65`), free-configs (`profile_notifier.dart:222-234`), логи/Sentry. Шаблон
клиента — `lib/features/app_update/`.

**Врезка `vpn://activate?code=...`:**
1) схема: `<data android:scheme="vpn"/>` в `AndroidManifest.xml:71-90` + `vpn` в `Info.plist:27-42`;
2) маршрут: ранняя ветка в `redirect` (`routing_config_notifier.dart:71-115`):
`scheme=='vpn' && host=='activate'` → открыть экран активации с `code` (дешевле, чем учить
`LinkParser.deep` отдавать пару url/name);
3) API: новый `lib/features/activation/` на `DioHttpClient` (`lib/core/http_client/http_client_provider.dart:10-20`,
`get` — `dio_http_client.dart:105-126`); адрес — `String.fromEnvironment('activation_api')` или
`lib/core/model/constants.dart:6-16`. Нюанс: `get` без `proxyOnly` идёт режимом `both` (через sing-box,
если порт открыт), строго-direct флага в клиенте **нет** — правка на 5 строк, если понадобится;
4) профиль: `sub_url` из ответа → `addClipboard(subUrl)`/`upsertRemote` — станет активным сам;
токен sub в логи не писать (дисциплина уже есть: `profile_parser.dart:219-222`);
5) UI: страница `AddProfilePages.activation` (`profile_notifier.dart:219`) + вход. Учесть, что ряд кнопок
`FixBtns` (`add_profile_modal.dart:58-70`) рассчитан на `fixBtnsItemCount=4/3`
(`lib/core/model/constants.dart:23-26`): либо править константы, либо вход в `NavBar`
(`widgets/nav_bar.dart:19-42`).

Контракт API (согласовать с `docs/activation-api.md`): POST кода → `{sub_url, name?, expires_at?}`;
клиенту достаточно `sub_url`, остальное приедет заголовками 3x-ui. Идемпотентность/лимит попыток — на API.

## B. Автоселект/failover

**Конфиг sing-box генерирует ядро**, не приложение: `BuildConfig` (`hiddify-core/v2/config/builder.go:62`),
`setOutbounds` (`:145`). Приложение шлёт только настройки (`config_option_repository.dart:471-552`) и путь
к профилю (`hiddify_core_service.dart:160`). Приложение умеет получить готовый конфиг
(`generateFullConfigByPath`, `hiddify_core_service.dart:84-90`; «Экспорт конфига» —
`profiles_notifier.dart:102-114`) — удобно для проверки правок.

**Что строится (>1 сервера):** теги `select`/`lowest`/`balance` (`builder.go:40-46`); серверы в порядке
подписки (`:193-196`); балансер `lowest` — `Strategy "lowest-delay"`, `DelayAcceptableRatio 2`,
`Tolerance 100`, `ToleranceRatio 0.1` (`:247-262`, это и есть «Auto Select»); балансер `balance` —
`Strategy = opt.BalancerStrategy`, по умолчанию round-robin (`:265-280`, `config_option_repository.dart:27-32`);
selector `select` = `[lowest, balance, ...сервера]`, **`Default = balance`** (`:285-309`); финальный маршрут
→ `select` (`:986`). При одном сервере групп нет, `Default = tags[0]` (`:285`). Группы в app:
`lib/features/proxy/model/proxy_entity.dart:41-43`, `ConnectionHealth` (`connection_health.dart:39-113`).

**Вывод:** приоритетов серверов и failover по списку в ядре нет; «по умолчанию» трафик идёт через
`balance`. Поле `§default§` (`builder.go:287-290`) выставляет `Default` в литерал `"§default§"`, которого
нет в `Outbounds` — выглядит нерабочим, опираться нельзя (проверить нельзя: `hiddify-sing-box` пуст,
`go.mod:300` тянет `sagernet/sing-box v1.13.0`, replace на форк закомментирован `go.mod:319`).

**Варианты:**
- **A (для MVP): приложение + gRPC.** `selectOutbound` (`hiddify_core_service.dart:491-507`), `urlTest`
  (`:509`), `proxy_repository.dart:42-55`, поток групп `MainOutboundsNotifier`
  (`active_proxy_notifier.dart:102-150`). После `Connected` выбрать первый живой тег по приоритету и
  `selectProxy("select", tag)`; при `!isValidDelay` (`constants.dart:150-158`, валидно `0<d<65000`)
  переключать на следующий живой; дебаунс — `Throttler` (`active_proxy_notifier.dart:208-221`).
  Приоритет = порядок outbound'ов в подписке 3x-ui (`builder.go:193-196`) либо наша нумерация в имени.
  **M.** Ужать `url-test-interval` (default 10 мин, `config_option_repository.dart:163-168`) до 1-2 мин.
- **B: свой конфиг** — `StartRequest.enable_raw_config` + `config_content` (`hiddify-core/v2/hcore/hcore.proto:59-67`;
  ядро при `EnableRawConfig` берёт конфиг как есть, `buildconfighelper.go:36-41`); приложение сейчас всегда
  шлёт только `configPath` (`hiddify_core_service.dart:201-206`). Полный контроль групп, но теряем патчи
  ядра (DNS, chain, tls-tricks). **M-L, риск.**
- **C: патч ядра** — новая группа/стратегия в `builder.go` + сборка AAR (`make build-android-libs`,
  `Makefile:546-548`, Go+gomobile+NDK). **L**, не для MVP.

Смежное: `execute-config-as-is` (`lib/singbox/model/singbox_config_option.dart:23`, жёстко `false` в
`config_option_repository.dart:477`) ядром **не читается** — в `HiddifyOptions` ключ `enable-full-config`
(`hiddify_option.go:14`) — настройка мёртвая.

## C. Гео RU → direct

Правила — `lib/features/route_rules/notifier/rules_notifier.dart`: `_geoUrl =
https://raw.githubusercontent.com/hiddify/hiddify-geo/rule-set` (`:19`); `BuiltinRule` (`:23-78`):
`bypassLan` (direct, приватные CIDR, вкл.), `blockAds` (reject, выкл.), `bypassRegion` (direct,
`ruleSets: ['$_geoUrl/country/geosite-{region}.srs', '$_geoUrl/country/geoip-{region}.srs']`, **вкл. по
умолчанию**); `{region}` подставляет ядро, при `other` правило отбрасывается (`:99-119`).

`Region.ru` уже есть (`lib/core/model/region.dart:3-11`); интро ставит `region=ru` и локаль `ru` по
таймзоне/локали (`intro_page.dart:44-47`, `:209-252`, RU — `:251-252`); default `other`
(`config_option_repository.dart:34-38`); смена вручную — `routing_options_page.dart:102-150`.

Путь до sing-box: приложение **всегда** шлёт `route-rule` (`config_option_repository.dart:550`), ядро при
`RouteRule != nil` работает по списку приложения и builtin'ы не добавляет (`builder.go:657-661, 777-780, 877`).
Построение: `hiddify-core/v2/config/route_rules.go:39-56` (`buildAppRouteRules`), `:103-170` (`add`), `:232-272`
(`ruleSet`: remote `.srs`, тег = имя файла, `UpdateInterval 5 дней`, `DownloadDetour "select"`).
**DNS для direct-правил тоже direct** (`:174-230` `addDNSRule`) — утечки резолва RU-доменов нет.

Проверено HTTP с этой машины 2026-10-31: `country/geosite-ru.srs` — 200, 15 684 Б; `country/geoip-ru.srs` —
200, 104 905 Б (это не проверка с телефона в РФ). Если GitHub недоступен: URL набора произволен
(`rule_set` в `Rule`, `route_rule.pbjson.dart:78-99`) → свой mirror `.srs` на нашем сервере, или дешёвый
inline-фолбэк `domain_suffix: ['.ru']` (домены, но не IP/CDN).

## D. Брендинг

**Android.** `applicationId "app.hiddify.com"` + `namespace com.hiddify.hiddify`
(`android/app/build.gradle:55, 74`). Label — хардкод `"Hiddify"` в `AndroidManifest.xml:31`, ресурса
`app_name` нет (`res/values/strings.xml:3-8` — только строка уведомления/плитки); `res/values-ru` нет.
⚠️ `res/xml/shortcuts.xml:11` хардкодит `android:targetPackage="app.hiddify.com"` — обновить при смене
applicationId. Иконки: `mipmap-*/ic_launcher{,_round}.webp`, adaptive `mipmap-anydpi-v26/ic_launcher.xml`
+ `drawable/ic_launcher_foreground.xml` + цвет `#F0F3FA` в `res/values/ic_launcher_background.xml:3`;
баннер `ic_banner*`; статус `drawable-{mdpi,hdpi}/ic_stat_logo.png`; `ic_launcher-playstore.png`.
Splash: `drawable/launch_background.xml` + `drawable-v21/…`, `drawable-xxxhdpi/splash.png`,
`drawable/android12splash.xml`, стили `values/styles.xml`, `values-night/styles.xml`, `values-v31`. `flutter_native_splash`
(`pubspec.yaml:189-196`) ссылается на отсутствующие PNG (`assets/images/source/ic_launcher_splash.png`,
`ic_launcher_foreground.png`) — конфиг нерабочий, splash сейчас живёт как Android-ресурсы.
Цвета: seed `0xFF293CA0` (`lib/core/theme/app_theme.dart:12, 23`), статусы
(`lib/core/theme/theme_extensions.dart:10-11`).

**iOS.** `CFBundleDisplayName "Hiddify"` (`ios/Runner/Info.plist:11-12`), bundle id из
`ios/Base.xcconfig:9-11` (`BASE_BUNDLE_IDENTIFIER=apple.hiddify.com`, `SERVICE_IDENTIFIER`, `DEVELOPMENT_TEAM`),
туннель `$(BASE_BUNDLE_IDENTIFIER).HiddifyPacketTunnel` (`project.pbxproj:776, 797`), схемы
`Info.plist:27-44`, camera-строки по-английски (`:54-59`), `InfoPlist.strings` для ru нет; иконки —
`ios/Runner/AppIcon.icon/icon.json`, `Assets.xcassets`.

**Dart-пакет:** `pubspec.yaml:1` `name: hiddify`, импорты `package:hiddify/...` — переименование = все
импорты заново (**L**), не рекомендуется. **Локализация:** 11 языков `assets/translations/*.i18n.json`,
ru 40 КБ (`appTitle` — `ru.i18n.json:3`); генерация slang (`build.yaml:20-29`, `Makefile:75-76`
`dart run slang`), `lib/gen/translations.g.dart` в git нет. Ещё «Hiddify»: `constants.dart:6` (и URL
`:7-16`), UA `app_info_entity.dart:20`.

## E. Сборка Android на Linux

**Версии из CI** (`.github/workflows/build.yml`): Flutter `3.38.5` (`:18`), NDK `r28c` (`:19`), android —
`ubuntu-latest` (`:86-87`), JDK 17 Zulu (`actions/setup-java@v5`, `:196-201`), Android SDK через
`android-actions/setup-android@v3` с `packages: platform-tools` (`:211-215`), установка NDK в CI
закомментирована (`:203-206`) — AGP подтянет сам.

**Gradle/проект:** compileSdk 36, targetSdk 36, `minSdk = flutter.minSdkVersion` (не пиннится),
`ndkVersion "28.2.13676358"`, Java/Kotlin 17 (`android/app/build.gradle:57-67, 75-76`), ABI-splits
`x86_64/armeabi-v7a/arm64-v8a` + universalApk (`:83-92`), `useLegacyPackaging` (`:126-132`), зависимости из
`libs` (`:146`); Gradle 8.7, AGP 8.6.0, Kotlin 2.1.0 (`android/settings.gradle:22-23`), protobuf 0.9.4 +
wire 5.3.1 (`app/build.gradle:6-7`); Dart `^3.10.4` (`pubspec.yaml:7`).

**Ядро:** `dependencies.properties` → `core.version=5.3.0`; `CORE_URL` = релиз `v5.3.0` (`Makefile:53-56`);
`make android-libs` качает `hiddify-lib-android.tar.gz` в `android/app/libs/` (`Makefile:494-496`) — без
этого Kotlin не соберётся (`Application.kt` импортирует `go.Seq`). Полная сборка ядра —
`make build-android-libs` (`Makefile:546-548`; сабмодуль уже на v5.3.0).

**Кодогенерация обязательна:** `**/*.g.dart`, `**/*.freezed.dart`, `**/*.gen.dart` в `.gitignore`;
`lib/gen/translations.g.dart`, `lib/gen/assets.gen.dart` в дереве отсутствуют. `make android-prepare` =
`get gen translate` + `android-libs` (`Makefile:108, 71-77`).

**Порядок debug APK (fastforge не нужен):** Flutter 3.38.5 + JDK 17 + SDK 36 (+NDK) →
`flutter pub get` → `dart run build_runner build --delete-conflicting-outputs` → `dart run slang` →
`make android-libs` (или `curl -L "$CORE_URL/hiddify-lib-android.tar.gz" | tar xz -C android/app/libs/`) →
`flutter build apk --debug`. Релиз: `--release`; без `android/key.properties` подпишется debug-ключом
(`android/app/build.gradle:32-48, 105-111`). fastforge — только упаковка релизов (`Makefile:269-287`;
`--build-target android-arm,android-arm64,android-x64`, для AAB `--build-dart-define=release=google-play`).
**dart-define:** обязательных нет (`sentry_dsn` — крэши, `environment.dart:7`; `release=` — сторы;
`driver=true` — debug, `main.dart:20-22`); entrypoint `main.dart` (dev) / `main_prod.dart` (prod) по
`CHANNEL` (`Makefile:57-62`).

## F. План минимальных правок

| # | Фича | Файлы | Что сделать | Сложность |
|---|------|-------|-------------|-----------|
| 1 | Клиент API активации | новый `lib/features/activation/{data,model,notifier}`; `constants.dart` | `DioHttpClient`: код → `sub_url`, модель ошибок, провайдеры как в `app_update` | **S** (0.5–1 д) |
| 2 | Экран ввода кода | `add_profile_modal.dart`, `fix_btns.dart`/`nav_bar.dart`, `AddProfilePages` (`profile_notifier.dart:219`), `*.i18n.json` | страница «код» + вход; учесть `fixBtnsItemCount` (`constants.dart:23-26`) | **S-M** |
| 3 | Deep link `vpn://activate` | `routing_config_notifier.dart:71-115`, `link_parsers.dart:17/29-48`, `AndroidManifest.xml:71-90`, `Info.plist:27-42` | ветка `scheme==vpn && host==activate` → активация с кодом; регистрация схемы | **S** |
| 4 | Код → профиль | `profile_notifier.dart:64`, `profile_repository.dart:136` | `upsertRemote(sub_url)`; профиль станет активным (`profile_data_source.dart:87-100`) | **S** |
| 5 | RU → direct | `config_option_repository.dart:34-38`, `rules_notifier.dart:23-78` | default `region=ru` (правило уже вкл.); при блокировке GitHub — свой mirror `.srs`/inline `.ru` | **S** (0.5 д) |
| 6 | Приоритетный автоселект | новый notifier `lib/features/proxy/active/`; `active_proxy_notifier.dart:195-221`; `hiddify_core_service.dart:491`; `config_option_repository.dart:163-168` | после `Connected` первый живой тег по приоритету через `SelectOutbound`; переключение при `!isValidDelay`; interval 1-2 мин | **M** (1.5–2 д) |
| 7 | Брендинг Android | `build.gradle:55,74`; `AndroidManifest.xml:31`; `res/xml/shortcuts.xml:11`; иконки/splash; новый `res/values-ru/strings.xml`; `app_theme.dart:12,23` | applicationId/namespace, label, иконки, splash, цвета, ru-строки уведомлений | **M** (1–2 д) |
| 8 | ru-локализация | `assets/translations/ru.i18n.json` + `dart run slang` | продуктовые строки, hiddify-ссылки в About/интро | **S** |
| 9 | Фиксация тулчейна | новый `docs/build-android.md` | Flutter/JDK/SDK/NDK, `make gen`+`translate`+`android-libs`, debug APK | **S** (0.5 д) |
| 10 | (опция) приоритет в ядре | `hiddify-core/v2/config/builder.go` + сборка AAR | своя группа/failover; форк ядра | **L** — не для MVP |

## Риски

1. **`.srs` тянутся с GitHub через туннель** (`DownloadDetour "select"`, `route_rules.go:271`): на первом
   старте без кэша RU-правил нет, из РФ `raw.githubusercontent.com` может не открыться → свой mirror или
   inline `.ru`. Проверить на устройстве в РФ.
2. **Автоселект — «управляемый выбор + фейловер»** на стороне app, а не смена балансировщика в ядре;
   если нужна мгновенность/приоритет внутри ядра — вариант B/C.
3. **`§default§` и поля балансера** не подтверждены: `hiddify-sing-box` пуст, в `go.mod` официальный
   `sing-box v1.13.0`. Сверить при сборке.
4. **`execute-config-as-is` мёртв** — не использовать как рычаг.
5. **3x-ui sub-формат**: для предсказуемости — base64-список VLESS + `profile-title`,
   `subscription-userinfo`, `profile-update-interval`. Проверить на мок-3x-ui (этап 0.3).
6. **Лицензия Hiddify** (ADR-001) влияет на имя/бренд и обязанность публиковать изменения — вопрос
   владельцу; технически план не блокируется.
