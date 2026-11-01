# STATE — vitosamin (клиент Vitosamin, форк Hiddify App)

> Обновлено: 2026-11-01 04:20 (Europe/Kaliningrad)
> https://github.com/vitosamin/vpn-client (публичный форк hiddify/hiddify-app)
> Ветка `main`, версия 1.0.3+4; релизы [1.0.2](https://github.com/vitosamin/vpn-client/releases/tag/v1.0.2) и [1.0.3](https://github.com/vitosamin/vpn-client/releases/tag/v1.0.3) опубликованы

## Что это

Android-клиент Vitosamin (3x-ui, VLESS/Reality) на базе Hiddify App 5.3.0
(Flutter + sing-box). Форк публичный, релизы собирает только GitHub Actions
(`.github/workflows/release-apk.yml`, тег `v*`).

## Как собрать/выпустить

```sh
source /home/dsh/projects/.env-android.sh
cd /home/dsh/projects/vitosamin
flutter build apk --release        # universal + splits, arm64 берём оттуда
```

Релиз: поднять `version` в `pubspec.yaml`, закоммитить, поставить тег `vX.Y.Z`,
запушить — Actions соберёт, подпишет и опубликует (`docs/RELEASING.md`).

## Доступ к GitHub

- OAuth-токен `gh` (repo, workflow): `.sandbox/.gh-oauth-token`; git-креды —
  `.sandbox/.git-credentials-oauth`; gh config — `.home/.config/gh`.
- Секреты подписи в репозитории: `KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`,
  `KEY_ALIAS`; keystore — `.secrets/vitosamin-release.jks` (CN=Vitosamin).

## Сделано (01.11.2026)

- 1.0.2: экран без белого круга (кнопка-pill), строка сервера в тон карточке,
  спокойный автоселект (явный ручной выбор, пинг `0` не падение, лог переключений).
- 1.0.3: российские сайты — к правилу региона добавлены суффиксы `ru`, `su`,
  `xn--p1ai`, `moscow`; прямой DNS для ru → `udp://77.88.8.8` (Яндекс) с миграцией
  старого дефолта 1.1.1.1; регион `other` миграцией возвращается на `ru`;
  в лог пишется число загруженных гео-записей.
- Обновления: приложение проверяет GitHub Releases (раз в 12 ч и из «О приложении»)
  и скачивает APK из релиза.

## Следующий шаг

- Установить 1.0.3 (1.0.2 должна предложить сама; иначе «О приложении → Проверить
  обновления») и проверить российские сайты.
- Повторный системный запрос VPN: нужен скриншот диалога и данные, нет ли второго
  VPN-приложения/always-on VPN. Код просит разрешение один раз через
  `VpnService.prepare`; если системный диалог повторяется, согласие не сохраняет
  ROM, а не логика приложения.

## Грабли и решения

- `android-actions/setup-android@v3` падает на раннере — workflow берёт SDK раннера.
- `flutter test` целиком падает на 27 тестах из-за отсутствия `libsqlite3.so`
  (drift); точечные тесты зелёные.
- `~/.android` и `~/.config` только для чтения: `HOME=/home/dsh/projects/.home`,
  `ANDROID_USER_HOME=…/.home/.android`, Gradle `-Duser.home` в `.gradle/gradle.properties`.
- В geosite-ru нет голого суффикса `ru`; прямой DNS 1.1.1.1 режется на части
  мобильных сетей РФ — отсюда «не работают российские сайты» в 1.0.2.

## Не закоммичено

- чисто
