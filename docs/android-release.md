# Релиз Android: подпись и безопасность

**Статус (01.11.2026): keystore создан и используется, release-APK собран.**
Ключ: `vpn-client/secrets/release.jks` (алгоритм RSA 4096, SHA384withRSA,
alias `vitosamin`, срок 10 000 дней, CN=Vitosamin). Пароль:
`vpn-client/secrets/keystore-password.txt`. Оба файла с правами 600 и в
`.gitignore` — **скопировать их в надёжное место у Виталия** (потеря = нельзя
обновить приложение в сторе).

Подпись подключена через `app/android/key.properties` (тоже не в git):
`storeFile=/root/MyHome/vpn-client/secrets/release.jks`, alias/keyPassword/
storePassword оттуда. `flutter build apk --release` использует её автоматически
(в `android/app/build.gradle` — `signingConfigs.release` при наличии
`key.properties`). Проверено: `apksigner verify --print-certs` → CN=Vitosamin.

Собранные артефакты (01.11.2026):

| Файл | Размер | Назначение |
|---|---|---|
| `dist/vitosamin-1.0.0-release.apk` | 167 МБ | universal (3 ABI), для теста и раздачи |
| `dist/vitosamin-1.0.0-release-arm64.apk` | 145 МБ | только arm64 — телефоны |
| `dist/vitosamin-1.0.0-debug.apk` | 251 МБ | debug, для отладки |

Перед обновлением версии — поднять `versionCode`/`versionName` в `pubspec.yaml`.

Для новой сборки понадобится:

1. **Keystore** — создаём один раз, храним у владельца в двух местах
   (не в git, не в переписке):

   ```bash
   keytool -genkeypair -v -keystore release.jks -alias vpn \
     -keyalg RSA -keysize 4096 -validity 10000 \
     -storepass '<пароль>' -keypass '<пароль>' \
     -dname "CN=<name>, O=<org>, C=RU"
   ```

   Пароль — сгенерировать (`openssl rand -base64 24`) и сохранить у Виталия.
   Потеря keystore = невозможность обновить приложение в сторах (перевыпуск
   под новым applicationId).

2. **applicationId** — наш (например `ru.<brand>.vpn`), не `app.hiddify.com`.
   Меняется в `android/app/build.gradle*`; после смены — новый keystore не нужен,
   но все предыдущие установки станут «другим приложением».

3. **Подписанный релиз**:

   ```bash
   flutter build apk --release   # + подпись через key.properties / gradle
   flutter build appbundle --release
   ```

   Для GitHub Actions-релизов (требование лицензии Hiddify) keystore и пароли
   храним в secrets репозитория, не в файлах.

4. **Куда публикуем** (решение владельца):
   - RuStore — основной для РФ, VPN-приложения проходят модерацию;
   - APK с собственного сайта — самый быстрый и без модерации;
   - Google Play — риск удаления/ограничений для VPN-приложений из РФ.

5. **Проверка перед релизом**: `flutter build apk --release`, установка на
   устройство, туннель поднимается, RU-сайты идут direct, автопереключение при
   выключенном сервере, коды активации работают, нет секретов в логах.
