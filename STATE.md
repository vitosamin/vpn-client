# STATE — vitosamin (клиент Vitosamin, форк Hiddify App)

> Обновлено: 2026-11-01 10:05 (Europe/Kaliningrad)
> https://github.com/vitosamin/vpn-client (публичный форк hiddify/hiddify-app)
> Ветка `main`, версия 1.0.4+5; релизы 1.0.2–1.0.4 опубликованы ([v1.0.4](https://github.com/vitosamin/vpn-client/releases/tag/v1.0.4))

## Что это

Android-клиент Vitosamin (3x-ui, VLESS/Reality), форк Hiddify App 5.3.0
(Flutter + sing-box). Релизы собирает только GitHub Actions по тегу `v*`.

## Как собрать/выпустить

`source .env-android.sh && flutter build apk --release` (universal + splits).
Релиз: поднять `version` в `pubspec.yaml`, тег `vX.Y.Z`, запушить — Actions
соберёт, подпишет и опубликует (`docs/RELEASING.md`).

## Доступ к GitHub

OAuth-токен `gh` (repo, workflow) — `.sandbox/.gh-oauth-token`, git-креды —
`.sandbox/.git-credentials-oauth`. Секреты подписи — в репозитории; keystore —
`.secrets/vitosamin-release.jks` (CN=Vitosamin).

## Сделано (01.11.2026)

- 1.0.2: экран без белого круга (кнопка-pill), строка сервера в тон карточке,
  спокойный автоселект (явный ручной выбор, пинг `0` не падение, лог переключений).
- 1.0.3: российские сайты — суффиксы `ru`, `su`, `xn--p1ai`, `moscow`, прямой DNS
  `udp://77.88.8.8`, миграция старого дефолта 1.1.1.1 и региона `other`.
- 1.0.4: правило «Российские сайты — напрямую» больше не зависит от региона и всегда
  есть в списке (даже при `other`); добавлен `assets/geo/ru_extra.txt` — российские
  сервисы на не-`.ru` доменах; прямой DNS Яндекс для всех регионов; на главном экране
  плашка «Доступно обновление», проверка обновлений идёт при каждом запуске.
- Обновления: проверка GitHub Releases при каждом запуске и из «О приложении»,
  скачивание APK из релиза.

## Следующий шаг

- Установить 1.0.4 (приложение предложит само или плашкой на главной; иначе
  «О приложении → Проверить обновления») и проверить российские сайты.
- Если какие-то сайты всё ещё не открываются — нужны их адреса: добавить в
  `assets/geo/ru_extra.txt` и выпустить 1.0.5.
- Повторный системный запрос VPN: нужен скриншот диалога и данные, нет ли второго
  VPN-приложения/always-on VPN. Код просит разрешение один раз через
  `VpnService.prepare`; если системный диалог повторяется, согласие не сохраняет
  ROM, а не логика приложения.

## Грабли и решения

- `android-actions/setup-android@v3` падает на раннере — workflow берёт SDK раннера.
- `flutter test` целиком падает на 27 тестах без `libsqlite3.so` (drift);
  точечные тесты зелёные.
- `~/.android` и `~/.config` только для чтения: `HOME=/home/dsh/projects/.home`,
  `ANDROID_USER_HOME=…/.home/.android`, Gradle `-Duser.home` в `.gradle/gradle.properties`.
- В geosite-ru нет голого суффикса `ru`; прямой DNS 1.1.1.1 режется на части
  мобильных сетей РФ — отсюда «не работают российские сайты» в 1.0.2.
