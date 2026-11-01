# STATE — vitosamin (клиент Vitosamin, форк Hiddify App)

> Обновлено: 2026-11-01 03:30 (Europe/Kaliningrad)
> Репозиторий: https://github.com/vitosamin/vpn-client (публичный форк hiddify/hiddify-app)
> Ветка `main`, версия 1.0.2+3 · релиз [v1.0.2](https://github.com/vitosamin/vpn-client/releases/tag/v1.0.2) опубликован

## Что это

Android-клиент Vitosamin (3x-ui, VLESS/Reality) на базе Hiddify App 5.3.0
(Flutter + sing-box). Форк публичный, лицензия Hiddify соблюдена: релизы собирает
только GitHub Actions (`.github/workflows/release-apk.yml`, тег `v*`).

## Как собрать/выпустить

```sh
source /home/dsh/projects/.env-android.sh
cd /home/dsh/projects/vitosamin
flutter build apk --release        # universal + splits, arm64 берём оттуда
```

Релиз: поднять `version` в `pubspec.yaml`, закоммитить, поставить тег `vX.Y.Z` и
запушить — Actions соберёт, подпишет и опубликует (см. `docs/RELEASING.md`).

## Доступ к GitHub

- OAuth-токен `gh` (scopes `repo`, `workflow`): `.sandbox/.gh-oauth-token`,
  gh config — `.home/.config/gh`; git-креды — `.sandbox/.git-credentials-oauth`.
- Секреты подписи в репозитории выставлены: `KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`,
  `KEY_ALIAS`; keystore — `.secrets/vitosamin-release.jks` (CN=Vitosamin).

## Сделано (01.11.2026)

- Опубликован форк и релиз 1.0.2 (universal + arm64 APK, SHA256SUMS), подпись
  проверена `apksigner` уже у скачанного из релиза файла.
- Главный экран: белый круг Hiddify заменён кнопкой-pill, строка активного сервера
  в тон карточке, статус без дубля.
- Переключение: ручной выбор — явный сигнал из списка прокси, пинг `0` не считается
  падением, смена только после трёх таймаутов (кулдаун 45 с), переключения пишутся
  в журнал; тесты селектора 23/23.
- Обновления: приложение проверяет GitHub Releases (раз в 12 ч и из «О приложении»)
  и скачивает APK из релиза.
- Документация и `server/` активации — в репозитории, отчёт — `docs/impl-1.0.2.md`.

## Следующий шаг

- Установить 1.0.2 на телефон с релиза и проверить: экран, что сервер не скачет,
  установку поверх 1.0.1.
- Следующая версия (1.0.3) должна сама предложить обновление на телефоне.

## Грабли и решения

- `android-actions/setup-android@v3` падает на раннере (ставит удалённый пакет
  `tools`) — workflow берёт SDK раннера и вызывает его `sdkmanager` напрямую.
- `flutter test` целиком падает на 27 тестах из-за отсутствия `libsqlite3.so`
  (drift); точечные тесты зелёные.
- `~/.android` и `~/.config` только для чтения: `HOME=/home/dsh/projects/.home`,
  `ANDROID_USER_HOME=…/.home/.android`, Gradle `-Duser.home` в `.gradle/gradle.properties`.
- Старый fine-grained токен (`.sandbox/.git-credentials`) не умеет создавать репозитории
  и секреты — для публикации нужен OAuth-токен выше.

## Не закоммичено

- чисто
