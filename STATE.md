# STATE — vitosamin (клиент Vitosamin, форк Hiddify App)

> Обновлено: 2026-11-01 02:55 (Europe/Kaliningrad)
> Ветка: `main` · последний коммит: `a3dd22e` «docs: note the embedded server row and switch logging in the 1.0.2 report»
> Версия: 1.0.2+3 (versionCode 3)

## Что это

Android-клиент сервиса Vitosamin (3x-ui, VLESS/Reality) — публичный форк Hiddify App
5.3.0 (Flutter + sing-box). Репозиторий развёрнут из `vitosamin-transfer/…/vitosamin.bundle`,
история сшита с upstream v5.3.0 (`upstream` = hiddify/hiddify-app, fetch blobless).

## Как собрать

```sh
source /home/dsh/projects/.env-android.sh     # HOME/PUB_CACHE/GRADLE_USER_HOME в воркспейсе
cd /home/dsh/projects/vitosamin
flutter build apk --release
flutter build apk --release --target-platform android-arm64
```

Окружение: Flutter 3.38.5 `tools/flutter`, JDK 17 `tools/jdk`, SDK 36 + NDK 28.2
`tools/sdk`. Ядро: `make android-libs CHANNEL=prod`. Подпись: `android/key.properties`
(keystore в `/home/dsh/projects/.secrets/vitosamin-release.jks`, CN=Vitosamin).

## Сделано (01.11.2026)

- Главный экран: белый круг Hiddify заменён кнопкой-pill («Подключить/Отключить»,
  спиннер, градиент по состоянию), статус без дубля «нажмите для подключения».
- Переключение серверов: ручной выбор теперь явный сигнал из списка прокси
  (`proxy_pick_signal.dart`), а не догадка по списку ядра — убран источник «пинг-понга»
  с ядром; пинг `0` («не измерено») больше не считается падением, фейловер только по
  таймаутам (3 подряд, кулдаун 45 с). Тесты селектора 23/23.
- Обновления: `Release.allowCustomUpdateChecker = true`, проверка GitHub Releases при
  старте (раз в 12 ч) и в «О приложении», кнопка качает APK из релиза. Константы
  указывают на `vitosamin/vpn-client`.
- CI: `.github/workflows/release-apk.yml` — сборка по тегу `v*`, подпись секретами,
  публикация universal + arm64 APK и SHA256SUMS.
- Активный сервер внутри hero — та же полупрозрачная плитка, без отдельной чёрной
  карточки (`ActiveProxyFooter(embedded: true)`); каждое автопереключение пишется
  в журнал приложения.
- Документация, `server/` активации и README перенесены в репозиторий;
  `docs/impl-1.0.2.md` — отчёт об изменениях.

## Следующий шаг

- **GitHub:** токен пушит в существующие репозитории, но не создаёт новые и не
  выставляет секреты Actions. Нужен один шаг человека: форк `hiddify/hiddify-app`
  (владелец vitosamin) и право `Secrets: Read and write` у токена (или classic-токен
  с `repo`+`workflow`). Дальше — `bash /home/dsh/projects/.sandbox/publish-vitosamin.sh`:
  переименует форк в `vpn-client`, запушит `main`+теги, выставит секреты, поставит
  тег `v1.0.2` и дождётся сборки.
- После релиза: проверить на телефоне установку 1.0.2 поверх 1.0.1 и автообновление.

## Грабли и решения

- `~/.android` и `~/.config` только для чтения: `HOME=/home/dsh/projects/.home`,
  `ANDROID_USER_HOME=…/.home/.android`; для Gradle `-Duser.home` прописан в
  `/home/dsh/projects/.gradle/gradle.properties`.
- `flutter test` целиком падает на 27 тестах из-за отсутствия `libsqlite3.so` в системе
  (drift), это не наш код; точечные тесты (`test/features/proxy`, `test/features/app_update`)
  зелёные.
- APK universal ~171 МБ, arm64 ~61 МБ; versionCode 3 ставится поверх 1.0.1.

## Не закоммичено

- `docs/screenshots/` (скриншот golden главного экрана)
