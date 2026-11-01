# Как выпустить обновление

Репозиторий: **https://github.com/vitosamin/vpn-client** (публичный форк
`hiddify/hiddify-app`). Секреты подписи уже выставлены, первый релиз
[`v1.0.2`](https://github.com/vitosamin/vpn-client/releases/tag/v1.0.2) собран
workflow `Release APK`.

Лицензия Hiddify требует собирать релизы **только в GitHub Actions**, поэтому
подписанный APK не собирается на телефоне и не кладётся в релиз руками: тег → workflow
`.github/workflows/release-apk.yml` → APK в GitHub Releases.

## Один раз: секреты подписи

В репозитории (Settings → Secrets and variables → Actions) должны лежать:

| Секрет | Значение |
|---|---|
| `KEYSTORE_BASE64` | `base64 -w0 release.jks` (одной строкой) |
| `KEYSTORE_PASSWORD` | пароль из `keystore-password.txt` |
| `KEY_ALIAS` | `vitosamin` |

Доступ к GitHub у агента — через OAuth-токен `gh` (scopes `repo`, `workflow`);
он лежит в `/home/dsh/projects/.sandbox/.gh-oauth-token`, git — в
`.sandbox/.git-credentials-oauth`.

```bash
base64 -w0 release.jks > keystore.b64
gh secret set KEYSTORE_BASE64 < keystore.b64
gh secret set KEYSTORE_PASSWORD --body "$(cat keystore-password.txt)"
gh secret set KEY_ALIAS --body vitosamin
```

Сам `release.jks` и пароль **не коммитятся** и хранятся в двух местах: без них
обновления приложения невозможны (Android не даст поставить APK с другой подписью
поверх установленного).

## Выпуск версии (можно с телефона)

1. Поднять версию в `pubspec.yaml`: `version: 1.0.3+4` (обязательно и `versionName`,
   и `versionCode`).
2. Закоммитить это в `main`.
3. На GitHub: **Releases → Draft a new release → Choose a tag → создать `v1.0.3` от
   `main` → Publish release**.
4. Workflow сам соберёт universal и arm64 APK, проверит подпись и приложит файлы
   `vitosamin-1.0.3-release.apk`, `…-arm64.apk` и `SHA256SUMS.txt` к релизу.

Если версия в `pubspec.yaml` не совпадает с тегом, workflow падает с понятной ошибкой —
это защита от релиза со старым `versionCode`, который телефон не установит поверх.

## Как телефон узнаёт об обновлении

Приложение при старте (не чаще раза в 12 часов) и по кнопке в «О приложении»
запрашивает `https://api.github.com/repos/vitosamin/vpn-client/releases`, находит
последний не-prerelease и сравнивает версию с установленной. Если новее — показывает
диалог «Доступно обновление»; кнопка «Обновить» на Android скачивает APK из ассетов
релиза (universal, иначе обычный, иначе arm64) прямо в браузер. Дальше — обычная
установка поверх: настройки, профили и подписка сохраняются.

Репозиторий зашит в `lib/core/model/constants.dart` (`githubReleasesApiUrl`); если
форк переименовать, правится одна строка.

## Проверка релиза

```bash
apksigner verify --print-certs vitosamin-1.0.3-release.apk | head -3   # CN=Vitosamin
aapt2 dump badging vitosamin-1.0.3-release.apk | head -1               # versionCode/versionName
```

Первые установки (пока приложение не умеет обновляться само) ставятся вручную с
телефона: открыть релиз → скачать APK → разрешить установку из этого источника.
